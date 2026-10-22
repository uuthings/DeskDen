#!/usr/bin/env python3
"""Isolated behavior checks for publication gates; no real repository mutations."""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
CHECKER = ROOT / "tools/check-public-scope.py"


class PublicGateTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory(prefix="deskden-gate-fixture-")
        self.repo = Path(self.folder.name)
        self.git("init", "-q")
        self.git("config", "user.name", "Fixture Maintainer")
        self.git("config", "user.email", "fixture@users.noreply.github.com")
        shutil.copyfile(ROOT / ".gitleaks.toml", self.repo / ".gitleaks.toml")
        self.write("README.md", "# Harmless public fixture\n")
        self.git("add", "README.md", ".gitleaks.toml")

    def tearDown(self):
        self.folder.cleanup()

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.repo), *args], stderr=subprocess.STDOUT)

    def write(self, name, value):
        file = self.repo / name
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(value)

    def check(self, *args):
        return subprocess.run([sys.executable, str(CHECKER), "--repo", str(self.repo), *args], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    def test_index_is_not_replaced_by_worktree(self):
        private_path = "/" + "Users" + "/personal-owner/private.txt"
        self.write("README.md", private_path)
        self.assertEqual(self.check("--staged").returncode, 0)
        self.git("add", "README.md")
        result = self.check("--staged")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(private_path.encode(), result.stdout)

    def test_private_file_is_rejected(self):
        self.write("Design/private-diary.md", "Retain locally only")
        self.git("add", "Design/private-diary.md")
        self.assertNotEqual(self.check("--staged").returncode, 0)

    def test_public_signing_metadata_is_allowed(self):
        self.write("README.md", "Team: ABCD123456\nCertificate SHA-1: 0123456789012345678901234567890123456789\n")
        self.git("add", "README.md")
        self.assertEqual(self.check("--staged").returncode, 0)

    def test_secret_is_rejected_without_echo(self):
        token = "gh" + "p_" + "Ab1Cd2Ef3Gh4Ij5Kl6Mn7Op8Qr9St0Uv1Wx2"
        self.write("README.md", "token = " + token + "\n")
        self.git("add", "README.md")
        result = self.check("--staged")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(token.encode(), result.stdout)

    def test_removed_private_history_is_still_rejected(self):
        self.write("Design/old-private.md", "Old private draft")
        self.git("add", "Design/old-private.md")
        self.git("commit", "-qm", "docs: add fixture history")
        self.git("rm", "-q", "Design/old-private.md")
        self.git("commit", "-qm", "docs: remove private fixture")
        self.assertNotEqual(self.check("--all-refs").returncode, 0)
        self.assertNotEqual(self.check("--commits", "HEAD").returncode, 0)

    def test_unstaged_scanner_config_cannot_hide_staged_secret(self):
        token = "gh" + "p_" + "Ab1Cd2Ef3Gh4Ij5Kl6Mn7Op8Qr9St0Uv1Wx2"
        self.write("README.md", "token = " + token + "\n")
        self.git("add", "README.md")
        self.write(".gitleaks.toml", '[allowlist]\nregexes = [".*"]\n')
        self.assertNotEqual(self.check("--staged").returncode, 0)

    def test_commit_title_policy(self):
        message = self.repo / "message.txt"
        message.write_text("chore(release): release v0.1.0\n")
        self.assertEqual(self.check("--commit-message", str(message)).returncode, 0)
        message.write_text("Update code\n")
        self.assertNotEqual(self.check("--commit-message", str(message)).returncode, 0)

    def test_symlink_and_unexpected_binary_are_rejected(self):
        self.git("commit", "-qm", "docs: add public fixture")
        (self.repo / "README.md").unlink()
        (self.repo / "README.md").symlink_to(".gitleaks.toml")
        self.git("add", "README.md")
        self.assertNotEqual(self.check("--staged").returncode, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
