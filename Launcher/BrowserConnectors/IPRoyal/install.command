#!/bin/sh
set -eu
KIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
HOST_NAME=com.uuthings.deskden.iproyal
SOURCE="$KIT_DIR/$HOST_NAME.json"
DEST_DIR="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
RUNTIME_DIR="$HOME/Library/Application Support/DeskDen/Connectors/IPRoyal"
APP_PATH=""
BRIDGE_PATH=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --app) [ "$#" -ge 2 ] || exit 2; APP_PATH=$2; shift 2 ;;
    --bridge-directory) [ "$#" -ge 2 ] || exit 2; BRIDGE_PATH=$2; shift 2 ;;
    *) printf '%s\n' 'Usage: install.command [--app /path/to/App.app] [--bridge-directory /absolute/path]'; exit 2 ;;
  esac
done
[ -f "$KIT_DIR/Extension/manifest.json" ] || { printf '%s\n' '连接包不完整，缺少 Extension。'; exit 1; }
PREPARED=0
if [ -f "$SOURCE" ] && [ -x "$KIT_DIR/native-host.command" ] && [ -z "$APP_PATH" ]; then
  PREPARED=1
else
  if [ -z "$APP_PATH" ]; then
    APP_PATH=$(/usr/bin/osascript -e 'POSIX path of (choose file with prompt "请选择已安装的 DeskDen（方寸）App" of type {"com.apple.application-bundle"})') || exit 0
  fi
  APP_PATH=${APP_PATH%/}
  case "$APP_PATH" in /*.app) ;; *) printf '%s\n' '请选择完整的方寸 App。'; exit 1 ;; esac
  INFO="$APP_PATH/Contents/Info.plist"
  EXECUTABLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO")
  VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO")
  case "$EXECUTABLE" in ''|*[!A-Za-z0-9_-]*|Launcher) printf '%s\n' 'App 可执行文件名称无效。'; exit 1 ;; esac
  case "$EXECUTABLE" in *Launcher) PREFIX=${EXECUTABLE%Launcher} ;; *) printf '%s\n' '所选 App 不支持 DeskDen 连接器。'; exit 1 ;; esac
  printf '%s\n' "$VERSION" | /usr/bin/awk -F. 'NF==3 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && ($1>0 || $2>=3) {ok=1} END {exit !ok}' || { printf '%s\n' '连接器需要 DeskDen 0.3.0 或更新版本。'; exit 1; }
  [ -x "$APP_PATH/Contents/MacOS/$EXECUTABLE" ] && [ -f "$APP_PATH/Contents/Resources/BrowserConnectors/IPRoyal/manifest.json" ] || { printf '%s\n' 'App 缺少本机连接组件。'; exit 1; }
  # Read the selected App's declared data profile, never any account or order.
  # The profile prefix is derived from that App's executable, not hard-coded.
  if [ -z "$BRIDGE_PATH" ]; then
    BASE="$HOME/Library/Application Support/$PREFIX/Launcher"
    if [ "$(/usr/libexec/PlistBuddy -c "Print :${PREFIX}DeviceAcceptance" "$INFO" 2>/dev/null || true)" = true ]; then
      PROFILE=$(/usr/libexec/PlistBuddy -c "Print :${PREFIX}DeviceAcceptanceProfile" "$INFO" 2>/dev/null || printf '%s' DeviceStatus)
      case "$PROFILE" in ''|*[!A-Za-z0-9_-]*) printf '%s\n' 'App 测试目录配置无效。'; exit 1 ;; esac
      BASE="$HOME/Library/Application Support/$PREFIX/TestProfiles/$PROFILE"
    fi
    if [ "$(/usr/libexec/PlistBuddy -c "Print :${PREFIX}UIReview" "$INFO" 2>/dev/null || true)" = true ]; then
      BASE=$(/usr/libexec/PlistBuddy -c "Print :${PREFIX}UIReviewDataDirectory" "$INFO" 2>/dev/null || true)
      [ -n "$BASE" ] || { printf '%s\n' '界面验收 App 需要明确指定数据目录。'; exit 1; }
    fi
    BRIDGE_PATH="$BASE/Workbench/ProviderUsage/BrowserBridge"
  fi
  case "$BRIDGE_PATH" in /*) ;; *) printf '%s\n' '本机连接目录必须是绝对路径。'; exit 1 ;; esac
fi
printf '%s\n' '这一步会将本机启动组件安装到 DeskDen 专用的应用支持目录，并注册当前用户的 Chrome 连接。' '不会安装扩展、读取浏览器凭据或修改网站账户。' '移动连接包后在 Chrome 重选 Extension 目录；移动 App 后重新运行本安装程序。' '输入 INSTALL 继续，其他输入退出：'
read -r ANSWER
[ "$ANSWER" = INSTALL ] || exit 0
[ ! -L "$DEST_DIR" ] && [ ! -L "$DEST_DIR/$HOST_NAME.json" ] && [ ! -L "$RUNTIME_DIR" ] && [ ! -L "$RUNTIME_DIR/native-host.command" ] || { printf '%s\n' '目标是符号链接，已停止。'; exit 1; }
umask 077
mkdir -p "$DEST_DIR" "$RUNTIME_DIR"
TEMP_FILE=$(mktemp "$DEST_DIR/.deskden-host.XXXXXX")
LAUNCH_FILE=$(mktemp "$RUNTIME_DIR/.deskden-launch.XXXXXX")
trap 'rm -f "$TEMP_FILE" "$LAUNCH_FILE"' EXIT HUP INT TERM
if [ "$PREPARED" = 1 ]; then
  # App-exported kits already contain local configuration. Distribution ZIPs do not.
  /usr/bin/plutil -convert xml1 -o "$TEMP_FILE" "$SOURCE"
  cp "$KIT_DIR/native-host.command" "$LAUNCH_FILE"
else
  shell_quote() { printf "'%s'" "$(printf '%s' "$1" | /usr/bin/sed "s/'/'\\\\''/g")"; }
  {
    printf '#!/bin/sh\nexec '
    shell_quote "$APP_PATH/Contents/MacOS/$EXECUTABLE"
    printf ' --provider-usage-browser-host --provider-usage-browser-directory '
    shell_quote "$BRIDGE_PATH"
    printf ' "$@"\n'
  } > "$LAUNCH_FILE"
  /usr/bin/plutil -create xml1 "$TEMP_FILE"
  /usr/bin/plutil -insert name -string "$HOST_NAME" "$TEMP_FILE"
  /usr/bin/plutil -insert description -string 'DeskDen IPRoyal Connector' "$TEMP_FILE"
  /usr/bin/plutil -insert type -string stdio "$TEMP_FILE"
  /usr/bin/plutil -insert path -string '' "$TEMP_FILE"
  /usr/bin/plutil -insert allowed_origins -json '["chrome-extension://dbgielekmbgphidnnfidmlobjmdblagf/"]' "$TEMP_FILE"
fi
/usr/bin/plutil -replace path -string "$RUNTIME_DIR/native-host.command" "$TEMP_FILE"
/usr/bin/plutil -convert json "$TEMP_FILE"
chmod 700 "$LAUNCH_FILE"
mv -f "$LAUNCH_FILE" "$RUNTIME_DIR/native-host.command"
chmod 600 "$TEMP_FILE"
mv -f "$TEMP_FILE" "$DEST_DIR/$HOST_NAME.json"
printf '%s\n' '本机连接文件已注册。接下来请在 Chrome 扩展管理页加载本包 Extension 文件夹，并在扩展弹窗启用连接。' '请保持 Chrome 登录 IPRoyal；登录过程完全留在浏览器。'
