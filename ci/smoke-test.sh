#!/bin/sh
# Smoke test against the real github-backup binary and the real exec.sh in the
# built image.
#
# A stubbed binary cannot tell a wrong flag from a wrong credential, and static
# linting cannot tell a wrong flag at all -- that is how 1.2.1 shipped with
# --token-file, a flag python-github-backup never had. Everything here runs the
# actual image and asserts on observable behaviour.
set -eu

IMAGE=${1:-github-backup-docker:test}
FAILURES=0
CONTAINER=""
HOOK_CONTAINER=""
NETWORK=""

cleanup() {
    for c in "${CONTAINER}" "${HOOK_CONTAINER}"; do
        if [ -n "${c}" ]; then
            docker rm -f "${c}" >/dev/null 2>&1 || true
        fi
    done
    if [ -n "${NETWORK}" ]; then
        docker network rm "${NETWORK}" >/dev/null 2>&1 || true
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

# Tear down the container the current check was working with.
drop_container() {
    docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
    CONTAINER=""
}

# Start the image detached and wait until the scheduler has finished a cycle and
# gone to sleep. Polling beats "docker logs -f", which would block until the
# container's day-long sleep is over instead of returning at the marker line.
#
# Returns non-zero if the cycle never completed. Reporting success on timeout
# would let a caller assert against a half-finished container and call it a
# pass, which is precisely the kind of blind spot this test exists to remove.
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

    fail "container did not complete a cycle within ${waited}s"
    docker logs "${CONTAINER}" 2>&1 | tail -20
    return 1
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
    if ! start_and_wait_for_cycle "-e TOKEN=${token} -e BACKUP_OPTIONS=--repositories -e GITHUB_USER=wus-technik-smoke-test-does-not-exist"; then
        drop_container
        return 1
    fi

    output=$(docker logs "${CONTAINER}" 2>&1)
    drop_container

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
# 3. Invalid configuration is rejected before the first run, with exit 78
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
    drop_container

    if [ -n "${still_running}" ]; then
        fail "${label}: still running after ${waited}s, the invalid value was accepted"
    elif [ "${rc}" -ne 78 ]; then
        fail "${label}: expected exit code 78 (EX_CONFIG), got ${rc}"
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

check_retention() {
    echo "== retention: MAX_BACKUPS=2 keeps the 2 newest snapshots =="
    if ! start_and_wait_for_cycle "-e TOKEN=ghp_x -e MAX_BACKUPS=2 -e BACKUP_OPTIONS=--repositories -e GITHUB_USER=wus-technik-smoke-test-does-not-exist"; then
        drop_container
        return 1
    fi

    # Seeded with far-future run dates so they sort newest regardless of how
    # many snapshots the container's own cycles create in the meantime.
    docker exec "${CONTAINER}" sh -c 'mkdir -p /srv/var/20990101-000000 /srv/var/20990102-000000 /srv/var/20990103-000000' >/dev/null

    docker restart -t 5 "${CONTAINER}" >/dev/null
    waited=0
    while [ "${waited}" -lt 120 ]; do
        if [ "$(docker logs "${CONTAINER}" 2>&1 | grep -c 'sleep for 1 day')" -ge 2 ]; then
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done

    if [ "${waited}" -ge 120 ]; then
        fail "retention: second cycle did not complete within ${waited}s"
        drop_container
        return 1
    fi

    remaining=$(docker exec "${CONTAINER}" sh -c 'ls -1 /srv/var | grep "^20" | sort | paste -sd" " -')
    drop_container

    if [ "${remaining}" = "20990102-000000 20990103-000000" ]; then
        pass "retention kept exactly the 2 newest snapshots"
    else
        fail "retention kept the wrong snapshots: [${remaining}]"
        echo "     expected: [20990102-000000 20990103-000000]"
    fi
}

check_retention

# ---------------------------------------------------------------------------
# 5. COMPRESSION decides whether a snapshot is packed
#
#    Any value that is not a negative spelling enables compression, so a
#    descriptive setting like GZIP keeps working while "no" turns it off.
#    The archive is written even when the backup itself failed, as long as
#    github-backup created the output directory -- which is what makes this
#    checkable with a dummy token.
# ---------------------------------------------------------------------------

check_compression() {
    label=$1
    value=$2
    expected=$3

    echo "== compression: ${label} =="
    if ! start_and_wait_for_cycle "-e TOKEN=ghp_x -e COMPRESSION=${value} -e BACKUP_OPTIONS=--repositories -e GITHUB_USER=wus-technik-smoke-test-does-not-exist"; then
        drop_container
        return 1
    fi

    mode=$(docker logs "${CONTAINER}" 2>&1 | grep -m1 '^compression=' || true)
    archives=$(docker exec "${CONTAINER}" sh -c 'ls -1 /srv/var/*/*.tar.gz 2>/dev/null | wc -l')
    drop_container

    if [ "${mode}" != "compression=${expected}" ]; then
        fail "${label}: reported '${mode}', expected 'compression=${expected}'"
    elif [ "${expected}" = "enabled" ] && [ "${archives}" -eq 0 ]; then
        fail "${label}: reported enabled but wrote no archive"
    elif [ "${expected}" = "disabled" ] && [ "${archives}" -ne 0 ]; then
        fail "${label}: reported disabled but wrote ${archives} archive(s)"
    else
        pass "${label} (${mode}, ${archives} archive(s))"
    fi
}

check_compression "COMPRESSION=GZIP packs" GZIP enabled
check_compression "COMPRESSION=no does not pack" no disabled
check_compression "COMPRESSION=OFF does not pack" OFF disabled

# ---------------------------------------------------------------------------
# 6. Failures reach the webhook
#
#    Run failures and configuration errors go through the same notification
#    path, but a configuration error has no log file to quote, so its card is
#    built differently and is worth checking on its own.
#
#    Both checks count cards instead of grepping the whole receiver log: a
#    later check must not pass on a card an earlier one produced.
# ---------------------------------------------------------------------------

WEBHOOK_SERVER_PY=$(cat <<'PYSRV'
import http.server
class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8", "replace")
        print("WEBHOOK-RECEIVED " + body.replace(chr(10), " "), flush=True)
        self.send_response(200)
        self.end_headers()
    def log_message(self, *args):
        pass
server = http.server.HTTPServer(("", 8080), Handler)
print("WEBHOOK-READY", flush=True)
server.serve_forever()
PYSRV
)

start_webhook_receiver() {
    NETWORK="github-backup-smoke-net-$$"
    docker network rm "${NETWORK}" >/dev/null 2>&1 || true
    docker network create "${NETWORK}" >/dev/null

    HOOK_CONTAINER="github-backup-smoke-hook-$$"
    docker rm -f "${HOOK_CONTAINER}" >/dev/null 2>&1 || true
    docker run -d --name "${HOOK_CONTAINER}" --network "${NETWORK}" -e "SRV=${WEBHOOK_SERVER_PY}" --entrypoint python3 "${IMAGE}" -c 'import os; exec(os.environ["SRV"])' >/dev/null

    waited=0
    while [ "${waited}" -lt 30 ]; do
        if docker logs "${HOOK_CONTAINER}" 2>&1 | grep -q 'WEBHOOK-READY'; then
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    fail "webhook receiver did not come up"
    return 1
}

stop_webhook_receiver() {
    docker rm -f "${HOOK_CONTAINER}" >/dev/null 2>&1 || true
    HOOK_CONTAINER=""
    docker network rm "${NETWORK}" >/dev/null 2>&1 || true
    NETWORK=""
}

cards_matching() {
    docker logs "${HOOK_CONTAINER}" 2>&1 | grep -c "$1" || true
}

check_config_notification() {
    hook_url=$1

    echo "== notifications: configuration error =="
    before=$(cards_matching 'GitHub backup configuration error')

    CONTAINER="github-backup-smoke-$$"
    docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
    rc=0
    docker run --rm --name "${CONTAINER}" --network "${NETWORK}" -e "NOTIFY_WEBHOOK_URL=${hook_url}" -e TOKEN=ghp_x -e MAX_BACKUPS=00 "${IMAGE}" >/dev/null 2>&1 || rc=$?
    CONTAINER=""

    after=$(cards_matching 'GitHub backup configuration error')
    named=$(cards_matching 'MAX_BACKUPS must be a positive integer')

    if [ "${rc}" -ne 78 ]; then
        fail "configuration error: expected exit code 78, got ${rc}"
    elif [ "${after}" -le "${before}" ]; then
        fail "configuration error did not reach the webhook"
    elif [ "${named}" -eq 0 ]; then
        fail "configuration card does not name the problem"
    else
        pass "configuration error posts a card and exits ${rc}"
    fi
}

check_failure_notification() {
    hook_url=$1

    echo "== notifications: failed run =="
    before=$(cards_matching 'GitHub backup failure')

    if ! start_and_wait_for_cycle "--network ${NETWORK} -e NOTIFY_WEBHOOK_URL=${hook_url} -e TOKEN=ghp_x -e BACKUP_OPTIONS=--repositories -e GITHUB_USER=wus-technik-smoke-test-does-not-exist"; then
        drop_container
        return 1
    fi
    drop_container

    after=$(cards_matching 'GitHub backup failure')

    if [ "${after}" -le "${before}" ]; then
        fail "failed run did not reach the webhook"
    else
        pass "failed run posts a card"
    fi
}

if start_webhook_receiver; then
    url="http://${HOOK_CONTAINER}:8080/hook"
    check_config_notification "${url}"
    check_failure_notification "${url}"
    stop_webhook_receiver
fi

# ---------------------------------------------------------------------------
# 7. SIGTERM during the daily sleep terminates promptly
# ---------------------------------------------------------------------------

check_sigterm() {
    echo "== signals: SIGTERM during sleep =="
    if ! start_and_wait_for_cycle "-e TOKEN=ghp_x -e BACKUP_OPTIONS=--repositories -e GITHUB_USER=wus-technik-smoke-test-does-not-exist"; then
        drop_container
        return 1
    fi

    started=$(date +%s)
    docker stop -t 30 "${CONTAINER}" >/dev/null
    elapsed=$(( $(date +%s) - started ))
    rc=$(docker inspect -f '{{.State.ExitCode}}' "${CONTAINER}")
    drop_container

    if [ "${rc}" != "143" ]; then
        fail "SIGTERM: expected exit code 143, got ${rc}"
    elif [ "${elapsed}" -gt 10 ]; then
        fail "SIGTERM: took ${elapsed}s, the trap did not fire during the sleep"
    else
        pass "SIGTERM handled in ${elapsed}s (exit 143)"
    fi
}

check_sigterm

# ---------------------------------------------------------------------------

echo
if [ "${FAILURES}" -eq 0 ]; then
    echo "smoke test passed"
else
    echo "smoke test FAILED (${FAILURES} check(s))"
    exit 1
fi
