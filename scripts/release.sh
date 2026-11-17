#!/bin/sh
# Makes a release of BackMeUp for a given version, on the maintainer's Mac.
# Usage: scripts/release.sh VERSION   (for example: scripts/release.sh 1.2.0)
#
# It builds, versions, ad-hoc signs and zips the app into build/release/BackMeUp-VERSION.zip, then
# signs the zip with the Sparkle update key and writes build/release/appcast.xml offering it.
# The private key comes from the login Keychain (where Sparkle's generate_keys put it), or from
# the file named by SPARKLE_ED_KEY_FILE if that's set.
# It never uploads, pushes or tags anything: see docs/releasing.md for the manual upload step.
set -eu
cd "$(dirname "$0")/.."

repo=https://github.com/Blowoffvalve/BackMeUp
placeholder=REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY

usage() {
    echo "Usage: scripts/release.sh VERSION" >&2
    echo "VERSION is one to three numbers separated by dots, such as 1.2.0" >&2
    exit 64
}

[ $# -eq 1 ] || usage
version=$1
echo "$version" | grep -Eq '^[0-9]+(\.[0-9]+){0,2}$' || usage

# Users' copies only install updates signed with the key in Info.plist, so a release built
# with the placeholder could never be updated. Check before spending time on the build.
public_key=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Packaging/Info.plist 2>/dev/null || true)
if [ -z "$public_key" ] || [ "$public_key" = "$placeholder" ] ||
    [ "$(printf '%s' "$public_key" | base64 -D 2>/dev/null | wc -c | tr -d ' ')" != 32 ]; then
    echo "Packaging/Info.plist has no real SUPublicEDKey yet, so the update can't be signed." >&2
    echo "Do the one-time key setup in docs/releasing.md first." >&2
    exit 65
fi

out=build/release
zip=$out/BackMeUp-$version.zip

scripts/build-app.sh "$version"

mkdir -p "$out"
rm -f "$zip" "$out/appcast.xml"
# ditto keeps the bundle's symlinks, extended attributes and signature intact, unlike zip(1).
ditto -c -k --sequesterRsrc --keepParent build/BackMeUp.app "$zip"
echo "Made $zip"

# Sign the zip and write the appcast with Sparkle's generate_appcast, which SwiftPM fetched with
# the Sparkle package. It works on a folder of archives, so give it one holding only this zip:
# the appcast offers just the newest version, which is all Sparkle needs.
tools=.build/artifacts/sparkle/Sparkle/bin
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
cp "$zip" "$staging/"
set -- --download-url-prefix "$repo/releases/download/v$version/" --link "$repo" --maximum-deltas 0
if [ -n "${SPARKLE_ED_KEY_FILE:-}" ]; then
    set -- "$@" --ed-key-file "$SPARKLE_ED_KEY_FILE"
fi
"$tools/generate_appcast" "$@" "$staging"

# generate_appcast only warns when the private key doesn't match the app's public key, but users'
# copies would then refuse the update. Check the signature the way they will before keeping it.
signature=$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' "$staging/appcast.xml")
if [ -z "$signature" ] || ! swift scripts/verify-update-signature.swift "$public_key" "$signature" "$zip"; then
    echo "The update's signature doesn't match SUPublicEDKey in Packaging/Info.plist." >&2
    echo "Sign with the private key that goes with it: see docs/releasing.md." >&2
    exit 1
fi
cp "$staging/appcast.xml" "$out/appcast.xml"
echo "Made $out/appcast.xml"
