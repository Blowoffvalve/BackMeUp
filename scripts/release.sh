#!/bin/sh
# Makes a release of BackMeUp on the maintainer's Mac.
# Usage: scripts/release.sh [--dry-run] [patch | minor | major | VERSION]
#
# With no argument it asks what kind of release this is and works out the version from the last
# one: the highest vX.Y.Z tag, locally or on GitHub (0.0.0 if there's none). patch, minor or major
# skip the question. A VERSION (three numbers, such as 1.2.0) is used as given, if it's higher than
# the last release. --dry-run prints the version and stops.
#
# It builds, versions, ad-hoc signs and zips the app into build/release/BackMeUp-VERSION.zip, then
# signs the zip with the Sparkle update key and writes build/release/appcast.xml offering it.
# The private key comes from the login Keychain (where Sparkle's generate_keys put it), or from
# the file named by SPARKLE_ED_KEY_FILE if that's set.
# It never uploads, pushes or tags anything: see docs/releasing.md for the manual upload step.
# Tagging is what records the release, so the next run counts on from it.
set -eu
cd "$(dirname "$0")/.."

repo=https://github.com/Blowoffvalve/BackMeUp
placeholder=REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY

usage() {
    echo "Usage: scripts/release.sh [--dry-run] [patch | minor | major | VERSION]" >&2
    echo "VERSION is three numbers separated by dots, such as 1.2.0" >&2
    exit 64
}

dry_run=false
if [ "${1:-}" = --dry-run ]; then dry_run=true; shift; fi
[ $# -le 1 ] || usage

# The last release: the highest vX.Y.Z tag here or on GitHub. Other tags are ignored.
last=$(
    {
        git for-each-ref --format='%(refname:short)' refs/tags 2>/dev/null || true
        git ls-remote --tags --refs origin 2>/dev/null | sed 's|.*refs/tags/||' || true
    } | sed -n 's/^v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$/\1/p' |
        sort -u -t. -k1,1n -k2,2n -k3,3n | tail -n 1
)
[ -n "$last" ] || last=0.0.0
major=${last%%.*}; rest=${last#*.}; minor=${rest%%.*}; patch=${rest#*.}
next_patch=$major.$minor.$((patch + 1))
next_minor=$major.$((minor + 1)).0
next_major=$((major + 1)).0.0

kind=${1:-}
if [ -z "$kind" ]; then
    if [ "$last" = 0.0.0 ]; then echo "No releases yet."; else echo "Last release: v$last"; fi
    echo "What kind of release is this?"
    echo "  1) Patch  $next_patch  bug fixes only"
    echo "  2) Minor  $next_minor  new features or settings; everything that worked still works"
    echo "  3) Major  $next_major  big changes: something removed, or people must set it up again"
    printf "Choose 1, 2 or 3: "
    if ! read -r answer; then
        echo
        echo "Got no answer. Run this in a terminal, or say which kind: scripts/release.sh patch, minor or major." >&2
        usage
    fi
    case "$answer" in
        1 | patch | Patch) kind=patch ;;
        2 | minor | Minor) kind=minor ;;
        3 | major | Major) kind=major ;;
        *) echo "Stopped: '$answer' isn't 1, 2 or 3." >&2; exit 64 ;;
    esac
fi
case "$kind" in
    patch) version=$next_patch ;;
    minor) version=$next_minor ;;
    major) version=$next_major ;;
    *)
        version=$kind
        echo "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || usage
        # Users' copies only install a version higher than theirs.
        if [ "$(printf '%s\n%s\n' "$last" "$version" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)" != "$version" ] ||
            [ "$version" = "$last" ]; then
            echo "$version isn't higher than the last release, v$last." >&2
            exit 65
        fi
        ;;
esac
if [ "$last" = 0.0.0 ]; then echo "Releasing $version, the first release."; else echo "Releasing $version (last release: v$last)."; fi
if $dry_run; then exit 0; fi

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

echo
echo "Next, by hand (docs/releasing.md, step 2). Tagging also records this version for the next release:"
echo "  git tag v$version && git push origin v$version"
echo "  gh release create v$version $zip $out/appcast.xml --title \"BackMeUp $version\" --notes \"...\""
