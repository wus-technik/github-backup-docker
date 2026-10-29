# GitHub backup operations

## Migration

This release changes the runtime UID/GID to `10001:10001`, secret handling and
retention. Apply the following to the **deployment host**, not the source checkout:

1. Verify a recent backup and keep an independent copy. Inventory the current
   stack's volume path, token type, accounts and custom backup options.
2. Stop the old container after its current backup finishes. Existing releases do
   not support the updater's maintenance protocol, so the first upgrade is manual.
3. Restrict the existing data directory and transfer ownership to UID/GID 10001.
   For the sample `./var` bind mount, review the absolute path before running:

   ```sh
   sudo chown -R 10001:10001 ./var
   sudo chmod -R go-rwx ./var
   ```

4. Create the `secrets` directory and token file as described in README. Never put
   the token in a shell command argument, committed file, screenshot or ticket.
   Compose file secrets retain their host permissions; ensure UID 10001 can read.
5. Adapt the hardened Compose sample, pull the new release, and recreate it:

   ```sh
   docker compose pull github-backup
   docker compose up -d --no-build github-backup
   docker compose ps
   docker compose logs --tail 100 github-backup
   ```

6. Verify the first backup and perform a restore from it. Review status records and
   Docker health. With compression, test archive extraction and repository history.
7. Old snapshots have no trusted completion records and are preserved indefinitely.
   Delete them only after verification and according to your storage policy.
8. Old Git remotes/logs/notification cards may contain the previous access token.
   Inspect them without printing secrets into shared logs. After migrating,
   revoke/rotate exposed tokens and remove or restrict affected historical copies.
   New code does not rewrite old backups, archives or Teams history.

Warnings are retained as incomplete data, separately from successes. Every account
has its own retention history. Removed accounts and unknown/legacy directories
remain untouched until an operator reviews them.

## Release and GitHub setup

1. Merge the hardening branch, then create a new plain release tag (for example
   `1.3.0`) on master. Until a hardened release exists, scheduled stable rebuilds
   stop with an explicit bootstrap error instead of republishing an unsafe old
   image. Never move old tags to the new source.
2. In GitHub, restrict the `image-publish` environment to master and approved
   release tags, protect master with required PR checks/review, and restrict
   release-tag creation. Enable Dependabot alerts and updates. Environment rules
   and branch/tag protections are repository settings, not enforced by YAML.
3. Configure publication-failure monitoring: a failed weekly CVE/build/test gate
   must reach the responsible maintainer. Review Actions run status and the summary
   containing source revision, unique build tag and image-index digest.
4. Configure the deployment host separately if automatic replacement is desired.

All pinned Actions SHAs were resolved from their official release tags. Dependabot
maintains them. Python installation verifies the wheel hash, so dependency updates
must update the version **and** matching hash. CI builds/scans/tests all supported
architectures before any image from that run can be published.

Weekly builds refresh packages without changing application source for stable.
Python updates require a dependency PR and a new release. Existing release and
commit image tags remain unchanged; use a new unique build tag/digest to audit or
roll back a security rebuild. SBOM/provenance are attached to each platform image
and retained when the multi-architecture index is assembled.

GitHub's `queue: max` preserves pending publish jobs. The current actionlint schema
does not recognize this recent GitHub property; `.github/actionlint.yaml` suppresses
only that specific schema diagnostic, leaving other workflow checks enabled.

## Deployment updates

`ops/update.sh` is opt-in and requires Python 3 on a Linux Docker Compose host. Copy it next
to your deployment Compose file and run it from that directory. The script honors
`COMPOSE_FILE`, `SERVICE` (default `github-backup`) and `UPDATE_TIMEOUT` in seconds
(default `3600`). It needs the same Docker access as normal Compose administration.

```sh
./ops/update.sh
```

The updater:

1. Acquires a host update lock and requests a maintenance lease inside the service.
2. Defers with exit `75` unless every account is fresh and the latest cycle is
   successful and idle. The lease uses the same filesystem lock as the scheduler;
   a backup cannot start between the readiness check and container replacement.
3. Tags the old local image for rollback, pulls the configured image and recreates
   the service. The replacement identifies itself with a new instance ID and
   resumes backups immediately.
4. Waits for Docker health, requiring actual successful backups for every account.
   Set `UPDATE_TIMEOUT` higher than the expected full backup duration.
5. On failure, recreates the service with the saved image and exits nonzero.
   Inspect logs/health and restore data from an independent copy if necessary.
   Image rollback does not reverse data changes or recreate pruned snapshots.

Example opt-in cron entry, using the real deployment directory:

```cron
41 * * * * cd /srv/stacks/github-backup && ./ops/update.sh >> /var/log/github-backup-update.log 2>&1
```

Exit `75` means defer and try on the next schedule. Monitor other nonzero exits.
The script never installs a cron job automatically. Keep the deployment Compose
file as `docker-compose.yml`, or set `COMPOSE_FILE` explicitly; rollback appends an
image override to that same configuration. Do not run another updater/Watchtower
against this service in parallel.

The initial migration, secret rotation, host scheduler, repository protections and
first hardened release are deployment/release tasks; creating this source branch
does not change running services or publish an image.
