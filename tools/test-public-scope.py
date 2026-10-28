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

    def test_browser_connector_has_an_exact_source_scope(self):
        prefix = "Launcher/BrowserConnectors/IPRoyal/"
        for name in ["manifest.json", "extension-id.txt", "protocol.js", "protocol-isolated.js", "observer.js", "content.js", "background.js",
                     "popup.js", "popup.html", "popup.css", "README.md", "install.command", "prepare-kit.py",
                     "tests/protocol.test.cjs", "tests/native-host.test.py"]:
            self.write(prefix + name, "public fixture\n")
            self.git("add", prefix + name)
        self.assertEqual(self.check("--staged").returncode, 0)
        for name in ["captured-response.json", "NativeMessagingHosts/host.json", "Extension/private-profile.json"]:
            self.write(prefix + name, "must stay local\n")
            self.git("add", prefix + name)
            self.assertNotEqual(self.check("--staged").returncode, 0)
            self.git("rm", "--cached", prefix + name)

    def test_browser_connector_icons_have_an_exact_public_scope(self):
        prefix = "Launcher/BrowserConnectors/IPRoyal/"
        for size in [16, 32, 64, 128]:
            path = prefix + f"icon-{size}.png"
            target = self.repo / path
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / path, target)
            self.git("add", path)
        result = self.check("--staged")
        self.assertEqual(result.returncode, 0, result.stdout.decode())

        for name in ["icon-48.png", "icon-256.png", "icon-32@2x.png",
                     "icons/icon-32.png", "private-preview.png"]:
            with self.subTest(path=name):
                target = self.repo / prefix / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / prefix / "icon-32.png", target)
                self.git("add", prefix + name)
                self.assertNotEqual(self.check("--staged").returncode, 0)
                self.git("rm", "--cached", "-q", prefix + name)

    def test_public_signing_metadata_is_allowed(self):
        self.write("README.md", "Team: ABCD123456\nCertificate SHA-1: 0123456789012345678901234567890123456789\n")
        self.git("add", "README.md")
        self.assertEqual(self.check("--staged").returncode, 0)

    def test_mountain_assets_have_a_named_public_scope(self):
        for folder, name in [("Artwork/Workbench", "qingbi-chenwu.png"),
                             ("Resources/Workbench", "qingbi-chenwu.jpg")]:
            path = "Launcher/" + folder + "/" + name
            target = self.repo / path
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / path, target)
            self.git("add", path)
        self.assertEqual(self.check("--staged").returncode, 0)
        extra = "Launcher/Artwork/Workbench/private-preview.png"
        shutil.copyfile(ROOT / "Launcher/Artwork/Workbench/qingbi-chenwu.png", self.repo / extra)
        self.git("add", extra)
        self.assertNotEqual(self.check("--staged").returncode, 0)

    def test_minimal_brand_assets_have_an_exact_public_scope(self):
        for path in ["Launcher/Artwork/AppIcons/Minimal/minimal-ink.png",
                     "Launcher/Artwork/AppIcons/Minimal/minimal-frame.png",
                     "Launcher/Resources/AppIcons/minimal-ink.icns",
                     "Launcher/Resources/AppIcons/minimal-frame-menubar.png",
                     "Launcher/Artwork/AppIcons/provenance-minimal.json"]:
            target = self.repo / path
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / path, target)
            self.git("add", path)
        self.assertEqual(self.check("--staged").returncode, 0)
        extra = "Launcher/Artwork/AppIcons/Minimal/private-preview.png"
        shutil.copyfile(ROOT / "Launcher/Artwork/AppIcons/Minimal/minimal-ink.png", self.repo / extra)
        self.git("add", extra)
        self.assertNotEqual(self.check("--staged").returncode, 0)

    def test_desk_brand_assets_have_an_exact_public_scope(self):
        artwork = "Launcher/Artwork/AppIcons/Desk/"
        resource = "Launcher/Resources/AppIcons/"
        paths = [artwork + name for name in [
            "app-master.svg", "app-small.svg", "menu-template-16.svg",
            "menu-template-18.svg", "menu-template-20.svg", "desk-panel.png",
            "desk-small.png", "desk-small-1x.png", "desk-menubar.png",
            "desk-menubar-1x.png", "desk.iconset/icon_16x16.png",
            "desk.iconset/icon_16x16@2x.png", "desk.iconset/icon_32x32.png",
            "desk.iconset/icon_32x32@2x.png", "desk.iconset/icon_128x128.png",
            "desk.iconset/icon_128x128@2x.png", "desk.iconset/icon_256x256.png",
            "desk.iconset/icon_256x256@2x.png", "desk.iconset/icon_512x512.png",
            "desk.iconset/icon_512x512@2x.png",
        ]] + [resource + name for name in [
            "desk.icns", "desk-small.png", "desk-small-1x.png",
            "desk-menubar.png", "desk-menubar-1x.png",
        ]] + ["Launcher/Artwork/AppIcons/provenance-desk.json"]
        for path in paths:
            target = self.repo / path
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / path, target)
            self.git("add", path)
        result = self.check("--staged")
        self.assertEqual(result.returncode, 0, result.stdout.decode())

        for extra in [
            artwork + "private-preview.png", artwork + "original-02.svg",
            artwork + "app-master-draft.svg", artwork + "menu-template-24.svg",
            artwork + "desk.iconset/icon_64x64.png",
            artwork + "desk.iconset/icon_16x32.png",
            artwork + "desk.iconset/icon_16x16@3x.png",
            artwork + "drafts/menu-template-18.svg", resource + "desk-panel.png",
        ]:
            with self.subTest(path=extra):
                source = "app-master.svg" if extra.endswith(".svg") else "desk-small.png"
                target = self.repo / extra
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / artwork / source, target)
                self.git("add", extra)
                self.assertNotEqual(self.check("--staged").returncode, 0)
                self.git("rm", "--cached", "-q", extra)

    def test_only_reviewed_entitlement_template_is_public(self):
        path = "Launcher/Signing/DeskDen.entitlements"
        self.write(path, (ROOT / path).read_text())
        self.git("add", path)
        self.assertEqual(self.check("--staged").returncode, 0)
        unexpected = "Launcher/Signing/Personal.entitlements"
        self.write(unexpected, "<plist><dict/></plist>\n")
        self.git("add", unexpected)
        self.assertNotEqual(self.check("--staged").returncode, 0)

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
