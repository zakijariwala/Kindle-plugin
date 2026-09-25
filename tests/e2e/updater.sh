#!/bin/sh
# End-to-end test of Settings → About → Check for updates inside the KOReader
# emulator, against a local fake GitHub over HTTPS (test CA, "updates.test").
#
#   tests/e2e/updater.sh          sets everything up, runs the TLS checks,
#                                 and starts KOReader with an "old" install
#
# Then, in the emulator (tools/emulator.sh vnc, or taps):
#   Home → Settings → About → Check for updates → "Installed 0000000 /
#   Available e2e1234" → Update → "Restart now" → About shows 0.1.0-e2e.
#   Checking again says "You have the latest version". Kill the server
#   (kill $(cat $W/srv-8443.pid)) and check again: "Could not check for updates".
set -e
cd "$(dirname "$0")/../.."
R=$(pwd)
W=${KO_UPD_WORK:-/tmp/kindleui-updater-e2e}
SHA=e2e1234567890abcdef1234567890abcdef12345
for p in "$W"/srv-*.pid; do [ -f "$p" ] && kill "$(cat "$p")" 2>/dev/null || true; done
rm -rf "$W"; mkdir -p "$W/certs" "$W/plugins" "$W/patches" "$W/new/kindle-plugin-$SHA" "$W/books"

cd "$W/certs"
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -days 2 -subj "/CN=KindleUI Test CA" 2> /dev/null
mk() {
    openssl req -newkey rsa:2048 -nodes -keyout "$1.key" -out "$1.csr" -subj "/CN=$2" 2> /dev/null
    printf "subjectAltName=DNS:%s\nbasicConstraints=CA:FALSE\n" "$2" > "$1.ext"
    openssl x509 -req -in "$1.csr" -CA ca.pem -CAkey ca.key -CAcreateserial -out "$1.pem" -days 2 -extfile "$1.ext" 2> /dev/null
}
mk good updates.test
mk wronghost other.test
openssl req -x509 -newkey rsa:2048 -nodes -keyout selfsigned.key -out selfsigned.pem -days 2 \
    -subj "/CN=updates.test" -addext "subjectAltName=DNS:updates.test" 2> /dev/null
cp "$R/tests/e2e/tls_checks.lua" .
cd "$R"

# "old" installed plugin, and a "new" build as a GitHub-style archive
cp -r kindleui.koplugin "$W/plugins/"
echo 0000000000000000000000000000000000000000 > "$W/plugins/kindleui.koplugin/BUILD"
cp -r kindleui.koplugin README.md "$W/new/kindle-plugin-$SHA/"
sed -i 's/VERSION = "\([^"]*\)"/VERSION = "\1-e2e"/' "$W/new/kindle-plugin-$SHA/kindleui.koplugin/kindleui/config.lua"
(cd "$W/new" && zip -qr "$W/update.zip" "kindle-plugin-$SHA")
cat > "$W/patches/2-updater-urls.lua" <<'LUA'
local t = G_reader_settings:readSetting("kindleui") or {}
t.update_api_url = "https://updates.test:8443/repos/zakijariwala/kindle-plugin/commits/main"
t.update_zip_url = "https://updates.test:8443/zip/%s"
t.update_cafile = "/certs/ca.pem"
G_reader_settings:saveSetting("kindleui", t)
LUA
chmod -R a+rwX "$W"

for x in "8443 good" "8444 wronghost" "8445 selfsigned"; do
    set -- $x
    nohup python3 tests/e2e/fake_github.py "$1" "$W/certs/$2.pem" "$W/certs/$2.key" "$SHA" "$W/update.zip" \
        > "$W/srv-$1.log" 2>&1 &
    echo $! > "$W/srv-$1.pid"
done
sleep 1

GW=$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}')
KO_PLUGINS_DIR="$W/plugins" KO_ADD_HOST="updates.test:$GW" KO_EXTRA_MOUNT="$W/certs:/certs" \
    KO_PATCHES="$W/patches" tools/emulator.sh start "$W/books"
echo "== TLS checks (KOReader's LuaJIT + LuaSec)"
docker exec -e SHA="$SHA" kindleui-emu sh -c 'cd /usr/lib/koreader && ./luajit /certs/tls_checks.lua 2>&1' \
    | grep -E "OK|REFUSED"
echo "Now drive: Home → Settings → About → Check for updates (see header)."
