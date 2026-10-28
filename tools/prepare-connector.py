#!/usr/bin/env python3
"""Build a generic connector ZIP from an exact source allowlist; never install it."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import runpy
import stat
import zipfile

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / 'Launcher/BrowserConnectors/IPRoyal'


def prepare(output):
    output = output.absolute()
    if output.exists() or output.is_relative_to(ROOT):
        raise ValueError('Use a new output directory outside the repository')
    manifest = json.loads((SOURCE / 'manifest.json').read_text())
    version = manifest['version']
    if not re.fullmatch(r'\d+\.\d+\.\d+', version) or manifest['name'] != 'DeskDen IPRoyal Connector':
        raise ValueError('Unexpected connector name or version')
    files = runpy.run_path(str(SOURCE / 'prepare-kit.py'))['FILES']
    entries = {'Extension/' + name: SOURCE / name for name in files}
    entries.update({'install.command': SOURCE / 'install.command', 'README.md': SOURCE / 'INSTALL.md'})
    payload = {}
    for name, path in entries.items():
        if path.is_symlink() or not path.is_file():
            raise ValueError('Distribution sources must be regular files')
        data = path.read_bytes()
        if path.suffix not in {'.png'} and re.search(rb'/(Users|home)/(?!test/)[^/\s]+/', data):
            raise ValueError('Machine-specific path found in distribution source')
        payload[name] = data
    output.mkdir(parents=True)
    archive = output / ('DeskDen-IPRoyal-Connector-' + version + '-chrome-macos.zip')
    folder = 'DeskDen-IPRoyal-Connector'
    with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED) as z:
        for name, data in sorted(payload.items()):
            info = zipfile.ZipInfo(folder + '/' + name, date_time=(2020, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = (stat.S_IFREG | (0o755 if name == 'install.command' else 0o644)) << 16
            z.writestr(info, data)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (output / 'SHA256SUMS.txt').write_text(digest + '  ' + archive.name + '\n')
    record = {'version': version, 'minimumAppVersion': '0.3.0', 'file': archive.name, 'sha256': digest,
              'size': archive.stat().st_size, 'generic': True, 'files': sorted(payload)}
    (output / 'package-record.json').write_text(json.dumps(record, indent=2) + '\n')
    return record


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(prepare(args.output), indent=2))
