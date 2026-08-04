#!/bin/bash
# Enters the simulated Mac: a user namespace (so we get CAP_SYS_ADMIN without
# being root), a private mount namespace, a PID namespace (so `ps` only sees
# this session) and a UTS namespace (so the hostname is really the Mac's).
set -u

R="${MACOS_ROOT:-$HOME/.macos}"
HOST_NAME="Learners-MacBook-Pro.local"
CMDLOG="${MACOS_CMDLOG:-/tmp/.command_log.txt}"

if [ "${MACOS_STAGE:-}" != "inner" ]; then
  [ -d "$R" ] || { echo "macOS root not built at $R" >&2; exit 1; }
  SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  export MACOS_STAGE=inner MACOS_ROOT="$R" MACOS_CMDLOG="$CMDLOG"
  # --map-root-user, not --map-user=501: any non-root mapping makes unshare
  # setuid away from root, which drops the capabilities we need to mount and
  # chroot. Inside the namespace we are uid 0; /etc/passwd is what makes that
  # read as Learner (uid 501 is faked by the `id` shim).
  exec unshare --user --map-root-user \
               --mount --pid --fork --uts --propagation private \
               "$SELF" "$@"
fi

# ------------------------------------------------------------------- hostname
hostname "$HOST_NAME" 2>/dev/null

# ---------------------------------------------------------------- host plumbing
b()  { [ -e "$2" ] && mount --bind "$1" "$2" 2>/dev/null; }
rb() { [ -e "$2" ] && mount --rbind "$1" "$2" 2>/dev/null; }

b  /usr/lib          "$R/usr/lib"
b  /usr/lib64        "$R/lib64"
b  /usr/share        "$R/usr/share"
b  /etc/ld.so.cache  "$R/private/etc/ld.so.cache"
b  /usr/bin          "$R/usr/libexec/.sys/bin"
b  /usr/sbin         "$R/usr/libexec/.sys/sbin"
b  /opt/python       "$R/opt/python"
rb /dev              "$R/dev"
# A fresh procfs cannot be mounted inside a container's user namespace (the
# host /proc has masked submounts), so bind the existing one. It leaks the
# host process list, which is why ps/top are shimmed.
rb /proc             "$R/proc"

# Apple's zsh has no new-user setup script; this one's does, and it fires
# because a fresh Mac home has no ~/.zshrc. Blank it out.
: > "$R/private/var/db/.empty"
for nu in /usr/share/zsh/*/scripts/newuser; do
  [ -f "$nu" ] && b "$R/private/var/db/.empty" "$R${nu}"
done

# command tracking: the log file itself lives outside the chroot
[ -f "$CMDLOG" ] || : > "$CMDLOG"
b "$CMDLOG" "$R/private/var/db/.cmdlog"

# --------------------------------------------------------------- command binds
# Zero-length files in the command directories are placeholders written by
# build.sh; bind the real host binary over each one. Non-empty files are shims
# and are left alone.
farm() { # farm <dst-dir> <host-dir>...
  local dst="$1"; shift
  local f n src
  for f in "$dst"/*; do
    [ -f "$f" ] || continue
    [ -s "$f" ] && continue
    n="${f##*/}"
    for src in "$@"; do
      if [ -x "$src/$n" ] && [ ! -d "$src/$n" ]; then
        mount --bind "$src/$n" "$f" 2>/dev/null
        break
      fi
    done
  done
}
farm "$R/usr/bin"  /usr/bin
farm "$R/bin"      /usr/bin
farm "$R/usr/sbin" /usr/sbin /usr/bin
farm "$R/sbin"     /usr/sbin /usr/bin
mount --bind /usr/bin/bash "$R/bin/sh" 2>/dev/null

# --------------------------------------------------------------- self-test
# MACOS_SELFTEST=selftest.sh runs that script inside the simulated Mac instead
# of starting a login shell. The copy only exists during a test run, so the
# learner's filesystem never carries it.
if [ -n "${MACOS_SELFTEST:-}" ]; then
  if [ ! -f "$MACOS_SELFTEST" ]; then
    echo "MACOS_SELFTEST: no such file: $MACOS_SELFTEST" >&2; exit 1
  fi
  install -m 755 "$MACOS_SELFTEST" "$R/private/var/db/.selftest" || exit 1
  set -- /bin/bash /private/var/db/.selftest
fi

# ------------------------------------------------------------------ login
ENVV=(
  HOME=/Users/Learner
  USER=Learner
  LOGNAME=Learner
  SHELL=/bin/zsh
  TERM="${TERM:-xterm-256color}"
  TERM_PROGRAM=Apple_Terminal
  TERM_PROGRAM_VERSION=455
  TERM_SESSION_ID=w0t0p0
  LANG=en_US.UTF-8
  TZ=Europe/Berlin
  __CF_USER_TEXT_ENCODING=0x1F5:0x0:0x0
  XPC_SERVICE_NAME=0
  XPC_FLAGS=0x0
  COMMAND_MODE=unix2003
)

# Arguments (from the self-test above, or from a grader that wants to inspect
# the built root) run in place of the interactive login.
if [ $# -gt 0 ]; then
  exec chroot "$R" /usr/bin/env -i "${ENVV[@]}" "$@"
fi

# seed.sh records a starting directory here when a task wants the learner to
# begin somewhere other than the home. Anything unusable falls back to the home
# rather than dropping the learner at / - seed.sh is where a bad path is
# reported, at setup time, where someone can act on it.
START=/Users/Learner
if [ -f "$R/private/var/db/.startdir" ]; then
  S="$(head -1 "$R/private/var/db/.startdir" | tr -d '\r')"
  case "$S" in
    ''|*\'*) ;;
    *) [ -d "$R$S" ] && START="$S" ;;
  esac
fi

LOGIN_TS="$(LC_ALL=C date '+%a %b %e %T')"
printf 'Last login: %s on ttys000\n' "$LOGIN_TS"

exec chroot "$R" /usr/bin/env -i "${ENVV[@]}" \
  /bin/sh -c "cd '$START' && exec /bin/zsh -l"
