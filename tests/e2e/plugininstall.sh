#!/bin/sh
# End-to-end test of "Install plugin from phone" inside the KOReader emulator:
# a GitHub-layout .zip (with junk files) is sent like a phone would, confirmed,
# KOReader restarts and loads it; a second version replaces it; Undo brings
# the first version back. Fails on any wrong step or Lua error in the log.
#
#   tests/e2e/plugininstall.sh
set -e
cd "$(dirname "$0")/../.."
R=$(pwd)
W=${KO_PI_WORK:-/tmp/kindleui-pi-e2e}
rm -rf "$W"; mkdir -p "$W/plugins" "$W/patches" "$W/e2e" "$W/books" "$W/zips"
cp -r kindleui.koplugin "$W/plugins/"
cp tests/e2e/plugininstall/*.lua "$W/patches/"
cp tests/books/*.epub "$W/books/" 2> /dev/null || tests/make_library.sh "$W/books" 5 2 > /dev/null

# greeter.koplugin as GitHub's "Download ZIP" of a repo named greeter.koplugin
zipv() {
    d="$W/src$1/greeter.koplugin-main"
    mkdir -p "$d/.github" "$d/.git" "$W/src$1/__MACOSX/greeter.koplugin-main"
    cat > "$d/_meta.lua" <<LUA
local _ = require("gettext")
return { name = "greeter", fullname = _("Greeter"), description = _("Logs a line when it loads (v$1).") }
LUA
    cat > "$d/main.lua" <<LUA
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local Greeter = WidgetContainer:extend{ name = "greeter", is_doc_only = false }
function Greeter:init() logger.info("GREETER LOADED v$1") end
return Greeter
LUA
    echo "ci" > "$d/.github/ci.yml"; echo "x" > "$d/.git/HEAD"; echo "x" > "$d/.DS_Store"
    echo "x" > "$W/src$1/__MACOSX/greeter.koplugin-main/._main.lua"; echo "readme" > "$d/README.md"
    (cd "$W/src$1" && zip -qr "$W/zips/greeter-v$1.zip" .)
}
zipv 1; zipv 2
chmod -R a+rwX "$W"

fail() { echo "PLUGIN INSTALL E2E: FAILED: $*"; tools/emulator.sh log | grep -E "KINDLEUI PI|GREETER" | tail -20; exit 1; }
# Log lines since the last mark (so an earlier run's lines never match).
MARK=0
mark() { MARK=$(tools/emulator.sh log 2> /dev/null | wc -l); }
since_start() { tools/emulator.sh log | tail -n +"$((MARK + 1))"; }
wait_for() { for _ in $(seq "${2:-60}"); do since_start | grep -q "$1" && return 0; sleep 1; done; fail "timed out waiting for: $1"; }
cmd() { mark; echo "$1" > "$W/e2e/cmd"; wait_for "KINDLEUI PI done $1" 30; }
send() { # zip → the Send Plugin screen, like the phone page does
    cmd open
    url=$(since_start | grep -o 'KINDLEUI PI url [^ ]*' | tail -1 | cut -d' ' -f4)
    [ -n "$url" ] || fail "no URL"
    code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/octet-stream' \
        --data-binary @"$1" "$url/upload?name=$(basename "$1")" || true)
    [ "$code" = 200 ] || fail "upload answered $code"
    curl -s -X POST "$url/finish" > /dev/null || fail "finish"
    sleep 3
}
restart() { mark; tools/emulator.sh restart; wait_for "KINDLEUI PI ready" 90; }

docker rm -f "${KO_NAME:-kindleui-emu}" > /dev/null 2>&1 || true
KO_PLUGINS_DIR="$W/plugins" KO_PATCHES="$W/patches" KO_EXTRA_MOUNT="$W/e2e:/e2e" tools/emulator.sh start "$W/books" > /dev/null
wait_for "KINDLEUI PI ready" 90

echo "1. install v1 (new plugin)"
send "$W/zips/greeter-v1.zip"
tools/emulator.sh shot "$W/confirm-new.png"
cmd confirm
since_start | grep -q "confirm text: Install this plugin? | Greeter (greeter.koplugin).*This is a new plugin" || fail "confirm text (new)"
wait_for "after confirm: Greeter is installed. Restart KOReader" 10
[ -f "$W/plugins/greeter.koplugin/main.lua" ] || fail "plugin not installed"
for junk in .github .git .DS_Store; do [ ! -e "$W/plugins/greeter.koplugin/$junk" ] || fail "junk installed: $junk"; done
[ -f "$W/plugins/greeter.koplugin/README.md" ] || fail "README.md inside the plugin folder not installed"
restart
wait_for "GREETER LOADED v1" 5

echo "2. replace with v2"
send "$W/zips/greeter-v2.zip"
tools/emulator.sh shot "$W/confirm-replace.png"
cmd confirm
wait_for "after confirm: Greeter is installed" 10
since_start | grep -q "confirm text: .*It replaces the installed version" || fail "confirm text (replace)"
[ -d "$W/plugins/.greeter.koplugin.undo" ] || fail "previous version not kept"
restart
wait_for "GREETER LOADED v2" 5

echo "3. undo brings v1 back"
cmd undo
since_start | grep -q "undo ok greeter.koplugin" || fail "undo"
since_start | grep -q "can undo again: false" || fail "second undo offered"
restart
wait_for "GREETER LOADED v1" 5
[ ! -e "$W/plugins/.greeter.koplugin.undo" ] || fail "undo folder left"
ls -A "$W/plugins" | grep -qE '\.(new|old)$' && fail "staging folder left"

ERRORS=$(tools/emulator.sh log | grep -E "attempt to|stack traceback|kindleui[^ ]*\.lua:[0-9]+:|KINDLEUI PI FAIL" || true)
[ -z "$ERRORS" ] || fail "Lua errors in the log: $ERRORS"
echo "screenshots: $W/confirm-new.png $W/confirm-replace.png"
echo "PLUGIN INSTALL E2E: OK"
