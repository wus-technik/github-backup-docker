#!/bin/sh
set -u

VAR_DIR=${VAR_DIR:=/srv/var}
LOG_DIR="${VAR_DIR}/logs"

TIME_ZONE=${TIME_ZONE:=UTC}
echo "timezone=${TIME_ZONE}"

BACKUP_OPTIONS=${BACKUP_OPTIONS:='--all --private --gists'}
echo "backup options=${BACKUP_OPTIONS}"

MAX_BACKUPS=${MAX_BACKUPS:=10}
echo "max backups=${MAX_BACKUPS}"

COMPRESSION=${COMPRESSION:-}
if [ -n "${COMPRESSION}" ]; then
    echo "compression=enabled"
else
    echo "compression=disabled"
fi

NOTIFY_WEBHOOK_URL=${NOTIFY_WEBHOOK_URL:-}
if [ -n "${NOTIFY_WEBHOOK_URL}" ]; then
    echo "notifications=enabled"
else
    echo "notifications=disabled"
fi

# Fail fast on invalid configuration instead of burning a run cycle on it
if [ -z "${TOKEN:-}" ]; then
    echo "ERROR: TOKEN is not set" >&2
    exit 1
fi

case "${MAX_BACKUPS}" in
    0 | *[!0-9]*)
        echo "ERROR: MAX_BACKUPS must be a positive integer (got '${MAX_BACKUPS}')" >&2
        exit 1
        ;;
esac

if [ ! -f "/usr/share/zoneinfo/${TIME_ZONE}" ]; then
    echo "ERROR: unknown TIME_ZONE '${TIME_ZONE}'" >&2
    exit 1
fi

# Substrings marking a soft failure: successful exit, but some repositories
# were skipped. Shared by has_soft_failures (warning detection) and the
# notification card (matched lines).
SOFT_FAILURE_MARKERS='is unavailable|repository not accessible|returned 128|Pull requests are disabled'

cp /usr/share/zoneinfo/"${TIME_ZONE}" /etc/localtime
echo "${TIME_ZONE}" >/etc/timezone

# Write token to a temp file to avoid exposing it in the process list.
# github-backup reads the first line when the value is a file:// URI.
TOKEN_FILE=$(mktemp)
echo "${TOKEN}" > "${TOKEN_FILE}"
chmod 600 "${TOKEN_FILE}"

# Fine-grained tokens must go through --token-fine; anything else is a classic
# PAT/OAuth token and belongs on --token.
case "${TOKEN}" in
    github_pat_*) TOKEN_FLAG="--token-fine" ;;
    *)            TOKEN_FLAG="--token" ;;
esac
echo "token flag=${TOKEN_FLAG}"

cleanup_token() {
    rm -f "${TOKEN_FILE}"
}

trap cleanup_token EXIT
trap 'cleanup_token; exit 143' INT TERM

notify_teams() {
    level=$1
    entity_type=$2
    entity=$3
    run_date=$4
    exit_code=$5
    log_file=$6

    if [ -z "${NOTIFY_WEBHOOK_URL}" ]; then
        return 0
    fi

    export NOTIFY_WEBHOOK_URL
    export NOTIFY_LEVEL="${level}"
    export NOTIFY_ENTITY_TYPE="${entity_type}"
    export NOTIFY_ENTITY="${entity}"
    export NOTIFY_RUN_DATE="${run_date}"
    export NOTIFY_EXIT_CODE="${exit_code}"
    export NOTIFY_LOG_FILE="${log_file}"
    export NOTIFY_SOFT_FAILURE_MARKERS="${SOFT_FAILURE_MARKERS}"

    python3 <<'PY'
import json
import os
import sys
import urllib.error
import urllib.request

level = os.environ["NOTIFY_LEVEL"]
entity_type = os.environ["NOTIFY_ENTITY_TYPE"]
entity = os.environ["NOTIFY_ENTITY"]
run_date = os.environ["NOTIFY_RUN_DATE"]
exit_code = os.environ["NOTIFY_EXIT_CODE"]
log_file = os.environ["NOTIFY_LOG_FILE"]
webhook_url = os.environ["NOTIFY_WEBHOOK_URL"]
# Same markers the shell uses to detect soft failures, plus "ERROR" and
# "Traceback", which are always worth showing in the card.
markers = os.environ["NOTIFY_SOFT_FAILURE_MARKERS"].split("|") + ["ERROR", "Traceback"]

def read_matching_lines(path):
    lines = []
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                if any(marker in line for marker in markers):
                    lines.append(line.rstrip())
    except OSError as exc:
        lines.append(f"could not read log: {exc}")
    return lines[-25:]

def read_tail(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            return [line.rstrip() for line in handle.readlines()[-20:]]
    except OSError as exc:
        return [f"could not read log: {exc}"]

matches = read_matching_lines(log_file)
tail = read_tail(log_file)
theme = "D13438" if level == "failure" else "F2C744"
title = f"GitHub backup {level}: {entity_type} {entity}"
summary = f"{entity_type} {entity}, run {run_date}, exit code {exit_code}"

payload = {
    "@type": "MessageCard",
    "@context": "https://schema.org/extensions",
    "themeColor": theme,
    "summary": title,
    "title": title,
    "sections": [
        {
            "facts": [
                {"name": "Entity", "value": f"{entity_type} {entity}"},
                {"name": "Run date", "value": run_date},
                {"name": "Exit code", "value": exit_code},
                {"name": "Log", "value": log_file},
            ],
            "text": summary,
        },
        {"activityTitle": "Matched lines", "text": "\n\n".join(matches) if matches else "No matching error or warning lines found."},
        {"activityTitle": "Log tail", "text": "\n\n".join(tail)},
    ],
}

request = urllib.request.Request(
    webhook_url,
    data=json.dumps(payload).encode("utf-8"),
    headers={"Content-Type": "application/json"},
    method="POST",
)

try:
    with urllib.request.urlopen(request, timeout=20) as response:
        if response.status >= 400:
            print(f"notification failed with HTTP {response.status}", file=sys.stderr)
except (urllib.error.URLError, TimeoutError) as exc:
    print(f"notification failed: {exc}", file=sys.stderr)
PY
}

has_soft_failures() {
    log_file=$1
    grep -E "${SOFT_FAILURE_MARKERS}" "${log_file}" >/dev/null 2>&1
}

run_backup() {
    entity_type=$1
    entity=$2
    organization_flag=$3
    run_date=$4
    output_directory="${VAR_DIR}/${run_date}/${entity}"
    log_file="${LOG_DIR}/${run_date}_${entity_type}_${entity}.log"
    archive="${VAR_DIR}/${run_date}/${run_date}_${entity}.tar.gz"
    rc_file=$(mktemp)

    mkdir -p "${LOG_DIR}"
    echo "$(date) - execute backup for ${entity_type} ${entity}, ${run_date}" | tee -a "${log_file}"

    # shellcheck disable=SC2086
    { github-backup "${entity}" ${organization_flag} "${TOKEN_FLAG}=file://${TOKEN_FILE}" --output-directory="${output_directory}" ${BACKUP_OPTIONS}; echo "$?" > "${rc_file}"; } 2>&1 | tee -a "${log_file}"
    rc=$(cat "${rc_file}")
    rm -f "${rc_file}"

    if [ "${rc}" -ne 0 ]; then
        echo "$(date) - ERROR: backup failed for ${entity_type} ${entity} with exit code ${rc}" | tee -a "${log_file}"
        notify_teams "failure" "${entity_type}" "${entity}" "${run_date}" "${rc}" "${log_file}"
    elif has_soft_failures "${log_file}"; then
        echo "$(date) - WARNING: backup completed for ${entity_type} ${entity} with warnings" | tee -a "${log_file}"
        notify_teams "warning" "${entity_type}" "${entity}" "${run_date}" "${rc}" "${log_file}"
    fi

    if [ -n "${COMPRESSION}" ] && [ -d "${output_directory}" ]; then
        echo "$(date) - compress ${output_directory} -> ${archive}" | tee -a "${log_file}"
        if tar -C "${VAR_DIR}/${run_date}" -czf "${archive}" "${entity}" >>"${log_file}" 2>&1; then
            rm -rf "${output_directory}"
        else
            echo "$(date) - ERROR: compression failed for ${entity_type} ${entity}, keeping ${output_directory}" | tee -a "${log_file}"
        fi
    fi
}

cleanup_old_backups() {
    if [ -d "${VAR_DIR}" ] && [ "$(find "${VAR_DIR}" -mindepth 1 -maxdepth 1 -type d -name '20*' 2>/dev/null)" ]; then
        find "${VAR_DIR}" -mindepth 1 -maxdepth 1 -type d -name '20*' | sort | head -n "-${MAX_BACKUPS}" | xargs -r rm -rf
    fi
}

cleanup_old_logs() {
    [ -d "${LOG_DIR}" ] || return 0

    # Log names start with the run date (YYYYMMDD-HHMMSS, 15 chars). Group by
    # run date so log retention matches backup retention, no matter how many
    # entities produce a log per run.
    find "${LOG_DIR}" -mindepth 1 -maxdepth 1 -type f -name '*.log' 2>/dev/null \
        | while read -r log_file; do
              basename "${log_file}" | cut -c1-15
          done \
        | sort -u \
        | head -n "-${MAX_BACKUPS}" \
        | while read -r stale_run; do
              rm -f -- "${LOG_DIR}/${stale_run}"_*.log
          done
}

echo "$(date) - start backup scheduler"
while :; do
    DATE=$(date +%Y%m%d-%H%M%S)

    if [ -z "${GITHUB_USER:-}" ]; then
        echo "No Github users defined."
    else
        for u in $(echo "$GITHUB_USER" | tr "," "\n"); do
            run_backup "User" "${u}" "" "${DATE}"
        done
    fi

    if [ -z "${GITHUB_ORG:-}" ]; then
        echo "No Github organization defined."
    else
        for o in $(echo "$GITHUB_ORG" | tr "," "\n"); do
            run_backup "Organization" "${o}" "--organization" "${DATE}"
        done
    fi

    if [ -z "${GITHUB_USER:-}" ] && [ -z "${GITHUB_ORG:-}" ]; then
        echo "No entities (user, organization) defined. No backup performed."
    else
        echo "Backup performed."

        echo "$(date) - cleanup"
        cleanup_old_backups
        cleanup_old_logs
    fi

    echo "$(date) - sleep for 1 day"
    # Backgrounded so the INT/TERM trap fires immediately; a foreground
    # sleep would defer the trap until the sleep finishes.
    sleep 86400 &
    wait $!
done
