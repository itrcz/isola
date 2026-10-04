#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo 'Tests require Apple Silicon macOS.' >&2; exit 1; }
case "${1:-}" in ''|--ui|--disk) ;; *) echo 'Usage: bash scripts/test.sh [--ui|--disk]' >&2; exit 1 ;; esac
mkdir -p .build
SWIFT=(xcrun swiftc -swift-version 5 -target arm64-apple-macosx14.0 -parse-as-library)
(cd Network && go test -race ./... && go build -o ../.build/isola-network-test .)
python3 scripts/test_helper.py .build/isola-network-test
for TEST in ClipboardSmoke GuestPerformanceSmoke HomeMirrorsSmoke; do
    "${SWIFT[@]}" Sources/Shared/*.swift "Tests/$TEST.swift" -o ".build/$TEST" -framework AppKit
    ".build/$TEST"
done
"${SWIFT[@]}" -D WINDOW_LIFECYCLE_TEST Sources/Shared/*.swift Sources/Isola/*.swift Tests/ResourcesSmoke.swift -o .build/ResourcesSmoke -framework AppKit -framework SwiftUI -framework Virtualization -framework Security
.build/ResourcesSmoke
if [[ "${1:-}" == --ui ]]; then
    "${SWIFT[@]}" -D WINDOW_LIFECYCLE_TEST Sources/Shared/*.swift Sources/Isola/*.swift Tests/WindowLifecycleSmoke.swift -o .build/WindowLifecycleSmoke -framework AppKit -framework SwiftUI -framework Virtualization -framework Security
    .build/WindowLifecycleSmoke
fi
if [[ "${1:-}" == --disk ]]; then
    "${SWIFT[@]}" Sources/Isola/DiskExpansion.swift Sources/Isola/VMDirectoryLock.swift Tests/DiskExpansionSmoke.swift -o .build/disk-expansion-smoke
    python3 scripts/test_disk_expansion.py
fi
