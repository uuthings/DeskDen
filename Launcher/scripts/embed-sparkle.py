#!/usr/bin/env python3
"""Embed the pinned SwiftPM artifact in an ad-hoc local preview, inside-out."""
import pathlib
import plistlib
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parent.parent
app = pathlib.Path(sys.argv[1]).resolve()
matches = list((root / '.build/artifacts').glob('sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework'))
if len(matches) != 1:
    raise SystemExit('Resolve the pinned Sparkle package before embedding its framework')
source = matches[0]
info = plistlib.loads((source / 'Resources/Info.plist').read_bytes())
if info['CFBundleShortVersionString'] != '2.10.0':
    raise SystemExit('Unexpected Sparkle artifact version')
destination = app / 'Contents/Frameworks/Sparkle.framework'
if destination.exists():
    raise SystemExit('The preview framework output already exists')
destination.parent.mkdir(parents=True, exist_ok=True)
subprocess.run(['ditto', str(source), str(destination)], check=True)
magic = {b'\xfe\xed\xfa\xce', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'}
targets = []
for path in destination.rglob('*'):
    if path.is_symlink():
        if not path.resolve(strict=True).is_relative_to(destination.resolve()):
            raise SystemExit('Framework link escapes its bundle')
    elif path.is_file():
        with path.open('rb') as handle:
            if handle.read(4) in magic:
                targets.append(path)
for path in targets + sorted([p for p in destination.rglob('*') if not p.is_symlink() and p.suffix in {'.app', '.xpc'}], key=lambda p: len(p.parts), reverse=True) + [destination]:
    subprocess.run(['codesign', '--force', '--sign', '-', '--preserve-metadata=entitlements', str(path)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(destination)], check=True)
print('Pinned Sparkle framework and nested helpers embedded and verified for local preview')
