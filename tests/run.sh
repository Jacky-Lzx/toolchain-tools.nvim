#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test_root=$(mktemp -d "${TMPDIR:-/tmp}/toolchain-tools-tests.XXXXXX")
trap 'rm -rf "$test_root"' EXIT HUP INT TERM
export XDG_DATA_HOME="$test_root/data" XDG_STATE_HOME="$test_root/state" XDG_CACHE_HOME="$test_root/cache"
export NVIM_LOG_FILE="$test_root/nvim.log" PYTHONDONTWRITEBYTECODE=1
"${NVIM_BIN:-nvim}" --headless -n -u NONE -i NONE --noplugin -l tests/core.lua
