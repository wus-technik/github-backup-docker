"""Exercise deployment decisions with a fake Docker CLI, never a real stack."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


@unittest.skipUnless(os.name == "posix", "Linux deployment script")
class UpdateTests(unittest.TestCase):
    def invoke(self, scenario):
        # The security test container deliberately mounts /tmp with noexec.
        # Only this fake CLI needs an executable fixture, outside that tmpfs.
        writable = "/srv/var" if Path("/srv/var").is_dir() else None
        with tempfile.TemporaryDirectory(dir=writable) as directory:
            root = Path(directory)
            docker = root / "docker"
            docker.write_text("""#!/opt/venv/bin/python3
import json,os,sys
args=sys.argv[1:]
with open(os.environ['CALLS'],'a') as handle:
 handle.write(json.dumps({'args':args,'compose':os.environ.get('COMPOSE_FILE','')})+'\\n')
if args[:3]==['compose','ps','-q']: print('test-container')
if args[:2]==['inspect','--format']: print('sha256:'+'a'*64)
if args[:3]==['compose','config','--format']: print(json.dumps({'services':{'github-backup':{'image':'example:stable'}}}))
if args[:3]==['image','inspect','--format']: print('sha256:'+('a' if os.environ['SCENARIO']=='unchanged' else 'b')*64)
if '--prepare-update' in args and os.environ['SCENARIO']=='defer': sys.exit(75)
if '--wait' in args and os.environ['SCENARIO']=='failure': sys.exit(1)
""")
            docker.chmod(0o700)
            calls = root / "calls"
            script = Path(__file__).resolve().parent.parent / "ops/update.sh"
            result = subprocess.run(["sh", str(script)], env={**os.environ, "PATH": str(root) + ":" + os.environ["PATH"], "CALLS": str(calls), "SCENARIO": scenario, "UPDATE_LOCK_DIR": str(root / "lock"), "COMPOSE_FILE": "custom.yml"}, capture_output=True, text=True)
            self.assertTrue(calls.exists(), result.stderr)
            self.assertFalse((root / "lock").exists())
            return result, [json.loads(line) for line in calls.read_text().splitlines()]

    def test_busy_service_is_deferred_without_pull_or_recreation(self):
        result, calls = self.invoke("defer")
        self.assertEqual(result.returncode, 75, result.stderr)
        self.assertFalse(any("pull" in item["args"] or "up" in item["args"] for item in calls))

    def test_successful_update_waits_for_health_and_releases_lease(self):
        result, calls = self.invoke("success")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any("--prepare-update" in item["args"] for item in calls))
        self.assertTrue(any("--wait" in item["args"] for item in calls))
        self.assertTrue(any("--cancel-update" in item["args"] for item in calls))

    def test_unchanged_image_does_not_restart_service(self):
        result, calls = self.invoke("unchanged")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any("up" in item["args"] for item in calls))

    def test_failed_update_rolls_back_with_original_compose_configuration(self):
        result, calls = self.invoke("failure")
        self.assertEqual(result.returncode, 1, result.stderr)
        recreations = [item for item in calls if item["args"][:2] == ["compose", "up"]]
        self.assertEqual(len(recreations), 2)
        self.assertTrue(recreations[1]["compose"].startswith("custom.yml:"))
        self.assertNotIn("--wait", recreations[1]["args"])


if __name__ == "__main__":
    unittest.main()
