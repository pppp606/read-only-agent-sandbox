import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("snapshot", "host/prepare_snapshot.py")
snapshot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(snapshot)

def git(repo, *args):
    subprocess.run(["git", "-C", str(repo), *args], check=True, stdout=subprocess.DEVNULL)

class SnapshotTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "repo"
        self.root.mkdir()
        git(self.root, "init", "-q")
        git(self.root, "config", "user.email", "test@example.invalid")
        git(self.root, "config", "user.name", "Test")

    def commit(self):
        git(self.root, "add", "-A")
        git(self.root, "commit", "-qm", "fixture")

    def test_only_tracked_files_and_metadata_history(self):
        (self.root / "main.py").write_text("print('safe')\n")
        (self.root / ".env").write_text("TOKEN=secret")
        (self.root / "link").symlink_to("/etc/passwd")
        self.commit()
        # Created after the commit so it is genuinely untracked.
        (self.root / "untracked.txt").write_text("not copied")
        out = Path(self.temp.name) / "out"
        snapshot.prepare(self.root, out, 5)
        self.assertTrue((out / "source/main.py").exists())
        self.assertFalse((out / "source/.env").exists())
        self.assertFalse((out / "source/link").exists())
        self.assertFalse((out / "source/untracked.txt").exists())
        self.assertFalse((out / "source/.git").exists())
        self.assertIn("fixture", (out / "history.txt").read_text())

    def test_excludes_agent_extension_points(self):
        (self.root / "main.py").write_text("ok\n")
        (self.root / ".mcp.json").write_text("{}")
        (self.root / ".claude").mkdir()
        (self.root / ".claude" / "settings.json").write_text('{"hooks": {}}')
        self.commit()
        out = Path(self.temp.name) / "out"
        snapshot.prepare(self.root, out, 1)
        self.assertTrue((out / "source/main.py").exists())
        self.assertFalse((out / "source/.mcp.json").exists())
        self.assertFalse((out / "source/.claude").exists())

    def test_empty_repository_is_rejected_cleanly(self):
        with self.assertRaises(ValueError):
            snapshot.prepare(self.root, Path(self.temp.name) / "out", 1)

    def test_detects_known_secret_marker(self):
        (self.root / "bad.txt").write_text("-----BEGIN OPENSSH PRIVATE KEY-----")
        self.commit()
        with self.assertRaises(ValueError):
            snapshot.prepare(self.root, Path(self.temp.name) / "out", 1)

    def test_rejects_output_inside_repo(self):
        (self.root / "a.txt").write_text("ok")
        self.commit()
        with self.assertRaises(ValueError):
            snapshot.prepare(self.root, self.root / "snapshot", 1)

if __name__ == "__main__":
    unittest.main()
