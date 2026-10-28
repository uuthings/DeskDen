#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if [[ "${1:-}" != "--use-verified-build" ]]; then
  ./scripts/verify-local.sh
fi
candidate_name="${DESKDEN_ACCEPTANCE_NAME:-设备状态验收版}"
candidate_profile="${DESKDEN_ACCEPTANCE_PROFILE:-DeviceStatus}"
if [[ ! "$candidate_profile" =~ '^[A-Za-z0-9_-]+$' ]]; then
  print -u2 '验收配置名称只能包含字母、数字、下划线和连字符。'
  exit 1
fi
if [[ "$candidate_name" == */* || "$candidate_name" == "." || "$candidate_name" == ".." ]]; then
  print -u2 '验收目录名称不能包含路径。'
  exit 1
fi
candidate="$PWD/../Deliverables/$candidate_name"
app="$candidate/方寸.app"
if [[ -e "$app" ]]; then
  print -u2 '验收目录已有 App；请使用新的候选目录，不能覆盖正在验收的版本。'
  exit 1
fi
mkdir -p "$candidate/检查记录"
ditto "$PWD/build/方寸.app" "$app"
/usr/libexec/PlistBuddy -c 'Add :DeskDenDeviceAcceptance bool true' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :DeskDenDeviceAcceptanceProfile string $candidate_profile" "$app/Contents/Info.plist"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
ditto "$PWD/build/verification" "$candidate/检查记录/自动检查"
python3 - "$candidate" "$candidate_profile" <<'PY'
from pathlib import Path
import sys, hashlib, json, datetime
candidate = Path(sys.argv[1])
app = candidate / '方寸.app'
files = {str(p.relative_to(app)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(app.rglob('*')) if p.is_file()}
sources = Path.cwd()
source_files = list((sources / 'Sources').rglob('*.swift')) + list((sources / 'Tests').rglob('*.swift')) + [sources / 'Package.swift', sources / 'Resources/Info.plist', sources.parent / 'DeskDen.xcodeproj/project.pbxproj']
record = {'kind': '设备状态本机验收候选（非正式发布）', 'created_at': datetime.datetime.now().astimezone().isoformat(), 'git': '当前目录无 Git 仓库，以源文件 SHA-256 标识', 'profile': 'DeskDen/TestProfiles/' + sys.argv[2], 'app_files': files, 'source_files': {str(p.relative_to(sources.parent)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(source_files)}}
(candidate / '检查记录/构建指纹.json').write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n')
PY
print "设备状态验收 App：$app"
