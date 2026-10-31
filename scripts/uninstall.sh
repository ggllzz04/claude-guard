#!/bin/bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "请用 sudo 运行: sudo bash scripts/uninstall.sh [--purge]"
    exit 1
fi

PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

USER_NAME="${SUDO_USER:-$(stat -f %Su /dev/console)}"
USER_UID="$(id -u "$USER_NAME")"
[ "$USER_UID" -gt 0 ] || { echo '请在已登录用户的桌面使用 sudo 运行'; exit 1; }
USER_HOME="$(dscl . -read "/Users/$USER_NAME" NFSHomeDirectory | cut -d ' ' -f 2-)"

echo "== 停止守护 =="
launchctl bootout system "/Library/LaunchDaemons/com.local.claudeguard.daemon.plist" >/dev/null 2>&1 || true
launchctl bootout "system/com.local.claudeguard.daemon" >/dev/null 2>&1 || true
pkill -x RouteGuard >/dev/null 2>&1 || true
pkill -x ClaudeGuard >/dev/null 2>&1 || true

echo "== 移除 PF anchor =="
pfctl -a com.local.claudeguard -F rules >/dev/null 2>&1 || true
PF_TEMP="$(mktemp /etc/pf.conf.claudeguard.XXXXXX)"
trap 'rm -f "$PF_TEMP"' EXIT
/usr/bin/awk '!/com[.]local[.]claudeguard/' /etc/pf.conf > "$PF_TEMP"
/sbin/pfctl -nf "$PF_TEMP"
install -m 644 -o root -g wheel "$PF_TEMP" /etc/pf.conf
pfctl -f /etc/pf.conf >/dev/null 2>&1 || true
rm -f "/etc/pf.anchors/com.local.claudeguard"

echo "== 移除 App / CLI / 启动项 =="
rm -rf "/Applications/Route Guard.app" "/Applications/Claude Guard.app"
rm -f "/usr/local/bin/route-guardctl" "/usr/local/bin/claude-guardctl"
rm -f "/Library/PrivilegedHelperTools/com.local.claudeguard.daemon"
rm -f "/Library/LaunchDaemons/com.local.claudeguard.daemon.plist"
launchctl bootout "gui/$USER_UID" "$USER_HOME/Library/LaunchAgents/com.local.claudeguard.menu.plist" >/dev/null 2>&1 || true
rm -f "$USER_HOME/Library/LaunchAgents/com.local.claudeguard.menu.plist"

if [ "$PURGE" -eq 1 ]; then
    echo "== 清理本地数据 =="
    rm -rf "/Library/Application Support/Claude Guard"
    rm -rf "$USER_HOME/Library/Application Support/Claude Guard"
    rm -f "$USER_HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/profiles/RouteGuard.yaml"
    rm -f "$USER_HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/profiles/ClaudeGuard.yaml"
fi

echo "卸载完成。"
echo "未使用 --purge 时，本地设置和安装备份保留在 /Library/Application Support/Claude Guard。"
