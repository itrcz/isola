#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Use only the hardware model (not a disk, auxiliary storage or VM identity).
# The test boots firmware on a new sparse disk, then resumes in a second process.
[[ $# == 1 && -f "$1" ]] || { echo 'Usage: bash scripts/test_suspend.sh /path/to/Hardware.bin' >&2; exit 1; }
HARDWARE=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' scripts/Info.plist)
TOOLS="$PWD/dist/Isola-$VERSION.app/Contents/Resources/Isola Tools.cdr"
[[ -f "$TOOLS" ]] || { echo 'Build Isola first: bash scripts/build.sh' >&2; exit 1; }
mkdir -p .build
WORK=$(mktemp -d "$PWD/.build/suspend-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/Test.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$TOOLS" "$APP/Contents/Resources/Isola Tools.cdr"
cp "$PWD/dist/Isola-$VERSION.app/Contents/MacOS/isola-network" "$APP/Contents/MacOS/isola-network"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>VMSuspendSmoke</string><key>CFBundleIdentifier</key><string>local.isola.suspend-test</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
xcrun swiftc -swift-version 5 -target arm64-apple-macosx14.0 -parse-as-library -D WINDOW_LIFECYCLE_TEST Sources/Shared/*.swift Sources/Isola/*.swift Tests/VMSuspendSmoke.swift -o "$APP/Contents/MacOS/VMSuspendSmoke" -framework AppKit -framework SwiftUI -framework Virtualization -framework Security
codesign --force --sign - --entitlements scripts/Isola.entitlements "$APP"
"$APP/Contents/MacOS/VMSuspendSmoke" save "$WORK/Fixture" "$HARDWARE"
"$APP/Contents/MacOS/VMSuspendSmoke" resume "$WORK/Fixture"

"$APP/Contents/MacOS/VMSuspendSmoke" save "$WORK/ProxyFixture" "$HARDWARE" --proxy
"$APP/Contents/MacOS/VMSuspendSmoke" resume "$WORK/ProxyFixture"
