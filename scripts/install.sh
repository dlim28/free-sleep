#!/bin/bash
# Exit immediately on error, on undefined variables, and on error in pipelines
set -euo pipefail

# --------------------------------------------------------------------------------
# Variables
# FREE_SLEEP_REPO and FREE_SLEEP_BRANCH select the GitHub source (default: upstream main).
FREE_SLEEP_REPO="${FREE_SLEEP_REPO:-throwaway31265/free-sleep}"
FREE_SLEEP_BRANCH="${FREE_SLEEP_BRANCH:-main}"
REPO_URL="https://github.com/$FREE_SLEEP_REPO/archive/refs/heads/$FREE_SLEEP_BRANCH.zip"
REPO_DIR="/home/dac/free-sleep"
CHECKOUT_BACKUP_DIR="/home/dac/free-sleep-backup"
SERVER_DIR="$REPO_DIR/server"
USERNAME="dac"
DATABASE_PATH="/persistent/free-sleep-data/free-sleep.db"
DATABASE_BACKUP_PATH="/persistent/free-sleep-data/free-sleep-copy.db"

# Installation progress, read by finish_install to decide what to roll back.
# update.sh sets FREE_SLEEP_UPDATING and restores the previous checkout itself.
updater_owns_checkout_backup="${FREE_SLEEP_UPDATING:-false}"
installer_owns_checkout_backup=false
code_replaced=false
database_backup_created=false
migration_started=false
services_started=false
installation_succeeded=false
download_dir=""
services_to_restore=""

restore_database_backup() {
  local temporary_path="$DATABASE_PATH.restore"
  echo "Restoring the database from $DATABASE_BACKUP_PATH..." >&2
  if cp -p "$DATABASE_BACKUP_PATH" "$temporary_path" \
    && rm -f "$DATABASE_PATH-wal" "$DATABASE_PATH-shm" "$DATABASE_PATH-journal" \
    && mv -f "$temporary_path" "$DATABASE_PATH"; then
    chown "$USERNAME:$USERNAME" "$DATABASE_PATH" 2>/dev/null || echo "WARNING: Unable to set $USERNAME ownership on $DATABASE_PATH" >&2
    return 0
  fi
  rm -f "$temporary_path"
  return 1
}

restore_previous_checkout() {
  echo "Restoring the previous installation from $CHECKOUT_BACKUP_DIR..." >&2
  rm -rf "$REPO_DIR" && mv "$CHECKOUT_BACKUP_DIR" "$REPO_DIR"
}

# Single exit path. On failure, restore the pre-migration database and (for direct reruns)
# the previous checkout, and restart stopped services only when code and data match again.
finish_install() {
  local exit_status=$?
  local can_restart_services=true
  trap - EXIT INT TERM HUP
  set +e
  if [ -n "$download_dir" ]; then
    rm -rf "$download_dir"
  fi

  if [ "$installation_succeeded" != "true" ]; then
    if [ "$exit_status" -eq 0 ]; then
      exit_status=1
    fi
    # Stop the new code before its database or checkout is rolled back underneath it.
    if [ "$services_started" = "true" ] && { [ "$database_backup_created" = "true" ] \
      || [ "$installer_owns_checkout_backup" = "true" ] || [ "$updater_owns_checkout_backup" = "true" ]; }; then
      systemctl stop free-sleep || true
      systemctl stop free-sleep-stream 2>/dev/null || true
    fi
    if [ "$migration_started" = "true" ] && [ "$database_backup_created" = "true" ]; then
      if ! restore_database_backup; then
        echo "ERROR: Unable to restore the database; the pre-migration backup is at $DATABASE_BACKUP_PATH" >&2
        can_restart_services=false
      fi
    fi
    if [ "$installer_owns_checkout_backup" = "true" ]; then
      if ! restore_previous_checkout; then
        echo "ERROR: Unable to restore the previous installation; it is still at $CHECKOUT_BACKUP_DIR" >&2
        can_restart_services=false
      fi
    elif [ "$code_replaced" = "true" ]; then
      can_restart_services=false
    fi
    echo -e "\033[31mERROR: Free Sleep installation failed (exit code $exit_status).\033[0m" >&2
  fi

  if [ "$can_restart_services" = "true" ]; then
    for service_name in $services_to_restore; do
      systemctl start "$service_name" || true
    done
  fi
  exit "$exit_status"
}
trap finish_install EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# Stop both services before replacing code or touching the database. Restore them on failure too.
for service_name in free-sleep-stream free-sleep; do
  if systemctl is-active --quiet "$service_name"; then
    services_to_restore="$service_name $services_to_restore"
    systemctl stop "$service_name"
  fi
done

# --------------------------------------------------------------------------------
# Download the repository
# Stage next to the installation directory so the final move stays on one filesystem.
echo "Downloading the repository from $FREE_SLEEP_REPO ($FREE_SLEEP_BRANCH)..."
download_dir="$(mktemp -d "$(dirname "$REPO_DIR")/free-sleep-download.XXXXXX")"
if ! curl -fL -o "$download_dir/free-sleep.zip" "$REPO_URL"; then
  echo "ERROR: Unable to download $REPO_URL" >&2
  echo "If internet access is blocked, run: sh $REPO_DIR/scripts/unblock_internet_access.sh" >&2
  exit 1
fi

echo ""
echo "Unzipping the repository..."
unzip -q "$download_dir/free-sleep.zip" -d "$download_dir/source"
rm -f "$download_dir/free-sleep.zip"
extracted_dirs=("$download_dir/source"/*/)
if [ "${#extracted_dirs[@]}" -ne 1 ] || [ ! -d "${extracted_dirs[0]}" ]; then
  echo "ERROR: Unexpected archive layout in $REPO_URL" >&2
  exit 1
fi

echo "Setting up the installation directory..."
if [ -d "$REPO_DIR" ]; then
  if [ "$updater_owns_checkout_backup" = "true" ]; then
    rm -rf "$REPO_DIR"
  else
    # Direct reruns keep the current installation until this one succeeds.
    echo "Keeping the current installation at $CHECKOUT_BACKUP_DIR until installation succeeds..."
    rm -rf "$CHECKOUT_BACKUP_DIR"
    mv "$REPO_DIR" "$CHECKOUT_BACKUP_DIR"
    installer_owns_checkout_backup=true
  fi
fi
mv "${extracted_dirs[0]%/}" "$REPO_DIR"
code_replaced=true


chown -R "$USERNAME":"$USERNAME" "$REPO_DIR"

# Synchronize installed biometrics before restarting services. Old updaters also
# download this installer, so this repairs environments created before new dependencies.
if [ -x /home/dac/venv/bin/python ]; then
  sh "$REPO_DIR/scripts/install_python_packages.sh"
fi

# --------------------------------------------------------------------------------
# Install or update Volta
# - We check once. If it’s not installed, install it.
echo "Checking if Volta is installed for user '$USERNAME'..."
if [ -d "/home/$USERNAME/.volta" ]; then
  echo "Volta is already installed for user '$USERNAME'."
else
  echo "Volta is not installed. Installing for user '$USERNAME'..."
  sudo -u "$USERNAME" bash -c 'curl https://get.volta.sh | bash'
  # Ensure Volta environment variables are in the DAC user’s profile:
  if ! grep -q 'export VOLTA_HOME=' "/home/$USERNAME/.profile"; then
    echo -e '\nexport VOLTA_HOME="/home/dac/.volta"\nexport PATH="$VOLTA_HOME/bin:$PATH"\n' \
      >> "/home/$USERNAME/.profile"
  fi
  echo "Finished installing Volta"
  echo ""
fi


# --------------------------------------------------------------------------------
# Install (or update) Node via Volta
echo "Installing/ensuring Node 24.11.0 via Volta..."
sudo -u "$USERNAME" bash -c "source /home/$USERNAME/.profile && volta install node@24.11.0"

# --------------------------------------------------------------------------------
# Setup /persistent/free-sleep-data (migrate old configs, logs, etc.)
mkdir -p /persistent/free-sleep-data/logs/
mkdir -p /persistent/free-sleep-data/lowdb/

SRC_FILE="/opt/eight/bin/frank.sh"
DEST_FILE="/persistent/free-sleep-data/dac_sock_path.txt"

if [ -f "$DEST_FILE" ]; then
  echo "Destination file $DEST_FILE already exists, skipping copy."
else
  if [ -r "$SRC_FILE" ]; then
    echo "Found $SRC_FILE, searching for dac.sock path..."
    result=$(grep -oP '(?<=DAC_SOCKET=)[^ ]*dac\.sock' "$SRC_FILE" || true)
    if [ -n "$result" ]; then
      echo "$result" > "$DEST_FILE"
      echo "DAC socket path saved to $DEST_FILE"
    else
      echo "No dac.sock path found in $SRC_FILE, skipping write."
    fi
  else
    echo "File $SRC_FILE not found or not readable, skipping."
  fi
fi


# DO NOT REMOVE, OLD VERSIONS WILL LOSE settings & schedules
FILES_TO_MOVE=(
  "/home/dac/free-sleep-database/settingsDB.json:/persistent/free-sleep-data/lowdb/settingsDB.json"
  "/home/dac/free-sleep-database/schedulesDB.json:/persistent/free-sleep-data/lowdb/schedulesDB.json"
  "/home/dac/dac_sock_path.txt:/persistent/free-sleep-data/dac_sock_path.txt"
)

for entry in "${FILES_TO_MOVE[@]}"; do
  IFS=":" read -r SOURCE_FILE DESTINATION <<< "$entry"
  if [ -f "$SOURCE_FILE" ]; then
    mv "$SOURCE_FILE" "$DESTINATION"
    echo "Moved $SOURCE_FILE to $DESTINATION"
  fi
done

if [ -d /persistent/deviceinfo/ ]; then
  chown -R "$USERNAME":"$USERNAME" /persistent/deviceinfo/
fi

if [ -d /deviceinfo/ ]; then
  chown -R "$USERNAME":"$USERNAME" /deviceinfo/
fi

# Change ownership and permissions
chown -R "$USERNAME":"$USERNAME" /persistent/free-sleep-data/
chmod 770 /persistent/free-sleep-data/
chmod g+s /persistent/free-sleep-data/

# --------------------------------------------------------------------------------
# Install server dependencies

BACKUP_PATH="$CHECKOUT_BACKUP_DIR/server/package-lock.json"
NEW_PATH="$SERVER_DIR/package-lock.json"
NODE_MODULES_BACKUP="$CHECKOUT_BACKUP_DIR/server/node_modules"
NODE_MODULES_NEW="$SERVER_DIR/node_modules"

echo "Reviewing npm dependencies for changes..."
if [ -f "$BACKUP_PATH" ] && [ -f "$NEW_PATH" ]; then
  BACKUP_HASH=$(sha256sum "$BACKUP_PATH" | awk '{print $1}')
  NEW_HASH=$(sha256sum "$NEW_PATH" | awk '{print $1}')

  echo "Backup hash: $BACKUP_HASH"
  echo "New hash: $NEW_HASH"

  if [ "$BACKUP_HASH" != "$NEW_HASH" ]; then
    echo "package-lock.json changed — running npm install..."
    sudo -u "$USERNAME" bash -c "cd '$SERVER_DIR' && /home/$USERNAME/.volta/bin/npm install"
  else
    echo "package-lock.json unchanged — copying node_modules from backup..."
    if [ -d "$NODE_MODULES_BACKUP" ]; then
      # Copy rather than move so the backup stays complete for rollback.
      cp -a "$NODE_MODULES_BACKUP" "$NODE_MODULES_NEW"
      chown -R "$USERNAME:$USERNAME" "$NODE_MODULES_NEW" || true
      echo "node_modules restored from backup."
    else
      echo "Backup node_modules not found, running npm install instead..."
      sudo -u "$USERNAME" bash -c "cd '$SERVER_DIR' && /home/$USERNAME/.volta/bin/npm install"
    fi
  fi
else
  echo "One or both package-lock.json files missing, running npm install..."
  sudo -u "$USERNAME" bash -c "cd '$SERVER_DIR' && /home/$USERNAME/.volta/bin/npm install"
fi
echo ""

# --------------------------------------------------------------------------------
# Run Prisma migrations

if [ -f "$DATABASE_PATH" ]; then
  echo "Verifying and backing up the database prior to migrations..."
  python3 "$REPO_DIR/scripts/sqlite_maintenance.py" backup "$DATABASE_PATH" "$DATABASE_BACKUP_PATH" --checkpoint
  database_backup_created=true
else
  echo "Source database not found, skipping copying database."
fi

# Production migrations never prompt or reset data; failures restore the backup on exit.
echo "Running Prisma migrations..."
migration_started=true
if ! sudo -u "$USERNAME" bash -c "cd '$SERVER_DIR' && /home/$USERNAME/.volta/bin/npm run migrate:deploy"; then
  echo -e "\033[31mERROR: Prisma migrations failed!\033[0m" >&2
  exit 1
fi
echo "Prisma migrations completed successfully."

# migrate deploy does not generate the client, and reused node_modules hold the old one.
echo "Generating the Prisma client..."
if ! sudo -u "$USERNAME" bash -c "cd '$SERVER_DIR' && /home/$USERNAME/.volta/bin/npm run generate"; then
  echo -e "\033[31mERROR: Prisma client generation failed!\033[0m" >&2
  exit 1
fi

echo ""

# --------------------------------------------------------------------------------
# Create systemd service

SERVICE_FILE="/etc/systemd/system/free-sleep.service"

echo "Creating systemd service file at $SERVICE_FILE..."

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Free Sleep Server
After=network.target

[Service]
ExecStart=/home/$USERNAME/.volta/bin/npm run start
WorkingDirectory=$SERVER_DIR
Restart=always
User=$USERNAME
Environment=NODE_ENV=production
Environment=VOLTA_HOME=/home/$USERNAME/.volta
Environment=PATH=/home/$USERNAME/.volta/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin

[Install]
WantedBy=multi-user.target
EOF

echo "Reloading systemd daemon and enabling the service..."
systemctl daemon-reload
systemctl enable free-sleep.service

echo "Starting free-sleep.service..."
services_started=true
systemctl start free-sleep.service

# Recover an enabled streamer even if it was already failing before the update.
if systemctl is-enabled --quiet free-sleep-stream.service; then
  systemctl reset-failed free-sleep-stream.service
  systemctl restart free-sleep-stream.service
fi

echo "Checking free-sleep service status..."
systemctl status free-sleep.service --no-pager || true
echo ""

# -----------------------------------------------------------------------------------------------------
# Create systemd service for updating

UPDATE_SERVICE_FILE="/etc/systemd/system/free-sleep-update.service"
echo "Creating systemd service file at $UPDATE_SERVICE_FILE..."

cat > "$UPDATE_SERVICE_FILE" <<EOF
[Unit]
Description=Free Sleep Updater
After=free-sleep.service

[Service]
Type=oneshot
ExecStart=/home/dac/free-sleep/scripts/update_service.sh
User=root
Group=root
KillMode=process
# Also capture logs at the unit level (append so your file grows)
StandardOutput=append:/persistent/free-sleep-data/logs/free-sleep-update.log
StandardError=append:/persistent/free-sleep-data/logs/free-sleep-update.log

EOF
# --------------------------------------------------------------------------------
# Graceful device time update (optional)

echo "Attempting to update device time from Google..."
# If the curl fails or is blocked, skip with a warning but don't fail the entire script
if date_string="$(curl -s --head http://google.com | grep '^Date: ' | sed 's/Date: //g')" && [ -n "$date_string" ]; then
  date -s "$date_string" || echo "WARNING: Unable to update system time"
else
  echo -e "\033[0;33mWARNING: Unable to retrieve date from Google... Skipping time update.\033[0m"
fi

echo ""
# --------------------------------------------------------------------------------
# Setup passwordless sudo scripts for dac user

SUDOERS_FILE="/etc/sudoers.d/$USERNAME"
echo "Setting up sudoers rules..."
# Reboot
SUDOERS_RULE="$USERNAME ALL=(ALL) NOPASSWD: /sbin/reboot"
if sudo grep -Fxq "$SUDOERS_RULE" "$SUDOERS_FILE" 2>/dev/null; then
  echo "Rule for '$USERNAME' reboot permissions already exists."
else
  echo "$SUDOERS_RULE" | sudo tee "$SUDOERS_FILE" > /dev/null
  sudo chmod 440 "$SUDOERS_FILE"
  echo "Passwordless permission for reboots granted to '$USERNAME'."
fi

# Updates
SUDOERS_UPDATE_RULE="$USERNAME ALL=(root) NOPASSWD: /bin/systemctl start free-sleep-update.service --no-block"
if sudo grep -Fxq "$SUDOERS_UPDATE_RULE" "$SUDOERS_FILE" 2>/dev/null; then
  echo "Rule for '$USERNAME' update permissions already exists."
else
  echo "$SUDOERS_UPDATE_RULE" | sudo tee -a "$SUDOERS_FILE" >> /dev/null
  sudo chmod 440 "$SUDOERS_FILE"
  echo "Passwordless permission for updates granted to '$USERNAME'."
fi
chmod 755 /home/dac/free-sleep/scripts/update_service.sh

# Keep the update guard outside the downloaded checkout, including across older installers.
MAINTENANCE_DIR="/persistent/free-sleep-maintenance"
mkdir -p "$MAINTENANCE_DIR" /etc/systemd/system/free-sleep-update.service.d
cp "$REPO_DIR/scripts/update_service.sh" "$MAINTENANCE_DIR/update_service.sh"
cp "$REPO_DIR/scripts/sqlite_maintenance.py" "$MAINTENANCE_DIR/sqlite_maintenance.py"
chown -R root:root "$MAINTENANCE_DIR"
chmod 755 "$MAINTENANCE_DIR" "$MAINTENANCE_DIR/update_service.sh"
chmod 644 "$MAINTENANCE_DIR/sqlite_maintenance.py"
cat > /etc/systemd/system/free-sleep-update.service.d/sqlite-maintenance.conf <<EOF
[Service]
ExecStart=
ExecStart=$MAINTENANCE_DIR/update_service.sh
EOF
systemctl daemon-reload


# Biometrics enablement
SUDOERS_BIOMETRICS_RULE="$USERNAME ALL=(ALL) NOPASSWD: /bin/sh /home/dac/free-sleep/scripts/enable_biometrics.sh"
if sudo grep -Fxq "$SUDOERS_BIOMETRICS_RULE" "$SUDOERS_FILE" 2>/dev/null; then
  echo "Rule for '$USERNAME' biometrics permissions already exists."
else
  echo "$SUDOERS_BIOMETRICS_RULE" | sudo tee -a "$SUDOERS_FILE" >> /dev/null
  sudo chmod 440 "$SUDOERS_FILE"
  echo "Passwordless permission for biometrics granted to '$USERNAME'."
fi

echo ""

sh /home/dac/free-sleep/scripts/add_shortcuts.sh

# --------------------------------------------------------------------------------
# Verify the server stays up before declaring success

# Succeed when a service stays active without restarting for the whole observation window.
wait_for_stable_service() {
  local service_name="$1" observation_seconds="$2" elapsed_seconds=0 initial_restarts current_restarts
  initial_restarts="$(systemctl show -p NRestarts --value "$service_name" 2>/dev/null || true)"
  while [ "$elapsed_seconds" -lt "$observation_seconds" ]; do
    sleep 2
    elapsed_seconds=$((elapsed_seconds + 2))
    if systemctl is-failed --quiet "$service_name"; then
      return 1
    fi
    current_restarts="$(systemctl show -p NRestarts --value "$service_name" 2>/dev/null || true)"
    if [ -n "$initial_restarts" ] && [ "$current_restarts" != "$initial_restarts" ]; then
      return 1
    fi
  done
  systemctl is-active --quiet "$service_name"
}

echo "Verifying free-sleep.service stays running..."
if ! wait_for_stable_service free-sleep.service 20; then
  if [ -d "$CHECKOUT_BACKUP_DIR" ]; then
    echo -e "\033[31mERROR: free-sleep.service did not stay running; rolling back. See: journalctl -u free-sleep --no-pager\033[0m" >&2
    exit 1
  fi
  # A first installation has nothing to roll back to, so finish setup and report the problem.
  echo -e "\033[33mWARNING: free-sleep.service did not stay running. See: journalctl -u free-sleep --no-pager\033[0m" >&2
fi

installation_succeeded=true
if [ "$installer_owns_checkout_backup" = "true" ]; then
  rm -rf "$CHECKOUT_BACKUP_DIR"
fi

# --------------------------------------------------------------------------------
# Finish
echo "This is your dac.sock path (if it doesn't end in dac.sock, contact support):"
cat /persistent/free-sleep-data/dac_sock_path.txt 2>/dev/null || echo "No dac.sock path found."

echo -e "\033[0;32mInstallation complete! The Free Sleep server is running and will start automatically on boot.\033[0m"
echo -e "\033[0;32mSee logs with: journalctl -u free-sleep --no-pager --output=cat\033[0m"
