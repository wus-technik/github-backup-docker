#!/bin/sh
# Smoke test against the real github-backup binary in the built image.
#
# A stubbed binary cannot tell a wrong flag from a wrong credential, so this
# runs the actual entrypoint with a dummy token and inspects the failure mode:
#   "unrecognized arguments" / "github-backup: error:" -> the arguments exec.sh
#   builds are wrong (fail). An authentication or API error -> the arguments
#   were accepted and only the credential was rejected (pass).
set -eu

IMAGE=${1:-github-backup-docker:test}
CONTAINER=""

cleanup() {
    if [ -n "${CONTAINER}" ]; then
        docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT INT TERM

echo "== github-backup --help =="
docker run --rm --entrypoint github-backup "${IMAGE}" --help >/dev/null
echo "OK: github-backup binary is callable"

run_case() {
    label=$1
    token=$2

    echo "== ${label} =="
    CONTAINER="github-backup-smoke-$$"
    docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
    docker run -d --name "${CONTAINER}" \
        -e TOKEN="${token}" \
        -e GITHUB_USER=wus-technik-smoke-test-does-not-exist \
        -e BACKUP_OPTIONS=--repositories \
        "${IMAGE}" >/dev/null

    # Wait until the scheduler goes to sleep, i.e. the run is over. Polling
    # beats "docker logs -f", which would block until the container's 1-day
    # sleep is over instead of returning at the marker line.
    waited=0
    while [ "${waited}" -lt 120 ]; do
        output=$(docker logs "${CONTAINER}" 2>&1)
        if echo "${output}" | grep -q 'sleep for 1 day'; then
            break
        fi
        if [ -z "$(docker ps -q --filter "name=^${CONTAINER}\$")" ]; then
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done

    output=$(docker logs "${CONTAINER}" 2>&1)
    docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
    CONTAINER=""

    echo "${output}"

    if echo "${output}" | grep -qE 'unrecognized arguments|github-backup: error:'; then
        echo "FAIL: github-backup rejected the arguments built by exec.sh"
        return 1
    fi

    if ! echo "${output}" | grep -qE 'Bad credentials|401|403|404|Not Found'; then
        echo "FAIL: expected an authentication or API error, got none"
        return 1
    fi

    echo "OK: ${label}"
}

run_case "classic token (--token)" "ghp_smoketestsmoketestsmoketestsmoke"
run_case "fine-grained token (--token-fine)" "github_pat_smoketestsmoketestsmoketest"

echo "smoke test passed"
