#!/bin/sh
set -eu
KIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
HOST_NAME=com.uuthings.fangcun.iproyal
SOURCE="$KIT_DIR/$HOST_NAME.json"
DEST_DIR="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
if [ ! -f "$SOURCE" ] || [ ! -x "$KIT_DIR/native-host.command" ]; then
  printf '%s\n' '连接包不完整。请从方寸重新导出连接包。'; exit 1
fi
printf '%s\n' '这一步会为当前用户注册方寸 IPRoyal 本机连接文件。' '不会安装扩展、读取浏览器凭据或修改网站账户。' '移动连接包后请重新运行本脚本，并在 Chrome 重选 Extension 目录；移动方寸 App 后请重新导出连接包。' '输入 INSTALL 继续，其他输入退出：'
read -r ANSWER
[ "$ANSWER" = INSTALL ] || exit 0
[ ! -L "$DEST_DIR" ] && [ ! -L "$DEST_DIR/$HOST_NAME.json" ] || { printf '%s\n' '目标是符号链接，已停止。'; exit 1; }
mkdir -p "$DEST_DIR"
umask 077
TEMP_FILE=$(mktemp "$DEST_DIR/.fangcun-host.XXXXXX")
trap 'rm -f "$TEMP_FILE"' EXIT HUP INT TERM
# plutil lint/replacement require a plist; convert JSON before editing and back afterward.
/usr/bin/plutil -convert xml1 -o "$TEMP_FILE" "$SOURCE"
/usr/bin/plutil -replace path -string "$KIT_DIR/native-host.command" "$TEMP_FILE"
/usr/bin/plutil -convert json "$TEMP_FILE"
chmod 600 "$TEMP_FILE"
mv -f "$TEMP_FILE" "$DEST_DIR/$HOST_NAME.json"
printf '%s\n' '本机连接文件已注册。接下来请在 Chrome 扩展管理页加载本包 Extension 文件夹，并在扩展弹窗启用连接。' '请保持 Chrome 登录 IPRoyal；登录过程完全留在浏览器。'
