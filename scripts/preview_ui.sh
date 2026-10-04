#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/.build/Isola-UI-Review.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -swift-version 5 -D WINDOW_LIFECYCLE_TEST -target arm64-apple-macosx14.0 -parse-as-library Sources/Shared/*.swift Sources/Isola/*.swift Tests/UIReview.swift -o "$APP/Contents/MacOS/UIReview" -framework AppKit -framework SwiftUI -framework Virtualization -framework Security
cp Assets/IsolaIcon.png "$APP/Contents/Resources/IsolaIcon.png"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>UIReview</string>
<key>CFBundleIdentifier</key><string>local.isola.ui-review</string>
<key>CFBundleName</key><string>Isola UI Review</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
open -n "$APP" --args "$@"
