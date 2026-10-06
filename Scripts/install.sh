#!/bin/zsh
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(cat "$PROJECT_DIR/VERSION" | tr -d '\n')"
PACKAGE="$PROJECT_DIR/Release/GaoMenHu-$VERSION.dmg"
MOUNT="$(mktemp -d /private/tmp/mendao-install.XXXXXX)"
NEW_APP="/Applications/.GaoMenHu-install.app"
trap 'hdiutil detach -quiet "$MOUNT" 2>/dev/null || true; rmdir "$MOUNT" 2>/dev/null || true' EXIT
if [[ ! -f "$PACKAGE" ]]; then print -u2 "请先构建当前版本。"; exit 1; fi
hdiutil attach -quiet -nobrowse -mountpoint "$MOUNT" "$PACKAGE"
SOURCE="$MOUNT/搞门户.app"
codesign --verify --strict "$SOURCE"
if [[ "$(defaults read "$SOURCE/Contents/Info" CFBundleIdentifier)" != "cn.mendao.launcher" ]]; then print -u2 "应用标识不匹配。"; exit 1; fi
# Validate every existing destination before replacing either product name.
for OLD_APP in "/Applications/门道.app" "/Applications/搞门户.app" "$NEW_APP"; do
  if [[ -e "$OLD_APP" ]]; then
    if [[ "$(defaults read "$OLD_APP/Contents/Info" CFBundleIdentifier)" != "cn.mendao.launcher" ]]; then
      print -u2 "同名程序标识不符，停止替换：$OLD_APP"; exit 1
    fi
  fi
done
if [[ -e "$NEW_APP" ]]; then rm -rf "$NEW_APP"; fi
ditto "$SOURCE" "$NEW_APP"
codesign --verify --strict "$NEW_APP"
pkill -TERM -x MenDao 2>/dev/null || true
pkill -TERM -x MenDaoBridge 2>/dev/null || true
sleep 1
for OLD_APP in "/Applications/门道.app" "/Applications/搞门户.app"; do
  if [[ -e "$OLD_APP" ]]; then rm -rf "$OLD_APP"; fi
done
mv "$NEW_APP" "/Applications/搞门户.app"
open "/Applications/搞门户.app"
print "已安装搞门户 V$VERSION；用户数据和钥匙串保留。"
