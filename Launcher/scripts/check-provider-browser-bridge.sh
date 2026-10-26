#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/fangcun-browser-build.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
swiftc -swift-version 6 -emit-library -emit-module -module-name LauncherCore \
  "$task_root/Sources/LauncherCore/ProviderUsageCore.swift" \
  "$task_root/Sources/LauncherCore/ProviderUsageRefresh.swift" \
  "$task_root/Sources/LauncherCore/ProviderUsageBrowserProtocol.swift" \
  "$task_root/Sources/LauncherCore/ProviderUsageBrowserMailbox.swift" \
  "$task_root/Sources/LauncherCore/ProviderUsageBrowserNativeProtocol.swift" \
  -emit-module-path "$check_dir/LauncherCore.swiftmodule" -o "$check_dir/libLauncherCore.dylib"
swiftc -swift-version 6 -parse-as-library -I "$check_dir" -L "$check_dir" -lLauncherCore \
  -Xlinker -rpath -Xlinker "$check_dir" \
  "$task_root/Sources/FangcunLauncher/ProviderUsageBrowserBridge.swift" \
  "$task_root/Tests/WorkbenchChecks/ProviderUsageBrowserBridgeChecks.swift" -o "$check_dir/provider-browser-checks"
"$check_dir/provider-browser-checks"
python3 "$task_root/BrowserConnectors/IPRoyal/tests/native-host.test.py" "$check_dir/provider-browser-checks"
