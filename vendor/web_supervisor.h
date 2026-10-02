#ifndef SKETERM_WEB_SUPERVISOR_H
#define SKETERM_WEB_SUPERVISOR_H

/* Exit status of a supervisor that gave up deleting its private root. It is
 * above every 128+signal status and never returned by the helper itself. */
#define SK_WEB_SUPERVISOR_CLEANUP_FAILED 251

/* Longest TMPDIR (<root>/t) the browser may get: Chromium binds
 * $TMPDIR/org.chromium.Chromium.XXXXXX/SingletonSocket, ~46 more bytes,
 * and sockaddr_un caps at 108. A longer root is refused up front. */
#define SK_WEB_SUPERVISOR_TMPDIR_MAX 60

/* Creates the private root; returns 1 only in the browser child.
 * The caller must already have set RLIMIT_CORE=0 (refused otherwise). The
 * supervisor makes itself nondumpable after the fork; the browser child's
 * dumpable flag is left untouched for Chromium's namespace sandbox. */
int sk_web_supervise(const char *private_root, int lifetime_fd);

/* Test seam: nonzero forces descendant discovery through a /proc/<pid>/stat
 * scan, the path taken on kernels without CONFIG_PROC_CHILDREN. */
void sk_web_supervisor_force_proc_scan(int on);

#endif
