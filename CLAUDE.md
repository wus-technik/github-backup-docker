# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Does

A Dockerized wrapper around [python-github-backup](https://github.com/josegonzalez/python-github-backup) that runs daily backups of GitHub users and/or organizations, retaining a configurable number of backup snapshots.

This fork is owned and maintained by `wus-technik`. Keep attribution and provenance references to the upstream project, `umputun/github-backup-docker`.

## Key Commands

```bash
# Build the Docker image
docker-compose build

# Run the container (requires environment variables set)
docker-compose up -d

# Build image directly
docker build .
```

## Architecture

The project consists of four files:

- **`Dockerfile`** — Alpine (`alpine:3.23`) image that installs `github-backup==0.65.1` into a virtualenv at `/opt/venv` (Alpine's Python is externally managed) and sets `exec.sh` as the entrypoint. Update the pinned version here when upgrading.
- **`exec.sh`** — The entire application logic: sets timezone, writes the token to a temp file and passes it as `--token=file://…` / `--token-fine=file://…` depending on the token prefix (to avoid process-list exposure), loops forever (sleeping 1 day between runs), calls `github-backup` for each user/org with per-run logs and exit-code checking, optionally sends Teams/Power Automate notifications, then prunes old timestamped backups and logs.
- **`docker-compose.yml`** — Reference configuration showing all supported environment variables
- **`ci/smoke-test.sh`** — Runs the built image with a dummy token against a non-existent user and asserts the failure is a *credential* error, not an argparse error. This is the only check that exercises the real `github-backup` binary with the arguments `exec.sh` actually builds — a wrong flag is invisible to `shellcheck`, `sh -n` and `docker build`.

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `TOKEN` | required | GitHub personal access token (needs `repo` scope) |
| `GITHUB_USER` | — | Comma-separated GitHub usernames to back up |
| `GITHUB_ORG` | — | Comma-separated GitHub organizations to back up (token must have org access) |
| `MAX_BACKUPS` | `10` | Number of backup snapshots to retain |
| `TIME_ZONE` | `UTC` | Timezone string (e.g. `America/Chicago`) |
| `BACKUP_OPTIONS` | `--all --private --gists` | Flags passed directly to `github-backup` |
| `NOTIFY_WEBHOOK_URL` | — | Optional Teams/Power Automate webhook for failure and warning cards |
| `COMPRESSION` | — | Set to any non-empty value to tar/gzip each snapshot after the backup |

Backups are stored at `/srv/var/<TIMESTAMP>/<user_or_org>/` inside the container (or as `/srv/var/<TIMESTAMP>/<TIMESTAMP>_<user_or_org>.tar.gz` when `COMPRESSION` is set). Per-run logs are stored at `/srv/var/logs/`. Mount a volume at `/srv/var` to persist them.

## CI/CD

Two workflows:

- **`.github/workflows/ci.yml`** — on every push/PR: shellcheck + `sh -n` on `exec.sh` and `ci/smoke-test.sh`, compose validation, a Docker image build, and `ci/smoke-test.sh` against the built image.
- **`.github/workflows/build.yml`** — publishes multi-arch images (`linux/amd64`, `linux/arm/v7`, `linux/arm64`) to `ghcr.io/wus-technik/github-backup-docker`:

| Trigger | Image tags |
|---|---|
| push to `master` | `:latest`, `:master-<short sha>` |
| push of a semver tag `X.Y.Z` | `:X.Y.Z`, plus `:stable` if it is the highest semver tag |
| push of a non-semver tag | nothing (build skipped) |
| manual dispatch on a tag | same as pushing that tag (lets `:stable` be re-minted without re-tagging) |
| manual dispatch on a branch | `:<full commit sha>` |

Every publishing run first builds a `linux/amd64` image and gates the push on `ci/smoke-test.sh`.

`:latest` tracks `master` and is therefore a staging tag. Production deployments should pin `:stable` (as `docker-compose.yml` does) or an explicit version.
