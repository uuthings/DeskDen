#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
app_path="${1:-$PWD/build/方寸.app}"
build_configuration="${2:-release}"
if [[ "$build_configuration" != debug && "$build_configuration" != release ]]; then
    print -u2 'Usage: build-local.sh [absolute-new-app-path] [debug|release]'
    exit 2
fi
evidence_path="$app_path.evidence"
connector_template_files=(
    manifest.json extension-id.txt protocol.js protocol-isolated.js observer.js content.js
    background.js popup.html popup.css popup.js install.command README.md INSTALL.md prepare-kit.py
    icon-16.png icon-32.png icon-64.png icon-128.png
)
if [[ "$app_path" != /* ]] || [[ -e "$app_path" ]] || [[ -e "$evidence_path" ]]; then
    print -u2 'The output must be a new absolute path; existing candidates and evidence are preserved.'
    exit 2
fi
python3 ./scripts/check-signing-config.py
python3 ./scripts/check-update-config.py
python3 - "$evidence_path" "$build_configuration" "${connector_template_files[@]}" <<'PY'
from pathlib import Path
import datetime, hashlib, json, plistlib, sys

root = Path.cwd()
evidence = Path(sys.argv[1])
connector_root = root / 'BrowserConnectors/IPRoyal'
connector_files = sys.argv[3:]
if connector_root.is_symlink() or connector_root.parent.is_symlink():
    raise SystemExit('Connector template directories must not be symbolic links')
for name in connector_files:
    path = connector_root / name
    if not path.is_file() or path.is_symlink():
        raise SystemExit(f'Missing regular connector template: BrowserConnectors/IPRoyal/{name}')
required = ['Info.plist', 'PanelLogo.png', 'AppIcon.icns', 'AppIcons/desk.icns', 'AppIcons/desk-small.png', 'AppIcons/desk-small-1x.png', 'AppIcons/desk-menubar.png', 'AppIcons/desk-menubar-1x.png', 'Workbench/ar-world.jpg',
            'Workbench/thunder-cabin.jpg', 'Workbench/qingbi-chenwu.jpg', 'Workbench/yuebai-yunhai.jpg',
            'Workbench/nuanxia-xuanshan.jpg', 'Workbench/claude.png', 'Workbench/chatgpt.png']
for name in required:
    path = root / 'Resources' / name
    if not path.is_file() or path.is_symlink():
        raise SystemExit(f'Missing regular production resource: Resources/{name}')
info = plistlib.loads((root / 'Resources/Info.plist').read_bytes())
qa_keys = {'DeskDenDeviceAcceptance', 'DeskDenDeviceAcceptanceProfile', 'DeskDenUIReview',
           'DeskDenUIReviewDataDirectory', 'DeskDenTopEntryDiagnostics'}
if qa_keys.intersection(info):
    raise SystemExit('Production Info.plist contains QA keys: ' + ', '.join(sorted(qa_keys.intersection(info))))
if info.get('CFBundleExecutable') != 'DeskDenLauncher':
    raise SystemExit('Unexpected production executable name')
paths = [root / 'Package.swift', root / 'Signing/DeskDen.entitlements']
paths.extend(connector_root / name for name in connector_files)
for directory, pattern in [('Sources', '*.swift'), ('Tests', '*.swift'), ('scripts', '*.sh'), ('scripts', '*.py'), ('scripts', '*.swift'), ('Resources', '*')]:
    paths.extend(path for path in (root / directory).rglob(pattern) if path.is_file())
paths.extend(path for path in [root / 'Package.resolved', root.parent / 'DeskDen.xcodeproj/project.pbxproj', root.parent / 'DeskDen.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved', root.parent / 'updates/appcast.xml', root.parent / 'tools/prepare-update-feed.py', root.parent / 'tools/test-prepare-update-feed.py'] if path.is_file())
paths.extend((root.parent / 'DeskDen.xcodeproj/xcshareddata/xcschemes').glob('*.xcscheme'))
files = {}
for path in sorted(set(paths)):
    if path.is_symlink():
        raise SystemExit('Source inputs must not be symbolic links: ' + str(path.relative_to(root.parent)))
    data = path.read_bytes()
    files[path.relative_to(root.parent).as_posix()] = {'sha256': hashlib.sha256(data).hexdigest(), 'bytes': len(data)}
evidence.mkdir(parents=True, exist_ok=False)
snapshot = {'schema': 'deskden.build-inputs/1', 'configuration': sys.argv[2], 'files': files}
(evidence / 'source-inputs-before.json').write_text(json.dumps(snapshot, ensure_ascii=False, indent=2) + '\n')
(evidence / 'build-context.json').write_text(json.dumps({'configuration': sys.argv[2], 'createdAt': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'signing': 'ad-hoc local development; no archive, notarization or publication'}, indent=2) + '\n')
PY
swift build -c "$build_configuration"
binary_dir="$(swift build -c "$build_configuration" --show-bin-path)"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources/Workbench"
cp "$binary_dir/DeskDenLauncher" "$app_path/Contents/MacOS/DeskDenLauncher"
cp "$PWD/Resources/Info.plist" "$app_path/Contents/Info.plist"
cp "$PWD/Resources/PanelLogo.png" "$app_path/Contents/Resources/PanelLogo.png"
cp "$PWD/Resources/AppIcon.icns" "$app_path/Contents/Resources/AppIcon.icns"
mkdir -p "$app_path/Contents/Resources/AppIcons"
for icon_resource in desk.icns desk-small.png desk-small-1x.png desk-menubar.png desk-menubar-1x.png; do
    cp "$PWD/Resources/AppIcons/$icon_resource" "$app_path/Contents/Resources/AppIcons/$icon_resource"
done
for resource_name in ar-world.jpg thunder-cabin.jpg qingbi-chenwu.jpg yuebai-yunhai.jpg nuanxia-xuanshan.jpg claude.png chatgpt.png; do
    cp "$PWD/Resources/Workbench/$resource_name" "$app_path/Contents/Resources/Workbench/$resource_name"
done
mkdir -p "$app_path/Contents/Resources/BrowserConnectors/IPRoyal"
for connector_resource in "${connector_template_files[@]}"; do
    cp "$PWD/BrowserConnectors/IPRoyal/$connector_resource" "$app_path/Contents/Resources/BrowserConnectors/IPRoyal/$connector_resource"
done
python3 - "$app_path" "$binary_dir/DeskDenLauncher" "$evidence_path" <<'PY'
from pathlib import Path
import hashlib, json, sys
source, copied = Path(sys.argv[2]), Path(sys.argv[1]) / 'Contents/MacOS/DeskDenLauncher'
source_hash = hashlib.sha256(source.read_bytes()).hexdigest()
if hashlib.sha256(copied.read_bytes()).hexdigest() != source_hash:
    raise SystemExit('The bundled executable differs from the current SwiftPM output before signing')
(Path(sys.argv[3]) / 'executable-before-signing.json').write_text(json.dumps({'sha256': source_hash, 'matchesCurrentSwiftPMOutput': True}, indent=2) + '\n')
PY
python3 ./scripts/embed-sparkle.py "$app_path"
codesign --force --sign - "$app_path"
codesign --verify --deep --strict "$app_path"
python3 - "$app_path" "$evidence_path" "${connector_template_files[@]}" <<'PY'
from pathlib import Path
import hashlib, json, os, plistlib, sys
root, app, evidence = Path.cwd(), Path(sys.argv[1]), Path(sys.argv[2])
connector_root = root / 'BrowserConnectors/IPRoyal'
connector_files = sys.argv[3:]
if connector_root.is_symlink() or connector_root.parent.is_symlink():
    raise SystemExit('Connector template directory became a symbolic link')
before = json.loads((evidence / 'source-inputs-before.json').read_text())
paths = [root / 'Package.swift', root / 'Signing/DeskDen.entitlements']
paths.extend(connector_root / name for name in connector_files)
for directory, pattern in [('Sources', '*.swift'), ('Tests', '*.swift'), ('scripts', '*.sh'), ('scripts', '*.py'), ('scripts', '*.swift'), ('Resources', '*')]:
    paths.extend(path for path in (root / directory).rglob(pattern) if path.is_file())
paths.extend(path for path in [root / 'Package.resolved', root.parent / 'DeskDen.xcodeproj/project.pbxproj', root.parent / 'DeskDen.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved', root.parent / 'updates/appcast.xml', root.parent / 'tools/prepare-update-feed.py', root.parent / 'tools/test-prepare-update-feed.py'] if path.is_file())
paths.extend((root.parent / 'DeskDen.xcodeproj/xcshareddata/xcschemes').glob('*.xcscheme'))
files = {}
for path in sorted(set(paths)):
    if path.is_symlink():
        raise SystemExit('Source input became a symbolic link: ' + str(path.relative_to(root.parent)))
    data = path.read_bytes()
    files[path.relative_to(root.parent).as_posix()] = {'sha256': hashlib.sha256(data).hexdigest(), 'bytes': len(data)}
after = dict(before, files=files)
(evidence / 'source-inputs-after.json').write_text(json.dumps(after, ensure_ascii=False, indent=2) + '\n')
if before != after:
    raise SystemExit('Source inputs changed during the build; this candidate is not verified')
resources = ['PanelLogo.png', 'AppIcon.icns', 'AppIcons/desk.icns', 'AppIcons/desk-small.png', 'AppIcons/desk-small-1x.png', 'AppIcons/desk-menubar.png', 'AppIcons/desk-menubar-1x.png', 'Workbench/ar-world.jpg', 'Workbench/thunder-cabin.jpg', 'Workbench/qingbi-chenwu.jpg', 'Workbench/yuebai-yunhai.jpg', 'Workbench/nuanxia-xuanshan.jpg', 'Workbench/claude.png', 'Workbench/chatgpt.png']
connector_resources = ['BrowserConnectors/IPRoyal/' + name for name in connector_files]
expected = {'Contents/Info.plist': root / 'Resources/Info.plist'}
expected.update({'Contents/Resources/' + name: root / 'Resources' / name for name in resources})
expected.update({'Contents/Resources/' + name: root / name for name in connector_resources})
for name, source in expected.items():
    target = app / name
    if not target.is_file() or target.is_symlink() or target.read_bytes() != source.read_bytes():
        raise SystemExit('Bundled production input differs from source: ' + name)
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
qa_keys = {'DeskDenDeviceAcceptance', 'DeskDenDeviceAcceptanceProfile', 'DeskDenUIReview', 'DeskDenUIReviewDataDirectory', 'DeskDenTopEntryDiagnostics'}
if qa_keys.intersection(info):
    raise SystemExit('The bundled Info.plist contains QA keys')
actual_resources = {path.relative_to(app / 'Contents/Resources').as_posix() for path in (app / 'Contents/Resources').rglob('*') if path.is_file()}
if actual_resources != set(resources + connector_resources):
    raise SystemExit('The production bundle resource set is incomplete or contains unexpected files')
bundle = {}
for path in sorted(app.rglob('*')):
    if path.is_symlink():
        if not path.is_relative_to(app / 'Contents/Frameworks/Sparkle.framework') or not path.resolve(strict=True).is_relative_to(app.resolve()):
            raise SystemExit('Unexpected symbolic link in the local bundle')
        bundle[path.relative_to(app).as_posix()] = {'symlink': os.readlink(path)}
        continue
    if path.is_file():
        data = path.read_bytes()
        bundle[path.relative_to(app).as_posix()] = {'sha256': hashlib.sha256(data).hexdigest(), 'bytes': len(data)}
manifest = {'schema': 'deskden.local-bundle/1', 'configuration': before['configuration'], 'sourceInputsUnchanged': True, 'productionInfoAndResourcesMatchSource': True, 'codeSignatureVerified': True, 'executableMatchesBuildOutputBeforeSigning': True, 'files': bundle}
(evidence / 'bundle-integrity.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
print(f'Production bundle verified: {len(bundle)} files; source input and signed bundle SHA-256 evidence saved.')
PY
print "Local development app: $app_path"
print "Build evidence: $evidence_path"
