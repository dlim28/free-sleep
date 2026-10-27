"""Run the real install.sh, update.sh, and update_service.sh against temporary Pod paths and
mocked system commands: migrations, dependency reuse, rollback, disk space, and signals."""

import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
import unittest
import zipfile


scripts_path = Path(__file__).resolve().parents[1]


def write_executable(path, source):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(source)
    path.chmod(0o755)
    return path


def create_database(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(path) as connection:
        connection.execute('CREATE TABLE vitals (id INTEGER PRIMARY KEY, heart_rate REAL)')
        connection.execute('INSERT INTO vitals (heart_rate) VALUES (61.5)')


def database_tables(path):
    with sqlite3.connect(path) as connection:
        return {row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}


# Simulates an applied migration so tests can verify the pre-migration database comes back.
MIGRATE_DATABASE = '''python3 -c "import sqlite3, sys; c = sqlite3.connect(sys.argv[1]); \
c.execute('CREATE TABLE migrated (id INTEGER)'); c.commit()" "$TEST_DATABASE"'''


class PodTestCase(unittest.TestCase):
    """Temporary Pod filesystem with logged fake systemctl, sudo, curl, unzip, and npm."""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.folder = Path(self.directory.name)
        self.commands = self.folder / 'commands'
        self.home = self.folder / 'home/dac'
        self.app_dir = self.home / 'free-sleep'
        self.backup_dir = self.home / 'free-sleep-backup'
        self.data_dir = self.folder / 'persistent/free-sleep-data'
        self.database = self.data_dir / 'free-sleep.db'
        self.database_copy = self.data_dir / 'free-sleep-copy.db'
        self.service_state = self.folder / 'service-state'
        self.log = self.folder / 'commands.log'
        for folder in (self.home, self.data_dir, self.service_state, self.folder / 'etc/systemd/system',
                       self.folder / 'etc/sudoers.d'):
            folder.mkdir(parents=True, exist_ok=True)
        self.log.touch()

        write_executable(self.commands / 'systemctl', '''#!/bin/sh
printf 'systemctl %s\\n' "$*" >> "$TEST_LOG"
state="$TEST_SERVICE_STATE"
action="$1"
shift
case "$action" in
  is-active)
    [ "$1" = "--quiet" ] && shift
    if [ -f "$state/${1%.service}" ]; then exit 0; fi
    exit 3
    ;;
  start | restart)
    for service in "$@"; do touch "$state/${service%.service}"; done
    exit "${MOCK_START_EXIT:-0}"
    ;;
  stop)
    for service in "$@"; do rm -f "$state/${service%.service}"; done
    ;;
  is-enabled | is-failed) exit 1 ;;
  show)
    if [ -n "${MOCK_RESTART_LOOP:-}" ]; then
      count="$(cat "$state/restarts" 2>/dev/null || echo 0)"
      echo $((count + 1)) > "$state/restarts"
      echo "$count"
    else
      echo 0
    fi
    ;;
esac
exit 0
''')
        # Tests are not root, so read-only sudoers permissions would block the next append.
        write_executable(self.commands / 'sudo', '''#!/bin/bash
if [ "$1" = "-u" ]; then shift 2; fi
if [ "$1" = "chmod" ]; then exit 0; fi
exec "$@"
''')
        write_executable(self.commands / 'chown', '#!/bin/sh\nexit 0\n')
        write_executable(self.commands / 'sleep', '#!/bin/sh\nexit 0\n')
        write_executable(self.commands / 'volta', '#!/bin/sh\nexit 0\n')
        write_executable(self.commands / 'curl', '''#!/bin/sh
printf 'curl %s\\n' "$*" >> "$TEST_LOG"
[ "${MOCK_CURL_EXIT:-0}" = 0 ] || exit "$MOCK_CURL_EXIT"
case "$*" in
  *--head*) exit 0 ;;
  *-fsSL*) cat "$TEST_INSTALLER_SOURCE" ;;
  *-o*)
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "-o" ]; then cp "$TEST_ARCHIVE" "$2"; fi
      shift
    done
    ;;
esac
''')
        write_executable(self.commands / 'unzip', '''#!/usr/bin/env python3
import sys, zipfile
arguments = [argument for argument in sys.argv[1:] if argument not in ('-q', '-o')]
destination = arguments[arguments.index('-d') + 1] if '-d' in arguments else '.'
zipfile.ZipFile(arguments[0]).extractall(destination)
''')
        write_executable(self.home / '.volta/bin/npm', f'''#!/bin/sh
printf 'npm %s\\n' "$*" >> "$TEST_LOG"
case "$*" in
  install) mkdir -p node_modules && touch node_modules/installed-by-npm ;;
  "run migrate:deploy")
    if [ -f "$TEST_DATABASE" ]; then {MIGRATE_DATABASE}; fi
    exit "${{MOCK_MIGRATE_EXIT:-0}}"
    ;;
  "run generate") exit "${{MOCK_GENERATE_EXIT:-0}}" ;;
esac
''')
        (self.home / '.profile').touch()

        self.environment = dict(
            os.environ,
            PATH=f"{self.commands}:{os.environ['PATH']}",
            TEST_LOG=str(self.log),
            TEST_SERVICE_STATE=str(self.service_state),
            TEST_DATABASE=str(self.database),
            TEST_APP=str(self.app_dir),
            TEST_BACKUP=str(self.backup_dir),
        )
        self.environment.pop('FREE_SLEEP_UPDATING', None)

    def rebase(self, source):
        # The temporary home path ends in /home/dac, so replace '/home/dac' before inserting it again.
        return (source.replace('/home/dac', str(self.home))
                .replace('/home/$USERNAME', str(self.home))
                .replace('/persistent', str(self.folder / 'persistent'))
                .replace('/etc/systemd/system', str(self.folder / 'etc/systemd/system'))
                .replace('/etc/sudoers.d', str(self.folder / 'etc/sudoers.d'))
                .replace('/opt/eight', str(self.folder / 'opt/eight'))
                .replace(' /deviceinfo/', ' ' + str(self.folder / 'deviceinfo') + '/')
                .replace('export PATH="/usr/sbin:', f'export PATH="{self.commands}:/usr/sbin:'))

    def run_rebased(self, script_name, **environment):
        script = self.folder / script_name
        write_executable(script, self.rebase((scripts_path / script_name).read_text()))
        return subprocess.run(['bash', str(script)], env=dict(self.environment, **environment),
                              capture_output=True, text=True, timeout=120)

    def mark_services_active(self, *services):
        for service in services:
            (self.service_state / service).touch()

    def commands_run(self):
        return self.log.read_text().splitlines()

    def create_checkout(self, path, release, lockfile='lock-v1'):
        (path / 'server/node_modules').mkdir(parents=True)
        (path / 'server/node_modules/reused-marker').touch()
        (path / 'server/package-lock.json').write_text(lockfile)
        (path / 'release.txt').write_text(release)
        (path / 'scripts').mkdir()
        shutil.copy(scripts_path / 'sqlite_maintenance.py', path / 'scripts/sqlite_maintenance.py')
        for name in ('unblock_internet_access.sh', 'block_internet_access.sh'):
            write_executable(path / f'scripts/{name}', f'''#!/bin/sh
printf '{name} %s\\n' "$*" >> "$TEST_LOG"
[ "{name}" = block_internet_access.sh ] && exit "${{MOCK_BLOCK_EXIT:-0}}"
exit 0
''')


class InstallerTests(PodTestCase):
    def setUp(self):
        super().setUp()
        self.archive = self.folder / 'archive.zip'
        self.write_archive()
        self.environment['TEST_ARCHIVE'] = str(self.archive)

    def write_archive(self, lockfile='lock-v1'):
        with zipfile.ZipFile(self.archive, 'w') as archive:
            prefix = 'free-sleep-main/'
            archive.writestr(prefix + 'release.txt', 'new release')
            archive.writestr(prefix + 'server/package-lock.json', lockfile)
            archive.writestr(prefix + 'scripts/add_shortcuts.sh', 'exit 0\n')
            archive.writestr(prefix + 'scripts/update_service.sh', '#!/bin/bash\n')
            archive.write(scripts_path / 'sqlite_maintenance.py', prefix + 'scripts/sqlite_maintenance.py')

    def run_installer(self, **environment):
        return self.run_rebased('install.sh', **environment)

    def assert_installed_new_release(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.app_dir / 'release.txt').read_text(), 'new release')
        self.assertIn('Installation complete!', result.stdout)
        self.assertEqual(list(self.home.glob('free-sleep-download.*')), [])

    def test_installer_uses_production_migrations_and_generates_the_client(self):
        installer = (scripts_path / 'install.sh').read_text()
        self.assertIn('npm run migrate:deploy', installer)
        self.assertIn('npm run generate', installer)
        self.assertNotIn('npm run migrate deploy', installer)
        self.assertNotIn('npm run migrate deploy', (scripts_path / 'reset_db.sh').read_text())

    def test_fresh_install_succeeds(self):
        result = self.run_installer()
        self.assert_installed_new_release(result)
        commands = self.commands_run()
        self.assertIn('npm install', commands)
        self.assertLess(commands.index('npm run migrate:deploy'), commands.index('npm run generate'))
        self.assertIn('systemctl start free-sleep.service', commands)
        self.assertFalse(self.backup_dir.exists())
        self.assertTrue((self.folder / 'etc/systemd/system/free-sleep.service').exists())
        self.assertIn('throwaway31265/free-sleep/archive/refs/heads/main.zip', self.log.read_text())

    def test_source_repository_and_branch_can_be_overridden(self):
        result = self.run_installer(FREE_SLEEP_REPO='owner/fork', FREE_SLEEP_BRANCH='fix/install')
        self.assert_installed_new_release(result)
        self.assertIn('https://github.com/owner/fork/archive/refs/heads/fix/install.zip', self.log.read_text())

    def test_direct_rerun_reuses_dependencies_and_removes_backup_after_success(self):
        self.create_checkout(self.app_dir, 'old release')
        create_database(self.database)
        self.mark_services_active('free-sleep', 'free-sleep-stream')
        result = self.run_installer()
        self.assert_installed_new_release(result)
        self.assertTrue((self.app_dir / 'server/node_modules/reused-marker').exists())
        self.assertNotIn('npm install', self.commands_run())
        self.assertFalse(self.backup_dir.exists())
        self.assertTrue(self.database_copy.exists())

    def test_direct_rerun_with_changed_lockfile_installs_dependencies(self):
        self.create_checkout(self.app_dir, 'old release', lockfile='lock-v0')
        result = self.run_installer()
        self.assert_installed_new_release(result)
        self.assertIn('npm install', self.commands_run())
        self.assertFalse((self.app_dir / 'server/node_modules/reused-marker').exists())

    def test_direct_rerun_migration_failure_restores_checkout_database_and_services(self):
        self.create_checkout(self.app_dir, 'old release')
        create_database(self.database)
        self.mark_services_active('free-sleep', 'free-sleep-stream')
        result = self.run_installer(MOCK_MIGRATE_EXIT='1')

        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Prisma migrations failed', result.stderr)
        self.assertNotIn('Installation complete!', result.stdout)
        self.assertEqual((self.app_dir / 'release.txt').read_text(), 'old release')
        self.assertTrue((self.app_dir / 'server/node_modules/reused-marker').exists())
        self.assertFalse(self.backup_dir.exists())
        self.assertNotIn('migrated', database_tables(self.database))
        self.assertIn('vitals', database_tables(self.database))
        commands = self.commands_run()
        self.assertEqual(commands[-2:], ['systemctl start free-sleep', 'systemctl start free-sleep-stream'])
        self.assertNotIn('npm run generate', commands)

    def test_generate_failure_is_an_installation_failure(self):
        self.create_checkout(self.app_dir, 'old release')
        result = self.run_installer(MOCK_GENERATE_EXIT='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Prisma client generation failed', result.stderr)
        self.assertEqual((self.app_dir / 'release.txt').read_text(), 'old release')

    def test_unstable_server_rolls_back_an_update_after_stopping_new_code(self):
        # update.sh moved the previous checkout aside and owns restoring it.
        self.create_checkout(self.backup_dir, 'old release')
        create_database(self.database)
        result = self.run_installer(FREE_SLEEP_UPDATING='true', MOCK_RESTART_LOOP='1')

        self.assertNotEqual(result.returncode, 0)
        self.assertIn('did not stay running; rolling back', result.stderr)
        self.assertNotIn('Installation complete!', result.stdout)
        self.assertNotIn('migrated', database_tables(self.database))
        self.assertTrue(self.backup_dir.exists())
        commands = self.commands_run()
        self.assertIn('systemctl stop free-sleep-stream', commands)
        self.assertLess(commands.index('systemctl start free-sleep.service'),
                        commands.index('systemctl stop free-sleep'))

    def test_unstable_server_on_first_install_finishes_setup_with_a_warning(self):
        result = self.run_installer(MOCK_RESTART_LOOP='1')
        self.assert_installed_new_release(result)
        self.assertIn('WARNING: free-sleep.service did not stay running', result.stderr)
        self.assertNotIn('systemctl stop free-sleep', self.commands_run())

    def test_download_failure_keeps_the_existing_installation_running(self):
        self.create_checkout(self.app_dir, 'old release')
        self.mark_services_active('free-sleep')
        result = self.run_installer(MOCK_CURL_EXIT='22')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('unblock_internet_access.sh', result.stderr)
        self.assertEqual((self.app_dir / 'release.txt').read_text(), 'old release')
        self.assertEqual(self.commands_run()[-1], 'systemctl start free-sleep')
        self.assertEqual(list(self.home.glob('free-sleep-download.*')), [])


class UpdaterTests(PodTestCase):
    def setUp(self):
        super().setUp()
        self.create_checkout(self.app_dir, 'old release')
        create_database(self.database)
        self.mark_services_active('free-sleep', 'free-sleep-stream')
        self.installer = self.folder / 'installer.sh'
        self.environment['TEST_INSTALLER_SOURCE'] = str(self.installer)

    def use_installer(self, body):
        self.installer.write_text('set -e\n' + body)

    def new_release_installer(self):
        return '''mkdir -p "$TEST_APP/server"
cp -R "$TEST_BACKUP/scripts" "$TEST_APP/scripts"
printf 'new release' > "$TEST_APP/release.txt"
'''

    def run_update(self, **environment):
        return self.run_rebased('update.sh', **environment)

    def test_installer_failure_restores_checkout_and_database(self):
        self.use_installer(self.new_release_installer() + MIGRATE_DATABASE + '\nexit 1\n')
        result = self.run_update()

        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('the previous installation and database were restored', result.stderr)
        self.assertNotIn('Update completed successfully', result.stdout)
        self.assertEqual((self.app_dir / 'release.txt').read_text(), 'old release')
        self.assertFalse(self.backup_dir.exists())
        self.assertNotIn('migrated', database_tables(self.database))
        commands = self.commands_run()
        self.assertIn('unblock_internet_access.sh ', commands)
        self.assertIn('block_internet_access.sh --restore-prior-state', commands)
        self.assertIn('systemctl enable free-sleep', commands)
        # Stopped before the update and again before rollback, then started with the old code.
        stops = [index for index, command in enumerate(commands) if command == 'systemctl stop free-sleep']
        self.assertEqual(len(stops), 2)
        self.assertLess(stops[-1], commands.index('systemctl start free-sleep'))

    def test_rollback_reclaims_dependencies_moved_by_older_installers(self):
        self.use_installer('''mkdir -p "$TEST_APP/server"
cp "$TEST_BACKUP/server/package-lock.json" "$TEST_APP/server/"
mv "$TEST_BACKUP/server/node_modules" "$TEST_APP/server/node_modules"
exit 1
''')
        result = self.run_update()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertTrue((self.app_dir / 'server/node_modules/reused-marker').exists())

    def test_success_removes_checkout_backup_and_keeps_database_copy(self):
        self.use_installer(self.new_release_installer())
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('Update completed successfully', result.stdout)
        self.assertEqual((self.app_dir / 'release.txt').read_text(), 'new release')
        self.assertFalse(self.backup_dir.exists())
        self.assertTrue(self.database_copy.exists())
        self.assertIn('block_internet_access.sh --restore-prior-state', self.commands_run())

    def test_insufficient_disk_space_refuses_before_changing_anything(self):
        write_executable(self.commands / 'df', '''#!/bin/sh
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/root 100000 99000 1000 99% /"
''')
        self.use_installer(self.new_release_installer())
        result = self.run_update()
        self.assertEqual(result.returncode, 1)
        self.assertIn('Not enough free disk space', result.stderr)
        self.assertEqual((self.app_dir / 'release.txt').read_text(), 'old release')
        commands = self.commands_run()
        self.assertFalse(any('stop' in command or 'unblock' in command for command in commands), commands)

    def test_stale_database_copy_is_not_restored_when_no_database_existed(self):
        self.database.unlink()
        self.database_copy.write_text('stale copy from an older update')
        self.use_installer(self.new_release_installer() + 'printf "fresh" > "$TEST_DATABASE"\nexit 1\n')
        result = self.run_update()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.database.read_text(), 'fresh')

    def test_firewall_restore_failure_after_success_is_reported(self):
        self.use_installer(self.new_release_installer())
        result = self.run_update(MOCK_BLOCK_EXIT='1')
        self.assertEqual(result.returncode, 1)
        self.assertIn('restoring the firewall policy failed', result.stderr)
        self.assertEqual((self.app_dir / 'release.txt').read_text(), 'new release')

    def test_termination_during_installation_rolls_back(self):
        self.use_installer('kill -TERM "$PPID"\n' + self.new_release_installer())
        result = self.run_update()
        self.assertEqual(result.returncode, 143, result.stdout + result.stderr)
        self.assertEqual((self.app_dir / 'release.txt').read_text(), 'old release')
        self.assertIn('block_internet_access.sh --restore-prior-state', self.commands_run())

    def test_unblock_failure_reenables_and_restarts_the_server(self):
        write_executable(self.app_dir / 'scripts/unblock_internet_access.sh', 'exit 1\n')
        self.use_installer(self.new_release_installer())
        result = self.run_update()
        self.assertEqual(result.returncode, 1)
        self.assertEqual((self.app_dir / 'release.txt').read_text(), 'old release')
        commands = self.commands_run()
        self.assertIn('systemctl enable free-sleep', commands)
        self.assertIn('systemctl start free-sleep', commands)
        self.assertIn('block_internet_access.sh --restore-prior-state', commands)

    def run_update_service(self):
        # update_service.sh runs from the maintenance folder next to its sqlite helper.
        shutil.copy(scripts_path / 'sqlite_maintenance.py', self.folder / 'sqlite_maintenance.py')
        return self.run_rebased('update_service.sh')

    def test_update_service_keeps_services_stopped_when_manual_recovery_is_needed(self):
        write_executable(self.app_dir / 'scripts/update.sh', 'exit 3\n')
        result = self.run_update_service()
        self.assertEqual(result.returncode, 3)
        commands = self.commands_run()
        self.assertIn('systemctl stop free-sleep', commands)
        self.assertFalse(any(command.startswith('systemctl start') for command in commands), commands)

    def test_update_service_restarts_services_after_ordinary_failure(self):
        write_executable(self.app_dir / 'scripts/update.sh', 'exit 1\n')
        result = self.run_update_service()
        self.assertEqual(result.returncode, 1)
        self.assertIn('systemctl start free-sleep', self.commands_run())


if __name__ == '__main__':
    unittest.main()
