#!/bin/sh
# Fetches the sample books used by the emulator runs and the benchmark
# (from KOReader's own test-data repository) into tests/books/.
set -e
cd "$(dirname "$0")"
[ -f books/juliet.epub ] && exit 0
tmp=$(mktemp -d)
git clone -q --depth 1 https://github.com/koreader/test-data.git "$tmp/test-data"
mkdir -p books
cp "$tmp/test-data/juliet.epub" "$tmp/test-data/leaves.epub" "$tmp/test-data/sample.pdf" "$tmp/test-data/2col.pdf" books/
rm -rf "$tmp"
echo "sample books in tests/books"
