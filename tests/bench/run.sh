#!/bin/sh
# Scripted timing run in the KOReader emulator (see tools/emulator.sh).
#
#   tests/bench/run.sh [books=150] [with_progress=50] [cpus]
#
# Builds a synthetic library, starts KOReader at Paperwhite 12 geometry with
# this plugin, drives Home → Library (cold, then warm) → page turns →
# Installed Plugins → restart (cache load), and prints every
# "KindleUI perf:" line. Pass a CPU quota (e.g. 0.1) for a crude slow-device
# proxy; it is NOT a Kindle measurement.
set -e
cd "$(dirname "$0")/../.."
N=${1:-150}; P=${2:-50}; CPUS=$3
LIB=${KO_BENCH_LIB:-/tmp/kindleui-bench-lib}
E=tools/emulator.sh
tests/make_library.sh "$LIB" "$N" "$P"

KO_PATCHES=$(pwd)/tests/bench KO_CPUS=$CPUS $E start "$LIB" > /dev/null
slow=1; [ -n "$CPUS" ] && slow=4
w() { sleep $(( $1 * slow )); }

# First run opens KOReader's quickstart guide in the reader: leave it through
# the reader's top menu → file browser icon (that also exercises the
# "Home appears when the file browser is created" path).
w 4; $E tap 632 60; w 2; $E tap 865 55; w 5
$E tap 300 675; w 12           # My Library (cold cache: sidecar reads + cover extraction)
$E key Escape; w 3
$E tap 300 675; w 6            # My Library again (warm cache)
$E swipe 1000 900 200 900; w 8 # page 2 (covers extracted on first visit)
$E swipe 200 900 1000 900; w 4 # back to page 1 (all cached)
$E key Escape; w 3
$E tap 300 990; w 4            # Installed Plugins (lazy)
$E key Escape; w 2
$E tap 300 990; w 4            # Installed Plugins again
$E key Escape; w 2
$E restart; w 4                # new process: Home at startup with cache on disk
$E tap 300 675; w 6            # Library after restart (cache file load)
$E log | grep -E "KindleUI perf:" | sed -E 's/^[0-9/]+-([0-9:]+) INFO  KindleUI perf: /\1 /'
$E log | grep -E "KindleUI.*(rror|attempt)|traceback" || true
