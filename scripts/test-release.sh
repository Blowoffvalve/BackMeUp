#!/bin/sh
# Tests scripts/release.sh from the outside: runs it the way the maintainer would and checks the zip.
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
for bad in "" "v1.0" "1.0-beta" "1..2" "1.2.3.4" "abc"; do
    out=$(scripts/release.sh $bad 2>&1)
    if [ $? -eq 0 ]; then fail "accepted version '$bad'"; else pass "rejects version '$bad'"; fi
    case "$out" in *Usage*) ;; *) fail "no usage message for '$bad': $out" ;; esac
done
if [ -d build/release ] && [ -n "$(find build/release -name '*.zip' -newer "$tmp/marker")" ]; then
    fail "a rejected run made a zip"
fi

# --- A valid version makes build/release/BackMeUp-VERSION.zip holding a versioned app ---
version=9.8.7
zip=build/release/BackMeUp-$version.zip
rm -f "$zip"
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

if PATH="$tmp/bin:$PATH" scripts/release.sh "$version" >"$tmp/release.log" 2>&1; then
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
else
    fail "no $zip"
fi

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
