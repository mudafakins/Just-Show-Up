#!/bin/bash
# Builds the menu bar app into build/<APP_NAME>.app (no Xcode needed).
# Usage: scripts/build-app.sh [debug|release] [--run]
set -euo pipefail

# Rename the product here; nothing else needs to change.
APP_NAME='Just Show Up!'
BUNDLE_ID="com.example.justshowup"

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/$APP_NAME.app"

cd "$ROOT"

# Without full Xcode, the macOS 27 SDK can't compile SwiftUI (its macro plugin
# ships only with Xcode), so fall back to the 26 SDK from Command Line Tools.
CLT_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
if [[ -z "${SDKROOT:-}" && "$(xcode-select -p)" == "/Library/Developer/CommandLineTools" && -d "$CLT_SDK" ]]; then
    export SDKROOT="$CLT_SDK"
fi

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/TeamPointer"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/TeamPointer"
sed -e "s/__APP_NAME__/$APP_NAME/g" -e "s/__BUNDLE_ID__/$BUNDLE_ID/g" \
    "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"

# Embed the LiveKit libraries and tell the executable where to find them.
BIN_DIR="$(dirname "$BIN")"
mkdir -p "$APP/Contents/Frameworks"
for framework in "$BIN_DIR"/*.framework; do
    [[ -d "$framework" ]] || continue
    cp -R "$framework" "$APP/Contents/Frameworks/"
    codesign --force --sign - "$APP/Contents/Frameworks/$(basename "$framework")" >/dev/null 2>&1
done
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/TeamPointer" 2>/dev/null || true

# Bundle the keys (Config.local.json is Git-ignored; see Config.example.json).
mkdir -p "$APP/Contents/Resources"
if [[ -f "$ROOT/Config.local.json" ]]; then
    cp "$ROOT/Config.local.json" "$APP/Contents/Resources/Config.json"
else
    echo "warning: Config.local.json not found; the app will show 'Setup needed'." >&2
fi

# Ad-hoc signature: enough to run locally without an Apple Developer account.
codesign --force --sign - "$APP" >/dev/null

echo "Built $APP"

if [[ "${2:-}" == "--run" ]]; then
    # Quit the running copy and wait for it to exit before reopening.
    pkill -x TeamPointer 2>/dev/null || true
    while pgrep -x TeamPointer >/dev/null; do sleep 0.2; done
    open "$APP" || { sleep 1; open "$APP"; }
fi
