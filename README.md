<div align="center">

# github-backup-docker

**Your GitHub, backed up daily — with retention that takes care of itself.**

A Dockerized wrapper around [python-github-backup](https://github.com/josegonzalez/python-github-backup)
that backs up GitHub users and/or organizations every day and keeps a configurable
number of backup snapshots. This fork is maintained by [wus-technik](https://github.com/wus-technik)
and keeps upstream provenance with [umputun/github-backup-docker](https://github.com/umputun/github-backup-docker).

[![Latest release](https://img.shields.io/github/v/release/wus-technik/github-backup-docker?style=for-the-badge&logo=github&color=6C4BF6)](https://github.com/wus-technik/github-backup-docker/releases/latest)
[![CI](https://img.shields.io/github/actions/workflow/status/wus-technik/github-backup-docker/ci.yml?branch=master&style=for-the-badge&label=CI)](https://github.com/wus-technik/github-backup-docker/actions/workflows/ci.yml)
[![Docker image](https://img.shields.io/badge/Docker-ghcr.io%2Fwus--technik%2Fgithub--backup--docker-2496ED?style=for-the-badge&logo=docker&logoColor=white)](https://github.com/orgs/wus-technik/packages/container/package/github-backup-docker)

[![License: MIT](https://img.shields.io/github/license/wus-technik/github-backup-docker?style=flat-square&color=blue)](LICENSE)
![Alpine](https://img.shields.io/badge/base-alpine%3A3.23-0D94FB?style=flat-square&logo=alpinelinux&logoColor=white)
![Multi-arch](https://img.shields.io/badge/multi--arch-amd64%2C_armv7%2C_arm64-0078D6?style=flat-square)
![Runs](https://img.shields.io/badge/runs-daily%2C_retention--managed-lightgrey?style=flat-square)

</div>

---

## Why

GitHub has no undo: a deleted repo, a vanished gist, or an org you lose access to
is gone. This container runs [python-github-backup](https://github.com/josegonzalez/python-github-backup)
on a daily schedule, retains `MAX_BACKUPS` timestamped snapshots, and sends a
Teams/Power Automate card when a run fails or shows soft failures — so a backup
problem is caught the same day, not after the loss.

## What you get

| | |
|---|---|
| 📦 **Daily full backups** | Repos (public + private), issues, pull requests, labels, gists and more — whatever `BACKUP_OPTIONS` selects |
| 🏷 **Many targets, one container** | Back up several users and/or organizations, comma-separated in `GITHUB_USER` / `GITHUB_ORG` |
| ⏳ **Snapshot retention** | Keeps the newest `MAX_BACKUPS` (default `10`) timestamped backups and prunes the rest, logs included |
| 🗜 **Optional compression** | Each finished snapshot can be packed into a single `.tar.gz` |
| 🔔 **Smart notifications** | Teams/Power Automate cards on non-zero exits and soft-failure markers (unavailable repos, git rc `128`, disabled PRs) — clean runs stay silent |
| 📄 **Per-run logs** | One log file per target under `/srv/var/logs/` |
| 🧱 **Multi-arch image** | Published for `linux/amd64`, `linux/arm/v7`, and `linux/arm64` |

## Install and run

1. Generate a GitHub [access token](https://github.com/settings/tokens) with `repo` scope, covering every account and organization you want to back up.
2. Grab the provided `docker-compose.yml`; adjust the `volumes` mapping and `MAX_BACKUPS` if needed.
3. Set `TIME_ZONE` (see the [list](https://en.wikipedia.org/wiki/List_of_tz_database_time_zones)).
4. Set `TOKEN` (in the environment or directly in `docker-compose.yml`).
5. Set `GITHUB_USER` (GitHub user accounts) and/or `GITHUB_ORG` (GitHub organizations — make sure the token has access to them). Multiple targets are comma-separated.
6. Run `docker-compose up -d` to start the daily backup cycle.

> [!NOTE]
> Backups land in `/srv/var/<TIMESTAMP>/<user_or_org>/` inside the container —
> mount a volume at `/srv/var` to persist them.

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `TOKEN` | required | GitHub personal access token with `repo` scope |
| `GITHUB_USER` | — | Comma-separated GitHub usernames to back up |
| `GITHUB_ORG` | — | Comma-separated GitHub organizations (token must have org access) |
| `MAX_BACKUPS` | `10` | Number of backup snapshots to retain |
| `TIME_ZONE` | `UTC` | Timezone string, e.g. `America/Chicago` |
| `BACKUP_OPTIONS` | `--all --private --gists` | Flags passed straight through to `github-backup` |
| `NOTIFY_WEBHOOK_URL` | — | Teams/Power Automate webhook for failure and warning cards |
| `COMPRESSION` | — | Packs each finished snapshot into a `.tar.gz`; `no`, `false`, `off`, `0` and an empty value turn it off |

## Monitoring and notifications

Each backup run writes an entity-specific log file under `/srv/var/logs/`.

Set `NOTIFY_WEBHOOK_URL` to a Teams/Power Automate webhook URL to get a card when:

- `github-backup` exits with a non-zero code
- the run exits successfully but its log shows soft-failure markers such as unavailable repositories, inaccessible repositories, git return code `128`, or disabled pull requests

Clean runs stay silent.

> [!WARNING]
> Do not commit webhook URLs or GitHub tokens; provide them through the live stack environment.

## Customize what gets backed up

The underlying [python-github-backup](https://github.com/josegonzalez/python-github-backup)
library [has a lot of options](https://github.com/josegonzalez/python-github-backup#usage)
for what is backed up. They are exposed one-for-one through `BACKUP_OPTIONS`.
By default the container backs up everything with `--all --private --gists` —
repositories, issues, pull requests, labels, and so on.

To back up only repository code (including private repositories), set in your
`docker-compose.yml` environment:

```yaml
environment:
  BACKUP_OPTIONS: "--private --repositories"
```

## Compression

Set `COMPRESSION` to pack each finished snapshot into
`/srv/var/<TIMESTAMP>/<TIMESTAMP>_<user_or_org>.tar.gz` and remove the uncompressed
directory. If the `tar` run fails, the directory is kept and the failure is logged.

Compression is **off** when the value is empty or one of `no`, `false`, `off`, `0`
(case-insensitive). Every other value turns it **on**, so a descriptive setting such
as `COMPRESSION=GZIP` works as expected.

## Prepared images

[GitHub Packages](https://github.com/orgs/wus-technik/packages/container/package/github-backup-docker) — `ghcr.io/wus-technik/github-backup-docker`

| Tag | Content |
|---|---|
| `stable` | the newest released version — **use this in production** |
| `X.Y.Z` | a specific release |
| `latest` | the current state of `master` (staging, may be unreleased) |
| `master-<sha>` | a specific `master` build |

<details>
<summary><b>Release semantics</b></summary>

<br>

Pushing `master` mints `:latest` and `:master-<short sha>`. Pushing a semver tag
`X.Y.Z` mints `:X.Y.Z` and, if it is the newest plain release, `:stable` — prereleases
like `X.Y.Z-rc1` get their own tag but never `:stable`. A manual dispatch on a tag
re-mints it (this is how `:stable` can be restored without re-tagging), and a manual
dispatch on a branch builds `:<full commit sha>`. Non-semver tags build nothing.
Every publishing run first builds a `linux/amd64` image and gates the push on the
CI smoke test.

</details>

## Build from the source

```bash
git clone https://github.com/wus-technik/github-backup-docker
docker-compose build
```

CI runs `shellcheck`, `sh -n`, and compose validation on every push, then builds the
image and runs `ci/smoke-test.sh` against it — the one check that exercises the real
`github-backup` binary with the exact arguments `exec.sh` builds.

## Upstream

This fork is maintained by [wus-technik](https://github.com/wus-technik) and started out
from [umputun/github-backup-docker](https://github.com/umputun/github-backup-docker).
The upstream project is not actively tracked anymore, but provenance references and
attribution are kept.

---

## License

[MIT](LICENSE) — Copyright (c) 2019 Umputun; Modifications Copyright (c) 2026 wus-technik

<div align="center">
<sub>Not affiliated with GitHub Inc. Backs up only the accounts and organizations your token can reach.</sub>
</div>