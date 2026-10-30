"""Regression tests for checks that must cover a committed PR, not just dirty files."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("check_pr", Path(__file__).resolve().parents[1] / "check_pr.py")
check_pr = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check_pr)


class WhitespaceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.git("init", "-q")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        (self.root / "photo.txt").write_text("clean\n")
        self.git("add", ".")
        self.git("commit", "-qm", "base")
        self.git("branch", "base")

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.root, stderr=subprocess.STDOUT)

    def codes(self):
        _, commands = check_pr.whitespace_commands(self.root, "base")
        return [subprocess.run(c, cwd=self.root, capture_output=True).returncode for c in commands]

    def test_clean_committed_change_passes(self):
        (self.root / "photo.txt").write_text("changed\n")
        self.git("commit", "-qam", "change")
        self.assertTrue(all(code == 0 for code in self.codes()))

    def test_committed_whitespace_fails_on_clean_checkout(self):
        (self.root / "photo.txt").write_text("bad  \n")
        self.git("commit", "-qam", "change")
        self.assertEqual(self.git("status", "--porcelain"), b"")
        self.assertTrue(any(self.codes()))

    def test_uncommitted_and_staged_whitespace_fail(self):
        (self.root / "photo.txt").write_text("bad  \n")
        self.assertTrue(any(self.codes()))
        self.git("add", ".")
        self.assertTrue(any(self.codes()))

    def test_new_file_whitespace_fails(self):
        (self.root / "new file.txt").write_text("bad  \n")
        self.assertTrue(any(self.codes()))

    def test_unrelated_base_branch_whitespace_is_excluded(self):
        (self.root / "photo.txt").write_text("feature\n")
        self.git("commit", "-qam", "feature")
        feature = self.git("rev-parse", "HEAD").decode().strip()
        self.git("checkout", "-q", "base")
        (self.root / "base-only.txt").write_text("base whitespace  \n")
        self.git("add", ".")
        self.git("commit", "-qm", "base advanced")
        self.git("checkout", "-q", feature)
        self.assertTrue(all(code == 0 for code in self.codes()))
