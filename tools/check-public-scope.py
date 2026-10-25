#!/usr/bin/env python3
"""Check staged blobs or complete reachable history, never unstaged substitutes."""
import argparse
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
ALLOWED = [
    r"(?:README\.md|LICENSE|\.gitignore|\.gitleaks\.toml)",
    r"Fangcun\.xcodeproj/(?:project\.pbxproj|xcshareddata/xcschemes/Fangcun\.xcscheme|project\.xcworkspace/xcshareddata/swiftpm/Package\.resolved)",
    r"updates/appcast\.xml",
    r"Launcher/(?:Package\.swift|Package\.resolved|README\.md)",
    r"Launcher/Sources/(?:FangcunLauncher|LauncherCore)/[A-Za-z0-9_]+\.swift",
    r"Launcher/Tests/(?:LauncherCoreTests|WorkbenchChecks)/[A-Za-z0-9_]+\.swift",
    r"Launcher/scripts/[a-z0-9-]+\.(?:sh|py|swift)",
    r"Launcher/Signing/Fangcun\.entitlements",
    r"Launcher/Resources/(?:Info\.plist|AppIcon\.icns|PanelLogo\.png)",
    r"Launcher/Resources/Workbench/(?:(?:ar-world|thunder-cabin|qingbi-chenwu|yuebai-yunhai|nuanxia-xuanshan)\.jpg|(?:chatgpt|claude)\.png)",
    r"Launcher/Artwork/Workbench/(?:(?:qingbi-chenwu|yuebai-yunhai|nuanxia-xuanshan)\.png|README\.md|provenance\.json)",
    r"Launcher/(?:Resources/AppIcons/minimal-(?:ink|frame)(?:\.icns|-menubar\.png)|Artwork/AppIcons/(?:Minimal/minimal-(?:ink|frame)\.png|provenance-minimal\.json))",
    r"Launcher/Artwork/AppIcons/Desk/(?:app-(?:master|small)\.svg|menu-template-(?:16|18|20)\.svg|desk-(?:panel|small(?:-1x)?|menubar(?:-1x)?)\.png|desk\.iconset/icon_(?:16x16|32x32|128x128|256x256|512x512)(?:@2x)?\.png)",
    r"Launcher/Artwork/AppIcons/provenance-desk\.json",
    r"Launcher/Resources/AppIcons/desk(?:\.icns|-(?:small|menubar)(?:-1x)?\.png)",
    r"Launcher/(?:Resources/AppIcons/(?:qingbi-chenwu|yuebai-yunhai|nuanxia-xuanshan)\.icns|Artwork/AppIcons/(?:(?:qingbi-chenwu|yuebai-yunhai|nuanxia-xuanshan)\.png|README\.md|provenance\.json))",
    r"docs/[a-z0-9-]+\.md",
    r"tools/[a-z0-9-]+\.(?:py|sh|json)",
    r"\.githooks/(?:pre-commit|commit-msg|pre-push)",
    r"\.github/workflows/(?:public-checks|verify)\.yml",
]
PRIVATE_PATH = re.compile(rb"/(?:Users|home)/(?!test(?:/|[\"']))[^/\s\"']+")
PRIVATE_KEY = re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----")
TITLE = re.compile(r"(?:feat|fix|refactor|perf|style|docs|test|build|ci|chore|revert)(?:\([A-Za-z0-9._/-]+\))?!?: [A-Za-z].+")


def git(*args):
    return subprocess.check_output(["git", "-C", str(ROOT), *args])


def title_errors(title):
    return [] if TITLE.fullmatch(title) and not re.search(r"[\u3400-\u9fff]", title) else ["Commit title must use an English conventional commit"]


def entries(tree=None):
    if tree:
        rows = git("ls-tree", "-rz", "--full-tree", tree).split(b"\0")
        for row in filter(None, rows):
            head, path = row.split(b"\t", 1)
            mode, kind, oid = head.decode().split()
            yield mode, oid, os.fsdecode(path)
    else:
        for row in filter(None, git("ls-files", "--stage", "-z").split(b"\0")):
            head, path = row.split(b"\t", 1)
            mode, oid, stage = head.decode().split()
            if stage != "0":
                raise RuntimeError("Unmerged index cannot be published")
            yield mode, oid, os.fsdecode(path)


def check_blob(mode, oid, path):
    errors = []
    if not any(re.fullmatch(pattern, path) for pattern in ALLOWED):
        return [f"Outside public allowlist: {path}"], None
    if mode not in {"100644", "100755"}:
        return [f"Non-regular file is forbidden: {path}"], None
    data = git("cat-file", "blob", oid)
    if len(data) > 8 * 1024 * 1024:
        errors.append(f"Public file exceeds 8 MiB: {path}")
    extension = Path(path).suffix.lower()
    signatures = {".png": b"\x89PNG\r\n\x1a\n", ".jpg": b"\xff\xd8\xff", ".icns": b"icns"}
    if extension in signatures:
        if not data.startswith(signatures[extension]):
            errors.append(f"Unexpected binary type: {path}")
    else:
        try:
            data.decode("utf-8")
        except UnicodeDecodeError:
            errors.append(f"Expected UTF-8 public source: {path}")
        if b"\0" in data:
            errors.append(f"Binary content in text source: {path}")
        if PRIVATE_PATH.search(data):
            errors.append(f"Machine-local home path: {path}")
        if PRIVATE_KEY.search(data):
            errors.append(f"Private key material: {path}")
    return errors, data


def main():
    global ROOT
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--staged", action="store_true")
    mode.add_argument("--all-refs", action="store_true")
    mode.add_argument("--commits", nargs="+")
    parser.add_argument("--repo", type=Path, default=ROOT, help=argparse.SUPPRESS)
    parser.add_argument("--commit-message", type=Path)
    args = parser.parse_args()
    ROOT = args.repo.resolve()
    if args.commit_message:
        title = args.commit_message.read_text().splitlines()[0]
        errors = title_errors(title)
        if errors:
            raise SystemExit("\n".join(errors))
        print("Public commit title verified")
        return
    commits = []
    if args.all_refs:
        commits = git("rev-list", "--all").decode().splitlines()
    elif args.commits:
        commits = git("rev-list", *args.commits).decode().splitlines()
    if (args.all_refs or args.commits) and not commits:
        raise SystemExit("No reachable commits to verify")
    errors, seen, metadata = [], set(), []
    for commit in commits:
        raw = git("show", "-s", "--format=%s%x00%ae%x00%ce%x00%B", commit)
        title, author, committer, body = raw.decode().split("\0", 3)
        errors += [f"{commit[:12]}: {error}" for error in title_errors(title)]
        if PRIVATE_PATH.search(raw) or PRIVATE_KEY.search(raw):
            errors.append(f"{commit[:12]}: private metadata in commit")
        metadata.append(raw)
    with tempfile.TemporaryDirectory(prefix="deskden-public-check-") as folder:
        snapshot = Path(folder) / "snapshot"
        snapshot.mkdir()
        for tree in commits or [None]:
            for mode_value, oid, path in entries(tree):
                key = (mode_value, oid, path)
                if key in seen:
                    continue
                seen.add(key)
                found, data = check_blob(*key)
                errors.extend(found)
                if data is not None:
                    target = snapshot / oid / path
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(data)
        if errors:
            raise SystemExit("\n".join(sorted(set(errors))))
        (snapshot / "commit-metadata.txt").write_bytes(b"\n".join(metadata))
        checker = Path(__file__).with_name("ensure-gitleaks.py")
        executable = subprocess.check_output([sys.executable, str(checker)], text=True).strip()
        report = Path(folder) / "report.json"
        # Scanner policy must not be weakened by an unstaged working-tree config.
        scanner_config = Path(folder) / "gitleaks.toml"
        scanner_config.write_text('[extend]\nuseDefault = true\n')
        command = [executable, "dir", str(snapshot), "--no-banner", "--redact=100", "--exit-code=1", "--log-level=error", "--report-format=json", "--report-path", str(report), "--config", str(scanner_config)]
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if result.returncode:
            # Do not echo scanner output or secret values. Only report affected paths/rules.
            import json
            try:
                findings = json.loads(report.read_text())
                for finding in findings:
                    print("Secret scanner: " + finding.get("RuleID", "unknown") + " in " + finding.get("File", "unknown"), file=sys.stderr)
            except (ValueError, OSError):
                print("Required Gitleaks scan failed; no findings were disclosed", file=sys.stderr)
            raise SystemExit(1)
    print(f"Public scope and Gitleaks 8.30.1 verified: {len(seen)} file versions; {len(commits)} commits")


if __name__ == "__main__":
    main()
