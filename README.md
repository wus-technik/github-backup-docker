<div align="center">

# github-backup-docker

**Your GitHub, backed up daily — with successful snapshots kept safe.**

A Docker wrapper around [python-github-backup](https://github.com/josegonzalez/python-github-backup),
maintained by [wus-technik](https://github.com/wus-technik), based on
[umputun/github-backup-docker](https://github.com/umputun/github-backup-docker).

[![CI](https://img.shields.io/github/actions/workflow/status/wus-technik/github-backup-docker/ci.yml?branch=master)](https://github.com/wus-technik/github-backup-docker/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

</div>

Daily backups of multiple GitHub users/organizations, per-account retention,
optional compression, and optional Teams/Power Automate failure notifications.
Images support `linux/amd64`, `linux/arm64`, and `linux/arm/v7`.

## Install

1. Create a GitHub token covering the accounts and data to back up. Prefer a
   fine-grained token with the read permissions required by your selected options;
   test the resulting backup coverage. Classic PATs with `repo` scope also work,
   but have broader permissions. Gists may require a separate classic-token setup.
2. Copy `docker-compose.yml`. Configure `GITHUB_USER` and/or `GITHUB_ORG`.
3. Prepare the data directory and secret **on the Linux Docker host**:

   ```sh
   sudo install -d -o 10001 -g 10001 -m 0700 var secrets
   sudo install -o 10001 -g 10001 -m 0400 /secure/path/github-token secrets/github_token
   ```

4. Start with `docker compose up -d` and verify a successful first cycle and healthy
   container. Secret files must be readable by UID 10001; Compose file secrets are
   bind mounts, so set the host-file permissions explicitly.

The container runs as UID/GID `10001:10001`; the root filesystem is read-only, and
only `/srv/var` and a bounded `/tmp` tmpfs are writable. It drops Linux capabilities
and uses `no-new-privileges`. New files are private (`umask 077`). Timezone selection
uses `TZ` and does not modify `/etc`.

**Upgrading an existing deployment:** read [the migration instructions](docs/operations.md#migration)
before recreating it. Existing data-directory ownership must be adjusted, and old
backups may contain embedded access tokens.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `TOKEN_FILE` | — | Preferred: path to a token file, e.g. `/run/secrets/github_token` |
| `TOKEN` | — | Compatibility alternative; never set together with `TOKEN_FILE` |
| `GITHUB_USER` | — | Comma-separated GitHub usernames |
| `GITHUB_ORG` | — | Comma-separated GitHub organizations |
| `MAX_BACKUPS` | `10` | Successful snapshots retained **per account** |
| `MAX_FAILED_BACKUPS` | `3` | Failed, incomplete or warning snapshots retained separately per account |
| `TIME_ZONE` | `UTC` | IANA timezone, e.g. `Europe/Berlin` |
| `BACKUP_OPTIONS` | `--all --private --gists` | Upstream backup options; shell-style quoting supported |
| `NOTIFY_WEBHOOK_URL_FILE` | — | Preferred: path to a Teams/Power Automate webhook secret |
| `NOTIFY_WEBHOOK_URL` | — | Compatibility alternative to the webhook file |
| `COMPRESSION` | off | Empty, `no`, `false`, `off`, `0` disable compression, case-insensitively |
| `VAR_DIR` | `/srv/var` | Data and status directory |

At least one account is required. Duplicate or invalid account names are rejected.
Authentication, account type and output-directory flags cannot be overridden using
`BACKUP_OPTIONS`; these are managed by the supervisor. Other flags follow the
[upstream CLI](https://github.com/josegonzalez/python-github-backup#usage).
For example, `BACKUP_OPTIONS="--private --repositories"` selects repository code.
`--all` means upstream's selection; it does not include every optional feature
(for example LFS, forks or attachments). Verify the coverage you need.

## Storage and retention

- Data: `/srv/var/<timestamp>/<account>/`.
- Successful compressed data: `/srv/var/<timestamp>/<timestamp>_<account>.tar.gz`.
- Sanitized logs: `/srv/var/logs/<timestamp>_<type>_<account>.log`.
- Completion records: `<timestamp>/.status/<type>_<account>.json`.
- Health/update coordination: `health.json`, `.cycle.lock`, `.update-request`.

A run is marked incomplete before it starts. Only a zero exit without detected
partial failures, and successful compression if requested, is marked successful.
Warnings and failures cannot displace successful backups. Retention prunes each
account's own data and logs, preserving other accounts sharing the timestamp.
Failed snapshots have a separate limit, so outages do not grow them indefinitely.

**Legacy directories without completion records are preserved**, because their
success cannot be inferred from their names. Review and remove them manually after
verifying a replacement backup. Never create successful completion records for
unverified old data. Accounts removed from configuration are also preserved.

Compression writes a temporary archive, renames it on success, and only then
removes the original directory. Failed or interrupted compression preserves the
uncompressed backup and is not considered a successful snapshot.

## Security and monitoring

The API receives a token-file path. Git receives credential-free HTTPS URLs and
uses a read-only helper restricted to the configured GitHub host. The helper's
token is neither stored in remote configuration nor passed in process arguments.
Token/webhook values and common credential representations are redacted before
logs are persisted or sent. Avoid including other secrets in repository data or
custom options; redaction is not an alternative to access controls or encryption.

Optional notifications cover configuration errors, failed backups, partial backup
warnings, and compression errors. Webhook requests have a bounded overall timeout.
Clean cycles stay silent. A failed webhook is reported without exposing its URL.

The Docker health check requires a successful snapshot for every configured
account within the last 48 hours. A running container alone does not prove backup
success. Docker health status itself does not trigger a restart.

| Exit code | Meaning |
|---|---|
| `78` | Invalid configuration; notification attempted before exit |
| `143` | Clean shutdown requested by SIGTERM/SIGINT |
| `1` | Unexpected supervisor or persistent storage failure |

SIGTERM reaches the current process group, including Git/tar grandchildren; after
a five-second grace period remaining children are killed. Interrupted snapshots
retain failure status. Temporary credentials are removed during shutdown.

Backups are not encrypted by this application. Restrict host access, encrypt the
backup storage, and maintain an independent/off-host copy and periodic restore test.

## Images and automatic updates

| Tag | Meaning |
|---|---|
| `stable` | Newest plain release, including tested OS-security rebuilds |
| `X.Y.Z` | First published build of that release; not overwritten by rebuilds |
| `X.Y.Z-rc1` | First published prerelease build; never promoted to `stable` |
| `latest` | Current `master`, potentially unreleased |
| `master-<sha>` | First published build of that master commit |
| `<full commit sha>` | First published manual preview build of that commit |
| `build-<run>-<attempt>-<channel>` | Exact multi-architecture build, also on security rebuilds |

Use `stable` for production with the controlled updater, or pin an image digest
when you require immutable contents. A Git commit or version alone does not
identify new OS packages; every rebuild has a unique build tag and digest.

The publishing workflow runs on master pushes, release tags, PRs, manual dispatch
and weekly on Monday. PRs only build/test. Scheduled/manual-master runs build
master/latest and the newest supported release/stable **from separate immutable
source SHAs**. Release tags must be on master; non-version tags are skipped.
Docker tags do not support SemVer `+build` metadata, so those tags are skipped too.

The first hardened release bootstraps stable-security rebuilds. Releases must
contain `.security-rebuild-version` with value `1`. An older release is deliberately
not promoted by a scheduled build; the workflow reports the required release.

Each architecture is built once into an OCI archive with SBOM/provenance, scanned
for HIGH/CRITICAL vulnerabilities, and smoke/security/restore-tested. Publication
uploads these same archives with their original manifests and attestations. Only
the publish job can write to GHCR. Channel promotion is serialized and checks
current Git refs plus build sequence to prevent stale jobs from rolling back tags.

Dependabot proposes weekly updates for Actions, Alpine and the hash-pinned Python
dependency. OS packages are refreshed on every publishing build (`pull`, fresh
package installation and upgrade); runtime installers are removed. A scan failure
blocks publication, including when no upstream fix is available.

**Publishing a fresh image does not update a running container.**
The opt-in [deployment updater](ops/update.sh) holds a maintenance lease after a
successful idle cycle, pulls/recreates the service, verifies a successful first
backup through Docker health, and rolls back on failure. See
[deployment automation and rollback](docs/operations.md#deployment-updates).

## Development

```sh
docker build --pull -t github-backup-docker:test .
./ci/smoke-test.sh github-backup-docker:test
python3 -m unittest discover -v -s ci -p test_pipeline.py
```

`exec.sh` applies the private umask and launches `backup.py`. The supervisor uses
Python's standard library; `secure_github_backup.py` adapts upstream's Git URLs,
and `git_credential.py` implements Git's credential protocol. Upstream behavior is
otherwise retained. Security tests exercise the installed wheel and real Git.

## Upstream and license

This fork is maintained by wus-technik and originated from
[umputun/github-backup-docker](https://github.com/umputun/github-backup-docker).
That wrapper is no longer actively tracked; its attribution and provenance remain.
[python-github-backup](https://github.com/josegonzalez/python-github-backup) supplies
the GitHub backup implementation and is kept pinned and tested here.

[MIT](LICENSE) — Copyright (c) 2019 Umputun; Modifications Copyright (c) 2026 wus-technik.
Not affiliated with GitHub Inc.
