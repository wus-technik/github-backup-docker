#!/bin/sh
# Run from the deployment directory, optionally with COMPOSE_FILE set.
# A non-idle/unhealthy backup is deferred (exit 75), never interrupted.
set -eu
umask 077
SERVICE=${SERVICE:-github-backup}
UPDATE_TIMEOUT=${UPDATE_TIMEOUT:-3600}
case "$SERVICE" in *[!a-zA-Z0-9_-]*|'') echo 'invalid SERVICE' >&2; exit 64 ;; esac
case "$UPDATE_TIMEOUT" in *[!0-9]*|''|0) echo 'invalid UPDATE_TIMEOUT' >&2; exit 64 ;; esac
if ! [ "$UPDATE_TIMEOUT" -gt 0 ] 2>/dev/null; then echo 'invalid UPDATE_TIMEOUT' >&2; exit 64; fi
lock_dir=${UPDATE_LOCK_DIR:-/tmp/github-backup-image-update.lock}
if ! mkdir "$lock_dir" 2>/dev/null; then
    echo 'another update is running' >&2
    exit 75
fi
override_file=""
container=""
# shellcheck disable=SC2329 # Called by the EXIT trap.
cleanup() {
    if [ -n "$container" ]; then
        docker exec "$container" python3 /srv/backup.py --cancel-update >/dev/null 2>&1 || true
    fi
    if [ -n "$override_file" ]; then rm -f -- "$override_file"; fi
    rmdir "$lock_dir"
}
trap cleanup EXIT
trap 'exit 143' INT TERM

container=$(docker compose ps -q "$SERVICE")
if [ -z "$container" ] || ! docker exec "$container" python3 /srv/backup.py --prepare-update; then
    echo 'update deferred: the current cycle must be successful and idle' >&2
    exit 75
fi
old_image=$(docker inspect --format '{{.Image}}' "$container")
rollback_tag="github-backup-docker:rollback-$(printf '%s' "$old_image" | cut -c8-19)"
docker image tag "$old_image" "$rollback_tag"
docker compose pull "$SERVICE"
# A scheduled check without a new image must not restart the service or trigger
# another full backup. Resolve the configured service image through Compose.
new_image=$(docker compose config --format json | python3 -c 'import json,sys; print(json.load(sys.stdin)["services"][sys.argv[1]]["image"])' "$SERVICE")
new_id=$(docker image inspect --format '{{.Id}}' "$new_image")
if [ "$old_image" = "$new_id" ]; then
    echo 'configured image is already current'
    exit 0
fi
# The maintenance request is held until replacement; a daily cycle cannot start
# between the readiness check and recreation. The replacement resumes itself.
if docker compose up -d --no-build --pull never --wait --wait-timeout "$UPDATE_TIMEOUT" "$SERVICE"; then
    echo 'update succeeded; the new container completed a successful backup'
    exit 0
fi
echo 'new container failed its health check; restoring previous image' >&2
override_file=$(mktemp)
printf 'services:\n  %s:\n    image: %s\n' "$SERVICE" "$rollback_tag" > "$override_file"
# COMPOSE_FILE remains honored; append only the rollback image override.
compose_files=${COMPOSE_FILE:-docker-compose.yml}
COMPOSE_FILE="${compose_files}:${override_file}" docker compose up -d --no-build --pull never "$SERVICE"
exit 1
