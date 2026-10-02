#define _GNU_SOURCE
#include "../vendor/web_supervisor.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

/* cc -std=c11 -O2 -Wall -Wextra -Werror dist/test-web-supervisor.c
 *    vendor/web_supervisor.c -o "${TMPDIR:-/tmp}/test-web-supervisor" */

struct tree { pid_t supervisor, browser, broker, writer; };

static const char *const private_env[][2] = {
    {"HOME", "h"}, {"TMPDIR", "t"}, {"XDG_CONFIG_HOME", "c"}, {"XDG_CACHE_HOME", "k"},
    {"XDG_DATA_HOME", "d"}, {"XDG_STATE_HOME", "s"}, {"XDG_RUNTIME_DIR", "r"},
};

/* What sk_web_untrusted_core_limit does in the helper before supervising. */
static void limit_core(void) {
    struct rlimit limit = {0, 0};
    assert(!setrlimit(RLIMIT_CORE, &limit));
}

/* The browser side inherits the core limit but stays dumpable, so Chromium's
 * namespace sandbox can still write its uid_map. */
static void no_core(void) {
    struct rlimit limit;
    assert(!getrlimit(RLIMIT_CORE, &limit));
    assert(!limit.rlim_cur && !limit.rlim_max);
    assert(prctl(PR_GET_DUMPABLE, 0, 0, 0, 0) == 1);
    assert(prctl(PR_GET_NO_NEW_PRIVS, 0, 0, 0, 0) == 1);
}

/* A nondumpable process's /proc/<pid>/status is owned by root (the
 * directory itself is not). The supervisor clears the flag right after its
 * fork, racing the browser's first report. */
static void nondumpable(pid_t pid) {
    char proc[64];
    snprintf(proc, sizeof(proc), "/proc/%ld/status", (long)pid);
    for (int tries = 0; tries < 200; ++tries) {
        struct stat st;
        assert(!stat(proc, &st));
        if (st.st_uid == 0) return;
        (void)poll(NULL, 0, 10);
    }
    assert(!"supervisor stayed dumpable");
}

static void read_exact(int fd, void *data, size_t size) {
    struct pollfd p = {fd, POLLIN, 0};
    assert(poll(&p, 1, 5000) > 0);
    assert(read(fd, data, size) == (ssize_t)size);
}

static int wait_exact(pid_t pid) {
    struct timespec start, now;
    assert(!clock_gettime(CLOCK_MONOTONIC, &start));
    for (;;) {
        int status = 0;
        pid_t result = waitpid(pid, &status, WNOHANG);
        if (result == pid) return status;
        assert(result == 0 || (result < 0 && errno == EINTR));
        assert(!clock_gettime(CLOCK_MONOTONIC, &now));
        assert(now.tv_sec - start.tv_sec < 8);
        (void)poll(NULL, 0, 10);
    }
}

static void path(char *buf, size_t size, const char *base, const char *name) {
    int n = snprintf(buf, size, "%s/%s", base, name);
    assert(n > 0 && (size_t)n < size);
}

static void touch(const char *dir, const char *name) {
    char file[1024];
    path(file, sizeof(file), dir, name);
    int fd = open(file, O_CREAT | O_WRONLY | O_EXCL | O_CLOEXEC, 0600);
    assert(fd >= 0);
    close(fd);
}

/* Directories whose own modes forbid deleting their contents. */
static void hostile_modes(const char *parent) {
    char locked[1024], readonly[1024];
    path(locked, sizeof(locked), parent, "locked"); assert(!mkdir(locked, 0700));
    touch(locked, "file");
    assert(!chmod(locked, 0));
    path(readonly, sizeof(readonly), parent, "readonly"); assert(!mkdir(readonly, 0700));
    touch(readonly, "file");
    assert(!chmod(readonly, 0500));
}

static void browser(const char *root, int report, int command, int delayed) {
    no_core();
    assert(getenv("SKETERM_WEB_SUPERVISED"));
    assert(getsid(0) == getpid() && getpgrp() == getpid());
    for (size_t i = 0; i < sizeof(private_env) / sizeof(private_env[0]); ++i) {
        char want[1024];
        path(want, sizeof(want), root, private_env[i][1]);
        const char *got = getenv(private_env[i][0]);
        assert(got && !strcmp(got, want));
        struct stat st;
        assert(!lstat(want, &st) && S_ISDIR(st.st_mode) && (st.st_mode & 07777) == 0700);
    }
    char cache[512], link[512], outside[512];
    path(cache, sizeof(cache), root, "cache-test"); assert(!mkdir(cache, 0700));
    path(link, sizeof(link), cache, "symlink");
    int n = snprintf(outside, sizeof(outside), "%s/../outside", root);
    assert(n > 0 && (size_t)n < sizeof(outside));
    assert(!symlink(outside, link));
    hostile_modes(cache);
    int ready[2];
    assert(!pipe2(ready, O_CLOEXEC));
    pid_t broker = fork();
    assert(broker >= 0);
    if (!broker) {
        no_core();
        close(ready[0]);
        assert(!setpgid(0, 0));
        assert(signal(SIGTERM, SIG_IGN) != SIG_ERR);
        pid_t middle = fork();
        assert(middle >= 0);
        if (!middle) {
            pid_t writer = fork();
            assert(writer >= 0);
            if (writer) _exit(0);
            no_core();
            assert(setsid() > 0);
            pid_t me = getpid();
            assert(write(ready[1], &me, sizeof(me)) == sizeof(me));
            close(ready[1]);
            char byte;
            if (read(delayed, &byte, 1) == 1) {
                (void)poll(NULL, 0, 200);
                /* A leaked writer recreates the root after an early delete. */
                (void)mkdir(root, 0700);
                char late[512]; path(late, sizeof(late), root, "late-write");
                int fd = open(late, O_WRONLY | O_CREAT, 0600);
                if (fd >= 0) { (void)write(fd, "late", 4); close(fd); }
            }
            for (;;) pause();
        }
        assert(WIFEXITED(wait_exact(middle)));
        for (;;) pause();
    }
    close(ready[1]);
    struct tree tree = {getppid(), getpid(), broker, 0};
    read_exact(ready[0], &tree.writer, sizeof(tree.writer));
    close(ready[0]);
    assert(write(report, &tree, sizeof(tree)) == sizeof(tree));
    close(report);
    char byte;
    read_exact(command, &byte, 1);
    assert(byte == 'q');
    _exit(0);
}

static void retired(struct tree tree, const char *root, int root_left) {
    assert(kill(tree.browser, 0) < 0 && errno == ESRCH);
    assert(kill(tree.broker, 0) < 0 && errno == ESRCH);
    assert(kill(tree.writer, 0) < 0 && errno == ESRCH);
    struct stat st;
    if (root_left) {
        assert(!lstat(root, &st) && S_ISDIR(st.st_mode));
        return;
    }
    assert(lstat(root, &st) < 0 && errno == ENOENT);
    (void)poll(NULL, 0, 250);
    assert(lstat(root, &st) < 0 && errno == ENOENT);
}

enum cause { CLOSE, KILL_BROWSER, ABORT_BROWSER, PIPE_EOF, TERM_OWNER, PARENT_DEATH, DELETE_RETRY, DELETE_GIVE_UP };

struct options {
    enum cause cause;
    int lifetime;  /* pass a lifetime fence fd to the supervisor */
    int scan;      /* force the /proc/<pid>/stat discovery path */
    int sweep;     /* plant stale, live, young and foreign siblings */
};

/* $TMPDIR unless it is too long for the private TMPDIR limit, then /tmp. */
static const char *temp_base(void) {
    const char *tmp = getenv("TMPDIR");
    return tmp && *tmp && strlen(tmp) + sizeof("/sk-supervisor-XXXXXX/private/t") <= SK_WEB_SUPERVISOR_TMPDIR_MAX ? tmp : "/tmp";
}

static void make_base(char *base, size_t size) {
    int n = snprintf(base, size, "%s/sk-supervisor-XXXXXX", temp_base());
    assert(n > 0 && (size_t)n < size);
    assert(mkdtemp(base));
}

static void sibling(char *out, size_t size, const char *base, char fill) {
    char name[17];
    memset(name, fill, 16); name[16] = 0;
    path(out, size, base, name);
}

static void age(const char *dir) {
    struct timespec old[2] = {{1000000000, 0}, {1000000000, 0}};
    assert(!utimensat(AT_FDCWD, dir, old, AT_SYMLINK_NOFOLLOW));
}

static void supervise_child(const struct options *o, const char *root, int lifetime_read, int report, int command, int delayed) {
    limit_core();
    if (o->scan) sk_web_supervisor_force_proc_scan(1);
    assert(sk_web_supervise(root, o->lifetime ? lifetime_read : -1));
    browser(root, report, command, delayed);
}

static void scenario(struct options o) {
    char base[512];
    make_base(base, sizeof(base));
    char root[512], outside[512], sentinel[512];
    path(root, sizeof(root), base, "private");
    path(outside, sizeof(outside), base, "outside"); assert(!mkdir(outside, 0700));
    path(sentinel, sizeof(sentinel), outside, "sentinel");
    touch(outside, "sentinel");
    char stale[512], live[512], young[512], foreign[512];
    int live_lock = -1;
    if (o.sweep) {
        sibling(stale, sizeof(stale), base, 'a'); assert(!mkdir(stale, 0700));
        char nested[600]; path(nested, sizeof(nested), stale, "nested"); assert(!mkdir(nested, 0700));
        touch(nested, "file");
        hostile_modes(stale);
        age(stale);
        sibling(live, sizeof(live), base, 'b'); assert(!mkdir(live, 0700));
        touch(live, "file");
        age(live);
        live_lock = open(live, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
        assert(live_lock >= 0 && !flock(live_lock, LOCK_EX | LOCK_NB));
        sibling(young, sizeof(young), base, 'c'); assert(!mkdir(young, 0700));
        path(foreign, sizeof(foreign), base, "keep-me"); assert(!mkdir(foreign, 0700));
        age(foreign);
    }
    int report[2], command[2], delayed[2], lifetime[2];
    assert(!pipe2(report, O_CLOEXEC) && !pipe2(command, O_CLOEXEC) &&
           !pipe2(delayed, O_CLOEXEC) && !pipe2(lifetime, O_CLOEXEC));
    pid_t unrelated = fork(); assert(unrelated >= 0);
    if (!unrelated) {
        close(lifetime[0]); close(lifetime[1]);
        for (;;) pause();
    }
    pid_t launcher = -1, supervisor;
    if (o.cause == PARENT_DEATH) {
        int started[2]; assert(!pipe2(started, O_CLOEXEC));
        launcher = fork(); assert(launcher >= 0);
        if (!launcher) {
            close(started[0]);
            supervisor = fork(); assert(supervisor >= 0);
            if (!supervisor) {
                close(lifetime[1]); close(started[1]);
                supervise_child(&o, root, lifetime[0], report[1], command[0], delayed[0]);
            }
            assert(write(started[1], &supervisor, sizeof(supervisor)) == sizeof(supervisor));
            close(started[1]);
            for (;;) pause();
        }
        close(started[1]);
        read_exact(started[0], &supervisor, sizeof(supervisor)); close(started[0]);
    } else {
        supervisor = fork(); assert(supervisor >= 0);
        if (!supervisor) {
            close(lifetime[1]);
            supervise_child(&o, root, lifetime[0], report[1], command[0], delayed[0]);
        }
    }
    close(lifetime[0]); close(report[1]); close(command[0]); close(delayed[0]);
    if (o.cause == PARENT_DEATH) { close(lifetime[1]); lifetime[1] = -1; }
    struct tree tree;
    read_exact(report[0], &tree, sizeof(tree)); close(report[0]);
    assert(tree.supervisor == supervisor);
    nondumpable(supervisor);
    assert(kill(tree.browser, 0) == 0 && kill(tree.broker, 0) == 0 && kill(tree.writer, 0) == 0);
    if (o.cause == DELETE_RETRY || o.cause == DELETE_GIVE_UP) assert(!chmod(base, 0500));
    assert(write(delayed[1], "w", 1) == 1); close(delayed[1]);
    switch (o.cause) {
    case CLOSE: case DELETE_RETRY: case DELETE_GIVE_UP: assert(write(command[1], "q", 1) == 1); break;
    case KILL_BROWSER: assert(!kill(tree.browser, SIGKILL)); break;
    case ABORT_BROWSER: assert(!kill(tree.browser, SIGABRT)); break;
    case PIPE_EOF: close(lifetime[1]); lifetime[1] = -1; break;
    case TERM_OWNER: assert(!kill(supervisor, SIGTERM)); break;
    case PARENT_DEATH: assert(!kill(launcher, SIGKILL)); assert(WIFSIGNALED(wait_exact(launcher))); break;
    }
    close(command[1]);
    if (o.cause == DELETE_RETRY) {
        (void)poll(NULL, 0, 300);
        assert(!kill(supervisor, 0));
        struct stat st; assert(!lstat(root, &st));
        int status; assert(waitpid(supervisor, &status, WNOHANG) == 0);
        assert(!chmod(base, 0700));
    }
    int status = wait_exact(supervisor);
    assert(WIFEXITED(status));
    if (o.cause == CLOSE || o.cause == DELETE_RETRY) assert(WEXITSTATUS(status) == 0);
    if (o.cause == KILL_BROWSER) assert(WEXITSTATUS(status) == 128 + SIGKILL);
    if (o.cause == ABORT_BROWSER) assert(WEXITSTATUS(status) == 128 + SIGABRT);
    if (o.cause == DELETE_GIVE_UP) assert(WEXITSTATUS(status) == SK_WEB_SUPERVISOR_CLEANUP_FAILED);
    if (lifetime[1] >= 0) close(lifetime[1]);
    retired(tree, root, o.cause == DELETE_GIVE_UP);
    if (o.cause == DELETE_GIVE_UP) {
        /* Everything the root held was removed; only its own name was pinned. */
        assert(!chmod(base, 0700));
        assert(!rmdir(root));
    }
    assert(!kill(unrelated, 0));
    assert(!kill(unrelated, SIGKILL)); assert(WIFSIGNALED(wait_exact(unrelated)));
    struct stat st; assert(!lstat(sentinel, &st));
    if (o.sweep) {
        assert(lstat(stale, &st) < 0 && errno == ENOENT);
        char file[700]; path(file, sizeof(file), live, "file");
        assert(!lstat(file, &st));
        assert(!lstat(young, &st) && !lstat(foreign, &st));
        assert(!unlink(file) && !rmdir(live) && !rmdir(young) && !rmdir(foreign));
        close(live_lock);
    }
    assert(!unlink(sentinel) && !rmdir(outside) && !rmdir(base));
}

/* A root whose TMPDIR cannot hold Chromium's singleton socket is refused. */
static void refuse_long_root(void) {
    char base[512], root[512];
    make_base(base, sizeof(base));
    char name[SK_WEB_SUPERVISOR_TMPDIR_MAX + 1];
    memset(name, 'x', sizeof(name) - 1); name[sizeof(name) - 1] = 0;
    path(root, sizeof(root), base, name);
    pid_t child = fork(); assert(child >= 0);
    if (!child) { limit_core(); _exit(sk_web_supervise(root, -1) == 0 ? 0 : 1); }
    int status = wait_exact(child);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    struct stat st;
    assert(lstat(root, &st) < 0 && errno == ENOENT);
    assert(!rmdir(base));
}

/* A refused supervisor must leave no root and fork nothing. */
static void refusal(int core_limited, mode_t parent_mode) {
    char base[512], root[512];
    make_base(base, sizeof(base));
    path(root, sizeof(root), base, "private");
    assert(!chmod(base, parent_mode));
    pid_t child = fork(); assert(child >= 0);
    if (!child) {
        if (core_limited) limit_core();
        _exit(sk_web_supervise(root, -1) == 0 ? 0 : 1);
    }
    int status = wait_exact(child);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    struct stat st;
    assert(lstat(root, &st) < 0 && errno == ENOENT);
    assert(!chmod(base, 0700) && !rmdir(base));
}

int main(void) {
    alarm(120);
    assert(!prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0));
    for (enum cause cause = CLOSE; cause <= DELETE_GIVE_UP; ++cause) {
        scenario((struct options){cause, 1, 0, 0});
        printf("PASS lifecycle cause %d (all descendants reaped, root handled, unrelated child and symlink target intact)\n", cause);
    }
    puts("PASS hostile 0000/0500 directories repaired and deleted; PASS bounded give-up exits 251");
    scenario((struct options){CLOSE, 0, 0, 0});
    scenario((struct options){TERM_OWNER, 0, 0, 0});
    puts("PASS no lifetime fence (lifetime_fd == -1): close and SIGTERM retire the tree");
    scenario((struct options){CLOSE, 1, 1, 0});
    scenario((struct options){KILL_BROWSER, 1, 1, 0});
    scenario((struct options){PIPE_EOF, 1, 1, 0});
    puts("PASS /proc/<pid>/stat discovery without the children file retires setpgid/setsid escapees");
    scenario((struct options){CLOSE, 1, 0, 1});
    puts("PASS stale unlocked sibling swept; locked, young and foreign siblings kept");
    refusal(0, 0700);
    puts("PASS refuses when the caller did not limit core dumps");
    refusal(1, 0755);
    puts("PASS refuses a parent directory other users can read or write");
    refuse_long_root();
    puts("PASS refuses a root whose TMPDIR would overflow Chromium's singleton socket path");
    for (unsigned i = 0; i < 12; ++i) scenario((struct options){CLOSE, 1, 0, 0});
    puts("PASS 12 repeated restarts; PASS inherited core limit, browser dumpable, supervisor nondumpable; PASS delayed descendant writes prevented");
    return 0;
}
