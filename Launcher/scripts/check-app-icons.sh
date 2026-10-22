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
manifest = json.loads((root / 'Artwork/AppIcons/provenance.json').read_text())
for item in manifest['artwork']:
    source = root / 'Artwork/AppIcons' / item['source']
    resource = root / item['productionResource']
    assert hashlib.sha256(source.read_bytes()).hexdigest() == item['sourceSHA256'], item['id'] + ' source changed'
    assert hashlib.sha256(resource.read_bytes()).hexdigest() == item['productionSHA256'], item['id'] + ' production conversion changed'
print('PASS all three approved originals and production icon SHA-256 values match provenance')
PY
