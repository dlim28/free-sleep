#!/bin/bash
# Shared firewall functions for block_internet_access.sh and unblock_internet_access.sh.
#
# Free Sleep owns only its dedicated chains and the single hooks that jump to them:
#   IPv4: FREE_SLEEP_IN (from INPUT) and FREE_SLEEP_OUT (from OUTPUT)
#   IPv6: FREE_SLEEP_IN6 (from INPUT) and FREE_SLEEP_OUT6 (from OUTPUT)
# Unrelated filter and NAT rules are never flushed. firewall_config.env records the owner's
# preference, which maintenance scripts restore after a temporary unblock.

FIREWALL_DATA_DIR="${FREE_SLEEP_DATA_DIR:-/persistent/free-sleep-data}"
FIREWALL_CONFIG_FILE="$FIREWALL_DATA_DIR/firewall_config.env"
DNS_OVERRIDE_FILE="$FIREWALL_DATA_DIR/dns_servers.txt"
RESOLV_CONF_FILE="${FREE_SLEEP_RESOLV_CONF:-/etc/resolv.conf}"
SAVED_RULES_DIR="${FREE_SLEEP_IPTABLES_RULES_DIR:-/etc/iptables}"
FIREWALL_LOCK_FILE="${FREE_SLEEP_FIREWALL_LOCK_FILE:-/run/free-sleep-firewall.lock}"
TIMESYNCD_CONFIG_FILE="${FREE_SLEEP_TIMESYNCD_CONFIG:-/etc/systemd/timesyncd.conf}"

IPV4_IN_CHAIN="FREE_SLEEP_IN"
IPV4_OUT_CHAIN="FREE_SLEEP_OUT"
IPV6_IN_CHAIN="FREE_SLEEP_IN6"
IPV6_OUT_CHAIN="FREE_SLEEP_OUT6"
STAGING_SUFFIX="_NEW"

LAN_IPV4_RANGES=(10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16)
LAN_IPV6_RANGES=(fe80::/10 fc00::/7)
# https://docs.sentry.io/security-legal-pii/security/ip-ranges/#event-ingestion
SENTRY_IPV4_ADDRESSES=(35.186.247.156 34.120.195.249 34.36.122.224 34.36.87.148 34.120.62.213 130.211.36.74)
# ICMPv6 needed beyond local addresses: errors including Packet Too Big (1-4),
# multicast listener messages (130-132, 143), and router/neighbor discovery (133-137).
ICMPV6_REQUIRED_TYPES=(1 2 3 4 130 131 132 133 134 135 136 137 143)

# Exact rules appended to the built-in chains by earlier versions of block_internet_access.sh.
LEGACY_IPV4_INPUT_RULES=(
  "-m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"
  "-s 10.0.0.0/8 -j ACCEPT"
  "-s 172.16.0.0/12 -j ACCEPT"
  "-s 192.168.0.0/16 -j ACCEPT"
  "-p udp --sport 123 -j ACCEPT"
  "-i lo -j ACCEPT"
  "-j DROP"
)
LEGACY_IPV4_OUTPUT_RULES=(
  "-m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"
  "-d 35.186.247.156 -j ACCEPT"
  "-d 34.120.195.249 -j ACCEPT"
  "-d 34.36.122.224 -j ACCEPT"
  "-d 34.36.87.148 -j ACCEPT"
  "-d 34.120.62.213 -j ACCEPT"
  "-d 130.211.36.74 -j ACCEPT"
  "-d 10.0.0.0/8 -j ACCEPT"
  "-d 172.16.0.0/12 -j ACCEPT"
  "-d 192.168.0.0/16 -j ACCEPT"
  "-p udp --dport 123 -j ACCEPT"
  "-o lo -j ACCEPT"
  "-j DROP"
)
LEGACY_IPV6_INPUT_RULES=(
  "-s fe80::/10 -j ACCEPT"
  "-s fd00::/8 -j ACCEPT"
  "-p udp --sport 123 -j ACCEPT"
  "-j DROP"
)
LEGACY_IPV6_OUTPUT_RULES=(
  "-d fe80::/10 -j ACCEPT"
  "-d fd00::/8 -j ACCEPT"
  "-p udp --dport 123 -j ACCEPT"
  "-j DROP"
)

IPV4_WAIT_ARGUMENTS=""
IPV6_WAIT_ARGUMENTS=""
IPV6_AVAILABLE=false
INCOMING_RULES=()
OUTGOING_RULES=()

# --------------------------------------------------------------------------------
# Firewall commands

run_firewall_command() {
  local family="$1"
  shift
  # Wait arguments are a flag plus an optional number, so they are split on purpose.
  if [ "$family" = "ipv6" ]; then
    # shellcheck disable=SC2086
    ip6tables $IPV6_WAIT_ARGUMENTS "$@"
  else
    # shellcheck disable=SC2086
    iptables $IPV4_WAIT_ARGUMENTS "$@"
  fi
}

# Choose xtables lock-wait arguments supported by the installed iptables version.
detect_wait_arguments() {
  local binary="$1"
  if "$binary" -w 5 -L INPUT -n >/dev/null 2>&1; then
    echo "-w 5"
  elif "$binary" -w -L INPUT -n >/dev/null 2>&1; then
    echo "-w"
  fi
}

# Verify firewall commands before changing anything. IPv6 support is optional.
initialize_firewall_tools() {
  if ! command -v iptables >/dev/null 2>&1; then
    echo "ERROR: iptables is not installed; cannot manage the firewall." >&2
    return 1
  fi
  IPV4_WAIT_ARGUMENTS="$(detect_wait_arguments iptables)"
  if ! run_firewall_command ipv4 -L INPUT -n >/dev/null 2>&1; then
    echo "ERROR: Unable to read IPv4 firewall rules. Run this script as root." >&2
    return 1
  fi

  IPV6_AVAILABLE=false
  if command -v ip6tables >/dev/null 2>&1; then
    IPV6_WAIT_ARGUMENTS="$(detect_wait_arguments ip6tables)"
    if run_firewall_command ipv6 -L INPUT -n >/dev/null 2>&1; then
      IPV6_AVAILABLE=true
    fi
  fi
  if [ "$IPV6_AVAILABLE" != "true" ]; then
    echo "WARNING: ip6tables is unavailable; only IPv4 traffic is managed." >&2
    if [ -s /proc/net/if_inet6 ]; then
      echo "WARNING: IPv6 is enabled on this system, so IPv6 traffic cannot be filtered." >&2
    fi
  fi
}

# Serialize firewall changes from concurrent update and biometrics maintenance.
acquire_firewall_lock() {
  if ! command -v flock >/dev/null 2>&1; then
    echo "WARNING: flock is unavailable; concurrent firewall changes are not serialized." >&2
    return 0
  fi
  if ! touch "$FIREWALL_LOCK_FILE" 2>/dev/null; then
    echo "WARNING: Unable to create $FIREWALL_LOCK_FILE; continuing without a firewall lock." >&2
    return 0
  fi
  exec 9>"$FIREWALL_LOCK_FILE"
  if flock --help 2>&1 | grep -q -- '--timeout'; then
    if ! flock -w 120 9; then
      echo "ERROR: Timed out waiting for another firewall change to finish." >&2
      return 1
    fi
  else
    flock 9
  fi
}

chain_exists() {
  run_firewall_command "$1" -S "$2" >/dev/null 2>&1
}

# Remove every INPUT/OUTPUT hook to a chain, then delete the chain if it exists.
discard_chain() {
  local family="$1" chain="$2" builtin_chain attempt
  for builtin_chain in INPUT OUTPUT; do
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
      run_firewall_command "$family" -D "$builtin_chain" -j "$chain" 2>/dev/null || break
    done
  done
  if chain_exists "$family" "$chain"; then
    run_firewall_command "$family" -F "$chain" && run_firewall_command "$family" -X "$chain"
  fi
}

append_rules() {
  local family="$1" chain="$2" rule_spec
  local -a rule_arguments
  shift 2
  for rule_spec in "$@"; do
    read -ra rule_arguments <<< "$rule_spec"
    if ! run_firewall_command "$family" -A "$chain" "${rule_arguments[@]}"; then
      echo "ERROR: Unable to add $family rule to $chain: $rule_spec" >&2
      return 1
    fi
  done
}

# Swap a fully built staging chain into place so the old policy stays active until then.
activate_staging_chain() {
  local family="$1" builtin_chain="$2" chain="$3" staging_chain="$4"
  run_firewall_command "$family" -I "$builtin_chain" 1 -j "$staging_chain" \
    && discard_chain "$family" "$chain" \
    && run_firewall_command "$family" -E "$staging_chain" "$chain"
}

# Build both chains for one address family from INCOMING_RULES/OUTGOING_RULES, then activate.
# On failure the staging chains are removed and the previous policy is left untouched.
install_policy() {
  local family="$1" in_chain="$2" out_chain="$3"
  local staging_in="$in_chain$STAGING_SUFFIX" staging_out="$out_chain$STAGING_SUFFIX"
  if discard_chain "$family" "$staging_in" \
    && discard_chain "$family" "$staging_out" \
    && run_firewall_command "$family" -N "$staging_in" \
    && run_firewall_command "$family" -N "$staging_out" \
    && append_rules "$family" "$staging_in" "${INCOMING_RULES[@]}" \
    && append_rules "$family" "$staging_out" "${OUTGOING_RULES[@]}" \
    && activate_staging_chain "$family" INPUT "$in_chain" "$staging_in" \
    && activate_staging_chain "$family" OUTPUT "$out_chain" "$staging_out"; then
    return 0
  fi
  discard_chain "$family" "$staging_in" || true
  discard_chain "$family" "$staging_out" || true
  return 1
}

remove_policy() {
  local family="$1" in_chain="$2" out_chain="$3" chain
  for chain in "$in_chain" "$out_chain" "$in_chain$STAGING_SUFFIX" "$out_chain$STAGING_SUFFIX"; do
    if ! discard_chain "$family" "$chain"; then
      echo "ERROR: Unable to remove $family chain $chain." >&2
      return 1
    fi
  done
}

# Remove rules left by earlier block scripts. Only chains that still contain the legacy
# unconditional DROP are touched; otherwise identical rules may belong to the owner.
remove_legacy_rules() {
  local family="$1" builtin_chain="$2" rule_spec attempt
  local -a rule_arguments
  shift 2
  if ! run_firewall_command "$family" -C "$builtin_chain" -j DROP 2>/dev/null; then
    return 0
  fi
  echo "Removing legacy Free Sleep rules from the $family $builtin_chain chain..."
  for rule_spec in "$@"; do
    read -ra rule_arguments <<< "$rule_spec"
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
      run_firewall_command "$family" -D "$builtin_chain" "${rule_arguments[@]}" 2>/dev/null || break
    done
  done
}

remove_all_legacy_rules() {
  local family="$1"
  if [ "$family" = "ipv6" ]; then
    remove_legacy_rules ipv6 INPUT "${LEGACY_IPV6_INPUT_RULES[@]}"
    remove_legacy_rules ipv6 OUTPUT "${LEGACY_IPV6_OUTPUT_RULES[@]}"
  else
    remove_legacy_rules ipv4 INPUT "${LEGACY_IPV4_INPUT_RULES[@]}"
    remove_legacy_rules ipv4 OUTPUT "${LEGACY_IPV4_OUTPUT_RULES[@]}"
  fi
}

# Warn about rules outside Free Sleep's chains that can still block internet access.
report_remaining_blocking_rules() {
  local family="$1" builtin_chain blocking_rules
  for builtin_chain in INPUT OUTPUT; do
    blocking_rules="$(run_firewall_command "$family" -S "$builtin_chain" 2>/dev/null \
      | grep -E -- '^-P [A-Z]+ DROP|-j (DROP|REJECT)' || true)"
    if [ -n "$blocking_rules" ]; then
      echo "WARNING: Other $family $builtin_chain rules may still block internet access:" >&2
      printf '%s\n' "$blocking_rules" | sed 's/^/  /' >&2
    fi
  done
}

# --------------------------------------------------------------------------------
# Network discovery

is_ipv4_address() {
  local pattern='^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$' octet
  [[ "$1" =~ $pattern ]] || return 1
  for octet in "${BASH_REMATCH[@]:1}"; do
    [ "$((10#$octet))" -le 255 ] || return 1
  done
}

is_ipv6_address() {
  local pattern='^[0-9A-Fa-f:.]+$'
  [[ "$1" == *:*:* ]] && [[ "$1" =~ $pattern ]]
}

# Print a DNS server as a plain IP address, or nothing for labels and loopback stubs.
normalize_dns_address() {
  local address="$1"
  local bracketed_pattern='^\[([0-9A-Fa-f:.]+)\](:[0-9]+)?$'
  local ipv4_with_port_pattern='^([0-9.]+):[0-9]+$'
  address="${address%%#*}"
  address="${address//\\/}"
  if [[ "$address" =~ $bracketed_pattern ]] || [[ "$address" =~ $ipv4_with_port_pattern ]]; then
    address="${BASH_REMATCH[1]}"
  fi
  address="${address%%\%*}"
  case "$address" in
    127.* | ::1) return 0 ;;
  esac
  if is_ipv4_address "$address" || is_ipv6_address "$address"; then
    printf '%s\n' "$address"
  fi
}

# List DNS servers from the owner override, resolv.conf, systemd-resolved, and NetworkManager.
# Tool output is split into words; resolvectl labels and nmcli '\:' escapes are discarded.
discover_dns_servers() {
  {
    if [ -r "$DNS_OVERRIDE_FILE" ]; then
      sed 's/#.*//' "$DNS_OVERRIDE_FILE"
    fi
    if [ -r "$RESOLV_CONF_FILE" ]; then
      awk '$1 == "nameserver" { print $2 }' "$RESOLV_CONF_FILE"
    fi
    if command -v resolvectl >/dev/null 2>&1; then
      resolvectl dns 2>/dev/null || true
    fi
    if command -v nmcli >/dev/null 2>&1; then
      nmcli -g IP4.DNS,IP6.DNS device show 2>/dev/null || true
    fi
  } | tr -s ' \t|' '\n\n\n' | while IFS= read -r candidate; do
    normalize_dns_address "$candidate"
  done | sort -u
}

# Print networks attached to the Pod's interfaces, covering LANs outside the standard ranges.
discover_local_networks() {
  local family="$1"
  if ! command -v ip >/dev/null 2>&1; then
    return 0
  fi
  if [ "$family" = "ipv6" ]; then
    ip -o -6 addr show 2>/dev/null | awk '{ print $4 }' \
      | grep -E '^[0-9A-Fa-f:]+/[0-9]+$' | grep -v -E '^(::1|fe80:)' | sort -u || true
  else
    ip -o -4 addr show 2>/dev/null | awk '{ print $4 }' \
      | grep -E '^[0-9.]+/[0-9]+$' | grep -v '^127\.' | sort -u || true
  fi
}

# Set IPV4_DNS_SERVERS, IPV6_DNS_SERVERS, and DNS_DISCOVERY_FAILED.
collect_dns_servers() {
  local server
  IPV4_DNS_SERVERS=""
  IPV6_DNS_SERVERS=""
  while IFS= read -r server; do
    case "$server" in
      "") ;;
      *:*) IPV6_DNS_SERVERS="$IPV6_DNS_SERVERS $server" ;;
      *) IPV4_DNS_SERVERS="$IPV4_DNS_SERVERS $server" ;;
    esac
  done <<< "$(discover_dns_servers)"

  DNS_DISCOVERY_FAILED=false
  if [ -z "$IPV4_DNS_SERVERS$IPV6_DNS_SERVERS" ]; then
    DNS_DISCOVERY_FAILED=true
    echo "WARNING: No DNS servers were discovered; allowing DNS (port 53) to any server." >&2
    echo "WARNING: List trusted DNS servers in $DNS_OVERRIDE_FILE to restrict DNS." >&2
  else
    echo "Allowing DNS to:$IPV4_DNS_SERVERS$IPV6_DNS_SERVERS"
  fi
}

# --------------------------------------------------------------------------------
# Rule sets. Each entry is the argument list for one rule; DROP is always last.

add_dns_rules() {
  local dns_servers="$1" server
  if [ "$DNS_DISCOVERY_FAILED" = "true" ]; then
    OUTGOING_RULES+=("-p udp --dport 53 -j ACCEPT" "-p tcp --dport 53 -j ACCEPT")
    INCOMING_RULES+=(
      "-p udp --sport 53 -m conntrack --ctstate ESTABLISHED -j ACCEPT"
      "-p tcp --sport 53 -m conntrack --ctstate ESTABLISHED -j ACCEPT"
    )
    return 0
  fi
  for server in $dns_servers; do
    OUTGOING_RULES+=("-p udp -d $server --dport 53 -j ACCEPT" "-p tcp -d $server --dport 53 -j ACCEPT")
    INCOMING_RULES+=(
      "-p udp -s $server --sport 53 -j ACCEPT"
      "-p tcp -s $server --sport 53 -m conntrack --ctstate ESTABLISHED -j ACCEPT"
    )
  done
}

collect_ipv4_rules() {
  local allow_sentry="$1" network address
  OUTGOING_RULES=("-o lo -j ACCEPT")
  INCOMING_RULES=("-i lo -j ACCEPT")
  for network in "${LAN_IPV4_RANGES[@]}" $(discover_local_networks ipv4); do
    OUTGOING_RULES+=("-d $network -j ACCEPT")
    INCOMING_RULES+=("-s $network -j ACCEPT")
  done
  # DHCP lease acquisition and renewal
  OUTGOING_RULES+=("-p udp --sport 68 --dport 67 -j ACCEPT")
  INCOMING_RULES+=("-p udp --sport 67 --dport 68 -j ACCEPT")
  # NTP clock synchronization
  OUTGOING_RULES+=("-p udp --dport 123 -j ACCEPT")
  INCOMING_RULES+=("-p udp --sport 123 -j ACCEPT")
  add_dns_rules "$IPV4_DNS_SERVERS"
  if [ "$allow_sentry" = "true" ]; then
    for address in "${SENTRY_IPV4_ADDRESSES[@]}"; do
      OUTGOING_RULES+=("-d $address -j ACCEPT")
      INCOMING_RULES+=("-s $address -m conntrack --ctstate ESTABLISHED -j ACCEPT")
    done
  fi
  OUTGOING_RULES+=("-j DROP")
  INCOMING_RULES+=("-j DROP")
}

collect_ipv6_rules() {
  local network icmp_type
  OUTGOING_RULES=("-o lo -j ACCEPT")
  INCOMING_RULES=("-i lo -j ACCEPT")
  for network in "${LAN_IPV6_RANGES[@]}" $(discover_local_networks ipv6); do
    OUTGOING_RULES+=("-d $network -j ACCEPT")
    INCOMING_RULES+=("-s $network -j ACCEPT")
  done
  for icmp_type in "${ICMPV6_REQUIRED_TYPES[@]}"; do
    OUTGOING_RULES+=("-p icmpv6 --icmpv6-type $icmp_type -j ACCEPT")
    INCOMING_RULES+=("-p icmpv6 --icmpv6-type $icmp_type -j ACCEPT")
  done
  # DHCPv6 lease acquisition and renewal
  OUTGOING_RULES+=("-p udp --sport 546 --dport 547 -j ACCEPT")
  INCOMING_RULES+=("-p udp --sport 547 --dport 546 -j ACCEPT")
  # NTP clock synchronization
  OUTGOING_RULES+=("-p udp --dport 123 -j ACCEPT")
  INCOMING_RULES+=("-p udp --sport 123 -j ACCEPT")
  add_dns_rules "$IPV6_DNS_SERVERS"
  OUTGOING_RULES+=("-j DROP")
  INCOMING_RULES+=("-j DROP")
}

# --------------------------------------------------------------------------------
# Saved preference and boot persistence

load_firewall_preference() {
  local key value
  FIREWALL_PREFERRED_STATUS="blocked"
  FIREWALL_PREFERRED_ALLOW_SENTRY="true"
  if [ ! -r "$FIREWALL_CONFIG_FILE" ]; then
    return 0
  fi
  while IFS='=' read -r key value || [ -n "$key" ]; do
    key="${key//[[:space:]]/}"
    value="${value//\"/}"
    value="${value//[[:space:]]/}"
    case "$key:$value" in
      FIREWALL_STATUS:blocked | FIREWALL_STATUS:unblocked) FIREWALL_PREFERRED_STATUS="$value" ;;
      ALLOW_SENTRY:true | ALLOW_SENTRY:false) FIREWALL_PREFERRED_ALLOW_SENTRY="$value" ;;
    esac
  done < "$FIREWALL_CONFIG_FILE"
}

save_firewall_preference() {
  local status="$1" allow_sentry="$2" temporary_file="$FIREWALL_CONFIG_FILE.tmp"
  if mkdir -p "$FIREWALL_DATA_DIR" \
    && printf 'FIREWALL_STATUS="%s"\nALLOW_SENTRY="%s"\n' "$status" "$allow_sentry" > "$temporary_file" \
    && chmod 644 "$temporary_file" \
    && mv -f "$temporary_file" "$FIREWALL_CONFIG_FILE"; then
    return 0
  fi
  rm -f "$temporary_file"
  echo "ERROR: Unable to save the firewall preference to $FIREWALL_CONFIG_FILE." >&2
  return 1
}

write_saved_rules() {
  local save_command="$1" destination="$2" temporary_file="$2.free-sleep.tmp"
  if "$save_command" > "$temporary_file" && grep -q '^\*filter' "$temporary_file" \
    && mv -f "$temporary_file" "$destination"; then
    return 0
  fi
  rm -f "$temporary_file"
  echo "ERROR: Unable to save firewall rules with $save_command to $destination." >&2
  return 1
}

# Save the complete rule set for the Pod's boot-time iptables restore.
save_firewall_rules() {
  if [ ! -d "$SAVED_RULES_DIR" ]; then
    echo "WARNING: $SAVED_RULES_DIR does not exist; firewall rules will not persist after reboot." >&2
    return 0
  fi
  write_saved_rules iptables-save "$SAVED_RULES_DIR/iptables.rules" || return 1
  if [ "$IPV6_AVAILABLE" = "true" ]; then
    write_saved_rules ip6tables-save "$SAVED_RULES_DIR/ip6tables.rules" || return 1
  fi
  echo "Saved firewall rules to $SAVED_RULES_DIR for reboot."
}

# Point timesyncd at NTP pools, which stay reachable through the NTP allowance.
configure_time_sync() {
  local config_dir
  config_dir="$(dirname "$TIMESYNCD_CONFIG_FILE")"
  if [ ! -d "$config_dir" ] || [ ! -w "$config_dir" ]; then
    return 0
  fi
  echo "Updating the timesyncd config"
  cat > "$TIMESYNCD_CONFIG_FILE" <<EOF
[Time]
NTP=pool.ntp.org 0.pool.ntp.org 1.pool.ntp.org 2.pool.ntp.org 3.pool.ntp.org
FallbackNTP=time1.google.com time2.google.com time3.google.com time4.google.com
RootDistanceMaxSec=5
PollIntervalMinSec=32
PollIntervalMaxSec=2048
EOF
  systemctl restart systemd-timesyncd || echo "WARNING: Unable to restart systemd-timesyncd." >&2
}

# --------------------------------------------------------------------------------
# Operations used by the block and unblock scripts

# Block external traffic for IPv4 and IPv6, save the preference, and persist the rules.
firewall_block() {
  local allow_sentry="$1"
  acquire_firewall_lock || return 1
  initialize_firewall_tools || return 1
  echo "Configuring Free Sleep firewall rules (ALLOW_SENTRY=$allow_sentry)..."
  collect_dns_servers

  collect_ipv4_rules "$allow_sentry"
  if ! install_policy ipv4 "$IPV4_IN_CHAIN" "$IPV4_OUT_CHAIN"; then
    echo "ERROR: Failed to apply IPv4 blocking; the previous IPv4 policy was kept." >&2
    return 1
  fi
  remove_all_legacy_rules ipv4

  if [ "$IPV6_AVAILABLE" = "true" ]; then
    collect_ipv6_rules
    if ! install_policy ipv6 "$IPV6_IN_CHAIN" "$IPV6_OUT_CHAIN"; then
      echo "ERROR: Failed to apply IPv6 blocking; the previous IPv6 policy was kept." >&2
      return 1
    fi
    remove_all_legacy_rules ipv6
  fi

  save_firewall_preference blocked "$allow_sentry" || return 1
  save_firewall_rules || return 1
  configure_time_sync
}

# Remove Free Sleep's chains. Only a persistent unblock changes the preference and boot rules.
firewall_unblock() {
  local persistent="$1"
  acquire_firewall_lock || return 1
  initialize_firewall_tools || return 1
  echo "Removing Free Sleep firewall rules..."

  remove_policy ipv4 "$IPV4_IN_CHAIN" "$IPV4_OUT_CHAIN" || return 1
  remove_all_legacy_rules ipv4
  report_remaining_blocking_rules ipv4
  if [ "$IPV6_AVAILABLE" = "true" ]; then
    remove_policy ipv6 "$IPV6_IN_CHAIN" "$IPV6_OUT_CHAIN" || return 1
    remove_all_legacy_rules ipv6
    report_remaining_blocking_rules ipv6
  fi

  if [ "$persistent" = "true" ]; then
    load_firewall_preference
    save_firewall_preference unblocked "$FIREWALL_PREFERRED_ALLOW_SENTRY" || return 1
    save_firewall_rules || return 1
  fi
}

# Re-apply the saved preference after a temporary unblock. Without a saved preference
# this blocks, matching the behavior of earlier update and biometrics scripts.
restore_preferred_firewall_state() {
  load_firewall_preference
  if [ "$FIREWALL_PREFERRED_STATUS" = "unblocked" ]; then
    echo "Saved firewall preference is unblocked; leaving internet access unblocked."
    firewall_unblock false
  else
    firewall_block "$FIREWALL_PREFERRED_ALLOW_SENTRY"
  fi
}
