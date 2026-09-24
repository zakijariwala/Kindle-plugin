#!/bin/sh
# Builds a synthetic library for timing runs:
#   tests/make_library.sh <dir> [books=150] [with_progress=50]
# Books are copies of KOReader's test-data samples (tests/books) under distinct
# names; the first <with_progress> get a KOReader sidecar (.sdr/metadata.*.lua)
# with title, author and reading progress, as if they had been read.
set -e
DIR=$1; N=${2:-150}; P=${3:-50}
"$(dirname "$0")/fetch_books.sh" > /dev/null
SRC=$(cd "$(dirname "$0")/books" && pwd)
[ -n "$DIR" ] || { echo "usage: $0 <dir> [books] [with_progress]"; exit 1; }
rm -rf "$DIR"; mkdir -p "$DIR"
set -- juliet.epub leaves.epub sample.pdf 2col.pdf
i=1
while [ $i -le "$N" ]; do
    for f in juliet.epub leaves.epub juliet.epub leaves.epub sample.pdf; do
        [ $i -le "$N" ] || break
        ext=${f##*.}
        sub=$(( i % 4 ))   # spread over a few folders
        mkdir -p "$DIR/shelf$sub"
        name="Book $(printf %03d $i)"
        cp "$SRC/$f" "$DIR/shelf$sub/$name.$ext"
        if [ $i -le "$P" ]; then
            mkdir -p "$DIR/shelf$sub/$name.sdr"
            cat > "$DIR/shelf$sub/$name.sdr/metadata.$ext.lua" <<LUA
-- we can read Lua syntax here!
return {
    ["percent_finished"] = 0.$(( (i * 37) % 90 + 10 )),
    ["doc_pages"] = 300,
    ["doc_props"] = {
        ["title"] = "Test Book $i",
        ["authors"] = "Author $(( i % 17 ))",
        ["language"] = "en",
    },
    ["summary"] = {
        ["status"] = "reading",
    },
}
LUA
        fi
        i=$((i + 1))
    done
done
echo "created $N books ($P with reading progress) in $DIR"
