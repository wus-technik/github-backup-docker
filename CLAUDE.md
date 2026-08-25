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

The project consists of three files:

- **`Dockerfile`** — Alpine (`alpine:3.19`) image that installs `github-backup==0.65.1` via pip3 and sets `exec.sh` as the entrypoint. Update the pinned version here when upgrading.
- **`exec.sh`** — The entire application logic: sets timezone, writes the token to a temp file (to avoid process-list exposure), loops forever (sleeping 1 day between runs), calls `github-backup` for each user/org with per-run logs and exit-code checking, optionally sends Teams/Power Automate notifications, then prunes old timestamped backups and logs.
- **`docker-compose.yml`** — Reference configuration showing all supported environment variables

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

Backups are stored at `/srv/var/<TIMESTAMP>/<user_or_org>/` inside the container. Per-run logs are stored at `/srv/var/logs/`. Mount a volume at `/srv/var` to persist them.

## CI/CD

GitHub Actions (`.github/workflows/ci.yml`) builds the Docker image on every push/PR. On pushes to `master` or tags, it pushes multi-arch images (`linux/amd64`, `linux/arm/v7`, `linux/arm64`) to `ghcr.io/wus-technik/github-backup-docker`.
