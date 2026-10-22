#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/fangcun-vault-editor-build.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
swiftc -swift-version 6 -emit-library -emit-module -module-name LauncherCore \
  "$task_root/Sources/LauncherCore/VaultCore.swift" \
  -emit-module-path "$check_dir/LauncherCore.swiftmodule" -o "$check_dir/libLauncherCore.dylib"
# Compile the actual production native-formatting class in isolation from the
# workbench shell, so this check never creates a window or requests permissions.
python3 - "$task_root/Sources/FangcunLauncher/VaultModuleView.swift" "$check_dir/VaultEditorFormatting.swift" <<'PY'
import pathlib,sys
source=pathlib.Path(sys.argv[1]).read_text()
start=source.index('@MainActor final class VaultEditorFormatting:')
end=source.index('/// Font metrics determine the insertion point.',start)
pathlib.Path(sys.argv[2]).write_text('import AppKit\nimport Combine\nimport LauncherCore\n'+source[start:end])
PY
swiftc -swift-version 6 -parse-as-library -I "$check_dir" -L "$check_dir" -lLauncherCore \
  -Xlinker -rpath -Xlinker "$check_dir" \
  "$check_dir/VaultEditorFormatting.swift" \
  "$task_root/Tests/WorkbenchChecks/VaultEditorChecks.swift" -o "$check_dir/vault-editor-checks"
"$check_dir/vault-editor-checks"
