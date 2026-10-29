"""Daily backup supervisor. Only completed, credential-free backups are successful."""
import base64
import contextlib
from collections import deque
from datetime import datetime
import fcntl
import json
import io
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import urllib.request
import uuid
from urllib.parse import quote
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

SOFT_FAILURES = ("is unavailable", "repository not accessible", "returned 128")
NAME = re.compile(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?\Z")
STAMP = re.compile(r"20\d{6}-\d{6}(?:-\d+)?\Z")


class StopRequested(BaseException):
    pass


class ConfigError(ValueError):
    pass


def secret(name, required=False):
    value, filename = os.environ.get(name, ""), os.environ.get(name + "_FILE", "")
    if value and filename:
        raise ConfigError(f"set only {name} or {name}_FILE")
    if filename:
        try:
            value = Path(filename).read_text().rstrip("\r\n")
        except OSError:
            raise ConfigError(f"cannot read {name}_FILE") from None
    if required and not value:
        raise ConfigError(f"{name} is not set")
    if "\n" in value or "\r" in value:
        raise ConfigError(f"{name} must contain a single line")
    return value


class Redactor:
    def __init__(self, *secrets):
        self.values = set()
        for value in filter(None, secrets):
            self.values.update((value, quote(value, safe="")))
            for plain in (value + ":x-oauth-basic", "x-access-token:" + value, "oauth2:" + value):
                self.values.add(base64.b64encode(plain.encode()).decode())

    def __call__(self, text):
        for value in sorted(self.values, key=len, reverse=True):
            text = text.replace(value, "[REDACTED]")
        text = re.sub(r"https?://[^\s/@]+(?::[^\s/@]*)?@", "https://[REDACTED]@", text)
        return re.sub(r"(?:github_pat_|gh[pousr]_)[A-Za-z0-9_]+", "[REDACTED]", text)


def atomic_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    with temporary.open("w") as handle:
        json.dump(data, handle)
        handle.flush()
        os.fsync(handle.fileno())
    temporary.replace(path)


def positive_integer(name, default):
    value = os.environ.get(name, str(default))
    if not value.isascii() or not value.isdigit() or not 1 <= int(value) <= 1000000:
        raise ConfigError(f"{name} must be a positive integer (at most 1000000)")
    return int(value)


def entities():
    result = []
    for kind, variable in (("User", "GITHUB_USER"), ("Organization", "GITHUB_ORG")):
        for value in os.environ.get(variable, "").split(","):
            value = value.strip()
            if value:
                if not NAME.fullmatch(value):
                    raise ConfigError(f"invalid {variable}: expected GitHub account names")
                if value.lower() in [name.lower() for _, name in result]:
                    raise ConfigError("duplicate GitHub account")
                result.append((kind, value))
    if not result:
        raise ConfigError("GITHUB_USER or GITHUB_ORG is required")
    return result


class Supervisor:
    def __init__(self):
        self.process = None
        self.root = Path(os.environ.get("VAR_DIR", "/srv/var"))
        self.token = ""
        self.webhook = ""
        self.redact = Redactor(os.environ.get("TOKEN", ""), os.environ.get("NOTIFY_WEBHOOK_URL", ""))
        self.workspace = None
        self.health = {"phase": "starting", "last_success": {}, "cycle_success": False, "instance": uuid.uuid4().hex}

    def log(self, message, handle=None):
        line = self.redact(str(message)).rstrip("\r\n")
        print(line, flush=True)
        if handle:
            handle.write(line + "\n")
            handle.flush()

    def configure(self):
        self.webhook = secret("NOTIFY_WEBHOOK_URL")
        self.redact = Redactor(os.environ.get("TOKEN", ""), self.webhook)
        self.token = secret("TOKEN", required=True)
        self.redact = Redactor(self.token, self.webhook)
        zone = os.environ.get("TIME_ZONE", "UTC")
        try:
            ZoneInfo(zone)
        except (ValueError, ZoneInfoNotFoundError):
            raise ConfigError("unknown TIME_ZONE") from None
        os.environ["TZ"] = zone
        time.tzset()
        self.keep = positive_integer("MAX_BACKUPS", 10)
        self.keep_failed = positive_integer("MAX_FAILED_BACKUPS", 3)
        self.targets = entities()
        self.compress = os.environ.get("COMPRESSION", "").lower() not in ("", "no", "false", "off", "0")
        try:
            self.options = shlex.split(os.environ.get("BACKUP_OPTIONS", "--all --private --gists"))
        except ValueError:
            raise ConfigError("BACKUP_OPTIONS has invalid quoting") from None
        # Authentication and output paths are exclusively managed by the runner.
        from github_backup.github_backup import parse_args
        try:
            with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
                parsed = parse_args(["example", *self.options])
        except SystemExit:
            raise ConfigError("BACKUP_OPTIONS contains invalid arguments") from None
        reserved = ("--token", "--token-fine", "--token-from-gh", "--keychain-name", "--keychain-account", "--output-directory", "--organization")
        explicit_override = any(
            (key.startswith("--") and any(flag.startswith(key) for flag in reserved))
            or re.match(r"^-[tfoO]", key)
            for key in (option.split("=", 1)[0] for option in self.options)
        )
        if explicit_override or any((parsed.token_classic is not None, parsed.token_fine is not None, parsed.token_from_gh, parsed.osx_keychain_item_name is not None, parsed.osx_keychain_item_account is not None, parsed.output_directory != ".", parsed.organization)):
            raise ConfigError("BACKUP_OPTIONS cannot override authentication, target type or output directory")
        self.git_host = parsed.github_host or "github.com"
        if not re.fullmatch(r"[A-Za-z0-9.-]+(?::[0-9]+)?", self.git_host):
            raise ConfigError("invalid --github-host")
        self.root.mkdir(parents=True, exist_ok=True)
        self.root = self.root.resolve()
        (self.root / "logs").mkdir(exist_ok=True)
        self.workspace = tempfile.TemporaryDirectory(prefix="github-backup-")
        self.token_file = Path(self.workspace.name) / "token"
        self.token_file.write_text(self.token + "\n")
        self.token_file.chmod(0o600)
        # Do not pass secret values to git, tar or any other child process.
        self.env = {key: value for key, value in os.environ.items() if key not in ("TOKEN", "NOTIFY_WEBHOOK_URL")}
        self.env.update(BACKUP_TOKEN_FILE=str(self.token_file), BACKUP_GIT_HOST=self.git_host)
        self.flag = "--token-fine" if self.token.startswith("github_pat_") else "--token"
        self.log(f"timezone={zone}\ncompression={'enabled' if self.compress else 'disabled'}")
        self.log(f"token flag={self.flag}")

    def terminate(self):
        process = self.process
        if process is None:
            return
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
        # A grandchild can outlive its parent; kill the entire group as well.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
        if process.stdout:
            process.stdout.close()
        self.process = None

    def run(self, command, handle=None, timeout=None):
        self.process = subprocess.Popen(command, env=self.env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace", start_new_session=True)
        try:
            if timeout is not None:
                output, _ = self.process.communicate(timeout=timeout)
                if output:
                    self.log(output, handle)
            else:
                for line in self.process.stdout:
                    self.log(line, handle)
            return self.process.wait()
        finally:
            self.terminate()

    def notify(self, level, kind="-", name="-", rc=78, logfile=None, message=""):
        if not self.webhook:
            return
        title = "GitHub backup configuration error" if level == "config" else f"GitHub backup {level}: {kind} {name}"
        tail = []
        if logfile:
            try:
                with logfile.open(errors="replace") as handle:
                    tail = list(deque(handle, maxlen=25))
            except OSError:
                pass
        payload = {"@type": "MessageCard", "@context": "https://schema.org/extensions", "themeColor": "F2C744" if level == "warning" else "D13438", "summary": title, "title": title, "sections": [{"facts": [{"name": "Problem", "value": self.redact(message or f"exit code {rc}")}], "text": self.redact("".join(tail))[-12000:]}]}
        # Isolate the blocking HTTP operation so signals and its overall deadline
        # are enforced by the supervisor, including DNS/TLS negotiation.
        with tempfile.TemporaryDirectory(prefix="backup-notify-") as directory:
            request = Path(directory) / "request.json"
            request.write_text(json.dumps({"url": self.webhook, "payload": payload}))
            self.env = getattr(self, "env", {k: v for k, v in os.environ.items() if k not in ("TOKEN", "NOTIFY_WEBHOOK_URL")})
            try:
                self.run([sys.executable, __file__, "--notify", str(request)], timeout=10 if level == "config" else 60)
            except subprocess.TimeoutExpired:
                self.log("notification timed out")

    def save_health(self):
        atomic_json(self.root / "health.json", self.health)

    def backup(self, kind, name, stamp):
        snapshot = self.root / stamp
        snapshot.mkdir(exist_ok=True)
        output = snapshot / name
        archive = snapshot / f"{stamp}_{name}.tar.gz"
        logfile = self.root / "logs" / f"{stamp}_{kind}_{name}.log"
        marker = snapshot / ".status" / f"{kind}_{name}.json"
        record = {"kind": kind, "name": name, "state": "failure", "compressed": False}
        atomic_json(marker, record)  # An interrupted run is never successful.
        with logfile.open("a") as handle:
            self.log(f"{datetime.now().isoformat()} - execute backup for {kind} {name}, {stamp}", handle)
            command = [sys.executable, "/srv/secure_github_backup.py", name, f"{self.flag}=file://{self.token_file}", f"--output-directory={output}", *self.options]
            if kind == "Organization":
                command.append("--organization")
            rc = self.run(command, handle)
            with logfile.open(errors="replace") as reader:
                warning = any(any(marker in line for marker in SOFT_FAILURES) or "ERROR" in line or "returned " in line for line in reader)
            state = "failure" if rc else "warning" if warning else "success"
            if not output.is_dir() or output.is_symlink():
                state = "failure"
            if state == "success" and self.compress:
                self.health["phase"] = "compressing"
                self.save_health()
                temporary = archive.with_suffix(".gz.partial")
                rc = self.run(["tar", "-C", str(snapshot), "-czf", str(temporary), name], handle)
                if rc == 0:
                    temporary.replace(archive)
                    shutil.rmtree(output)
                    record["compressed"] = True
                else:
                    state = "failure"
                    temporary.unlink(missing_ok=True)
                    self.log("ERROR: compression failed; keeping uncompressed backup", handle)
            record["state"] = state
            atomic_json(marker, record)
            if state != "success":
                self.log(f"{state.upper()}: backup {state} for {kind} {name} with exit code {rc}", handle)
                self.notify(state, kind, name, rc, logfile)
            else:
                self.health["last_success"][f"{kind}_{name}"] = time.time()
                self.log(f"backup completed for {kind} {name}", handle)
        return state == "success"

    def prune(self, kind, name):
        successful, failed = [], []
        for snapshot in sorted(self.root.iterdir()):
            if not STAMP.fullmatch(snapshot.name) or not snapshot.is_dir() or snapshot.is_symlink():
                continue
            marker = snapshot / ".status" / f"{kind}_{name}.json"
            if not marker.is_file() or marker.is_symlink() or marker.parent.is_symlink():
                continue  # Preserve legacy/unclassified data until explicitly verified.
            try:
                record = json.loads(marker.read_text())
            except (OSError, ValueError):
                continue
            if record.get("kind") != kind or record.get("name") != name:
                continue
            (successful if record.get("state") == "success" else failed).append((snapshot, marker))
        for group, keep in ((successful, self.keep), (failed, self.keep_failed)):
            for snapshot, marker in group[:-keep]:
                for artifact in (snapshot / name, snapshot / f"{snapshot.name}_{name}.tar.gz", snapshot / f"{snapshot.name}_{name}.tar.gz.partial"):
                    if artifact.is_symlink() or artifact.is_file():
                        artifact.unlink()
                    elif artifact.is_dir():
                        shutil.rmtree(artifact)
                (self.root / "logs" / f"{snapshot.name}_{kind}_{name}.log").unlink(missing_ok=True)
                marker.unlink()
                try:
                    marker.parent.rmdir()
                    snapshot.rmdir()
                except OSError:
                    pass  # Other entities and unknown files are retained.

    def cycle(self):
        with (self.root / ".cycle.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            maintenance = self.root / ".update-request"
            if maintenance.exists():
                if maintenance.read_text() == self.health["instance"]:
                    return False
                maintenance.unlink()  # A replacement container resumes immediately.
            self._cycle()
            return True

    def _cycle(self):
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        if (self.root / stamp).exists():
            stamp += f"-{time.time_ns()}"
        self.health.update(phase="running", cycle_success=False)
        self.save_health()
        results = []
        for kind, name in self.targets:
            self.health["phase"] = "running"
            results.append(self.backup(kind, name, stamp))
            self.prune(kind, name)
        self.health.update(phase="idle", cycle_success=all(results))
        self.save_health()

    def main(self):
        os.umask(0o077)
        def stop(signum, frame):
            raise SystemExit(143)
        signal.signal(signal.SIGTERM, stop)
        signal.signal(signal.SIGINT, stop)
        try:
            self.configure()
            while True:
                if not self.cycle():
                    time.sleep(5)
                    continue
                self.log("sleep for 1 day")
                time.sleep(86400)
        except ConfigError as exc:
            self.log(f"ERROR: {exc}")
            self.notify("config", message=str(exc))
            return 78
        except StopRequested:
            self.log("shutdown requested")
            return 143
        except Exception as exc:
            self.log(f"ERROR: supervisor failed: {exc}")
            self.notify("failure", rc=1, message=str(exc))
            return 1
        finally:
            # A second signal must not interrupt cleanup of credentials/children.
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            signal.signal(signal.SIGINT, signal.SIG_IGN)
            self.terminate()
            if self.workspace:
                self.workspace.cleanup()


def healthcheck(idle=False):
    try:
        status = json.loads((Path(os.environ.get("VAR_DIR", "/srv/var")) / "health.json").read_text())
        fresh = all(0 <= time.time() - status["last_success"].get(f"{kind}_{name}", 0) <= 172800 for kind, name in entities())
        return 0 if fresh and (not idle or status["phase"] == "idle" and status["cycle_success"]) else 1
    except (OSError, ValueError, KeyError):
        return 1


def maintenance(cancel=False):
    root = Path(os.environ.get("VAR_DIR", "/srv/var"))
    try:
        with (root / ".cycle.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            request = root / ".update-request"
            if cancel:
                request.unlink(missing_ok=True)
                return 0
            if healthcheck(idle=True):
                return 75
            status = json.loads((root / "health.json").read_text())
            request.write_text(status["instance"])
            return 0
    except (OSError, ValueError, KeyError):
        return 75


if __name__ == "__main__":
    if sys.argv[1:] == ["--healthcheck"]:
        sys.exit(healthcheck())
    if sys.argv[1:] == ["--idle"]:
        sys.exit(healthcheck(idle=True))
    if sys.argv[1:] == ["--prepare-update"]:
        sys.exit(maintenance())
    if sys.argv[1:] == ["--cancel-update"]:
        sys.exit(maintenance(cancel=True))
    if len(sys.argv) == 3 and sys.argv[1] == "--notify":
        request = json.loads(Path(sys.argv[2]).read_text())
        try:
            req = urllib.request.Request(request["url"], data=json.dumps(request["payload"]).encode(), headers={"Content-Type": "application/json"})
            urllib.request.urlopen(req, timeout=20).close()
        except Exception:
            print("notification delivery failed", file=sys.stderr)
            sys.exit(1)
    else:
        sys.exit(Supervisor().main())
