#!/bin/sh
# Makes a release zip of BackMeUp.app for a given version, on the maintainer's Mac.
# Usage: scripts/release.sh VERSION   (for example: scripts/release.sh 1.2.0)
#
# It builds, versions, ad-hoc signs and zips the app into build/release/BackMeUp-VERSION.zip.
# It never uploads, pushes or tags anything: see docs/releasing.md for the manual upload step.
set -eu
cd "$(dirname "$0")/.."

usage() {
    echo "Usage: scripts/release.sh VERSION" >&2
    echo "VERSION is one to three numbers separated by dots, such as 1.2.0" >&2
    exit 64
}

[ $# -eq 1 ] || usage
version=$1
echo "$version" | grep -Eq '^[0-9]+(\.[0-9]+){0,2}$' || usage

out=build/release
zip=$out/BackMeUp-$version.zip

scripts/build-app.sh "$version"

mkdir -p "$out"
rm -f "$zip"
# ditto keeps the bundle's symlinks, extended attributes and signature intact, unlike zip(1).
ditto -c -k --sequesterRsrc --keepParent build/BackMeUp.app "$zip"

echo "Made $zip"
