#!/bin/sh
# Builds and runs the test suite with the toolchain this package needs
# (xcode-select may point at the Command Line Tools, which lack `metal`),
# and gives up after 8 minutes rather than hang on a stuck PTY test.
# Extra arguments go to `swift test`, e.g. scripts/test.sh --filter Orchestrator
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
exec perl -e 'alarm 480; exec @ARGV' swift test "$@"
