# Installation and networking reliability plan

Date: 2026-10-27

Branch: `fix/install-network-reliability`

Status: Implemented and reviewed; automated validation passes. Hardware checks on a Pod are still pending (see "Validation record").

## Scope and assumptions

Address points 2–9 from the installation-script review. The Pod has one trusted owner-administrator. Preserve convenient root SSH access and owner customization. Point 1 (restricting writable scripts and passwordless sudo) is outside this plan.

The work covers `scripts/install.sh`, `scripts/setup_ssh.sh`, `scripts/block_internet_access.sh`, `scripts/unblock_internet_access.sh`, and `scripts/enable_biometrics.sh`, plus their callers, shared helpers, tests, and installation documentation where necessary.

Prioritize failed installations and broken rollback, then predictable firewall behavior. Keep Pod-specific logic in `scripts/` and regression tests in `scripts/tests/`. Use descriptive variable names and short comments for complex behavior.

## Implementation order

1. Correct database migrations and preserve recoverable update backups (points 2–3).
2. Implement shared firewall behavior and network allowances together (points 4, 6, 7, and 9).
3. Propagate failures and integrate temporary network access with update and biometrics workflows (point 5).
4. Correct SSH configuration handling (point 8).
5. Complete regression checks and document Pod validation procedures.

## Point 2: Correct database migration execution and failure handling

Files: `server/package.json`, `scripts/install.sh`, `scripts/update.sh`, `scripts/update_service.sh`, and relevant SQLite helpers/tests.

- [x] Add an explicit production migration command, such as `migrate:deploy`, that loads `.env.pod` and runs `prisma migrate deploy`.
- [x] Call that command from the installer. Keep the existing development migration command available for development.
- [x] Treat migration failure as installation failure: return a nonzero status, omit the installation-success message, and prevent the updater from deleting its backup.
- [x] Preserve the pre-migration SQLite backup and keep database writers stopped during backup and migration.
- [x] Define recovery for partially applied migrations before restarting either service. Restore a matching code/database pair when rollback is safe; otherwise leave affected services stopped and report the backup location and recovery instructions. Do not let unconditional exit traps restart an incompatible application.
- [x] Delete recovery artifacts only at the documented success boundary, after required deployment checks pass.

Validation:

- Verify the invoked command is `migrate deploy`, not `migrate dev --name deploy`.
- Inject migration failures and verify the installer/updater return failure, retain recovery artifacts, and do not print success or restart incompatible services.
- Exercise fresh and existing databases with disposable SQLite files; include partial-migration failure and backup integrity checks.

## Point 3: Keep update backups usable throughout installation

Files: `scripts/install.sh`, `scripts/update.sh`, and script regression tests.

- [x] Replace the destructive move of backup `node_modules` with a strategy that leaves the backup complete. Prefer an independent copy when space permits; do not use writable hard links that let installation modify the backup.
- [x] Check available space before destructive replacement. If a complete recoverable update cannot fit, stop with a clear error while the old installation remains usable.
- [x] Preserve the original checkout and its dependencies until dependencies, migrations, and bounded service-health checks succeed.
- [x] Restore the complete previous checkout on failure, coordinated with database recovery from point 2.
- [x] Make direct installer reruns either use the same recovery protection or refuse replacement of an existing installation with instructions to use the updater.

Validation:

- Inject failures after dependency reuse and at later installation stages; verify the restored checkout still contains usable dependencies.
- Cover unchanged and changed lockfiles, missing backup dependencies, insufficient disk space, and successful cleanup.
- Verify rollback preserves settings, schedules, and the intended service enabled/disabled state.

## Point 4: Make blocking apply to existing external connections

Files: firewall scripts and a shared firewall helper under `scripts/` if needed.

- [x] Define blocking as stopping disallowed external traffic immediately, including traffic belonging to previously established connections.
- [x] Evaluate destination/source allowances before accepting established traffic. Remove the blanket established-connection bypass from Free Sleep's blocking behavior.
- [x] Keep permitted LAN SSH sessions, loopback, DNS, NTP, and optional Sentry traffic working.
- [x] Prefer filtering disallowed packets without globally clearing connection tracking, which could disrupt unrelated traffic and require another Pod dependency.

Validation:

- In an isolated Linux network namespace, open a simulated external connection before blocking and verify it cannot exchange traffic afterward.
- Verify permitted LAN SSH and required response traffic remain functional.
- Confirm the behavior with Sentry allowances enabled and disabled.

## Point 6: Make repeated firewall configuration deterministic

Files: firewall scripts, shared helper, and firewall regression tests.

- [x] Use dedicated Free Sleep chains with controlled hooks instead of repeatedly appending rules to built-in chains.
- [x] Rebuild owned rules from the requested configuration so identical repeated runs produce the same effective rules and rule counts.
- [x] Support transitions in both directions for `ALLOW_SENTRY`; disabling it must remove previously installed Sentry allowances.
- [x] Preserve the existing default for a first configuration, record an explicit owner preference, and ensure maintenance operations do not silently reset that preference. Keep firewall permission separate from the UI's error-reporting setting.
- [x] Plan migration from the existing unlabelled rules: save the original rules, identify known legacy sequences conservatively, and avoid deleting ambiguous owner rules automatically. Report any conflict that prevents the requested policy from taking effect.
- [x] Use supported locking and rule-update mechanisms to prevent concurrent update/biometrics operations from interleaving firewall changes.

Validation:

- Exercise repeated block calls and Sentry true-to-false and false-to-true transitions.
- Assert stable rule counts, correct packet decisions, and preservation of unrelated rules.
- Cover legacy-rule migration, conflicts, interrupted changes, and concurrent callers.

## Point 7: Separate temporary unblocking from persistent configuration

Files: firewall scripts, `scripts/update.sh`, `scripts/enable_biometrics.sh`, and `INSTALLATION.md`.

- [x] Remove or suspend only Free Sleep-owned rules; do not flush all IPv4 filter or NAT rules.
- [x] Apply unblock operations consistently to IPv4 and IPv6 where available. Detect and report unsupported address families explicitly.
- [x] Keep no-argument unblocking temporary for compatibility with maintenance workflows. Provide a documented explicit option for persistent unblocking.
- [x] Capture the previous Free Sleep policy before temporary unblocking and restore that policy on completion or failure, including its Sentry preference. A previously unblocked device should remain unblocked.
- [x] Preserve saved boot rules during temporary unblocking. Update persistent state only for an explicit persistent change, using verified rule-save and boot-restore behavior on the target Pod.
- [x] Ensure temporary access is restored once per operation; remove duplicate blocking calls from biometrics setup.

Validation:

- Cover IPv4-only and dual-stack environments, temporary and persistent modes, and previously blocked/unblocked states.
- Verify custom filter/NAT rules survive block/unblock operations.
- Verify maintenance failure restores the prior policy without altering its saved configuration.
- Verify reboot persistence on a test Pod or representative system with its actual rule-restore service.

## Point 9: Preserve required DNS and local IPv6 communication

Files: shared firewall implementation and installation documentation.

- [x] Allow IPv6 loopback and the ICMPv6 traffic needed for neighbor discovery, router discovery, and working local communication.
- [x] Determine permitted LAN networks from the Pod's interfaces/routes and documented configuration. Account for local IPv6 addresses that are not unique-local addresses without opening general external IPv6 access.
- [x] Discover the effective upstream DNS servers, including systems using a local resolver stub, and permit TCP/UDP port 53 to those servers only.
- [ ] Refresh resolver-dependent rules when network configuration changes using mechanisms actually available on the Pod. Provide a documented override if automatic discovery is unavailable.
  - Partial: rules are rediscovered on every block, update, and biometrics run, and `dns_servers.txt` is the documented override. No NetworkManager dispatcher hook was added, because it would re-block during a temporary maintenance unblock; router DNS on the LAN is always reachable through the LAN allowance.
- [x] Retain NTP access and verify configured NTP hostnames can resolve while blocking is enabled.
- [x] Verify DHCP acquisition/renewal still works; add narrowly scoped allowances if the target network stack requires them.

Validation:

- Cover router-provided DNS, public DNS, local resolver stubs, resolver changes, and IPv6 DNS.
- Verify IPv6 loopback, neighbor discovery, local communication, and NTP while disallowed external traffic stays blocked.
- Verify Wi-Fi reconnection and address renewal on representative Pod networking.

## Point 5: Propagate failures through installation and cleanup

Files: firewall scripts, `scripts/enable_biometrics.sh`, and update callers.

- [x] Check every required firewall, rule-save, and service operation and return nonzero on failure. Print success only after the requested state has been verified.
- [x] Preflight required commands and paths before changing network access. Use explicit handling where failures are expected instead of relying solely on shell error flags.
- [x] If an operation fails after partially changing rules, attempt to restore the previous policy and report both the original and restoration failures.
- [x] Preserve the original installation failure status. If installation succeeded but firewall restoration failed, return failure rather than silently returning zero.
- [x] Use one cleanup path for normal completion and supported termination signals; avoid repeated restoration and duplicate rules. Document that abrupt power loss cannot run cleanup.
- [x] Make biometrics health reporting reflect the completed operation. Bound HTTP requests and treat HTTP error responses as failures rather than assuming any response means success.

Validation:

- Inject failures in IPv4/IPv6 commands, persistence writes, service operations, dependency installation, and health-report requests.
- Verify exit codes, diagnostic messages, restored policy, and absence of false success messages.
- Test installation success followed by cleanup failure, and installation failure followed by cleanup failure.
- Retain existing dependency and SQLite regression coverage.

## Point 8: Keep SSH server and client configuration separate

Files: `scripts/setup_ssh.sh` and SSH setup regression tests.

- [x] Stop deleting or overwriting `/etc/ssh/ssh_config` when configuring `sshd`.
- [x] Preserve incoming root SSH access, port 8822, and the existing owner authentication choices.
- [x] Prepare and validate the server configuration with `sshd -t` before activating it, retaining the previous working configuration on failure.
- [x] For devices affected by the old script, detect the known generated server-config copy in the client-config path. Back it up and repair only that recognized case; preserve customized client files and report ambiguous cases.
- [x] Document that the original defect affects SSH initiated from the Pod, independently of incoming administrator access.

Validation:

- Validate the client configuration using `ssh -G`, without opening a network connection.
- Verify existing custom client configuration remains byte-for-byte unchanged.
- Test a recognized previously corrupted client configuration and invalid server configuration.
- On a test Pod, verify a new root SSH session succeeds before closing the existing administrator session.

## Completion criteria

- [x] Run syntax checks using each script's actual interpreter, including scripts invoked explicitly with `sh`.
- [x] Run `python3 -m unittest discover -s scripts/tests` in a supported Linux environment and add focused regression tests for the failure paths above.
- [x] Use mocked commands and temporary files for installation tests. Use isolated network namespaces for real firewall tests; never alter the development host's live firewall.
- [x] Validate production migration behavior against disposable databases.
- [x] Update `INSTALLATION.md` with temporary/persistent firewall behavior, required networking, recovery instructions, and the unchanged root-administrator model.
- [x] Record Pod-specific capabilities and validation results. Clearly distinguish automated checks from hardware checks that remain unperformed.
- [x] Confirm only intended files changed and that no device configuration or production data was modified during local testing.

## Review corrections (2026-10-28)

The first implementation was reviewed against this plan. These defects were fixed:

- Every caller runs the scripts with `sh`, which is bash in POSIX mode on the Pod: `add_shortcuts.sh` uses bash arrays and has always run that way. The firewall helper used process substitution, which bash before 5.1 rejects in POSIX mode, so blocking and unblocking could fail to start, after `update.sh` had already disabled the server. The scripts that need bash now re-run themselves with `/bin/bash` and no longer use process substitution.
- The `nmcli` DNS output was concatenated into one invalid address (`tr -d '[:space:]'` also removed newlines), IPv6 values kept `nmcli`'s `\:` escapes, and `resolvectl` labels were treated as addresses. Any of these aborted blocking. DNS candidates are now split, unescaped, and validated as IP addresses.
- `migrate deploy` does not generate the Prisma client, which `migrate dev` used to do. Reused `node_modules` would have kept a client for the previous schema. The installer now runs `npm run generate` after migrations. `reset_db.sh` also used `migrate dev`.
- Rollback restored the database and checkout while the new server was still running, and the later `systemctl start` was a no-op. Both scripts now stop the new code before restoring.
- A stale `free-sleep-copy.db` could replace a database created during a failed update, and a successful update deleted the database backup. Only a backup taken by the current run is restored, and the backup is kept.
- Direct reruns of the documented install command were refused. They now keep the current installation as a backup and restore it on failure.
- `setup_ssh.sh` stopped removing the default `/etc/ssh/authorized_keys`, validated before creating `/var/run/sshd`, replaced any client config containing three keywords, and wrote client options that builds without GSSAPI reject. It now matches the original behavior for keys, prepares validation prerequisites, and repairs only the recognized server-config copy.
- Blocking rebuilt its chains in place, so a failure part-way left a partial policy. It removed only one legacy `DROP`, so duplicated legacy rules kept internet access blocked during updates. There was no lock between concurrent callers, and rule-save failures were ignored. Policies are now built in staging chains and swapped in, legacy rules are removed exactly and repeatedly, changes are serialized with `flock`, and saves are checked.
- Outbound ICMPv6 was allowed to every destination. Only the error, multicast-listener, and router/neighbor discovery types are allowed outside local addresses, and on-link global IPv6 prefixes are treated as local.
- The service check used one `is-active` probe after two seconds and stopped a first installation before its sudoers, update service, and shortcuts were configured. It now watches for restarts for about 20 seconds at the end of installation. It triggers rollback when a previous installation exists, and only warns on a first installation.

## Validation record

Automated, in WSL Ubuntu 20.04 (bash 5.0, dash as `sh`), 74 tests in `scripts/tests`:

- Real packets through the real scripts in unprivileged network namespaces (`unshare -rnm`, no host firewall changes): an established internet connection stops exchanging data after blocking, new internet connections fail, and LAN, loopback, discovered DNS, and NTP keep working. Sentry follows `ALLOW_SENTRY`, and temporary unblock and restore behave as described. Duplicated legacy rules are migrated and unblock restores internet access. Owner chains and NAT rules survive, and repeated blocks produce identical rules.
- Stateful fake `iptables`/`ip6tables` covering: deterministic rules, Sentry transitions, temporary versus persistent unblock, saved boot rules, legacy migration, DNS discovery, IPv6 rules, missing `ip6tables`, injected rule and save failures, concurrent callers, and POSIX-mode bash.
- The real `install.sh` with mocked system commands: fresh install, repository and branch override, direct rerun with reused or reinstalled dependencies, migration and client-generation failures, an unstable server during an update or a first install, and a download failure.
- The real `update.sh` and `update_service.sh`: rollback of checkout and database, dependencies moved by older installers, success cleanup, refusal for low disk space, stale database copy, firewall restore failure, `SIGTERM` during installation, unblock failure, and exit status 3 keeping services stopped.
- `setup_ssh.sh` with `ssh -G`: the legacy client-config copy is rejected by `ssh` and the repaired file is accepted.
- Prisma 6.19.3 against disposable SQLite files: `migrate deploy` creates a fresh database and does nothing on reruns. It accepts databases with extra `*_deploy` records left by `migrate dev`. A partially applied migration exits 1, and later runs keep failing (P3009) until the pre-migration backup is restored.
- Syntax checks: `bash -n` and `bash --posix -n` for bash scripts, and `sh -n` (dash) for POSIX scripts.

Not yet verified on Pod hardware:

- Boot-time restore of `/etc/iptables/iptables.rules` and `ip6tables.rules` with the new chains; `iptables -w` and `iptables -E` support on the Pod's iptables build.
- Wi-Fi reconnection, DHCP renewal, and NTP while blocked; whether the Pod's kernel provides `ip6tables` (if not, IPv6 is reported as unfiltered).
- A new `ssh root@<pod> -p 8822` session after `setup_ssh.sh`, before closing the existing session.
- Free space under `/home/dac` for an update with an independent dependency copy.
