#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/deskden-vault-compatibility-build.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
# Schema-v1 fixture derived from VaultCore.swift at 564d5c141c161454181cc0390317b4d3fb3cfb8a.
# Commit 77477a399259815ab28cabd101b94b0ae4a109f4 changed only its format/AAD
# names and restore extension to DeskDen; this is not the original release bytes.
fixture="$task_root/Tests/WorkbenchChecks/VaultV1CompatibilityCore.swift"
fixture_hash="$(shasum -a 256 "$fixture" | cut -d ' ' -f 1)"
[[ "$fixture_hash" == "effaecf975ab89e0546411aa359001ff0a05564a6f4dab58319ea63fa1c1150f" ]] || { print -u2 'DeskDen schema-v1 compatibility fixture has changed'; exit 1; }
swiftc -swift-version 6 -emit-library -emit-module -module-name VaultV1Compatibility \
  "$fixture" -emit-module-path "$check_dir/VaultV1Compatibility.swiftmodule" -o "$check_dir/libVaultV1Compatibility.dylib"
swiftc -swift-version 6 -emit-library -emit-module -module-name LauncherCore \
  "$task_root/Sources/LauncherCore/VaultCore.swift" "$task_root/Sources/LauncherCore/ProtectedAtomicFile.swift" \
  -emit-module-path "$check_dir/LauncherCore.swiftmodule" -o "$check_dir/libLauncherCore.dylib"
swiftc -swift-version 6 -parse-as-library -I "$check_dir" -L "$check_dir" -lLauncherCore -lVaultV1Compatibility \
  -Xlinker -rpath -Xlinker "$check_dir" \
  "$task_root/Sources/DeskDenLauncher/VaultModule.swift" \
  "$task_root/Tests/WorkbenchChecks/VaultFormatCompatibilityChecks.swift" -o "$check_dir/vault-compatibility-checks"
"$check_dir/vault-compatibility-checks"
