#!/bin/sh
set -eu
KIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
HOST_NAME=com.uuthings.fangcun.iproyal
SOURCE="$KIT_DIR/$HOST_NAME.json"
DEST_DIR="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
if [ ! -f "$SOURCE" ] || [ ! -x "$KIT_DIR/native-host.command" ]; then
  printf '%s\n' '连接包不完整。请从方寸重新导出连接包。'; exit 1
fi
printf '%s\n' '这一步会为当前用户注册方寸 IPRoyal 本机连接文件。' '不会安装扩展、读取浏览器凭据或修改网站账户。' '连接包和方寸 App 必须保留在当前位置；移动后请重新导出并注册。' '输入 INSTALL 继续，其他输入退出：'
read -r ANSWER
[ "$ANSWER" = INSTALL ] || exit 0
[ ! -L "$DEST_DIR" ] && [ ! -L "$DEST_DIR/$HOST_NAME.json" ] || { printf '%s\n' '目标是符号链接，已停止。'; exit 1; }
/usr/bin/plutil -lint "$SOURCE" >/dev/null
mkdir -p "$DEST_DIR"
umask 077
TEMP_FILE=$(mktemp "$DEST_DIR/.fangcun-host.XXXXXX")
trap 'rm -f "$TEMP_FILE"' EXIT HUP INT TERM
cp "$SOURCE" "$TEMP_FILE"
chmod 600 "$TEMP_FILE"
mv -f "$TEMP_FILE" "$DEST_DIR/$HOST_NAME.json"
printf '%s\n' '本机连接文件已注册。接下来请在 Chrome 扩展管理页加载本包 Extension 文件夹，并在扩展弹窗启用连接。' '请保持 Chrome 登录 IPRoyal；登录过程完全留在浏览器。'
