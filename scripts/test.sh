#!/bin/sh
# Runs the test suite. Extra arguments go to `swift test`, e.g. `scripts/test.sh --filter Scheduler`.
#
# With the Command Line Tools (no Xcode), the compiler's in-process macro plugin loader sometimes
# fails with "plugin for module 'TestingMacros' not found". Loading Swift Testing's macros through
# the out-of-process plugin server avoids that.
set -eu
cd "$(dirname "$0")/.."

server=$(xcrun --find swift-plugin-server)
toolchain_usr=$(dirname "$(dirname "$server")")
plugins="$toolchain_usr/lib/swift/host/plugins/testing"

if [ -d "$plugins" ]; then
    exec swift test -Xswiftc -external-plugin-path -Xswiftc "$plugins#$server" "$@"
else
    exec swift test "$@"
fi
