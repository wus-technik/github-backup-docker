FROM alpine:3.23

LABEL org.opencontainers.image.title="github-backup-docker" \
      org.opencontainers.image.description="wus-technik maintained Docker wrapper for python-github-backup, based on upstream umputun/github-backup-docker" \
      org.opencontainers.image.vendor="wus-technik" \
      org.opencontainers.image.authors="wus-technik" \
      org.opencontainers.image.source="https://github.com/wus-technik/github-backup-docker" \
      org.opencontainers.image.url="https://github.com/wus-technik/github-backup-docker" \
      org.opencontainers.image.documentation="https://github.com/wus-technik/github-backup-docker#readme" \
      org.opencontainers.image.licenses="MIT"

ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    HOME=/tmp
COPY requirements.txt /srv/requirements.txt
# A unique pipeline value also refreshes packages between base-image rebuilds.
# Install/remove build tools in one layer so their bytes are not shipped either.
ARG PACKAGE_REFRESH=local
RUN echo "package refresh: ${PACKAGE_REFRESH}" \
 && apk upgrade --no-cache \
 && apk add --no-cache ca-certificates tzdata git python3 tini \
 && apk add --no-cache --virtual .build-deps py3-pip \
 && python3 -m venv /opt/venv \
 && pip install --no-cache-dir --require-hashes --only-binary=:all: -r /srv/requirements.txt \
 && python3 -m pip uninstall -y pip \
 && apk del .build-deps \
 && addgroup -g 10001 backup \
 && adduser -D -H -u 10001 -G backup backup \
 && mkdir -p /srv/var \
 && chown backup:backup /srv/var

COPY exec.sh backup.py secure_github_backup.py git_credential.py /srv/
RUN chmod 755 /srv/exec.sh /srv/git_credential.py \
 && github-backup --version
USER 10001:10001
HEALTHCHECK --interval=60s --timeout=5s --start-period=30m \
    CMD ["python3", "/srv/backup.py", "--healthcheck"]
ENTRYPOINT ["/sbin/tini", "--", "/srv/exec.sh"]
