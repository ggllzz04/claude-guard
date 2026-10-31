#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-$(cat "$ROOT/VERSION")}"
ARCH="$(uname -m)"
export VERSION
[ "${SKIP_BUILD:-0}" = 1 ] || bash "$ROOT/scripts/build-app.sh"
STAGE="$ROOT/build/dmg-stage"
DMG="$ROOT/build/Claude-Guard-$VERSION-$ARCH.dmg"
rm -rf "$STAGE"
mkdir -p "$STAGE"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/build/Claude Guard.app/Contents/Info.plist")"
[ "$APP_VERSION" = "$VERSION" ] || { echo 'App 版本与 DMG 版本不一致'; exit 1; }
ditto "$ROOT/build/Claude Guard.app" "$STAGE/Claude Guard.app"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/安装说明.txt" <<'TXT'
Claude Guard

1. 将 Claude Guard 拖到 Applications（应用程序）。
2. 打开应用，点「初始化并安装」，在 macOS 授权窗口中输入管理员密码。
3. 请先安装并启动 Clash Verge / mihomo，开启 TUN；按面板检查分流规则并确认 AI 节点后，在设置里开启保护。

升级会保留现有设置、节点批准和保护开关。初始化也支持直接从此磁盘安装。
菜单栏图标可按住 ⌘ 拖动排序；关闭主窗口后，应用仍在菜单栏运行。
密码由 macOS 接收，应用不读取或保存。
TXT
cp "$ROOT/scripts/uninstall.sh" "$STAGE/uninstall.sh"
rm -f "$DMG"
hdiutil create -volname "Claude Guard" -srcfolder "$STAGE" -format UDZO -ov "$DMG"
hdiutil verify "$DMG"
echo "DMG: $DMG"
