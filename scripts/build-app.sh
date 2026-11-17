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
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/BackMeUp"
cp Packaging/Info.plist "$app/Contents/Info.plist"
if [ $# -ge 1 ]; then
    # Sparkle compares CFBundleVersion between releases, so it gets the same dotted version.
    plutil -replace CFBundleShortVersionString -string "$1" "$app/Contents/Info.plist"
    plutil -replace CFBundleVersion -string "$1" "$app/Contents/Info.plist"
fi
plutil -lint -s "$app/Contents/Info.plist"

# Ad-hoc signature ("-"), no hardened runtime: the spec needs library validation off so the
# ad-hoc signed app can later load the Sparkle framework.
codesign --force --sign - --timestamp=none "$app"
codesign --verify --strict "$app"

echo "Built $app"
