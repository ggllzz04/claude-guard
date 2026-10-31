#!/bin/bash
# Upgrade an existing Guard installation without changing Clash or network rules.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo '需要管理员授权'; exit 1; }
SOURCE_APP="${1:?请指定已构建的 Claude Guard.app}"
PAYLOAD="$SOURCE_APP/Contents/Resources/Installer"
DEST_APP='/Applications/Claude Guard.app'
SUPPORT='/Library/Application Support/Claude Guard'
HELPER='/Library/PrivilegedHelperTools/com.local.claudeguard.daemon'
DAEMON_PLIST='/Library/LaunchDaemons/com.local.claudeguard.daemon.plist'
[ -d "$DEST_APP" ] && [ -f "$HELPER" ] && [ -f "$SUPPORT/settings.json" ] || {
    echo '此流程仅更新已有 Guard，不执行网络初始化。'; exit 1;
}
for name in GuardDaemon GuardCLI daemon.plist menu.plist; do
    [ -f "$PAYLOAD/$name" ] || { echo "缺少 Guard 安装文件：$name"; exit 1; }
done
/usr/bin/codesign --verify --deep --strict "$SOURCE_APP"
/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:1' "$PAYLOAD/daemon.plist" | /usr/bin/grep -qx -- '--preserve-network'
CONSOLE_USER="$(stat -f %Su /dev/console)"
CONSOLE_UID="$(id -u "$CONSOLE_USER")"
CONSOLE_GID="$(id -g "$CONSOLE_USER")"
CONSOLE_HOME="$(dscl . -read "/Users/$CONSOLE_USER" NFSHomeDirectory | cut -d ' ' -f 2-)"
[ "$CONSOLE_UID" -gt 0 ] || { echo '请在登录用户的桌面运行'; exit 1; }
LOCK="$SUPPORT/install.lock"
mkdir "$LOCK" 2>/dev/null || { echo '另一个 Guard 安装正在进行'; exit 1; }
STAGE="/Applications/.ClaudeGuard-update-$$.app"
trap 'rm -rf "$STAGE"; rmdir "$LOCK" 2>/dev/null || true' EXIT
BACKUP="$SUPPORT/Backups/guard-only-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP"
ditto "$DEST_APP" "$BACKUP/Claude Guard.app"
cp "$SUPPORT/settings.json" "$BACKUP/settings.json"
cp "$HELPER" "$BACKUP/GuardDaemon"
cp "$DAEMON_PLIST" "$BACKUP/daemon.plist"
[ ! -f /usr/local/bin/claude-guardctl ] || cp /usr/local/bin/claude-guardctl "$BACKUP/GuardCLI"
# Snapshot active rules for verification; every pfctl invocation here is read-only.
/sbin/pfctl -s rules > "$BACKUP/pf-main-before.txt" 2>/dev/null
/sbin/pfctl -s rules -a com.local.claudeguard > "$BACKUP/pf-anchor-before.txt" 2>/dev/null
ditto "$SOURCE_APP" "$STAGE"
chown -R root:wheel "$STAGE"
chmod -R go-w "$STAGE"
/usr/bin/codesign --verify --deep --strict "$STAGE"
if launchctl print system/com.local.claudeguard.daemon >/dev/null 2>&1; then
    launchctl bootout system/com.local.claudeguard.daemon
fi
install -m 755 -o root -g wheel "$PAYLOAD/GuardDaemon" "$HELPER"
install -m 755 -o root -g wheel "$PAYLOAD/GuardCLI" /usr/local/bin/claude-guardctl
install -m 644 -o root -g wheel "$PAYLOAD/daemon.plist" "$DAEMON_PLIST"
rm -rf "$DEST_APP"
mv "$STAGE" "$DEST_APP"
AGENTS="$CONSOLE_HOME/Library/LaunchAgents"
install -m 644 -o "$CONSOLE_USER" -g "$CONSOLE_GID" "$PAYLOAD/menu.plist" "$AGENTS/com.local.claudeguard.menu.plist"
launchctl enable system/com.local.claudeguard.daemon
launchctl bootstrap system "$DAEMON_PLIST"
OK=0
for attempt in {1..30}; do
    if /usr/local/bin/claude-guardctl status >/dev/null 2>&1; then OK=1; break; fi
    /bin/sleep 0.2
done
[ "$OK" = 1 ] || { echo "Guard 守护启动失败，备份位于 $BACKUP"; exit 1; }
/sbin/pfctl -s rules > "$BACKUP/pf-main-after.txt" 2>/dev/null
/sbin/pfctl -s rules -a com.local.claudeguard > "$BACKUP/pf-anchor-after.txt" 2>/dev/null
cmp -s "$BACKUP/pf-main-before.txt" "$BACKUP/pf-main-after.txt"
cmp -s "$BACKUP/pf-anchor-before.txt" "$BACKUP/pf-anchor-after.txt"
/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$DEST_APP/Contents/Info.plist" > "$SUPPORT/installed-version"
chmod 644 "$SUPPORT/installed-version"
echo 'Guard 已更新并启动；现有 PF 规则一致，未执行网络初始化。'
echo "Guard 备份：$BACKUP"
