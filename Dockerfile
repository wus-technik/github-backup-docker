FROM alpine:3.19

LABEL org.opencontainers.image.title="github-backup-docker" \
      org.opencontainers.image.description="wus-technik maintained Docker wrapper for python-github-backup, based on upstream umputun/github-backup-docker" \
      org.opencontainers.image.vendor="wus-technik" \
      org.opencontainers.image.authors="wus-technik" \
      org.opencontainers.image.source="https://github.com/wus-technik/github-backup-docker" \
      org.opencontainers.image.url="https://github.com/wus-technik/github-backup-docker" \
      org.opencontainers.image.documentation="https://github.com/wus-technik/github-backup-docker#readme" \
      org.opencontainers.image.licenses="MIT"

RUN apk add --update --no-cache tzdata git python3 py3-pip
RUN pip3 install --break-system-packages github-backup==0.65.1 && github-backup -v
COPY exec.sh /srv/exec.sh
RUN chmod +x /srv/exec.sh
ENTRYPOINT ["/srv/exec.sh"]
