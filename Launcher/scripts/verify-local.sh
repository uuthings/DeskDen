#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
verify_preserved_designs=0
if [[ "${1:-}" == "--verify-preserved-designs" ]]; then
    verify_preserved_designs=1
    shift
fi
if (( $# )); then
    print -u2 "Usage: verify-local.sh [--verify-preserved-designs]"
    exit 2
fi
verification_dir="$PWD/build/verification/run-$(date -u +%Y%m%dT%H%M%SZ)-$(uuidgen)"
mkdir -p "$verification_dir"
python3 - "$verification_dir" <<'PY'
from pathlib import Path
import hashlib, json, sys
root = Path.cwd()
paths = [root / 'Package.swift', root / 'Signing/Fangcun.entitlements']
for directory, pattern in [('Sources', '*.swift'), ('Tests', '*.swift'), ('scripts', '*.sh'), ('scripts', '*.py'), ('Resources', '*')]:
    paths.extend(path for path in (root / directory).rglob(pattern) if path.is_file())
paths.extend(path for path in [root / 'Package.resolved', root.parent / 'Fangcun.xcodeproj/project.pbxproj'] if path.is_file())
paths.extend((root.parent / 'Fangcun.xcodeproj/xcshareddata/xcschemes').glob('*.xcscheme'))
files = {}
for path in sorted(set(paths)):
    if path.is_symlink():
        raise SystemExit('Verification inputs must not be symbolic links: ' + str(path.relative_to(root.parent)))
    data = path.read_bytes()
    files[path.relative_to(root.parent).as_posix()] = {'sha256': hashlib.sha256(data).hexdigest(), 'bytes': len(data)}
(Path(sys.argv[1]) / 'source-inputs-before.json').write_text(json.dumps({'schema': 'fangcun.verification-inputs/1', 'files': files}, ensure_ascii=False, indent=2) + '\n')
PY
python3 ./scripts/check-signing-config.py > "$verification_dir/signing-config-checks.log" 2>&1
zsh ./scripts/check-app-icons.sh > "$verification_dir/app-icon-checks.log" 2>&1
swift test > "$verification_dir/core-tests.log" 2>&1
# Full mounted health and expanded AI checks are DEBUG-only. Keep their result
# separate from the production Release executable instead of reporting 0/0 as coverage.
./scripts/build-local.sh "$verification_dir/Debug/方寸.app" debug > "$verification_dir/debug-build.log" 2>&1
"$verification_dir/Debug/方寸.app/Contents/MacOS/FangcunLauncher" --self-check > "$verification_dir/debug-native-checks.log" 2>&1
"$verification_dir/Debug/方寸.app/Contents/MacOS/FangcunLauncher" --device-check > "$verification_dir/debug-device-module-checks.log" 2>&1
./scripts/build-local.sh "$verification_dir/Release/方寸.app" release > "$verification_dir/build.log" 2>&1
"$verification_dir/Release/方寸.app/Contents/MacOS/FangcunLauncher" --self-check > "$verification_dir/native-checks.log" 2>&1
"$verification_dir/Release/方寸.app/Contents/MacOS/FangcunLauncher" --device-check > "$verification_dir/device-module-checks.log" 2>&1
"$verification_dir/Release/方寸.app/Contents/MacOS/FangcunLauncher" --form-check > "$verification_dir/form-checks.log" 2>&1
zsh ./scripts/check-device-monitoring.sh > "$verification_dir/device-monitoring-checks.log" 2>&1
zsh ./scripts/check-calendar-model.sh > "$verification_dir/calendar-model-checks.log" 2>&1
zsh ./scripts/check-vault-model.sh > "$verification_dir/vault-model-checks.log" 2>&1
zsh ./scripts/check-vault-v5.sh > "$verification_dir/vault-v5-checks.log" 2>&1
zsh ./scripts/check-vault-editor.sh > "$verification_dir/vault-editor-checks.log" 2>&1
zsh ./scripts/check-vault-compatibility.sh > "$verification_dir/vault-compatibility-checks.log" 2>&1
zsh ./scripts/check-ai-model.sh > "$verification_dir/ai-model-checks.log" 2>&1
python3 - "$verification_dir" "$verify_preserved_designs" <<'PY'
from pathlib import Path
import hashlib, json, re, sys
verification = Path(sys.argv[1])
source = Path.cwd()
paths = [source / 'Package.swift', source / 'Signing/Fangcun.entitlements']
for directory, pattern in [('Sources', '*.swift'), ('Tests', '*.swift'), ('scripts', '*.sh'), ('scripts', '*.py'), ('Resources', '*')]:
    paths.extend(path for path in (source / directory).rglob(pattern) if path.is_file())
paths.extend(path for path in [source / 'Package.resolved', source.parent / 'Fangcun.xcodeproj/project.pbxproj'] if path.is_file())
paths.extend((source.parent / 'Fangcun.xcodeproj/xcshareddata/xcschemes').glob('*.xcscheme'))
files = {}
for path in sorted(set(paths)):
    if path.is_symlink():
        raise SystemExit('Verification input became a symbolic link: ' + str(path.relative_to(source.parent)))
    data = path.read_bytes()
    files[path.relative_to(source.parent).as_posix()] = {'sha256': hashlib.sha256(data).hexdigest(), 'bytes': len(data)}
after = {'schema': 'fangcun.verification-inputs/1', 'files': files}
(verification / 'source-inputs-after.json').write_text(json.dumps(after, ensure_ascii=False, indent=2) + '\n')
if after != json.loads((verification / 'source-inputs-before.json').read_text()):
    raise SystemExit('Source inputs changed between checks; Debug and Release results do not describe one frozen input set')
if sys.argv[2] == "1":
    root = Path('Design')
    manifest = json.loads((root / 'baseline.json').read_text())
    for name, expected in manifest['files'].items():
        assert hashlib.sha256((root / name).read_bytes()).hexdigest() == expected, name
    print('Historical launcher snapshot integrity verified.')
    root = Path('Design/Workbench')
    manifest = json.loads((root / 'baseline.json').read_text())
    for name, expected in manifest['files'].items():
        assert hashlib.sha256((root / name).read_bytes()).hexdigest() == expected, name
    print('Final workbench design snapshot integrity verified.')
    root = Path('Design/Workbench/DeviceStatus')
    manifest = json.loads((root / 'baseline.json').read_text())
    for name, expected in manifest['files'].items():
        assert hashlib.sha256((root / name).read_bytes()).hexdigest() == expected, name
    print('Accepted device design snapshot integrity verified.')
    root = Path('Design/Workbench/DeviceStatus/NetworkBudget')
    manifest = json.loads((root / 'baseline.json').read_text())
    for name, expected in manifest['files'].items():
        assert hashlib.sha256((root / name).read_bytes()).hexdigest() == expected, name
    print('Accepted eight-card device design snapshot integrity verified.')
    root = Path('Design/Workbench/Unified/2026-10-21')
    manifest = json.loads((root / 'baseline.json').read_text())
    for name, expected in manifest['files'].items():
        data = (root / name).read_bytes()
        assert hashlib.sha256(data).hexdigest() == expected['sha256'], name
        assert len(data) == expected['bytes'], name
    print('Accepted V5 unified design snapshot integrity verified.')
else:
    print("Private historical design snapshots were not requested; public source verification is independent.")
def checked_log(name):
    text = (verification / name).read_text()
    if not text.strip():
        raise SystemExit('Empty verification log: ' + name)
    if re.search(r'^\s*(?:SKIP(?:PED)?|FAIL(?:ED)?)(?:\b|:)', text, re.MULTILINE | re.IGNORECASE):
        raise SystemExit('Some checks failed or were skipped: ' + name)
    if re.search(r'^\s*Test (?:Case|Suite)\b.*\b(?:failed|skipped)\b', text, re.MULTILINE | re.IGNORECASE):
        raise SystemExit('XCTest failure or skip: ' + name)
    if re.search(r'\b[1-9]\d* tests? skipped\b', text, re.IGNORECASE):
        raise SystemExit('Skipped XCTest cases: ' + name)
    return text

summary = {'schema': 'fangcun.local-verification/1', 'sourceInputsUnchanged': True, 'core': {}, 'debug': [], 'release': [], 'models': [], 'configuration': []}
core = checked_log('core-tests.log')
core_counts = re.findall(r'^\s*Executed (\d+) tests?, with (\d+) failures\b', core, re.MULTILINE)
if not core_counts or int(core_counts[-1][0]) <= 0 or int(core_counts[-1][1]) != 0:
    raise SystemExit('Missing positive successful core test summary')
summary['core'] = {'log': 'core-tests.log', 'checks': int(core_counts[-1][0]), 'failures': 0}
icons = checked_log('app-icon-checks.log')
icon_counts = re.findall(r'^Application icon checks: (\d+) checks, (\d+) failures$', icons, re.MULTILINE)
if len(icon_counts) != 1 or int(icon_counts[0][0]) <= 0 or int(icon_counts[0][1]) != 0:
    raise SystemExit('Missing positive successful application icon check summary')
summary['applicationIcons'] = {'log': 'app-icon-checks.log', 'checks': int(icon_counts[0][0]), 'failures': 0}
print(f"Core: {summary['core']['checks']} tests, 0 failures")

checks = [
    ('configuration', 'signing-config-checks.log', 'Signing configuration checks', 'ratio'),
    ('debug', 'debug-native-checks.log', 'Native checks', 'native'),
    ('debug', 'debug-device-module-checks.log', 'Device module checks', 'ratio'),
    ('release', 'native-checks.log', 'Native checks', 'native'),
    ('release', 'device-module-checks.log', 'Device module checks', 'ratio'),
    ('release', 'form-checks.log', 'Device monitoring form checks', 'ratio'),
    ('models', 'device-monitoring-checks.log', 'Device monitoring model checks', 'ratio'),
    ('models', 'calendar-model-checks.log', 'Calendar model checks', 'ratio'),
    ('models', 'vault-model-checks.log', 'Vault model checks', 'ratio'),
    ('models', 'vault-v5-checks.log', 'Vault V5 checks', 'ratio'),
    ('models', 'vault-v5-checks.log', 'Vault signing preflight checks', 'ratio'),
    ('models', 'vault-editor-checks.log', 'Vault editor checks', 'ratio'),
    ('models', 'vault-compatibility-checks.log', 'Vault format compatibility checks', 'ratio'),
    ('models', 'ai-model-checks.log', 'AI model checks', 'ratio'),
]
for group, name, title, style in checks:
    text = checked_log(name)
    if group == 'debug' and re.search(r'(?:requires? (?:a )?DEBUG|did not run)', text, re.IGNORECASE):
        raise SystemExit('DEBUG-only mounted checks did not run: ' + name)
    pattern = re.escape(title) + (r': (\d+) checks, (\d+) failures' if style == 'native' else r': (\d+)/(\d+) passed')
    matches = re.findall(r'^' + pattern + r'\s*$', text, re.MULTILINE)
    if len(matches) != 1:
        raise SystemExit('Missing or ambiguous check summary: ' + name)
    first, second = map(int, matches[0])
    total, failures = (first, second) if style == 'native' else (second, second - first)
    if total <= 0 or failures != 0 or (style == 'ratio' and first <= 0):
        raise SystemExit('Checks must have a positive count and no failures: ' + name)
    summary[group].append({'log': name, 'checks': total, 'failures': 0})
    print(f'{group}: {title}: {total} checks, 0 failures')

for group, name in [('debug', 'debug-build.log'), ('release', 'build.log')]:
    text = checked_log(name)
    matches = re.findall(r'^Production bundle verified: (\d+) files;', text, re.MULTILINE)
    if len(matches) != 1 or int(matches[0]) <= 0:
        raise SystemExit('Missing verified production bundle summary: ' + name)
    bundle = json.loads((verification / ('Debug' if group == 'debug' else 'Release') / '方寸.app.evidence/bundle-integrity.json').read_text())
    if bundle.get('configuration') != group or not all(bundle.get(key) is True for key in ['sourceInputsUnchanged', 'productionInfoAndResourcesMatchSource', 'codeSignatureVerified', 'executableMatchesBuildOutputBeforeSigning']):
        raise SystemExit('Build evidence does not match the requested configuration: ' + name)
    app = verification / ('Debug' if group == 'debug' else 'Release') / '方寸.app'
    actual_files = {}
    for path in sorted(app.rglob('*')):
        if path.is_symlink():
            raise SystemExit('Unexpected symbolic link in the checked bundle: ' + name)
        if path.is_file():
            data = path.read_bytes()
            actual_files[path.relative_to(app).as_posix()] = {'sha256': hashlib.sha256(data).hexdigest(), 'bytes': len(data)}
    if not actual_files or actual_files != bundle.get('files') or len(actual_files) != int(matches[0]):
        raise SystemExit('The checked bundle changed after packaging: ' + name)
    for phase in ['before', 'after']:
        build_inputs = json.loads((verification / ('Debug' if group == 'debug' else 'Release') / ('方寸.app.evidence/source-inputs-' + phase + '.json')).read_text())
        if build_inputs.get('configuration') != group or build_inputs.get('files') != after['files']:
            raise SystemExit('Build inputs do not match the complete verification input set: ' + name)
    summary[group + 'BundleManifest'] = ('Debug' if group == 'debug' else 'Release') + '/方寸.app.evidence/bundle-integrity.json'

(verification / 'verification-summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2) + '\n')
print('Debug mounted coverage and Release production checks are separate; Release omits DEBUG-only cases.')
PY
print "Local workbench and launcher verification passed. Evidence: $verification_dir"
