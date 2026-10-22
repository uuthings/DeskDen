#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/fangcun-vault-v5-build.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
swiftc -swift-version 6 -emit-library -emit-module -module-name LauncherCore \
  "$task_root/Sources/LauncherCore/VaultCore.swift" \
  "$task_root/Sources/LauncherCore/ProtectedAtomicFile.swift" \
  -emit-module-path "$check_dir/LauncherCore.swiftmodule" -o "$check_dir/libLauncherCore.dylib"
swiftc -swift-version 6 -parse-as-library -I "$check_dir" -L "$check_dir" -lLauncherCore \
  -Xlinker -rpath -Xlinker "$check_dir" \
  "$task_root/Sources/FangcunLauncher/VaultModule.swift" \
  "$task_root/Tests/WorkbenchChecks/VaultV5ModelChecks.swift" -o "$check_dir/vault-v5-checks"
"$check_dir/vault-v5-checks"
# The signing diagnostic is verified with injected stores only. This second
# isolated executable never invokes the current process's real Keychain preflight.
swiftc -swift-version 6 -parse-as-library -I "$check_dir" -L "$check_dir" -lLauncherCore \
  -Xlinker -rpath -Xlinker "$check_dir" \
  "$task_root/Sources/FangcunLauncher/VaultModule.swift" \
  "$task_root/Sources/FangcunLauncher/VaultSigningChecks.swift" \
  "$task_root/Tests/WorkbenchChecks/VaultSigningPreflightChecks.swift" -o "$check_dir/vault-signing-preflight-checks"
"$check_dir/vault-signing-preflight-checks"
