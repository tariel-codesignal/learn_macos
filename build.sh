#!/bin/bash
# Assembles the Darwin-shaped root filesystem. Runs once, at task setup, outside
# any namespace. Everything here is plain file creation - the mounts that make it
# usable happen later in enter.sh.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
R="${MACOS_ROOT:-$HOME/.macos}"
USER_NAME="Learner"
HOST_NAME="Learners-MacBook-Pro"
OS_VERSION="15.5"
OS_BUILD="24F74"

# ----------------------------------------------------------- vendored payload
# zsh, its modules and function digests, less and nano are the only part of this
# task that is not plain text. They are not committed here: this whole macos/
# tree is fetched fresh from github.com (see .codesignal/setup_steps.sh) into a
# normal filesystem, so vendor/vendor.txz just sits alongside this script as a
# plain xz'd tar - no chunking or text-safe encoding needed.
# Takes the message as arguments, not on stdin: piping into a function puts it in
# a subshell, where `exit 1` would abandon only the subshell and let the build
# carry on to report success with a broken root.
bail() { # bail <line>...
  printf '%s\n' "$@" | tee /tmp/.macos_build_error >&2
  exit 1
}

VEN="$(mktemp -d)"
trap 'rm -rf "$VEN"' EXIT

if [ ! -f "$HERE/vendor/vendor.txz" ]; then
  bail "macOS simulator: vendor/vendor.txz is missing." \
       "Rebuild it with: .codesignal/macos/revendor.sh"
fi

# Verify before trusting it, so corruption is named precisely instead of
# surfacing as a confusing tar error. Paths in checksums.txt are relative to
# vendor/, hence the cd.
if ! VERR="$( cd "$HERE/vendor" && sha256sum -c checksums.txt --quiet 2>&1 )"; then
  bail "macOS simulator: the vendored payload is corrupt." \
       "$VERR" \
       "" \
       "Rebuild it with:" \
       "  .codesignal/macos/revendor.sh"
fi

if ! tar -C "$VEN" -xJf "$HERE/vendor/vendor.txz"; then
  bail "macOS simulator: could not unpack the vendored payload." \
       "Rebuild it with: .codesignal/macos/revendor.sh"
fi

for need in zsh/bin/zsh zsh/modules zsh/functions tools/bin/less tools/bin/nano; do
  [ -e "$VEN/$need" ] || bail "macOS simulator: payload is missing $need."
done

rm -rf "$R"
mkdir -p "$R"

# ---------------------------------------------------------------- directories
mkdir -p "$R"/{Applications,Library,System,Users,Volumes,cores,opt,private,usr,bin,sbin,lib64,proc,dev}
mkdir -p "$R"/private/{etc,var,tmp}
mkdir -p "$R"/private/var/{db,folders,log,root,run,tmp,empty}
mkdir -p "$R"/private/etc/{paths.d,ssl}
mkdir -p "$R"/usr/{bin,sbin,share,lib,libexec,local}
mkdir -p "$R"/usr/local/{bin,lib,share,opt}
mkdir -p "$R"/usr/libexec/.sys/{bin,sbin}
mkdir -p "$R"/opt/homebrew/{bin,sbin,Cellar,var/homebrew,opt}
mkdir -p "$R"/opt/python
mkdir -p "$R"/System/{Applications,Library,Volumes,Cryptexes}
mkdir -p "$R"/System/Applications/Utilities
mkdir -p "$R"/System/Library/{CoreServices,Frameworks,Fonts,PrivateFrameworks,LaunchDaemons,zsh}
mkdir -p "$R"/System/Cryptexes/App/usr/bin
mkdir -p "$R"/Library/{Application\ Support,Caches,Fonts,Logs,Preferences,Developer}
mkdir -p "$R"/Library/Developer/CommandLineTools/usr/bin
chmod 1777 "$R"/private/tmp

# macOS keeps /etc, /var and /tmp as symlinks into /private
ln -sfn private/etc "$R/etc"
ln -sfn private/var "$R/var"
ln -sfn private/tmp "$R/tmp"
ln -sfn usr/lib "$R/lib"
ln -sfn / "$R/Volumes/Macintosh HD"

# --------------------------------------------------------------------- /Users
H="$R/Users/$USER_NAME"
mkdir -p "$H"/{Desktop,Documents,Downloads,Movies,Music,Pictures,Public}
mkdir -p "$H"/Library/{Application\ Support,Caches,Preferences,Logs,Fonts,Containers}
mkdir -p "$H"/Public/Drop\ Box
printf '0x08000100:0x0' > "$H/.CFUserTextEncoding"
mkdir -p "$R/Users/Shared"

# ----------------------------------------------------------------- /private/etc
E="$R/private/etc"

cat > "$E/passwd" <<EOF
##
# User Database
#
# Note that this file is consulted directly only when the system is running
# in single-user mode. At other times this information is provided by
# Open Directory.
##
nobody:*:-2:-2:Unprivileged User:/var/empty:/usr/bin/false
$USER_NAME:*:0:0:$USER_NAME:/Users/$USER_NAME:/bin/zsh
daemon:*:1:1:System Services:/var/root:/usr/bin/false
_spotlight:*:89:89:Spotlight:/var/db/spotlight:/usr/bin/false
_windowserver:*:88:88:WindowServer:/var/run/windowserver:/usr/bin/false
root:*:65534:65534:System Administrator:/var/root:/bin/sh
EOF

cat > "$E/group" <<'EOF'
##
# Group Database
##
nobody:*:-2:
nogroup:*:-1:
staff:*:0:root
daemon:*:1:root
everyone:*:12:
admin:*:80:root,Learner
_developer:*:204:Learner
wheel:*:65534:root
EOF

printf '%s.local\n' "$HOST_NAME" > "$E/hostname"

cat > "$E/hosts" <<EOF
##
# Host Database
#
# localhost is used to configure the loopback interface
# when the system is booting.  Do not change this entry.
##
127.0.0.1	localhost
255.255.255.255	broadcasthost
::1             localhost
127.0.0.1	$HOST_NAME.local
EOF

cat > "$E/shells" <<'EOF'
# List of acceptable shells for chpass(1).
# Ftpd will not allow users to connect who are not using
# one of these shells.

/bin/bash
/bin/csh
/bin/dash
/bin/ksh
/bin/sh
/bin/tcsh
/bin/zsh
EOF

cat > "$E/paths" <<'EOF'
/usr/local/bin
/usr/bin
/bin
/usr/sbin
/sbin
EOF

# ------------------------------------------------------------------ zsh config
# zsh lives at a relocated prefix; /etc/zshenv points it at its modules and
# functions before anything else runs.
cat > "$E/zshenv" <<'EOF'
module_path=(/System/Library/zsh/modules)
fpath=(/System/Library/zsh/functions /System/Library/zsh/functions/Completion)
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/System/Cryptexes/App/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export SHELL=/bin/zsh
export PAGER=less
export NANORC=/System/Library/nano/nanorc
export TMPDIR=/var/folders/qz/8k3n7x2d1r7g9v4mbqp0lqrc0000gn/T/
EOF

cat > "$E/zprofile" <<'EOF'
# System-wide profile for interactive zsh(1) login shells.
if [ -x /usr/libexec/path_helper ]; then
	eval `/usr/libexec/path_helper -s`
fi
EOF

cat > "$E/zshrc" <<'EOF'
# System-wide profile for interactive zsh(1) shells.

# Correctly display UTF-8 with combining characters.
if [[ "$(locale LC_CTYPE)" == "UTF-8" ]]; then
	setopt COMBINING_CHARS
fi

# Disable the log builtin, so we don't conflict with /usr/bin/log
disable log

# Save command history
HISTFILE=${ZDOTDIR:-$HOME}/.zsh_history
HISTSIZE=2000
SAVEHIST=1000

# Beep on error
setopt BEEP

# Default prompt
PS1="%n@%m %1~ %% "

# Useful support for interacting with Terminal.app or other terminal programs
[ -r "/etc/zshrc_$TERM_PROGRAM" ] && . "/etc/zshrc_$TERM_PROGRAM"

autoload -Uz compinit && compinit -u -d "${ZDOTDIR:-$HOME}/.zcompdump" 2>/dev/null

# --- CodeSignal command tracking -------------------------------------------
# PROMPT_SP marks partial lines with an inverse "%", which only adds noise to a
# recorded transcript.
unsetopt PROMPT_SP
preexec() { print -r -- "$1" >> /private/var/db/.cmdlog 2>/dev/null }
EOF

# This zsh build reads its system config from /etc/zsh (Debian layout), but a
# Mac keeps it directly in /etc. Real files live at the Mac paths; /etc/zsh
# just points at them.
mkdir -p "$E/zsh"
for f in zshenv zprofile zshrc; do ln -sfn "../$f" "$E/zsh/$f"; done

# ------------------------------------------------------- /System/Library/zsh
install -m 755 "$VEN/zsh/bin/zsh" "$R/bin/zsh"
cp -a "$VEN/zsh/modules" "$R/System/Library/zsh/modules"
cp -a "$VEN/zsh/functions" "$R/System/Library/zsh/functions"

# --------------------------------------------------- SystemVersion.plist etc.
cat > "$R/System/Library/CoreServices/SystemVersion.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>ProductBuildVersion</key>
	<string>$OS_BUILD</string>
	<key>ProductCopyright</key>
	<string>1983-2025 Apple Inc.</string>
	<key>ProductName</key>
	<string>macOS</string>
	<key>ProductUserVisibleVersion</key>
	<string>$OS_VERSION</string>
	<key>ProductVersion</key>
	<string>$OS_VERSION</string>
	<key>iOSSupportVersion</key>
	<string>18.5</string>
</dict>
</plist>
EOF

# ------------------------------------------------------------ app bundles
mkapp() { # mkapp <dir> <AppName> <bundle-id> <version>
  local d="$1/$2.app"
  mkdir -p "$d/Contents/MacOS" "$d/Contents/Resources"
  : > "$d/Contents/MacOS/${2// /}"
  chmod 755 "$d/Contents/MacOS/${2// /}"
  cat > "$d/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>${2// /}</string>
	<key>CFBundleIdentifier</key>
	<string>$3</string>
	<key>CFBundleName</key>
	<string>$2</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$4</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
</dict>
</plist>
PL
}

mkapp "$R/Applications" "Safari"             com.apple.Safari              18.5
mkapp "$R/Applications" "Visual Studio Code" com.microsoft.VSCode          1.99.3
mkapp "$R/Applications" "Google Chrome"      com.google.Chrome             136.0.7103.93
mkapp "$R/Applications" "Slack"              com.tinyspeck.slackmacgap     4.43.51
mkapp "$R/Applications" "iTerm"              com.googlecode.iterm2         3.5.11
mkapp "$R/System/Applications" "Calculator"     com.apple.calculator       10.16
mkapp "$R/System/Applications" "Calendar"       com.apple.iCal             14.0
mkapp "$R/System/Applications" "Notes"          com.apple.Notes            4.11
mkapp "$R/System/Applications" "Preview"        com.apple.Preview          11.0
mkapp "$R/System/Applications" "System Settings" com.apple.systempreferences 15.0
mkapp "$R/System/Applications" "TextEdit"       com.apple.TextEdit         1.20
mkapp "$R/System/Applications/Utilities" "Terminal"         com.apple.Terminal        2.14
mkapp "$R/System/Applications/Utilities" "Activity Monitor" com.apple.ActivityMonitor 10.14
mkapp "$R/System/Applications/Utilities" "Disk Utility"     com.apple.DiskUtility     22.6
mkapp "$R/System/Applications/Utilities" "Console"          com.apple.Console         1.1
ln -sfn /System/Applications/Utilities "$R/Applications/Utilities"

# --------------------------------------------------------------------- shims
install_shims() { # install_shims <src-dir> <dst-dir>
  [ -d "$1" ] || return 0
  mkdir -p "$2"
  cp "$1"/* "$2"/ 2>/dev/null
  chmod 755 "$2"/* 2>/dev/null
}
install_shims "$HERE/shims/usr_bin"      "$R/usr/bin"
# a Mac ships these in /bin as well, so the shim has to win there too
for c in ls date df ps; do
  [ -f "$HERE/shims/usr_bin/$c" ] && install -m 755 "$HERE/shims/usr_bin/$c" "$R/bin/$c"
done
install_shims "$HERE/shims/usr_sbin"     "$R/usr/sbin"
install_shims "$HERE/shims/sbin"         "$R/sbin"
install_shims "$HERE/shims/bin"          "$R/bin"
install_shims "$HERE/shims/homebrew_bin" "$R/opt/homebrew/bin"

# Commands every Mac ships that this host image lacks, vendored as binaries
install -m 755 "$VEN/tools/bin/"* "$R/usr/bin/"
[ -d "$VEN/tools/share/nano" ] && cp -a "$VEN/tools/share/nano" "$R/System/Library/nano"

# sudo: real sudo is setuid and cannot work inside a user namespace
cat > "$R/usr/bin/sudo" <<'EOF'
#!/bin/bash
while [ $# -gt 0 ]; do
  case "$1" in
    -u|-g|-p) shift 2 ;;
    -[A-Za-z]) shift ;;
    --) shift; break ;;
    *) break ;;
  esac
done
[ $# -eq 0 ] && { printf 'usage: sudo -h | -K | -k | -V\nusage: sudo -v [-ABkNnS] [-g group] [-h host] [-p prompt] [-u user]\n' >&2; exit 1; }
exec "$@"
EOF
chmod 755 "$R/usr/bin/sudo"

# python3 lives outside /usr on this host; wrap it so /usr/bin/python3 works
PY_REAL="$(command -v python3 2>/dev/null)"
if [ -n "$PY_REAL" ] && [ ! -e "/usr/bin/python3" ]; then
  printf '#!/bin/bash\nexec %s "$@"\n' "$PY_REAL" > "$R/usr/bin/python3"
  chmod 755 "$R/usr/bin/python3"
  ln -sf python3 "$R/usr/bin/python"
fi

# ------------------------------------------------- bind-mount target stubs
# enter.sh binds a real host binary over each of these, so they must exist as
# files first. Names come from the manifests, which are curated to the set of
# commands a Mac actually ships - no apt, dpkg or systemctl.
stub() { # stub <manifest> <host-dir> <dst-dir>
  local m="$1" hd="$2" dd="$3" n
  mkdir -p "$dd"
  while IFS= read -r n; do
    [ -z "$n" ] && continue
    [ -e "$dd/$n" ] && continue          # a shim already claims this name
    [ -x "$hd/$n" ] || continue          # host does not have it
    : > "$dd/$n"
  done < "$m"
}
stub "$HERE/manifest/bin.txt"      /usr/bin  "$R/bin"
stub "$HERE/manifest/usr_bin.txt"  /usr/bin  "$R/usr/bin"
stub "$HERE/manifest/usr_sbin.txt" /usr/sbin "$R/usr/sbin"
stub "$HERE/manifest/usr_sbin.txt" /usr/bin  "$R/usr/sbin"
stub "$HERE/manifest/sbin.txt"     /usr/sbin "$R/sbin"
stub "$HERE/manifest/sbin.txt"     /usr/bin  "$R/sbin"
# /bin/sh on macOS is a real shell binary, not a symlink to dash
: > "$R/bin/sh"

# tracking + linker plumbing that enter.sh binds over
: > "$R/private/var/db/.cmdlog"
: > "$R/private/etc/ld.so.cache"
mkdir -p "$R/usr/lib" "$R/usr/share" "$R/lib64"

exit 0
