#!/bin/bash
# Rebuilds macos/vendor/ from upstream Ubuntu packages.
#
# Run this when build.sh reports the vendored binaries as missing or corrupt, or
# to change what is vendored. It needs network; the task itself never does.
# Afterwards the tree is byte-identical to what checksums.txt records, so
# build.sh will pass again. This repo (learn_macos) is fetched fresh into
# .codesignal/macos/ by the task's setup_steps.sh, so after running this, commit
# and push vendor/ here.
#
#   bash macos/revendor.sh
#
# The pinned versions match the host image (Ubuntu 22.04, x86-64). zsh's modules
# and function digests are ABI-locked to the zsh binary, so all three come from
# the same pair of packages and must be upgraded together.
#
# Runs on Linux or macOS: dpkg-deb is used when present, otherwise `ar` plus the
# matching decompressor.
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
    if curl -sSfL --retry 3 --retry-all-errors --connect-timeout 10 -o "$2" "$m/$1"; then return 0; fi
  done
  echo "could not fetch $1 from any mirror" >&2
  return 1
}

# dpkg-deb is not on macOS, and a .deb is just an ar archive holding
# data.tar.{xz,zst,gz}, so unpack it by hand when it has to be.
extract_deb() { # extract_deb <deb> <dest>
  local deb="$1" dest="$2" member
  mkdir -p "$dest"
  if command -v dpkg-deb >/dev/null 2>&1; then
    dpkg-deb -x "$deb" "$dest"
    return
  fi
  member="$(ar t "$deb" | grep '^data\.tar' | head -1)"
  [ -n "$member" ] || { echo "no data member in $deb" >&2; return 1; }
  case "$member" in
    *.xz)  ar p "$deb" "$member" | tar -xJ -C "$dest" ;;
    *.gz)  ar p "$deb" "$member" | tar -xz -C "$dest" ;;
    *.zst)
      command -v zstd >/dev/null 2>&1 || {
        echo "$deb holds $member and zstd is not installed (brew install zstd)" >&2
        return 1
      }
      ar p "$deb" "$member" | zstd -d | tar -x -C "$dest" ;;
    *) echo "unhandled data member $member in $deb" >&2; return 1 ;;
  esac
}

echo "Fetching packages…"
fetch "pool/main/z/zsh/zsh_${ZSH_V}_amd64.deb"        "$WORK/zsh.deb"
fetch "pool/main/z/zsh/zsh-common_${ZSH_V}_all.deb"   "$WORK/zsh-common.deb"
fetch "pool/main/l/less/less_${LESS_V}_amd64.deb"     "$WORK/less.deb"
fetch "pool/main/n/nano/nano_${NANO_V}_amd64.deb"     "$WORK/nano.deb"

echo "Extracting…"
for p in zsh zsh-common less nano; do
  extract_deb "$WORK/$p.deb" "$WORK/x-$p"
done

ZSH_ABI="${ZSH_V%-*}"   # 5.8.1

# Assemble the tree in a staging dir; it is packed into vendor/vendor.txz below
# and never committed as loose binaries.
STAGE="$WORK/stage"
mkdir -p "$STAGE/zsh/bin" "$STAGE/zsh/modules/zsh" "$STAGE/zsh/functions/Completion" \
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

# ------------------------------------------------------- completion functions
# Without these, compinit finds no _* functions and tab completion falls back to
# filenames - no `git <tab>`, no flag completion. Ubuntu keeps them in
# per-platform subdirectories (Base, Unix, Zsh, X, Darwin, Linux, Debian, …);
# a Mac flattens the lot into one directory. Flatten them the same way and keep
# only the names a real Mac has, per manifest/zsh_functions.txt - which is what
# keeps Ubuntu-only additions out without hand-maintaining a blocklist.
ALLOW="$HERE/manifest/zsh_functions.txt"
[ -f "$ALLOW" ] || { echo "missing $ALLOW" >&2; exit 1; }

CSRC="$WORK/x-zsh-common/usr/share/zsh/functions/Completion"
kept=0; skipped=0
if [ -n "$(find "$CSRC" -type f -name '_*' -print -quit 2>/dev/null)" ]; then
  # names to keep, comments and blanks stripped
  KEEP="$WORK/keep.txt"
  sed -e 's/#.*//' -e 's/[[:space:]]//g' "$ALLOW" | grep -v '^$' | LC_ALL=C sort -u > "$KEEP"
  while IFS= read -r f; do
    b="${f##*/}"
    if LC_ALL=C grep -qxF -- "$b" "$KEEP"; then
      install -m 644 "$f" "$STAGE/zsh/functions/Completion/$b"
      kept=$((kept+1))
    else
      skipped=$((skipped+1))
    fi
  done < <(find "$CSRC" -type f ! -name '*.zwc' | LC_ALL=C sort)
  echo "  completion: kept $kept function files, skipped $skipped not present on a Mac"
else
  # This package shipped digests only. build.sh's fpath generator handles either
  # layout, so fall back to the per-suite digests - dropping the three no Mac
  # has, since here the name is all there is to filter on.
  for z in "$CSRC"/*.zwc; do
    [ -e "$z" ] || continue
    case "$(basename "$z" .zwc)" in
      Debian|Linux|Redhat|Mandriva|openSUSE|Cygwin|AIX|Solaris) continue ;;
    esac
    install -m 644 "$z" "$STAGE/zsh/functions/Completion/"
    kept=$((kept+1))
  done
  echo "  completion: no loose sources in the package; vendored $kept suite digests instead"
fi
[ "$kept" -gt 0 ] || { echo "no completion functions vendored - check $CSRC" >&2; exit 1; }

install -m 755 "$WORK/x-nano/bin/nano" "$STAGE/tools/bin/nano"
install -m 755 "$WORK/x-less/usr/bin/less" "$STAGE/tools/bin/less"
install -m 644 "$WORK/x-nano/usr/share/nano/"*.nanorc "$STAGE/tools/share/nano/"

# ------------------------------------------------------------------ packing
# One xz'd tar. This tree is fetched fresh from GitHub at setup time rather
# than committed into CodeSignal task storage, so there's no need to chunk or
# text-encode it - a plain binary file is fine. --sort/--mtime/--owner make the
# tar reproducible; -9e and xz's CRC64 do the rest.
# The flags that make it reproducible are GNU tar's; macOS bsdtar has no --sort
# or --mtime, and packing with it would produce a different checksum every run.
echo "Packing…"
TAR=tar
command -v gtar >/dev/null 2>&1 && TAR=gtar
"$TAR" --version 2>/dev/null | grep -q 'GNU tar' || {
  echo "packing needs GNU tar (macOS: brew install gnu-tar, then rerun)" >&2
  exit 1
}
rm -rf "$V"; mkdir -p "$V"
"$TAR" --sort=name --owner=0 --group=0 --numeric-owner --mtime='UTC 2020-01-01' \
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
