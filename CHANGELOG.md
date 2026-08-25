# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

### Changed
- **Breaking for image consumers:** `:latest` now tracks `master` (staging) instead of the newest release. The newest release is published as `:stable`, and `docker-compose.yml` has been repointed to `:stable`. Pin `:stable` or an explicit version for production.
- Pushes to `master` now publish images (`:latest` and `:master-<short sha>`); previously only tags did

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
