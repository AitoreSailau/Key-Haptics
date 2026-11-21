#!/bin/bash
# Builds a universal (Apple Silicon + Intel) KeyHaptics.app into ./build
set -euo pipefail
cd "$(dirname "$0")"

APP="build/KeyHaptics.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS"

swiftc -O -swift-version 5 -target arm64-apple-macos12.0  main.swift -o build/kh_arm
swiftc -O -swift-version 5 -target x86_64-apple-macos12.0 main.swift -o build/kh_x86
lipo -create build/kh_arm build/kh_x86 -output "$APP/Contents/MacOS/KeyHaptics"
rm build/kh_arm build/kh_x86

cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

echo "Built: $(pwd)/$APP"
