#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ "$(id -u)" -ne 0 ]; then
    echo '请直接打开 DMG 中的应用完成初始化，或使用 sudo bash scripts/install.sh。'
    exit 1
fi
INSTALLER="$ROOT/build/Claude Guard.app/Contents/Resources/Installer/setup-install.sh"
[ -f "$INSTALLER" ] || { echo '请先运行 bash scripts/build-app.sh'; exit 1; }
bash "$INSTALLER"
USER_UID="$(stat -f %u /dev/console)"
launchctl asuser "$USER_UID" /usr/bin/open '/Applications/Claude Guard.app'
