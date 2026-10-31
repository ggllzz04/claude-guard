#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
ARGS=(--disable-xctest)
# Some Command Line Tools builds omit the Testing macro during module emission.
# Loading the bundled plugin explicitly also keeps tests usable without XCTest.
DEVELOPER_PATH="$(xcode-select -p)"
TESTING_PLUGIN="$DEVELOPER_PATH/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [[ "$DEVELOPER_PATH" == */CommandLineTools ]] && [ -f "$TESTING_PLUGIN" ]; then
    ARGS+=(-Xswiftc -load-plugin-library -Xswiftc "$TESTING_PLUGIN")
fi
swift test "${ARGS[@]}" "$@"
