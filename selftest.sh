#!/bin/bash
# Asserts that the simulated Mac still behaves like one. Run it after changing
# anything here, and after the host image changes - most of what this tree does
# depends on host binaries existing at expected paths, and both build.sh's stubs
# and enter.sh's mounts fail silently by design.
#
#   bash build.sh && MACOS_SELFTEST=selftest.sh bash enter.sh
#
# Runs inside the chroot. Exits non-zero if any check fails.
# enter.sh hands the interactive shell no PATH - /etc/zshenv sets it. This runs
# under bash instead, so set the same one rather than inheriting bash's default,
# which may not even contain /sbin.
PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/System/Cryptexes/App/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

PASS=0; FAIL=0; SKIP=0
red()  { printf '\033[31m%s\033[0m' "$1"; }
green(){ printf '\033[32m%s\033[0m' "$1"; }

pass() { PASS=$((PASS+1)); printf '  %s %s\n' "$(green ok)" "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  %s %s\n' "$(red FAIL)" "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
skip() { SKIP=$((SKIP+1)); printf '  -- %s (%s)\n' "$1" "$2"; }
group(){ printf '\n%s\n' "$1"; }

# is <desc> <expected> <cmd...>   - stdout must equal expected exactly
is() {
  local d="$1" want="$2"; shift 2
  local got; got="$("$@" 2>/dev/null)"
  [ "$got" = "$want" ] && pass "$d" || fail "$d" "want [$want] got [$got]"
}
# succeeds / fails <desc> <cmd...>
succeeds() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d" "exit $?"; fi; }
fails()    { local d="$1"; shift; if "$@" >/dev/null 2>&1; then fail "$d" "expected non-zero exit"; else pass "$d"; fi; }
# errs <desc> <substring> <cmd...>  - must fail, and stderr must contain substring
errs() {
  local d="$1" want="$2"; shift 2
  local err rc
  err="$("$@" 2>&1 >/dev/null)"; rc=$?
  if [ $rc -eq 0 ]; then fail "$d" "expected non-zero exit"
  elif [ "${err#*"$want"}" = "$err" ]; then fail "$d" "stderr lacks [$want]: $err"
  else pass "$d"; fi
}
# lacks <desc> <substring> <cmd...> - stdout must not contain substring
lacks() {
  local d="$1" bad="$2"; shift 2
  local got; got="$("$@" 2>/dev/null)"
  if [ "${got#*"$bad"}" = "$got" ]; then pass "$d"; else fail "$d" "output contains [$bad]"; fi
}
# zsh sources /etc/zshenv for every shell but /etc/zshrc only for interactive
# ones, so checks split by which file sets the thing being checked.
zsh_env_is() { # <desc> <expected> <zsh code>   - needs zshenv only
  is "$1" "$2" /bin/zsh -lc "$3"
}

# An interactive zsh insists on owning a terminal. Started from this script it is
# not the foreground process group, so it takes SIGTTIN and stops the whole run.
# `script` hands each check its own pty; the pty turns \n into \r\n, hence the tr.
have_pty=0
command -v script >/dev/null 2>&1 && have_pty=1
zi() { # <zsh code> - run in an interactive login zsh, echo its stdout
  script -q -c "/bin/zsh -lic $(printf '%q' "$1")" /dev/null 2>/dev/null | tr -d '\r'
}
zsh_rc_is() { # <desc> <expected> <zsh code>   - needs zshrc
  if [ $have_pty -eq 0 ]; then skip "$1" "no script(1) for a pty"; return; fi
  local got; got="$(zi "$3")"
  [ "$got" = "$2" ] && pass "$1" || fail "$1" "want [$2] got [$got]"
}

T=/Users/Learner/.selftest.tmp
trap 'rm -rf "$T"' EXIT
mkdir -p "$T"

group "identity"
is "sw_vers reports 15.5"          "15.5"    sw_vers -productVersion
is "uname -s is Darwin"            "Darwin"  uname -s
is "uname -m is arm64"             "arm64"   uname -m
is "id -u is 501"                  "501"     id -u
is "id -gn is staff"               "staff"   id -gn
is "whoami is Learner"             "Learner" whoami
is "hostname is the Mac's"         "Learners-MacBook-Pro.local" hostname

group "filesystem shape"
succeeds "/Volumes/Macintosh HD exists"   test -d "/Volumes/Macintosh HD"
succeeds "/etc is a symlink"              test -L /etc
succeeds "SystemVersion.plist exists"     test -f /System/Library/CoreServices/SystemVersion.plist
succeeds "Safari.app has an Info.plist"   test -f "/Applications/Safari.app/Contents/Info.plist"
is "sed resolves to /usr/bin/sed"  "/usr/bin/sed" command -v sed
for linux in apt dpkg systemctl snap; do
  fails "no $linux on PATH" command -v "$linux"
done
lacks "ls / hides lib"    " lib "    bash -c 'echo " $(ls -a /) "'
lacks "ls / hides lib64"  " lib64 "  bash -c 'echo " $(ls -a /) "'
lacks "ls / hides proc"   " proc "   bash -c 'echo " $(ls -a /) "'

group "BSD vs GNU behaviour"
printf 'aaa\n' > "$T/f"
errs  "sed -i needs an extension" "invalid command code" sed -i 's/a/b/' "$T/f"
is    "sed -i left the file alone" "aaa" cat "$T/f"
succeeds "ls -G is accepted"                ls -G /
errs  "ls rejects GNU long options" "illegal option" ls --all /
errs  "stat rejects -c"             "illegal option" stat -c %n /etc/passwd
succeeds "stat -f works"                    stat -f %N /etc/passwd
errs  "date rejects -d"             "illegal option" date -d now
succeeds "date -v works"                    date -v+1d
errs  "grep rejects -P"             "illegal option" grep -P a /etc/passwd
errs  "readlink rejects -f"         "illegal option" readlink -f /etc
errs  "find rejects -printf"        "unknown primary" find / -printf '%p'
errs  "man has no pages"            "No manual entry" man ls

group "leak containment"
lacks "find / does not walk into /proc"  "/proc"  find / -maxdepth 1
lacks "find / does not show /lib64"      "/lib64" find / -maxdepth 1
lacks "find /usr/libexec hides .sys"     ".sys"   find /usr/libexec -maxdepth 1
errs  "dmesg refuses"     "Operation not permitted" dmesg
lacks "dmesg leaks no kernel log"        "Linux"  dmesg
errs  "umount refuses"    "Operation not permitted" umount /usr/lib
succeeds "/usr/lib survived the umount"  bash -c '[ -n "$(ls -A /usr/lib 2>/dev/null)" ]'
errs  "shutdown refuses"  "NOT super-user"          shutdown -h now
errs  "reboot refuses"    "NOT super-user"          reboot

group "process tools (canned)"
lacks "ps does not leak Linux pids"  "containerd" ps aux
lacks "ps shows no systemd"          "systemd"    ps aux
is    "pgrep matches the fake table" "488"        pgrep Finder
fails "pgrep misses what is absent"  pgrep definitelynotrunning
fails "pkill misses what is absent"  pkill definitelynotrunning
lacks "mount output is APFS"         "ext4"       mount

group "homebrew"
is "brew --prefix"  "/opt/homebrew"  brew --prefix
succeeds "brew list runs"            brew list
if [ -x /usr/libexec/.sys/bin/wget ]; then
  brew install wget >/dev/null 2>&1
  succeeds "brew install wget produced a binary" command -v wget
else
  skip "brew install wget" "host has no wget"
fi

group "zsh (from /etc/zshenv)"
zsh_env_is "OSTYPE reads darwin"    "darwin24.0"  'print -r -- $OSTYPE'
zsh_env_is "VENDOR reads apple"     "apple"       'print -r -- $VENDOR'
zsh_env_is "CPUTYPE reads arm64"    "arm64"       'print -r -- $CPUTYPE'
zsh_env_is "TMPDIR is a Darwin one" "0"           '[[ $TMPDIR == /var/folders/* ]]; print -r -- $?'
zsh_env_is "fpath reaches every digest" "0" \
  'for d in Completion Misc Zle Prompts VCS_Info; do
     (( ${fpath[(I)/System/Library/zsh/functions/$d]} )) || exit 1
   done; print -r -- 0'
for fn in compinit zmv add-zsh-hook colors promptinit zargs edit-command-line; do
  succeeds "autoload $fn resolves" /bin/zsh -lc "autoload +X -Uz $fn"
done

group "zsh (from /etc/zshrc, needs a pty)"
zsh_rc_is "prompt is the Mac's"    "%n@%m %1~ %% "               'print -r -- $PS1'
zsh_rc_is "history file is Apple's path" "/Users/Learner/.zsh_history" 'print -r -- $HISTFILE'
zsh_rc_is "Home key is bound"      "0" 'bindkey "^[[H" | grep -q beginning-of-line; print -r -- $?'
zsh_rc_is "Delete key is bound"    "0" 'bindkey "^[[3~" | grep -q delete-char; print -r -- $?'
zsh_rc_is "Up arrow searches history" "0" 'bindkey | grep -q up-line-or-search; print -r -- $?'
fails     "no .zcompdump in \$HOME"   test -e /Users/Learner/.zcompdump

C=/System/Library/zsh/functions/Completion
if ls "$C"/_* >/dev/null 2>&1 || ls "$C"/*.zwc >/dev/null 2>&1; then
  N="$(zi 'print -r -- ${#_comps}' | tr -dc 0-9)"
  if [ "${N:-0}" -gt 100 ]; then pass "completion is live (${N} completers)"
  else fail "completion is live" "only ${N:-0} completers; check fpath in /etc/zshenv"; fi
  zsh_rc_is "git completion is defined" "1" 'print -r -- ${+_comps[git]}'
else
  skip "programmable completion" "payload has no Completion functions; run revendor.sh"
fi

group "command binding (host image drift)"
# A zero-length file here is a placeholder build.sh wrote that enter.sh never
# managed to bind a host binary over - the symptom of the host image changing.
UNBOUND=""
for d in /bin /usr/bin /sbin /usr/sbin; do
  for f in "$d"/*; do
    [ -f "$f" ] || continue
    [ -s "$f" ] || UNBOUND="$UNBOUND ${f##*/}"
  done
done
if [ -z "$UNBOUND" ]; then pass "every manifest name is bound to a real binary"
else fail "unbound command placeholders" "$UNBOUND"; fi

printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
