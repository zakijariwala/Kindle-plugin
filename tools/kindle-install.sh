#!/bin/sh
# Installs (or updates) Kindle-style Home straight on the e-reader, without a
# computer. Run it from KOReader's Terminal emulator (Tools → More tools →
# Terminal emulator) or over SSH:
#
#   curl -fsSL https://raw.githubusercontent.com/zakijariwala/Kindle-plugin/main/tools/kindle-install.sh | sh
#
# It downloads the repository as a .tar.gz (busybox tar is on every Kindle;
# unzip is not), replaces koreader/plugins/kindleui.koplugin as a whole, and
# leaves everything else alone. Restart KOReader afterwards.
#   env BRANCH=<branch>   install another branch (default: main)
#   env KOREADER_DIR=dir  KOReader folder (default: found automatically)
set -e
REPO=zakijariwala/Kindle-plugin
BRANCH=${BRANCH:-main}
URL="https://codeload.github.com/$REPO/tar.gz/refs/heads/$BRANCH"

if [ -z "$KOREADER_DIR" ]; then
    for d in /mnt/us/koreader /mnt/onboard/.adds/koreader "$PWD"; do
        if [ -d "$d/plugins" ] && [ -f "$d/reader.lua" ]; then KOREADER_DIR=$d; break; fi
    done
fi
[ -n "$KOREADER_DIR" ] && [ -d "$KOREADER_DIR/plugins" ] || {
    echo "KOReader folder not found. Run: KOREADER_DIR=/path/to/koreader sh kindle-install.sh"; exit 1; }
PLUGINS="$KOREADER_DIR/plugins"
TMP="${TMPDIR:-/tmp}/kindleui-install.$$"
rm -rf "$TMP"; mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading $REPO ($BRANCH)..."
# The Kindle's own CA list can be old; KOReader ships a current one.
CA="$KOREADER_DIR/data/ca-bundle.crt"
if [ -f "$CA" ]; then
    curl -fsSL --cacert "$CA" -o "$TMP/src.tar.gz" "$URL" || curl -fsSL -o "$TMP/src.tar.gz" "$URL"
else
    curl -fsSL -o "$TMP/src.tar.gz" "$URL"
fi
(cd "$TMP" && tar -xzf src.tar.gz)
SRC=$(ls -d "$TMP"/*/kindleui.koplugin 2>/dev/null | head -n 1)
[ -n "$SRC" ] && [ -f "$SRC/main.lua" ] && [ -f "$SRC/_meta.lua" ] || { echo "The download does not contain the plugin."; exit 1; }

# Swap whole folders: files a new version dropped do not linger.
rm -rf "$PLUGINS/.kindleui.koplugin.new"
cp -r "$SRC" "$PLUGINS/.kindleui.koplugin.new"
if [ -d "$PLUGINS/kindleui.koplugin" ]; then
    rm -rf "$PLUGINS/.kindleui.koplugin.old"
    mv "$PLUGINS/kindleui.koplugin" "$PLUGINS/.kindleui.koplugin.old"
fi
mv "$PLUGINS/.kindleui.koplugin.new" "$PLUGINS/kindleui.koplugin"
rm -rf "$PLUGINS/.kindleui.koplugin.old"
echo "Installed in $PLUGINS/kindleui.koplugin"
echo "Now restart KOReader (menu → Exit → Restart KOReader)."
