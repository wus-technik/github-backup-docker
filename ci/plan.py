"""Resolve immutable build inputs; scheduled builds include the released code."""
import json
import os
import re
import subprocess
import sys

PLAIN = re.compile(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)\Z")
RELEASE = re.compile(r"(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?\Z")


def git(*args):
    return subprocess.check_output(["git", *args], text=True).strip()


def on_master(ref):
    return subprocess.run(["git", "merge-base", "--is-ancestor", ref, "origin/master"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0


def latest_release():
    tags = [tag for tag in git("tag", "--list").splitlines() if PLAIN.fullmatch(tag) and on_master(tag)]
    return max(tags, key=lambda tag: tuple(map(int, tag.split("."))), default="")


def plan(event, ref, sha):
    targets = []
    def add(source, channel, version=""):
        resolved = git("rev-parse", source + "^{commit}")
        # Old releases lack the hardening and cannot safely be rebuilt/promoted
        # by the new pipeline. A new hardened release bootstraps this channel.
        if channel == "stable":
            marker = subprocess.run(["git", "show", resolved + ":.security-rebuild-version"], capture_output=True, text=True)
            if marker.returncode or marker.stdout.strip() != "1":
                raise ValueError("latest release lacks security rebuild support; release the hardening first")
        targets.append({"id": channel, "sha": resolved, "channel": channel, "version": version})
    if event == "pull_request":
        add(sha, "test")
    elif ref.startswith("refs/tags/"):
        tag = ref.removeprefix("refs/tags/")
        if RELEASE.fullmatch(tag) and len(tag) <= 128 and on_master(sha):
            add(sha, "release", tag)
    elif event == "schedule" or event == "workflow_dispatch" and ref == "refs/heads/master":
        add("origin/master", "latest")
        release = latest_release()
        if release:
            add(release, "stable", release)
    else:
        add(sha, "latest" if event == "push" and ref == "refs/heads/master" else "preview")
    return targets


if __name__ == "__main__":
    targets = plan(os.environ["GITHUB_EVENT_NAME"], os.environ["GITHUB_REF"], os.environ["GITHUB_SHA"])
    builds = [{**target, "arch": arch, "platform": platform} for target in targets for arch, platform in (("amd64", "linux/amd64"), ("arm64", "linux/arm64"), ("armv7", "linux/arm/v7"))]
    output = {"targets": json.dumps(targets), "matrix": json.dumps({"include": builds}), "publish": str(bool(targets) and targets[0]["channel"] != "test").lower(), "build": str(bool(targets)).lower()}
    with open(os.environ["GITHUB_OUTPUT"], "a") as handle:
        for key, value in output.items():
            print(f"{key}={value}", file=handle)
    print(json.dumps(targets, indent=2))
