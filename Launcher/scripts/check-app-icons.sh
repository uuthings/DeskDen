#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/fangcun-app-icon-checks.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
swiftc -swift-version 6 -parse-as-library \
  "$task_root/Sources/FangcunLauncher/ApplicationIconController.swift" \
  "$task_root/Tests/WorkbenchChecks/ApplicationIconChecks.swift" \
  -o "$check_dir/application-icon-checks"
"$check_dir/application-icon-checks" "$task_root"
python3 - "$task_root" <<'PY'
from pathlib import Path
import hashlib, json, sys
root = Path(sys.argv[1])
manifest = json.loads((root / 'Artwork/AppIcons/provenance-minimal.json').read_text())
for item in manifest['artwork']:
    source = root / 'Artwork/AppIcons' / item['source']
    resource = root / item['productionResource']
    assert hashlib.sha256(source.read_bytes()).hexdigest() == item['sourceSHA256'], item['id'] + ' source changed'
    assert hashlib.sha256(resource.read_bytes()).hexdigest() == item['productionSHA256'], item['id'] + ' production conversion changed'
    assert hashlib.sha256((root / item['menuBarResource']).read_bytes()).hexdigest() == item['menuBarSHA256'], item['id'] + ' menu-bar mark changed'
print('PASS both minimal originals, production icons and menu-bar marks match reproducible provenance')
backgrounds = json.loads((root / 'Artwork/Workbench/provenance.json').read_text())
assert {item['id'] for item in backgrounds['artwork']} == {'qingbi-chenwu', 'yuebai-yunhai', 'nuanxia-xuanshan'}
for item in backgrounds['artwork']:
    source = root / 'Artwork/Workbench' / item['source']
    resource = root / item['productionResource']
    assert hashlib.sha256(source.read_bytes()).hexdigest() == item['sourceSHA256'], item['id'] + ' wallpaper original changed'
    assert hashlib.sha256(resource.read_bytes()).hexdigest() == item['productionSHA256'], item['id'] + ' wallpaper encoding changed'
    assert item['sourceDimensions'] == item['productionDimensions'] == [1672, 941]
print('PASS all three unchanged wallpaper PNG originals and production JPEG SHA-256 values match provenance')
build = (root / 'scripts/build-local.sh').read_text()
for name in ['ar-world', 'thunder-cabin', 'qingbi-chenwu', 'yuebai-yunhai', 'nuanxia-xuanshan']:
    assert build.count(name + '.jpg') == 3, name + ' must be required, copied and verified by the local build'
project = (root.parent / 'Fangcun.xcodeproj/project.pbxproj').read_text()
assert 'lastKnownFileType = folder; path = "Launcher/Resources/Workbench";' in project
print('PASS local build resource contracts and the Xcode resource folder include all five theme backgrounds')
PY
