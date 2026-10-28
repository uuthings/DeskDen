#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/deskden-vault-build.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
swiftc -swift-version 6 -emit-library -emit-module -module-name LauncherCore \
  "$task_root/Sources/LauncherCore/VaultCore.swift" \
  "$task_root/Sources/LauncherCore/ProtectedAtomicFile.swift" \
  -emit-module-path "$check_dir/LauncherCore.swiftmodule" -o "$check_dir/libLauncherCore.dylib"
swiftc -swift-version 6 -parse-as-library -I "$check_dir" -L "$check_dir" -lLauncherCore \
  -Xlinker -rpath -Xlinker "$check_dir" \
  "$task_root/Sources/DeskDenLauncher/VaultModule.swift" \
  "$task_root/Tests/WorkbenchChecks/VaultModelChecks.swift" -o "$check_dir/vault-model-checks"
"$check_dir/vault-model-checks"
