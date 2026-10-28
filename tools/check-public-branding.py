#!/usr/bin/env python3
"""Check public naming and release copy without network access or mutations."""
import argparse
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent
CONNECTOR = 'DeskDen IPRoyal Connector'
INTERNAL_COPY = re.compile(r'未倒填|本地版本交付|本地已公证交付|本页为现在补建|原始 Organizer 导出物|DMG 安装包补充|未重新构建|未重新签名|精校候选')


def release_errors(value):
    errors = []
    tag = value.get('tag_name', '')
    if not re.fullmatch(r'v\d+\.\d+\.\d+', tag):
        return ['Release must have a version tag']
    if value.get('name') != 'DeskDen ' + tag:
        errors.append('Release title must be DeskDen followed by its version tag')
    body = value.get('body', '')
    if not isinstance(body, str) or not body.strip():
        return errors + ['Release notes must not be empty']
    if INTERNAL_COPY.search(body):
        errors.append('Internal packaging or handoff copy belongs in the private archive')
    filename = 'DeskDen-' + tag[1:] + '-macos-universal.dmg'
    url = 'https://github.com/uuthings/DeskDen/releases/download/' + tag + '/' + filename
    if url not in body:
        errors.append('Release must link to its own DeskDen DMG')
    names = [a.get('name') for a in value.get('assets', [])]
    assets = set(names)
    if len(names) != len(assets):
        errors.append('Release contains duplicate asset names')
    allowed = {filename, filename.removesuffix('.dmg') + '.zip', 'SHA256SUMS.txt'}
    component_pattern = r'DeskDen-IPRoyal-Connector-\d+\.\d+\.\d+-chrome-macos\.zip'
    for name in names:
        if not isinstance(name, str) or (name not in allowed and not re.fullmatch(component_pattern, name)):
            errors.append('Unexpected release asset name: ' + str(name))
    if CONNECTOR in body and not any(isinstance(n, str) and re.fullmatch(component_pattern, n) for n in names):
        errors.append('The documented optional connector needs a downloadable distribution package')
    if filename not in assets:
        errors.append('Declared release assets are missing the DeskDen DMG')
    checksum_links = re.findall(r'https://github\.com/uuthings/DeskDen/releases/download/' + re.escape(tag) + r'/(SHA256SUMS[^\s)\]]*\.txt)', body)
    if checksum_links != ['SHA256SUMS.txt'] or 'SHA256SUMS.txt' not in assets:
        errors.append('Release must link to its single SHA256SUMS.txt manifest')
    return errors


def checksum_errors(value, text):
    expected = {a['name']: a.get('digest') for a in value.get('assets', []) if a.get('name', '').endswith(('.dmg', '.zip'))}
    actual = {}
    errors = []
    for line in text.splitlines():
        match = re.fullmatch(r'([0-9a-f]{64})  ([^/\\]+)', line)
        if not match or match[2] in actual:
            errors.append('Invalid or duplicate checksum entry')
        else:
            actual[match[2]] = match[1]
    if set(actual) != set(expected):
        errors.append('Checksum manifest must cover exactly all downloadable binary assets')
    for name, digest in expected.items():
        if digest and digest != 'sha256:' + actual.get(name, ''):
            errors.append('Checksum does not match published asset: ' + name)
    return errors


def source_errors(staged=False):
    errors = []
    def read(path):
        return subprocess.check_output(['git', '-C', str(ROOT), 'show', ':' + path], text=True) if staged else (ROOT / path).read_text()
    folder = 'Launcher/BrowserConnectors/IPRoyal/'
    manifest = json.loads(read(folder + 'manifest.json'))
    if not re.fullmatch(r'\d+\.\d+\.\d+', str(manifest.get('version', ''))):
        errors.append('Connector version must use X.Y.Z')
    if manifest.get('name') != CONNECTOR or manifest.get('action', {}).get('default_title') != CONNECTOR:
        errors.append('Extension name and toolbar title must use the public connector name')
    if '<title>' + CONNECTOR + '</title>' not in read(folder + 'popup.html'):
        errors.append('Extension popup title must use the public connector name')
    guide = read('docs/install.md')
    first_step = next((line for line in guide.splitlines() if line.startswith('1. ')), '')
    if not re.search(r'DeskDen-\d+\.\d+\.\d+-macos-universal\.dmg', first_step):
        errors.append('First installation must recommend a DeskDen DMG')
    return errors


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--release-json', type=Path)
    parser.add_argument('--checksums', type=Path, help='Downloaded or prepared SHA256SUMS.txt for the given release')
    parser.add_argument('--staged', action='store_true', help='Check exact index blobs for commit hooks')
    args = parser.parse_args()
    errors = source_errors(args.staged)
    if args.release_json:
        release = json.loads(args.release_json.read_text())
        errors.extend(release_errors(release))
        if args.checksums:
            errors.extend(checksum_errors(release, args.checksums.read_text()))
    print(json.dumps({'passed': not errors, 'errors': errors}, ensure_ascii=False))
    raise SystemExit(bool(errors))
