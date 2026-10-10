/* Restricted HTTP loader: only the pre-CEF broker owns Internet sockets;
 * unsupported Fetch semantics fail closed. No curl entry point is hard-linked. */
#define _GNU_SOURCE
#include "web_untrusted.h"

#if defined(__linux__) && ((defined(__x86_64__) && !defined(__ILP32__)) || \
                          (defined(__aarch64__) && !defined(__AARCH64EB__)))
#include <arpa/inet.h>
#include <ctype.h>
#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <limits.h>
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/netlink.h>
#include <linux/seccomp.h>
#include <netdb.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <curl/curl.h>

#if defined(__x86_64__) && !defined(__ILP32__)
#define SK_AUDIT_ARCH AUDIT_ARCH_X86_64
#elif defined(__aarch64__)
#define SK_AUDIT_ARCH AUDIT_ARCH_AARCH64
#endif

#define SK_URL_CAP ((unsigned)SK_WEB_UNTRUSTED_URL_CAP)
#define SK_HEADER_CAP ((unsigned)SK_WEB_UNTRUSTED_HEADER_CAP)
#define SK_HEADER_FIELDS ((unsigned)SK_WEB_UNTRUSTED_HEADER_FIELDS)
#define SK_UPLOAD_CAP ((unsigned)SK_WEB_UNTRUSTED_UPLOAD_CAP)
#define SK_BODY_CAP ((unsigned)SK_WEB_UNTRUSTED_BODY_CAP)
#define SK_JOBS ((unsigned)SK_WEB_UNTRUSTED_MAX_JOBS)
#define SK_QUEUE_CAP ((unsigned)SK_WEB_UNTRUSTED_QUEUE_CAP)
#define SK_TIMEOUT_MS ((int64_t)SK_WEB_UNTRUSTED_TIMEOUT_MS)
/* alarm() backstop in whole seconds, rounded up so it never fires before the
 * millisecond deadline that should have produced a TIMEOUT reply first. */
#define SK_TIMEOUT_S ((unsigned)((SK_WEB_UNTRUSTED_TIMEOUT_MS + 999) / 1000))
/* One unreachable address candidate must leave budget for the next family. */
#define SK_CONNECT_TIMEOUT_MS 5000L
/* curl gives up this long before the deadline so its TIMEOUT reply can still
 * be sent and read before the loader's own deadline closes the connection. */
#define SK_REPLY_MARGIN_MS 500
/* SIGCHLD stays default, so self-exited jobs are reaped by polling this often. */
#define SK_REAP_POLL_MS 100
/* After SIGTERM the broker gets this long to kill and reap its jobs before the
 * whole process group is SIGKILLed. */
#define SK_STOP_GRACE_MS 2000
#define SK_MAGIC 0x534b5531u

/* Local, same-binary protocol: lengths are checked before allocation or IO. */
struct sk_wire_request {
    uint32_t magic, url_len, method_len, headers_len, body_len, allow_private;
    uint32_t initiator_len, navigation, resource_type;
    /* Milliseconds left of the loader's deadline when the request was sent. */
    uint32_t budget_ms, user_activation, fetch_initiator_len;
};
struct sk_wire_response { uint32_t magic, reason, status, headers_len, body_len; };
struct sk_request {
    char *url, *method, *headers, *initiator, *fetch_initiator;
    unsigned char *body;
    size_t body_len;
    int allow_private, navigation, resource_type, user_activation;
};
struct sk_origin { char host[256]; unsigned port; int tls; };
/* The route's proxy as one job resolved it: the ONLY address its curl may
 * connect to, and the numeric url curl is handed, so curl resolves nothing. */
struct sk_proxy_target {
    struct sockaddr_storage address;
    char url[sizeof("socks5h://[]:65535") + INET6_ADDRSTRLEN];
};
struct sk_response {
    int reason, status, port, allow_private, cross_static;
    /* Non-NULL on a routed broker: connect-time allowance is exactly this. */
    const struct sk_proxy_target *proxy;
    char *headers;
    unsigned char *body;
    size_t headers_len, header_total, body_len, body_capacity;
};
struct psl_ctx_st;
struct sk_curl {
    void *handle;
    const struct psl_ctx_st *(*psl_builtin)(void);
    const char *(*psl_registrable_domain)(const struct psl_ctx_st *, const char *);
    CURLcode (*global_init)(long);
    void (*global_cleanup)(void);
    curl_version_info_data *(*version_info)(CURLversion);
    CURL *(*easy_init)(void);
    void (*easy_cleanup)(CURL *);
    CURLcode (*easy_setopt)(CURL *, CURLoption, ...);
    CURLcode (*easy_perform)(CURL *);
    CURLcode (*easy_getinfo)(CURL *, CURLINFO, ...);
    struct curl_slist *(*slist_append)(struct curl_slist *, const char *);
    void (*slist_free_all)(struct curl_slist *);
};

static _Atomic pid_t sk_broker_pid;
static int sk_lifetime_fd = -1;
/* The route's proxy, fixed at start and inherited by the broker and every
 * job: host as sk_parse_url canonicalised it (an IPv6 literal unbracketed). */
static struct { int on, socks; char host[256]; unsigned port; } sk_proxy;
static char sk_socket_path[sizeof(((struct sockaddr_un *)0)->sun_path)];
static volatile sig_atomic_t sk_broker_stop;

static int64_t sk_now_ms(void) {
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC, &t)) return -1;
    return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

static int sk_io(int fd, void *data, size_t len, int writing, int64_t deadline) {
    unsigned char *p = data;
    while (len) {
        int64_t now = sk_now_ms();
        if (now < 0 || now >= deadline) return 0;
        struct pollfd f = {fd, writing ? POLLOUT : POLLIN, 0};
        int n = poll(&f, 1, (int)(deadline - now));
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0 || (f.revents & (POLLERR | POLLNVAL))) return 0;
        ssize_t count = writing ? send(fd, p, len, MSG_NOSIGNAL | MSG_DONTWAIT)
                                : recv(fd, p, len, MSG_DONTWAIT);
        if (count < 0 && (errno == EINTR || errno == EAGAIN)) continue;
        if (count <= 0) return 0;
        p += count;
        len -= (size_t)count;
    }
    return 1;
}

static int sk_curl_load(struct sk_curl *a) {
    memset(a, 0, sizeof(*a));
    a->handle = dlopen("libcurl.so.4", RTLD_NOW | RTLD_LOCAL);
    if (!a->handle) return 0;
#define SK_BIND(name) do { a->name = dlsym(a->handle, "curl_" #name); \
    if (!a->name) goto bad; } while (0)
    SK_BIND(global_init); SK_BIND(global_cleanup); SK_BIND(version_info);
    SK_BIND(easy_init); SK_BIND(easy_cleanup); SK_BIND(easy_setopt);
    SK_BIND(easy_perform); SK_BIND(easy_getinfo);
    SK_BIND(slist_append); SK_BIND(slist_free_all);
#undef SK_BIND
    /* Many curl builds already load libpsl; no additional hard dependency. */
    a->psl_builtin = dlsym(a->handle, "psl_builtin");
    a->psl_registrable_domain = dlsym(a->handle, "psl_registrable_domain");
    curl_version_info_data *v = a->version_info(CURLVERSION_FIRST);
    int http = 0, https = 0;
    if (!v || v->version_num < 0x075500 || !(v->features & CURL_VERSION_SSL) || !v->protocols)
        goto bad;
    for (const char *const *p = v->protocols; *p; ++p) {
        if (!strcmp(*p, "http")) http = 1;
        if (!strcmp(*p, "https")) https = 1;
    }
    if (http && https) return 1;
bad:
    dlclose(a->handle);
    memset(a, 0, sizeof(*a));
    return 0;
}

/* Landlock UAPI, spelled locally: the syscall numbers are shared by x86_64 and
 * aarch64, and libc headers lag the kernel's newer struct fields. */
#define SK_LL_CREATE 444
#define SK_LL_ADD_RULE 445
#define SK_LL_RESTRICT 446
#define SK_LL_VERSION 1u
#define SK_LL_RULE_NET_PORT 2
#define SK_LL_NET_BIND_TCP (1ull << 0)
#define SK_LL_NET_CONNECT_TCP (1ull << 1)
#define SK_LL_SCOPE_ABSTRACT_UNIX (1ull << 0)
#define SK_LL_SCOPE_SIGNAL (1ull << 1)
/* Every ABI-1 filesystem right except READ_FILE (bit 2) and READ_DIR (bit 3):
 * NSS modules, resolver config and CA stores live in distro-specific places. */
#define SK_LL_FS_ABI1 (((1ull << 13) - 1) & ~((1ull << 2) | (1ull << 3)))
#define SK_LL_FS_REFER (1ull << 13)
#define SK_LL_FS_TRUNCATE (1ull << 14)
#define SK_LL_FS_IOCTL_DEV (1ull << 15)
#define SK_DNS_PORT 53u
struct sk_ll_ruleset { uint64_t fs, net, scoped; };
struct sk_ll_port { uint64_t allowed, port; };

/* Set before the broker forks, so the broker and its jobs inherit the probe. */
static int sk_landlock_abi;

static int sk_landlock_probe(void) {
    long abi = syscall(SK_LL_CREATE, NULL, 0, SK_LL_VERSION);
    return abi > 0 && abi < INT_MAX ? (int)abi : 0;
}

/* Fails only when Landlock was probed available; the job must then refuse.
 * dns also admits TCP port 53, for a job that resolves the page host itself. */
static int sk_landlock_job(int abi, unsigned port, int dns) {
    if (!abi) return 1;
    struct sk_ll_ruleset attr = {SK_LL_FS_ABI1, 0, 0};
    if (abi >= 2) attr.fs |= SK_LL_FS_REFER;
    if (abi >= 3) attr.fs |= SK_LL_FS_TRUNCATE;
    if (abi >= 4) attr.net = SK_LL_NET_BIND_TCP | SK_LL_NET_CONNECT_TCP;
    if (abi >= 5) attr.fs |= SK_LL_FS_IOCTL_DEV;
    if (abi >= 6) attr.scoped = SK_LL_SCOPE_ABSTRACT_UNIX | SK_LL_SCOPE_SIGNAL;
    /* Older kernels accept the zeroed trailing fields but reject unknown bits. */
    long fd = syscall(SK_LL_CREATE, &attr, sizeof(attr), 0u);
    if (fd < 0) return 0;
    int ok = 1;
    if (abi >= 4) {
        /* glibc falls back to TCP for truncated DNS answers. */
        const unsigned ports[2] = {port, SK_DNS_PORT};
        for (unsigned i = 0; i < (dns ? 2u : 1u) && ok; ++i) {
            struct sk_ll_port rule = {SK_LL_NET_CONNECT_TCP, ports[i]};
            ok = syscall(SK_LL_ADD_RULE, (int)fd, SK_LL_RULE_NET_PORT, &rule, 0u) == 0;
        }
    }
    /* The broker already set no_new_privs, which restrict_self requires. */
    if (ok) ok = syscall(SK_LL_RESTRICT, (int)fd, 0u) == 0;
    close((int)fd);
    return ok;
}

int sk_web_untrusted_job_landlock(void) { return sk_broker_pid && sk_landlock_abi > 0; }

int sk_web_untrusted_core_limit(void) {
    struct rlimit r = {0, 0};
    return setrlimit(RLIMIT_CORE, &r) == 0;
}

int sk_web_untrusted_nondumpable(void) { return prctl(PR_SET_DUMPABLE, 0, 0, 0, 0) == 0; }

int sk_web_untrusted_no_core(void) {
    int limited = sk_web_untrusted_core_limit();
    int nondumpable = sk_web_untrusted_nondumpable();
    return limited && nondumpable;
}

int sk_web_untrusted_confine(void) {
#ifdef SK_AUDIT_ARCH
    /* Refuse inherited Internet sockets rather than pretending creation-only
     * seccomp revokes them. AF_UNIX descriptor passing is outside the JS model. */
    DIR *dir = opendir("/proc/self/fd");
    if (!dir) return 0;
    int clean = 1;
    struct dirent *entry;
    for (;;) {
        errno = 0;
        entry = readdir(dir);
        if (!entry) { if (errno) clean = 0; break; }
        char *end;
        long fd = strtol(entry->d_name, &end, 10);
        if (*end || fd < 0 || fd > INT_MAX) continue;
        struct sockaddr_storage address;
        socklen_t size = sizeof(address);
        int result = getsockname((int)fd, (struct sockaddr *)&address, &size);
        if (result) {
            if (errno != ENOTSOCK) clean = 0;
        } else if (address.ss_family != AF_UNIX) {
            int protocol = -1;
            socklen_t plen = sizeof(protocol);
            if (address.ss_family != AF_NETLINK ||
                getsockopt((int)fd, SOL_SOCKET, SO_PROTOCOL, &protocol, &plen) ||
                protocol != NETLINK_ROUTE) clean = 0;
        }
    }
    closedir(dir);
    /* Core limit only: a nondumpable process cannot write its own uid_map, which
     * Chromium's namespace sandbox needs after this call. */
    if (!clean || !sk_web_untrusted_core_limit() || prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)) return 0;
#define LD(off) BPF_STMT(BPF_LD | BPF_W | BPF_ABS, (off))
#define EQ(val, yes, no) BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, (val), (yes), (no))
#define RET(val) BPF_STMT(BPF_RET | BPF_K, (val))
    struct sock_filter code[] = {
        LD(offsetof(struct seccomp_data, arch)), EQ(SK_AUDIT_ARCH, 1, 0),
        RET(SECCOMP_RET_KILL_PROCESS), LD(offsetof(struct seccomp_data, nr)),
#if defined(__x86_64__)
        BPF_JUMP(BPF_JMP | BPF_JSET | BPF_K, 0x40000000u, 0, 1),
        RET(SECCOMP_RET_KILL_PROCESS),
#endif
        EQ(__NR_io_uring_setup, 0, 1), RET(SECCOMP_RET_ERRNO | EPERM),
        EQ(__NR_io_uring_enter, 0, 1), RET(SECCOMP_RET_ERRNO | EPERM),
        EQ(__NR_io_uring_register, 0, 1), RET(SECCOMP_RET_ERRNO | EPERM),
        EQ(__NR_socketpair, 0, 4), LD(offsetof(struct seccomp_data, args[0])),
        EQ(AF_UNIX, 0, 1), RET(SECCOMP_RET_ALLOW), RET(SECCOMP_RET_ERRNO | EPERM),
        EQ(__NR_socket, 0, 7), LD(offsetof(struct seccomp_data, args[0])),
        EQ(AF_UNIX, 4, 0), EQ(AF_NETLINK, 0, 2),
        LD(offsetof(struct seccomp_data, args[2])), EQ(NETLINK_ROUTE, 1, 0),
        RET(SECCOMP_RET_ERRNO | EPERM), RET(SECCOMP_RET_ALLOW),
        RET(SECCOMP_RET_ALLOW)
    };
#undef LD
#undef EQ
#undef RET
    struct sock_fprog program = {(unsigned short)(sizeof(code) / sizeof(code[0])), code};
    return syscall(SYS_seccomp, SECCOMP_SET_MODE_FILTER, SECCOMP_FILTER_FLAG_TSYNC, &program) == 0;
#else
    return 0;
#endif
}

static int sk_public_v4(const unsigned char *b) {
    /* Conservative exclusion of IANA special-purpose, multicast and reserved
     * space, including transition/benchmark/documentation networks. */
    if (!b[0] || b[0] == 10 || b[0] == 127 || b[0] >= 224 ||
        (b[0] == 100 && (b[1] & 0xc0) == 64) ||
        (b[0] == 169 && b[1] == 254) ||
        (b[0] == 172 && (b[1] & 0xf0) == 16) ||
        (b[0] == 192 && (b[1] == 168 || (b[1] == 0 && (b[2] == 0 || b[2] == 2)) ||
                        (b[1] == 88 && b[2] == 99))) ||
        (b[0] == 198 && (b[1] == 18 || b[1] == 19 || (b[1] == 51 && b[2] == 100))) ||
        (b[0] == 203 && b[1] == 0 && b[2] == 113)) return 0;
    return 1;
}

static int sk_public_address(const struct sockaddr *address) {
    if (address->sa_family == AF_INET)
        return sk_public_v4((const unsigned char *)&((const struct sockaddr_in *)address)->sin_addr);
    if (address->sa_family != AF_INET6) return 0;
    const unsigned char *b = ((const struct sockaddr_in6 *)address)->sin6_addr.s6_addr;
    static const unsigned char mapped[12] = {0,0,0,0,0,0,0,0,0,0,255,255};
    if (!memcmp(b, mapped, sizeof(mapped))) return sk_public_v4(b + 12);
    /* Only ordinary global unicast; deny Teredo, 6to4, ORCHID, documentation,
     * benchmarking and other 2001::/23 protocol assignments as a whole. */
    return (b[0] & 0xe0) == 0x20 &&
        !(b[0] == 0x20 && b[1] == 0x01 && b[2] < 2) &&
        !(b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8) &&
        !(b[0] == 0x20 && b[1] == 0x02) &&
        !(b[0] == 0x3f && b[1] == 0xff && (b[2] & 0xf0) == 0);
}

/* Normalizes to 16 bytes, IPv4 as v4-mapped, so a mapped candidate matches. */
static int sk_address_bytes(const struct sockaddr *address, unsigned char out[16]) {
    if (address->sa_family == AF_INET) {
        static const unsigned char mapped[12] = {0,0,0,0,0,0,0,0,0,0,255,255};
        memcpy(out, mapped, sizeof(mapped));
        memcpy(out + 12, &((const struct sockaddr_in *)address)->sin_addr, 4);
        return 1;
    }
    if (address->sa_family != AF_INET6) return 0;
    memcpy(out, ((const struct sockaddr_in6 *)address)->sin6_addr.s6_addr, 16);
    return 1;
}

/* A public address assigned to this host reaches its services like loopback. */
static int sk_own_address(const struct sockaddr *address, const struct ifaddrs *own) {
    unsigned char want[16], have[16];
    if (!sk_address_bytes(address, want)) return 1;
    for (const struct ifaddrs *i = own; i; i = i->ifa_next)
        if (i->ifa_addr && sk_address_bytes(i->ifa_addr, have) && !memcmp(want, have, 16)) return 1;
    return 0;
}

/* own is this host's interface list, queried by the caller per check. */
static int sk_address_allowed(const struct sockaddr *address, int allow_private, const struct ifaddrs *own) {
    return allow_private || (sk_public_address(address) && !sk_own_address(address, own));
}

static int sk_parse_url(const char *url, struct sk_origin *o, int origin_only) {
    const char *p;
    memset(o, 0, sizeof(*o));
    if (!strncmp(url, "https://", 8)) { o->tls = 1; p = url + 8; o->port = 443; }
    else if (!strncmp(url, "http://", 7)) { p = url + 7; o->port = 80; }
    else return 0;
    for (const unsigned char *c = (const unsigned char *)url; *c; ++c)
        if (*c <= 32 || *c >= 127 || *c == '\\') return 0;
    const char *end = p + strcspn(p, "/?#");
    const char *host_end = end, *port = NULL;
    if (p == end || memchr(p, '@', (size_t)(end - p))) return 0;
    if (*p == '[') {
        const char *bracket = memchr(p, ']', (size_t)(end - p));
        if (!bracket || (bracket + 1 != end && bracket[1] != ':')) return 0;
        host_end = bracket;
        ++p;
        if (bracket + 1 != end) port = bracket + 2;
        size_t n = (size_t)(host_end - p);
        if (!n || n >= sizeof(o->host)) return 0;
        char text[256]; memcpy(text, p, n); text[n] = 0;
        struct in6_addr binary;
        if (strchr(text, '%') || inet_pton(AF_INET6, text, &binary) != 1 ||
            !inet_ntop(AF_INET6, &binary, o->host, sizeof(o->host))) return 0;
    } else {
        const char *colon = memchr(p, ':', (size_t)(end - p));
        if (colon) { host_end = colon; port = colon + 1; }
        size_t n = (size_t)(host_end - p);
        if (!n || n >= sizeof(o->host)) return 0;
        /* One trailing dot is a distinct but valid absolute name, as in Chromium. */
        size_t name = p[n - 1] == '.' ? n - 1 : n;
        if (!name) return 0;
        size_t label = 0;
        for (size_t i = 0; i < name; ++i) {
            unsigned char c = (unsigned char)p[i];
            if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                  (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.')) return 0;
            if (c == '.') {
                if (!label || p[i - 1] == '-') return 0;
                label = 0;
            } else {
                if ((!label && c == '-') || ++label > 63) return 0;
            }
        }
        if (!label || p[name - 1] == '-') return 0;
        for (size_t i = 0; i < n; ++i) o->host[i] = (char)tolower((unsigned char)p[i]);
        /* WHATWG and curl both read a host whose last label is decimal or 0x-hex
         * as IPv4, parsing every label as an inet_aton-style number. Require the
         * canonical dotted quad, refusing 0x7f.0.0.1, 0177.0.0.1, 127.1 and
         * a.1 alike; the connect-time address check stays authoritative. */
        const char *last = memrchr(o->host, '.', name);
        last = last ? last + 1 : o->host;
        size_t last_len = (size_t)(o->host + name - last), digits = 0, hex = 0;
        while (digits < last_len && isdigit((unsigned char)last[digits])) ++digits;
        if (last_len >= 2 && last[0] == '0' && last[1] == 'x')
            for (hex = 2; hex < last_len && isxdigit((unsigned char)last[hex]); ++hex) {}
        if (digits == last_len || hex == last_len) {
            char quad[INET_ADDRSTRLEN], canonical[INET_ADDRSTRLEN];
            struct in_addr binary;
            if (name >= sizeof(quad)) return 0;
            memcpy(quad, o->host, name); quad[name] = 0;
            if (inet_pton(AF_INET, quad, &binary) != 1 ||
                !inet_ntop(AF_INET, &binary, canonical, sizeof(canonical)) ||
                strcmp(canonical, quad)) return 0;
        }
    }
    if (port) {
        if (port == end || *port == '0') return 0;
        unsigned value = 0;
        for (const char *c = port; c != end; ++c) {
            if (*c < '0' || *c > '9' || value > 6553) return 0;
            value = value * 10 + (unsigned)(*c - '0');
        }
        if (!value || value > 65535) return 0;
        o->port = value;
    }
    return !origin_only || !*end;
}

static int sk_same_origin(const struct sk_origin *a, const struct sk_origin *b) {
    return a->tls == b->tls && a->port == b->port && !strcmp(a->host, b->host);
}

static int sk_trustworthy(const struct sk_origin *o) {
    if (o->tls) return 1;
    size_t n = strlen(o->host);
    if (n && o->host[n - 1] == '.') --n;
    if ((n == 9 && !memcmp(o->host, "localhost", n)) ||
        (n > 10 && !memcmp(o->host + n - 10, ".localhost", 10))) return 1;
    struct in_addr v4;
    struct in6_addr v6;
    char host[256]; memcpy(host, o->host, n); host[n] = 0;
    return (inet_pton(AF_INET, host, &v4) == 1 && ((unsigned char *)&v4)[0] == 127) ||
        (inet_pton(AF_INET6, host, &v6) == 1 && IN6_IS_ADDR_LOOPBACK(&v6));
}

static const char *sk_fetch_site(struct sk_curl *a, const struct sk_request *q,
                                const struct sk_origin *target) {
    const char *initiator = q->fetch_initiator ? q->fetch_initiator : q->initiator;
    if (!*initiator) return "none";
    struct sk_origin source;
    if (!sk_parse_url(initiator, &source, 1)) return "cross-site";
    if (sk_same_origin(&source, target)) return "same-origin";
    if (source.tls != target->tls) return "cross-site";
    if (!strcmp(source.host, target->host)) return "same-site";
    /* IP addresses and private PSL entries must not be grouped by suffix. */
    struct in_addr v4;
    struct in6_addr v6;
    if (inet_pton(AF_INET, source.host, &v4) == 1 || inet_pton(AF_INET6, source.host, &v6) == 1 ||
        inet_pton(AF_INET, target->host, &v4) == 1 || inet_pton(AF_INET6, target->host, &v6) == 1)
        return "cross-site";
    if (a->psl_builtin && a->psl_registrable_domain) {
        const struct psl_ctx_st *psl = a->psl_builtin();
        if (!psl) return "cross-site";
        const char *s = a->psl_registrable_domain(psl, source.host);
        const char *t = a->psl_registrable_domain(psl, target->host);
        if (s && t && !strcmp(s, t)) return "same-site";
    }
    return "cross-site";
}

static int sk_append_header(struct sk_curl *a, struct curl_slist **headers,
                            const char *name, const char *value) {
    size_t n = strlen(name), v = strlen(value);
    char *line = malloc(n + v + 3);
    if (!line) return 0;
    memcpy(line, name, n); line[n] = ':'; line[n + 1] = ' ';
    memcpy(line + n + 2, value, v + 1);
    /* curl's "Name;" preserves an empty header instead of removing it. */
    if (!v) { line[n] = ';'; line[n + 1] = 0; }
    struct curl_slist *next = a->slist_append(*headers, line);
    free(line);
    if (!next) return 0;
    *headers = next;
    return 1;
}

/* CEF omits metadata that Chromium's network service adds after interception;
 * its API also lacks arbitrary Fetch modes and the audio/video destination. */
static int sk_fetch_metadata(struct sk_curl *a, struct curl_slist **headers,
                             const struct sk_request *q, size_t header_len,
                             const struct sk_origin *target) {
    if (!sk_trustworthy(target)) return 1;
    const char *dest = "empty", *mode = "no-cors";
    int has_origin = 0;
    for (size_t at = 0; at < header_len;) {
        const char *name = q->headers + at; at += strlen(name) + 1;
        at += strlen(q->headers + at) + 1;
        if (!strcasecmp(name, "origin")) has_origin = 1;
    }
    if (q->navigation) {
        dest = q->resource_type == RT_MAIN_FRAME ? "document" : "iframe";
        mode = "navigate";
    } else {
        switch (q->resource_type) {
        case RT_SCRIPT: dest = "script"; break;
        case RT_STYLESHEET: dest = "style"; break;
        case RT_FONT_RESOURCE: dest = "font"; mode = "cors"; break;
        case RT_IMAGE: dest = "image"; break;
        case RT_OBJECT: dest = "object"; break;
        case RT_XHR: mode = "cors"; break;
        case RT_CSP_REPORT: dest = "report"; break;
        default: break;
        }
        if (has_origin && q->resource_type != RT_PING && q->resource_type != RT_CSP_REPORT)
            mode = "cors";
    }
    return sk_append_header(a, headers, "Sec-Fetch-Dest", dest) &&
        sk_append_header(a, headers, "Sec-Fetch-Mode", mode) &&
        sk_append_header(a, headers, "Sec-Fetch-Site", sk_fetch_site(a, q, target)) &&
        (!q->navigation || !q->user_activation || sk_append_header(a, headers, "Sec-Fetch-User", "?1"));
}

static int sk_token(const char *s, size_t len) {
    if (!len) return 0;
    for (size_t i = 0; i < len; ++i) {
        unsigned char c = (unsigned char)s[i];
        if (!c || (!(isalnum(c) && c < 128) && !strchr("!#$%&'*+-.^_`|~", c))) return 0;
    }
    return 1;
}

static int sk_value(const char *s) {
    for (const unsigned char *p = (const unsigned char *)s; *p; ++p)
        if ((*p < 32 && *p != '\t') || *p == 127) return 0;
    return 1;
}

static int sk_safelisted(const char *name, const char *value) {
    if (strlen(value) > 128) return 0;
    if (!strcasecmp(name, "accept-language") || !strcasecmp(name, "content-language")) {
        for (const unsigned char *p = (const unsigned char *)value; *p; ++p)
            if (!(isalnum(*p) && *p < 128) && !strchr(" *,-.;=", *p)) return 0;
        return 1;
    }
    if (strcasecmp(name, "accept") && strcasecmp(name, "content-type")) return 0;
    for (const unsigned char *p = (const unsigned char *)value; *p; ++p)
        if ((*p < 32 && *p != '\t') || *p == 127 || strchr("\"():<>?@[\\]{}", *p)) return 0;
    if (!strcasecmp(name, "accept")) return 1;
    size_t n = strcspn(value, ";");
    while (n && (value[n - 1] == ' ' || value[n - 1] == '\t')) --n;
    return (n == 10 && !strncasecmp(value, "text/plain", n)) ||
        (n == 33 && !strncasecmp(value, "application/x-www-form-urlencoded", n)) ||
        (n == 19 && !strncasecmp(value, "multipart/form-data", n));
}

static int sk_browser_header(const char *name) {
    return !strcasecmp(name, "cookie") || !strcasecmp(name, "user-agent") ||
        !strcasecmp(name, "accept-encoding") || !strcasecmp(name, "referer") ||
        !strncasecmp(name, "sec-fetch-", 10) || !strncasecmp(name, "sec-ch-ua", 9);
}

static int sk_forbidden_header(const char *name) {
    return !strcasecmp(name, "host") || !strcasecmp(name, "range") ||
        !strcasecmp(name, "if-range") || !strcasecmp(name, "authorization") ||
        !strncasecmp(name, "proxy-", 6) || !strcasecmp(name, "connection") ||
        !strcasecmp(name, "upgrade") || !strcasecmp(name, "transfer-encoding") ||
        !strcasecmp(name, "content-encoding") || !strcasecmp(name, "content-length") ||
        !strcasecmp(name, "te") || !strcasecmp(name, "trailer") ||
        !strcasecmp(name, "expect") || !strcasecmp(name, "keep-alive");
}

/* Header wire format is name NUL value NUL, not curl's permissive text parser. */
static int sk_validate(struct sk_request *r, size_t header_len, struct sk_origin *target) {
    if (!sk_parse_url(r->url, target, 0) ||
        (strcmp(r->method, "GET") && strcmp(r->method, "HEAD") && strcmp(r->method, "POST")) ||
        r->body_len > SK_UPLOAD_CAP || (r->body_len && strcmp(r->method, "POST")) ||
        (r->allow_private != 0 && r->allow_private != 1) ||
        (r->navigation != 0 && r->navigation != 1) ||
        (r->user_activation != 0 && r->user_activation != 1) || !r->initiator) return 0;
    struct sk_origin source;
    int known = sk_parse_url(r->initiator, &source, 1);
    int same = known && sk_same_origin(target, &source);
    if (r->navigation) {
        if (r->resource_type != RT_MAIN_FRAME && r->resource_type != RT_SUB_FRAME) return 0;
    } else {
        switch (r->resource_type) {
        case RT_STYLESHEET: case RT_SCRIPT: case RT_FONT_RESOURCE: break;
        case RT_IMAGE: case RT_SUB_RESOURCE: case RT_OBJECT: case RT_MEDIA:
        case RT_XHR: case RT_PING: case RT_CSP_REPORT:
            if (!same) return 0;
            break;
        default: return 0;
        }
        if (!same && (!known || strcmp(r->method, "GET") || (source.tls && !target->tls))) return 0;
    }
    const char *origin = NULL;
    const char *names[SK_HEADER_FIELDS];
    size_t fields = 0;
    int non_simple = 0;
    size_t safe_bytes = 0;
    for (size_t at = 0; at < header_len;) {
        const char *name = r->headers + at;
        const char *nul = memchr(name, 0, header_len - at);
        if (!nul || !sk_token(name, (size_t)(nul - name)) || fields == SK_HEADER_FIELDS) return 0;
        at += (size_t)(nul - name) + 1;
        const char *value = r->headers + at;
        nul = memchr(value, 0, header_len - at);
        if (!nul || !sk_value(value) || sk_forbidden_header(name)) return 0;
        at += (size_t)(nul - value) + 1;
        if (!strcasecmp(name, "origin")) {
            if (origin) return 0;
            origin = value;
        } else if (!sk_browser_header(name)) {
            int navigation_header = r->navigation &&
                (!strcasecmp(name, "accept") ||
                 (!strcasecmp(name, "upgrade-insecure-requests") && !strcmp(value, "1")));
            if (!navigation_header && !sk_safelisted(name, value)) non_simple = 1;
            else safe_bytes += strlen(value);
            /* Duplicate author fields combine into a value whose safelist
             * semantics are ambiguous; require same-origin conservatively. */
            for (size_t i = 0; i < fields; ++i)
                if (!strcasecmp(name, names[i])) non_simple = 1;
        }
        names[fields++] = name;
    }
    if (safe_bytes > 1024) non_simple = 1;
    /* Origin is consistency-checked, never used as authority. */
    if (origin) {
        struct sk_origin header_origin;
        if (known) {
            if (!sk_parse_url(origin, &header_origin, 1) || !sk_same_origin(&source, &header_origin)) return 0;
        } else if (strcmp(origin, "null")) return 0;
    }
    return (strcmp(r->method, "POST") || same) && (!non_simple || same);
}

static void sk_request_free(struct sk_request *r) {
    free(r->url); free(r->method); free(r->headers); free(r->initiator); free(r->fetch_initiator); free(r->body);
    memset(r, 0, sizeof(*r));
}

static int sk_recv_text(int fd, char **out, uint32_t len, int64_t deadline) {
    *out = malloc((size_t)len + 1);
    if (!*out || !sk_io(fd, *out, len, 0, deadline)) return 0;
    (*out)[len] = 0;
    return !memchr(*out, 0, len);
}

/* Compiled out; dist/test-web-untrusted.c records every socket curl asks for
 * through it, refused ones included, to prove what a routed job dials. */
#ifndef SK_OPEN_SOCKET_OBSERVE
#define SK_OPEN_SOCKET_OBSERVE(purpose, address) ((void)0)
#endif

static curl_socket_t sk_open_socket(void *user, curlsocktype purpose, struct curl_sockaddr *a) {
    struct sk_response *r = user;
    SK_OPEN_SOCKET_OBSERVE(purpose, a);
    int port = 0;
    if (a->family == AF_INET && a->addrlen == sizeof(struct sockaddr_in))
        port = ntohs(((struct sockaddr_in *)&a->addr)->sin_port);
    else if (a->family == AF_INET6 && a->addrlen == sizeof(struct sockaddr_in6))
        port = ntohs(((struct sockaddr_in6 *)&a->addr)->sin6_port);
    if (purpose != CURLSOCKTYPE_IPCXN ||
        (a->socktype & ~(SOCK_CLOEXEC | SOCK_NONBLOCK)) != SOCK_STREAM ||
        (a->protocol != 0 && a->protocol != IPPROTO_TCP) || port != r->port || !port ||
        a->addr.sa_family != a->family) return CURL_SOCKET_BAD;
    if (r->proxy) {
        /* A routed job opens one kind of socket: TCP to the proxy this job
         * resolved. The proxy may be loopback or private (it is the caller's);
         * anything else, whatever its class, is refused. */
        unsigned char want[16], have[16];
        if (a->family != r->proxy->address.ss_family ||
            !sk_address_bytes((const struct sockaddr *)&r->proxy->address, want) ||
            !sk_address_bytes(&a->addr, have) || memcmp(want, have, sizeof(want))) return CURL_SOCKET_BAD;
        return socket(a->family, a->socktype | SOCK_CLOEXEC, a->protocol);
    }
    if (!r->allow_private) {
        /* Queried per candidate so an address added since the last load is seen. */
        struct ifaddrs *own = NULL;
        if (getifaddrs(&own)) return CURL_SOCKET_BAD;
        int allowed = sk_address_allowed(&a->addr, 0, own);
        freeifaddrs(own);
        if (!allowed) {
            r->reason = SK_WEB_UNTRUSTED_PRIVATE;
            return CURL_SOCKET_BAD;
        }
    }
    return socket(a->family, a->socktype | SOCK_CLOEXEC, a->protocol);
}

static size_t sk_write_body(char *data, size_t size, size_t count, void *user) {
    struct sk_response *r = user;
    if (size && count > SIZE_MAX / size) return 0;
    size_t len = size * count;
    if (len > SK_BODY_CAP - r->body_len) return 0;
    if (r->body_len + len > r->body_capacity) {
        size_t capacity = r->body_capacity ? r->body_capacity : 16384;
        while (capacity < r->body_len + len) capacity *= 2;
        if (capacity > SK_BODY_CAP) capacity = SK_BODY_CAP;
        void *p = realloc(r->body, capacity);
        if (!p) return 0;
        r->body = p; r->body_capacity = capacity;
    }
    if (len) memcpy(r->body + r->body_len, data, len);
    r->body_len += len;
    return len;
}

static int sk_transport_header(const char *name) {
    return !strcasecmp(name, "content-encoding") || !strcasecmp(name, "content-length") ||
        !strcasecmp(name, "transfer-encoding") || !strcasecmp(name, "connection") ||
        !strcasecmp(name, "keep-alive") || !strcasecmp(name, "upgrade") ||
        !strcasecmp(name, "proxy-authenticate") || !strcasecmp(name, "trailer") ||
        !strcasecmp(name, "te");
}

static size_t sk_write_header(char *data, size_t size, size_t count, void *user) {
    struct sk_response *r = user;
    if (size && count > SIZE_MAX / size) return 0;
    size_t len = size * count;
    if (len > SK_HEADER_CAP - r->header_total) return 0;
    r->header_total += len;
    if (len >= 5 && !memcmp(data, "HTTP/", 5)) {
        /* Discard interim headers, but account them against the same cap. */
        r->headers_len = 0;
        return len;
    }
    if (len == 2 && !memcmp(data, "\r\n", 2)) return len;
    if (len < 2 || data[len - 2] != '\r' || data[len - 1] != '\n') return 0;
    char *colon = memchr(data, ':', len - 2);
    if (!colon || !sk_token(data, (size_t)(colon - data))) return 0;
    size_t n = (size_t)(colon - data);
    char name[SK_HEADER_CAP + 1];
    memcpy(name, data, n); name[n] = 0;
    const char *value = colon + 1, *end = data + len - 2;
    while (value < end && (*value == ' ' || *value == '\t')) ++value;
    while (end > value && (end[-1] == ' ' || end[-1] == '\t')) --end;
    size_t v = (size_t)(end - value);
    for (size_t i = 0; i < v; ++i)
        if ((unsigned char)value[i] < 32 && value[i] != '\t') return 0;
        else if ((unsigned char)value[i] == 127) return 0;
    /* HTTP upgrades and partial responses are unsupported, not new transports. */
    if (!strcasecmp(name, "upgrade") || !strcasecmp(name, "content-range")) return 0;
    if (r->cross_static && !strcasecmp(name, "set-cookie")) return len;
    if (sk_transport_header(name)) return len;
    if (n + v + 2 > SK_HEADER_CAP - r->headers_len) return 0;
    memcpy(r->headers + r->headers_len, name, n + 1); r->headers_len += n + 1;
    memcpy(r->headers + r->headers_len, value, v); r->headers_len += v;
    r->headers[r->headers_len++] = 0;
    return len;
}

static int sk_static_response(const struct sk_request *q, const struct sk_response *r) {
    const char *mime = NULL, *acao = NULL;
    for (size_t at = 0; at < r->headers_len;) {
        const char *name = r->headers + at; at += strlen(name) + 1;
        const char *value = r->headers + at; at += strlen(value) + 1;
        if (!strcasecmp(name, "access-control-allow-origin")) {
            if (acao) return 0;
            acao = value;
        } else if (!strcasecmp(name, "content-type")) {
            if (mime) return 0;
            mime = value;
        } else if (!strcasecmp(name, "cross-origin-resource-policy") && strcmp(value, "cross-origin")) return 0;
    }
    if (!acao || strcmp(acao, "*") || !mime) return 0;
    size_t n = strcspn(mime, ";");
    while (n && (mime[n - 1] == ' ' || mime[n - 1] == '\t')) --n;
#define MIME(text) (n == sizeof(text) - 1 && !strncasecmp(mime, text, n))
    int ok = q->resource_type == RT_SCRIPT ? (MIME("text/javascript") || MIME("application/javascript")) :
        q->resource_type == RT_STYLESHEET ? MIME("text/css") :
        q->resource_type == RT_FONT_RESOURCE && (MIME("font/woff") || MIME("font/woff2") ||
            MIME("font/ttf") || MIME("font/otf") || MIME("application/font-woff"));
#undef MIME
    return ok;
}

/* Resolve the route's proxy for one job: its first stream address, and the
 * numeric url curl dials. curl gets no name to resolve, so a page host only
 * ever travels to the proxy (socks5h ATYP 3, an HTTP CONNECT or absolute-form
 * request line). Runs before the job's Landlock, which then admits only the
 * proxy's port. */
static int sk_proxy_resolve(struct sk_proxy_target *t) {
    struct addrinfo hints = {.ai_family = AF_UNSPEC, .ai_socktype = SOCK_STREAM, .ai_protocol = IPPROTO_TCP}, *list = NULL;
    if (getaddrinfo(sk_proxy.host, NULL, &hints, &list) || !list) return 0;
    const struct addrinfo *pick = NULL;
    for (const struct addrinfo *i = list; i && !pick; i = i->ai_next)
        if ((i->ai_family == AF_INET && i->ai_addrlen == sizeof(struct sockaddr_in)) ||
            (i->ai_family == AF_INET6 && i->ai_addrlen == sizeof(struct sockaddr_in6))) pick = i;
    int ok = 0;
    char text[INET6_ADDRSTRLEN];
    if (pick) {
        memset(&t->address, 0, sizeof(t->address));
        memcpy(&t->address, pick->ai_addr, pick->ai_addrlen);
        const void *raw = pick->ai_family == AF_INET ? (const void *)&((struct sockaddr_in *)pick->ai_addr)->sin_addr
                                                     : (const void *)&((struct sockaddr_in6 *)pick->ai_addr)->sin6_addr;
        int n = inet_ntop(pick->ai_family, raw, text, sizeof(text)) ?
            snprintf(t->url, sizeof(t->url), pick->ai_family == AF_INET ? "%s://%s:%u" : "%s://[%s]:%u",
                     sk_proxy.socks ? "socks5h" : "http", text, sk_proxy.port) : -1;
        ok = n > 0 && (size_t)n < sizeof(t->url);
    }
    freeaddrinfo(list);
    return ok;
}

static void sk_fetch(struct sk_curl *a, struct sk_request *q, size_t header_len, struct sk_response *r,
                     int64_t deadline) {
    struct sk_origin origin;
    r->reason = SK_WEB_UNTRUSTED_UNSUPPORTED;
    if (!sk_validate(q, header_len, &origin)) return;
    struct sk_origin source;
    r->cross_static = !q->navigation &&
        (!sk_parse_url(q->initiator, &source, 1) || !sk_same_origin(&source, &origin));
    r->reason = SK_WEB_UNTRUSTED_BROKER_FAILURE;
    r->port = (int)(sk_proxy.on ? sk_proxy.port : origin.port); r->allow_private = q->allow_private;
    int64_t now = sk_now_ms();
    long budget = now < 0 ? 0 : (long)(deadline - SK_REPLY_MARGIN_MS - now);
    if (budget <= 0) { r->reason = SK_WEB_UNTRUSTED_TIMEOUT; return; }
    struct sk_proxy_target proxy;
    if (sk_proxy.on) {
        if (!sk_proxy_resolve(&proxy)) return;
        r->proxy = &proxy;
    }
    if (!sk_landlock_job(sk_landlock_abi, (unsigned)r->port, !sk_proxy.on)) return;
    r->headers = malloc(SK_HEADER_CAP);
    CURL *easy = a->easy_init();
    struct curl_slist *headers = NULL;
    if (!easy || !r->headers) goto done;
    int typed = 0;
    for (size_t at = 0; at < header_len;) {
        const char *name = q->headers + at; at += strlen(name) + 1;
        const char *value = q->headers + at; at += strlen(value) + 1;
        if (!strcasecmp(name, "content-type")) typed = 1;
        if (!strcasecmp(name, "accept-encoding") || !strncasecmp(name, "sec-fetch-", 10)) continue;
        if (r->cross_static && (!strcasecmp(name, "cookie") || !strcasecmp(name, "referer") ||
                                !strcasecmp(name, "origin"))) continue;
        if (!sk_append_header(a, &headers, name, value)) goto done;
    }
    if (!sk_fetch_metadata(a, &headers, q, header_len, &origin)) goto done;
    struct curl_slist *next = a->slist_append(headers, "Expect:");
    if (!next) goto done;
    headers = next;
    /* curl labels a POST body x-www-form-urlencoded unless its default is removed;
     * a body the page left untyped must reach the server untyped. */
    if (!typed && !strcmp(q->method, "POST")) {
        next = a->slist_append(headers, "Content-Type:");
        if (!next) goto done;
        headers = next;
    }
    if (r->cross_static) {
        char line[SK_URL_CAP + 9];
        snprintf(line, sizeof(line), "Origin: %s", *q->initiator ? q->initiator : "null");
        next = a->slist_append(headers, line);
        if (!next) goto done;
        headers = next;
    }
#define SET(option, value) do { if (a->easy_setopt(easy, (option), (value)) != CURLE_OK) goto done; } while (0)
    SET(CURLOPT_URL, q->url);
    SET(CURLOPT_PROTOCOLS_STR, "http,https"); SET(CURLOPT_REDIR_PROTOCOLS_STR, "http,https");
    /* Routed: every transfer through the proxy, none exempt (an empty
     * NOPROXY, not curl's default list). Direct: no proxy whatever the
     * environment says. */
    SET(CURLOPT_PROXY, sk_proxy.on ? proxy.url : ""); SET(CURLOPT_NOPROXY, sk_proxy.on ? "" : "*");
    SET(CURLOPT_PRE_PROXY, ""); SET(CURLOPT_HTTPPROXYTUNNEL, 0L);
    if (sk_proxy.on && !sk_proxy.socks) SET(CURLOPT_SUPPRESS_CONNECT_HEADERS, 1L);
    SET(CURLOPT_NETRC, (long)CURL_NETRC_IGNORED);
    SET(CURLOPT_HTTPAUTH, (long)CURLAUTH_NONE); SET(CURLOPT_PROXYAUTH, (long)CURLAUTH_NONE);
    SET(CURLOPT_FOLLOWLOCATION, 0L); SET(CURLOPT_MAXREDIRS, 0L);
    SET(CURLOPT_SSL_VERIFYPEER, 1L); SET(CURLOPT_SSL_VERIFYHOST, 2L);
    SET(CURLOPT_NOSIGNAL, 1L); SET(CURLOPT_TIMEOUT_MS, budget);
    SET(CURLOPT_CONNECTTIMEOUT_MS, budget < SK_CONNECT_TIMEOUT_MS ? budget : SK_CONNECT_TIMEOUT_MS);
    SET(CURLOPT_HTTP_VERSION, (long)CURL_HTTP_VERSION_1_1);
    SET(CURLOPT_FRESH_CONNECT, 1L); SET(CURLOPT_FORBID_REUSE, 1L);
    SET(CURLOPT_ACCEPT_ENCODING, "");
    SET(CURLOPT_HTTPHEADER, headers);
    SET(CURLOPT_OPENSOCKETFUNCTION, sk_open_socket); SET(CURLOPT_OPENSOCKETDATA, r);
    SET(CURLOPT_WRITEFUNCTION, sk_write_body); SET(CURLOPT_WRITEDATA, r);
    SET(CURLOPT_HEADERFUNCTION, sk_write_header); SET(CURLOPT_HEADERDATA, r);
    if (!strcmp(q->method, "HEAD")) SET(CURLOPT_NOBODY, 1L);
    if (!strcmp(q->method, "POST")) {
        SET(CURLOPT_POST, 1L);
        SET(CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)q->body_len);
        SET(CURLOPT_POSTFIELDS, q->body ? (const char *)q->body : "");
    }
    /* A refused candidate may precede a valid candidate; only successful
     * completion clears the private-address diagnostic. */
    CURLcode result = a->easy_perform(easy);
    long status = 0;
    if (result == CURLE_OK && a->easy_getinfo(easy, CURLINFO_RESPONSE_CODE, &status) == CURLE_OK &&
        status >= 200 && status <= 599 && status != 206) {
        if (q->navigation) {
            /* CEF attributes classic worker imports to the document's frame
             * and RT_SCRIPT, so only an engine-enforced CSP separates them. */
            static const char worker_csp[] = "Content-Security-Policy\0worker-src 'none'\0";
            if (sizeof(worker_csp) - 1 > SK_HEADER_CAP - r->headers_len) goto done;
            memcpy(r->headers + r->headers_len, worker_csp, sizeof(worker_csp) - 1);
            r->headers_len += sizeof(worker_csp) - 1;
        }
        if ((!q->navigation && (status == 301 || status == 302 || status == 303 || status == 307 || status == 308)) ||
            (r->cross_static && (status >= 300 || !sk_static_response(q, r))))
            r->reason = SK_WEB_UNTRUSTED_UNSUPPORTED;
        else { r->status = (int)status; r->reason = 0; }
    } else if (result == CURLE_OPERATION_TIMEDOUT && r->reason != SK_WEB_UNTRUSTED_PRIVATE) {
        r->reason = SK_WEB_UNTRUSTED_TIMEOUT;
    }
#undef SET
done:
    if (easy) a->easy_cleanup(easy);
    if (headers) a->slist_free_all(headers);
    /* The target dies with this frame; nothing may reach it afterwards. */
    r->proxy = NULL;
}

static void sk_job(int fd, struct sk_curl *a) {
    /* Backstop for blocking libc/NSS resolution and a wedged curl; never earlier
     * than the deadline, so the loader reports TIMEOUT rather than EOF. */
    alarm(SK_TIMEOUT_S);
    int64_t deadline = sk_now_ms() + SK_TIMEOUT_MS;
    struct sk_wire_request w;
    struct sk_request q = {0};
    struct sk_response r = {.reason = SK_WEB_UNTRUSTED_UNSUPPORTED};
    if (!sk_io(fd, &w, sizeof(w), 0, deadline)) goto done;
    if (w.magic != SK_MAGIC || !w.url_len || w.url_len > SK_URL_CAP ||
        !w.method_len || w.method_len > 4 || w.headers_len > SK_HEADER_CAP ||
        w.body_len > SK_UPLOAD_CAP || w.allow_private > 1 || w.initiator_len > SK_URL_CAP ||
        w.navigation > 1 || w.user_activation > 1 || w.fetch_initiator_len > SK_URL_CAP || w.resource_type >= RT_NUM_VALUES ||
        !w.budget_ms || w.budget_ms > SK_TIMEOUT_MS) goto reply;
    {
        /* The loader's deadline, which may be nearer than ours after queueing. */
        int64_t loader = sk_now_ms() + (int64_t)w.budget_ms;
        if (loader < deadline) {
            deadline = loader;
            alarm((unsigned)((w.budget_ms + 999) / 1000));
        }
    }
    if (!sk_recv_text(fd, &q.url, w.url_len, deadline) ||
        !sk_recv_text(fd, &q.method, w.method_len, deadline) ||
        !sk_recv_text(fd, &q.initiator, w.initiator_len, deadline) ||
        !sk_recv_text(fd, &q.fetch_initiator, w.fetch_initiator_len, deadline)) goto reply;
    q.headers = malloc((size_t)w.headers_len + 1);
    q.body = w.body_len ? malloc(w.body_len) : NULL;
    if (!q.headers || (w.body_len && !q.body)) { r.reason = SK_WEB_UNTRUSTED_BROKER_FAILURE; goto reply; }
    if (!sk_io(fd, q.headers, w.headers_len, 0, deadline) ||
        !sk_io(fd, q.body, w.body_len, 0, deadline)) goto done;
    q.headers[w.headers_len] = 0;
    q.body_len = w.body_len; q.allow_private = (int)w.allow_private;
    q.navigation = (int)w.navigation; q.resource_type = (int)w.resource_type;
    q.user_activation = (int)w.user_activation;
    sk_fetch(a, &q, w.headers_len, &r, deadline);
reply:;
    struct sk_wire_response answer = {SK_MAGIC, (uint32_t)r.reason, (uint32_t)r.status,
        r.reason ? 0 : (uint32_t)r.headers_len, r.reason ? 0 : (uint32_t)r.body_len};
    if (sk_io(fd, &answer, sizeof(answer), 1, deadline) && !r.reason) {
        if (sk_io(fd, r.headers, r.headers_len, 1, deadline))
            (void)sk_io(fd, r.body, r.body_len, 1, deadline);
    }
done:
    sk_request_free(&q); free(r.headers); free(r.body); close(fd);
    _exit(0);
}

static void sk_term(int sig) { (void)sig; sk_broker_stop = 1; }

static int sk_close_inherited(int listener, int lifetime, int ready) {
    int fds[3] = {listener, lifetime, ready}, copies[3];
    for (int i = 0; i < 3; ++i) {
        copies[i] = fcntl(fds[i], F_DUPFD_CLOEXEC, 6);
        if (copies[i] < 0) return 0;
    }
    for (int i = 0; i < 3; ++i) if (dup3(copies[i], 3 + i, O_CLOEXEC) < 0) return 0;
    /* Fail closed if the kernel cannot close the entire inherited table. */
    if (syscall(SYS_close_range, 6u, ~0u, 0u)) return 0;
    /* Occupy 0-2 so neither stray library output nor a later socket can land
     * on a standard descriptor and mix into the framed IPC. */
    int null = open("/dev/null", O_RDWR | O_CLOEXEC);
    if (null < 0) return 0;
    for (int i = 0; i < 3; ++i) if (dup2(null, i) != i) { close(null); return 0; }
    close(null);
    return 1;
}

static void sk_broker(int listener, int lifetime, int ready, pid_t parent) {
    if (setpgid(0, 0) || !sk_close_inherited(listener, lifetime, ready)) _exit(1);
    listener = 3; lifetime = 4; ready = 5;
    umask(077);
    if (chdir("/") || clearenv() || !sk_web_untrusted_no_core()) _exit(1);
    struct sigaction sa = {0};
    sa.sa_handler = sk_term; sigemptyset(&sa.sa_mask);
    if (sigprocmask(SIG_SETMASK, &sa.sa_mask, NULL) || prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)) _exit(1);
    if (sigaction(SIGTERM, &sa, NULL) || sigaction(SIGINT, &sa, NULL)) _exit(1);
    sa.sa_handler = SIG_DFL;
    if (sigaction(SIGCHLD, &sa, NULL) || sigaction(SIGALRM, &sa, NULL)) _exit(1);
    /* CURLOPT_NOSIGNAL leaves TLS backends' broken-pipe handling to us. */
    sa.sa_handler = SIG_IGN;
    if (sigaction(SIGPIPE, &sa, NULL)) _exit(1);
    if (prctl(PR_SET_PDEATHSIG, SIGTERM) || getppid() != parent) _exit(1);
    /* listen records the broker's SO_PEERCRED identity, not the browser's. */
    if (listen(listener, SK_JOBS)) _exit(1);
    alarm(SK_TIMEOUT_S); /* Bounds startup by the same budget the parent waits. */
    struct sk_curl a;
    if (!sk_curl_load(&a) || a.global_init(CURL_GLOBAL_DEFAULT) != CURLE_OK) _exit(1);
    unsigned char ok = 1;
    if (write(ready, &ok, 1) != 1) _exit(1);
    close(ready); alarm(0);
    pid_t jobs[SK_JOBS] = {0};
    int peers[SK_JOBS];
    for (unsigned i = 0; i < SK_JOBS; ++i) peers[i] = -1;
    while (!sk_broker_stop) {
        for (unsigned i = 0; i < SK_JOBS; ++i)
            if (jobs[i] && waitpid(jobs[i], NULL, WNOHANG) == jobs[i]) {
                jobs[i] = 0; close(peers[i]); peers[i] = -1;
            }
        unsigned slot = 0;
        while (slot < SK_JOBS && jobs[slot]) ++slot;
        /* With every slot busy a connection waits in the backlog rather than being
         * refused: a loader may connect before its predecessor's job is reaped. */
        struct pollfd f[2 + SK_JOBS] = {{listener, slot < SK_JOBS ? POLLIN : 0, 0}, {lifetime, POLLIN, 0}};
        /* RDHUP sees cancellation even with unread request bytes; never read or
         * poll POLLIN here, since those bytes belong exclusively to the job. */
        for (unsigned i = 0; i < SK_JOBS; ++i) f[2 + i] = (struct pollfd){peers[i], POLLRDHUP, 0};
        int n = poll(f, 2 + SK_JOBS, SK_REAP_POLL_MS);
        if (n < 0) { if (errno == EINTR) continue; break; }
        if (f[1].revents) break;
        for (unsigned i = 0; i < SK_JOBS; ++i) {
            if (!jobs[i] || !(f[2 + i].revents & (POLLRDHUP | POLLHUP | POLLERR | POLLNVAL))) continue;
            kill(jobs[i], SIGKILL);
            while (waitpid(jobs[i], NULL, 0) < 0 && errno == EINTR) {}
            jobs[i] = 0; close(peers[i]); peers[i] = -1;
        }
        if (!(f[0].revents & POLLIN)) continue;
        slot = 0;
        while (slot < SK_JOBS && jobs[slot]) ++slot;
        if (slot == SK_JOBS) continue;
        int fd = accept4(listener, NULL, NULL, SOCK_CLOEXEC | SOCK_NONBLOCK);
        if (fd < 0) continue;
        struct ucred cred; socklen_t len = sizeof(cred);
        if ( getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &len) ||
            cred.uid != getuid() || cred.pid != parent) { close(fd); continue; }
        pid_t owner = getpid();
        pid_t pid = fork();
        if (!pid) {
            sa.sa_handler = SIG_DFL;
            sigaction(SIGTERM, &sa, NULL); sigaction(SIGINT, &sa, NULL);
            if (prctl(PR_SET_PDEATHSIG, SIGKILL) || getppid() != owner) _exit(1);
            close(listener); close(lifetime);
            for (unsigned i = 0; i < SK_JOBS; ++i) if (peers[i] >= 0) close(peers[i]);
            sk_job(fd, &a);
        }
        if (pid > 0) { jobs[slot] = pid; peers[slot] = fd; }
        else close(fd);
    }
    close(listener); close(lifetime);
    for (unsigned i = 0; i < SK_JOBS; ++i) if (jobs[i]) kill(jobs[i], SIGKILL);
    for (unsigned i = 0; i < SK_JOBS; ++i) if (jobs[i])
        while (waitpid(jobs[i], NULL, 0) < 0 && errno == EINTR) {}
    for (unsigned i = 0; i < SK_JOBS; ++i) if (peers[i] >= 0) close(peers[i]);
    a.global_cleanup(); dlclose(a.handle);
    _exit(0);
}

/* socks5h://HOST:PORT or http://HOST:PORT with an explicit port and nothing
 * else; anything else refuses the start rather than browsing direct. */
static int sk_proxy_configure(const char *url) {
    memset(&sk_proxy, 0, sizeof(sk_proxy));
    if (!url || !*url) return 1;
    int socks = !strncmp(url, "socks5h://", 10);
    if (!socks && strncmp(url, "http://", 7)) return 0;
    const char *authority = url + (socks ? 10 : 7);
    /* sk_parse_url defaults a missing port to 80; a proxy names its own. */
    const char *close = *authority == '[' ? strchr(authority, ']') : NULL;
    const char *colon = close ? (close[1] == ':' ? close + 1 : NULL) : strrchr(authority, ':');
    if (!colon || !colon[1]) return 0;
    char text[SK_URL_CAP];
    int n = snprintf(text, sizeof(text), "http://%s", authority);
    struct sk_origin o;
    if (n <= 0 || (size_t)n >= sizeof(text) || !sk_parse_url(text, &o, 1)) return 0;
    memcpy(sk_proxy.host, o.host, sizeof(sk_proxy.host));
    sk_proxy.port = o.port; sk_proxy.socks = socks; sk_proxy.on = 1;
    return 1;
}

int sk_web_untrusted_start(const char *private_dir, const char *proxy) {
#ifndef SK_AUDIT_ARCH
    (void)private_dir; (void)proxy;
    return 0;
#else
    if (sk_broker_pid || !private_dir || private_dir[0] != '/' ||
        getuid() != geteuid() || getgid() != getegid() || !sk_web_untrusted_core_limit()) return 0;
    if (!sk_proxy_configure(proxy)) return 0;
    /* The caller stays dumpable: Chromium's namespace sandbox needs that, and
     * the broker child below makes itself nondumpable. */
    char *canonical = realpath(private_dir, NULL);
    struct stat st;
    int valid = canonical && !strcmp(canonical, private_dir) &&
        !lstat(private_dir, &st) && S_ISDIR(st.st_mode) && st.st_uid == getuid() &&
        (st.st_mode & 0777) == 0700;
    free(canonical);
    if (!valid) return 0;
    int n = snprintf(sk_socket_path, sizeof(sk_socket_path), "%s/broker.sock", private_dir);
    if (n < 0 || (size_t)n >= sizeof(sk_socket_path)) { sk_socket_path[0] = 0; return 0; }
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    memcpy(address.sun_path, sk_socket_path, (size_t)n + 1);
    int listener = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    int lifetime[2] = {-1,-1}, ready[2] = {-1,-1}, bound = 0;
    pid_t pid = -1;
    if (listener < 0 || bind(listener, (struct sockaddr *)&address, sizeof(address))) goto bad;
    bound = 1;
    if (chmod(sk_socket_path, 0600) ||
        pipe2(lifetime, O_CLOEXEC | O_NONBLOCK) || pipe2(ready, O_CLOEXEC | O_NONBLOCK)) goto bad;
    pid_t parent = getpid();
    sk_landlock_abi = sk_landlock_probe();
    pid = fork();
    if (pid < 0) goto bad;
    if (!pid) sk_broker(listener, lifetime[0], ready[1], parent);
    close(lifetime[0]); lifetime[0] = -1;
    close(ready[1]); ready[1] = -1;
    struct pollfd f = {ready[0], POLLIN, 0};
    unsigned char ok = 0;
    if (poll(&f, 1, SK_TIMEOUT_MS) <= 0 || read(ready[0], &ok, 1) != 1 || ok != 1) goto bad;
    close(listener); close(ready[0]);
    sk_broker_pid = pid; sk_lifetime_fd = lifetime[1];
    return 1;
bad:
    if (pid > 0) { kill(pid, SIGKILL); while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {} }
    if (listener >= 0) close(listener);
    for (int i = 0; i < 2; ++i) {
        if (lifetime[i] >= 0) close(lifetime[i]);
        if (ready[i] >= 0) close(ready[i]);
    }
    if (bound) unlink(sk_socket_path);
    sk_socket_path[0] = 0;
    return 0;
#endif
}

struct sk_handler {
    cef_resource_handler_t cef;
    atomic_uint refs;
    pthread_mutex_t lock;
    struct sk_request request;
    size_t header_len, position;
    struct sk_response response;
    cef_callback_t *callback;
    int fd, canceled, started;
    int queued; /* Guarded by sk_workers_lock, like next. */
    int browser_id;
    int64_t deadline;
    sk_web_untrusted_denied_fn denied;
    uint64_t request_id;
    struct sk_handler *next;
};
static pthread_mutex_t sk_workers_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t sk_workers_done = PTHREAD_COND_INITIALIZER;
/* Active handlers each own a worker thread; a nonempty queue implies all
 * SK_JOBS slots are busy, and finishing workers adopt the queue head. */
static struct sk_handler *sk_workers, *sk_queue_head, *sk_queue_tail;
static unsigned sk_worker_count, sk_queue_count;
static int sk_stopping;

static void sk_release_arg(cef_base_ref_counted_t *base) { if (base) base->release(base); }
static void CEF_CALLBACK sk_add_ref(cef_base_ref_counted_t *base) {
    struct sk_handler *h = (struct sk_handler *)base;
    atomic_fetch_add_explicit(&h->refs, 1, memory_order_relaxed);
}
static int CEF_CALLBACK sk_release(cef_base_ref_counted_t *base) {
    struct sk_handler *h = (struct sk_handler *)base;
    if (atomic_fetch_sub_explicit(&h->refs, 1, memory_order_acq_rel) != 1) return 0;
    sk_request_free(&h->request); free(h->response.headers); free(h->response.body);
    pthread_mutex_destroy(&h->lock); free(h);
    return 1;
}
static int CEF_CALLBACK sk_has_one_ref(cef_base_ref_counted_t *base) {
    return atomic_load_explicit(&((struct sk_handler *)base)->refs, memory_order_acquire) == 1;
}
static int CEF_CALLBACK sk_has_ref(cef_base_ref_counted_t *base) {
    return atomic_load_explicit(&((struct sk_handler *)base)->refs, memory_order_acquire) != 0;
}

/* Caller holds sk_workers_lock. */
static void sk_unqueue(struct sk_handler *h) {
    struct sk_handler *prev = NULL;
    for (struct sk_handler *i = sk_queue_head; i; prev = i, i = i->next) {
        if (i != h) continue;
        if (prev) prev->next = h->next; else sk_queue_head = h->next;
        if (sk_queue_tail == h) sk_queue_tail = prev;
        break;
    }
    h->next = NULL; h->queued = 0; --sk_queue_count;
}

static void CEF_CALLBACK sk_cancel(cef_resource_handler_t *self) {
    struct sk_handler *h = (struct sk_handler *)self;
    pthread_mutex_lock(&sk_workers_lock);
    /* A queued request has no worker yet, so its queue reference ends here. */
    int dequeued = h->queued;
    if (dequeued) sk_unqueue(h);
    pthread_mutex_lock(&h->lock);
    h->canceled = 1;
    /* The worker owns close(), avoiding fd reuse while its poll is in flight. */
    if (h->fd >= 0) shutdown(h->fd, SHUT_RDWR);
    cef_callback_t *callback = h->callback; h->callback = NULL;
    pthread_mutex_unlock(&h->lock);
    if (dequeued) pthread_cond_broadcast(&sk_workers_done);
    pthread_mutex_unlock(&sk_workers_lock);
    if (callback) sk_release_arg(&callback->base);
    if (dequeued) sk_release(&h->cef.base);
}

static int sk_send_request(int fd, struct sk_handler *h, uint32_t budget_ms, int64_t deadline) {
    struct sk_request *q = &h->request;
    struct sk_wire_request w = {SK_MAGIC, (uint32_t)strlen(q->url), (uint32_t)strlen(q->method),
        (uint32_t)h->header_len, (uint32_t)q->body_len, (uint32_t)q->allow_private,
        (uint32_t)strlen(q->initiator), (uint32_t)q->navigation, (uint32_t)q->resource_type, budget_ms,
        (uint32_t)q->user_activation, (uint32_t)strlen(q->fetch_initiator)};
    return sk_io(fd, &w, sizeof(w), 1, deadline) && sk_io(fd, q->url, w.url_len, 1, deadline) &&
        sk_io(fd, q->method, w.method_len, 1, deadline) &&
        sk_io(fd, q->initiator, w.initiator_len, 1, deadline) &&
        sk_io(fd, q->fetch_initiator, w.fetch_initiator_len, 1, deadline) &&
        sk_io(fd, q->headers, w.headers_len, 1, deadline) && sk_io(fd, q->body, w.body_len, 1, deadline);
}

static int sk_response_headers_valid(struct sk_response *r) {
    for (size_t at = 0; at < r->headers_len;) {
        const char *name = r->headers + at;
        const char *end = memchr(name, 0, r->headers_len - at);
        if (!end || !sk_token(name, (size_t)(end - name)) || sk_transport_header(name)) return 0;
        at += (size_t)(end - name) + 1;
        const char *value = r->headers + at;
        end = memchr(value, 0, r->headers_len - at);
        if (!end || !sk_value(value)) return 0;
        at += (size_t)(end - value) + 1;
    }
    return 1;
}

static void sk_serve(struct sk_handler *h) {
    struct sk_response r = {.reason = SK_WEB_UNTRUSTED_BROKER_FAILURE};
    int64_t deadline = h->deadline, now = sk_now_ms();
    int fd = -1, canceled;
    /* Too little budget left after queueing for the job to answer in time. */
    if (now < 0 || deadline - now <= SK_REPLY_MARGIN_MS) { r.reason = SK_WEB_UNTRUSTED_TIMEOUT; goto done; }
    fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    if (fd < 0) goto done;
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    /* start/stop are lifecycle operations, not concurrent with new factories. */
    memcpy(address.sun_path, sk_socket_path, sizeof(address.sun_path));
    if (connect(fd, (struct sockaddr *)&address, sizeof(address))) goto done;
    struct ucred cred; socklen_t len = sizeof(cred);
    if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &len) ||
        cred.uid != getuid() || cred.pid != sk_broker_pid) goto done;
    /* Publish only after connect: shutdown on an unconnected socket does not
     * prevent a later connect, so early cancellation must be checked here. */
    pthread_mutex_lock(&h->lock);
    h->fd = fd;
    canceled = h->canceled;
    pthread_mutex_unlock(&h->lock);
    if (canceled || !sk_send_request(fd, h, (uint32_t)(deadline - now), deadline)) goto done;
    struct sk_wire_response w;
    if (!sk_io(fd, &w, sizeof(w), 0, deadline) || w.magic != SK_MAGIC ||
        w.reason > SK_WEB_UNTRUSTED_TIMEOUT ||
        w.headers_len > SK_HEADER_CAP || w.body_len > SK_BODY_CAP ||
        (w.reason && (w.headers_len || w.body_len)) ||
        (!w.reason && (w.status < 200 || w.status > 599 || w.status == 206))) goto done;
    if (w.reason) { r.reason = (int)w.reason; goto done; }
    r.headers = malloc((size_t)w.headers_len + 1);
    r.body = w.body_len ? malloc(w.body_len) : NULL;
    if (!r.headers || (w.body_len && !r.body) ||
        !sk_io(fd, r.headers, w.headers_len, 0, deadline) ||
        !sk_io(fd, r.body, w.body_len, 0, deadline)) goto done;
    r.headers[w.headers_len] = 0;
    r.headers_len = w.headers_len; r.body_len = w.body_len;
    if (!sk_response_headers_valid(&r)) goto done;
    r.reason = 0; r.status = (int)w.status;
done:
    /* The job's alarm backstop never precedes this deadline, so an IO failure
     * past it is the deadline's, not a broker fault. */
    if (r.reason == SK_WEB_UNTRUSTED_BROKER_FAILURE && sk_now_ms() >= deadline)
        r.reason = SK_WEB_UNTRUSTED_TIMEOUT;
    pthread_mutex_lock(&h->lock);
    h->fd = -1;
    if (fd >= 0) close(fd);
    h->response = r;
    cef_callback_t *callback = h->callback; h->callback = NULL;
    canceled = h->canceled;
    pthread_mutex_unlock(&h->lock);
    if (!canceled && r.reason && h->denied) h->denied(h->browser_id, h->request_id, r.reason, 0);
    if (callback) {
        if (!canceled) callback->cont(callback);
        sk_release_arg(&callback->base);
    }
}

/* Serves its handler, then adopts queued ones FIFO. Every active deadline
 * precedes every queued one, and serving ends by its deadline, so a queued
 * request is reached no later than about its own deadline. */
static void *sk_worker(void *user) {
    struct sk_handler *h = user;
    for (;;) {
        sk_serve(h);
        pthread_mutex_lock(&sk_workers_lock);
        struct sk_handler **link = &sk_workers;
        while (*link != h) link = &(*link)->next;
        *link = h->next;
        struct sk_handler *next = sk_queue_head;
        if (next) {
            sk_unqueue(next);
            next->next = sk_workers; sk_workers = next;
        } else --sk_worker_count;
        sk_release(&h->cef.base);
        pthread_cond_broadcast(&sk_workers_done);
        pthread_mutex_unlock(&sk_workers_lock);
        if (!next) return NULL;
        h = next;
    }
}

static int CEF_CALLBACK sk_open(cef_resource_handler_t *self, cef_request_t *request,
                               int *handle_request, cef_callback_t *callback) {
    struct sk_handler *h = (struct sk_handler *)self;
    sk_release_arg(request ? &request->base : NULL);
    *handle_request = 1;
    pthread_mutex_lock(&sk_workers_lock);
    pthread_mutex_lock(&h->lock);
    int reason = h->response.reason;
    int canceled = h->canceled;
    int refused = h->started || canceled || reason || sk_stopping || !sk_broker_pid ?
        SK_WEB_UNTRUSTED_BROKER_FAILURE :
        sk_worker_count >= SK_JOBS && sk_queue_count >= SK_QUEUE_CAP ? SK_WEB_UNTRUSTED_QUEUE_FULL : 0;
    if (refused == SK_WEB_UNTRUSTED_QUEUE_FULL) h->response.reason = refused;
    if (refused) {
        pthread_mutex_unlock(&h->lock); pthread_mutex_unlock(&sk_workers_lock);
        sk_release_arg(callback ? &callback->base : NULL);
        if (!reason && !canceled && h->denied) h->denied(h->browser_id, h->request_id, refused, 1);
        return 0;
    }
    if (!callback) { pthread_mutex_unlock(&h->lock); pthread_mutex_unlock(&sk_workers_lock); return 0; }
    h->started = 1; h->callback = callback;
    h->deadline = sk_now_ms() + SK_TIMEOUT_MS;
    sk_add_ref(&h->cef.base);
    if (sk_worker_count >= SK_JOBS) {
        h->queued = 1; h->next = NULL;
        if (sk_queue_tail) sk_queue_tail->next = h; else sk_queue_head = h;
        sk_queue_tail = h; ++sk_queue_count;
        *handle_request = 0;
        pthread_mutex_unlock(&h->lock); pthread_mutex_unlock(&sk_workers_lock);
        return 1;
    }
    h->next = sk_workers; sk_workers = h; ++sk_worker_count;
    pthread_t thread;
    pthread_attr_t attr;
    int attr_ok = pthread_attr_init(&attr) == 0;
    int ok = attr_ok && !pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED) &&
        !pthread_create(&thread, &attr, sk_worker, h);
    if (attr_ok) pthread_attr_destroy(&attr);
    if (!ok) {
        sk_workers = h->next; --sk_worker_count; h->callback = NULL;
        pthread_mutex_unlock(&h->lock); pthread_mutex_unlock(&sk_workers_lock);
        sk_release_arg(&callback->base);
        if (h->denied) h->denied(h->browser_id, h->request_id, SK_WEB_UNTRUSTED_BROKER_FAILURE, 1);
        sk_release(&h->cef.base);
        return 0;
    }
    *handle_request = 0;
    pthread_mutex_unlock(&h->lock); pthread_mutex_unlock(&sk_workers_lock);
    return 1;
}

static int sk_cef_string(const char *value, size_t len, cef_string_t *out) {
    return cef_string_utf8_to_utf16(value, len, out);
}

static void CEF_CALLBACK sk_get_headers(cef_resource_handler_t *self, cef_response_t *response,
                                      int64_t *length, cef_string_t *redirect) {
    (void)redirect;
    struct sk_handler *h = (struct sk_handler *)self;
    struct sk_response *r = &h->response;
    *length = 0;
    if (r->reason) { response->set_error(response, ERR_FAILED); goto done; }
    cef_string_multimap_t map = cef_string_multimap_alloc();
    if (!map) { response->set_error(response, ERR_FAILED); goto done; }
    int ok = 1;
    for (size_t at = 0; at < r->headers_len && ok;) {
        const char *name = r->headers + at; at += strlen(name) + 1;
        const char *value = r->headers + at; at += strlen(value) + 1;
        cef_string_t k = {0}, v = {0};
        ok = sk_cef_string(name, strlen(name), &k) && sk_cef_string(value, strlen(value), &v) &&
            cef_string_multimap_append(map, &k, &v);
        if (ok && !strcasecmp(name, "content-type")) {
            size_t n = strcspn(value, ";");
            while (n && (value[n - 1] == ' ' || value[n - 1] == '\t')) --n;
            cef_string_t mime = {0};
            if (sk_cef_string(value, n, &mime)) response->set_mime_type(response, &mime);
            else ok = 0;
            cef_string_clear(&mime);
            /* CEF's explicit charset field is separate from the header map. */
            const char *param = strchr(value, ';');
            while (param && ok) {
                ++param;
                while (*param == ' ' || *param == '\t') ++param;
                const char *end = strchr(param, ';');
                size_t size = end ? (size_t)(end - param) : strlen(param);
                if (size >= 8 && !strncasecmp(param, "charset=", 8)) {
                    const char *cs = param + 8;
                    size_t len = size - 8;
                    while (len && (*cs == ' ' || *cs == '\t')) { ++cs; --len; }
                    while (len && (cs[len - 1] == ' ' || cs[len - 1] == '\t')) --len;
                    if (len >= 2 && cs[0] == '"' && cs[len - 1] == '"') { ++cs; len -= 2; }
                    cef_string_t charset = {0};
                    if (sk_cef_string(cs, len, &charset)) response->set_charset(response, &charset);
                    else ok = 0;
                    cef_string_clear(&charset);
                    break;
                }
                param = end;
            }
        }
        cef_string_clear(&k); cef_string_clear(&v);
    }
    char text[32];
    int n = snprintf(text, sizeof(text), "%zu", r->body_len);
    cef_string_t k = {0}, v = {0};
    if (ok) ok = n > 0 && sk_cef_string("Content-Length", 14, &k) &&
        sk_cef_string(text, (size_t)n, &v) && cef_string_multimap_append(map, &k, &v);
    cef_string_clear(&k); cef_string_clear(&v);
    if (ok) {
        response->set_status(response, r->status);
        response->set_header_map(response, map);
        *length = (int64_t)r->body_len;
    } else response->set_error(response, ERR_FAILED);
    cef_string_multimap_free(map);
done:
    sk_release_arg(&response->base);
}

static int CEF_CALLBACK sk_read(cef_resource_handler_t *self, void *out, int wanted,
                               int *count, cef_resource_read_callback_t *callback) {
    struct sk_handler *h = (struct sk_handler *)self;
    sk_release_arg(callback ? &callback->base : NULL);
    *count = 0;
    if (wanted <= 0 || h->position >= h->response.body_len || h->response.reason) return 0;
    size_t n = h->response.body_len - h->position;
    if (n > (size_t)wanted) n = (size_t)wanted;
    memcpy(out, h->response.body + h->position, n);
    h->position += n; *count = (int)n;
    return 1;
}

static int CEF_CALLBACK sk_skip(cef_resource_handler_t *self, int64_t wanted,
                               int64_t *count, cef_resource_skip_callback_t *callback) {
    (void)self; (void)wanted;
    sk_release_arg(callback ? &callback->base : NULL);
    *count = ERR_REQUEST_RANGE_NOT_SATISFIABLE;
    return 0;
}

static char *sk_utf8(const cef_string_t *value, size_t cap) {
    if (!value || value->length > cap) return NULL;
    cef_string_utf8_t s = {0};
    if (!cef_string_utf16_to_utf8(value->str, value->length, &s)) {
        cef_string_utf8_clear(&s);
        return NULL;
    }
    char *result = NULL;
    if (s.length <= cap && (!s.length || !memchr(s.str, 0, s.length))) {
        result = malloc(s.length + 1);
        if (result) { if (s.length) memcpy(result, s.str, s.length); result[s.length] = 0; }
    }
    cef_string_utf8_clear(&s);
    return result;
}

struct sk_request_handler {
    cef_resource_request_handler_t cef;
    atomic_uint refs;
    char *initiator;
    int navigation, resource_type;
};

/* UI-thread navigation callbacks precede IO-thread resource callbacks. CEF's
 * navigation request has identifier 0, so match its browser, URL and type. */
static pthread_mutex_t sk_navigation_lock = PTHREAD_MUTEX_INITIALIZER;
static struct {
    char url[SK_URL_CAP + 1], initiator[512];
    int browser_id, resource_type, user_gesture;
    int64_t deadline;
} sk_navigations[SK_QUEUE_CAP];

void sk_web_untrusted_navigation(cef_request_t *request, cef_frame_t *frame, int browser_id, int user_gesture) {
    if (!request || !request->get_url || !request->get_resource_type || browser_id <= 0) return;
    cef_string_userfree_t raw = request->get_url(request);
    char *url = sk_utf8(raw, SK_URL_CAP);
    if (raw) cef_string_userfree_free(raw);
    if (!url) return;
    int type = request->get_resource_type(request);
    char initiator[512] = "";
    cef_frame_t *current = frame;
    int owned = 0;
    for (unsigned depth = 0; current && depth < 32; ++depth) {
        raw = current->get_url ? current->get_url(current) : NULL;
        char *source = raw ? sk_utf8(raw, SK_URL_CAP) : NULL;
        if (raw) cef_string_userfree_free(raw);
        struct sk_origin origin;
        if (source && sk_parse_url(source, &origin, 0)) {
            size_t n = strcspn(source + (origin.tls ? 8 : 7), "/?#") + (origin.tls ? 8 : 7);
            if (n < sizeof(initiator)) { memcpy(initiator, source, n); initiator[n] = 0; }
            free(source);
            break;
        }
        int inherited = !source || !*source || !strcmp(source, "about:blank") || !strcmp(source, "about:srcdoc");
        free(source);
        if (!inherited) { strcpy(initiator, "null"); break; }
        cef_frame_t *parent = current->get_parent ? current->get_parent(current) : NULL;
        if (owned) sk_release_arg(&current->base);
        current = parent; owned = 1;
    }
    if (owned && current) sk_release_arg(&current->base);
    if (type == RT_MAIN_FRAME && request->get_transition_type &&
        (request->get_transition_type(request) & TT_SOURCE_MASK) == TT_EXPLICIT)
        initiator[0] = 0;
    int64_t now = sk_now_ms();
    pthread_mutex_lock(&sk_navigation_lock);
    unsigned slot = 0;
    for (unsigned i = 0; i < SK_QUEUE_CAP; ++i) {
        if (sk_navigations[i].browser_id == browser_id && sk_navigations[i].resource_type == type &&
            !strcmp(sk_navigations[i].url, url)) { slot = i; break; }
        if (sk_navigations[i].deadline < sk_navigations[slot].deadline) slot = i;
    }
    memcpy(sk_navigations[slot].url, url, strlen(url) + 1);
    memcpy(sk_navigations[slot].initiator, initiator, strlen(initiator) + 1);
    sk_navigations[slot].browser_id = browser_id;
    sk_navigations[slot].resource_type = type;
    sk_navigations[slot].user_gesture = user_gesture != 0;
    sk_navigations[slot].deadline = now + SK_TIMEOUT_MS;
    pthread_mutex_unlock(&sk_navigation_lock);
    free(url);
}

static int sk_navigation_metadata(struct sk_request *r, int browser_id) {
    if (!r->navigation) {
        r->fetch_initiator = strdup(r->initiator);
        return r->fetch_initiator != NULL;
    }
    char initiator[512] = "null";
    int active = 0, found = 0;
    int64_t now = sk_now_ms();
    pthread_mutex_lock(&sk_navigation_lock);
    for (unsigned i = 0; i < SK_QUEUE_CAP; ++i) {
        if (sk_navigations[i].browser_id == browser_id && sk_navigations[i].deadline > now &&
            sk_navigations[i].resource_type == r->resource_type && !strcmp(sk_navigations[i].url, r->url)) {
            active = sk_navigations[i].user_gesture;
            memcpy(initiator, sk_navigations[i].initiator, sizeof(initiator));
            found = 1;
            break;
        }
    }
    pthread_mutex_unlock(&sk_navigation_lock);
    /* CEF reports "null" even for browser-initiated navigations. */
    if (r->resource_type == RT_MAIN_FRAME && (found ? !*initiator : !*r->initiator)) {
        initiator[0] = 0;
        active = 1;
    }
    /* Presentation metadata never replaces the CEF initiator used by policy. */
    r->fetch_initiator = strdup(found || active ? initiator : r->initiator);
    r->user_activation = active;
    return r->fetch_initiator != NULL;
}

static void CEF_CALLBACK sk_request_add_ref(cef_base_ref_counted_t *base) {
    atomic_fetch_add_explicit(&((struct sk_request_handler *)base)->refs, 1, memory_order_relaxed);
}
static int CEF_CALLBACK sk_request_release(cef_base_ref_counted_t *base) {
    struct sk_request_handler *h = (struct sk_request_handler *)base;
    if (atomic_fetch_sub_explicit(&h->refs, 1, memory_order_acq_rel) != 1) return 0;
    free(h->initiator); free(h);
    return 1;
}
static int CEF_CALLBACK sk_request_has_one_ref(cef_base_ref_counted_t *base) {
    return atomic_load_explicit(&((struct sk_request_handler *)base)->refs, memory_order_acquire) == 1;
}
static int CEF_CALLBACK sk_request_has_ref(cef_base_ref_counted_t *base) {
    return atomic_load_explicit(&((struct sk_request_handler *)base)->refs, memory_order_acquire) != 0;
}

cef_resource_request_handler_t *sk_web_untrusted_request_handler(
    const cef_resource_request_handler_t *callbacks, cef_request_t *request,
    int is_navigation, int is_download, const cef_string_t *request_initiator) {
    if (!callbacks) return NULL;
    struct sk_request_handler *h = calloc(1, sizeof(*h));
    if (!h) return NULL;
    h->initiator = request_initiator ? sk_utf8(request_initiator, SK_URL_CAP) : strdup("");
    if (!h->initiator) { free(h); return NULL; }
    h->cef = *callbacks;
    h->cef.base = (cef_base_ref_counted_t){sizeof(h->cef), sk_request_add_ref, sk_request_release,
        sk_request_has_one_ref, sk_request_has_ref};
    atomic_init(&h->refs, 1);
    h->navigation = is_navigation;
    h->resource_type = !is_download && request && request->get_resource_type ?
        (int)request->get_resource_type(request) : -1;
    return &h->cef;
}

static int sk_copy_request(struct sk_handler *h, cef_request_t *request) {
    struct sk_request *r = &h->request;
    cef_string_userfree_t url = request->get_url(request), method = request->get_method(request);
    r->url = sk_utf8(url, SK_URL_CAP); r->method = sk_utf8(method, 4);
    cef_string_userfree_free(url); cef_string_userfree_free(method);
    if (!r->url || !r->method) return 0;
    cef_string_multimap_t map = cef_string_multimap_alloc();
    r->headers = malloc(SK_HEADER_CAP);
    if (!map || !r->headers) { if (map) cef_string_multimap_free(map); return 0; }
    request->get_header_map(request, map);
    int ok = 1;
    size_t entries = cef_string_multimap_size(map);
    if (entries > SK_HEADER_FIELDS) ok = 0;
    for (size_t i = 0; i < entries && ok; ++i) {
        cef_string_t key = {0}, value = {0};
        ok = cef_string_multimap_key(map, i, &key) && cef_string_multimap_value(map, i, &value);
        char *k = ok ? sk_utf8(&key, SK_HEADER_CAP) : NULL;
        char *v = ok ? sk_utf8(&value, SK_HEADER_CAP) : NULL;
        cef_string_clear(&key); cef_string_clear(&value);
        if (!k || !v || strlen(k) + strlen(v) + 2 > SK_HEADER_CAP - h->header_len) ok = 0;
        if (ok) {
            size_t n = strlen(k) + 1; memcpy(r->headers + h->header_len, k, n); h->header_len += n;
            n = strlen(v) + 1; memcpy(r->headers + h->header_len, v, n); h->header_len += n;
        }
        free(k); free(v);
    }
    cef_string_multimap_free(map);
    if (!ok) return 0;
    cef_post_data_t *post = request->get_post_data(request);
    if (post) {
        size_t count = post->get_element_count(post);
        if (post->has_excluded_elements(post) || count > 1024 || strcmp(r->method, "POST")) ok = 0;
        cef_post_data_element_t **elements = ok && count ? calloc(count, sizeof(*elements)) : NULL;
        if (ok && count && !elements) ok = 0;
        if (ok && count) {
            size_t received = count;
            post->get_elements(post, &received, elements);
            if (received > count) received = count;
            if (received != count) ok = 0;
            for (size_t i = 0; i < received; ++i) {
                cef_post_data_element_t *e = elements[i];
                if (!e) { ok = 0; continue; }
                if (ok) {
                    cef_postdataelement_type_t type = e->get_type(e);
                    size_t n = type == PDE_TYPE_BYTES ? e->get_bytes_count(e) : 0;
                    /* EMPTY is how CEF surfaces a data-pipe part (Blob, File, stream): never "no bytes". */
                    if (type != PDE_TYPE_BYTES || n > SK_UPLOAD_CAP - r->body_len) ok = 0;
                    else if (n) {
                        void *p = realloc(r->body, r->body_len + n);
                        if (!p) ok = 0;
                        else {
                            r->body = p;
                            if (e->get_bytes(e, n, r->body + r->body_len) != n) ok = 0;
                            else r->body_len += n;
                        }
                    }
                }
                sk_release_arg(&e->base);
            }
        }
        free(elements); sk_release_arg(&post->base);
    }
    struct sk_origin target;
    return ok && sk_navigation_metadata(r, h->browser_id) && sk_validate(r, h->header_len, &target);
}

cef_resource_handler_t *sk_web_untrusted_resource(cef_request_t *request,
                                                const cef_resource_request_handler_t *metadata, int allow_private,
                                                sk_web_untrusted_denied_fn denied, int browser_id) {
    uint64_t request_id = request && request->get_identifier ? request->get_identifier(request) : 0;
    struct sk_handler *h = calloc(1, sizeof(*h));
    if (!h || pthread_mutex_init(&h->lock, NULL)) {
        free(h); if (denied) denied(browser_id, request_id, SK_WEB_UNTRUSTED_BROKER_FAILURE, 1); return NULL;
    }
    atomic_init(&h->refs, 1); h->fd = -1; h->request_id = request_id;
    h->request.allow_private = allow_private;
    h->denied = denied; h->browser_id = browser_id;
    h->cef.base.size = sizeof(h->cef);
    h->cef.base.add_ref = sk_add_ref; h->cef.base.release = sk_release;
    h->cef.base.has_one_ref = sk_has_one_ref; h->cef.base.has_at_least_one_ref = sk_has_ref;
    h->cef.open = sk_open; h->cef.get_response_headers = sk_get_headers;
    h->cef.read = sk_read; h->cef.skip = sk_skip; h->cef.cancel = sk_cancel;
    int trusted = metadata && metadata->base.release == sk_request_release;
    if (trusted) {
        const struct sk_request_handler *m = (const struct sk_request_handler *)metadata;
        h->request.initiator = strdup(m->initiator);
        h->request.navigation = m->navigation; h->request.resource_type = m->resource_type;
        trusted = request && request->get_resource_type &&
            (int)request->get_resource_type(request) == m->resource_type;
    }
    if (!trusted || !sk_copy_request(h, request)) h->response.reason = SK_WEB_UNTRUSTED_UNSUPPORTED;
    else if (!sk_broker_pid) h->response.reason = SK_WEB_UNTRUSTED_BROKER_FAILURE;
    if (h->response.reason && denied) denied(browser_id, request_id, h->response.reason, 1);
    return &h->cef;
}

void sk_web_untrusted_stop(void) {
    pthread_mutex_lock(&sk_workers_lock);
    sk_stopping = 1;
    /* Keep callbacks outside the list lock: releasing one may re-enter CEF. */
    struct sk_handler *pending[SK_JOBS + SK_QUEUE_CAP];
    unsigned count = 0;
    for (struct sk_handler *h = sk_workers; h; h = h->next) {
        sk_add_ref(&h->cef.base); pending[count++] = h;
    }
    for (struct sk_handler *h = sk_queue_head; h; h = h->next) {
        sk_add_ref(&h->cef.base); pending[count++] = h;
    }
    pthread_mutex_unlock(&sk_workers_lock);
    for (unsigned i = 0; i < count; ++i) { sk_cancel(&pending[i]->cef); sk_release(&pending[i]->cef.base); }
    if (sk_lifetime_fd >= 0) { close(sk_lifetime_fd); sk_lifetime_fd = -1; }
    if (sk_broker_pid > 0) {
        kill(sk_broker_pid, SIGTERM);
        int64_t deadline = sk_now_ms() + SK_STOP_GRACE_MS;
        int reaped = 0;
        do {
            pid_t result = waitpid(sk_broker_pid, NULL, WNOHANG);
            if (result == sk_broker_pid || (result < 0 && errno == ECHILD)) { reaped = 1; break; }
            if (result < 0 && errno != EINTR) break;
            struct timespec pause = {0, 10000000}; nanosleep(&pause, NULL);
        } while (sk_now_ms() < deadline);
        if (!reaped) {
            kill(-sk_broker_pid, SIGKILL);
            kill(sk_broker_pid, SIGKILL);
            while (waitpid(sk_broker_pid, NULL, 0) < 0 && errno == EINTR) {}
        }
    }
    pthread_mutex_lock(&sk_workers_lock);
    while (sk_worker_count || sk_queue_count) pthread_cond_wait(&sk_workers_done, &sk_workers_lock);
    pthread_mutex_unlock(&sk_workers_lock);
    sk_broker_pid = 0;
    pthread_mutex_lock(&sk_navigation_lock);
    memset(sk_navigations, 0, sizeof(sk_navigations));
    pthread_mutex_unlock(&sk_navigation_lock);
    if (sk_socket_path[0]) unlink(sk_socket_path);
    sk_socket_path[0] = 0;
    memset(&sk_proxy, 0, sizeof(sk_proxy));
    /* Restart is supported only at the same pre-thread lifecycle boundary. */
    pthread_mutex_lock(&sk_workers_lock);
    sk_stopping = 0;
    pthread_mutex_unlock(&sk_workers_lock);
}

#else
int sk_web_untrusted_job_landlock(void) { return 0; }
int sk_web_untrusted_core_limit(void) { return 0; }
int sk_web_untrusted_nondumpable(void) { return 0; }
int sk_web_untrusted_no_core(void) { return 0; }
int sk_web_untrusted_start(const char *private_dir, const char *proxy) { (void)private_dir; (void)proxy; return 0; }
int sk_web_untrusted_confine(void) { return 0; }
void sk_web_untrusted_stop(void) {}
void sk_web_untrusted_navigation(cef_request_t *request, cef_frame_t *frame, int browser_id, int user_gesture) {
    (void)request; (void)frame; (void)browser_id; (void)user_gesture;
}
cef_resource_request_handler_t *sk_web_untrusted_request_handler(
    const cef_resource_request_handler_t *callbacks, cef_request_t *request,
    int is_navigation, int is_download, const cef_string_t *request_initiator) {
    (void)callbacks; (void)request; (void)is_navigation; (void)is_download; (void)request_initiator;
    return NULL;
}
cef_resource_handler_t *sk_web_untrusted_resource(cef_request_t *request,
                                                const cef_resource_request_handler_t *metadata, int allow_private,
                                                sk_web_untrusted_denied_fn denied, int browser_id) {
    (void)request; (void)metadata; (void)allow_private;
    if (denied) denied(browser_id, 0, SK_WEB_UNTRUSTED_BROKER_FAILURE, 1);
    return NULL;
}
#endif
