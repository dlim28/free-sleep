#!/bin/bash
# Update Free Sleep: back up the checkout and database, temporarily unblock internet access,
# run the downloaded installer, and roll back to the previous checkout and database on failure.
#
# FREE_SLEEP_REPO and FREE_SLEEP_BRANCH select the GitHub source (default: upstream main).
# Exit status: 0 updated; 1 update failed or was refused, previous installation kept;
# 3 rollback failed and manual recovery is required (services are left stopped).

# Maintenance commands run this script with `sh`; re-run it with bash outside POSIX mode.
if [ -z "${FREE_SLEEP_BASH_REEXEC:-}" ]; then
  case "${BASH_VERSION:-}:${SHELLOPTS:-}" in
    :* | *posix*)
      export FREE_SLEEP_BASH_REEXEC=1
      exec /bin/bash "$0" "$@"
      ;;
  esac
fi
unset FREE_SLEEP_BASH_REEXEC

set -euo pipefail

APP_DIR="/home/dac/free-sleep"
BACKUP_DIR="/home/dac/free-sleep-backup"
DATA_DIR="/persistent/free-sleep-data"
DATABASE_PATH="$DATA_DIR/free-sleep.db"
DATABASE_BACKUP_PATH="$DATA_DIR/free-sleep-copy.db"
FREE_SLEEP_REPO="${FREE_SLEEP_REPO:-throwaway31265/free-sleep}"
FREE_SLEEP_BRANCH="${FREE_SLEEP_BRANCH:-main}"
INSTALLER_URL="https://raw.githubusercontent.com/$FREE_SLEEP_REPO/$FREE_SLEEP_BRANCH/scripts/install.sh"
export FREE_SLEEP_REPO FREE_SLEEP_BRANCH

# Update progress, read by finish_update to decide what to restore.
update_stage="preparing"
services_to_restore=""
free_sleep_disabled=false
firewall_unblocked=false
database_backup_created=false

print_json_if_exists() {
  local file_path="$1"

  if [ -f "$file_path" ]; then
    python3 -m json.tool "$file_path" \
      | sed 's/^/      /' \
      | sed $'s/^/\033[0;90m/' \
      | sed $'s/$/\033[0m/' || true
  else
    echo "File not found: $file_path ❌"
  fi
}

is_number() {
  case "$1" in
    "" | *[!0-9]*) return 1 ;;
  esac
}

# Refuse to start when the backup, download, and an independent dependency copy cannot fit.
check_free_space() {
  local parent_dir available_kb checkout_kb dependencies_kb=0 required_kb
  [ -d "$APP_DIR" ] || return 0
  parent_dir="$(dirname "$APP_DIR")"
  available_kb="$(df -Pk "$parent_dir" 2>/dev/null | awk 'NR == 2 { print $4 }' || true)"
  checkout_kb="$(du -sk "$APP_DIR" 2>/dev/null | awk '{ print $1 }' || true)"
  if [ -d "$APP_DIR/server/node_modules" ]; then
    dependencies_kb="$(du -sk "$APP_DIR/server/node_modules" 2>/dev/null | awk '{ print $1 }' || true)"
  fi
  if ! is_number "$available_kb" || ! is_number "$checkout_kb" || ! is_number "$dependencies_kb"; then
    echo "WARNING: Unable to measure free disk space; continuing without the space check." >&2
    return 0
  fi

  # The archive and extracted source each need about the source size, plus one dependency copy.
  required_kb=$(( (checkout_kb - dependencies_kb) * 2 + dependencies_kb + 51200 ))
  if [ "$available_kb" -lt "$required_kb" ]; then
    echo "ERROR: Not enough free disk space for a recoverable update." >&2
    echo "Required: about $(( required_kb / 1024 ))MB. Available: $(( available_kb / 1024 ))MB on $parent_dir." >&2
    echo "The current installation was not changed." >&2
    return 1
  fi
}

restore_database_backup() {
  local temporary_path="$DATABASE_PATH.restore"
  echo "Restoring the database from $DATABASE_BACKUP_PATH..."
  if cp -p "$DATABASE_BACKUP_PATH" "$temporary_path" \
    && rm -f "$DATABASE_PATH-wal" "$DATABASE_PATH-shm" "$DATABASE_PATH-journal" \
    && mv -f "$temporary_path" "$DATABASE_PATH"; then
    chown dac:dac "$DATABASE_PATH" 2>/dev/null || echo "WARNING: Unable to set dac ownership on $DATABASE_PATH" >&2
    return 0
  fi
  rm -f "$temporary_path"
  return 1
}

# Older installers move node_modules out of the backup when package-lock.json is unchanged.
reclaim_moved_dependencies() {
  local backup_modules="$BACKUP_DIR/server/node_modules" installed_modules="$APP_DIR/server/node_modules"
  if [ ! -d "$backup_modules" ] && [ -d "$installed_modules" ] \
    && cmp -s "$BACKUP_DIR/server/package-lock.json" "$APP_DIR/server/package-lock.json"; then
    echo "Returning server dependencies to the previous installation..."
    mv "$installed_modules" "$backup_modules"
  fi
}

# Put back the previous checkout and the database snapshot taken before installation.
restore_previous_installation() {
  local restore_failed=false
  if [ -d "$BACKUP_DIR" ]; then
    echo "Restoring the previous installation from $BACKUP_DIR..."
    reclaim_moved_dependencies || restore_failed=true
    if ! { rm -rf "$APP_DIR" && mv "$BACKUP_DIR" "$APP_DIR"; }; then
      restore_failed=true
    fi
  fi
  if [ "$database_backup_created" = "true" ] && ! restore_database_backup; then
    restore_failed=true
  fi
  [ "$restore_failed" = "false" ]
}

print_manual_recovery_instructions() {
  echo "ERROR: Automatic rollback failed. Free Sleep services were left stopped." >&2
  echo "To recover manually:" >&2
  echo "  1. If $BACKUP_DIR exists: rm -rf $APP_DIR && mv $BACKUP_DIR $APP_DIR" >&2
  echo "  2. If $DATABASE_BACKUP_PATH exists: cp $DATABASE_BACKUP_PATH $DATABASE_PATH" >&2
  echo "     then rm -f $DATABASE_PATH-wal $DATABASE_PATH-shm" >&2
  echo "  3. systemctl enable free-sleep && systemctl start free-sleep free-sleep-stream" >&2
}

restore_firewall_policy() {
  local block_script="$APP_DIR/scripts/block_internet_access.sh"
  firewall_unblocked=false
  if [ -f "$block_script" ] && sh "$block_script" --restore-prior-state; then
    return 0
  fi
  echo "ERROR: Failed to restore the firewall policy. Run: sh $block_script --restore-prior-state" >&2
  return 1
}

# Single exit path for success, failures, and termination signals.
finish_update() {
  local exit_status=$?
  trap - EXIT INT TERM HUP
  set +e

  if [ "$update_stage" = "installing" ]; then
    echo "Reinstall failed. Restoring from backup..." >&2
    # Installers may have started the new code; stop it before restoring files underneath it.
    systemctl stop free-sleep || true
    systemctl stop free-sleep-stream 2>/dev/null || true
    if ! restore_previous_installation; then
      print_manual_recovery_instructions
      if [ "$firewall_unblocked" = "true" ] && [ -d "$APP_DIR" ]; then
        restore_firewall_policy
      fi
      exit 3
    fi
    update_stage="restored"
    if [ "$exit_status" -eq 0 ]; then
      exit_status=1
    fi
  elif [ "$update_stage" = "installed" ]; then
    rm -rf "$BACKUP_DIR"
  fi

  if [ "$free_sleep_disabled" = "true" ]; then
    systemctl enable free-sleep || echo "ERROR: Unable to enable free-sleep.service" >&2
  fi
  if [ "$update_stage" = "installed" ] || [ "$update_stage" = "restored" ]; then
    systemctl start free-sleep || echo "ERROR: Unable to start free-sleep.service" >&2
  fi
  for service_name in $services_to_restore; do
    systemctl start "$service_name" || echo "ERROR: Unable to start $service_name" >&2
  done

  if [ "$firewall_unblocked" = "true" ] && ! restore_firewall_policy; then
    if [ "$exit_status" -eq 0 ]; then
      exit_status=1
    fi
  fi

  case "$update_stage" in
    restored)
      echo "Update failed; the previous installation and database were restored." >&2
      ;;
    installed)
      if [ "$exit_status" -eq 0 ]; then
        echo -e "\033[0;32mUpdate completed successfully!\033[0m"
        echo -e "\033[0;32mRestart your pod with 'reboot -h now'\033[0m"
      else
        echo "Update installed, but restoring the firewall policy failed." >&2
      fi
      ;;
  esac
  exit "$exit_status"
}

trap finish_update EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

print_json_if_exists "$APP_DIR/server/src/serverInfo.json"
check_free_space

# Keep biometrics stopped through the downloaded installer, including older installers.
for service_name in free-sleep-stream free-sleep; do
  if systemctl is-active --quiet "$service_name"; then
    services_to_restore="$service_name $services_to_restore"
    systemctl stop "$service_name"
  fi
done

if [ -f "$DATABASE_PATH" ]; then
  echo "Backing up the database before updating..."
  python3 "$APP_DIR/scripts/sqlite_maintenance.py" backup \
    "$DATABASE_PATH" "$DATABASE_BACKUP_PATH" --checkpoint
  database_backup_created=true
fi

free_sleep_disabled=true
systemctl disable free-sleep

# Temporary access for the download; finish_update restores the saved firewall preference.
firewall_unblocked=true
sh "$APP_DIR/scripts/unblock_internet_access.sh"

update_stage="installing"
if [ -d "$APP_DIR" ]; then
  echo "Backing up current free-sleep to $BACKUP_DIR"
  rm -rf "$BACKUP_DIR"
  mv "$APP_DIR" "$BACKUP_DIR"
fi

echo "Attempting to reinstall free-sleep from $FREE_SLEEP_REPO ($FREE_SLEEP_BRANCH)..."
export FREE_SLEEP_UPDATING=true
# Older installers download into the working directory; keep that next to the checkout.
cd "$(dirname "$APP_DIR")"
# Check the download separately: running an empty script after a failed curl exits successfully.
if installer_source="$(curl -fsSL "$INSTALLER_URL")" \
  && [ -n "$installer_source" ] \
  && /bin/bash -c "$installer_source" \
  && [ -d "$APP_DIR" ]; then
  echo "Reinstall successful."
  update_stage="installed"
  exit 0
fi
exit 1
