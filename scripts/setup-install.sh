#!/bin/bash
# Self-contained installer, invoked by the app through the macOS administrator dialog.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo '需要管理员授权'; exit 1; }
PAYLOAD="$(cd "$(dirname "$0")" && pwd)"
SOURCE_APP="$(cd "$PAYLOAD/../../.." && pwd)"
DEST_APP='/Applications/Route Guard.app'
LEGACY_APP='/Applications/Claude Guard.app'
SUPPORT='/Library/Application Support/Claude Guard'
CONSOLE_USER="$(stat -f %Su /dev/console)"
CONSOLE_UID="$(id -u "$CONSOLE_USER")"
CONSOLE_GID="$(id -g "$CONSOLE_USER")"
CONSOLE_HOME="$(dscl . -read "/Users/$CONSOLE_USER" NFSHomeDirectory | cut -d ' ' -f 2-)"
[ "$CONSOLE_UID" -gt 0 ] || { echo '请在登录用户的桌面运行'; exit 1; }
for name in GuardDaemon GuardCLI daemon.plist menu.plist ipv6.pf RouteGuard.yaml; do
    [ -f "$PAYLOAD/$name" ] || { echo "安装文件缺失：$name"; exit 1; }
done
/usr/bin/codesign --verify --deep --strict "$SOURCE_APP"
mkdir -p "$SUPPORT/Backups" /Library/PrivilegedHelperTools /Library/LaunchDaemons /usr/local/bin
LOCK="$SUPPORT/install.lock"
mkdir "$LOCK" 2>/dev/null || { echo '另一个安装正在进行'; exit 1; }
STAGE="/Applications/.RouteGuard-install-$$.app"
trap 'rm -rf "$STAGE"; rmdir "$LOCK" 2>/dev/null || true' EXIT
BACKUP="$SUPPORT/Backups/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP"
# Stage and validate before replacing a working installation.
ditto "$SOURCE_APP" "$STAGE"
chown -R root:wheel "$STAGE"
chmod -R go-w "$STAGE"
/usr/bin/codesign --verify --deep --strict "$STAGE"
[ ! -d "$DEST_APP" ] || ditto "$DEST_APP" "$BACKUP/Route Guard.app"
[ ! -d "$LEGACY_APP" ] || ditto "$LEGACY_APP" "$BACKUP/Legacy Guard.app"
[ ! -f "$SUPPORT/settings.json" ] || cp "$SUPPORT/settings.json" "$BACKUP/settings.json"
HELPER='/Library/PrivilegedHelperTools/com.local.claudeguard.daemon'
[ ! -f "$HELPER" ] || cp "$HELPER" "$BACKUP/GuardDaemon"
# Keep preferences, protection state and approval intact across updates.
install -m 755 -o root -g wheel "$PAYLOAD/GuardDaemon" "$HELPER.new"
install -m 644 -o root -g wheel "$PAYLOAD/daemon.plist" /Library/LaunchDaemons/com.local.claudeguard.daemon.plist
install -m 644 -o root -g wheel "$PAYLOAD/ipv6.pf" /etc/pf.anchors/com.local.claudeguard
if ! /usr/bin/grep -q '^anchor "com.local.claudeguard"' /etc/pf.conf; then
    cp /etc/pf.conf "$BACKUP/pf.conf"
    /usr/bin/awk '
    !done && /^anchor "com.apple\/\*"/ { print "anchor \"com.local.claudeguard\""; print "load anchor \"com.local.claudeguard\" from \"/etc/pf.anchors/com.local.claudeguard\""; done=1 }
    {print}
    END { if (!done) { print "anchor \"com.local.claudeguard\""; print "load anchor \"com.local.claudeguard\" from \"/etc/pf.anchors/com.local.claudeguard\"" } }
    ' /etc/pf.conf > "$SUPPORT/pf.conf.new"
    /sbin/pfctl -nf "$SUPPORT/pf.conf.new"
    install -m 644 -o root -g wheel "$SUPPORT/pf.conf.new" /etc/pf.conf
    /sbin/pfctl -f /etc/pf.conf
elif ! /usr/bin/grep -q '^load anchor "com.local.claudeguard"' /etc/pf.conf; then
    cp /etc/pf.conf "$BACKUP/pf.conf"
    printf '\nload anchor "com.local.claudeguard" from "/etc/pf.anchors/com.local.claudeguard"\n' >> /etc/pf.conf
fi
/sbin/pfctl -E >/dev/null 2>&1 || true
/sbin/pfctl -a com.local.claudeguard -f /etc/pf.anchors/com.local.claudeguard
# Recover obsolete jobs without changing or stopping Claude itself.
for label in com.claude.guard com.claude.pflock; do
    OLD="/Library/LaunchDaemons/$label.plist"
    if [ -f "$OLD" ]; then
        launchctl bootout "system/$label" >/dev/null 2>&1 || true
        mv "$OLD" "$BACKUP/$label.plist.disabled"
    fi
done
# Minimal interruption: all slow staging work completed before restarting the helper.
launchctl bootout system/com.local.claudeguard.daemon >/dev/null 2>&1 || true
mv -f "$HELPER.new" "$HELPER"
rm -rf "$DEST_APP"
mv "$STAGE" "$DEST_APP"
install -m 755 -o root -g wheel "$PAYLOAD/GuardCLI" /usr/local/bin/route-guardctl
# Preserve existing scripts that use the earlier CLI name.
ln -sfn route-guardctl /usr/local/bin/claude-guardctl
launchctl enable system/com.local.claudeguard.daemon
launchctl bootstrap system /Library/LaunchDaemons/com.local.claudeguard.daemon.plist
# Verify the new helper before marking this version installed.
OK=0
for attempt in {1..30}; do
    if /usr/local/bin/route-guardctl status >/dev/null 2>&1; then OK=1; break; fi
    /bin/sleep 0.2
done
[ "$OK" = 1 ] || { echo '守护进程未启动，请重试初始化。备份已保留。'; exit 1; }
PROFILE="$CONSOLE_HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/profiles"
if [ -d "$PROFILE" ] && [ ! -f "$PROFILE/RouteGuard.yaml" ]; then
    install -m 644 -o "$CONSOLE_USER" -g "$CONSOLE_GID" "$PAYLOAD/RouteGuard.yaml" "$PROFILE/RouteGuard.yaml"
fi
AGENTS="$CONSOLE_HOME/Library/LaunchAgents"
install -d -m 755 -o "$CONSOLE_USER" -g "$CONSOLE_GID" "$AGENTS"
install -m 644 -o "$CONSOLE_USER" -g "$CONSOLE_GID" "$PAYLOAD/menu.plist" "$AGENTS/com.local.claudeguard.menu.plist"
# The current app owns this session. The login agent takes effect on the next login.
/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$DEST_APP/Contents/Info.plist" > "$SUPPORT/installed-version"
chmod 644 "$SUPPORT/installed-version"
# Only remove the old app after the replacement service has passed its health check.
[ ! -d "$LEGACY_APP" ] || rm -rf "$LEGACY_APP"
echo '初始化完成，偏好设置与保护状态已保留。'
