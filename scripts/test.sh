#!/bin/sh
# Builds and runs the test suite with the toolchain this package needs
# (xcode-select may point at the Command Line Tools, which lack `metal`),
# and gives up after 8 minutes rather than hang on a stuck PTY test.
# Serial by default: in parallel, the tests that start real worker processes
# and git worktrees run out of time on a loaded laptop and fail at random;
# one at a time the suite takes ~30s and passes. Pass --parallel to override.
# Extra arguments go to `swift test`, e.g. scripts/test.sh --filter Orchestrator
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
# The picker reads the user's provider switches; the tests must not.
export VITRA_PROVIDERS_FILE=/nonexistent/vitra-test-providers.json
case " $* " in *" --parallel "*) ;; *) set -- --no-parallel "$@" ;; esac
exec perl -e 'alarm 480; exec @ARGV' swift test "$@"
