#!/bin/bash
# Runs the test suite. With only the Command Line Tools installed (no Xcode), SwiftPM doesn't
# find Swift Testing on its own, and the CLT copy lacks the Foundation cross-import overlay.
set -euo pipefail
cd "$(dirname "$0")/.."

FRAMEWORKS=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
if [ -d "$FRAMEWORKS/Testing.framework" ] && ! xcode-select -p | grep -q Xcode.app; then
    exec swift test \
        -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
        -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
        -Xlinker -F -Xlinker "$FRAMEWORKS" \
        -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
        "$@"
fi
exec swift test "$@"
