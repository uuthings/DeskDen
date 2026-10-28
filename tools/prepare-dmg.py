#!/usr/bin/env python3
"""Prepare and verify a signed DMG from an existing notarized Organizer export.

This tool never builds or re-signs the App, submits notarization, edits a feed,
uploads files, or creates a tag/Release. The DMG still needs container notarization.
"""
import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import tempfile
import uuid


ROOT = Path(__file__).resolve().parent.parent
IDENTIFIER = 'local.fangcun.launcher'
TEAM = '97K37J92QD'
ARCHITECTURES = {'arm64', 'x86_64'}


def digest(path):
    hasher = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            hasher.update(block)
    return hasher.hexdigest()


def manifest(root):
    """Compare file bytes, modes and link targets without following bundle links."""
    result = {}

    def visit(path):
        relative = path.relative_to(root).as_posix()
        metadata = path.lstat()
        mode = stat.S_IMODE(metadata.st_mode)
        if stat.S_ISLNK(metadata.st_mode):
            target = os.readlink(path)
            resolved = (path.parent / target).resolve()
            if Path(target).is_absolute() or not resolved.is_relative_to(root.resolve()):
                raise ValueError('App contains an external symbolic link: ' + relative)
            result[relative] = {'kind': 'link', 'target': target}
        elif stat.S_ISREG(metadata.st_mode):
            result[relative] = {'kind': 'file', 'mode': mode, 'bytes': metadata.st_size, 'sha256': digest(path)}
        elif stat.S_ISDIR(metadata.st_mode):
            result[relative] = {'kind': 'directory', 'mode': mode}
            for child in sorted(path.iterdir()):
                visit(child)
        else:
            raise ValueError('App contains an unsupported file type: ' + relative)

    visit(root)
    return result


def manifest_digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def write_json(path, value):
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
    temporary.replace(path)


def validate_output(output, release):
    if output.exists() or output.is_symlink():
        raise ValueError('Use a new output directory; existing files are never overwritten')
    if output.is_relative_to(ROOT) or output.is_relative_to(release) or release.is_relative_to(output):
        raise ValueError('Output must be outside the repository and the original release archive')
    if any(part in {'.build', 'build', 'DerivedData', 'Caches'} for part in output.parts):
        raise ValueError('Output must be persistent, outside build and cache directories')
    if any(output.is_relative_to(Path(p)) for p in ['/tmp', '/private/tmp', '/private/var/folders']):
        raise ValueError('Output must not be in a temporary directory')


def accepted_submission(log, submission):
    try:
        return (uuid.UUID(log['jobId']) == uuid.UUID(submission)
                and log.get('status') == 'Accepted' and log.get('statusCode') == 0)
    except (KeyError, ValueError, AttributeError, TypeError):
        return False


def read_provenance(release):
    metadata_path = release / 'RELEASE_METADATA.json'
    metadata = json.loads(metadata_path.read_text())
    version, build, commit = metadata.get('version'), str(metadata.get('build', '')), metadata.get('sourceCommit')
    if not isinstance(version, str) or not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise ValueError('Release metadata has an invalid version')
    if not re.fullmatch(r'\d+(?:\.\d+)*', build) or not isinstance(commit, str) or not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise ValueError('Release metadata must identify its Build and full source commit')
    notary = metadata.get('notarization', {})
    submission = metadata.get('notarizationSubmissionID', notary.get('submissionID'))
    if metadata.get('notarizationStatus', notary.get('status')) != 'Accepted':
        raise ValueError('The original App notarization was not accepted')
    if not isinstance(submission, str) or not re.fullmatch(r'[0-9A-Fa-f-]{36}', submission):
        raise ValueError('Missing original App notarization submission')
    archive = Path(metadata['organizerArchive']).expanduser()
    if archive.is_symlink() or archive.suffix != '.xcarchive' or not archive.is_dir():
        raise ValueError('The original real Organizer archive is required')
    properties = plistlib.loads((archive / 'Info.plist').read_bytes())['ApplicationProperties']
    expected = {'CFBundleIdentifier': IDENTIFIER, 'CFBundleShortVersionString': version, 'CFBundleVersion': build, 'Team': TEAM}
    if any(str(properties.get(key, '')) != value for key, value in expected.items()):
        raise ValueError('Organizer archive identity does not match the release metadata')
    submission_root = archive / 'Submissions' / submission
    apple_log = json.loads((submission_root / 'notarization-log.json').read_text())
    if not accepted_submission(apple_log, submission):
        raise ValueError('The original Organizer submission log does not match')
    app = release / 'Export' / '方寸.app'
    if app.is_symlink() or not app.is_dir():
        raise ValueError('A complete original Export/方寸.app is required')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if any(str(info.get(key, '')) != value for key, value in expected.items() if key != 'Team'):
        raise ValueError('Exported App identity does not match the archive')
    executable = info.get('CFBundleExecutable')
    if not isinstance(executable, str) or Path(executable).name != executable or executable in {'.', '..'}:
        raise ValueError('Invalid App executable')
    submitted_app = submission_root / '方寸.app'
    if not submitted_app.is_dir() or submitted_app.is_symlink():
        raise ValueError('Original Organizer submitted App is missing')
    return app, submitted_app, info, {
        'version': version, 'build': build, 'sourceCommit': commit,
        'sourceReleaseDirectory': str(release), 'sourceMetadataSHA256': digest(metadata_path),
        'originalDistributionScope': metadata.get('distributionScope', 'published' if metadata.get('publishedAt') else 'not-recorded'),
        'originalPublishedAt': metadata.get('publishedAt'), 'organizerArchive': str(archive),
        'appNotarizationSubmissionID': submission, 'appNotarizationStatus': 'Accepted',
        'appNotarizationLogSHA256': digest(submission_root / 'notarization-log.json'),
    }


class Recorder:
    def __init__(self, directory):
        self.directory = directory / 'Logs'
        self.directory.mkdir()

    def run(self, label, *command):
        command = [str(part) for part in command]
        result = subprocess.run(command, capture_output=True, timeout=180)
        (self.directory / (label + '.stdout')).write_bytes(result.stdout)
        (self.directory / (label + '.stderr')).write_bytes(result.stderr)
        write_json(self.directory / (label + '.json'), {'command': command, 'exitCode': result.returncode})
        if result.returncode:
            raise RuntimeError(label + ' failed; see its retained log')
        return result.stdout, result.stderr


def signature_details(recorder, label, path, architecture=None):
    command = ['codesign', '--display', '--verbose=4']
    if architecture:
        command += ['--arch', architecture]
    stdout, stderr = recorder.run(label, *command, path)
    return (stdout + stderr).decode()


def cleanup_workspace(workspace, mount, dmg, runner=subprocess.run):
    """Detach only this image; never traverse a mounted or uncertain workspace."""
    evidence = []

    def run(*command):
        result = runner([str(part) for part in command], capture_output=True, timeout=30)
        evidence.append({'command': [str(part) for part in command], 'exitCode': result.returncode,
                         'stdout': result.stdout.decode(errors='replace'), 'stderr': result.stderr.decode(errors='replace')})
        if result.returncode:
            raise RuntimeError('Workspace cleanup failed; retained ' + str(workspace))
        return result.stdout

    def mounts():
        information = plistlib.loads(run('hdiutil', 'info', '-plist'))
        found = []
        for image in information.get('images', []):
            for entity in image.get('system-entities', []):
                point = entity.get('mount-point')
                if point and Path(point).resolve().is_relative_to(workspace.resolve()):
                    found.append((Path(point).resolve(), Path(image.get('image-path', '')).resolve()))
        return found

    try:
        active = mounts()
        if active and active != [(mount.resolve(), dmg.resolve())]:
            raise RuntimeError('Unexpected mounted volume; retained ' + str(workspace))
        if active:
            run('hdiutil', 'detach', mount)
        if mounts():
            raise RuntimeError('Volume is still mounted; retained ' + str(workspace))
        shutil.rmtree(workspace)
    finally:
        # Evidence writes happen after cleanup attempts, so a log-write failure
        # cannot prevent us from trying to detach a successfully attached image.
        write_json(workspace.parent / 'workspace-cleanup.json', evidence)


@contextmanager
def packaging_workspace(output, dmg, runner=subprocess.run):
    workspace = Path(tempfile.mkdtemp(prefix='.packaging-', dir=output))
    try:
        yield workspace
    finally:
        # An attach error/timeout does not establish that attachment failed.
        cleanup_workspace(workspace, workspace / 'Mounted', dmg, runner)


def verify_app(recorder, label, app, info):
    recorder.run(label + '-codesign', 'codesign', '--verify', '--deep', '--strict', '--all-architectures', app)
    for architecture in sorted(ARCHITECTURES):
        detail = signature_details(recorder, label + '-' + architecture, app, architecture)
        if ('Identifier=' + IDENTIFIER + '\n' not in detail or 'TeamIdentifier=' + TEAM + '\n' not in detail
                or 'Authority=Developer ID Application:' not in detail or 'Timestamp=' not in detail
                or not re.search(r'flags=.*\bruntime\b', detail)):
            raise ValueError('App is missing its expected Developer ID, runtime or timestamp')
    arches, _ = recorder.run(label + '-architectures', 'lipo', '-archs', app / 'Contents/MacOS' / info['CFBundleExecutable'])
    if set(arches.decode().split()) != ARCHITECTURES:
        raise ValueError('App must preserve both original Mac architectures')
    recorder.run(label + '-stapler', 'xcrun', 'stapler', 'validate', app)
    recorder.run(label + '-gatekeeper', 'spctl', '--assess', '--type', 'execute', '--verbose=4', app)


def verify_origin(recorder, app, submitted):
    values = {}
    for architecture in sorted(ARCHITECTURES):
        pair = []
        for label, path in [('export', app), ('submitted', submitted)]:
            detail = signature_details(recorder, 'origin-' + label + '-' + architecture, path, architecture)
            matches = re.findall(r'^CDHash=([0-9a-fA-F]{40})$', detail, re.M)
            if len(matches) != 1:
                raise ValueError('Cannot identify original signed App code hash')
            pair.append(matches[0])
        if pair[0] != pair[1]:
            raise ValueError('Export differs from the original Organizer submitted App')
        values[architecture] = pair[0]
    return values


def prepare(release, output, identity):
    if not re.fullmatch(r'[0-9a-fA-F]{40}', identity):
        raise ValueError('Use the existing Developer ID certificate SHA-1; no key is generated')
    validate_output(output, release)
    app, submitted, info, provenance = read_provenance(release)
    before = manifest(app)
    output.mkdir(parents=True)
    recorder = Recorder(output)
    state = {'schema': 'fangcun.dmg-preparation/1', 'state': 'preparing',
             'createdAt': datetime.now(timezone.utc).isoformat(), **provenance,
             'containerSigningCertificateSHA1': identity, 'containerNotarizationSubmitted': False,
             'containerNotarizationStatus': 'not-submitted', 'published': False,
             'releaseReady': False, 'existingFeedChanged': False, 'originalAppResigned': False}
    write_json(output / 'preparation.json', state)
    write_json(output / 'source-app-manifest.json', before)
    try:
        verify_app(recorder, 'source-app', app, info)
        state['originalAppCodeHashes'] = verify_origin(recorder, app, submitted)
        state['sourceAppManifestSHA256'] = manifest_digest(before)
        dmg = output / ('DeskDen-' + info['CFBundleShortVersionString'] + '-macos-universal.dmg')
        with packaging_workspace(output, dmg) as workspace:
            layout = workspace / 'Layout'
            layout.mkdir()
            recorder.run('copy-app', 'ditto', app, layout / app.name)
            if manifest(layout / app.name) != before:
                raise ValueError('App copy changed content, permissions or symbolic links')
            (layout / 'Applications').symlink_to('/Applications', target_is_directory=True)
            recorder.run('create-dmg', 'hdiutil', 'create', '-volname', 'DeskDen', '-srcfolder', layout,
                         '-fs', 'APFS', '-format', 'ULFO', dmg)
            recorder.run('sign-dmg', 'codesign', '--sign', identity, '--timestamp', dmg)
            recorder.run('verify-dmg-signature', 'codesign', '--verify', '--strict', dmg)
            detail = signature_details(recorder, 'dmg-signature', dmg)
            if 'TeamIdentifier=' + TEAM + '\n' not in detail or 'Authority=Developer ID Application:' not in detail or 'Timestamp=' not in detail:
                raise ValueError('DMG does not have the expected Developer ID signature')
            recorder.run('verify-image', 'hdiutil', 'verify', dmg)
            mount = workspace / 'Mounted'
            mount.mkdir()
            recorder.run('mount-readonly', 'hdiutil', 'attach', '-readonly', '-nobrowse', '-noautoopen',
                         '-mountpoint', mount, '-plist', dmg)
            if not (mount / 'Applications').is_symlink() or os.readlink(mount / 'Applications') != '/Applications':
                raise ValueError('DMG is missing its Applications drag-install target')
            if manifest(mount / app.name) != before:
                raise ValueError('Mounted DMG App changed content, permissions or symbolic links')
            verify_app(recorder, 'mounted-app', mount / app.name, info)
            state['mountedAppMatchesOriginal'] = True
            state['applicationsLinkVerified'] = True
        if manifest(app) != before or digest(release / 'RELEASE_METADATA.json') != provenance['sourceMetadataSHA256']:
            raise ValueError('Original App or release metadata changed during preparation')
        state.update(state='signed-awaiting-container-notarization', originalAppUnchanged=True,
                     dmg=dmg.name, dmgBytes=dmg.stat().st_size, preparedDMGSHA256=digest(dmg),
                     containerSignatureVerified=True, appSignatureAndTicketVerified=True,
                     dragInstallPerformed=False, freshLaunchPerformed=False, automaticUpgradePerformed=False,
                     completedAt=datetime.now(timezone.utc).isoformat())
        (output / 'PREPARATION-SHA256SUMS.txt').write_text(state['preparedDMGSHA256'] + '  ' + dmg.name + '\n')
        (output / 'README.md').write_text(
            '# Local DMG supplement\n\n'
            'State: **signed, awaiting separate container notarization**. Not published or release-ready.\n\n'
            'The DMG contains the unchanged, already notarized Organizer-exported App and an Applications link. '
            'The original release archive, ZIP, feed and version are unchanged. '
            'This preparation does not install or launch the App.\n\n'
            'Before publication, complete the separately authorized DMG notarization and stapling workflow. '
            'Keep this submitted input unchanged; staple a distinct copy and record its final hash and verification. '
            'PREPARATION-SHA256SUMS.txt describes these pre-stapling bytes, not the final publication bytes. '
            'Record Finder installation, launch and any update test separately; mounting alone does not prove them.\n')
        write_json(output / 'preparation.json', state)
        return state
    except Exception as error:
        state.update(state='preparation-failed', error=str(error), originalAppUnchanged=manifest(app) == before)
        write_json(output / 'preparation.json', state)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--release-directory', required=True, type=Path, help='Original durable archive with RELEASE_METADATA.json and Export/方寸.app')
    parser.add_argument('--output', required=True, type=Path, help='New persistent directory outside Git and the original archive')
    parser.add_argument('--identity', required=True, help='Existing Developer ID Application certificate SHA-1')
    args = parser.parse_args()
    try:
        if args.output.expanduser().is_symlink() or args.release_directory.expanduser().is_symlink():
            raise ValueError('Release and output directories must not be symbolic links')
        result = prepare(args.release_directory.expanduser().resolve(), args.output.expanduser().resolve(), args.identity)
    except (ValueError, RuntimeError, OSError, KeyError, subprocess.SubprocessError) as error:
        parser.exit(1, str(error) + '\n')
    print(result['dmg'] + ': signed and verified locally; container notarization and publication remain pending.')


if __name__ == '__main__':
    main()
