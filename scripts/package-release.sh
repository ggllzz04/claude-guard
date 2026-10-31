#!/bin/bash
# Build the app, disk image, ZIP and checksums from the same source version.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(cat "$ROOT/VERSION")"
ARCH="$(uname -m)"
export VERSION
export CONFIG=release
bash "$ROOT/scripts/build-dmg.sh"
OUT="$ROOT/build/release"
mkdir -p "$OUT"
NAME="Route-Guard-$VERSION-$ARCH"
cp "$ROOT/build/$NAME.dmg" "$OUT/$NAME.dmg"
ditto -c -k --sequesterRsrc --keepParent "$ROOT/build/Route Guard.app" "$OUT/$NAME.zip"
cp "$ROOT/scripts/uninstall.sh" "$OUT/uninstall.sh"
python3 "$ROOT/scripts/check-privacy.py" "$ROOT/build/Route Guard.app" "$OUT/uninstall.sh"
cd "$OUT"
shasum -a 256 "$NAME.dmg" "$NAME.zip" uninstall.sh > SHA256SUMS.txt
shasum -a 256 -c SHA256SUMS.txt
printf 'Release artifacts: %s\n' "$OUT"
