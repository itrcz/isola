#!/bin/bash
# Build a fresh app, package it without host metadata, and verify the delivered ZIP.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' scripts/Info.plist)
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid release version' >&2; exit 1; }
mkdir -p .build dist/release
STAGING=$(mktemp -d "$PWD/.build/release.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
ISOLA_APP_OUTPUT="$STAGING/Isola.app" bash scripts/build.sh
ARCHIVE="Isola-$VERSION-macos-arm64.zip"
ditto -c -k --norsrc --noextattr --noqtn --keepParent "$STAGING/Isola.app" "$PWD/dist/release/$ARCHIVE"
mkdir "$STAGING/verify"
ditto -x -k "$PWD/dist/release/$ARCHIVE" "$STAGING/verify"
codesign --verify --deep --strict "$STAGING/verify/Isola.app"
file "$STAGING/verify/Isola.app/Contents/MacOS/Isola"
(cd dist/release && shasum -a 256 "$ARCHIVE" > SHA256SUMS.txt && shasum -a 256 -c SHA256SUMS.txt)
echo "Release: $PWD/dist/release/$ARCHIVE"
