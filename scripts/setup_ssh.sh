#!/bin/bash
# Set up sshd on port 8822 as a systemd service. The server configuration is validated with
# `sshd -t` before it replaces /etc/ssh/sshd_config; the client configuration
# (/etc/ssh/ssh_config) is only repaired when an older version of this script overwrote it.

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

SERVICE_FILE="/etc/systemd/system/sshd.service"
SSHD_CONFIG_FILE="/etc/ssh/sshd_config"
CANDIDATE_CONFIG_FILE="/etc/ssh/sshd_config.candidate"
SSH_CONFIG_FILE="/etc/ssh/ssh_config"
DEFAULT_AUTHORIZED_KEYS_FILE="/etc/ssh/authorized_keys"
AUTHORIZED_KEYS_FILE="/home/root/ssh/authorized_keys"
PRIVILEGE_SEPARATION_DIR="/var/run/sshd"

# Directives written by the old script's sshd_config copy, and the server-only subset of them.
LEGACY_COPIED_DIRECTIVES=" allowusers authorizedkeysfile challengeresponseauthentication clientalivecountmax clientaliveinterval compression listenaddress passwordauthentication permitrootlogin permittty port pubkeyauthentication subsystem usepam "
SERVER_ONLY_DIRECTIVES=" allowusers authorizedkeysfile clientalivecountmax clientaliveinterval listenaddress permitrootlogin permittty subsystem usepam "

interactive=false
if [ -t 0 ] && [ "${NON_INTERACTIVE:-false}" != "true" ]; then
  interactive=true
fi

# Print the lowercase keyword of every directive line, skipping blanks and comments.
list_directives() {
  awk '$1 !~ /^#/ && NF { print tolower($1) }' "$1"
}

# True when every directive is from the old generated server config and at least one is
# server-only, which is the exact damage left by earlier versions of this script.
is_generated_server_config_copy() {
  local file="$1" directive found_server_only=false
  while IFS= read -r directive; do
    case "$LEGACY_COPIED_DIRECTIVES" in
      *" $directive "*) ;;
      *) return 1 ;;
    esac
    case "$SERVER_ONLY_DIRECTIVES" in
      *" $directive "*) found_server_only=true ;;
    esac
  done <<< "$(list_directives "$file")"
  [ "$found_server_only" = "true" ]
}

contains_server_only_directives() {
  local directive
  while IFS= read -r directive; do
    case "$SERVER_ONLY_DIRECTIVES" in
      *" $directive "*) return 0 ;;
    esac
  done <<< "$(list_directives "$1")"
  return 1
}

has_host_keys() {
  local key_file
  for key_file in /etc/ssh/ssh_host_*_key; do
    [ -f "$key_file" ] && return 0
  done
  return 1
}

find_sshd_binary() {
  if command -v sshd >/dev/null 2>&1; then
    command -v sshd
  elif [ -x /usr/sbin/sshd ]; then
    echo /usr/sbin/sshd
  fi
}

echo "This script will:"
echo "- Replace the ssh server config at $SSHD_CONFIG_FILE (validated with sshd -t first)"
echo "- Setup the ssh service to auto run at boot (port 8822)"
echo "- Remove the default authorized ssh keys at $DEFAULT_AUTHORIZED_KEYS_FILE"
echo "- Repair $SSH_CONFIG_FILE if an older version of this script overwrote it"
echo "- Prompt you to add your public ssh key"
if [ "$interactive" = "true" ]; then
  echo "Press Enter to continue or Ctrl+C to quit..."
  read -r
fi

# --------------------------------------------------------------------------------
# Server configuration

mkdir -p /etc/ssh "$PRIVILEGE_SEPARATION_DIR"
chmod 0755 "$PRIVILEGE_SEPARATION_DIR"
chown root:root "$PRIVILEGE_SEPARATION_DIR" 2>/dev/null || true

cat > "$CANDIDATE_CONFIG_FILE" <<EOF
AllowUsers root rewt
AuthorizedKeysFile $AUTHORIZED_KEYS_FILE
ChallengeResponseAuthentication no
ClientAliveCountMax 4
ClientAliveInterval 15
Compression no
ListenAddress 0.0.0.0
PasswordAuthentication yes
PermitRootLogin yes
PermitTTY yes
Port 8822
PubkeyAuthentication yes
Subsystem	sftp	/usr/libexec/sftp-server
UsePAM yes
EOF
chmod 600 "$CANDIDATE_CONFIG_FILE"

# sshd -t also checks host keys, so create any missing default keys first.
if ! has_host_keys && command -v ssh-keygen >/dev/null 2>&1; then
  echo "Generating missing SSH host keys..."
  ssh-keygen -A || echo "WARNING: Unable to generate SSH host keys." >&2
fi

sshd_binary="$(find_sshd_binary)"
if [ -n "$sshd_binary" ]; then
  echo "Validating the new sshd configuration with $sshd_binary -t..."
  if ! "$sshd_binary" -t -f "$CANDIDATE_CONFIG_FILE"; then
    rm -f "$CANDIDATE_CONFIG_FILE"
    echo "ERROR: Invalid sshd configuration. $SSHD_CONFIG_FILE was not modified." >&2
    exit 1
  fi
else
  echo "WARNING: sshd was not found, so the configuration could not be validated." >&2
fi

if [ -f "$SSHD_CONFIG_FILE" ] && cmp -s "$CANDIDATE_CONFIG_FILE" "$SSHD_CONFIG_FILE"; then
  rm -f "$CANDIDATE_CONFIG_FILE"
  echo "$SSHD_CONFIG_FILE is already up to date."
else
  if [ -f "$SSHD_CONFIG_FILE" ]; then
    previous_config_backup="$SSHD_CONFIG_FILE.bak.$(date +%Y%m%d%H%M%S)"
    cp -p "$SSHD_CONFIG_FILE" "$previous_config_backup"
    echo "Saved the previous server config to $previous_config_backup"
  fi
  mv -f "$CANDIDATE_CONFIG_FILE" "$SSHD_CONFIG_FILE"
  chown root:root "$SSHD_CONFIG_FILE" 2>/dev/null || true
  echo "Installed the new server config at $SSHD_CONFIG_FILE"
fi

echo "Removing the default authorized_keys..."
rm -f "$DEFAULT_AUTHORIZED_KEYS_FILE"

# --------------------------------------------------------------------------------
# Client configuration: earlier versions replaced ssh_config with a copy of sshd_config,
# which breaks ssh commands started on the Pod. Repair only that recognized case.

if [ -f "$SSH_CONFIG_FILE" ]; then
  if is_generated_server_config_copy "$SSH_CONFIG_FILE"; then
    damaged_config_backup="$SSH_CONFIG_FILE.server-copy.bak.$(date +%Y%m%d%H%M%S)"
    cp -p "$SSH_CONFIG_FILE" "$damaged_config_backup"
    cat > "$SSH_CONFIG_FILE" <<'EOF'
# OpenSSH client configuration, restored by Free Sleep's setup_ssh.sh.
# Server settings belong in /etc/ssh/sshd_config. See ssh_config(5) for client options.
EOF
    chmod 644 "$SSH_CONFIG_FILE"
    chown root:root "$SSH_CONFIG_FILE" 2>/dev/null || true
    echo "Repaired $SSH_CONFIG_FILE (it contained a copy of the server config)."
    echo "The damaged file was saved to $damaged_config_backup"
    if command -v ssh >/dev/null 2>&1 && ! ssh -G -F "$SSH_CONFIG_FILE" localhost >/dev/null; then
      echo "WARNING: ssh -G reported a problem with $SSH_CONFIG_FILE." >&2
    fi
  elif contains_server_only_directives "$SSH_CONFIG_FILE"; then
    echo "WARNING: $SSH_CONFIG_FILE contains server-only directives but also custom settings." >&2
    echo "WARNING: It was left unchanged; remove the server directives if ssh from the Pod fails." >&2
  fi
fi

# --------------------------------------------------------------------------------
# Authorized keys

mkdir -p "$(dirname "$AUTHORIZED_KEYS_FILE")"
if [ "$interactive" = "true" ]; then
  echo "Please paste your SSH public key below and press Enter (or just press Enter to skip):"
  read -r ssh_key
  if [ -n "$ssh_key" ]; then
    echo "$ssh_key" >> "$AUTHORIZED_KEYS_FILE"
    chmod 644 "$AUTHORIZED_KEYS_FILE"
    chown root:root "$AUTHORIZED_KEYS_FILE" 2>/dev/null || true
    echo "Added your public key to $AUTHORIZED_KEYS_FILE"
  fi
fi

# --------------------------------------------------------------------------------
# systemd service

echo "Creating systemd service file for sshd at $SERVICE_FILE..."
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=OpenSSH Server
After=network.target

[Service]
ExecStart=/usr/sbin/sshd -D
Restart=always

[Install]
WantedBy=multi-user.target
EOF

echo "Reloading systemd daemon to apply the new service..."
systemctl daemon-reload

echo "Enabling sshd service to start at boot..."
systemctl enable sshd.service

echo "Starting sshd service now..."
systemctl start sshd.service

echo "Checking sshd service status..."
systemctl status sshd.service --no-pager || true

echo ""
echo "SSH service setup complete!"
echo "SSH uses port 8822!"
echo "SSH into your device with \`ssh root@<IP> -p 8822\`"
echo "Keep your current session open until a new SSH session succeeds."
echo ""
