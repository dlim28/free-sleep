#!/bin/bash
# Stateful stand-in for iptables, ip6tables, iptables-save, and ip6tables-save in tests.
# Each chain is a file of rule lines under $FAKE_FIREWALL_STATE/<binary>/<table>/.
# FAKE_FIREWALL_FAIL_MATCH makes rule additions containing that text fail;
# FAKE_FIREWALL_SAVE_FAIL makes saves fail; FAKE_IP6TABLES_UNAVAILABLE disables ip6tables.

set -u

program="$(basename "$0")"
binary="${program%-save}"
state_dir="$FAKE_FIREWALL_STATE/$binary"
printf '%s %s\n' "$program" "$*" >> "$FAKE_FIREWALL_STATE/commands.log"

if [ "$binary" = "ip6tables" ] && [ -n "${FAKE_IP6TABLES_UNAVAILABLE:-}" ]; then
  echo "ip6tables: can't initialize ip6tables table 'filter'" >&2
  exit 3
fi

builtin_chains() {
  case "$1" in
    nat) echo "PREROUTING INPUT OUTPUT POSTROUTING" ;;
    *) echo "INPUT FORWARD OUTPUT" ;;
  esac
}

initialize_table() {
  local table="$1" chain
  if [ ! -d "$state_dir/$table" ]; then
    mkdir -p "$state_dir/$table/chains" "$state_dir/$table/policies"
    for chain in $(builtin_chains "$table"); do
      : > "$state_dir/$table/chains/$chain"
      echo ACCEPT > "$state_dir/$table/policies/$chain"
    done
  fi
}

is_builtin() {
  [ -f "$table_dir/policies/$1" ]
}

user_chains() {
  local chain_file
  for chain_file in "$table_dir/chains"/*; do
    [ -f "$chain_file" ] || continue
    is_builtin "$(basename "$chain_file")" || basename "$chain_file"
  done | sort
}

print_rules() {
  local table="$1" chain
  for chain in $(builtin_chains "$table"); do
    echo "-P $chain $(cat "$table_dir/policies/$chain")"
  done
  for chain in $(user_chains); do
    echo "-N $chain"
  done
  for chain in $(builtin_chains "$table") $(user_chains); do
    sed "s/^/-A $chain /" "$table_dir/chains/$chain"
  done
}

if [ "$program" != "$binary" ]; then
  [ -z "${FAKE_FIREWALL_SAVE_FAIL:-}" ] || exit 1
  for table_path in "$state_dir"/*/; do
    [ -d "$table_path" ] || continue
    table="$(basename "$table_path")"
    table_dir="$state_dir/$table"
    echo "*$table"
    print_rules "$table" | grep -v '^-N ' | grep -v '^-P '
    echo "COMMIT"
  done
  exit 0
fi

table="filter"
arguments=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -w)
      shift
      case "${1:-}" in [0-9]*) shift ;; esac
      ;;
    -t)
      table="$2"
      shift 2
      ;;
    -n) shift ;;
    *)
      arguments+=("$1")
      shift
      ;;
  esac
done
initialize_table filter
initialize_table "$table"
table_dir="$state_dir/$table"
operation="${arguments[0]:-}"
chain="${arguments[1]:-}"
chain_file="$table_dir/chains/$chain"
rule="${arguments[*]:2}"

case "$operation" in
  -L)
    [ -z "$chain" ] || [ -f "$chain_file" ]
    ;;
  -S)
    if [ -z "$chain" ]; then
      print_rules "$table"
    else
      [ -f "$chain_file" ] || exit 1
      if is_builtin "$chain"; then
        echo "-P $chain $(cat "$table_dir/policies/$chain")"
      else
        echo "-N $chain"
      fi
      sed "s/^/-A $chain /" "$chain_file"
    fi
    ;;
  -N)
    [ ! -f "$chain_file" ] || exit 1
    : > "$chain_file"
    ;;
  -X)
    [ -f "$chain_file" ] && ! is_builtin "$chain" && [ ! -s "$chain_file" ] || exit 1
    ! grep -q -- "-j $chain\$" "$table_dir/chains"/* || exit 1
    rm -f "$chain_file"
    ;;
  -F)
    [ -f "$chain_file" ] || exit 1
    : > "$chain_file"
    ;;
  -E)
    new_chain="${arguments[2]}"
    [ -f "$chain_file" ] && [ ! -f "$table_dir/chains/$new_chain" ] || exit 1
    mv "$chain_file" "$table_dir/chains/$new_chain"
    sed -i "s/-j $chain\$/-j $new_chain/" "$table_dir/chains"/*
    ;;
  -A | -I)
    [ -f "$chain_file" ] || exit 1
    position=1
    if [ "$operation" = "-I" ] && [[ "${arguments[2]:-}" =~ ^[0-9]+$ ]]; then
      position="${arguments[2]}"
      rule="${arguments[*]:3}"
    fi
    if [ -n "${FAKE_FIREWALL_FAIL_MATCH:-}" ] && [[ "$rule" == *"$FAKE_FIREWALL_FAIL_MATCH"* ]]; then
      echo "$binary: injected failure for: $rule" >&2
      exit 1
    fi
    target="$(sed -n 's/.*-j \([^ ]*\).*/\1/p' <<< "$rule")"
    case "$target" in
      "" | ACCEPT | DROP | REJECT | RETURN | LOG) ;;
      *) [ -f "$table_dir/chains/$target" ] || exit 1 ;;
    esac
    if [ "$operation" = "-A" ] || [ ! -s "$chain_file" ]; then
      echo "$rule" >> "$chain_file"
    else
      sed -i "${position}i\\$rule" "$chain_file"
    fi
    ;;
  -D)
    [ -f "$chain_file" ] || exit 1
    line_number="$(grep -n -F -x -- "$rule" "$chain_file" | head -n 1 | cut -d: -f1)"
    [ -n "$line_number" ] || exit 1
    sed -i "${line_number}d" "$chain_file"
    ;;
  -C)
    [ -f "$chain_file" ] && grep -q -F -x -- "$rule" "$chain_file"
    ;;
  -P)
    echo "${arguments[2]}" > "$table_dir/policies/$chain"
    ;;
  *)
    echo "fake iptables: unsupported arguments: ${arguments[*]}" >&2
    exit 2
    ;;
esac
