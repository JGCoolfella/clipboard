#!/bin/zsh
set -eu
cd "${0:A:h}/.."
APP="$PWD/dist/Clipboard.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -swift-version 6 -warnings-as-errors -O -target arm64-apple-macos14.0 Sources/*.swift -o "$APP/Contents/MacOS/Clipboard" -framework AppKit -framework SwiftUI -framework Carbon -framework Security -framework ServiceManagement -framework CryptoKit
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ ! -f Resources/AppIcon.icns ]]; then
  xcrun swift scripts/icon.swift "$PWD/dist/AppIcon.iconset"
  python3 scripts/package_icon.py "$PWD/dist/AppIcon.iconset" Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Resources/Info.plist)
codesign --force --sign - --options runtime --timestamp=none --identifier "$BUNDLE_ID" "$APP"
codesign --verify --deep --strict "$APP"
printf 'Built %s\n' "$APP"
