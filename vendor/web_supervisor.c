#define _GNU_SOURCE
#include "web_supervisor.h"

#ifdef __linux__
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/signalfd.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

/* Deletion attempts before the supervisor gives up and reports failure. */
#define SK_DELETE_ATTEMPTS 30
#define SK_DELETE_RETRY_MS 100
/* Re-scan cadence while retiring descendants; new orphans arrive with SIGCHLD,
 * this only bounds a missed edge. */
#define SK_RETIRE_RETRY_MS 100
/* A sibling root younger than this may belong to a supervisor between its
 * mkdir and its flock, so the sweep leaves it for a later launch. */
#define SK_SWEEP_MIN_AGE_SEC 60
/* Private roots are named by 64 random bits in lowercase hex; uniqueness is
 * all the name provides, the 0700 parent provides the privacy. */
#define SK_ROOT_NAME_LEN 16

static int sk_force_scan;

void sk_web_supervisor_force_proc_scan(int on) { sk_force_scan = on; }

/* Every location the browser tree is told to write lives inside the root.
 * One-letter names keep $TMPDIR inside SK_WEB_SUPERVISOR_TMPDIR_MAX. */
static const char *const sk_private_env[][2] = {
    {"HOME", "h"},
    {"TMPDIR", "t"},
    {"XDG_CONFIG_HOME", "c"},
    {"XDG_CACHE_HOME", "k"},
    {"XDG_DATA_HOME", "d"},
    {"XDG_STATE_HOME", "s"},
    {"XDG_RUNTIME_DIR", "r"},
};

/* Open every component relative to its predecessor, never through a symlink. */
static int sk_parent(const char *path, char **storage, const char **name) {
    if (!path || path[0] != '/') { errno = EINVAL; return -1; }
    char *copy = strdup(path);
    if (!copy) return -1;
    int fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) { free(copy); return -1; }
    char *part = copy + 1;
    for (;;) {
        char *slash = strchr(part, '/');
        if (slash) *slash = 0;
        if (!*part || !strcmp(part, ".") || !strcmp(part, "..")) {
            close(fd); free(copy); errno = EINVAL; return -1;
        }
        if (!slash) { *storage = copy; *name = part; return fd; }
        int next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        close(fd);
        if (next < 0) { free(copy); return -1; }
        fd = next; part = slash + 1;
    }
}

/* Give an owned directory back its owner rwx through an O_PATH handle, so a
 * hostile 0000 mode cannot pin it and a swapped-in symlink is never followed. */
static int sk_repair_child(int dir, const char *name, const struct stat *st) {
    if (!S_ISDIR(st->st_mode) || st->st_uid != getuid() || (st->st_mode & 0700) == 0700) {
        errno = EACCES; return -1;
    }
    int handle = openat(dir, name, O_PATH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (handle < 0) return -1;
    struct stat opened;
    int result = -1;
    if (fstat(handle, &opened)) {
        /* errno set */
    } else if (opened.st_dev != st->st_dev || opened.st_ino != st->st_ino) {
        errno = ESTALE;
    } else {
        char proc[64];
        snprintf(proc, sizeof(proc), "/proc/self/fd/%d", handle);
        result = chmod(proc, 0700);
    }
    int saved = errno;
    close(handle);
    errno = saved;
    return result;
}

static int sk_open_child(int dir, const char *name, const struct stat *st) {
    int child = openat(dir, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (child >= 0 || errno != EACCES) return child;
    if (sk_repair_child(dir, name, st)) return -1;
    return openat(dir, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
}

/* The tree is quiescent before this runs; foreign filesystems stay untouched. */
static int sk_empty(int fd, dev_t device) {
    struct stat self;
    if (fstat(fd, &self)) return -1;
    /* Unlinking entries needs owner wx here; repair an owned dir in place. */
    if (self.st_uid == getuid() && (self.st_mode & 0700) != 0700 && fchmod(fd, 0700)) return -1;
    int scan = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (scan < 0) return -1;
    DIR *dir = fdopendir(scan);
    if (!dir) { close(scan); return -1; }
    int result = 0;
    for (;;) {
        errno = 0;
        struct dirent *entry = readdir(dir);
        if (!entry) { if (errno) result = -1; break; }
        const char *name = entry->d_name;
        if (!strcmp(name, ".") || !strcmp(name, "..")) continue;
        struct stat st;
        if (fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW)) { result = -1; break; }
        if (S_ISDIR(st.st_mode)) {
            int child = sk_open_child(fd, name, &st);
            if (child < 0) { result = -1; break; }
            struct stat opened;
            if (fstat(child, &opened) || opened.st_dev != device ||
                opened.st_dev != st.st_dev || opened.st_ino != st.st_ino) {
                close(child); errno = EXDEV; result = -1; break;
            }
            result = sk_empty(child, device);
            int saved = errno;
            if (close(child) && !result) { result = -1; saved = errno; }
            errno = saved;
            if (result || unlinkat(fd, name, AT_REMOVEDIR)) { result = -1; break; }
        } else if (unlinkat(fd, name, 0)) { result = -1; break; }
    }
    int saved = errno;
    if (closedir(dir) && !result) { result = -1; saved = errno; }
    errno = saved;
    return result;
}

static int sk_remove(int parent, const char *name, int root, const struct stat *owned) {
    struct stat current;
    if (fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW)) return -1;
    if (!S_ISDIR(current.st_mode) || current.st_dev != owned->st_dev || current.st_ino != owned->st_ino) {
        errno = ESTALE; return -1;
    }
    if (sk_empty(root, owned->st_dev)) return -1;
    return unlinkat(parent, name, AT_REMOVEDIR);
}

/* Whether a stop request (signal or lifetime EOF) is pending, without consuming it. */
static int sk_stop_pending(int sigfd, int lifetime_fd) {
    struct pollfd fds[2] = {{sigfd, POLLIN, 0}, {lifetime_fd, POLLIN, 0}};
    return poll(fds, lifetime_fd >= 0 ? 2 : 1, 0) > 0;
}

/* Bounded retries; a pending stop ends the pre-fork variant early. */
static int sk_remove_bounded(int parent, const char *name, int root, const struct stat *owned,
                             const char *label, int sigfd, int lifetime_fd) {
    for (unsigned attempt = 1;; ++attempt) {
        if (!sk_remove(parent, name, root, owned)) return 0;
        int err = errno;
        if (attempt == 1 || attempt % 10 == 0)
            dprintf(2, "sketerm-web: private root cleanup attempt %u/%d failed (%s): %s\n",
                    attempt, SK_DELETE_ATTEMPTS, label, strerror(err));
        if (attempt >= SK_DELETE_ATTEMPTS) { errno = err; return -1; }
        if (sigfd >= 0 && sk_stop_pending(sigfd, lifetime_fd)) { errno = err; return -1; }
        (void)poll(NULL, 0, SK_DELETE_RETRY_MS);
    }
}

/* Direct children cannot reuse their PIDs until THIS process reaps them. */
static int sk_kill_task_children(void) {
    char path[80];
    int n = snprintf(path, sizeof(path), "/proc/self/task/%ld/children", (long)getpid());
    if (n < 0 || (size_t)n >= sizeof(path)) { errno = EOVERFLOW; return -1; }
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    FILE *file = fdopen(fd, "r");
    if (!file) { close(fd); return -1; }
    long pid;
    int result = 0, parsed;
    while ((parsed = fscanf(file, "%ld", &pid)) == 1) {
        if (pid <= 0 || pid > INT_MAX) { errno = EINVAL; result = -1; break; }
        if (kill((pid_t)pid, SIGKILL) && errno != ESRCH) { result = -1; break; }
    }
    if (!result && (ferror(file) || parsed != EOF)) { errno = EIO; result = -1; }
    int saved = errno;
    if (fclose(file) && !result) { result = -1; saved = errno; }
    errno = saved;
    return result;
}

/* Without CONFIG_PROC_CHILDREN: a stat line naming us as parent is a live
 * child, and only we can reap it, so its pid cannot be recycled under us. */
static int sk_kill_scanned_children(void) {
    DIR *proc = opendir("/proc");
    if (!proc) return -1;
    long self = (long)getpid();
    int result = 0;
    for (;;) {
        errno = 0;
        struct dirent *entry = readdir(proc);
        if (!entry) { if (errno) result = -1; break; }
        char *end;
        long pid = strtol(entry->d_name, &end, 10);
        if (end == entry->d_name || *end || pid <= 0 || pid > INT_MAX) continue;
        char path[64];
        snprintf(path, sizeof(path), "/proc/%ld/stat", pid);
        int fd = open(path, O_RDONLY | O_CLOEXEC);
        if (fd < 0) continue;
        char line[512];
        ssize_t got = read(fd, line, sizeof(line) - 1);
        close(fd);
        if (got <= 0) continue;
        line[got] = 0;
        /* comm may hold spaces and parens; the fields resume after the last ')'. */
        char *tail = strrchr(line, ')');
        char state;
        long ppid;
        if (!tail || sscanf(tail + 1, " %c %ld", &state, &ppid) != 2 || ppid != self) continue;
        if (kill((pid_t)pid, SIGKILL) && errno != ESRCH) { result = -1; break; }
    }
    int saved = errno;
    closedir(proc);
    errno = saved;
    return result;
}

static int sk_kill_children(void) {
    if (!sk_force_scan && !sk_kill_task_children()) return 0;
    return sk_kill_scanned_children();
}

/* Either discovery path must work before a browser may be forked. */
static int sk_children_discoverable(void) {
    if (!sk_force_scan) {
        char path[80];
        snprintf(path, sizeof(path), "/proc/self/task/%ld/children", (long)getpid());
        if (!access(path, R_OK)) return 1;
    }
    DIR *proc = opendir("/proc");
    if (!proc) return 0;
    closedir(proc);
    return 1;
}

static int sk_root_name(const char *name) {
    if (strlen(name) != SK_ROOT_NAME_LEN) return 0;
    for (const char *p = name; *p; ++p)
        if (!((*p >= '0' && *p <= '9') || (*p >= 'a' && *p <= 'f'))) return 0;
    return 1;
}

/* Delete sibling roots whose supervisor died: an owner holds its root's flock
 * for its whole life, so a free lock on an aged root means nobody owns it. */
static void sk_sweep(int parent, const char *own, int sigfd, int lifetime_fd) {
    int scan = openat(parent, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (scan < 0) return;
    DIR *dir = fdopendir(scan);
    if (!dir) { close(scan); return; }
    struct stat parent_st;
    struct timespec now;
    if (fstat(parent, &parent_st) || clock_gettime(CLOCK_REALTIME, &now)) { closedir(dir); return; }
    for (;;) {
        if (sk_stop_pending(sigfd, lifetime_fd)) break;
        errno = 0;
        struct dirent *entry = readdir(dir);
        if (!entry) break;
        const char *name = entry->d_name;
        if (!sk_root_name(name) || !strcmp(name, own)) continue;
        struct stat st;
        if (fstatat(parent, name, &st, AT_SYMLINK_NOFOLLOW) || !S_ISDIR(st.st_mode) ||
            st.st_uid != getuid() || st.st_dev != parent_st.st_dev ||
            now.tv_sec - st.st_mtim.tv_sec < SK_SWEEP_MIN_AGE_SEC) continue;
        int root = sk_open_child(parent, name, &st);
        if (root < 0) continue;
        struct stat opened;
        if (!fstat(root, &opened) && opened.st_dev == st.st_dev && opened.st_ino == st.st_ino &&
            !flock(root, LOCK_EX | LOCK_NB)) {
            if (sk_remove(parent, name, root, &opened))
                dprintf(2, "sketerm-web: stale private root %s not swept: %s\n", name, strerror(errno));
        }
        close(root);
    }
    closedir(dir);
}

static void sk_restore_signals(const sigset_t *old) {
    struct sigaction sa = {0};
    sa.sa_handler = SIG_DFL;
    sigemptyset(&sa.sa_mask);
    (void)sigaction(SIGPIPE, &sa, NULL);
    (void)sigprocmask(SIG_SETMASK, old, NULL);
}

int sk_web_supervise(const char *private_root, int lifetime_fd) {
    struct rlimit limit;
    struct stat owned, pipe_stat, parent_st, linked;
    char *storage = NULL;
    const char *name = NULL;
    int parent = -1, root = -1, sigfd = -1;
    /* RLIMIT_CORE belongs to the caller (sk_web_untrusted_core_limit) and is
     * inherited by every descendant; this only refuses if it was not set. */
    if (getuid() != geteuid() || getgid() != getegid() ||
        getrlimit(RLIMIT_CORE, &limit) || limit.rlim_cur || limit.rlim_max ||
        prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) ||
        (lifetime_fd >= 0 && (fstat(lifetime_fd, &pipe_stat) || !S_ISFIFO(pipe_stat.st_mode))) ||
        !sk_children_discoverable()) return 0;
    if (strlen(private_root) + 2 > SK_WEB_SUPERVISOR_TMPDIR_MAX) {
        dprintf(2, "sketerm-web: private root %s is too long: its TMPDIR would exceed %d bytes and Chromium's singleton socket would not fit a unix socket path\n",
                private_root, SK_WEB_SUPERVISOR_TMPDIR_MAX);
        return 0;
    }
    parent = sk_parent(private_root, &storage, &name);
    if (parent < 0) return 0;
    if (fstat(parent, &parent_st) || parent_st.st_uid != getuid() || (parent_st.st_mode & 077)) {
        dprintf(2, "sketerm-web: private root parent must be owned by this user and mode 0700\n");
        close(parent); free(storage);
        return 0;
    }
    sigset_t mask, old;
    sigemptyset(&mask);
    sigaddset(&mask, SIGCHLD);
    sigaddset(&mask, SIGTERM);
    sigaddset(&mask, SIGINT);
    sigaddset(&mask, SIGHUP);
    if (sigprocmask(SIG_SETMASK, &mask, &old)) { close(parent); free(storage); return 0; }
    struct sigaction sa = {0};
    sigemptyset(&sa.sa_mask);
    /* SIG_IGN on SIGCHLD would auto-reap and starve the signalfd. */
    sa.sa_handler = SIG_DFL;
    if (sigaction(SIGCHLD, &sa, NULL)) goto bad;
    sa.sa_handler = SIG_IGN;
    if (sigaction(SIGPIPE, &sa, NULL)) goto bad;
    sigfd = signalfd(-1, &mask, SFD_CLOEXEC | SFD_NONBLOCK);
    if (sigfd < 0) goto bad;
    pid_t owner = getppid();
    if (prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) || prctl(PR_SET_PDEATHSIG, SIGTERM, 0, 0, 0)) goto bad;
    int stop = getppid() != owner || owner == 1;
    umask(077);
    if (mkdirat(parent, name, 0700)) goto bad;
    root = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (root < 0 || fstat(root, &owned) || owned.st_uid != getuid() || (owned.st_mode & 07777) != 0700) {
        /* No browser has been forked, so only an empty directory can exist. */
        for (unsigned attempt = 1; unlinkat(parent, name, AT_REMOVEDIR); ++attempt) {
            dprintf(2, "sketerm-web: empty private root cleanup failed: %s\n", strerror(errno));
            if (attempt >= SK_DELETE_ATTEMPTS || sk_stop_pending(sigfd, lifetime_fd)) break;
            (void)poll(NULL, 0, SK_DELETE_RETRY_MS);
        }
        goto bad;
    }
    /* The lock marks the root as owned for the sweep of a later supervisor;
     * a sweep that won the race between mkdir and here unlinked the name. */
    if (flock(root, LOCK_EX | LOCK_NB) ||
        fstatat(parent, name, &linked, AT_SYMLINK_NOFOLLOW) ||
        linked.st_dev != owned.st_dev || linked.st_ino != owned.st_ino) {
        dprintf(2, "sketerm-web: private root ownership could not be established\n");
        goto bad_root;
    }
    for (size_t i = 0; i < sizeof(sk_private_env) / sizeof(sk_private_env[0]); ++i) {
        if (mkdirat(root, sk_private_env[i][1], 0700)) {
            dprintf(2, "sketerm-web: private root layout failed: %s\n", strerror(errno));
            goto bad_root;
        }
    }
    pid_t supervisor = getpid();
    pid_t browser = stop ? -1 : fork();
    if (!browser) {
        close(parent); close(root); close(sigfd);
        if (lifetime_fd >= 0) close(lifetime_fd);
        sigset_t none;
        sigemptyset(&none);
        sa.sa_handler = SIG_DFL;
        if (setsid() < 0 || sigaction(SIGPIPE, &sa, NULL) || sigprocmask(SIG_SETMASK, &none, NULL) ||
            prctl(PR_SET_PDEATHSIG, SIGKILL, 0, 0, 0) || getppid() != supervisor ||
            setenv("SKETERM_WEB_SUPERVISED", "1", 1)) _exit(1);
        for (size_t i = 0; i < sizeof(sk_private_env) / sizeof(sk_private_env[0]); ++i) {
            char value[PATH_MAX];
            int n = snprintf(value, sizeof(value), "%s/%s", private_root, sk_private_env[i][1]);
            if (n < 0 || (size_t)n >= sizeof(value) || setenv(sk_private_env[i][0], value, 1)) _exit(1);
        }
        free(storage);
        return 1;
    }
    if (browser < 0) stop = 1;
    /* Only the supervisor: the browser must stay dumpable until its namespace
     * sandbox has written uid_map, and clears the flag itself afterwards. */
    if (prctl(PR_SET_DUMPABLE, 0, 0, 0, 0)) stop = 1;
    (void)prctl(PR_SET_NAME, "sk-web-cleanup", 0, 0, 0);
    if (!stop) sk_sweep(parent, name, sigfd, lifetime_fd);
    int browser_status = 1 << 8;
    unsigned failures = 0;
    for (;;) {
        int status;
        pid_t child;
        while ((child = waitpid(-1, &status, WNOHANG)) > 0) {
            if (child == browser) { browser_status = status; stop = 1; }
        }
        if (child < 0 && errno == ECHILD) break;
        if (stop && sk_kill_children() && failures++ % 50 == 0)
            dprintf(2, "sketerm-web: descendant retirement pending: %s\n", strerror(errno));
        struct pollfd fds[2] = {{sigfd, POLLIN, 0}, {lifetime_fd, POLLIN, 0}};
        int ready = poll(fds, lifetime_fd >= 0 ? 2 : 1, stop ? SK_RETIRE_RETRY_MS : -1);
        if (ready < 0) {
            if (errno != EINTR) { stop = 1; (void)nanosleep(&(struct timespec){0, SK_RETIRE_RETRY_MS * 1000000L}, NULL); }
            continue;
        }
        if (fds[0].revents) {
            struct signalfd_siginfo info;
            while (read(sigfd, &info, sizeof(info)) == (ssize_t)sizeof(info))
                if (info.ssi_signo != SIGCHLD) stop = 1;
        }
        if (lifetime_fd >= 0 && fds[1].revents) {
            /* The pipe is a one-way lifetime fence, never an input channel. */
            stop = 1; close(lifetime_fd); lifetime_fd = -1;
        }
    }
    /* ECHILD under our subreaper is the only permission to delete the root. */
    int cleaned = !sk_remove_bounded(parent, name, root, &owned, private_root, -1, -1);
    if (!cleaned)
        dprintf(2, "sketerm-web: gave up deleting private root %s after %d attempts\n", private_root, SK_DELETE_ATTEMPTS);
    close(root); close(parent); close(sigfd); free(storage);
    if (lifetime_fd >= 0) close(lifetime_fd);
    if (!cleaned) _exit(SK_WEB_SUPERVISOR_CLEANUP_FAILED);
    _exit(WIFEXITED(browser_status) ? WEXITSTATUS(browser_status) : 128 + WTERMSIG(browser_status));
bad_root:
    /* No browser exists yet, so the root holds only what we just made. */
    (void)sk_remove_bounded(parent, name, root, &owned, private_root, sigfd, lifetime_fd);
bad:
    if (root >= 0) close(root);
    if (sigfd >= 0) close(sigfd);
    close(parent); free(storage);
    (void)prctl(PR_SET_CHILD_SUBREAPER, 0, 0, 0, 0);
    sk_restore_signals(&old);
    return 0;
}
#else
int sk_web_supervise(const char *private_root, int lifetime_fd) {
    (void)private_root; (void)lifetime_fd; return 0;
}
void sk_web_supervisor_force_proc_scan(int on) { (void)on; }
#endif
