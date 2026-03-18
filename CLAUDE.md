# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Does

A Dockerized wrapper around [python-github-backup](https://github.com/josegonzalez/python-github-backup) that runs daily backups of GitHub users and/or organizations, retaining a configurable number of backup snapshots.

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

- **`Dockerfile`** — Alpine-based image that installs `github-backup` via pip and copies `exec.sh` as the entrypoint
- **`exec.sh`** — The entire application logic: sets timezone, loops forever (sleeping 1 day between runs), calls `github-backup` for each user/org, then prunes old backups using `ls | head -n -$MAX_BACKUPS | xargs rm -rf`. **Known bug:** line 31 logs `${u}` (user variable) instead of `${o}` when backing up orgs — harmless but produces misleading log output.
- **`docker-compose.yml`** — Reference configuration showing all supported environment variables

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `TOKEN` | required | GitHub personal access token (needs `repo` scope) |
| `GITHUB_USER` | — | Comma-separated GitHub usernames to back up |
| `GITHUB_ORG` | — | Comma-separated GitHub organizations to back up (token must have org access) |
| `MAX_BACKUPS` | — | Number of backup snapshots to retain |
| `TIME_ZONE` | `UTC` | Timezone string (e.g. `America/Chicago`) |
| `BACKUP_OPTIONS` | `--all --private --gists` | Flags passed directly to `github-backup` |

> **Warning:** `MAX_BACKUPS` has no fallback default. If unset, the cleanup command (`ls | head -n -`) will behave unpredictably and may delete all backups.

Backups are stored at `/srv/var/<TIMESTAMP>/<user_or_org>/` inside the container. Mount a volume at `/srv/var` to persist them.

## CI/CD

GitHub Actions (`.github/workflows/ci.yml`) builds the Docker image on every push/PR. On pushes to `master` or tags, it pushes multi-arch images (`linux/amd64`, `linux/arm/v7`, `linux/arm64`) to both `ghcr.io/umputun/github-backup-docker` and Docker Hub.
