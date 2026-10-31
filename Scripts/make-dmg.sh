#!/bin/bash
# Builds TimeLens.app and packs it into build/TimeLens-<version>.dmg (app + Applications link).
set -euo pipefail
cd "$(dirname "$0")/.."

Scripts/build-app.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
DMG="build/TimeLens-$VERSION.dmg"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R build/TimeLens.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname TimeLens -srcfolder "$STAGE" -format UDZO -ov "$DMG" >/dev/null
echo "Built $DMG"
