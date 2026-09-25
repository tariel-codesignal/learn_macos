#!/bin/bash
# Rebuilds vendor/casefold.so from casefold.c and updates vendor/checksums.txt.
#
# The library must link against the host image's glibc (Ubuntu 22.04, x86-64),
# so it is compiled in that image rather than on whatever machine runs this.
# Needs Docker. Commit and push vendor/ afterwards.
#
#   bash casefold/build.sh
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"

docker run --rm --platform linux/amd64 -v "$HERE:/src:ro" -v "$ROOT/vendor:/out" ubuntu:22.04 bash -c '
  set -e
  apt-get update -qq >/dev/null
  apt-get install -y -qq gcc libc6-dev >/dev/null 2>&1
  gcc -O2 -Wall -Wextra -Werror -shared -fPIC -o /out/casefold.so /src/casefold.c -ldl
  strip --strip-unneeded /out/casefold.so
'

cd "$ROOT/vendor"
grep -v '  casefold\.so$' checksums.txt > checksums.txt.new || true
sha256sum casefold.so 2>/dev/null >> checksums.txt.new || shasum -a 256 casefold.so >> checksums.txt.new
mv checksums.txt.new checksums.txt
echo "built vendor/casefold.so"
