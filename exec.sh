#!/bin/sh

TIME_ZONE=${TIME_ZONE:=UTC}
echo "timezone=${TIME_ZONE}"

BACKUP_OPTIONS=${BACKUP_OPTIONS:='--all --private --gists'}
echo "backup options=${BACKUP_OPTIONS}"

cp /usr/share/zoneinfo/${TIME_ZONE} /etc/localtime
echo "${TIME_ZONE}" >/etc/timezone

echo "$(date) - start backup scheduler"
while :; do
    DATE=$(date +%Y%m%d-%H%M%S)

    if [ -z "$GITHUB_USER" ]
      then
      echo "No Github users defined."
    else
      for u in $(echo $GITHUB_USER | tr "," "\n"); do
        echo "$(date) - execute backup for User ${u}, ${DATE}"
        OUTDIR="/srv/var/${DATE}/${u}"
        ARCHIVE="/srv/var/${DATE}/${u}.tar.gz"

        github-backup "${u}" --token="$TOKEN" --output-directory="$OUTDIR" ${BACKUP_OPTIONS}

        if [ -n "$COMPRESSION" ]; then
          echo "$(date) - compress ${OUTDIR} -> ${ARCHIVE}"
          tar -C "/srv/var/${DATE}" -czf "$ARCHIVE" "${u}" && rm -rf "$OUTDIR"
        fi
      done
    fi

    if [ -z "$GITHUB_ORG" ]
      then
          echo "No Github organization defined."
    else
      for o in $(echo $GITHUB_ORG | tr "," "\n"); do
        echo "$(date) - execute backup for Organization ${o}, ${DATE}"
        OUTDIR="/srv/var/${DATE}/${o}"
        ARCHIVE="/srv/var/${DATE}/${o}.tar.gz"

        github-backup "${o}" --organization --token="$TOKEN" --output-directory="$OUTDIR" ${BACKUP_OPTIONS}

        if [ -n "$COMPRESSION" ]; then
          echo "$(date) - compress ${OUTDIR} -> ${ARCHIVE}"
          tar -C "/srv/var/${DATE}" -czf "$ARCHIVE" "${o}" && rm -rf "$OUTDIR"
        fi
      done
    fi

    if [ -z "$GITHUB_USER" ] && [ -z "$GITHUB_ORG" ]
    then
      echo "No entities (user, organization) defined. No backup performed."
    else
      echo "Backup performed."
    fi

    echo "$(date) - cleanup"
    ls -d1 /srv/var/* | head -n -${MAX_BACKUPS} | xargs rm -rf

    echo "$(date) - sleep for 1 day"
    sleep 1d
done
