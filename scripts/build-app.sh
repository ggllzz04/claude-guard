#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="${CONFIG:-release}"
VERSION="${VERSION:-$(cat "$ROOT/VERSION")}"
BUILD_NUMBER="${BUILD_NUMBER:-$(cat "$ROOT/BUILD_NUMBER")}"
# Remap compiler paths before packaging; release binaries must not disclose a home directory.
swift build -c "$CONFIG" \
    -Xswiftc -file-prefix-map -Xswiftc "$ROOT=." \
    -Xcc "-ffile-prefix-map=$ROOT=."
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

APP="$ROOT/build/Claude Guard.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ROOT/build/bin"

cp "$BIN/GuardMenu" "$APP/Contents/MacOS/ClaudeGuard"
cp "$BIN/GuardDaemon" "$ROOT/build/bin/GuardDaemon"
cp "$BIN/GuardCLI" "$ROOT/build/bin/GuardCLI"
cp "$BIN/GuardMock" "$ROOT/build/bin/GuardMock"

# The DMG contains everything required for first-run setup; no developer tools needed.
PAYLOAD="$APP/Contents/Resources/Installer"
mkdir -p "$PAYLOAD"
cp "$ROOT/build/bin/GuardDaemon" "$PAYLOAD/GuardDaemon"
cp "$ROOT/build/bin/GuardCLI" "$PAYLOAD/GuardCLI"
cp "$ROOT/scripts/setup-install.sh" "$PAYLOAD/setup-install.sh"
cp "$ROOT/scripts/uninstall.sh" "$PAYLOAD/uninstall.sh"
cp "$ROOT/config/com.local.claudeguard.daemon.plist" "$PAYLOAD/daemon.plist"
cp "$ROOT/config/com.local.claudeguard.menu.plist" "$PAYLOAD/menu.plist"
cp "$ROOT/config/ClaudeGuard.yaml" "$PAYLOAD/ClaudeGuard.yaml"
cp "$ROOT/pf/com.local.claudeguard" "$PAYLOAD/ipv6.pf"
chmod 755 "$PAYLOAD/setup-install.sh" "$PAYLOAD/uninstall.sh"
ICONSET="$ROOT/build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
swift "$ROOT/scripts/make-icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cp "$ICONSET/icon_512x512@2x.png" "$APP/Contents/Resources/BrandIcon.png"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>ClaudeGuard</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.claudeguard.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Claude Guard</string>
    <key>CFBundleDisplayName</key>
    <string>Claude Guard</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHumanReadableCopyright</key>
    <string>Local-only Claude traffic guard</string>
</dict>
</plist>
PLIST

if [ "$CONFIG" = release ]; then
    for binary in "$APP/Contents/MacOS/ClaudeGuard" "$PAYLOAD/GuardDaemon" "$PAYLOAD/GuardCLI"; do
        strip -S "$binary"
    done
fi

xattr -cr "$APP" >/dev/null 2>&1 || true
codesign --force --sign - "$PAYLOAD/GuardDaemon"
codesign --force --sign - "$PAYLOAD/GuardCLI"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "Built: $APP"
echo "Binaries: $ROOT/build/bin"
