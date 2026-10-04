#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' scripts/Info.plist)
APP="${ISOLA_APP_OUTPUT:-$PWD/dist/Isola-$VERSION.app}"
case "$APP" in /*) ;; *) APP="$PWD/$APP" ;; esac
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" .build
WORK=$(mktemp -d "$PWD/.build/build.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
(cd Network && GOOS=darwin GOARCH=arm64 go build -trimpath -ldflags='-s -w' -o "$APP/Contents/MacOS/isola-network" .)
xcrun swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macosx14.0 Sources/Shared/*.swift Sources/Isola/*.swift -o "$APP/Contents/MacOS/Isola" -framework SwiftUI -framework AppKit -framework Virtualization -framework Security
TOOLS="$WORK/guest-tools"
mkdir -p "$TOOLS"
xcrun swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macosx14.0 Sources/Shared/*.swift Sources/ClipboardAgent/*.swift -o "$TOOLS/isola-clipboard" -framework AppKit
codesign --force --sign - "$TOOLS/isola-clipboard"
cp GuestTools/* "$TOOLS/"
hdiutil create -quiet -ov -fs HFS+ -format UDTO -volname "Isola Tools" -srcfolder "$TOOLS" "$APP/Contents/Resources/Isola Tools.cdr"
mkdir -p "$APP/Contents/Resources/Licenses"
GO_LICENSE="$(go env GOROOT)/LICENSE"
# Homebrew keeps the license one level above libexec/GOROOT.
if [ ! -f "$GO_LICENSE" ]; then GO_LICENSE="$(go env GOROOT)/../LICENSE"; fi
cp "$GO_LICENSE" "$APP/Contents/Resources/Licenses/Go-LICENSE"
(cd Network && go list -m -f '{{.Path}}|{{.Dir}}' all) | while IFS='|' read -r module module_dir; do
    [ -n "$module_dir" ] || continue
    module_name="${module//\//_}"
    for license_file in "$module_dir"/LICENSE* "$module_dir"/NOTICE* "$module_dir"/COPYING*; do
        [ -f "$license_file" ] || continue
        cp -f "$license_file" "$APP/Contents/Resources/Licenses/${module_name}-$(basename "$license_file")"
    done
done
ICONSET="$WORK/Isola.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Assets/IsolaIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" Assets/IsolaIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/IsolaFreeform.icns"
cp Assets/IsolaIcon.png "$APP/Contents/Resources/IsolaIcon.png"
cp scripts/Info.plist "$APP/Contents/Info.plist"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
codesign --force --sign - "$APP/Contents/MacOS/isola-network"
codesign --force --sign - --entitlements scripts/Isola.entitlements "$APP"
codesign --verify --deep --strict "$APP"
echo "Built: $APP"
