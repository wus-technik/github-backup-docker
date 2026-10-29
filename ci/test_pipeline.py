"""Offline tests for the publishing decisions; no registry credentials needed."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent))
import plan
import publish


class PlanTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.previous = Path.cwd()
        os.chdir(self.directory.name)
        self.git("init", "-q")
        self.git("config", "user.name", "Test")
        self.git("config", "user.email", "test@example.invalid")
        Path(".security-rebuild-version").write_text("1\n")
        self.git("add", ".")
        self.git("commit", "-qm", "hardened release")
        self.release = self.git("rev-parse", "HEAD")
        self.git("tag", "1.2.5")
        Path("change").write_text("unreleased")
        self.git("add", ".")
        self.git("commit", "-qm", "unreleased")
        self.head = self.git("rev-parse", "HEAD")
        self.git("update-ref", "refs/remotes/origin/master", self.head)

    def tearDown(self):
        os.chdir(self.previous)
        self.directory.cleanup()

    def git(self, *args):
        return subprocess.check_output(["git", *args], text=True).strip()

    def test_schedule_rebuilds_master_and_release_separately(self):
        targets = plan.plan("schedule", "refs/heads/master", self.head)
        self.assertEqual([(target["sha"], target["channel"]) for target in targets], [(self.head, "latest"), (self.release, "stable")])

    def test_pr_never_publishes(self):
        self.assertEqual(plan.plan("pull_request", "refs/pull/1/merge", self.head)[0]["channel"], "test")

    def test_dispatch_master_refreshes_stable_too(self):
        self.assertEqual(len(plan.plan("workflow_dispatch", "refs/heads/master", self.head)), 2)

    def test_prerelease_never_becomes_latest_release(self):
        self.git("tag", "9.0.0-rc1")
        self.assertEqual(plan.latest_release(), "1.2.5")

    def test_unmerged_tags_and_invalid_docker_tags_do_not_publish(self):
        for tag in ("not-a-version", "1.2.3+metadata"):
            self.assertEqual(plan.plan("push", "refs/tags/" + tag, self.head), [])
        with patch.object(plan, "on_master", return_value=False):
            self.assertEqual(plan.plan("push", "refs/tags/1.2.5", self.head), [])

    def test_archive_sources_and_immutable_release_tag(self):
        target = {"id": "release", "sha": self.release, "channel": "release", "version": "1.2.5"}
        with patch.object(publish, "copy") as copy, patch.object(publish, "run"), patch.object(publish.subprocess, "check_output", return_value=b"{}"), patch.object(publish, "exists", return_value=True), patch.object(publish, "latest_release", return_value="1.2.5"), patch.object(publish, "git", return_value=self.release):
            publish.publish(target, "ghcr.io/example/image", "123-1")
        sources = [call.args[0] for call in copy.call_args_list]
        self.assertEqual(sum(source.startswith("oci-archive:") for source in sources), 3)
        destinations = [call.args[1] for call in copy.call_args_list]
        self.assertNotIn("ghcr.io/example/image:1.2.5", destinations)
        self.assertIn("ghcr.io/example/image:stable", destinations)

    def test_stale_release_cannot_roll_back_stable(self):
        target = {"id": "release", "sha": self.release, "channel": "release", "version": "1.2.5"}
        with patch.object(publish, "copy") as copy, patch.object(publish, "run"), patch.object(publish.subprocess, "check_output", return_value=b"{}"), patch.object(publish, "exists", return_value=True), patch.object(publish, "latest_release", return_value="1.2.6"):
            publish.publish(target, "ghcr.io/example/image", "123-1")
        self.assertFalse(any(call.args[1].endswith(":stable") for call in copy.call_args_list))

    def test_registry_failure_does_not_authorize_overwrite(self):
        failure = subprocess.CompletedProcess([], 1, stderr="network timeout")
        with patch.object(publish.subprocess, "run", return_value=failure):
            with self.assertRaises(RuntimeError):
                publish.exists("ghcr.io/example/image:1.2.5")

    def test_older_rebuild_cannot_roll_back_same_release(self):
        raw = json.dumps({"annotations": {"io.wus-technik.build-sequence": "10.2"}}).encode()
        with patch.object(publish, "exists", return_value=True), patch.object(publish.subprocess, "check_output", return_value=raw):
            self.assertFalse(publish.newer_than_alias("example:stable", "9.1"))
            self.assertFalse(publish.newer_than_alias("example:stable", "10.1"))
            self.assertTrue(publish.newer_than_alias("example:stable", "10.2"))
            self.assertTrue(publish.newer_than_alias("example:stable", "11.1"))

    def test_schedule_does_not_republish_an_unhardened_release(self):
        with patch.object(plan, "latest_release", return_value="1.2.5"), patch.object(plan.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, stdout="")):
            with self.assertRaises(ValueError):
                plan.plan("schedule", "refs/heads/master", self.head)


if __name__ == "__main__":
    unittest.main()
