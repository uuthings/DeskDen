#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/fangcun-vault-compatibility-build.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
# Exact released VaultCore.swift from source commit
# 564d5c141c161454181cc0390317b4d3fb3cfb8a, frozen as a regression fixture.
fixture="$task_root/Tests/WorkbenchChecks/VaultV1CompatibilityCore.swift"
fixture_hash="$(shasum -a 256 "$fixture" | cut -d ' ' -f 1)"
[[ "$fixture_hash" == "dd22f0138c86836d2cdd09f10042d5d1607577f16a7c5e9d71f263dc03cf4587" ]] || { print -u2 'Released v1 compatibility fixture has changed'; exit 1; }
swiftc -swift-version 6 -emit-library -emit-module -module-name VaultV1Compatibility \
  "$fixture" -emit-module-path "$check_dir/VaultV1Compatibility.swiftmodule" -o "$check_dir/libVaultV1Compatibility.dylib"
swiftc -swift-version 6 -emit-library -emit-module -module-name LauncherCore \
  "$task_root/Sources/LauncherCore/VaultCore.swift" "$task_root/Sources/LauncherCore/ProtectedAtomicFile.swift" \
  -emit-module-path "$check_dir/LauncherCore.swiftmodule" -o "$check_dir/libLauncherCore.dylib"
swiftc -swift-version 6 -parse-as-library -I "$check_dir" -L "$check_dir" -lLauncherCore -lVaultV1Compatibility \
  -Xlinker -rpath -Xlinker "$check_dir" \
  "$task_root/Sources/FangcunLauncher/VaultModule.swift" \
  "$task_root/Tests/WorkbenchChecks/VaultFormatCompatibilityChecks.swift" -o "$check_dir/vault-compatibility-checks"
"$check_dir/vault-compatibility-checks"
