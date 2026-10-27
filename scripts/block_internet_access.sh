#!/bin/bash
# Block internet access while keeping LAN, loopback, DHCP, DNS, NTP, and optional Sentry traffic.
#
#   sh block_internet_access.sh                        Block and save the rules for reboot.
#   ALLOW_SENTRY=false sh block_internet_access.sh     Also block Sentry error reporting.
#   sh block_internet_access.sh --restore-prior-state  Re-apply the saved preference after a
#                                                      temporary unblock (used by maintenance).

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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=firewall_helpers.sh
source "$SCRIPT_DIR/firewall_helpers.sh"

case "${1:-}" in
  --restore-prior-state)
    restore_preferred_firewall_state
    echo "Restored the saved firewall preference."
    exit 0
    ;;
  "") ;;
  *)
    echo "Usage: sh $0 [--restore-prior-state]" >&2
    exit 2
    ;;
esac

# An explicit ALLOW_SENTRY value becomes the saved preference; otherwise keep the saved one.
load_firewall_preference
allow_sentry="$FIREWALL_PREFERRED_ALLOW_SENTRY"
if [ -n "${ALLOW_SENTRY:-}" ]; then
  if [ "$ALLOW_SENTRY" = "false" ]; then
    allow_sentry=false
  else
    allow_sentry=true
  fi
fi

if [ "$allow_sentry" = "false" ]; then
  echo "ALLOW_SENTRY=false — Sentry error logging traffic will be blocked."
else
  echo -e "\e[33mIP rules were setup to allow error logs to be sent to Sentry servers\e[0m"
  echo -e "\e[33mSentry error logs will NOT be sent to Sentry unless error logging is explicitly enabled in the UI. (It's off by default)\e[0m"
  echo -e "\e[33mIf you'd like to block Sentry servers, run: 'ALLOW_SENTRY=false sh scripts/block_internet_access.sh'\e[0m"
fi

firewall_block "$allow_sentry"
echo "Blocked WAN internet access successfully!"
