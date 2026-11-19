#!/bin/sh
# Builds build/BackMeUp.app: a release build, wrapped in an app bundle and ad-hoc signed.
# Needs only the Command Line Tools, not Xcode.
# Usage: scripts/build-app.sh [VERSION]. With a VERSION, both of the bundle's version fields are set
# to it; without one, they keep the placeholder in Packaging/Info.plist. scripts/release.sh passes it.
set -eu
cd "$(dirname "$0")/.."

app=build/BackMeUp.app

# Universal binary, so Intel Macs on macOS 14 can run it too.
build="swift build -c release --arch arm64 --arch x86_64"
$build --product BackMeUp
binary="$($build --show-bin-path)/BackMeUp"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp "$binary" "$app/Contents/MacOS/BackMeUp"
# The binary looks for Sparkle.framework next to itself; in the bundle it's in Contents/Frameworks.
install_name_tool -add_rpath @executable_path/../Frameworks "$app/Contents/MacOS/BackMeUp"

# Sparkle, for in-app updates. Its XPC services are only for sandboxed apps, so they're left out.
sparkle=$app/Contents/Frameworks/Sparkle.framework
ditto "$(dirname "$binary")/Sparkle.framework" "$sparkle"
rm -rf "$sparkle/XPCServices" "$sparkle/Versions/B/XPCServices"
cp Packaging/Info.plist "$app/Contents/Info.plist"
if [ $# -ge 1 ]; then
    # Sparkle compares CFBundleVersion between releases, so it gets the same dotted version.
    plutil -replace CFBundleShortVersionString -string "$1" "$app/Contents/Info.plist"
    plutil -replace CFBundleVersion -string "$1" "$app/Contents/Info.plist"
fi
plutil -lint -s "$app/Contents/Info.plist"

# The app icon, drawn from the same code as the menu bar icon (Sources/BackMeUp/Logo.swift).
icon_tmp=$(mktemp -d)
trap 'rm -rf "$icon_tmp"' EXIT
swiftc -O -o "$icon_tmp/make-icon" Sources/BackMeUp/Logo.swift scripts/make-icon/main.swift
"$icon_tmp/make-icon" "$icon_tmp/AppIcon.iconset"
iconutil -c icns -o "$app/Contents/Resources/AppIcon.icns" "$icon_tmp/AppIcon.iconset"

# Ad-hoc signature ("-"), no hardened runtime: the spec needs library validation off so the
# ad-hoc signed app can load the Sparkle framework. Sparkle ships with the runtime on, so its
# parts are re-signed the same way, inside out, before the app itself.
for code in "$sparkle/Versions/B/Autoupdate" "$sparkle/Versions/B/Updater.app" "$sparkle"; do
    codesign --force --sign - --timestamp=none "$code"
done
codesign --force --sign - --timestamp=none "$app"
codesign --verify --strict --deep "$app"

echo "Built $app"
