#!/bin/sh
# Runs the plugin's automated checks under LuaJIT (needs: luajit, lua-socket, curl;
# luacheck optional). They cover the transfer layer and the security helpers;
# UI modules need a KOReader runtime and are covered by docs/TESTING.md.
set -e
cd "$(dirname "$0")/.."
export LUA_PATH="./kindleui.koplugin/?.lua;./tests/?.lua;;"
status=0

echo "### syntax"
for f in $(find kindleui.koplugin -name '*.lua'); do
    luajit -bl "$f" > /dev/null || { echo "syntax error: $f"; status=1; }
done

# A loop variable named `_` shadows gettext's _() for the whole loop body,
# turning every translated string inside it into a runtime error.
echo "### gettext shadowing"
for f in $(grep -rl 'local _ = require("gettext")' kindleui.koplugin); do
    if grep -nE 'for _[ ,=]|local _,' "$f"; then
        echo "  FAIL $f shadows gettext's _"
        status=1
    fi
done

if command -v luacheck > /dev/null; then
    echo "### luacheck"
    luacheck --no-color --std luajit --globals G_reader_settings G_defaults \
        --no-unused-args --no-max-line-length kindleui.koplugin || status=1
fi

for t in tests/test_*.lua; do
    echo "### $t"
    luajit "$t" || status=1
done
exit $status
