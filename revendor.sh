#!/bin/bash
# Rebuilds macos/vendor/ from upstream Ubuntu packages.
#
# Run this only when build.sh reports the vendored binaries as missing or
# corrupt. It needs network; the task itself never does. Afterwards the tree is
# byte-identical to what checksums.txt records, so build.sh will pass again.
# This repo (learn_macos) is fetched fresh into .codesignal/macos/ by the
# task's setup_steps.sh, so after running this, commit and push vendor/ here.
#
#   bash macos/revendor.sh
#
# The pinned versions match the host image (Ubuntu 22.04, x86-64). zsh's modules
# and function digests are ABI-locked to the zsh binary, so all three come from
# the same pair of packages and must be upgraded together.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
V="$HERE/vendor"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ZSH_V=5.8.1-1
LESS_V=590-1ubuntu0.22.04.3
NANO_V=6.2-1

# archive.ubuntu.com drops releases after EOL; old-releases keeps them forever.
MIRRORS="http://archive.ubuntu.com/ubuntu http://old-releases.ubuntu.com/ubuntu"

fetch() { # fetch <pool-path> <output>
  local m
  for m in $MIRRORS; do
    if curl -sSfL --retry 2 -o "$2" "$m/$1"; then return 0; fi
  done
  echo "could not fetch $1 from any mirror" >&2
  return 1
}

echo "Fetching packages…"
fetch "pool/main/z/zsh/zsh_${ZSH_V}_amd64.deb"        "$WORK/zsh.deb"
fetch "pool/main/z/zsh/zsh-common_${ZSH_V}_all.deb"   "$WORK/zsh-common.deb"
fetch "pool/main/l/less/less_${LESS_V}_amd64.deb"     "$WORK/less.deb"
fetch "pool/main/n/nano/nano_${NANO_V}_amd64.deb"     "$WORK/nano.deb"

echo "Extracting…"
for p in zsh zsh-common less nano; do
  dpkg-deb -x "$WORK/$p.deb" "$WORK/x-$p"
done

ZSH_ABI="${ZSH_V%-*}"   # 5.8.1

# Assemble the tree in a staging dir; it is packed into vendor/payload/ below and
# never committed as loose binaries.
STAGE="$WORK/stage"
mkdir -p "$STAGE/zsh/bin" "$STAGE/zsh/modules/zsh" "$STAGE/zsh/functions" \
         "$STAGE/tools/bin" "$STAGE/tools/share/nano"

echo "Staging…"
install -m 755 "$WORK/x-zsh/bin/zsh" "$STAGE/zsh/bin/zsh"
install -m 755 "$WORK/x-zsh/usr/lib/x86_64-linux-gnu/zsh/$ZSH_ABI/zsh/"*.so \
               "$STAGE/zsh/modules/zsh/"
# Function digests, minus three suites nothing in this task can reach: Zftp
# (zfget/zfput), Calendar (calendar*) and TCP (tcp_open/tcp_send). They are not
# autoloaded by /etc/zshenv or /etc/zshrc, and compinit does not want them. Keep
# this list in sync with the note in README.md.
for z in "$WORK/x-zsh-common/usr/share/zsh/functions/"*.zwc; do
  # literal alternation: a "$VAR" holding TCP|Calendar|Zftp would be matched as
  # one string, since case parses | before expansion
  case "$(basename "$z" .zwc)" in
    TCP|Calendar|Zftp) continue ;;
  esac
  install -m 644 "$z" "$STAGE/zsh/functions/"
done
install -m 755 "$WORK/x-nano/bin/nano" "$STAGE/tools/bin/nano"
install -m 755 "$WORK/x-less/usr/bin/less" "$STAGE/tools/bin/less"
install -m 644 "$WORK/x-nano/usr/share/nano/"*.nanorc "$STAGE/tools/share/nano/"

# ------------------------------------------------------------------ packing
# One xz'd tar. This tree is fetched fresh from GitHub at setup time rather
# than committed into CodeSignal task storage, so there's no need to chunk or
# text-encode it - a plain binary file is fine. --sort/--mtime/--owner make the
# tar reproducible; -9e and xz's CRC64 do the rest.
echo "Packing…"
rm -rf "$V"; mkdir -p "$V"
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime='UTC 2020-01-01' \
    -C "$STAGE" -cf - . | xz -9e > "$V/vendor.txz"

echo "Recording checksum…"
( cd "$V" && sha256sum vendor.txz > checksums.txt )

# prove the committed file matches exactly what was staged
CHECK="$WORK/check"; mkdir -p "$CHECK"
( cd "$V" && sha256sum -c checksums.txt --quiet )
tar -C "$CHECK" -xJf "$V/vendor.txz"
diff -r "$STAGE" "$CHECK" >/dev/null \
  || { echo "payload does not match what was staged" >&2; exit 1; }

echo "vendor/ restored: $(du -sh "$V/vendor.txz" | cut -f1) tarball"
echo "  staged tree: $(find "$STAGE" -type f | wc -l) files, $(du -sh "$STAGE" | cut -f1)"
