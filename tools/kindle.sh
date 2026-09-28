#!/bin/sh
# Runs this repository's checks on a real Kindle, over SSH (KOReader's own SSH
# server: Tools → More tools → SSH server → Start). The same tests that run in
# the container/emulator, but on the device:
#
#   tools/kindle.sh setup-key            create an SSH key and say where it goes
#   tools/kindle.sh setup                install the device-test patches (once; then
#                                        restart KOReader once from its menu)
#   tools/kindle.sh teardown             remove them again (restart KOReader afterwards)
#   tools/kindle.sh ssh [command]        shell (or one command) on the Kindle
#   tools/kindle.sh deploy               copy kindleui.koplugin to the Kindle (whole-folder swap)
#   tools/kindle.sh restart              KOReader's own restart (needs setup)
#   tools/kindle.sh log [lines]          tail of koreader/crash.log
#   tools/kindle.sh unit                 tests/test_*.lua with KOReader's LuaJIT on the Kindle
#   tools/kindle.sh smoke [books=60]     the emulator smoke patch, in a scratch profile
#   tools/kindle.sh send [files...]      real Wi-Fi transfer: this computer plays the phone
#       env: SKIP_BOOKS=1; PLUGIN_ZIP=<zip> (default: a tiny test plugin);
#            INSTALL=1 PLUGIN_NAME=<name> taps Install and checks it loads
#   tools/kindle.sh all                  deploy + restart + unit + smoke + send
#
# Connection: KINDLE_HOST=<ip> (or put the IP in .kindle-host), KINDLE_PORT
# (default 2222), KINDLE_KEY (default ~/.ssh/kindle_ed25519). KOReader's SSH
# server reads keys from koreader/settings/SSH/authorized_keys.
#
# Restarts: always KOReader's own restart (exit code 85, through the
# tests/device/2-kindleui-devctl.lua patch). Killing KOReader and launching it
# again hands the screen back to the Kindle framework and grabs it again
# seconds later; on a Paperwhite (FW 5.19) that rebooted the device twice.
#
# Nothing here touches the real library or settings: `smoke` switches
# KOReader's data folder to /mnt/us/kindleui-devtest/home for one run
# (tests/device/1-kindleui-sandbox.lua), with a synthetic library next to it,
# then restarts into the real profile and deletes the folder.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
HOST=${KINDLE_HOST:-$(cat .kindle-host 2>/dev/null || true)}
PORT=${KINDLE_PORT:-2222}
KEY=${KINDLE_KEY:-$HOME/.ssh/kindle_ed25519}
KO=/mnt/us/koreader
WORK=/mnt/us/kindleui-devtest

die() { echo "kindle.sh: $*" >&2; exit 1; }
need_host() { [ -n "$HOST" ] || die "set KINDLE_HOST=<Kindle IP> (shown in KOReader: Network → Network info)"; }
k() { # run a command on the Kindle
    need_host
    ssh -p "$PORT" ${KEY:+-i "$KEY"} -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="$HOME/.ssh/known_hosts_kindle" -o ConnectTimeout=8 \
        -o ServerAliveInterval=10 -o LogLevel=ERROR root@"$HOST" "$@"
}
# tar a local file or folder into a Kindle folder (no scp/rsync needed on the device)
push() { # push <local path> <remote folder>
    tar -C "$(dirname "$1")" -cf - "$(basename "$1")" | k "mkdir -p '$2' && tar -C '$2' -xf -"
}
log_size() { k "wc -c < $KO/crash.log" | tr -d ' \r'; }
log_since() { k "tail -c +$(( $1 + 1 )) $KO/crash.log"; }
wait_log() { # wait_log <offset> <pattern> <seconds>
    i=0
    while [ $i -lt "$3" ]; do
        log_since "$1" 2>/dev/null | grep -q "$2" && return 0
        sleep 2; i=$((i + 2))
    done
    return 1
}
ctl() { k "echo '$*' > /tmp/kindleui-devctl.cmd"; } # a command for the devctl patch
need_devctl() {
    k "test -f $KO/patches/2-kindleui-devctl.lua" ||
        die "run 'tools/kindle.sh setup' first, then restart KOReader once from its menu"
}
ko_restart() { # KOReader's own restart; waits until Home is shown again
    need_devctl
    off=$(log_size)
    ctl restart
    wait_log "$off" "KINDLEUI DEVCTL ready" 150 || die "KOReader did not come back after a restart"
    wait_log "$off" "KindleUI perf: home open" 30 || true
}

cmd_setup() {
    need_host
    k "mkdir -p $KO/patches"
    push tests/device/1-kindleui-sandbox.lua "$KO/patches"
    push tests/device/2-kindleui-devctl.lua "$KO/patches"
    k "rm -f /tmp/kindleui-sandbox"
    echo "Installed the device-test patches in $KO/patches."
    echo "Restart KOReader once from its menu (☰ → Exit → Restart KOReader); after that"
    echo "tools/kindle.sh restarts it by itself."
}

cmd_teardown() {
    k "rm -f $KO/patches/1-kindleui-sandbox.lua $KO/patches/2-kindleui-devctl.lua $KO/patches/2-kindleui-smoke.lua \
        /tmp/kindleui-sandbox /tmp/kindleui-devctl.cmd; rm -rf $WORK"
    echo "Removed. Restart KOReader from its menu to unload them."
}

cmd_deploy() {
    need_host
    tmp=$(mktemp -d)
    cp -r kindleui.koplugin "$tmp/kindleui.koplugin"
    git rev-parse --short HEAD > "$tmp/kindleui.koplugin/BUILD" 2>/dev/null || true
    k "rm -rf $KO/plugins/.kindleui.koplugin.new"
    tar -C "$tmp" -cf - kindleui.koplugin | k "mkdir -p $KO/plugins/.kindleui.koplugin.new && tar -C $KO/plugins/.kindleui.koplugin.new -xf - &&
        cd $KO/plugins && rm -rf .kindleui.koplugin.old && { [ ! -d kindleui.koplugin ] || mv kindleui.koplugin .kindleui.koplugin.old; } &&
        mv .kindleui.koplugin.new/kindleui.koplugin kindleui.koplugin && rm -rf .kindleui.koplugin.new .kindleui.koplugin.old"
    rm -rf "$tmp"
    echo "deployed to $KO/plugins/kindleui.koplugin (restart KOReader to load it)"
}

cmd_unit() {
    need_host
    k "rm -rf $WORK/unit && mkdir -p $WORK/unit/shim"
    push kindleui.koplugin "$WORK/unit"
    push tests "$WORK/unit"
    # KOReader ships lfs as libs/libkoreader-lfs; the tests ask for plain "lfs".
    # Loaded from the .so directly: some tests preload libs/libkoreader-lfs as "lfs".
    k "echo 'return package.loadlib(\"$KO/libs/libkoreader-lfs.so\", \"luaopen_lfs\")()' > $WORK/unit/shim/lfs.lua"
    # Run from the test copy (like tests/run.sh from the repo root), with
    # KOReader's own modules and C libraries by absolute path.
    k "cd $WORK/unit && export LUA_PATH='./kindleui.koplugin/?.lua;./tests/?.lua;./shim/?.lua;$KO/?.lua;$KO/common/?.lua;$KO/frontend/?.lua;;' \
         LUA_CPATH='$KO/common/?.so;$KO/libs/?.so;$KO/?.so;;' TMPDIR=$WORK/unit/tmp KOREADER_BASE=$KO && mkdir -p \$TMPDIR && status=0
       echo '### syntax (on-device LuaJIT)'
       for f in \$(find kindleui.koplugin -name '*.lua'); do $KO/luajit -bl \"\$f\" > /dev/null || { echo \"syntax error: \$f\"; status=1; }; done
       for t in tests/test_*.lua; do echo \"### \${t##*/}\"; $KO/luajit \"\$t\" || status=1; done
       rm -rf $WORK/unit; exit \$status"
}

cmd_smoke() {
    need_host
    need_devctl
    n=${1:-60} # the smoke patch expects the emulator's 60 books
    tmp=$(mktemp -d)
    tests/make_library.sh "$tmp/books" "$n" 20 > /dev/null
    # The smoke patch lives in the real patches folder for this run, so it
    # must do nothing outside the scratch profile; it refers to the
    # emulator's /books, pointed at the device copy.
    { echo "if require(\"datastorage\"):getDataDir() ~= \"$WORK/home\" then return end"
      sed "s#\"/books/#\"$WORK/books/#g" tests/e2e/patches/2-kindleui-smoke.lua; } > "$tmp/2-kindleui-smoke.lua"
    mkdir -p "$tmp/home"
    cat > "$tmp/home/settings.reader.lua" <<LUA
return {
    ["home_dir"] = "$WORK/books",
    ["lastdir"] = "$WORK/books",
    ["quickstart_shown_version"] = 999999999999,
}
LUA
    k "rm -rf $WORK && mkdir -p $WORK"
    push "$tmp/books" "$WORK"
    push "$tmp/home" "$WORK"
    push "$tmp/2-kindleui-smoke.lua" "$KO/patches"
    rm -rf "$tmp"
    # never leave the smoke patch or the sandbox switch behind
    trap 'k "rm -f $KO/patches/2-kindleui-smoke.lua /tmp/kindleui-sandbox" 2>/dev/null || true' EXIT
    k "echo $WORK/home > /tmp/kindleui-sandbox"
    off=$(log_size)
    ko_restart
    log_since "$off" | grep -q "KINDLEUI SANDBOX data folder $WORK/home" || die "the scratch profile was not used"
    echo "smoke running in a scratch profile ($WORK/home)..."
    ok=0
    wait_log "$off" "KINDLEUI SMOKE DONE" 400 && ok=1
    sleep 3
    LOG=$(log_since "$off")
    # (the switch was used up by that start: this restart is the real profile)
    k "rm -f $KO/patches/2-kindleui-smoke.lua /tmp/kindleui-sandbox"
    ko_restart
    k "rm -rf $WORK"
    echo "$LOG" | grep "KINDLEUI SMOKE" | sed -E 's/^[0-9/]+-[0-9:]+ [A-Z]+ +//'
    ERRORS=$(echo "$LOG" | grep -E "attempt to|stack traceback|kindleui[^ ]*\.lua:[0-9]+:" | grep -v "KINDLEUI SMOKE" || true)
    if [ $ok = 0 ] || ! echo "$LOG" | grep -q "KINDLEUI SMOKE DONE failures=0"; then
        echo "SMOKE (device): FAILED (a step failed or the run did not finish)"; return 1
    fi
    [ -z "$ERRORS" ] || { echo "SMOKE (device): FAILED (Lua errors in the log):"; echo "$ERRORS"; return 1; }
    echo "SMOKE (device): OK"
}

devctl_url() { # devctl_url <books|plugin>: open that screen, print its session URL
    off=$(log_size)
    ctl "$1"
    wait_log "$off" "KINDLEUI DEVCTL url $1" 20 || return 0
    log_since "$off" | sed -n "s/.*KINDLEUI DEVCTL url $1 //p" | tail -n 1 | tr -d '\r '
}

cmd_send() {
    need_host
    need_devctl
    tmp=$(mktemp -d)
    status=0
    start=$(log_size)
    DEFAULT_BOOKS=
    [ $# -gt 0 ] || { tests/fetch_books.sh > /dev/null; set -- tests/books/juliet.epub tests/books/sample.pdf; DEFAULT_BOOKS=1; }
    [ -z "$SKIP_BOOKS" ] || set --
    # 1) books over the real Wi-Fi, from this computer
    if [ $# -gt 0 ]; then
        url=$(devctl_url books)
        echo "Send Book: ${url:-no URL}"
        [ -n "$url" ] || status=1
    fi
    if [ $# -gt 0 ] && [ -n "$url" ]; then
        code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 "$url"); echo "  page: $code"; [ "$code" = 200 ] || status=1
        i=1
        for f in "$@"; do
            name=$(basename "$f" | sed 's/ /%20/g')
            code=$(curl -s -o /dev/null -w '%{http_code}' -m 120 -X POST -H 'Content-Type: application/octet-stream' \
                --data-binary @"$f" "$url/upload?name=$name&index=$i&count=$#")
            echo "  upload $(basename "$f"): $code"; [ "$code" = 200 ] || status=1
            i=$((i + 1))
        done
        code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 -X POST "$url/finish"); echo "  finish: $code"
        sleep 3
        ctl close; sleep 3
    fi
    # 2) a plugin zip through the Send Plugin button: PLUGIN_ZIP=<zip> sends a
    # real one; INSTALL=1 (with PLUGIN_NAME=<name of its .koplugin>) taps
    # Install and checks that it loads after a restart.
    mkdir -p "$tmp/z/devsend-greeter.koplugin"
    printf 'local _ = require("gettext")\nreturn { name = "devsendgreeter", fullname = _("Devsend greeter"), description = _("Test plugin from tools/kindle.sh send.") }\n' \
        > "$tmp/z/devsend-greeter.koplugin/_meta.lua"
    printf 'local WidgetContainer = require("ui/widget/container/widgetcontainer")\nreturn WidgetContainer:extend{ name = "devsendgreeter" }\n' \
        > "$tmp/z/devsend-greeter.koplugin/main.lua"
    (cd "$tmp/z" && python -c "import zipfile,os
z=zipfile.ZipFile('greeter.zip','w')
for r,d,fs in os.walk('devsend-greeter.koplugin'):
    [z.write(os.path.join(r,f)) for f in fs]
z.close()")
    zip=${PLUGIN_ZIP:-$tmp/z/greeter.zip}
    zname=$(basename "$zip")
    url=$(devctl_url plugin)
    echo "Send Plugin: ${url:-no URL}"
    [ -n "$url" ] || status=1
    if [ -n "$url" ]; then
        page=$(curl -s -m 10 "$url")
        echo "$page" | grep -q "SEND PLUGIN" && echo "  page: plugin page" || { echo "  page: wrong page"; status=1; }
        if echo "$page" | grep -q 'accept='; then echo "  page still has an accept= filter"; status=1; fi
        t0=$(date +%s)
        code=$(curl -s -o "$tmp/resp" -w '%{http_code}' -m 600 -X POST --data-binary @"$zip" "$url/upload?name=$zname")
        echo "  upload $zname ($(wc -c < "$zip") bytes, $(( $(date +%s) - t0 )) s): $code $(cat "$tmp/resp")"
        [ "$code" = 200 ] || status=1
        curl -s -o /dev/null -m 10 -X POST "$url/finish"
        sleep 6
        off=$(log_size); ctl top; sleep 4
        log_since "$off" | sed -n 's/.*KINDLEUI DEVCTL //p' | tail -n 1
        if [ -n "$INSTALL" ] && [ $status = 0 ]; then
            off=$(log_size); ctl confirm; sleep 15
            log_since "$off" | grep -E "KINDLEUI DEVCTL confirming|KindleUI installer" | sed -E 's/^[0-9/]+-[0-9:]+ [A-Z]+ +//'
            ctl close; sleep 3
            k "ls -d $KO/plugins/$PLUGIN_NAME.koplugin" || status=1
            ko_restart
            off=$(log_size); ctl "loaded $PLUGIN_NAME"; sleep 4
            log_since "$off" | sed -n 's/.*KINDLEUI DEVCTL \(loaded .*\)/\1/p'
            log_since "$off" | grep -q "KINDLEUI DEVCTL loaded $PLUGIN_NAME true" || { echo "  $PLUGIN_NAME not loaded"; status=1; }
        else
            ctl close; sleep 3 # the confirm dialog: close it without installing
        fi
    fi
    log_since "$start" | grep -E "KindleUI (session|network|server|upload|installer)" | sed -E 's/^[0-9/]+-[0-9:]+ //'
    if [ -n "$DEFAULT_BOOKS" ]; then
        # the default test books are ours: take them out of the library again
        log_since "$start" | sed -n 's/.*KindleUI upload: validated and stored [0-9]* bytes as \(\/mnt\/us\/documents\/.*\) *$/\1/p' |
            sed 's/ *$//' | while IFS= read -r f; do
                k "rm -rf \"$f\" \"${f%.*}.sdr\"" < /dev/null && echo "  removed test book $f"
            done
    fi
    ERRORS=$(log_since "$start" | grep -E "attempt to|stack traceback|kindleui[^ ]*\.lua:[0-9]+:|DEVCTL error" || true)
    [ -z "$ERRORS" ] || { echo "$ERRORS"; status=1; }
    rm -rf "$tmp"
    [ $status = 0 ] && echo "SEND (device): OK" || echo "SEND (device): FAILED"
    return $status
}

case "$1" in
setup-key)
    [ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N "" -C kindleui-dev -f "$KEY"
    echo "Copy $KEY.pub to the Kindle as koreader/settings/SSH/authorized_keys (USB),"
    echo "then in KOReader: Tools → More tools → SSH server → Start."
    ;;
setup) cmd_setup ;;
teardown) cmd_teardown ;;
ssh) shift; k "$@" ;;
deploy) cmd_deploy ;;
restart) ko_restart; echo "KOReader restarted" ;;
log) k "tail -n ${2:-80} $KO/crash.log" ;;
unit) cmd_unit ;;
smoke) shift; cmd_smoke "$@" ;;
send) shift; cmd_send "$@" ;;
all) cmd_deploy; ko_restart; st=0; cmd_unit || st=1; cmd_smoke || st=1; cmd_send || st=1; exit $st ;;
*) sed -n '2,20p' "$0"; exit 1 ;;
esac
