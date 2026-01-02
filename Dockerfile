FROM alpine:3.23

RUN apk add --no-cache \
    tzdata \
    git \
    python3 \
    py3-pip

# Create venv, install, then remove pip
RUN python3 -m venv /opt/venv \
 && /opt/venv/bin/pip install --no-cache-dir --upgrade pip \
 && /opt/venv/bin/pip install --no-cache-dir github-backup \
 && apk del py3-pip

# Use venv by default
ENV PATH="/opt/venv/bin:$PATH"

COPY exec.sh /srv/exec.sh
RUN chmod +x /srv/exec.sh

CMD ["/srv/exec.sh"]
