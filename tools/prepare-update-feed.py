#!/usr/bin/env python3
"""Prepare a signed Sparkle ZIP/feed from an Organizer-exported notarized App.

This tool never signs the App, submits notarization, uploads or publishes files.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import runpy
import shutil
import subprocess
import urllib.parse

ROOT = Path(__file__).resolve().parent.parent
EXPECTED_TEAM = '97K37J92QD'
EXPECTED_IDENTIFIER = 'local.fangcun.launcher'
EXPECTED_ARCHITECTURES = {'arm64', 'x86_64'}
UPDATE_POLICY = runpy.run_path(str(ROOT / 'Launcher/scripts/check-update-config.py'))
EXPORTED_INFO_KEYS = (
    'CFBundleIdentifier', 'CFBundleExecutable', 'LSMinimumSystemVersion',
    'SUFeedURL', 'SUPublicEDKey', 'SUEnableAutomaticChecks', 'SUAutomaticallyUpdate',
    'SUAllowsAutomaticUpdates', 'SUSendProfileInfo', 'SUScheduledCheckInterval',
    'SURequireSignedFeed', 'SUVerifyUpdateBeforeExtraction',
)


def exported_metadata_errors(info, expected):
    """Apply the build policy to the actual exported metadata, not its template."""
    errors = UPDATE_POLICY['configuration_errors'](info)
    for key in EXPORTED_INFO_KEYS:
        if key not in info or key not in expected or type(info[key]) is not type(expected[key]) or info[key] != expected[key]:
            errors.append('Exported App configuration does not match source: ' + key)
    executable = info.get('CFBundleExecutable')
    if not isinstance(executable, str) or not executable or Path(executable).name != executable or executable in ('.', '..'):
        errors.append('Exported App must name one executable inside Contents/MacOS')
    return errors


def exported_identity_errors(identifier, team, architectures):
    errors = []
    if identifier != EXPECTED_IDENTIFIER:
        errors.append('The signed identifier must preserve the installed App identity')
    if team != EXPECTED_TEAM:
        errors.append('The exported App must reuse the existing Developer ID team')
    if set(architectures) != EXPECTED_ARCHITECTURES:
        errors.append('The universal update must contain both arm64 and x86_64, with no other architectures')
    return errors


def verify_exported_app(app, info, runner=subprocess.run, read_output=subprocess.check_output):
    # Verification never signs or mutates the Organizer export. Gatekeeper and
    # notarization alone cannot establish the required installed signing team.
    runner(['codesign', '--verify', '--deep', '--strict', '--all-architectures', str(app)], check=True)
    display = runner(['codesign', '--display', '--verbose=4', str(app)], capture_output=True, text=True, check=True)
    identity = display.stdout + display.stderr
    identifiers = re.findall(r'^Identifier=(.+)$', identity, flags=re.M)
    teams = re.findall(r'^TeamIdentifier=(.+)$', identity, flags=re.M)
    architectures = read_output(['lipo', '-archs', str(app / 'Contents/MacOS' / info['CFBundleExecutable'])], text=True).split()
    errors = exported_identity_errors(identifiers[0] if len(identifiers) == 1 else None,
                                      teams[0] if len(teams) == 1 else None, architectures)
    if errors:
        raise SystemExit('; '.join(errors))
    requirement = ('anchor apple generic and certificate leaf[subject.OU] = "' + EXPECTED_TEAM
                   + '" and identifier "' + EXPECTED_IDENTIFIER + '"')
    runner(['codesign', '--verify', '--strict', '--all-architectures', '-R=' + requirement, str(app)], check=True)
    runner(['xcrun', 'stapler', 'validate', str(app)], check=True)
    runner(['spctl', '--assess', '--type', 'execute', str(app)], check=True)
    return {'teamIdentifier': teams[0], 'signedIdentifier': identifiers[0], 'architectures': sorted(architectures)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--sparkle-bin', type=Path, required=True)
    parser.add_argument('--notes', type=Path, required=True, help='Public plain-text release notes')
    parser.add_argument('--output', type=Path, required=True, help='New persistent directory outside Git')
    args = parser.parse_args()
    root = ROOT
    app, output = args.app.resolve(), args.output.resolve()
    if output.exists() or output.is_relative_to(root):
        raise SystemExit('Use a new persistent output directory outside the repository')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    expected = plistlib.loads((root / 'Launcher/Resources/Info.plist').read_bytes())
    errors = exported_metadata_errors(info, expected)
    if errors:
        raise SystemExit('; '.join(errors))
    version, build = info['CFBundleShortVersionString'], info['CFBundleVersion']
    if not re.fullmatch(r'\d+\.\d+\.\d+', version) or not re.fullmatch(r'\d+(?:\.\d+)*', build):
        raise SystemExit('Invalid release version or Build')
    tools = args.sparkle_bin.resolve()
    for name in ['generate_appcast', 'sign_update', 'generate_keys']:
        if not (tools / name).is_file():
            raise SystemExit('Missing official Sparkle tool: ' + name)
    notes = args.notes.read_text()
    if not notes.strip():
        raise SystemExit('Public release notes are empty')
    signing = verify_exported_app(app, info)
    public_key = subprocess.check_output([str(tools / 'generate_keys'), '--account', 'local.fangcun.launcher', '-p'], text=True).strip()
    if public_key != info['SUPublicEDKey']:
        raise SystemExit('The existing update signing key does not match the exported App; do not rotate it')
    output.mkdir(parents=True)
    name = 'Fangcun-' + version + '-macos-universal'
    archive = output / (name + '.zip')
    subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(archive)], check=True)
    (output / (name + '.txt')).write_text(notes)
    shutil.copy2(root / 'updates/appcast.xml', output / 'appcast.xml')
    feed = output / 'appcast.xml'
    feed.write_text(feed.read_text().replace('Signed updates for Fangcun. No public update has been published.',
                                             'Official signed software updates for Fangcun.'))
    prefix = 'https://github.com/uuthings/DeskDen/releases/download/v' + urllib.parse.quote(version) + '/'
    command = [str(tools / 'generate_appcast'), '--account', 'local.fangcun.launcher',
               '--download-url-prefix', prefix, '--embed-release-notes', str(output)]
    result = subprocess.run(command, capture_output=True)
    (output / 'generate-appcast.log').write_bytes(result.stdout + result.stderr)
    if result.returncode:
        raise SystemExit('Appcast generation failed; candidate and log retained, nothing published')
    subprocess.run([str(tools / 'sign_update'), '--account', 'local.fangcun.launcher', '--verify', str(output / 'appcast.xml')], check=True)
    hashes = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in [archive, output / 'appcast.xml']}
    (output / 'SHA256SUMS.txt').write_text(''.join(value + '  ' + key + '\n' for key, value in hashes.items()))
    (output / 'update-preparation.json').write_text(json.dumps({'version': version, 'build': build, 'downloadPrefix': prefix,
        'appNotReSigned': True, 'notarizedAppValidated': True, 'signing': signing, 'uploaded': False, 'hashes': hashes}, indent=2) + '\n')
    print('Signed update files prepared locally; no upload, tag or Release was created.')


if __name__ == '__main__':
    main()
