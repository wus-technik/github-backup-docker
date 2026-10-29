"""Regression tests execute inside the built image against its real upstream wheel."""
import base64
import contextlib
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, "/srv")
from backup import ConfigError, Redactor, Supervisor, atomic_json, entities, healthcheck, maintenance, secret
from git_credential import credentials
import secure_github_backup as adapter
from github_backup import github_backup as upstream

TOKEN = "ghp_security_test_dummy_do_not_use"


class SecurityTests(unittest.TestCase):
    def setUp(self):
        os.umask(0o077)
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.environment = patch.dict(os.environ, {"TOKEN": TOKEN, "GITHUB_USER": "example", "GITHUB_ORG": "", "VAR_DIR": str(self.root), "TIME_ZONE": "UTC"})
        self.environment.start()

    def tearDown(self):
        self.environment.stop()
        self.directory.cleanup()

    def supervisor(self):
        supervisor = Supervisor()
        supervisor.configure()
        self.addCleanup(supervisor.workspace.cleanup)
        return supervisor

    def record(self, stamp, state, name="example"):
        snapshot = self.root / stamp
        (snapshot / name).mkdir(parents=True, exist_ok=True)
        (snapshot / name / "content").write_text("valid backup fixture")
        atomic_json(snapshot / ".status" / f"User_{name}.json", {"kind": "User", "name": name, "state": state})
        return snapshot

    def test_no_runtime_installers_and_non_root(self):
        self.assertNotEqual(os.getuid(), 0)
        import importlib.util
        self.assertIsNone(importlib.util.find_spec("pip"))
        self.assertIsNone(importlib.util.find_spec("setuptools"))

    def test_secrets_from_file_and_mutual_exclusion(self):
        filename = self.root / "token"
        filename.write_text(TOKEN + "\n")
        with patch.dict(os.environ, {"TOKEN": "", "TOKEN_FILE": str(filename)}):
            self.assertEqual(secret("TOKEN", True), TOKEN)
        with patch.dict(os.environ, {"TOKEN_FILE": str(filename)}):
            with self.assertRaises(ConfigError):
                secret("TOKEN", True)

    def test_redacts_token_url_basic_auth_and_webhook(self):
        webhook = "https://example.invalid/hook?sig=secret"
        redact = Redactor(TOKEN, webhook)
        for value in (TOKEN, base64.b64encode((TOKEN + ":x-oauth-basic").encode()).decode(), webhook):
            self.assertNotIn(value, redact("error " + value))
        self.assertNotIn("password", redact("https://user:password@github.com/owner/repo"))

    def test_no_secret_values_in_child_environment(self):
        supervisor = self.supervisor()
        self.assertNotIn("TOKEN", supervisor.env)
        self.assertNotIn("NOTIFY_WEBHOOK_URL", supervisor.env)
        self.assertEqual(supervisor.token_file.stat().st_mode & 0o777, 0o600)

    def test_subprocess_output_is_redacted_before_stdout_and_disk(self):
        supervisor = self.supervisor()
        logfile = self.root / "sanitized.log"
        code = "import os,pathlib,base64; t=pathlib.Path(os.environ['BACKUP_TOKEN_FILE']).read_text().strip(); print(t); print(base64.b64encode((t+':x-oauth-basic').encode()).decode())"
        output = io.StringIO()
        with logfile.open("w") as handle, contextlib.redirect_stdout(output):
            self.assertEqual(supervisor.run([sys.executable, "-c", code], handle), 0)
        for text in (logfile.read_text(), output.getvalue()):
            self.assertNotIn(TOKEN, text)
            self.assertNotIn(base64.b64encode((TOKEN + ":x-oauth-basic").encode()).decode(), text)
            self.assertIn("[REDACTED]", text)

    def test_notification_payload_is_redacted(self):
        supervisor = self.supervisor()
        supervisor.webhook = "https://example.invalid/hook?sig=dummy"
        supervisor.redact = Redactor(TOKEN, supervisor.webhook)
        logfile = self.root / "legacy.log"
        logfile.write_text("old log contains " + TOKEN)
        def request(command, timeout):
            data = json.loads(Path(command[-1]).read_text())
            self.assertNotIn(TOKEN, json.dumps(data["payload"]))
            return 0
        with patch.object(supervisor, "run", side_effect=request):
            supervisor.notify("failure", logfile=logfile, message=TOKEN)

    def test_invalid_targets_and_overrides_rejected(self):
        for name in ("../escape", "-option", "foo/bar", "a" * 40):
            with patch.dict(os.environ, {"GITHUB_USER": name}):
                with self.assertRaises(ConfigError):
                    entities()
        for option in ("--token=secret", "-t secret", "--out=/tmp/escape", "--organization", "-o .", "--out=.", "--token-fine=''"):
            with patch.dict(os.environ, {"BACKUP_OPTIONS": option}):
                with self.assertRaises(ConfigError):
                    Supervisor().configure()

    def test_helper_scopes_credentials_to_https_host(self):
        path = self.root / "token"
        path.write_text(TOKEN)
        env = {"BACKUP_TOKEN_FILE": str(path), "BACKUP_GIT_HOST": "github.com"}
        self.assertIn(TOKEN, credentials("protocol=https\nhost=github.com\n\n", "get", env))
        for request in ("protocol=http\nhost=github.com", "protocol=https\nhost=evil.invalid", "protocol=https\nhost=github.com.evil.invalid"):
            self.assertEqual(credentials(request, "get", env), "")
        self.assertEqual(credentials("protocol=https\nhost=github.com", "store", env), "")

    def test_real_git_uses_helper_without_storing_secret(self):
        supervisor = self.supervisor()
        # Set up the adapter exactly as its CLI does, but replace only API work.
        with patch("github_backup.cli.main", return_value=None):
            adapter.main()
        env = {**os.environ, **supervisor.env}
        reply = subprocess.run(["git", "credential", "fill"], input="protocol=https\nhost=github.com\n\n", text=True, capture_output=True, env=env, check=True)
        self.assertIn("password=" + TOKEN, reply.stdout)
        for token, flag in ((TOKEN, "--token"), ("github_pat_dummy_fine", "--token-fine")):
            args = upstream.parse_args(["example", flag, token])
            url = upstream.get_github_repo_url(args, {"owner": {"login": "example"}, "name": "fixture"})
            self.assertNotIn(token, url)
            self.assertEqual(url, "https://github.com/example/fixture.git")
        origin = self.root / "origin"
        subprocess.run(["git", "init", "-q", str(origin)], check=True)
        (origin / "restore.txt").write_text("recover this content")
        subprocess.run(["git", "-C", str(origin), "add", "restore.txt"], check=True)
        subprocess.run(["git", "-C", str(origin), "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "fixture"], check=True)
        dest = self.root / "restore"
        subprocess.run(["git", "-c", "protocol.file.allow=always", "-c", f"url.{origin}.insteadOf={url}", "clone", "-q", url, str(dest)], check=True)
        self.assertNotIn(TOKEN, (dest / ".git/config").read_text())
        self.assertEqual((dest / "restore.txt").read_text(), "recover this content")

    def test_failures_never_displace_successes(self):
        supervisor = self.supervisor()
        supervisor.keep = 2
        supervisor.keep_failed = 1
        good = [self.record(f"2020010{n}-000000", "success") for n in (1, 2)]
        bad = [self.record(f"2020010{n}-000000", "failure") for n in (3, 4, 5)]
        supervisor.prune("User", "example")
        self.assertTrue(all(path.exists() for path in good))
        self.assertFalse(bad[0].exists())
        self.assertFalse(bad[1].exists())
        self.assertTrue(bad[2].exists())

    def test_retention_per_account_preserves_legacy_and_other_accounts(self):
        supervisor = self.supervisor()
        supervisor.keep = 2
        legacy = self.root / "20190101-000000" / "example"
        legacy.mkdir(parents=True)
        old = self.record("20200101-000000", "success")
        other = self.record("20200101-000000", "success", "another")
        self.record("20200102-000000", "success")
        self.record("20200103-000000", "success")
        supervisor.prune("User", "example")
        self.assertFalse((old / "example").exists())
        self.assertTrue((other / "another/content").exists())
        self.assertTrue(legacy.exists())

    def test_warning_preserves_previous_success(self):
        supervisor = self.supervisor()
        supervisor.keep = 1
        good = self.record("20200101-000000", "success")
        self.record("20200102-000000", "warning")
        supervisor.prune("User", "example")
        self.assertTrue(good.exists())

    def test_pruning_does_not_follow_symlinks(self):
        supervisor = self.supervisor()
        supervisor.keep = 1
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "keep").write_text("keep")
        old = self.record("20200101-000000", "success")
        import shutil
        shutil.rmtree(old / "example")
        (old / "example").symlink_to(outside, target_is_directory=True)
        self.record("20200102-000000", "success")
        supervisor.prune("User", "example")
        self.assertTrue((outside / "keep").exists())

    def test_compression_failure_is_failed_and_notifies(self):
        supervisor = self.supervisor()
        supervisor.compress = True
        def run(command, handle):
            if command[0] == "tar":
                return 1
            output = next(part.split("=", 1)[1] for part in command if part.startswith("--output-directory="))
            Path(output).mkdir(parents=True)
            return 0
        with patch.object(supervisor, "run", side_effect=run), patch.object(supervisor, "notify") as notify:
            self.assertFalse(supervisor.backup("User", "example", "20200101-000000"))
            self.assertEqual(notify.call_args.args[0], "failure")
        self.assertTrue((self.root / "20200101-000000/example").exists())
        self.assertEqual(json.loads((self.root / "20200101-000000/.status/User_example.json").read_text())["state"], "failure")

    def test_compression_is_restorable_and_private(self):
        supervisor = self.supervisor()
        supervisor.compress = True
        real_run = supervisor.run
        def run(command, handle):
            if command[0] == "tar":
                return real_run(command, handle)
            output = Path(next(part.split("=", 1)[1] for part in command if part.startswith("--output-directory=")))
            output.mkdir(parents=True)
            (output / "restore.txt").write_text("recover me")
            return 0
        with patch.object(supervisor, "run", side_effect=run):
            self.assertTrue(supervisor.backup("User", "example", "20200101-000000"))
        archive = self.root / "20200101-000000/20200101-000000_example.tar.gz"
        self.assertEqual(archive.stat().st_mode & 0o777, 0o600)
        restored = subprocess.check_output(["tar", "-xOzf", str(archive), "example/restore.txt"])
        self.assertEqual(restored, b"recover me")

    def test_health_requires_every_target_and_successful_idle_cycle(self):
        atomic_json(self.root / "health.json", {"phase": "running", "last_success": {"User_example": time.time()}, "cycle_success": False})
        self.assertEqual(healthcheck(), 0)
        self.assertEqual(healthcheck(idle=True), 1)
        with patch.dict(os.environ, {"GITHUB_ORG": "another"}):
            self.assertEqual(healthcheck(), 1)

    def test_update_lease_prevents_new_cycle_until_replacement(self):
        supervisor = self.supervisor()
        supervisor.health.update(phase="idle", cycle_success=True, last_success={"User_example": time.time()})
        supervisor.save_health()
        self.assertEqual(maintenance(), 0)
        with patch.object(supervisor, "_cycle") as cycle:
            self.assertFalse(supervisor.cycle())
            cycle.assert_not_called()
            supervisor.health["instance"] = "replacement-container"
            self.assertTrue(supervisor.cycle())
            cycle.assert_called_once()

    def test_busy_backup_cannot_grant_update_lease(self):
        import fcntl
        with (self.root / ".cycle.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            self.assertEqual(maintenance(), 75)

    def test_signal_during_backup_and_compression_kills_grandchildren(self):
        for phase in ("backup", "compression"):
            script = self.root / f"signal-{phase}.py"
            script.write_text("""import sys,signal
from pathlib import Path
sys.path.insert(0,'/srv')
from backup import Supervisor
s=Supervisor()
s.configure()
s.compress=True
original=s.run
phase=sys.argv[1]
def run(command,handle):
 if phase=='backup' or command[0]=='tar':
  return original(['sh','-c','sleep 120 & echo CHILD=$!; wait'],handle)
 output=Path(next(arg.split('=',1)[1] for arg in command if arg.startswith('--output-directory=')))
 output.mkdir(parents=True)
 (output/'fixture').write_text('valid fixture')
 return 0
s.run=run
signal.signal(signal.SIGTERM,lambda *_:sys.exit(143))
try:
 s.backup('User','example','20200101-000000')
finally:
 s.terminate()
 s.workspace.cleanup()
""")
            process = subprocess.Popen([sys.executable, str(script), phase], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            for line in process.stdout:
                if line.startswith("CHILD="):
                    child = int(line.split("=")[1])
                    break
            started = time.monotonic()
            process.terminate()
            self.assertEqual(process.wait(timeout=8), 143)
            process.stdout.close()
            self.assertLess(time.monotonic() - started, 8)
            # tini reaps the terminated grandchild asynchronously.
            for _ in range(30):
                if not Path(f"/proc/{child}").exists():
                    break
                time.sleep(0.1)
            else:
                stat = Path(f"/proc/{child}/stat").read_text()
                self.assertIn(") Z ", stat)


if __name__ == "__main__":
    os.umask(0o077)
    unittest.main()
