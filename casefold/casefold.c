/*
 * Case-insensitive, case-preserving path lookup - what a Mac's APFS volume does
 * - for a tree that lives on a case-sensitive Linux filesystem.
 *
 * Loaded into every dynamically linked program in the simulated Mac through
 * /etc/ld.so.preload (not LD_PRELOAD, which `env` would show). Each wrapped
 * call first tries the path exactly as given; only when that names nothing
 * does it walk the path and swap each missing component for a sibling that
 * differs only in case. So:
 *
 *   mkdir notes; mkdir Notes     -> "File exists"
 *   touch Notes/agenda.txt       -> creates notes/agenda.txt
 *   ls Notes, cd Notes, cat NOTES/Agenda.TXT all reach notes/agenda.txt
 *   mv notes Notes               -> renames, as a case-only rename does on a Mac
 *
 * Names are stored as typed, so `ls` shows the case they were created with.
 * Folding is ASCII only; APFS folds all of Unicode, which no lesson relies on.
 * /proc, /dev and /sys are left alone.
 *
 * Directory scans use raw syscalls so they never re-enter these wrappers.
 * Statically linked programs bypass all of this; none ship in the tree.
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <sys/statfs.h>
#include <sys/statvfs.h>
#include <sys/syscall.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/xattr.h>
#include <unistd.h>
#include <utime.h>

#define BUF (PATH_MAX * 2)

static int raw_exists(int dirfd, const char *p) {
  struct stat st;
  return syscall(SYS_newfstatat, dirfd, p, &st, AT_SYMLINK_NOFOLLOW) == 0;
}

/* Finds an entry of dirfd/dir whose name equals `name` ignoring ASCII case. */
static int find_ci(int dirfd, const char *dir, const char *name, char *out, size_t outlen) {
  char dents[8192];
  int fd = syscall(SYS_openat, dirfd, *dir ? dir : ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  if (fd < 0) return 0;
  int found = 0;
  for (;;) {
    long n = syscall(SYS_getdents64, fd, dents, sizeof dents);
    if (n <= 0) break;
    for (long off = 0; off < n;) {
      struct { unsigned long long ino; long long off; unsigned short reclen; unsigned char type; char name[]; } *d =
        (void *)(dents + off);
      if (strcasecmp(d->name, name) == 0 && strlen(d->name) < outlen) {
        strcpy(out, d->name);
        found = 1;
        break;
      }
      off += d->reclen;
    }
    if (found) break;
  }
  syscall(SYS_close, fd);
  return found;
}

static int skipped(const char *p) {
  return !strncmp(p, "/proc", 5) || !strncmp(p, "/dev", 4) || !strncmp(p, "/sys", 4);
}

/*
 * Returns the path to hand the real call: `path` itself when it already names
 * something (or can't be helped), otherwise `buf` holding the folded spelling.
 * The last component is kept as typed when nothing matches it, so creating a
 * new name still works.
 */
static const char *fold_at(int dirfd, const char *path, char *buf) {
  if (!path || !*path || skipped(path)) return path;
  int saved = errno;
  if (strlen(path) >= PATH_MAX || raw_exists(dirfd, path)) { errno = saved; return path; }

  const char *p = path;
  size_t len = 0;
  int changed = 0;
  if (*p == '/') { buf[len++] = '/'; while (*p == '/') p++; }
  buf[len] = '\0';
  while (*p) {
    const char *e = strchr(p, '/');
    size_t n = e ? (size_t)(e - p) : strlen(p);
    if (n > NAME_MAX) { changed = 0; break; }
    size_t at = len;                    /* this component starts here in buf */
    memcpy(buf + at, p, n);
    len = at + n;
    buf[len] = '\0';
    int dots = (n == 1 && p[0] == '.') || (n == 2 && p[0] == '.' && p[1] == '.');
    if (!dots && !raw_exists(dirfd, buf)) {
      char dir[PATH_MAX], name[NAME_MAX + 1], real[NAME_MAX + 1];
      memcpy(dir, buf, at);
      dir[at] = '\0';
      if (at > 1) dir[at - 1] = '\0';  /* drop the separator, but keep "/" */
      memcpy(name, p, n);
      name[n] = '\0';
      if (!find_ci(dirfd, dir, name, real, sizeof real)) {
        /* nothing further down can exist either: keep the rest as typed */
        snprintf(buf + len, BUF - len, "%s", p + n);
        break;
      }
      memcpy(buf + at, real, n + 1);    /* an ASCII case match is the same length */
      changed = 1;
    }
    if (!e) break;
    p = e;
    while (*p == '/') p++;
    buf[len++] = '/';                   /* kept even when it trails */
    buf[len] = '\0';
  }
  errno = saved;
  return changed ? buf : path;
}

static const char *fold(const char *path, char *buf) { return fold_at(AT_FDCWD, path, buf); }

#define REAL(name) \
  static __typeof__(name) *real_##name; \
  if (!real_##name) real_##name = dlsym(RTLD_NEXT, #name)

/* ---------------------------------------------------------------- open */

static int has_mode(int flags) { return (flags & O_CREAT) || (flags & O_TMPFILE) == O_TMPFILE; }

#define OPEN_WRAP(name) \
  int name(const char *path, int flags, ...) { \
    REAL(name); char b[BUF]; mode_t m = 0; \
    if (has_mode(flags)) { va_list ap; va_start(ap, flags); m = va_arg(ap, mode_t); va_end(ap); } \
    return real_##name(fold(path, b), flags, m); }
OPEN_WRAP(open)
OPEN_WRAP(open64)

#define OPENAT_WRAP(name) \
  int name(int fd, const char *path, int flags, ...) { \
    REAL(name); char b[BUF]; mode_t m = 0; \
    if (has_mode(flags)) { va_list ap; va_start(ap, flags); m = va_arg(ap, mode_t); va_end(ap); } \
    return real_##name(fd, fold_at(fd, path, b), flags, m); }
OPENAT_WRAP(openat)
OPENAT_WRAP(openat64)

/* the _FORTIFY_SOURCE entry points Ubuntu builds call instead */
int __open_2(const char *path, int flags) { REAL(__open_2); char b[BUF]; return real___open_2(fold(path, b), flags); }
int __open64_2(const char *path, int flags) { REAL(__open64_2); char b[BUF]; return real___open64_2(fold(path, b), flags); }
int __openat_2(int fd, const char *path, int flags) { REAL(__openat_2); char b[BUF]; return real___openat_2(fd, fold_at(fd, path, b), flags); }
int __openat64_2(int fd, const char *path, int flags) { REAL(__openat64_2); char b[BUF]; return real___openat64_2(fd, fold_at(fd, path, b), flags); }

int creat(const char *path, mode_t m) { REAL(creat); char b[BUF]; return real_creat(fold(path, b), m); }
int creat64(const char *path, mode_t m) { REAL(creat64); char b[BUF]; return real_creat64(fold(path, b), m); }
FILE *fopen(const char *path, const char *mode) { REAL(fopen); char b[BUF]; return real_fopen(fold(path, b), mode); }
FILE *fopen64(const char *path, const char *mode) { REAL(fopen64); char b[BUF]; return real_fopen64(fold(path, b), mode); }
FILE *freopen(const char *path, const char *mode, FILE *f) { REAL(freopen); char b[BUF]; return real_freopen(fold(path, b), mode, f); }
FILE *freopen64(const char *path, const char *mode, FILE *f) { REAL(freopen64); char b[BUF]; return real_freopen64(fold(path, b), mode, f); }
DIR *opendir(const char *path) { REAL(opendir); char b[BUF]; return real_opendir(fold(path, b)); }

/* ---------------------------------------------------------------- stat */

int stat(const char *path, struct stat *st) { REAL(stat); char b[BUF]; return real_stat(fold(path, b), st); }
int stat64(const char *path, struct stat64 *st) { REAL(stat64); char b[BUF]; return real_stat64(fold(path, b), st); }
int lstat(const char *path, struct stat *st) { REAL(lstat); char b[BUF]; return real_lstat(fold(path, b), st); }
int lstat64(const char *path, struct stat64 *st) { REAL(lstat64); char b[BUF]; return real_lstat64(fold(path, b), st); }
int fstatat(int fd, const char *path, struct stat *st, int fl) { REAL(fstatat); char b[BUF]; return real_fstatat(fd, fold_at(fd, path, b), st, fl); }
int fstatat64(int fd, const char *path, struct stat64 *st, int fl) { REAL(fstatat64); char b[BUF]; return real_fstatat64(fd, fold_at(fd, path, b), st, fl); }
int statx(int fd, const char *path, int fl, unsigned int mask, struct statx *st) { REAL(statx); char b[BUF]; return real_statx(fd, fold_at(fd, path, b), fl, mask, st); }

/* pre-2.33 entry points, still what older binaries link against */
int __xstat(int v, const char *path, struct stat *st);
int __lxstat(int v, const char *path, struct stat *st);
int __xstat64(int v, const char *path, struct stat64 *st);
int __lxstat64(int v, const char *path, struct stat64 *st);
int __fxstatat(int v, int fd, const char *path, struct stat *st, int fl);
int __fxstatat64(int v, int fd, const char *path, struct stat64 *st, int fl);
int __xstat(int v, const char *path, struct stat *st) { REAL(__xstat); char b[BUF]; return real___xstat(v, fold(path, b), st); }
int __lxstat(int v, const char *path, struct stat *st) { REAL(__lxstat); char b[BUF]; return real___lxstat(v, fold(path, b), st); }
int __xstat64(int v, const char *path, struct stat64 *st) { REAL(__xstat64); char b[BUF]; return real___xstat64(v, fold(path, b), st); }
int __lxstat64(int v, const char *path, struct stat64 *st) { REAL(__lxstat64); char b[BUF]; return real___lxstat64(v, fold(path, b), st); }
int __fxstatat(int v, int fd, const char *path, struct stat *st, int fl) { REAL(__fxstatat); char b[BUF]; return real___fxstatat(v, fd, fold_at(fd, path, b), st, fl); }
int __fxstatat64(int v, int fd, const char *path, struct stat64 *st, int fl) { REAL(__fxstatat64); char b[BUF]; return real___fxstatat64(v, fd, fold_at(fd, path, b), st, fl); }

int statfs(const char *path, struct statfs *st) { REAL(statfs); char b[BUF]; return real_statfs(fold(path, b), st); }
int statvfs(const char *path, struct statvfs *st) { REAL(statvfs); char b[BUF]; return real_statvfs(fold(path, b), st); }

/* ------------------------------------------------------- access, exec, cd */

int access(const char *path, int m) { REAL(access); char b[BUF]; return real_access(fold(path, b), m); }
int euidaccess(const char *path, int m) { REAL(euidaccess); char b[BUF]; return real_euidaccess(fold(path, b), m); }
int eaccess(const char *path, int m) { REAL(eaccess); char b[BUF]; return real_eaccess(fold(path, b), m); }
int faccessat(int fd, const char *path, int m, int fl) { REAL(faccessat); char b[BUF]; return real_faccessat(fd, fold_at(fd, path, b), m, fl); }
int chdir(const char *path) { REAL(chdir); char b[BUF]; return real_chdir(fold(path, b)); }
int execve(const char *path, char *const argv[], char *const envp[]) { REAL(execve); char b[BUF]; return real_execve(fold(path, b), argv, envp); }
int execv(const char *path, char *const argv[]) { REAL(execv); char b[BUF]; return real_execv(fold(path, b), argv); }
char *realpath(const char *path, char *out) { REAL(realpath); char b[BUF]; return real_realpath(fold(path, b), out); }
char *canonicalize_file_name(const char *path) { REAL(canonicalize_file_name); char b[BUF]; return real_canonicalize_file_name(fold(path, b)); }
ssize_t readlink(const char *path, char *out, size_t n) { REAL(readlink); char b[BUF]; return real_readlink(fold(path, b), out, n); }
ssize_t readlinkat(int fd, const char *path, char *out, size_t n) { REAL(readlinkat); char b[BUF]; return real_readlinkat(fd, fold_at(fd, path, b), out, n); }

/* ------------------------------------------------------- create / remove */

int mkdir(const char *path, mode_t m) { REAL(mkdir); char b[BUF]; return real_mkdir(fold(path, b), m); }
int mkdirat(int fd, const char *path, mode_t m) { REAL(mkdirat); char b[BUF]; return real_mkdirat(fd, fold_at(fd, path, b), m); }
int rmdir(const char *path) { REAL(rmdir); char b[BUF]; return real_rmdir(fold(path, b)); }
int unlink(const char *path) { REAL(unlink); char b[BUF]; return real_unlink(fold(path, b)); }
int unlinkat(int fd, const char *path, int fl) { REAL(unlinkat); char b[BUF]; return real_unlinkat(fd, fold_at(fd, path, b), fl); }
int remove(const char *path) { REAL(remove); char b[BUF]; return real_remove(fold(path, b)); }
int mknod(const char *path, mode_t m, dev_t d) { REAL(mknod); char b[BUF]; return real_mknod(fold(path, b), m, d); }
int mknodat(int fd, const char *path, mode_t m, dev_t d) { REAL(mknodat); char b[BUF]; return real_mknodat(fd, fold_at(fd, path, b), m, d); }
int mkfifo(const char *path, mode_t m) { REAL(mkfifo); char b[BUF]; return real_mkfifo(fold(path, b), m); }
int mkfifoat(int fd, const char *path, mode_t m) { REAL(mkfifoat); char b[BUF]; return real_mkfifoat(fd, fold_at(fd, path, b), m); }
int symlink(const char *target, const char *path) { REAL(symlink); char b[BUF]; return real_symlink(target, fold(path, b)); }
int symlinkat(const char *target, int fd, const char *path) { REAL(symlinkat); char b[BUF]; return real_symlinkat(target, fd, fold_at(fd, path, b)); }
int link(const char *from, const char *to) { REAL(link); char b1[BUF], b2[BUF]; return real_link(fold(from, b1), fold(to, b2)); }
int linkat(int fd1, const char *from, int fd2, const char *to, int fl) { REAL(linkat); char b1[BUF], b2[BUF]; return real_linkat(fd1, fold_at(fd1, from, b1), fd2, fold_at(fd2, to, b2), fl); }

/* ---------------------------------------------------------------- rename */

/*
 * The destination folds too, so `mv a.txt A.TXT` would fold both names onto
 * a.txt and do nothing. A case-only rename on a Mac changes the stored name,
 * so when both sides land on the same entry, rename to the spelling typed.
 */
static int do_renameat2(int fd1, const char *from, int fd2, const char *to, unsigned int fl) {
  char b1[BUF], b2[BUF];
  const char *f = fold_at(fd1, from, b1);
  const char *t = fold_at(fd2, to, b2);
  if (t != to) {
    struct stat s1, s2;
    if (syscall(SYS_newfstatat, fd1, f, &s1, AT_SYMLINK_NOFOLLOW) == 0 &&
        syscall(SYS_newfstatat, fd2, t, &s2, AT_SYMLINK_NOFOLLOW) == 0 &&
        s1.st_dev == s2.st_dev && s1.st_ino == s2.st_ino) {
      /* keep the folded directories, take the typed final name */
      const char *slash = strrchr(t, '/');
      const char *want = strrchr(to, '/');
      want = want ? want + 1 : to;
      if (slash) {
        size_t n = (size_t)(slash - t) + 1;
        memmove(b2, t, n);
        snprintf(b2 + n, BUF - n, "%s", want);
        t = b2;
      } else {
        t = want;
      }
    }
  }
  return syscall(SYS_renameat2, fd1, f, fd2, t, fl);
}
int rename(const char *from, const char *to) { return do_renameat2(AT_FDCWD, from, AT_FDCWD, to, 0) ? -1 : 0; }
int renameat(int fd1, const char *from, int fd2, const char *to) { return do_renameat2(fd1, from, fd2, to, 0) ? -1 : 0; }
int renameat2(int fd1, const char *from, int fd2, const char *to, unsigned int fl) { return do_renameat2(fd1, from, fd2, to, fl) ? -1 : 0; }

/* ------------------------------------------------------------ attributes */

int chmod(const char *path, mode_t m) { REAL(chmod); char b[BUF]; return real_chmod(fold(path, b), m); }
int fchmodat(int fd, const char *path, mode_t m, int fl) { REAL(fchmodat); char b[BUF]; return real_fchmodat(fd, fold_at(fd, path, b), m, fl); }
int chown(const char *path, uid_t u, gid_t g) { REAL(chown); char b[BUF]; return real_chown(fold(path, b), u, g); }
int lchown(const char *path, uid_t u, gid_t g) { REAL(lchown); char b[BUF]; return real_lchown(fold(path, b), u, g); }
int fchownat(int fd, const char *path, uid_t u, gid_t g, int fl) { REAL(fchownat); char b[BUF]; return real_fchownat(fd, fold_at(fd, path, b), u, g, fl); }
int utime(const char *path, const struct utimbuf *t) { REAL(utime); char b[BUF]; return real_utime(fold(path, b), t); }
int utimes(const char *path, const struct timeval t[2]) { REAL(utimes); char b[BUF]; return real_utimes(fold(path, b), t); }
int lutimes(const char *path, const struct timeval t[2]) { REAL(lutimes); char b[BUF]; return real_lutimes(fold(path, b), t); }
int utimensat(int fd, const char *path, const struct timespec t[2], int fl) { REAL(utimensat); char b[BUF]; return real_utimensat(fd, fold_at(fd, path, b), t, fl); }
int truncate(const char *path, off_t n) { REAL(truncate); char b[BUF]; return real_truncate(fold(path, b), n); }
int truncate64(const char *path, off64_t n) { REAL(truncate64); char b[BUF]; return real_truncate64(fold(path, b), n); }
ssize_t getxattr(const char *path, const char *name, void *v, size_t n) { REAL(getxattr); char b[BUF]; return real_getxattr(fold(path, b), name, v, n); }
ssize_t lgetxattr(const char *path, const char *name, void *v, size_t n) { REAL(lgetxattr); char b[BUF]; return real_lgetxattr(fold(path, b), name, v, n); }
ssize_t listxattr(const char *path, char *l, size_t n) { REAL(listxattr); char b[BUF]; return real_listxattr(fold(path, b), l, n); }
ssize_t llistxattr(const char *path, char *l, size_t n) { REAL(llistxattr); char b[BUF]; return real_llistxattr(fold(path, b), l, n); }
