"""Keep upstream's CLI/API behavior, but use Git's credential protocol for clones.

This deliberately small adapter is tested against the installed upstream wheel.
No upstream source is copied or patched during the build.
"""
import os
import sys
from urllib.parse import urlsplit, urlunsplit

from github_backup import github_backup as upstream


def credential_free_url(url):
    parsed = urlsplit(url)
    if parsed.scheme in ("http", "https"):
        if parsed.scheme != "https":
            raise ValueError("refusing Git credentials over HTTP")
        return urlunsplit((parsed.scheme, parsed.netloc.rsplit("@", 1)[-1], parsed.path, parsed.query, parsed.fragment))
    return url


def main():
    original = upstream.get_github_repo_url

    def repo_url(args, repository):
        return credential_free_url(original(args, repository))

    upstream.get_github_repo_url = repo_url
    # Clear inherited/global helpers first; never store the returned credential.
    config = [
        ("credential.helper", ""),
        ("credential.helper", "/srv/git_credential.py"),
        ("credential.useHttpPath", "true"),
    ]
    os.environ["GIT_CONFIG_COUNT"] = str(len(config))
    for index, (key, value) in enumerate(config):
        os.environ[f"GIT_CONFIG_KEY_{index}"] = key
        os.environ[f"GIT_CONFIG_VALUE_{index}"] = value
    os.environ["GIT_TERMINAL_PROMPT"] = "0"
    os.environ["GIT_CONFIG_NOSYSTEM"] = "1"
    os.environ["GIT_CONFIG_GLOBAL"] = "/dev/null"
    from github_backup.cli import main as upstream_main
    try:
        upstream_main()
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
