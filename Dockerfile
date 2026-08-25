FROM alpine:3.19

RUN apk add --update --no-cache tzdata git python3 py3-pip
RUN pip3 install --break-system-packages github-backup==0.65.1 && github-backup -v
COPY exec.sh /srv/exec.sh
RUN chmod +x /srv/exec.sh
ENTRYPOINT ["/srv/exec.sh"]
