#!/opt/venv/bin/python3
"""Read-only Git credential helper: credentials never appear in argv or remotes."""
import os
import sys
from pathlib import Path


def credentials(request, operation, env=os.environ):
    if operation != "get":
        return ""
    fields = dict(line.split("=", 1) for line in request.splitlines() if "=" in line)
    if fields.get("protocol") != "https" or fields.get("host") != env.get("BACKUP_GIT_HOST"):
        return ""
    token = Path(env["BACKUP_TOKEN_FILE"]).read_text().splitlines()[0]
    return f"username=x-access-token\npassword={token}\n\n"


if __name__ == "__main__":
    sys.stdout.write(credentials(sys.stdin.read(), sys.argv[1] if len(sys.argv) > 1 else ""))
