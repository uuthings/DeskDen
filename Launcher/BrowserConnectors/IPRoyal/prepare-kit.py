#!/usr/bin/env python3
"""Prepare a portable connection kit; never install or register it."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import plistlib
import shlex
import shutil

FILES = ('manifest.json', 'protocol.js', 'protocol-isolated.js', 'observer.js', 'content.js', 'background.js', 'popup.html', 'popup.css', 'popup.js',
         'icon-16.png', 'icon-32.png', 'icon-64.png', 'icon-128.png')
HOST = 'com.uuthings.fangcun.iproyal'

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--bridge-directory', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    source = Path(__file__).resolve().parent
    app, bridge, output = args.app.resolve(), args.bridge_directory.resolve(), args.output.absolute()
    if output.exists() or output.is_symlink():
        parser.error('Output must be a new directory; existing files are never overwritten.')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    executable = app / 'Contents/MacOS' / info['CFBundleExecutable']
    if not executable.is_file():
        parser.error('App executable is missing.')
    manifest = json.loads((source / 'manifest.json').read_text())
    digest = hashlib.sha256(base64.b64decode(manifest['key'], validate=True)).hexdigest()[:32]
    extension_id = ''.join(chr(97 + int(c, 16)) for c in digest)
    if extension_id != (source / 'extension-id.txt').read_text().strip():
        parser.error('Extension identity mismatch.')
    output.mkdir(mode=0o700)
    try:
        ext = output / 'Extension'
        ext.mkdir(mode=0o700)
        for name in FILES:
            path = source / name
            if path.is_symlink() or not path.is_file():
                raise ValueError('Invalid template file')
            shutil.copyfile(path, ext / name)
        wrapper = output / 'native-host.command'
        wrapper.write_text('#!/bin/sh\nexec ' + shlex.quote(str(executable)) + ' --provider-usage-browser-host --provider-usage-browser-directory ' + shlex.quote(str(bridge)) + ' "$@"\n')
        wrapper.chmod(0o700)
        host = {'name': HOST, 'description':'Fangcun IPRoyal quota bridge', 'path':str(wrapper), 'type':'stdio',
                'allowed_origins':['chrome-extension://' + extension_id + '/']}
        host_path = output / (HOST + '.json')
        host_path.write_text(json.dumps(host, ensure_ascii=False, indent=2) + '\n')
        host_path.chmod(0o600)
        for name in ('install.command', 'README.md'):
            shutil.copyfile(source / name, output / name)
            (output / name).chmod(0o700 if name.endswith('.command') else 0o600)
    except Exception:
        shutil.rmtree(output)
        raise
    print('Connection kit prepared. Nothing installed or registered.')

if __name__ == '__main__':
    main()
