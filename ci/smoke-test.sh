#!/bin/sh
# Smoke test against the real github-backup binary and the real exec.sh in the
# built image.
#
# A stubbed binary cannot tell a wrong flag from a wrong credential, and
# shellcheck cannot tell a wrong flag at all -- that is how 1.2.1 shipped with
# --token-file, a flag python-github-backup never had. Everything here runs the
# actual image and asserts on observable behaviour.
set -eu

IMAGE=${1:-github-backup-docker:test}
FAILURES=0
CONTAINER=""

cleanup() {
    if [ -n "${CONTAINER}" ]; then
        docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT INT TERM

fail() {
    echo "FAIL: $*"
    FAILURES=$((FAILURES + 1))
}

pass() {
    echo "OK: $*"
}

# Start the image detached and wait until the scheduler has finished a cycle and
# gone to sleep. Polling beats "docker logs -f", which would block until the
# container's day-long sleep is over instead of returning at the marker line.
start_and_wait_for_cycle() {
    CONTAINER="github-backup-smoke-$$"
    docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
    # shellcheck disable=SC2086
    docker run -d --name "${CONTAINER}" $1 "${IMAGE}" >/dev/null

    waited=0
    while [ "${waited}" -lt 120 ]; do
        if docker logs "${CONTAINER}" 2>&1 | grep -q 'sleep for 1 day'; then
            return 0
        fi
        if [ -z "$(docker ps -q --filter "name=^${CONTAINER}\$")" ]; then
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done
    return 0
}

# ---------------------------------------------------------------------------
# 1. The binary itself is callable
# ---------------------------------------------------------------------------

echo "== github-backup binary =="
if docker run --rm --entrypoint github-backup "${IMAGE}" --help >/dev/null 2>&1; then
    pass "github-backup binary is callable"
else
    fail "github-backup binary is not callable"
fi

# ---------------------------------------------------------------------------
# 2. exec.sh builds arguments github-backup accepts
#
#    A credential error means the arguments were accepted and only the token was
#    rejected (pass). An argparse error means exec.sh built a wrong invocation
#    (fail) -- this is the 1.2.1 regression.
# ---------------------------------------------------------------------------

check_backup_args() {
    label=$1
    token=$2

    echo "== arguments: ${label} =="
    start_and_wait_for_cycle "-e TOKEN=${token} \
        -e GITHUB_USER=wus-technik-smoke-test-does-not-exist \
        -e BACKUP_OPTIONS=--repositories"
    output=$(docker logs "${CONTAINER}" 2>&1)
    docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
    CONTAINER=""

    if echo "${output}" | grep -qE 'unrecognized arguments|github-backup: error:'; then
        fail "${label}: github-backup rejected the arguments built by exec.sh"
        echo "${output}" | grep -E 'unrecognized arguments|github-backup: error:'
    elif ! echo "${output}" | grep -qE 'Bad credentials|401|403|404|Not Found'; then
        fail "${label}: expected an authentication or API error, got none"
        echo "${output}"
    else
        pass "${label}"
    fi
}

check_backup_args "classic token (--token)" "ghp_smoketestsmoketestsmoketestsmoke"
check_backup_args "fine-grained token (--token-fine)" "github_pat_smoketestsmoketestsmoketest"

# ---------------------------------------------------------------------------
# 3. Invalid configuration is rejected before the first run
# ---------------------------------------------------------------------------

check_config_rejected() {
    label=$1
    expected=$2
    shift 2

    echo "== config: ${label} =="
    CONTAINER="github-backup-smoke-$$"
    docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
    docker run -d --name "${CONTAINER}" "$@" "${IMAGE}" >/dev/null

    # Detached with a bounded wait on purpose: a value that is wrongly accepted
    # starts the scheduler, and a foreground "docker run" would then block until
    # the container's day-long sleep is over.
    waited=0
    while [ "${waited}" -lt 30 ]; do
        if [ -z "$(docker ps -q --filter "name=^${CONTAINER}\$")" ]; then
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done

    still_running=$(docker ps -q --filter "name=^${CONTAINER}\$")
    rc=$(docker inspect -f '{{.State.ExitCode}}' "${CONTAINER}")
    output=$(docker logs "${CONTAINER}" 2>&1)
    docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
    CONTAINER=""

    if [ -n "${still_running}" ]; then
        fail "${label}: still running after ${waited}s, the invalid value was accepted"
    elif [ "${rc}" -eq 0 ]; then
        fail "${label}: expected a non-zero exit, got 0"
    elif ! echo "${output}" | grep -q "${expected}"; then
        fail "${label}: expected message '${expected}', got:"
        echo "${output}" | head -5
    else
        pass "${label} (exit ${rc})"
    fi
}

check_config_rejected "TOKEN missing" \
    "ERROR: TOKEN is not set" \
    -e GITHUB_USER=nobody
check_config_rejected "MAX_BACKUPS=0" \
    "ERROR: MAX_BACKUPS" \
    -e TOKEN=ghp_x -e MAX_BACKUPS=0
check_config_rejected "MAX_BACKUPS=00" \
    "ERROR: MAX_BACKUPS" \
    -e TOKEN=ghp_x -e MAX_BACKUPS=00
check_config_rejected "MAX_BACKUPS=abc" \
    "ERROR: MAX_BACKUPS" \
    -e TOKEN=ghp_x -e MAX_BACKUPS=abc
check_config_rejected "TIME_ZONE unknown" \
    "ERROR: unknown TIME_ZONE" \
    -e TOKEN=ghp_x -e TIME_ZONE=Mars/Olympus

# ---------------------------------------------------------------------------
# 4. Retention keeps exactly MAX_BACKUPS snapshots
#
#    cleanup_old_backups feeds "head -n -MAX_BACKUPS" into "rm -rf", so an
#    off-by-one or a MAX_BACKUPS value that reaches head as 0 deletes every
#    snapshot instead of none.
# ---------------------------------------------------------------------------

echo "== retention: MAX_BACKUPS=2 keeps the 2 newest snapshots =="
start_and_wait_for_cycle "-e TOKEN=ghp_x -e MAX_BACKUPS=2     -e GITHUB_USER=wus-technik-smoke-test-does-not-exist     -e BACKUP_OPTIONS=--repositories"

# Seeded with far-future run dates so they sort newest regardless of how many
# snapshots the container's own cycles create in the meantime.
docker exec "${CONTAINER}" sh -c     'mkdir -p /srv/var/20990101-000000 /srv/var/20990102-000000 /srv/var/20990103-000000' >/dev/null

docker restart -t 5 "${CONTAINER}" >/dev/null
waited=0
while [ "${waited}" -lt 120 ]; do
    if [ "$(docker logs "${CONTAINER}" 2>&1 | grep -c 'sleep for 1 day')" -ge 2 ]; then
        break
    fi
    sleep 2
    waited=$((waited + 2))
done

remaining=$(docker exec "${CONTAINER}" sh -c 'ls -1 /srv/var | grep "^20" | sort | tr "
" " "')
docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
CONTAINER=""

if [ "${remaining}" = "20990102-000000 20990103-000000 " ]; then
    pass "retention kept exactly the 2 newest snapshots"
else
    fail "retention kept the wrong snapshots: [${remaining}]"
    echo "     expected: [20990102-000000 20990103-000000 ]"
fi

# ---------------------------------------------------------------------------
# 5. SIGTERM during the daily sleep terminates promptly
# ---------------------------------------------------------------------------

echo "== signals: SIGTERM during sleep =="
start_and_wait_for_cycle "-e TOKEN=ghp_x \
    -e GITHUB_USER=wus-technik-smoke-test-does-not-exist \
    -e BACKUP_OPTIONS=--repositories"
started=$(date +%s)
docker stop -t 30 "${CONTAINER}" >/dev/null
elapsed=$(( $(date +%s) - started ))
rc=$(docker inspect -f '{{.State.ExitCode}}' "${CONTAINER}")
docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
CONTAINER=""

if [ "${rc}" != "143" ]; then
    fail "SIGTERM: expected exit code 143, got ${rc}"
elif [ "${elapsed}" -gt 10 ]; then
    fail "SIGTERM: took ${elapsed}s, the trap did not fire during the sleep"
else
    pass "SIGTERM handled in ${elapsed}s (exit 143)"
fi

# ---------------------------------------------------------------------------

echo
if [ "${FAILURES}" -eq 0 ]; then
    echo "smoke test passed"
else
    echo "smoke test FAILED (${FAILURES} check(s))"
    exit 1
fi
