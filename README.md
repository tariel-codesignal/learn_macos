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
| `seed.sh` | Populates the built root from a task's own seed directory. Optional; runs after build.sh. |
| `selftest.sh` | ~90 assertions run inside the built root. Run it after any change here, and after the host image changes. |
| `manifest/*.txt` | Curated command names per directory — the reason `ls /usr/bin` reads like a Mac and has no `apt`, `dpkg` or `systemctl`. |
| `manifest/zsh_functions.txt` | Every zsh function name a real Mac ships. Filters what `revendor.sh` vendors for completion. |
| `shims/usr_bin/` | BSD-flavored and macOS-only commands. |
| `shims/usr_sbin/`, `shims/sbin/`, `shims/bin/` | Same, for those directories. |
| `shims/homebrew_bin/brew` | Homebrew simulator. |
| `vendor/vendor.txz` | zsh, its modules, function digests and completion functions, `less` and `nano`, packed as one `tar.xz`. |
| `vendor/checksums.txt` | sha256 of `vendor.txz`. `build.sh` verifies before unpacking. |
| `revendor.sh` | Rebuilds `vendor/vendor.txz` from upstream packages. Needs network; only for repair or to change what is vendored. |

Nothing is installed at setup time: no `apt`. Total setup cost is about **0.5
seconds**, most of it fetching and verifying the vendored payload.

### Why this tree lives here instead of directly in the task

The simulator needs several MB of real binaries — the zsh 5.8.1 executable, its
33 modules, function digests, `less` and `nano`. The host image ships none of
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
staged — then commit and push the result to `learn_macos`. It runs on Linux or
macOS (it falls back to `ar` when `dpkg-deb` is absent), but packing needs GNU
tar for a reproducible checksum — on macOS, `brew install gnu-tar`.

**zsh's modules, function digests and completion functions are ABI-locked to the
zsh binary.** They come from the same package pair and must always be replaced
together, never mixed across versions. A digest from another release is refused
outright — `zwc file has wrong version (zsh-5.8.1)` — and because `/etc/zshrc`
loads them through `autoload -Uz … && …`, a mismatch fails *silently*: no
`compinit`, no completion, no `zmv`. `selftest.sh` is what catches this; you can
also inspect a digest directly with `zcompile -t some.zwc`.

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

Both halves of that fail silently by design: `build.sh` skips a manifest name the
host does not have, and `enter.sh` ignores a bind that does not take. A
zero-length file left in `/bin`, `/usr/bin`, `/sbin` or `/usr/sbin` is therefore
the signature of host-image drift, and `selftest.sh` reports every one it finds.

### Identity

The session runs as uid 0 inside the namespace, because any other uid mapping
makes `unshare` setuid away from root and drop the capabilities needed to mount.
`/etc/passwd` is what does the naming:

- uid 0 → `Learner`, gid 0 → `staff` (files the learner owns)
- uid 65534 → `root`, gid 65534 → `wheel` (host-owned system files, which are
  unmapped in the namespace and therefore surface as the overflow uid)

`id` is shimmed to report the 501/20 a real Mac account has.

### zsh configuration

`/etc/zshenv` and `/etc/zshrc` are written by `build.sh` and track Apple's
versions of those files, with three deliberate differences.

**`fpath` is generated, not hardcoded.** A `.zwc` digest is consulted only when
`fpath` names the directory it was compiled from — the digest sits *beside* that
directory, which need not exist. So `fpath=(/System/Library/zsh/functions)`
reaches nothing at all: it looks for `functions.zwc`, and the directory itself
holds only digests. `build.sh` walks the payload and emits one entry per digest,
so a re-vendored set cannot silently lose a suite. Where a digest and loose
function files share a directory, a digest miss falls back to the files — which
is what lets `Completion/` be vendored either way.

`Newuser` is left off that list on purpose: reaching `zsh-newuser-install` would
let this zsh offer its first-run configuration wizard, which no Mac does.
`enter.sh` blanks the newuser script for the same reason.

**Darwin parameters are set.** This zsh was built for Linux on x86-64, so
`$OSTYPE` would otherwise read `linux-gnu`. `/etc/zshenv` sets `OSTYPE`,
`VENDOR`, `MACHTYPE` and `CPUTYPE` to what a 15.5 arm64 shell reports; besides
fixing `echo $OSTYPE`, this makes zsh's own completion functions take their BSD
branches. `ZSH_VERSION` is deliberately *not* faked — `compinit` and friends
branch on it, and claiming 5.9 could select a code path this 5.8.1 binary cannot
run.

**`compinit` runs.** See below.

## Tab completion

Worth knowing before treating this as a gap: **a stock Mac has no programmable
completion either.** Apple's `/etc/zshrc` never calls `compinit`, so on a fresh
account with no `~/.zshrc`, `git che<tab>` completes filenames and nothing more.
Verify on any Mac with:

```bash
env -i HOME=/tmp/empty TERM=xterm-256color /bin/zsh -l -i -c 'echo ${#_comps}'
```

This tree runs `compinit` anyway, because a course that teaches completion needs
it to work. Two notes on how:

- The dump goes to `/private/var/db/.zcompdump`, not `$HOME`. `compinit` writes a
  dump even when it finds no completers, and a fresh Mac home has no
  `.zcompdump` for `ls -a ~` to show.
- The completion functions are vendored from Ubuntu's `zsh-common`, flattened
  into one directory the way a Mac flattens them, and filtered through
  `manifest/zsh_functions.txt` — the name list from a real Mac. That list
  intentionally *includes* `_apt`, `_dpkg` and `_yum`: Apple ships upstream zsh's
  whole Completion tree, Linux completers included, so a real Mac really does
  complete `apt` once compinit is enabled. Filtering on Apple's list is what
  keeps Ubuntu-only additions out without maintaining a blocklist by hand.

If `vendor.txz` predates this and carries no completion functions, everything
still works — `compinit` just finds nothing, exactly as before. Run
`revendor.sh` to add them.

`/etc/zshrc` also carries Apple's `terminfo`-driven key bindings (Home, End,
Delete, and prefix-search on the arrow keys), plus the CSI forms of those keys,
which Apple's file lacks and the browser terminal actually sends. Without them
Home and End insert escape junk into the line — and into the graded transcript.

## Starting with a task's own files

`seed.sh` populates the built root from a directory the task ships, so a learner
can open a shell already holding the files the exercise is about — and start in
whichever directory the task wants.

```
bash build.sh && bash seed.sh /usercode/FILESYSTEM/.codesignal/macos-seed
```

Order matters: `build.sh` wipes the root, so seeding comes after it. It is
entirely optional — a task with no seed directory gets the stock home, and setup
behaves exactly as before.

The seed directory may hold any of these, all optional:

| Name | What it does |
|---|---|
| `home/` | Copied into `/Users/Learner`. |
| `root/` | Copied into `/` — for `/Applications`, `/etc`, `/Volumes`. |
| `MANIFEST` | Directories and empty files to create, one per line. |
| `START` | One line: the directory the learner's shell starts in. |
| `setup.zsh` | Runs last, inside the simulated Mac, as Learner. |

If none of those names are present, the whole directory is treated as `home/` —
the common case of "just give the learner these files". A worked example is in
[`examples/macos-seed/`](examples/macos-seed).

`MANIFEST` exists because **git cannot store an empty directory**, and neither
can CodeSignal's task storage. It is also the only way to set a mode:

```
dir  Desktop/report/archive
dir  Documents/private 700
file Desktop/report/.gitkeep
file Documents/private/secrets.txt 600
```

`setup.zsh` runs inside the chroot, so it can use the Mac's own commands rather
than reaching into the root from outside — `touch -t` to backdate a file for an
`ls -lt` exercise, `pbcopy` to prime the clipboard, `defaults write`,
`brew install`. The copy is removed afterwards, so the learner never finds it.

`START` is recorded at `/private/var/db/.startdir`, which `enter.sh` reads. A
path that does not exist is a setup-time failure naming the path, not a silent
fallback — but if the file is somehow unusable at login, `enter.sh` falls back to
the home rather than dropping the learner at `/`.

Three things to know before writing a seed:

- **Text only.** Seed content lives in task storage, which mangles binaries —
  the reason this repo exists. Anything binary has to come through `vendor/`.
- **Ownership takes care of itself.** Files copied by the user that runs setup
  map to uid 0 inside the namespace, which `/etc/passwd` names `Learner`. Files
  owned by anyone else surface as `root wheel`.
- **Avoid spaces in a `START` path.** `run_solution.sh` parses the transcript
  with a prompt pattern that expects a space-free directory name. `seed.sh`
  warns when it sees one.

## Self-test

```bash
bash build.sh && MACOS_SELFTEST=selftest.sh bash enter.sh
```

`enter.sh` copies the script into the root, runs it inside the chroot instead of
starting a login shell, and removes it afterwards, so nothing is left in the
learner's filesystem. It checks identity, filesystem shape, every deliberate
BSD-vs-GNU divergence, leak containment, the canned process tools, Homebrew, the
zsh parameters and key bindings, whether completion is live, and whether any
command placeholder failed to bind. Exit status is non-zero if anything fails.

Passing arguments to `enter.sh` also runs them in place of the login shell, which
is useful for graders that want to inspect the built root without a pty.

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
`networksetup`, `systemsetup`, `sysctl`, `nvram`, `df`, `mount`, `file`, `id`,
`man`, `sudo`.

**Commands shimmed because the host's version would be wrong or dangerous** —
`ps`, `top`, `pgrep`, `pkill` (canned; see the limitation below), `dmesg`
(refuses, as a Mac does to non-root, instead of dumping the host kernel's ring
buffer), `umount` (refuses; inside the namespace it would really unmount the
binds that make this work and break the session mid-task), and
`shutdown`/`halt`/`reboot` (refuse with `NOT super-user`; the host's are
systemctl wrappers that would print systemd diagnostics into a Mac session).

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
- **The process tools are a closed fiction.** `/proc` inside the chroot is the
  host's, because a container's user namespace cannot mount a fresh procfs over
  the one it inherited. So `ps`, `top`, `pgrep` and `pkill` all report the same
  hardcoded table instead of anything real: a learner's own `sleep 300 &` does
  not appear in `ps`, and `pkill sleep` reports no match. **Avoid tasks that
  teach process management.** Worth re-testing in the container: `enter.sh`
  already unshares a PID namespace, and `mount -t proc proc "$R/proc"` may
  succeed at a *fresh* mountpoint even though remounting over the inherited
  `/proc` does not. If it does, these four shims can become formatters over real
  data and this limitation goes away.
- **`/usr/lib` and `/usr/share` are the host's**, bind-mounted whole because the
  binaries need them. `ls /usr/share` and `ls /usr/lib` therefore show an Ubuntu
  tree (`x86_64-linux-gnu`, `dpkg`, `doc`). Narrowing this to per-subdirectory
  binds (terminfo, locale, zoneinfo, …) is possible but needs testing against
  every shimmed tool.
- **Seams that remain**: `ls -a /` hides `lib`, `lib64` and `proc`, and `find`
  prunes those plus `/usr/libexec/.sys`, but `echo /*` and `grep -r /` still
  reveal them. Shims are readable shell scripts. `uname -m` reports arm64 while
  the binaries underneath are x86-64.
- **Only `id` reports the Mac's uid.** The session really is uid 0, so
  `stat -f %u`, `ls -ln`, `find -user` and Python's `os.getuid()` all say 0 while
  `id -u` says 501. Avoid tasks that compare them.
- **`$PS1` reads `%%` where Apple's reads `%#`.** `%#` renders as `#` for a
  privileged shell, and this one is uid 0, so the literal `%%` is what keeps the
  prompt showing `%`. The rendered prompt is right; `echo $PS1` is not.
- **Error *wording* is still GNU's.** The shims `exec -a <name>` so the prefix is
  right — `sed: can't read …`, not `/usr/libexec/.sys/bin/sed: …` — but the
  phrasing underneath is GNU's: `ls: cannot access 'x'` where macOS says
  `ls: x: No such file or directory`, `stat: cannot statx`, and `find` quotes
  with `‘ ’`. Only the deliberately-reproduced errors (BSD `-i`, rejected long
  options, the usage blocks) are exact.
- **A few refusals are inferred, not verified.** `shutdown: NOT super-user` is
  verbatim from macOS 15; `halt` and `reboot` are assumed to share BSD's
  super-user check, and `umount`'s wording follows the `mount` shim's style.
  Under `sudo` they still refuse, where a real Mac would proceed.
- **`launchctl` and `log` are absent**, not simulated. Nothing here can model
  launchd, and the host has no equivalent worth exposing. `disable log` in
  `/etc/zshrc` is Apple's line, kept for fidelity, and harmless.
- **Version strings of real binaries leak Linux.** `$ZSH_VERSION` is 5.8.1 where
  macOS 15.5 ships 5.9; `less --version` says `590 (GNU regular expressions)`
  against Apple's `643 (POSIX …)`; `nano --version` says `GNU nano 6.2`; and a
  `brew install`ed host binary reports its own build, e.g. `wget … built on
  linux-gnu`. Avoid tasks that assert on version output.
- **Long commands wrap in the transcript.** At 80 columns zsh's line editor
  repositions with bare `\r`, and `run_solution.sh`'s escape-stripping cannot
  model cursor motion, so a command longer than the terminal width can surface
  with a doubled character. This is why `run_solution.sh` also prints the
  verbatim command list from the `preexec` log — that source is exact.
- **`/opt` contains `python`** alongside `homebrew`, because the host's Python
  has its prefix compiled in and must stay at its original path.

## Notes for the task side

`setup_steps.sh` is the single point of failure for every live task using this:
it fetches `refs/heads/main`, so a bad push here breaks all of them at once, and
a transient GitHub failure fails setup with no retry. Two things worth doing on
that side:

- **Pin it.** Fetch a tag or commit SHA rather than `main`, and move the tag when
  a change has been tested.
- **Do not swallow the diagnosis.** `setup.sh` sends `setup_steps.sh` output to
  `/dev/null`, which also discards `build.sh`'s error messages. On failure, print
  `/tmp/.macos_build_error` if it exists — it names the cause precisely.

```sh
if ! curl -fsSL --retry 3 --retry-all-errors --connect-timeout 10 --max-time 120 \
        "$MACOS_REPO_TARBALL" | tar -xz -C "$MACOS_DIR" --strip-components=1; then
  echo "Could not fetch the macOS simulator sources from GitHub." >&2
  exit 1
fi
```

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
   `manifest/*.txt` — and check the directory against a real Mac first, since
   macOS and Ubuntu disagree about several (`lsof`, `traceroute` and `route` all
   live elsewhere on macOS, and `telnet` has not shipped since 10.13).
4. Add an assertion to `selftest.sh`.
