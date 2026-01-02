FROM alpine:3.23

RUN apk add --no-cache \
    tzdata \
    git \
    python3 \
    py3-pip

RUN python3 -m pip install --no-cache-dir github-backup

COPY exec.sh /srv/exec.sh
RUN chmod +x /srv/exec.sh

CMD ["/srv/exec.sh"]
