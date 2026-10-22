#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/fangcun-ai-build.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
swiftc -swift-version 6 -emit-library -emit-module -module-name LauncherCore \
  "$task_root/Sources/LauncherCore/AIUsageCore.swift" \
  "$task_root/Sources/LauncherCore/AIQuotaAlerts.swift" \
  "$task_root/Sources/LauncherCore/AITokenLedger.swift" \
  -emit-module-path "$check_dir/LauncherCore.swiftmodule" -o "$check_dir/libLauncherCore.dylib"
swiftc -swift-version 6 -parse-as-library -I "$check_dir" -L "$check_dir" -lLauncherCore \
  -Xlinker -rpath -Xlinker "$check_dir" \
  "$task_root/Sources/FangcunLauncher/AIUsageModule.swift" \
  "$task_root/Tests/WorkbenchChecks/AIUsageModelChecks.swift" -o "$check_dir/ai-model-checks"
"$check_dir/ai-model-checks"
