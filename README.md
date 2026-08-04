# macOS terminal simulation

Puts the learner in a shell that looks and behaves like a Mac, on an Ubuntu
container, with no root and no Docker. The session is recorded by `script` and
rendered to stdout by `.codesignal/run_solution.sh` for the AI grader.

```
Learner@Learners-MacBook-Pro ~ % sw_vers
ProductName:		macOS
ProductVersion:		15.5
BuildVersion:		24F74
```

## How it works

`setup.sh` → `setup_steps.sh` → `macos/build.sh` assembles a Darwin-shaped root
filesystem at `$HOME/.macos`, then `setup.sh` execs:

```
script -q -f /tmp/.session_log.txt -c "bash .codesignal/macos/enter.sh"
```

`enter.sh` enters a user namespace (`unshare --map-root-user`), which grants the
capabilities needed to bind-mount and `chroot` without being root. It binds the
host's libraries and binaries into the fake root, then chroots into it and starts
zsh as a login shell.

The learner therefore gets a **real** filesystem root: `pwd` is `/Users/Learner`,
`cd /Applications` works, and `ls /` shows `Applications System Library Volumes`.

### Layout

| Path | What it is |
|---|---|
| `build.sh` | Builds the root filesystem. Pure file creation, ~0.3s. |
| `enter.sh` | Namespaces, bind mounts, chroot, login. |
| `manifest/*.txt` | Curated command names per directory — the reason `ls /usr/bin` reads like a Mac and has no `apt`, `dpkg` or `systemctl`. |
| `shims/usr_bin/` | BSD-flavored and macOS-only commands. |
| `shims/usr_sbin/`, `shims/sbin/`, `shims/bin/` | Same, for those directories. |
| `shims/homebrew_bin/brew` | Homebrew simulator. |
| `vendor/vendor.txz` | zsh, its modules and digests, `less` and `nano`, packed as one `tar.xz`. |
| `vendor/checksums.txt` | sha256 of `vendor.txz`. `build.sh` verifies before unpacking. |
| `revendor.sh` | Rebuilds `vendor/vendor.txz` from upstream packages. Needs network; only for repair. |

Nothing is installed at setup time: no `apt`. Total setup cost is about **0.5
seconds**, most of it fetching and verifying the vendored payload.

### Why this tree lives here instead of directly in the task

The simulator needs ~3.7 MB of real binaries — the zsh 5.8.1 executable, its 33
modules, 10 function digests, `less` and `nano`. The host image ships none of
them, so without these there is no shell and nothing works. This whole `macos/`
tree used to be committed straight into the CodeSignal task's own storage, but
that storage is hostile to binaries:

- **It corrupts binaries.** Files were round-tripped through a text encoding,
  which replaces every byte that is not valid UTF-8 with `U+FFFD`. That destroyed
  the entire original tree — a 2 KB file picked up 102 replacement characters.
  Nothing warned; `build.sh` just produced a chroot with no working `/bin/zsh`.
- **It caps file size and file count**, neither documented and neither behaving
  like a simple limit. Nothing above 75,522 B ever survived a save; a save that
  rejected 78,952 B accepted 202,848 B in the same tree; and a fixed number of
  files silently failed to persist regardless of their content.

The old workaround was splitting one `tar.xz` into ~25 base64 pieces small
enough to survive that round trip. The real fix is not touching that storage at
all: this `macos/` tree lives in `learn_macos` on GitHub, and
`.codesignal/setup_steps.sh` fetches it fresh into `.codesignal/macos/` on a
normal filesystem before running `build.sh`. A plain binary `vendor.txz` is fine
there, so no chunking or text-safe encoding is needed.

`build.sh` verifies `vendor/checksums.txt` and unpacks `vendor.txz` to a temp dir,
deleting it on exit. A missing or corrupt payload aborts the build naming the
cause, with the message also written to `/tmp/.macos_build_error`. To repair:

```
bash macos/revendor.sh
```

That refetches the pinned packages, restages the tree, repacks `vendor.txz`,
regenerates the checksum and verifies the result unpacks to exactly what was
staged — then commit and push the result to `learn_macos`. **zsh's modules and
function digests are ABI-locked to the zsh binary** — they come from the same
package pair and must always be replaced together, never mixed across versions.

Three function digests are **deliberately excluded** — `Zftp.zwc`
(`zfget`/`zfput`), `Calendar.zwc` (`calendar*`) and `TCP.zwc`
(`tcp_open`/`tcp_send`). Nothing here can reach them: they are not autoloaded by
`/etc/zshenv` or `/etc/zshrc`, and `compinit` does not want them. `revendor.sh`
skips them by name, so keep that list and this note in sync.

### Command binding

`build.sh` writes a zero-length placeholder for every name in a manifest that the
host can actually provide. `enter.sh` bind-mounts the real host binary over each
placeholder. Non-empty files are shims and are left alone. The result is that
`which sed` says `/usr/bin/sed`, `ls -l /usr/bin` shows real binaries with real
sizes owned by `root wheel`, and no Linux-only command names are visible.

### Identity

The session runs as uid 0 inside the namespace, because any other uid mapping
makes `unshare` setuid away from root and drop the capabilities needed to mount.
`/etc/passwd` is what does the naming:

- uid 0 → `Learner`, gid 0 → `staff` (files the learner owns)
- uid 65534 → `root`, gid 65534 → `wheel` (host-owned system files, which are
  unmapped in the namespace and therefore surface as the overflow uid)

`id` is shimmed to report the 501/20 a real Mac account has.

## What is simulated

**BSD vs GNU behavior** — the layer that matters most if the task teaches real
macOS shell work:

- `sed -i` requires an extension argument. `sed -i 's/a/b/' f` produces the exact
  macOS error, `sed: 1: "f": invalid command code f`, and leaves the file alone.
- `ls` accepts `-G`, rejects GNU long options, formats `-l` with BSD column
  spacing and no SELinux dot, and counts totals in 512-byte blocks.
- `stat -f`, `date -v`/`-r`/`-j`, `md5`, `shasum`, `du` in 512-byte blocks.
- `readlink -f`, `grep -P`, `find -printf`, `xargs -r`, `stat -c` and `date -d`
  all fail the way BSD fails, with BSD's usage text.

**macOS-only commands** — `sw_vers`, `uname` (Darwin/arm64), `open`, `pbcopy`,
`pbpaste`, `say`, `defaults`, `xattr`, `plutil`, `osascript`, `caffeinate`,
`mdfind`, `screencapture`, `xcode-select`, `csrutil`, `spctl`, `pmset`,
`vm_stat`, `arch`, `diskutil`, `system_profiler`, `softwareupdate`,
`networksetup`, `systemsetup`, `sysctl`, `nvram`, `launchctl`, `df`, `mount`,
`ps`, `top`, `file`, `id`, `man`, `sudo`.

**Homebrew** — `brew install/uninstall/list/info/search/update/upgrade/doctor/
config/--prefix`, with an installed-formula database under
`/opt/homebrew/Cellar`. When a formula's binary happens to exist on the host,
`brew install` links it into the prefix, so `brew install wget && wget --version`
really works.

**Filesystem** — `/Users/Learner` with the standard home directories,
`/Applications` and `/System/Applications` with real `.app` bundles and
`Info.plist` files, `/System/Library/CoreServices/SystemVersion.plist`,
`/etc` `/var` `/tmp` as symlinks into `/private`, `/Volumes/Macintosh HD`.

## Known limitations

- **No SIP.** `/usr/bin` and `/System` are writable. Inside the user namespace we
  hold `CAP_DAC_OVERRIDE` over every file the namespace maps, so no permission
  scheme can prevent this.
- **`brew install` of a formula the host lacks** records the install and prints
  correct output, but leaves no working binary. Formulae backed by a real host
  binary (wget, git, curl, tmux, python, node, openssl, rsync, watch, make,
  pkg-config, ripgrep) do work end to end.
- **No man pages.** The image ships none, so `man` reports
  `No manual entry for X` rather than leaking Ubuntu's "system has been
  minimized" notice.
- **`/proc` is the host's**, because a container's user namespace cannot mount a
  fresh procfs. That is why `ps` and `top` are shimmed — a real `ps` would list
  the container's Linux processes.
- **Seams that remain**: `ls -a /` hides `lib`, `lib64` and `proc` via the `ls`
  shim, but `echo /*` or `find /` still reveals them. Shims are readable shell
  scripts. `uname -m` reports arm64 while the binaries underneath are x86-64.
- **Error *wording* is still GNU's.** The shims `exec -a <name>` so the prefix is
  right — `sed: can't read …`, not `/usr/libexec/.sys/bin/sed: …` — but the
  phrasing underneath is GNU's: `ls: cannot access 'x'` where macOS says
  `ls: x: No such file or directory`, `stat: cannot statx`, and `find` quotes
  with `‘ ’`. Only the deliberately-reproduced errors (BSD `-i`, rejected long
  options, the usage blocks) are exact.
- **Version strings of real binaries leak Linux.** `$ZSH_VERSION` is 5.8.1 where
  macOS 15.5 ships 5.9; `less --version` says `590 (GNU regular expressions)`
  against Apple's `643 (POSIX …)`; `nano --version` says `GNU nano 6.2`; and a
  `brew install`ed host binary reports its own build, e.g. `wget … built on
  linux-gnu`. Avoid tasks that assert on version output.
- **Tab completion is minimal.** `/etc/zshenv` puts
  `/System/Library/zsh/functions/Completion` on `fpath`, but that directory is
  not vendored — its digests are ~10 MB, dominated by a 5.2 MB `Unix.zwc`. So
  `compinit` finds no `_*` functions and completion falls back to filenames: no
  `git <tab>`, no flag completion. To enable it, add
  `Completion/{Base,Unix,Zsh,Darwin,X}.zwc` in `revendor.sh` — and deliberately
  *not* `Debian.zwc`, `Linux.zwc` or `Redhat.zwc`, which no Mac has.
- **Long commands wrap in the transcript.** At 80 columns zsh's line editor
  repositions with bare `\r`, and `run_solution.sh`'s escape-stripping cannot
  model cursor motion, so a command longer than the terminal width can surface
  with a doubled character. This is why `run_solution.sh` also prints the
  verbatim command list from the `preexec` log — that source is exact.
- **`/opt` contains `python`** alongside `homebrew`, because the host's Python
  has its prefix compiled in and must stay at its original path.

## Changing the persona

Everything identity-related is at the top of `build.sh` (`USER_NAME`,
`HOST_NAME`, `OS_VERSION`, `OS_BUILD`) and in `enter.sh` (`HOST_NAME`, `TZ`).
Changing `USER_NAME` or `HOST_NAME` also means updating the `PROMPT` variable in
`.codesignal/run_solution.sh`, which parses the transcript by prompt.

## Adding a command

1. Drop an executable into `shims/usr_bin/` (or the matching directory).
2. To wrap a real GNU tool, call it at `/usr/libexec/.sys/bin/<name>` — that is
   the host's `/usr/bin`, bind-mounted where the learner will not find it.
3. To expose an existing host binary unchanged, add its name to the relevant
   `manifest/*.txt`.
