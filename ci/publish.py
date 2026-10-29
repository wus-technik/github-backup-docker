"""Publish verified OCI archives without rebuilding; serialize all promotions."""
import json
import os
from pathlib import Path
import subprocess
import sys
from plan import PLAIN, git, latest_release


def run(*args):
    subprocess.run(args, check=True)


def copy(source, target):
    run("skopeo", "copy", "--all", "--preserve-digests", "--authfile", str(Path.home() / ".docker/config.json"), source, "docker://" + target)


def exists(image):
    # Only a confirmed MANIFEST_UNKNOWN/404 permits creation. Network/authentication
    # failures must never be interpreted as permission to overwrite a release.
    result = subprocess.run(["skopeo", "inspect", "--raw", "docker://" + image], capture_output=True, text=True)
    if result.returncode == 0:
        return True
    if "manifest unknown" in result.stderr.lower() or "name unknown" in result.stderr.lower():
        return False
    raise RuntimeError(result.stderr)


def newer_than_alias(image, sequence):
    if not exists(image):
        return True
    raw = json.loads(subprocess.check_output(["skopeo", "inspect", "--raw", "docker://" + image]))
    previous = raw.get("annotations", {}).get("io.wus-technik.build-sequence", "0.0")
    return tuple(map(int, sequence.split("."))) >= tuple(map(int, previous.split(".")))


def publish(target, image, run_id):
    unique = f"build-{run_id}-{target['channel']}"
    sequence = os.environ.get("GITHUB_RUN_NUMBER", "0") + "." + os.environ.get("GITHUB_RUN_ATTEMPT", "1")
    references = []
    for arch in ("amd64", "arm64", "armv7"):
        tag = f"{image}:{unique}-{arch}"
        archive = Path("artifacts") / f"{target['id']}-{arch}" / "image.tar"
        copy("oci-archive:" + str(archive), tag)
        references.append(tag)
    tag = f"{image}:{unique}"
    run("docker", "buildx", "imagetools", "create", "--annotation", "index:io.wus-technik.build-sequence=" + sequence, "--tag", tag, *references)
    raw = subprocess.check_output(["skopeo", "inspect", "--raw", "docker://" + tag])
    import hashlib
    digest = "sha256:" + hashlib.sha256(raw).hexdigest()
    source = "docker://" + image + "@" + digest
    aliases = []
    channel, version = target["channel"], target["version"]
    # Refresh after waiting for the publish lock, not at the start of the build.
    run("git", "fetch", "--force", "--tags", "origin", "+refs/heads/master:refs/remotes/origin/master")
    if channel == "latest" and target["sha"] == git("rev-parse", "origin/master"):
        aliases.append("latest")
        commit_tag = "master-" + target["sha"][:7]
        if not exists(image + ":" + commit_tag):
            aliases.append(commit_tag)
    if channel == "preview" and not exists(image + ":" + target["sha"]):
        aliases.append(target["sha"])
    if channel == "release" and not exists(image + ":" + version):
        aliases.append(version)
    if channel in ("release", "stable") and PLAIN.fullmatch(version) and version == latest_release():
        # Reject a moved Git tag as well as a stale release/build.
        if target["sha"] == git("rev-parse", version + "^{commit}"):
            aliases.append("stable")
    for alias in aliases:
        if alias in ("latest", "stable") and not newer_than_alias(image + ":" + alias, sequence):
            continue
        copy(source, image + ":" + alias)
    with open(os.environ.get("GITHUB_STEP_SUMMARY", os.devnull), "a") as summary:
        print(f"- `{tag}` / `{digest}`: source `{target['sha']}`, release `{version or '-'}`, aliases `{', '.join(aliases) or '-'}" + "`", file=summary)


if __name__ == "__main__":
    for target in json.loads(os.environ["TARGETS"]):
        publish(target, "ghcr.io/" + os.environ["GITHUB_REPOSITORY"].lower(), os.environ["GITHUB_RUN_ID"] + "-" + os.environ["GITHUB_RUN_ATTEMPT"])
