#!/bin/sh
# Drives a real KOReader Linux build (SDL, X11) inside Docker with this plugin
# installed, for manual/automated UI checks and timing.
#
# Image: wardwouts/koreader-novnc (Debian + KOReader .deb + Xvfb + noVNC),
# pulled through mirror.gcr.io to avoid Docker Hub rate limits.
#
# Host needs: docker, xwd + convert (imagemagick), xdotool.
#
#   tools/emulator.sh start [books_dir]   start KOReader (Paperwhite 12 geometry)
#       env: KO_PATCHES=dir  mount KOReader user patches (e.g. tests/bench)
#            KO_CPUS=0.1     CPU quota (crude slow-device proxy)
#   tools/emulator.sh shot out.png        screenshot
#   tools/emulator.sh tap X Y             tap at screen coordinates
#   tools/emulator.sh swipe X1 Y1 X2 Y2   drag
#   tools/emulator.sh key KEY             X key name (e.g. Escape)
#   tools/emulator.sh log                 KOReader log (crash.log equivalent)
#   tools/emulator.sh restart             restart KOReader only
#   tools/emulator.sh stop
#   tools/emulator.sh vnc                 print noVNC URL (browser access)
set -e
IMAGE=${KO_IMAGE:-mirror.gcr.io/wardwouts/koreader-novnc:v2026.07.1}
NAME=${KO_NAME:-kindleui-emu}
W=${KO_W:-1264}   # Kindle Paperwhite 12 (2024): 1264x1680, 300 ppi
H=${KO_H:-1680}
DPI=${KO_DPI:-300}
ROOT=$(cd "$(dirname "$0")/.." && pwd)

ip() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$NAME"; }
disp() { echo "$(ip):0"; }

case "$1" in
start)
    [ -n "$2" ] || "$ROOT/tests/fetch_books.sh" > /dev/null
    BOOKS=$(cd "${2:-$ROOT/tests/books}" && pwd)
    docker rm -f "$NAME" > /dev/null 2>&1 || true
    docker run -d --name "$NAME" \
        -e EMULATE_READER_W="$W" -e EMULATE_READER_H="$H" -e EMULATE_READER_DPI="$DPI" \
        -v "$ROOT/kindleui.koplugin:/home/user/.config/koreader/plugins/kindleui.koplugin:ro" \
        -v "$BOOKS:/books" \
        ${KO_PATCHES:+-v "$KO_PATCHES:/home/user/.config/koreader/patches:ro"} \
        ${KO_CPUS:+--cpus "$KO_CPUS"} \
        "$IMAGE" > /dev/null
    # wait for the window (start_koreader sleeps 10s before launching)
    for _ in $(seq 60); do
        if DISPLAY=$(disp) xdotool search --name "KOReader" > /dev/null 2>&1; then break; fi
        sleep 1
    done
    sleep 3
    echo "started: DISPLAY=$(disp)"
    ;;
shot)
    DISPLAY=$(disp) xwd -root -silent | convert xwd:- -crop "${W}x${H}+0+0" +repage "${2:-shot.png}"
    ;;
tap)
    DISPLAY=$(disp) xdotool mousemove "$2" "$3" click 1
    ;;
swipe)
    DISPLAY=$(disp) xdotool mousemove "$2" "$3" mousedown 1 mousemove --sync "$(( ($2+$4)/2 ))" "$(( ($3+$5)/2 ))" mousemove "$4" "$5" mouseup 1
    ;;
key)
    DISPLAY=$(disp) xdotool key "$2"
    ;;
log)
    docker exec "$NAME" cat /home/user/koreader.log
    ;;
restart)
    # supervisord (autorestart=true) relaunches KOReader after ~10 s
    # (skip our own shell: its command line contains "reader.lua" too)
    docker exec "$NAME" sh -c 'for p in /proc/[0-9]*; do pid=${p#/proc/}; [ "$pid" = "$$" ] && continue
        grep -q "luajit ./reader.lua\|reader.lua" "$p/cmdline" 2>/dev/null && kill "$pid"; done' || true
    sleep 2
    for _ in $(seq 40); do
        sleep 1
        if DISPLAY=$(disp) xdotool search --name "KOReader" > /dev/null 2>&1; then break; fi
    done
    sleep 3
    ;;
exec)
    shift
    docker exec "$NAME" "$@"
    ;;
stop)
    docker rm -f "$NAME" > /dev/null
    ;;
vnc)
    echo "http://$(ip):8080/vnc.html"
    ;;
*)
    sed -n '2,20p' "$0"
    exit 1
    ;;
esac
