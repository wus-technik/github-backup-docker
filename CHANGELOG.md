# Changelog

All notable changes to this project are documented in this file.

## [1.2.4] - 2026-08-26

### Added
- Configuration errors now send a notification card through `NOTIFY_WEBHOOK_URL` before the container exits. The fail-fast checks added in 1.2.3 were diagnosable but silent — `notify_teams` was only reachable from a backup run, so a mistyped `TOKEN` was only found by someone looking at the container.
- The smoke test runs a real HTTP receiver and asserts that both a configuration error and a failed run post a card; both count cards before and after so one check cannot pass on another's card. Now 15 checks.

### Changed
- **Behaviour change:** an unusable configuration exits `78` (`EX_CONFIG`) instead of `1`, so monitoring can tell "misconfigured" from "crashed" without parsing logs. The exit codes are documented in the README.
- `TIME_ZONE` is validated and applied before the other checks, so every notification carries local time. A card about an invalid `TIME_ZONE` necessarily reports UTC.

### Fixed
- **Important:** The webhook call is backgrounded and waited on, like the daily sleep. A POSIX trap only runs once the foreground command returns, so a `SIGTERM` arriving mid-notification used to sit out the stop grace and end in `SIGKILL`. Measured against an unreachable webhook under the default 10s grace: exit `137` before, exit `143` within a second after.
- An `INT`/`TERM` trap is installed before anything can block. PID 1 ignores a `SIGTERM` that has no handler, so the window before the token file exists was unprotected.
- The notification attempt is bounded — 10s for configuration errors, 60s for run notifications, where a slow endpoint should not cost a failure card.
- The token file is written with `printf` rather than `echo`.
- `ci/smoke-test.sh` no longer reports success when a container fails to complete a cycle within the timeout, which could let a check assert against a half-finished container and pass.

## [1.2.3] - 2026-08-26

### Fixed
- **Important:** `exec.sh` now fails fast on a missing `TOKEN`, an invalid `MAX_BACKUPS` or an unknown `TIME_ZONE` instead of starting a run cycle that cannot work. Note that with a `restart` policy in place an invalid value now produces a restart loop rather than an idle container.
- **Important:** The daily sleep runs in the background and is waited on, so the `INT`/`TERM` traps fire immediately instead of after the sleep finishes. A container stop used to hit the grace period and exit 137; it now exits 143 within a second.
- Log retention is grouped by run date, so keeping `MAX_BACKUPS` runs of logs matches `MAX_BACKUPS` snapshots even when several users or organizations each write a log per run.
- **Critical:** `MAX_BACKUPS` was only rejected when it was the literal `0`, so `00` and `000` passed validation. Both reach `head -n -N` in the pruning step as `0`, and `head -n -0` emits every line rather than none — the complete list of snapshots was handed to `rm -rf` after every run. The value is now checked for digits and then numerically for `< 1`.

### Changed
- The soft-failure markers are defined once and shared by the warning detection and the notification card, which previously kept two drifting copies. The shared set matches `repository not accessible` without the former `Skipping ` prefix, so it is slightly broader than before.
- README: the upstream section now states that `umputun/github-backup-docker` is no longer actively tracked, while provenance and attribution are kept.
- `COMPRESSION` is now off for an empty value and for `no`, `false`, `off` and `0` (case-insensitive), and on for anything else. Previously any non-empty value enabled compression, so `COMPRESSION=no` compressed. Existing settings such as `COMPRESSION=GZIP` are unaffected; `docker-compose.yml` now shows `COMPRESSION=no`.

### Added
- The smoke test grew from 3 to 13 checks and now covers configuration validation (missing `TOKEN`, `MAX_BACKUPS` `0`/`00`/`abc`, unknown `TIME_ZONE`), retention (`MAX_BACKUPS=2` keeps exactly the two newest snapshots), `COMPRESSION` handling, and SIGTERM during the daily sleep (exit 143 within ten seconds). Each check was confirmed to fail against a deliberately broken image. Both workflow steps carry `timeout-minutes` as a backstop.

## [1.2.2] - 2026-08-26

### Fixed
- **Critical:** Every backup run since 1.2.0 aborted immediately. `exec.sh` passed the token as `--token-file=<path>`, a flag `python-github-backup` has never had; argparse exited with code 2 before a single repository was cloned. The token file is now passed as a `file://` URI on the flag the tool actually provides (`--token` for classic PATs/OAuth tokens, `--token-fine` for `github_pat_*` tokens, selected from the token prefix).

### Added
- `ci/smoke-test.sh`: runs the built image with a dummy token and verifies that `github-backup` rejects the *credential* rather than the *arguments*. Wired into `ci.yml` after the image build and into `build.yml` as a gate before any image is pushed, so a broken invocation can no longer reach `:latest` or `:stable`.

### Changed
- `:stable` is now computed from plain `X.Y.Z` release tags only. `sort -V` ranks a prerelease such as `1.3.0-rc1` above `1.3.0`, so a prerelease tag could have claimed `:stable` and blocked the real release from re-claiming it. Prerelease tags still get their own image tag.
- README restyled: centered header with badges, feature and environment-variable tables, and the release/tag semantics. The documented default for `BACKUP_OPTIONS` now matches the code (`--all --private --gists`).

## [1.2.1] - 2026-08-25

### Changed
- **Breaking for image consumers:** `:latest` now tracks `master` (staging) instead of the newest release. The newest release is published as `:stable`, and `docker-compose.yml` has been repointed to `:stable`. Pin `:stable` or an explicit version for production.
- Pushes to `master` now publish images (`:latest` and `:master-<short sha>`); previously only tags did
- A manual `workflow_dispatch` on a semver tag now resolves the same image tags as pushing that tag

Runtime content (`Dockerfile`, `exec.sh`) is identical to 1.2.0; this release exists to publish the new tag scheme.

## [1.2.0] - 2026-08-25

### Added
- `COMPRESSION` environment variable: when set, each finished snapshot is packed into `<TIMESTAMP>_<entity>.tar.gz` and the uncompressed directory is removed (merged from the wus-technik line of development)

### Changed
- Base image updated to `alpine:3.23`; `github-backup` is now installed into a virtualenv at `/opt/venv` instead of using `pip install --break-system-packages`
- All GitHub Actions bumped to their Node.js 24 majors (`actions/checkout@v7`, `docker/setup-qemu-action@v4`, `docker/setup-buildx-action@v4`, `docker/login-action@v4`, `docker/build-push-action@v7`); Node.js 20 is deprecated on GitHub-hosted runners
- Release images are built by `.github/workflows/build.yml` on semver tags and manual dispatch (multi-arch, `:latest` for the highest semver tag) using the built-in `GITHUB_TOKEN`; `ci.yml` is now lint/build verification only and no longer publishes

### Fixed
- **Important:** `exec.sh` now writes per-run logs under `/srv/var/logs`, sends optional Teams/Power Automate failure notifications on non-zero `github-backup` exits, and sends warning notifications for known soft-failure log markers
- **Important:** `exec.sh` now exits after cleaning up the token file on `INT`/`TERM` instead of continuing the scheduler loop
- **Important:** Backup cleanup now prunes timestamped backup directories and log files separately, preserving `/srv/var/logs` from snapshot cleanup
- **Critical:** Wrong variable `${u}` in org backup log (was printing user var instead of org var `${o}`)
- **Critical:** `MAX_BACKUPS` now has a default of `10` in `exec.sh`; pruning is guarded so it only runs when backups exist and uses `xargs -r` to prevent `rm -rf` with no arguments
- **Critical:** GitHub token no longer passed as a command-line argument (visible in `ps aux`); it is written to a temp file and passed via `--token-file`, cleaned up on exit
- **Important:** Added `set -u` to `exec.sh` so unset required variables fail fast
- **Important:** Added exit-code checks on `github-backup` invocations; failures are logged instead of silently ignored
- **Important:** Pruning block moved inside the backup guard so it does not run when no entities are configured
- **Important:** Quoted all variable expansions in `exec.sh` to prevent word-splitting and glob issues
- **Important:** Updated base image from EOL `alpine:3.15` to a current Alpine release
- **Important:** Fixed `py-pip` → `py3-pip` and removed duplicate `tzdata` in `Dockerfile`
- **Important:** Pinned `github-backup` to version `0.65.1` in `Dockerfile`
- **Minor:** Removed deprecated `version: "2"` key from `docker-compose.yml`
- **Minor:** Added inline comments to `docker-compose.yml` for `GITHUB_USER` and `GITHUB_ORG` to guide first-time setup
- **Minor:** Updated GitHub Actions to current versions: `checkout@v4`, `setup-qemu-action@v3`, `setup-buildx-action@v3`
- **Minor:** Changed `Dockerfile` to use `ENTRYPOINT` instead of `CMD`

---

## 2023-04-18

### Documentation
- Added documentation for `BACKUP_OPTIONS` environment variable to README

## 2023-04-17

### Added
- `BACKUP_OPTIONS` environment variable to customize flags passed to `python-github-backup` (default: `--all --private --gists`)

## 2023-01-05

### Documentation
- Updated README

## 2022-07-28

### Added
- Support for backing up GitHub organizations via `GITHUB_ORG` environment variable
- Multiple organizations supported via comma-separated list

## 2022-03-11

### Documentation
- Added info about backing up multiple organizations and required auth scope

## 2022-03-04

### Added
- GitHub Actions CI workflow to build and push multi-arch images (`linux/amd64`, `linux/arm/v7`, `linux/arm64`) to `ghcr.io` and Docker Hub on master push and tags

### Fixed
- Updated to Python 3 and newer Alpine version

## 2019-07-31

### Fixed
- Fixed `MAX_BACKUPS` cleanup issue (#2)

## 2019-07-24

### Fixed
- Suppressed errors from `rmdir` cleanup command

## 2019-07-23

### Fixed
- Corrected sort order for backup directory listing during cleanup (oldest first)

## 2019-04-08

### Added
- Initial release
- Daily backup scheduler with configurable `TIME_ZONE` and `MAX_BACKUPS`
- Timestamped backup directories (`YYYYMMDD-HHMMSS`)
- Support for multiple GitHub users via comma-separated `GITHUB_USER`
- Organization backup support via `--organization` flag
- Gist backup support
- GitHub access token via `TOKEN` environment variable
- `.env` added to `.gitignore`
- Docker Hub automated build badge in README
