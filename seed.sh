#!/bin/bash
# Seeds the built root with a task's own files, so a learner can start in a
# populated home instead of an empty one.
#
#   bash build.sh && bash seed.sh /usercode/FILESYSTEM/.codesignal/macos-seed
#
# Order matters: build.sh wipes the root, so seeding has to come after it.
# Nothing here is required - a task with no seed directory just gets the stock
# home, and setup keeps working unchanged.
#
# The seed directory may hold any of these; all are optional:
#
#   home/        copied into /Users/Learner
#   root/        copied into / - for /Applications, /etc, /Volumes, …
#   MANIFEST     directories and empty files to create (git cannot store an
#                empty directory, so this is the only way to ship one)
#   START        one line: the directory the learner's shell starts in
#   setup.zsh    runs last, inside the simulated Mac, as Learner
#
# If none of those names exist, the whole seed directory is treated as home/ -
# the common case of "just give the learner these files".
#
# Ownership takes care of itself: files copied by the user that runs setup map
# to uid 0 inside the namespace, which /etc/passwd names Learner. Files owned by
# anyone else would surface as root/wheel.
set -u

R="${MACOS_ROOT:-$HOME/.macos}"
HOME_DIR="/Users/Learner"
SEED="${1:-${MACOS_SEED:-}}"
ENTER="$(cd "$(dirname "$0")" && pwd)/enter.sh"

# Same channel build.sh uses, so setup.sh can surface the reason on failure.
die() {
  printf 'macOS seed: %s\n' "$@" | tee /tmp/.macos_build_error >&2
  exit 1
}

# A seed comes from task storage, where a typo is easy and a traversal would
# write outside the simulated root entirely.
check_rel() { # check_rel <path> <what>
  case "$1" in
    /*)    die "$2 must be relative to the home directory: $1" ;;
    *..*)  die "$2 may not contain '..': $1" ;;
    "")    die "$2 is empty" ;;
  esac
}

[ -n "$SEED" ] || die "no seed directory given" \
                      "usage: seed.sh <seed-dir>   (or set MACOS_SEED)"
[ -d "$SEED" ] || die "seed directory not found: $SEED"
[ -d "$R" ]    || die "no built root at $R - run build.sh first"
[ -d "$R$HOME_DIR" ] || die "$R$HOME_DIR is missing - is $R a built root?"

did=0

# ------------------------------------------------------------------ home/, root/
# cp -a keeps modes and mtimes; a task that wants specific timestamps can set
# them in setup.zsh with touch -t.
nfiles() { find "$1" -type f 2>/dev/null | wc -l | tr -d ' '; }

if [ -d "$SEED/home" ]; then
  cp -a "$SEED/home/." "$R$HOME_DIR/" || die "could not copy home/"
  echo "  copied $(nfiles "$SEED/home") files into $HOME_DIR"
  did=1
fi
if [ -d "$SEED/root" ]; then
  cp -a "$SEED/root/." "$R/" || die "could not copy root/"
  echo "  copied $(nfiles "$SEED/root") files into /"
  did=1
fi

# Nothing structured in there - treat it all as home content.
if [ $did -eq 0 ] && [ ! -f "$SEED/MANIFEST" ] && [ ! -f "$SEED/START" ] \
   && [ ! -f "$SEED/setup.zsh" ]; then
  [ -n "$(ls -A "$SEED" 2>/dev/null)" ] || die "seed directory $SEED is empty"
  cp -a "$SEED/." "$R$HOME_DIR/" || die "could not copy seed contents"
  echo "  copied $(nfiles "$SEED") files into $HOME_DIR"
  did=1
fi

# ---------------------------------------------------------------- MANIFEST
# Lines are:  dir <path> [mode]   |   file <path> [mode]
# Paths are relative to /Users/Learner. Blank lines and # comments are skipped.
if [ -f "$SEED/MANIFEST" ]; then
  n=0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    # shellcheck disable=SC2086
    set -- $line
    [ $# -eq 0 ] && continue
    verb="$1"; path="${2:-}"; mode="${3:-}"
    check_rel "$path" "MANIFEST path"
    case "$verb" in
      dir|d)
        mkdir -p "$R$HOME_DIR/$path" || die "MANIFEST: could not create $path" ;;
      file|f)
        mkdir -p "$(dirname "$R$HOME_DIR/$path")" || die "MANIFEST: $path"
        : > "$R$HOME_DIR/$path" || die "MANIFEST: could not create $path" ;;
      *)
        die "MANIFEST: unknown verb '$verb' (expected dir or file)" ;;
    esac
    [ -n "$mode" ] && chmod "$mode" "$R$HOME_DIR/$path"
    n=$((n+1))
  done < "$SEED/MANIFEST"
  echo "  seeded $n entries from MANIFEST"
  did=1
fi

# ------------------------------------------------------------------- START
# enter.sh reads this and starts the login shell there instead of the home.
if [ -f "$SEED/START" ]; then
  S="$(head -1 "$SEED/START" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [ -n "$S" ] || die "START is empty"
  case "$S" in
    /*) ;;                      # absolute path inside the simulated Mac
    *)  check_rel "$S" "START"; S="$HOME_DIR/$S" ;;
  esac
  case "$S" in *\'*) die "START may not contain a single quote: $S" ;; esac
  [ -d "$R$S" ] || die "START names a directory that does not exist: $S" \
                       "Create it in home/, root/ or MANIFEST first."
  case "$S" in
    *" "*) echo "  warning: START contains a space; run_solution.sh's prompt" >&2
           echo "           pattern matches a space-free directory name" >&2 ;;
  esac
  printf '%s\n' "$S" > "$R/private/var/db/.startdir" || die "could not record START"
  echo "  shell will start in $S"
  did=1
fi

# --------------------------------------------------------------- setup.zsh
# Runs inside the simulated Mac, so it can use the Mac's own commands - mkdir,
# defaults, brew install, xattr - instead of reaching into $R from outside.
# The copy is removed afterwards, so the learner never finds it.
if [ -f "$SEED/setup.zsh" ]; then
  install -m 755 "$SEED/setup.zsh" "$R/private/var/db/.seed" \
    || die "could not stage setup.zsh"
  if ! bash "$ENTER" /bin/sh -c \
        "cd '$HOME_DIR' && exec /bin/zsh -l /private/var/db/.seed"; then
    rm -f "$R/private/var/db/.seed"
    die "setup.zsh failed inside the simulated Mac"
  fi
  rm -f "$R/private/var/db/.seed"
  echo "  ran setup.zsh inside the simulated Mac"
  did=1
fi

[ $did -eq 1 ] || die "seed directory $SEED has nothing to seed"
exit 0
