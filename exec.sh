#!/bin/sh
set -u

TIME_ZONE=${TIME_ZONE:=UTC}
echo "timezone=${TIME_ZONE}"

BACKUP_OPTIONS=${BACKUP_OPTIONS:='--all --private --gists'}
echo "backup options=${BACKUP_OPTIONS}"

MAX_BACKUPS=${MAX_BACKUPS:=10}
echo "max backups=${MAX_BACKUPS}"

cp /usr/share/zoneinfo/"${TIME_ZONE}" /etc/localtime
echo "${TIME_ZONE}" >/etc/timezone

# Write token to a temp file to avoid exposing it in the process list
TOKEN_FILE=$(mktemp)
echo "${TOKEN}" > "${TOKEN_FILE}"
chmod 600 "${TOKEN_FILE}"
trap 'rm -f "${TOKEN_FILE}"' EXIT INT TERM

echo "$(date) - start backup scheduler"
while :; do
    DATE=$(date +%Y%m%d-%H%M%S)

    if [ -z "${GITHUB_USER:-}" ]; then
        echo "No Github users defined."
    else
        for u in $(echo "$GITHUB_USER" | tr "," "\n"); do
            echo "$(date) - execute backup for User ${u}, ${DATE}"
            # shellcheck disable=SC2086
            github-backup "${u}" --token-file="${TOKEN_FILE}" --output-directory="/srv/var/${DATE}/${u}" ${BACKUP_OPTIONS}
            if [ $? -ne 0 ]; then
                echo "$(date) - ERROR: backup failed for User ${u}"
            fi
        done
    fi

    if [ -z "${GITHUB_ORG:-}" ]; then
        echo "No Github organization defined."
    else
        for o in $(echo "$GITHUB_ORG" | tr "," "\n"); do
            echo "$(date) - execute backup for Organization ${o}, ${DATE}"
            # shellcheck disable=SC2086
            github-backup "${o}" --organization --token-file="${TOKEN_FILE}" --output-directory="/srv/var/${DATE}/${o}" ${BACKUP_OPTIONS}
            if [ $? -ne 0 ]; then
                echo "$(date) - ERROR: backup failed for Organization ${o}"
            fi
        done
    fi

    if [ -z "${GITHUB_USER:-}" ] && [ -z "${GITHUB_ORG:-}" ]; then
        echo "No entities (user, organization) defined. No backup performed."
    else
        echo "Backup performed."

        echo "$(date) - cleanup"
        if [ -d /srv/var ] && [ "$(ls -A /srv/var 2>/dev/null)" ]; then
            ls -d1 /srv/var/* 2>/dev/null | head -n "-${MAX_BACKUPS}" | xargs -r rm -rf
        fi
    fi

    echo "$(date) - sleep for 1 day"
    sleep 1d
done
