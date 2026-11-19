#!/bin/sh
# Tests scripts/release.sh from the outside: runs it the way the maintainer would and checks the zip
# and the appcast.
# Slow (it does a full universal release build), so it isn't part of scripts/test.sh.
set -u
cd "$(dirname "$0")/.."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failures=0

fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
pass() { echo "ok: $*"; }

# --- Rejects a missing or malformed version, and makes no zip ---
touch "$tmp/marker"
# An empty argument means "ask", and with no answer (stdin is /dev/null) it must stop too.
for bad in "" "v1.0" "1.0-beta" "1..2" "1.2" "1.2.3.4" "abc"; do
    out=$(scripts/release.sh $bad 2>&1 </dev/null)
    if [ $? -eq 0 ]; then fail "accepted version '$bad'"; else pass "rejects version '$bad'"; fi
    case "$out" in *Usage*) ;; *) fail "no usage message for '$bad': $out" ;; esac
done
if [ -d build/release ] && [ -n "$(find build/release -name '*.zip' -newer "$tmp/marker")" ]; then
    fail "a rejected run made a zip"
fi

# --- Works out the next version from the vX.Y.Z tags (fast: --dry-run stops before building) ---
mkdir -p "$tmp/vrepo/scripts"
cp scripts/release.sh "$tmp/vrepo/scripts/"
(cd "$tmp/vrepo" && git init -q && git -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m t)
next() { (cd "$tmp/vrepo" && scripts/release.sh --dry-run "$@" 2>&1); }
expect() { # expect WHAT VERSION OUTPUT
    case "$3" in *"Releasing $2"*) pass "$1 gives $2" ;; *) fail "$1 should give $2: $3" ;; esac
}
expect "minor with no tags" 0.1.0 "$(next minor </dev/null)"
expect "answering 3 with no tags" 1.0.0 "$(echo 3 | next)"
for tag in v0.9.0 v1.4.2 v1.10.0 v2.0-beta other; do git -C "$tmp/vrepo" tag "$tag"; done
expect "patch after v1.10.0" 1.10.1 "$(next patch </dev/null)"
expect "minor after v1.10.0" 1.11.0 "$(next minor </dev/null)"
expect "major after v1.10.0" 2.0.0 "$(next major </dev/null)"
expect "answering 2 after v1.10.0" 1.11.0 "$(echo 2 | next)"
expect "an explicit higher version" 1.10.1 "$(next 1.10.1 </dev/null)"
for not_higher in 1.10.0 1.9.9; do
    if next "$not_higher" </dev/null >/dev/null; then fail "accepted $not_higher after v1.10.0"; else pass "refuses $not_higher after v1.10.0"; fi
done
if echo x | next >/dev/null; then fail "accepted the answer x"; else pass "refuses the answer x"; fi

# --- Refuses to sign while Packaging/Info.plist has the placeholder update key ---
version=9.8.7
if [ "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Packaging/Info.plist)" = REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY ]; then
    rm -f "build/release/BackMeUp-$version.zip"
    out=$(scripts/release.sh "$version" 2>&1)
    if [ $? -eq 0 ]; then fail "released with the placeholder key"; else pass "refuses the placeholder key"; fi
    case "$out" in *SUPublicEDKey*docs/releasing.md*) pass "says how to add the key" ;; *) fail "unclear refusal: $out" ;; esac
    if [ -e "build/release/BackMeUp-$version.zip" ]; then fail "made a zip with the placeholder key"; fi
else
    echo "skip: Packaging/Info.plist already has a real key, so the placeholder refusal can't be tested here"
fi

# --- With a key, a valid version makes a versioned app zip, signed, and an appcast ---
# Everything runs in a copy of the repo with a throwaway key pair, so neither the real
# Info.plist nor the Keychain is touched. The private key is deleted with $tmp.
mkdir "$tmp/repo" "$tmp/scripts"
rsync -a --exclude .git --exclude .build --exclude build ./ "$tmp/repo/"
cat > "$tmp/scripts/make-key.swift" <<'SWIFT'
import CryptoKit
import Foundation
// Writes a private key file the way Sparkle's generate_keys -x does (the base64 seed), and
// prints the public key.
let key = Curve25519.Signing.PrivateKey()
try key.rawRepresentation.base64EncodedString().write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8)
print(key.publicKey.rawRepresentation.base64EncodedString())
SWIFT
public_key=$(swift "$tmp/scripts/make-key.swift" "$tmp/private-key")
/usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $public_key" "$tmp/repo/Packaging/Info.plist"

zip=$tmp/repo/build/release/BackMeUp-$version.zip
appcast=$tmp/repo/build/release/appcast.xml
# Stand-ins for the tools that could publish something. gh and curl must never run; git may run,
# but never to push or tag. Each logs its call so the checks below can see it.
mkdir "$tmp/bin"
real_git=$(command -v git)
for tool in gh curl; do
    printf '#!/bin/sh\necho "%s $*" >> "%s"\nexit 1\n' "$tool" "$tmp/calls.log" > "$tmp/bin/$tool"
done
printf '#!/bin/sh\necho "git $*" >> "%s"\nexec "%s" "$@"\n' "$tmp/calls.log" "$real_git" > "$tmp/bin/git"
chmod +x "$tmp/bin"/*
touch "$tmp/calls.log"
tags_before=$(git tag; git ls-remote --tags origin 2>/dev/null)

if PATH="$tmp/bin:$PATH" SPARKLE_ED_KEY_FILE="$tmp/private-key" "$tmp/repo/scripts/release.sh" "$version" >"$tmp/release.log" 2>&1; then
    pass "release.sh $version succeeded"
else
    cat "$tmp/release.log"
    fail "release.sh $version failed"
fi

if [ -f "$zip" ]; then
    pass "made $zip"
    mkdir "$tmp/unzipped"
    ditto -x -k "$zip" "$tmp/unzipped"
    app=$tmp/unzipped/BackMeUp.app
    if [ "$(ls "$tmp/unzipped")" = "BackMeUp.app" ]; then pass "zip holds only BackMeUp.app"; else fail "zip holds: $(ls "$tmp/unzipped")"; fi

    for key in CFBundleShortVersionString CFBundleVersion; do
        got=$(/usr/libexec/PlistBuddy -c "Print :$key" "$app/Contents/Info.plist" 2>&1)
        if [ "$got" = "$version" ]; then pass "$key is $version"; else fail "$key is '$got', expected $version"; fi
    done

    # The signature must survive zipping, so check the unzipped copy, not build/BackMeUp.app.
    if codesign --verify --strict --deep "$app" 2>"$tmp/verify.log"; then
        pass "codesign --verify passes on the unzipped app"
    else
        fail "codesign --verify: $(cat "$tmp/verify.log")"
    fi
    details=$(codesign -d --verbose=2 "$app" 2>&1)
    case "$details" in *"Signature=adhoc"*) pass "ad-hoc signed" ;; *) fail "not ad-hoc signed: $details" ;; esac
    # Sparkle (ticket #10) needs library validation off, which here means no hardened runtime.
    # codesign shows it as a flag, such as flags=0x10002(adhoc,runtime).
    flags=$(echo "$details" | sed -n 's/.*flags=[^(]*(\([^)]*\)).*/\1/p')
    case ",$flags," in *,runtime,*|*library-validation*) fail "hardened runtime is on: flags $flags" ;; *) pass "no hardened runtime (flags $flags)" ;; esac

    sparkle=$app/Contents/Frameworks/Sparkle.framework
    if [ -f "$sparkle/Versions/B/Sparkle" ]; then pass "Sparkle.framework is embedded"; else fail "no Sparkle.framework in Contents/Frameworks"; fi
    if otool -l "$app/Contents/MacOS/BackMeUp" | grep -q "path @executable_path/../Frameworks"; then
        pass "the binary looks in Contents/Frameworks"
    else
        fail "no @executable_path/../Frameworks rpath"
    fi
    for code in "$sparkle/Versions/B/Autoupdate" "$sparkle/Versions/B/Updater.app" "$sparkle"; do
        case "$(codesign -d --verbose=2 "$code" 2>&1)" in
            *runtime*) fail "hardened runtime is on for $code" ;;
            *) pass "no hardened runtime for ${code#$app/}" ;;
        esac
    done
    got=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$app/Contents/Info.plist" 2>&1)
    if [ "$got" = "$public_key" ]; then pass "the app carries the public key"; else fail "SUPublicEDKey is '$got'"; fi
else
    fail "no $zip"
fi

# The appcast offers this version from its GitHub release, signed with the key.
if [ -f "$appcast" ]; then
    pass "made appcast.xml"
    enclosure=$(grep '<enclosure' "$appcast")
    attr() { echo "$enclosure" | sed -n "s/.* $1=\"\([^\"]*\)\".*/\1/p"; }
    url=$(attr url)
    expected_url="https://github.com/Blowoffvalve/BackMeUp/releases/download/v$version/BackMeUp-$version.zip"
    if [ "$url" = "$expected_url" ]; then pass "download URL is the release's zip"; else fail "download URL is '$url'"; fi
    if grep -q "<sparkle:version>$version</sparkle:version>" "$appcast"; then pass "appcast version is $version"; else fail "no sparkle:version $version in the appcast"; fi
    length=$(attr length)
    if [ "$length" = "$(stat -f %z "$zip" 2>/dev/null)" ]; then pass "length matches the zip"; else fail "length '$length' doesn't match the zip"; fi
    signature=$(attr 'sparkle:edSignature')
    if [ -n "$signature" ] && swift scripts/verify-update-signature.swift "$public_key" "$signature" "$zip"; then
        pass "the zip's EdDSA signature checks out against the public key"
    else
        fail "bad or missing EdDSA signature '$signature'"
    fi
    if [ "$(grep -c '<item>' "$appcast")" -eq 1 ]; then pass "the appcast has one item"; else fail "the appcast has $(grep -c '<item>' "$appcast") items"; fi
else
    fail "no appcast.xml"
fi

# --- Refuses a private key that doesn't match the app's public key ---
# generate_appcast only warns about that, but users' copies would reject every such update.
other_key=$(swift "$tmp/scripts/make-key.swift" "$tmp/other-private-key")
/usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $other_key" "$tmp/repo/Packaging/Info.plist"
if PATH="$tmp/bin:$PATH" SPARKLE_ED_KEY_FILE="$tmp/private-key" "$tmp/repo/scripts/release.sh" "$version" >"$tmp/mismatch.log" 2>&1; then
    fail "released with a private key that doesn't match SUPublicEDKey"
else
    pass "refuses a private key that doesn't match SUPublicEDKey"
fi
if [ -e "$appcast" ]; then fail "left an appcast signed with the wrong key"; else pass "no appcast with the wrong key"; fi

# --- Never uploads, pushes or tags ---
if grep -Eq '^(gh|curl)|^git (push|tag)' "$tmp/calls.log"; then
    fail "release.sh tried to publish: $(cat "$tmp/calls.log")"
else
    pass "no gh, curl, git push or git tag calls"
fi
if [ "$(git tag; git ls-remote --tags origin 2>/dev/null)" = "$tags_before" ]; then
    pass "no new tags, locally or on origin"
else
    fail "tags changed"
fi

if [ $failures -ne 0 ]; then echo "$failures failure(s)"; exit 1; fi
echo "All release script tests passed"
