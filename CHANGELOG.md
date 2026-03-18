# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

### Fixed
- **Critical:** Wrong variable `${u}` in org backup log (was printing user var instead of org var `${o}`)
- **Critical:** `MAX_BACKUPS` now has a default of `10` in `exec.sh`; pruning is guarded so it only runs when backups exist and uses `xargs -r` to prevent `rm -rf` with no arguments
- **Critical:** GitHub token no longer passed as a command-line argument (visible in `ps aux`); it is written to a temp file and passed via `--token-file`, cleaned up on exit
- **Important:** Added `set -u` to `exec.sh` so unset required variables fail fast
- **Important:** Added exit-code checks on `github-backup` invocations; failures are logged instead of silently ignored
- **Important:** Pruning block moved inside the backup guard so it does not run when no entities are configured
- **Important:** Quoted all variable expansions in `exec.sh` to prevent word-splitting and glob issues
- **Important:** Updated base image from EOL `alpine:3.15` to `alpine:3.19`
- **Important:** Fixed `py-pip` → `py3-pip` and removed duplicate `tzdata` in `Dockerfile`
- **Important:** Pinned `github-backup` to version `0.102.0` in `Dockerfile`
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
