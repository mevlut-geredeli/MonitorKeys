#!/bin/sh
# Builds MonitorKeys.app into ./build. Requires Xcode Command Line Tools on Apple Silicon.
set -eu
cd "$(dirname "$0")"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Info.plist)
mkdir -p build/MonitorKeys.app/Contents/MacOS
xcrun clang -O2 -Wall -Wextra -Werror -fobjc-arc -mmacosx-version-min=14.2 -c AudioEngine.m -o build/AudioEngine.o
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx14.2 -import-objc-header AudioEngine.h main.swift build/AudioEngine.o \
  -framework AppKit -framework CoreAudio -framework ApplicationServices -framework ServiceManagement \
  -o build/MonitorKeys.app/Contents/MacOS/MonitorKeys
cp Info.plist build/MonitorKeys.app/Contents/Info.plist
# A persistent local signing identity (see scripts/make-signing-identity.sh) keeps macOS
# permissions valid across rebuilds. Without one, an ad-hoc signature is used.
IDENTITY="MonitorKeys Local Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then SIGN="$IDENTITY"; else SIGN="-"; fi
codesign --force --sign "$SIGN" --identifier "$BUNDLE_ID" build/MonitorKeys.app 2>&1 | grep -v 'replacing existing signature' || true
[ "$SIGN" = "-" ] && echo "note: ad-hoc signed; run scripts/make-signing-identity.sh to keep permissions across rebuilds"
echo "Built: $PWD/build/MonitorKeys.app (signed: $SIGN)"
