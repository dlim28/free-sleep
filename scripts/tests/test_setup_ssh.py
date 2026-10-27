"""Tests for OpenSSH server setup and SSH client configuration repair."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


scripts_path = Path(__file__).resolve().parents[1]

# What earlier versions of setup_ssh.sh copied over /etc/ssh/ssh_config.
LEGACY_SERVER_CONFIG_COPY = '''AllowUsers root rewt
AuthorizedKeysFile /home/root/ssh/authorized_keys
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
Subsystem\tsftp\t/usr/libexec/sftp-server
UsePAM yes
'''


def write_executable(path, source):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(source)
    path.chmod(0o755)
    return path


class SetupSSHTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.folder = Path(self.directory.name)
        self.commands = self.folder / 'commands'
        self.etc_ssh = self.folder / 'etc/ssh'
        self.etc_ssh.mkdir(parents=True)
        (self.folder / 'systemd').mkdir()
        self.privilege_separation_dir = self.folder / 'var_run_sshd'
        self.log = self.folder / 'commands.log'
        self.log.touch()

        # sshd -t needs its privilege separation directory, like the real daemon.
        write_executable(self.commands / 'sshd', f'''#!/bin/sh
printf 'sshd %s\\n' "$*" >> "{self.log}"
if [ "$1" = "-t" ]; then
  [ -d "{self.privilege_separation_dir}" ] || {{ echo "Missing privilege separation directory" >&2; exit 255; }}
  [ "${{MOCK_SSHD_FAIL_VALIDATION:-0}}" = "1" ] && {{ echo "sshd validation error" >&2; exit 255; }}
fi
exit 0
''')
        write_executable(self.commands / 'ssh-keygen', f'''#!/bin/sh
printf 'ssh-keygen %s\\n' "$*" >> "{self.log}"
''')
        write_executable(self.commands / 'systemctl', f'''#!/bin/sh
printf 'systemctl %s\\n' "$*" >> "{self.log}"
[ "$1" = "start" ] && exit "${{MOCK_START_EXIT:-0}}"
exit 0
''')

        self.environment = dict(os.environ, PATH=f"{self.commands}:{os.environ['PATH']}", NON_INTERACTIVE='true')

    def rebase(self, source):
        return (source.replace('/etc/ssh', str(self.etc_ssh))
                .replace('/etc/systemd/system', str(self.folder / 'systemd'))
                .replace('/home/root', str(self.folder / 'root'))
                .replace('/var/run/sshd', str(self.privilege_separation_dir)))

    def run_setup_ssh(self, **environment):
        script = write_executable(self.folder / 'setup_ssh.sh', self.rebase((scripts_path / 'setup_ssh.sh').read_text()))
        # Run with `sh` as documented in INSTALLATION.md.
        return subprocess.run(['sh', str(script)], env=dict(self.environment, **environment),
                              capture_output=True, text=True, stdin=subprocess.DEVNULL)

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def commands_run(self):
        return self.log.read_text().splitlines()

    def test_sshd_config_is_validated_then_installed_with_port_8822_and_root_login(self):
        self.assert_success(self.run_setup_ssh())
        commands = self.commands_run()
        sshd_config = (self.etc_ssh / 'sshd_config').read_text()
        self.assertIn('Port 8822', sshd_config)
        self.assertIn('PermitRootLogin yes', sshd_config)
        self.assertIn('AllowUsers root rewt', sshd_config)
        self.assertIn(f'AuthorizedKeysFile {self.folder}/root/ssh/authorized_keys', sshd_config)
        self.assertFalse((self.etc_ssh / 'sshd_config.candidate').exists())
        self.assertTrue(any(command.startswith('sshd -t -f') for command in commands))
        self.assertIn('systemctl enable sshd.service', commands)
        self.assertIn('systemctl start sshd.service', commands)
        self.assertEqual(oct((self.etc_ssh / 'sshd_config').stat().st_mode & 0o777), '0o600')

    def test_validation_failure_preserves_existing_sshd_config(self):
        existing_config = self.etc_ssh / 'sshd_config'
        existing_config.write_text('# Existing working sshd config\nPort 22\n')
        result = self.run_setup_ssh(MOCK_SSHD_FAIL_VALIDATION='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('ERROR: Invalid sshd configuration', result.stderr)
        self.assertEqual(existing_config.read_text(), '# Existing working sshd config\nPort 22\n')
        self.assertFalse((self.etc_ssh / 'sshd_config.candidate').exists())
        self.assertNotIn('systemctl start sshd.service', self.commands_run())

    def test_missing_host_keys_are_generated_before_validation(self):
        self.assert_success(self.run_setup_ssh())
        commands = self.commands_run()
        self.assertLess(commands.index('ssh-keygen -A'),
                        next(index for index, command in enumerate(commands) if command.startswith('sshd -t')))

    def test_existing_host_keys_are_left_alone(self):
        (self.etc_ssh / 'ssh_host_ed25519_key').write_text('key')
        self.assert_success(self.run_setup_ssh())
        self.assertNotIn('ssh-keygen -A', self.commands_run())

    def test_default_authorized_keys_are_removed(self):
        (self.etc_ssh / 'authorized_keys').write_text('ssh-rsa vendor-key\n')
        self.assert_success(self.run_setup_ssh())
        self.assertFalse((self.etc_ssh / 'authorized_keys').exists())

    def test_rerun_does_not_replace_an_up_to_date_server_config(self):
        self.assert_success(self.run_setup_ssh())
        result = self.run_setup_ssh()
        self.assert_success(result)
        self.assertIn('already up to date', result.stdout)
        self.assertEqual(list(self.etc_ssh.glob('sshd_config.bak.*')), [])

    def test_changed_server_config_is_backed_up(self):
        (self.etc_ssh / 'sshd_config').write_text('Port 22\n')
        self.assert_success(self.run_setup_ssh())
        backups = list(self.etc_ssh.glob('sshd_config.bak.*'))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_text(), 'Port 22\n')

    def test_custom_client_config_is_preserved_byte_for_byte(self):
        client_config = self.etc_ssh / 'ssh_config'
        custom_content = b'# Custom client configuration\nHost pod\n  User root\n  Port 8822\n'
        client_config.write_bytes(custom_content)
        self.assert_success(self.run_setup_ssh())
        self.assertEqual(client_config.read_bytes(), custom_content)

    def test_generated_server_config_copy_is_repaired_and_backed_up(self):
        client_config = self.etc_ssh / 'ssh_config'
        client_config.write_text(LEGACY_SERVER_CONFIG_COPY)
        result = self.run_setup_ssh()
        self.assert_success(result)
        self.assertIn('Repaired', result.stdout)

        backups = list(self.etc_ssh.glob('ssh_config.server-copy.bak.*'))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_text(), LEGACY_SERVER_CONFIG_COPY)
        repaired = client_config.read_text()
        self.assertNotIn('AllowUsers', repaired)
        self.assertNotIn('PermitRootLogin', repaired)

    @unittest.skipIf(shutil.which('ssh') is None, 'ssh client unavailable')
    def test_repaired_client_config_is_accepted_by_ssh(self):
        client_config = self.etc_ssh / 'ssh_config'
        client_config.write_text(LEGACY_SERVER_CONFIG_COPY)
        broken = subprocess.run(['ssh', '-G', '-F', str(client_config), 'pod'], capture_output=True, text=True)
        self.assertNotEqual(broken.returncode, 0, 'the legacy copy should break the ssh client')

        self.assert_success(self.run_setup_ssh())
        repaired = subprocess.run(['ssh', '-G', '-F', str(client_config), 'pod'], capture_output=True, text=True)
        self.assertEqual(repaired.returncode, 0, repaired.stderr)

    def test_mixed_client_config_is_reported_but_left_unchanged(self):
        client_config = self.etc_ssh / 'ssh_config'
        mixed_content = 'Host backup\n  HostName 192.168.1.20\nPermitRootLogin yes\n'
        client_config.write_text(mixed_content)
        result = self.run_setup_ssh()
        self.assert_success(result)
        self.assertIn('server-only directives but also custom settings', result.stderr)
        self.assertEqual(client_config.read_text(), mixed_content)
        self.assertEqual(list(self.etc_ssh.glob('ssh_config.server-copy.bak.*')), [])

    def test_service_start_failure_is_reported(self):
        result = self.run_setup_ssh(MOCK_START_EXIT='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('SSH service setup complete', result.stdout)


if __name__ == '__main__':
    unittest.main()
