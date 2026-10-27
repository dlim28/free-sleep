"""Firewall tests: deterministic chains, saved preferences, legacy-rule migration, DNS discovery,
failure handling, and real packet decisions inside unprivileged Linux network namespaces.

Scripts are run with `sh`, like the Pod's maintenance commands. Nothing here touches the host
firewall: script tests use a stateful fake iptables, and packet tests run in a private namespace.
"""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


scripts_path = Path(__file__).resolve().parents[1]
tests_path = Path(__file__).resolve().parent

SENTRY_ADDRESS = '35.186.247.156'

# The rules applied by earlier versions of block_internet_access.sh with Sentry allowed.
LEGACY_RULE_COMMANDS = '''
iptables -I INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -I OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
for address in 35.186.247.156 34.120.195.249 34.36.122.224 34.36.87.148 34.120.62.213 130.211.36.74; do
  iptables -A OUTPUT -d "$address" -j ACCEPT
done
for network in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do
  iptables -A INPUT -s "$network" -j ACCEPT
  iptables -A OUTPUT -d "$network" -j ACCEPT
done
iptables -I OUTPUT -p udp --dport 123 -j ACCEPT
iptables -I INPUT -p udp --sport 123 -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT -j DROP
iptables -A OUTPUT -j DROP
'''


def write_executable(path, source):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(source)
    path.chmod(0o755)
    return path


class FirewallScriptTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.folder = Path(self.directory.name)
        self.commands = self.folder / 'commands'
        self.state = self.folder / 'firewall-state'
        self.state.mkdir()
        self.data_dir = self.folder / 'persistent/free-sleep-data'
        self.rules_dir = self.folder / 'etc/iptables'
        self.rules_dir.mkdir(parents=True)
        self.resolv_conf = self.folder / 'resolv.conf'
        self.resolv_conf.write_text('nameserver 192.168.1.1\n')

        fake_iptables = (tests_path / 'fake_iptables.sh').read_text()
        for name in ('iptables', 'ip6tables', 'iptables-save', 'ip6tables-save'):
            write_executable(self.commands / name, fake_iptables)
        write_executable(self.commands / 'systemctl', '#!/bin/sh\nexit 0\n')
        write_executable(self.commands / 'ip', '''#!/bin/sh
case "$*" in
  *"-4 addr show"*) printf '%s\\n' "${FAKE_IPV4_ADDRESSES:-}" ;;
  *"-6 addr show"*) printf '%s\\n' "${FAKE_IPV6_ADDRESSES:-}" ;;
esac
''')
        for name in ('nmcli', 'resolvectl'):
            variable = 'FAKE_' + name.upper() + '_OUTPUT'
            write_executable(self.commands / name, f'''#!/bin/sh
[ -n "${{{variable}:-}}" ] || exit 1
printf '%s\\n' "${variable}"
''')

        self.environment = dict(
            os.environ,
            PATH=f"{self.commands}:{os.environ['PATH']}",
            FAKE_FIREWALL_STATE=str(self.state),
            FREE_SLEEP_DATA_DIR=str(self.data_dir),
            FREE_SLEEP_IPTABLES_RULES_DIR=str(self.rules_dir),
            FREE_SLEEP_RESOLV_CONF=str(self.resolv_conf),
            FREE_SLEEP_FIREWALL_LOCK_FILE=str(self.folder / 'firewall.lock'),
            FREE_SLEEP_TIMESYNCD_CONFIG=str(self.folder / 'missing/timesyncd.conf'),
        )
        self.environment.pop('ALLOW_SENTRY', None)

    def run_script(self, script_name, *arguments, **environment):
        return subprocess.run(['sh', str(scripts_path / script_name), *arguments],
                              env=dict(self.environment, **environment), capture_output=True, text=True)

    def run_firewall(self, *arguments, binary='iptables'):
        return subprocess.run([str(self.commands / binary), *arguments], env=self.environment,
                              capture_output=True, text=True, check=True).stdout

    def rules(self, binary='iptables'):
        return self.run_firewall('-S', binary=binary)

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def preference(self):
        return (self.data_dir / 'firewall_config.env').read_text()

    def apply_legacy_rules(self):
        subprocess.run(['bash', '-c', 'set -e\n' + LEGACY_RULE_COMMANDS], env=self.environment, check=True)

    def test_repeated_block_is_deterministic_with_single_hooks(self):
        self.assert_success(self.run_script('block_internet_access.sh'))
        first_ipv4, first_ipv6 = self.rules(), self.rules('ip6tables')
        self.assert_success(self.run_script('block_internet_access.sh'))
        self.assertEqual(self.rules(), first_ipv4)
        self.assertEqual(self.rules('ip6tables'), first_ipv6)

        self.assertEqual(first_ipv4.count('-A INPUT -j FREE_SLEEP_IN\n'), 1)
        self.assertEqual(first_ipv4.count('-A OUTPUT -j FREE_SLEEP_OUT\n'), 1)
        self.assertEqual(first_ipv6.count('-A OUTPUT -j FREE_SLEEP_OUT6\n'), 1)
        self.assertNotIn('_NEW', first_ipv4 + first_ipv6)
        self.assertTrue(self.run_firewall('-S', 'FREE_SLEEP_OUT').endswith('-A FREE_SLEEP_OUT -j DROP\n'))
        self.assertTrue(self.run_firewall('-S', 'FREE_SLEEP_IN').endswith('-A FREE_SLEEP_IN -j DROP\n'))
        self.assertNotIn('ESTABLISHED,RELATED', first_ipv4)
        self.assertIn('FIREWALL_STATUS="blocked"', self.preference())
        self.assertIn('FREE_SLEEP_OUT', (self.rules_dir / 'iptables.rules').read_text())
        self.assertIn('FREE_SLEEP_OUT6', (self.rules_dir / 'ip6tables.rules').read_text())

    def test_sentry_preference_transitions_in_both_directions(self):
        self.assert_success(self.run_script('block_internet_access.sh'))
        self.assertIn(SENTRY_ADDRESS, self.rules())

        self.assert_success(self.run_script('block_internet_access.sh', ALLOW_SENTRY='false'))
        self.assertNotIn(SENTRY_ADDRESS, self.rules())
        self.assertIn('ALLOW_SENTRY="false"', self.preference())

        self.assert_success(self.run_script('block_internet_access.sh'))
        self.assertNotIn(SENTRY_ADDRESS, self.rules())

        self.assert_success(self.run_script('block_internet_access.sh', ALLOW_SENTRY='true'))
        self.assertIn(SENTRY_ADDRESS, self.rules())
        self.assertIn('ALLOW_SENTRY="true"', self.preference())

    def test_temporary_unblock_preserves_saved_state_and_unrelated_rules(self):
        self.run_firewall('-N', 'OWNER_RULES')
        self.run_firewall('-A', 'OWNER_RULES', '-p', 'tcp', '--dport', '9999', '-j', 'ACCEPT')
        self.run_firewall('-A', 'INPUT', '-j', 'OWNER_RULES')
        self.run_firewall('-t', 'nat', '-A', 'OUTPUT', '-p', 'tcp', '--dport', '7777', '-j', 'RETURN')
        self.assert_success(self.run_script('block_internet_access.sh', ALLOW_SENTRY='false'))
        saved_rules = (self.rules_dir / 'iptables.rules').read_text()
        preference = self.preference()

        self.assert_success(self.run_script('unblock_internet_access.sh'))
        self.assertNotIn('FREE_SLEEP', self.rules() + self.rules('ip6tables'))
        self.assertIn('-A INPUT -j OWNER_RULES', self.rules())
        self.assertIn('--dport 7777 -j RETURN', self.run_firewall('-t', 'nat', '-S'))
        self.assertEqual((self.rules_dir / 'iptables.rules').read_text(), saved_rules)
        self.assertEqual(self.preference(), preference)

        self.assert_success(self.run_script('block_internet_access.sh', '--restore-prior-state'))
        restored = self.rules()
        self.assertIn('-A OUTPUT -j FREE_SLEEP_OUT', restored)
        self.assertNotIn(SENTRY_ADDRESS, restored)
        self.assertIn('-A INPUT -j OWNER_RULES', restored)
        self.assertIn('--dport 7777 -j RETURN', self.run_firewall('-t', 'nat', '-S'))

    def test_restore_without_saved_preference_blocks_like_earlier_maintenance(self):
        self.assert_success(self.run_script('unblock_internet_access.sh'))
        self.assert_success(self.run_script('block_internet_access.sh', '--restore-prior-state'))
        self.assertIn('-A OUTPUT -j FREE_SLEEP_OUT', self.rules())
        self.assertIn(SENTRY_ADDRESS, self.rules())

    def test_persistent_unblock_survives_maintenance_restore(self):
        self.assert_success(self.run_script('block_internet_access.sh'))
        self.assert_success(self.run_script('unblock_internet_access.sh', '--persistent'))
        self.assertIn('FIREWALL_STATUS="unblocked"', self.preference())
        self.assertNotIn('FREE_SLEEP', (self.rules_dir / 'iptables.rules').read_text())

        self.assert_success(self.run_script('unblock_internet_access.sh'))
        self.assert_success(self.run_script('block_internet_access.sh', '--restore-prior-state'))
        self.assertNotIn('FREE_SLEEP', self.rules())
        self.assertIn('FIREWALL_STATUS="unblocked"', self.preference())

        self.assert_success(self.run_script('block_internet_access.sh'))
        self.assertIn('FIREWALL_STATUS="blocked"', self.preference())

    def test_duplicated_legacy_rules_are_removed_but_owner_rules_kept(self):
        self.apply_legacy_rules()
        self.apply_legacy_rules()
        self.run_firewall('-A', 'INPUT', '-p', 'tcp', '--dport', '8822', '-j', 'ACCEPT')

        self.assert_success(self.run_script('block_internet_access.sh'))
        self.assertEqual(self.run_firewall('-S', 'INPUT'),
                         '-P INPUT ACCEPT\n-A INPUT -j FREE_SLEEP_IN\n-A INPUT -p tcp --dport 8822 -j ACCEPT\n')
        self.assertEqual(self.run_firewall('-S', 'OUTPUT'), '-P OUTPUT ACCEPT\n-A OUTPUT -j FREE_SLEEP_OUT\n')

        self.apply_legacy_rules()
        self.apply_legacy_rules()
        self.assert_success(self.run_script('unblock_internet_access.sh'))
        self.assertEqual(self.run_firewall('-S', 'OUTPUT'), '-P OUTPUT ACCEPT\n')
        self.assertIn('-A INPUT -p tcp --dport 8822 -j ACCEPT', self.rules())

    def test_legacy_looking_rules_without_legacy_drop_belong_to_the_owner(self):
        self.run_firewall('-A', 'OUTPUT', '-d', '10.0.0.0/8', '-j', 'ACCEPT')
        self.assert_success(self.run_script('block_internet_access.sh'))
        self.assert_success(self.run_script('unblock_internet_access.sh'))
        self.assertIn('-A OUTPUT -d 10.0.0.0/8 -j ACCEPT', self.rules())

    def test_unblock_reports_other_rules_that_still_block(self):
        self.run_firewall('-A', 'OUTPUT', '-p', 'tcp', '--dport', '25', '-j', 'REJECT')
        result = self.run_script('unblock_internet_access.sh')
        self.assert_success(result)
        self.assertIn('may still block internet access', result.stderr)
        self.assertIn('--dport 25 -j REJECT', result.stderr)

    def test_dns_discovery_ignores_labels_and_unescapes_networkmanager_output(self):
        self.resolv_conf.write_text('# managed\nnameserver 127.0.0.53\n')
        (self.data_dir).mkdir(parents=True)
        (self.data_dir / 'dns_servers.txt').write_text('9.9.9.9  # owner override\n')
        result = self.run_script(
            'block_internet_access.sh',
            FAKE_RESOLVECTL_OUTPUT='Global: 1.1.1.1#cloudflare-dns.com\nLink 2 (wlan0): 192.168.1.1 2001:db8::53',
            FAKE_NMCLI_OUTPUT='192.168.1.1 | 8.8.8.8\nfd00\\:\\:1\n',
        )
        self.assert_success(result)
        ipv4_rules, ipv6_rules = self.rules(), self.rules('ip6tables')
        for server in ('1.1.1.1', '8.8.8.8', '9.9.9.9', '192.168.1.1'):
            self.assertIn(f'-A FREE_SLEEP_OUT -p udp -d {server} --dport 53 -j ACCEPT', ipv4_rules)
            self.assertIn(f'-A FREE_SLEEP_OUT -p tcp -d {server} --dport 53 -j ACCEPT', ipv4_rules)
        for server in ('2001:db8::53', 'fd00::1'):
            self.assertIn(f'-A FREE_SLEEP_OUT6 -p udp -d {server} --dport 53 -j ACCEPT', ipv6_rules)
        self.assertNotIn('127.0.0.53', ipv4_rules)
        self.assertNotIn('-A FREE_SLEEP_OUT -p udp --dport 53 -j ACCEPT', ipv4_rules)
        self.assertNotIn('wlan0', ipv4_rules + ipv6_rules)

    def test_dns_falls_back_to_any_server_when_nothing_is_discovered(self):
        self.resolv_conf.write_text('nameserver 127.0.0.53\n')
        result = self.run_script('block_internet_access.sh')
        self.assert_success(result)
        self.assertIn('No DNS servers were discovered', result.stderr)
        self.assertIn('-A FREE_SLEEP_OUT -p udp --dport 53 -j ACCEPT', self.rules())
        self.assertIn('-A FREE_SLEEP_OUT6 -p udp --dport 53 -j ACCEPT', self.rules('ip6tables'))

    def test_ipv6_policy_allows_local_networks_and_discovery_without_opening_internet(self):
        result = self.run_script(
            'block_internet_access.sh',
            FAKE_IPV4_ADDRESSES='3: wlan0    inet 100.64.10.5/16 brd 100.64.255.255 scope global wlan0',
            FAKE_IPV6_ADDRESSES='3: wlan0    inet6 2001:db8:1::5/64 scope global dynamic\n'
                                '3: wlan0    inet6 fe80::1/64 scope link',
        )
        self.assert_success(result)
        ipv6_rules = self.rules('ip6tables')
        self.assertIn('-A FREE_SLEEP_OUT6 -d 2001:db8:1::5/64 -j ACCEPT', ipv6_rules)
        self.assertIn('-A FREE_SLEEP_IN6 -s fc00::/7 -j ACCEPT', ipv6_rules)
        self.assertIn('-A FREE_SLEEP_IN6 -p icmpv6 --icmpv6-type 134 -j ACCEPT', ipv6_rules)
        self.assertIn('-A FREE_SLEEP_OUT6 -p icmpv6 --icmpv6-type 135 -j ACCEPT', ipv6_rules)
        self.assertIn('-A FREE_SLEEP_OUT6 -p udp --sport 546 --dport 547 -j ACCEPT', ipv6_rules)
        self.assertNotIn('-p icmpv6 -j ACCEPT', ipv6_rules)
        self.assertTrue(self.run_firewall('-S', 'FREE_SLEEP_OUT6', binary='ip6tables')
                        .endswith('-A FREE_SLEEP_OUT6 -j DROP\n'))
        self.assertIn('-A FREE_SLEEP_OUT -d 100.64.10.5/16 -j ACCEPT', self.rules())

    def test_missing_ip6tables_manages_ipv4_and_reports_it(self):
        result = self.run_script('block_internet_access.sh', FAKE_IP6TABLES_UNAVAILABLE='1')
        self.assert_success(result)
        self.assertIn('ip6tables is unavailable', result.stderr)
        self.assertIn('-A OUTPUT -j FREE_SLEEP_OUT', self.rules())
        self.assertTrue((self.rules_dir / 'iptables.rules').exists())
        self.assertFalse((self.rules_dir / 'ip6tables.rules').exists())
        self.assert_success(self.run_script('unblock_internet_access.sh', FAKE_IP6TABLES_UNAVAILABLE='1'))

    def test_rule_failure_keeps_the_previous_policy_and_preference(self):
        self.assert_success(self.run_script('block_internet_access.sh', ALLOW_SENTRY='false'))
        previous_rules, previous_preference = self.rules(), self.preference()

        result = self.run_script('block_internet_access.sh', ALLOW_SENTRY='true',
                                 FAKE_FIREWALL_FAIL_MATCH='-d 34.36.87.148')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('previous IPv4 policy was kept', result.stderr)
        self.assertEqual(self.rules(), previous_rules)
        self.assertEqual(self.preference(), previous_preference)

    def test_rule_save_failure_is_reported_and_keeps_the_saved_file(self):
        (self.rules_dir / 'iptables.rules').write_text('previous saved rules\n')
        result = self.run_script('block_internet_access.sh', FAKE_FIREWALL_SAVE_FAIL='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Unable to save firewall rules', result.stderr)
        self.assertEqual((self.rules_dir / 'iptables.rules').read_text(), 'previous saved rules\n')

    def test_concurrent_block_runs_are_serialized(self):
        self.assert_success(self.run_script('block_internet_access.sh'))
        expected_rules = self.rules()
        processes = [subprocess.Popen(['sh', str(scripts_path / 'block_internet_access.sh')], env=self.environment,
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                     for _ in range(4)]
        for process in processes:
            stdout, stderr = process.communicate(timeout=120)
            self.assertEqual(process.returncode, 0, stdout + stderr)
        self.assertEqual(self.rules(), expected_rules)

    def test_bash_in_posix_mode_reexecutes_in_native_mode(self):
        # Pods where /bin/sh is bash run these scripts in POSIX mode.
        result = subprocess.run(['bash', '--posix', str(scripts_path / 'block_internet_access.sh')],
                                env=dict(self.environment, POSIXLY_CORRECT='1'), capture_output=True, text=True)
        self.assert_success(result)
        self.assertIn('-A OUTPUT -j FREE_SLEEP_OUT', self.rules())

    def test_unknown_arguments_are_rejected(self):
        self.assertEqual(self.run_script('block_internet_access.sh', '--bogus').returncode, 2)
        self.assertEqual(self.run_script('unblock_internet_access.sh', '--bogus').returncode, 2)


def namespace_support_error():
    """Return why real namespace tests cannot run here, or None when they can."""
    if shutil.which('unshare') is None or shutil.which('iptables') is None:
        return 'unshare or iptables is unavailable'
    probe = subprocess.run(
        ['unshare', '-rnm', 'bash', '-c',
         'mount -t tmpfs tmpfs /run && iptables -L -n >/dev/null && ip link add probe0 type veth peer name probe1'],
        capture_output=True, text=True,
    )
    return None if probe.returncode == 0 else (probe.stderr.strip() or 'namespace setup failed')


NAMESPACE_SUPPORT_ERROR = namespace_support_error() if os.name == 'posix' else 'requires Linux'

# The Pod is 192.168.77.1 with a LAN router at 192.168.77.2. Addresses on the router's loopback
# act as internet hosts: 198.51.100.10 (web/NTP), 198.51.100.53 (DNS), and a Sentry address.
NAMESPACE_PRELUDE = r'''
set -uo pipefail
work="$1"
probe="python3 $PROBE"
failures=0
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
cleanup() { kill $(jobs -p) 2>/dev/null || true; }
trap cleanup EXIT

mount -t tmpfs tmpfs /run && mkdir -p /run/netns
ip link set lo up
ip netns add router
ip link add veth0 type veth peer name veth1
ip link set veth1 netns router
ip addr add 192.168.77.1/24 dev veth0
ip link set veth0 up
ip netns exec router ip link set lo up
ip netns exec router ip addr add 192.168.77.2/24 dev veth1
ip netns exec router ip link set veth1 up
for address in 198.51.100.10 198.51.100.53 35.186.247.156; do
  ip netns exec router ip addr add "$address/32" dev lo
done
ip route add default via 192.168.77.2

ip netns exec router $probe serve-tcp 0.0.0.0 8080 &
ip netns exec router $probe serve-udp 0.0.0.0 53 &
ip netns exec router $probe serve-udp 0.0.0.0 123 &
ip netns exec router $probe serve-udp 0.0.0.0 5353 &
$probe serve-tcp 127.0.0.1 9000 &
sleep 1

mkdir -p "$work/mocks" "$work/timesyncd"
printf '#!/bin/sh\nexit 0\n' > "$work/mocks/systemctl"
printf '#!/bin/sh\nexit 1\n' > "$work/mocks/nmcli"
printf '#!/bin/sh\nexit 1\n' > "$work/mocks/resolvectl"
chmod 755 "$work/mocks/"*
echo "nameserver 198.51.100.53" > "$work/resolv.conf"
export PATH="$work/mocks:/usr/sbin:/usr/bin:/sbin:/bin"
export FREE_SLEEP_DATA_DIR="$work/data" FREE_SLEEP_IPTABLES_RULES_DIR="$work/no-saved-rules"
export FREE_SLEEP_RESOLV_CONF="$work/resolv.conf" FREE_SLEEP_TIMESYNCD_CONFIG="$work/timesyncd/timesyncd.conf"
export FREE_SLEEP_FIREWALL_LOCK_FILE=/run/free-sleep-firewall.lock
unset ALLOW_SENTRY

expect() {
  local expected="$1" protocol="$2" address="$3" port="$4" description="$5" actual
  if $probe "$protocol" "$address" "$port"; then actual=allowed; else actual=blocked; fi
  [ "$actual" = "$expected" ] || fail "$description: $protocol $address:$port was $actual, expected $expected"
}

run_firewall() {
  if ! sh "$SCRIPTS/$1" "${@:2}" > "$work/firewall.log" 2>&1; then
    fail "$* exited with an error"
    cat "$work/firewall.log"
  fi
}

wait_for_file() {
  local attempt
  for attempt in $(seq 1 200); do
    [ -f "$1" ] && return 0
    sleep 0.05
  done
  return 1
}

# Hold one internet connection open; each checkpoint reports whether it still exchanges data.
open_held_connection() {
  rm -f "$work/ready" "$work/result" "$work/go"*
  $probe hold-tcp 198.51.100.10 8080 "$work/ready" "$work/result" "$work/go1" "$work/go2" &
  wait_for_file "$work/ready" || fail "could not open the held internet connection"
}

held_connection_checkpoint() {
  local step="$1" attempt
  touch "$work/go$step"
  held_result="unknown"
  for attempt in $(seq 1 200); do
    if [ "$(wc -l < "$work/result" 2>/dev/null || echo 0)" -ge "$step" ]; then
      held_result="$(sed -n "${step}p" "$work/result")"
      return
    fi
    sleep 0.05
  done
}
'''

BLOCKING_SCENARIO = r'''
expect allowed tcp 198.51.100.10 8080 "internet before blocking"
open_held_connection
run_firewall block_internet_access.sh
held_connection_checkpoint 1
[ "$held_result" = "blocked" ] || fail "an established internet connection still worked after blocking ($held_result)"

expect blocked tcp 198.51.100.10 8080 "new internet connection"
expect allowed tcp 192.168.77.2 8080 "LAN connection"
expect allowed tcp 127.0.0.1 9000 "loopback connection"
expect allowed udp 198.51.100.53 53 "discovered DNS server"
expect blocked udp 198.51.100.10 53 "DNS to an undiscovered server"
expect allowed udp 198.51.100.10 123 "NTP"
expect blocked udp 198.51.100.10 5353 "other internet UDP"
expect allowed tcp 35.186.247.156 8080 "Sentry by default"

ALLOW_SENTRY=false run_firewall block_internet_access.sh
expect blocked tcp 35.186.247.156 8080 "Sentry after ALLOW_SENTRY=false"
expect allowed tcp 192.168.77.2 8080 "LAN after ALLOW_SENTRY=false"

run_firewall unblock_internet_access.sh
expect allowed tcp 198.51.100.10 8080 "internet during temporary unblock"

run_firewall block_internet_access.sh --restore-prior-state
expect blocked tcp 198.51.100.10 8080 "internet after restoring the preference"
expect blocked tcp 35.186.247.156 8080 "Sentry preference after restore"
expect allowed udp 198.51.100.53 53 "DNS after restore"
exit "$failures"
'''

LEGACY_MIGRATION_SCENARIO = r'''
iptables -N OWNER_RULES
iptables -A OWNER_RULES -p tcp --dport 9999 -j ACCEPT
iptables -A INPUT -j OWNER_RULES
iptables -t nat -A OUTPUT -p tcp --dport 7777 -j RETURN
apply_legacy_rules() {
''' + LEGACY_RULE_COMMANDS + r'''
}

# The Pod tracks connections before legacy rules load; a conntrack rule enables that here.
iptables -N CONNECTION_TRACKING
iptables -A CONNECTION_TRACKING -m conntrack --ctstate ESTABLISHED -j RETURN

# The legacy ESTABLISHED,RELATED bypass kept existing internet connections working.
open_held_connection
apply_legacy_rules
apply_legacy_rules
held_connection_checkpoint 1
[ "$held_result" = "exchanged" ] || fail "legacy rules unexpectedly blocked the established connection ($held_result)"
expect blocked tcp 198.51.100.10 8080 "new connection under legacy rules"

run_firewall block_internet_access.sh
held_connection_checkpoint 2
[ "$held_result" = "blocked" ] || fail "migration left the established connection working ($held_result)"
iptables -S | grep -q 'ESTABLISHED,RELATED' && fail "legacy established bypass remains"
iptables -S INPUT | grep -qx -- '-A INPUT -j DROP' && fail "legacy INPUT DROP remains"
[ "$(iptables -S INPUT | grep -c -- '-j FREE_SLEEP_IN$')" -eq 1 ] || fail "expected one INPUT hook"

iptables -S > "$work/rules-before"
run_firewall block_internet_access.sh
iptables -S > "$work/rules-after"
cmp -s "$work/rules-before" "$work/rules-after" || fail "repeating the block changed the rules"

apply_legacy_rules
apply_legacy_rules
run_firewall unblock_internet_access.sh
expect allowed tcp 198.51.100.10 8080 "internet after unblocking duplicated legacy rules"
iptables -S | grep -q -- '-j DROP' && fail "DROP rules remain after unblocking"
iptables -S INPUT | grep -qx -- '-A INPUT -j OWNER_RULES' || fail "owner INPUT hook was removed"
iptables -S OWNER_RULES | grep -q -- '--dport 9999' || fail "owner chain was changed"
iptables -t nat -S OUTPUT | grep -q -- '--dport 7777 -j RETURN' || fail "owner NAT rule was removed"
exit "$failures"
'''


@unittest.skipIf(NAMESPACE_SUPPORT_ERROR, f'network namespaces unavailable: {NAMESPACE_SUPPORT_ERROR}')
class FirewallNamespaceTests(unittest.TestCase):
    """Real packets through the real scripts, isolated from the host's firewall."""

    def run_scenario(self, scenario):
        with tempfile.TemporaryDirectory() as directory:
            script = Path(directory) / 'scenario.sh'
            script.write_text(NAMESPACE_PRELUDE + scenario)
            environment = dict(os.environ, PROBE=str(tests_path / 'network_probe.py'), SCRIPTS=str(scripts_path))
            result = subprocess.run(['unshare', '-rnm', 'bash', str(script), directory], env=environment,
                                    capture_output=True, text=True, timeout=300)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_blocking_stops_existing_and_new_internet_traffic_but_keeps_local_services(self):
        self.run_scenario(BLOCKING_SCENARIO)

    def test_legacy_rules_are_migrated_and_unblock_restores_internet(self):
        self.run_scenario(LEGACY_MIGRATION_SCENARIO)


if __name__ == '__main__':
    unittest.main()
