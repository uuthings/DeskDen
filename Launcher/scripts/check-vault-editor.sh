#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/deskden-vault-editor-build.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
swiftc -swift-version 6 -emit-library -emit-module -module-name LauncherCore \
  "$task_root/Sources/LauncherCore/ProtectedAtomicFile.swift" \
  "$task_root/Sources/LauncherCore/VaultCore.swift" \
  -emit-module-path "$check_dir/LauncherCore.swiftmodule" -o "$check_dir/libLauncherCore.dylib"
# Compile the production formatting and clipboard classes outside the shell.
# All clipboard operations use isolated named boards, never the user's clipboard.
python3 - "$task_root/Sources/DeskDenLauncher/VaultModuleView.swift" "$task_root/Sources/DeskDenLauncher/VaultModule.swift" "$check_dir/VaultEditorFormatting.swift" <<'PY'
import pathlib,sys
source=pathlib.Path(sys.argv[1]).read_text()
start=source.index('@MainActor final class VaultEditorFormatting:')
end=source.index('/// Font metrics determine the insertion point.',start)
clipboard=pathlib.Path(sys.argv[2]).read_text()
clipboard=clipboard[clipboard.index('/// Keeps only ownership metadata,'):]
pathlib.Path(sys.argv[3]).write_text('import AppKit\nimport Combine\nimport LauncherCore\n'+source[start:end]+'\n'+clipboard)
PY
swiftc -swift-version 6 -parse-as-library -I "$check_dir" -L "$check_dir" -lLauncherCore \
  -Xlinker -rpath -Xlinker "$check_dir" \
  "$check_dir/VaultEditorFormatting.swift" \
  "$task_root/Tests/WorkbenchChecks/VaultEditorChecks.swift" -o "$check_dir/vault-editor-checks"
"$check_dir/vault-editor-checks"
