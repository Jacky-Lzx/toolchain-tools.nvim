#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test_root=$(mktemp -d "${TMPDIR:-/tmp}/toolchain-tools-tests.XXXXXX")
trap 'rm -rf "$test_root"' EXIT HUP INT TERM
export XDG_DATA_HOME="$test_root/data" XDG_STATE_HOME="$test_root/state" XDG_CACHE_HOME="$test_root/cache"
export NVIM_LOG_FILE="$test_root/nvim.log" PYTHONDONTWRITEBYTECODE=1
"${NVIM_BIN:-nvim}" --headless -n -u NONE -i NONE --noplugin -l tests/core.lua
"${NVIM_BIN:-nvim}" --headless -n -u NONE -i NONE --noplugin -l tests/api.lua
"${NVIM_BIN:-nvim}" --headless -n -u NONE -i NONE --noplugin -l tests/backends.lua
"${NVIM_BIN:-nvim}" --headless -n -u NONE -i NONE --noplugin -l tests/hooks.lua
"${NVIM_BIN:-nvim}" --headless -n -u NONE -i NONE --noplugin -l tests/optional.lua
"${NVIM_BIN:-nvim}" --headless -n -u NONE -i NONE --noplugin -l tests/health.lua
"${NVIM_BIN:-nvim}" --headless -n -u NONE -i NONE --noplugin -l tests/runtime.lua
"${NVIM_BIN:-nvim}" --headless -n -u NONE -i NONE --noplugin -l tests/tools.lua
"${NVIM_BIN:-nvim}" --headless -n -u NONE -i NONE --noplugin -l tests/tool_downloads.lua
"${NVIM_BIN:-nvim}" --headless -n -u NONE -i NONE --noplugin -l tests/tool_locks.lua
"${NVIM_BIN:-nvim}" --headless -n -u NONE -i NONE --noplugin -l tests/tool_versions.lua
python3 tests/tui.py
python3 tests/versions_tui.py
if [ "${1:-}" = "--integration" ]; then
  "${NVIM_BIN:-nvim}" --headless -n -u NONE -i NONE --noplugin -l tests/parsers.lua
  "${NVIM_BIN:-nvim}" --headless -n -u NONE -i NONE --noplugin -l tests/integration.lua
elif [ "${1:-}" = "--parsers" ]; then
  "${NVIM_BIN:-nvim}" --headless -n -u NONE -i NONE --noplugin -l tests/parsers.lua
elif [ "${1:-}" = "--tools" ]; then
  python3 tests/clean_tools.py
elif [ "$#" -gt 0 ]; then
  printf 'Usage: sh tests/run.sh [--integration|--parsers|--tools]\n' >&2
  exit 2
fi
