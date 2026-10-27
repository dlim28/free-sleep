#!/bin/bash
# Remove Free Sleep's internet blocking without touching unrelated filter or NAT rules.
#
#   sh unblock_internet_access.sh               Temporary: the saved preference and boot rules
#                                               stay unchanged, so a reboot blocks again.
#   sh unblock_internet_access.sh --persistent  Keep internet access unblocked, including after
#                                               reboots and Free Sleep updates.

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
  --persistent) persistent=true ;;
  "") persistent=false ;;
  *)
    echo "Usage: sh $0 [--persistent]" >&2
    exit 2
    ;;
esac

firewall_unblock "$persistent"
if [ "$persistent" = "true" ]; then
  echo "Unblocked internet access persistently."
else
  echo "Unblocked internet access temporarily. Saved boot rules are unchanged."
  echo "Re-apply your saved preference with: sh $SCRIPT_DIR/block_internet_access.sh --restore-prior-state"
fi
echo "Unblocked internet access!"
