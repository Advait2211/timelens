#!/bin/bash
# Builds TimeLens.app into ./build. Pass --install to copy it to /Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product TimeLens
BIN="$(swift build -c release --show-bin-path)"

[ -f Resources/AppIcon.icns ] || swift Scripts/make-icon.swift Resources

APP=build/TimeLens.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN/TimeLens" "$APP/Contents/MacOS/TimeLens"

# Ad-hoc signature: enough to run locally and to register as a login item.
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    # Ask nicely (it saves the open stretch on quit); a hung copy gets killed.
    osascript -e 'with timeout of 5 seconds' -e 'tell application id "com.advait.timelens" to quit' -e 'end timeout' 2>/dev/null || true
    sleep 1
    pkill -x TimeLens 2>/dev/null && sleep 1 || true
    rm -rf /Applications/TimeLens.app
    cp -R "$APP" /Applications/TimeLens.app
    open /Applications/TimeLens.app
    echo "Installed to /Applications/TimeLens.app"
fi
