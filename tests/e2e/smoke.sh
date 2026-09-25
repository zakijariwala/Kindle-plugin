#!/bin/sh
# Emulator smoke test: runs tests/e2e/patches/2-kindleui-smoke.lua inside the
# real KOReader build (see tools/emulator.sh), which opens every screen and
# action of the plugin, then fails if any step failed or if the KOReader log
# contains a Lua error from the plugin (including errors while painting).
#
#   tests/e2e/smoke.sh [books=60]
set -e
cd "$(dirname "$0")/../.."
LIB=${KO_SMOKE_LIB:-/tmp/kindleui-smoke-lib}
tests/make_library.sh "$LIB" "${1:-60}" 20 > /dev/null
chmod -R a+rwX "$LIB"
KO_PATCHES="$(pwd)/tests/e2e/patches" tools/emulator.sh start "$LIB" > /dev/null
for _ in $(seq 120); do
    tools/emulator.sh log | grep -q "KINDLEUI SMOKE DONE" && break
    sleep 1
done
sleep 3 # let the last paint happen
LOG=$(tools/emulator.sh log)
echo "$LOG" | grep "KINDLEUI SMOKE" | sed -E 's/^[0-9/]+-[0-9:]+ [A-Z]+ +//'
ERRORS=$(echo "$LOG" | grep -E "attempt to|stack traceback|kindleui[^ ]*\.lua:[0-9]+:" | grep -v "KINDLEUI SMOKE" || true)
if echo "$LOG" | grep -q "KINDLEUI SMOKE FAIL" || ! echo "$LOG" | grep -q "KINDLEUI SMOKE DONE failures=0"; then
    echo "SMOKE: FAILED (a step failed or the run did not finish)"
    exit 1
fi
if [ -n "$ERRORS" ]; then
    echo "SMOKE: FAILED (Lua errors in the log):"
    echo "$ERRORS"
    exit 1
fi
echo "SMOKE: OK"
