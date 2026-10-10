/* Native tests, no CEF bootstrap and no public-network traffic; `zig build
 * test-web-untrusted-native` runs them. Scratch directories go under $TMPDIR
 * (default /tmp), which must stay short enough for a sockaddr_un path. By hand:
 * cc -std=c11 -Wall -Wextra -Werror -I/usr/include/cef \
 *   dist/test-web-untrusted.c -L/usr/lib/cef -Wl,-rpath,/usr/lib/cef \
 *   -Wl,--export-dynamic -lcef -ldl -lpthread -lz -lssl -lcrypto -o "$OUT/test-web-untrusted"
 * "$OUT/test-web-untrusted"
 * Portable branch: add -DSK_TEST_PORTABLE; no link libraries are needed.
 * Dependency refusal: build this file with -shared -fPIC -DSK_TEST_MISSING_CURL
 * as "$OUT/libcurl.so.4", then run with LD_LIBRARY_PATH="$OUT" and
 * --dependency-refusal. The fake library is never a production dependency.
 */
#ifdef SK_TEST_MISSING_CURL
int sk_missing_curl_placeholder(void) { return 0; }
#else
#ifdef SK_TEST_PORTABLE
#include "../vendor/web_untrusted.h"
#undef __linux__
#else
/* Every socket a routed job's curl asks for, refused ones included. */
static void observe_socket(int purpose, const void *address);
#define SK_OPEN_SOCKET_OBSERVE(purpose, address) observe_socket((int)(purpose), (address))
#endif
#include "../vendor/web_untrusted.c"
#ifdef SK_TEST_PORTABLE
#include <assert.h>
#include <stdio.h>
static int stub_reason;
static void stub_denied(int id, uint64_t request_id, int reason, int unsent) {
    assert(id == 17 && !request_id && unsent); stub_reason = reason;
}
int main(void) {
    assert(!sk_web_untrusted_job_landlock() && !sk_web_untrusted_no_core());
    assert(!sk_web_untrusted_core_limit() && !sk_web_untrusted_nondumpable());
    assert(!sk_web_untrusted_start("/unused", NULL) && !sk_web_untrusted_confine());
    assert(!sk_web_untrusted_request_handler(NULL, NULL, 0, 0, NULL));
    assert(!sk_web_untrusted_resource(NULL, NULL, 1, stub_denied, 17));
    assert(stub_reason == SK_WEB_UNTRUSTED_BROKER_FAILURE);
    sk_web_untrusted_stop();
    puts("PASS portable stubs fail closed");
    return 0;
}
#else
#include <assert.h>
#include <sys/mman.h>
#include <zlib.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>
#include <netdb.h>

/* A direct exit prevents crash handlers from delaying a failed native rig. */
#undef assert
#define assert(condition) do { if (!(condition)) { \
    dprintf(STDERR_FILENO, "%s:%d: assertion failed: %s\n", __FILE__, __LINE__, #condition); \
    syscall(SYS_exit_group, 1); } } while (0)

static void pause_ms(unsigned ms) {
    struct timespec t = {(time_t)(ms / 1000), (long)(ms % 1000) * 1000000};
    nanosleep(&t, NULL);
}

static void child_ok(pid_t child) {
    int status;
    assert(waitpid(child, &status, 0) == child);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
}

static void addresses(void) {
    const char *private4[] = {"0.0.0.0", "0.1.2.3", "10.0.0.1", "127.0.0.1", "127.255.255.255",
        "100.64.0.1", "100.127.255.255", "169.254.1.1", "172.16.0.1", "172.31.255.255",
        "192.168.0.1", "192.0.0.9", "192.0.2.1", "192.88.99.1", "198.18.0.1", "198.19.1.1",
        "198.51.100.1", "203.0.113.1", "224.0.0.1", "240.0.0.1", "255.255.255.255"};
    const char *public4[] = {"1.1.1.1", "8.8.8.8", "100.63.255.255", "100.128.0.1", "172.15.0.1", "172.32.0.1"};
    struct sockaddr_in a = {.sin_family = AF_INET};
    for (size_t i = 0; i < sizeof(private4) / sizeof(*private4); ++i) {
        assert(inet_pton(AF_INET, private4[i], &a.sin_addr) == 1);
        assert(!sk_public_address((struct sockaddr *)&a));
    }
    for (size_t i = 0; i < sizeof(public4) / sizeof(*public4); ++i) {
        assert(inet_pton(AF_INET, public4[i], &a.sin_addr) == 1);
        assert(sk_public_address((struct sockaddr *)&a));
    }
    const char *private6[] = {"::", "::1", "::127.0.0.1", "::ffff:127.0.0.1", "::ffff:10.0.0.1",
        "::ffff:100.64.0.1", "::ffff:169.254.1.1", "fc00::1", "fdff::1", "fe80::1", "ff02::1",
        "64:ff9b::7f00:1", "100::1", "2001::1", "2001:2::1", "2001:20::1", "2001:db8::1",
        "2002:7f00:1::1", "3fff::1"};
    const char *public6[] = {"2606:4700:4700::1111", "2001:4860:4860::8888", "::ffff:8.8.8.8"};
    struct sockaddr_in6 b = {.sin6_family = AF_INET6};
    for (size_t i = 0; i < sizeof(private6) / sizeof(*private6); ++i) {
        assert(inet_pton(AF_INET6, private6[i], &b.sin6_addr) == 1);
        assert(!sk_public_address((struct sockaddr *)&b));
    }
    for (size_t i = 0; i < sizeof(public6) / sizeof(*public6); ++i) {
        assert(inet_pton(AF_INET6, public6[i], &b.sin6_addr) == 1);
        assert(sk_public_address((struct sockaddr *)&b));
    }
    struct sk_response r = {.port = 80};
    struct curl_sockaddr c = {.family = AF_INET, .socktype = SOCK_STREAM,
        .protocol = IPPROTO_TCP, .addrlen = sizeof(a)};
    a.sin_port = htons(80); inet_pton(AF_INET, "127.0.0.1", &a.sin_addr);
    memcpy(&c.addr, &a, sizeof(a));
    assert(sk_open_socket(&r, CURLSOCKTYPE_IPCXN, &c) == CURL_SOCKET_BAD);
    assert(r.reason == SK_WEB_UNTRUSTED_PRIVATE);
    r.allow_private = 1;
    int fd = sk_open_socket(&r, CURLSOCKTYPE_IPCXN, &c);
    assert(fd >= 0); close(fd);
    ((struct sockaddr_in *)&c.addr)->sin_port = htons(81);
    assert(sk_open_socket(&r, CURLSOCKTYPE_IPCXN, &c) == CURL_SOCKET_BAD);
    puts("PASS binary IPv4/IPv6/mapped-address and actual-port checks");
}

static void set_address(struct sockaddr_storage *s, const char *text) {
    memset(s, 0, sizeof(*s));
    struct sockaddr_in *v4 = (struct sockaddr_in *)s;
    struct sockaddr_in6 *v6 = (struct sockaddr_in6 *)s;
    if (inet_pton(AF_INET, text, &v4->sin_addr) == 1) v4->sin_family = AF_INET;
    else { assert(inet_pton(AF_INET6, text, &v6->sin6_addr) == 1); v6->sin6_family = AF_INET6; }
}

/* Calls the real connect-time callback with a fresh getifaddrs() underneath. */
static void open_socket_for(const struct sockaddr *address, int allow, int *reason, int *opened) {
    struct sk_response r = {.port = 80, .allow_private = allow};
    /* curl's struct ends in a 16-byte sockaddr; its real storage fits sockaddr_in6. */
    union { struct curl_sockaddr c; unsigned char room[sizeof(struct curl_sockaddr) + sizeof(struct sockaddr_storage)]; } u;
    memset(&u, 0, sizeof(u));
    struct curl_sockaddr *c = &u.c;
    c->family = address->sa_family; c->socktype = SOCK_STREAM; c->protocol = IPPROTO_TCP;
    c->addrlen = address->sa_family == AF_INET ? sizeof(struct sockaddr_in) : sizeof(struct sockaddr_in6);
    memcpy(&c->addr, address, c->addrlen);
    if (address->sa_family == AF_INET) ((struct sockaddr_in *)&c->addr)->sin_port = htons(80);
    else ((struct sockaddr_in6 *)&c->addr)->sin6_port = htons(80);
    int fd = sk_open_socket(&r, CURLSOCKTYPE_IPCXN, c);
    *opened = fd != CURL_SOCKET_BAD; *reason = r.reason;
    if (fd >= 0) close(fd);
}

static void own_addresses(void) {
    /* Injected interface list: public addresses on this host, a v4 one also
     * reachable in mapped form, and an AF_PACKET entry that must be skipped. */
    struct sockaddr_storage own6, own4, packet, probe;
    set_address(&own6, "2606:4700::1"); set_address(&own4, "8.8.4.4");
    memset(&packet, 0, sizeof(packet)); packet.ss_family = AF_PACKET;
    struct ifaddrs n3 = {.ifa_addr = (struct sockaddr *)&own4};
    struct ifaddrs n2 = {.ifa_next = &n3, .ifa_addr = (struct sockaddr *)&packet};
    struct ifaddrs n1 = {.ifa_next = &n2, .ifa_addr = NULL};
    struct ifaddrs n0 = {.ifa_next = &n1, .ifa_addr = (struct sockaddr *)&own6};
    const char *refused[] = {"2606:4700::1", "8.8.4.4", "::ffff:8.8.4.4", "127.0.0.1", "10.0.0.1"};
    for (size_t i = 0; i < sizeof(refused) / sizeof(*refused); ++i) {
        set_address(&probe, refused[i]);
        assert(!sk_address_allowed((struct sockaddr *)&probe, 0, &n0));
        assert(sk_address_allowed((struct sockaddr *)&probe, 1, &n0));
    }
    const char *allowed[] = {"2606:4700::2", "8.8.8.8", "::ffff:8.8.8.8"};
    for (size_t i = 0; i < sizeof(allowed) / sizeof(*allowed); ++i) {
        set_address(&probe, allowed[i]);
        assert(sk_address_allowed((struct sockaddr *)&probe, 0, &n0));
    }
    set_address(&probe, "2606:4700::1");
    assert(sk_address_allowed((struct sockaddr *)&probe, 0, NULL));
    assert(sk_own_address((struct sockaddr *)&packet, NULL)); /* Unknown family fails closed. */
    puts("PASS own-address classifier with an injected interface list (v4, v6, mapped, skipped entries)");

    struct ifaddrs *list = NULL;
    assert(!getifaddrs(&list));
    char text[INET6_ADDRSTRLEN] = "";
    for (struct ifaddrs *i = list; i && !*text; i = i->ifa_next) {
        if (!i->ifa_addr || (i->ifa_addr->sa_family != AF_INET && i->ifa_addr->sa_family != AF_INET6) ||
            !sk_public_address(i->ifa_addr)) continue;
        const void *bytes = i->ifa_addr->sa_family == AF_INET ?
            (const void *)&((struct sockaddr_in *)i->ifa_addr)->sin_addr :
            (const void *)&((struct sockaddr_in6 *)i->ifa_addr)->sin6_addr;
        assert(inet_ntop(i->ifa_addr->sa_family, bytes, text, sizeof(text)));
    }
    freeifaddrs(list);
    if (!*text) {
        puts("SKIP live own-address refusal: no interface on this host carries a public-classified address");
        return;
    }
    set_address(&probe, text);
    int reason, opened;
    open_socket_for((struct sockaddr *)&probe, 0, &reason, &opened);
    assert(!opened && reason == SK_WEB_UNTRUSTED_PRIVATE);
    open_socket_for((struct sockaddr *)&probe, 1, &reason, &opened);
    assert(opened && !reason);
    printf("PASS live own-address refusal at connect time (%s) unless private addresses are allowed\n", text);
}

static void validation(void) {
    struct sk_origin o;
    const char *bad[] = {"file:///etc/passwd", "ftp://example.com/", "http://a@b/", "http://user:pass@b/",
        "http://a:0/", "http://a:080/", "http://a:+80/", "http://a:65536/", "http://a:/",
        "http://a%00b/", "http://a\\b/", "http://127.1/", "http://2130706433/", "http://0177.0.0.1/",
        "http://0x7f000001/", "http://a..b/", "http://-a/", "http://[fe80::1%25lo]/",
        "http://0x7f.0.0.1/", "http://0X7F.0.0.1/", "http://127.0x0.0.1/", "http://127.0.0.01/",
        "http://0x7f.0.0.1./", "http://127.1./", "http://a.1/", "http://a.0x1/", "http://example.0x/",
        "http://1.2.3.4.5/", "http://a../", "http://./", "http://../", "http://a-./", "http://a_b..c/"};
    for (size_t i = 0; i < sizeof(bad) / sizeof(*bad); ++i) {
        if (sk_parse_url(bad[i], &o, 0)) fprintf(stderr, "accepted: %s\n", bad[i]);
        assert(!sk_parse_url(bad[i], &o, 0));
    }
    assert(sk_parse_url("https://EXAMPLE.com:443/a?q=a#ref", &o, 0));
    assert(!strcmp(o.host, "example.com") && o.port == 443 && o.tls);
    /* Hosts Chromium accepts: underscores, one trailing dot, hex-looking DNS labels. */
    const char *good[][2] = {{"http://_dmarc.Sub_Domain.example/", "_dmarc.sub_domain.example"},
        {"http://a_./", "a_."}, {"http://example.com./x", "example.com."},
        {"http://127.0.0.1./", "127.0.0.1."}, {"http://0x7f.example.com/", "0x7f.example.com"},
        {"http://a./", "a."}};
    for (size_t i = 0; i < sizeof(good) / sizeof(*good); ++i) {
        if (!sk_parse_url(good[i][0], &o, 0)) fprintf(stderr, "refused: %s\n", good[i][0]);
        assert(sk_parse_url(good[i][0], &o, 0) && !strcmp(o.host, good[i][1]) && o.port == 80);
    }
    struct sk_origin dotted;
    assert(sk_parse_url("http://example.com.", &dotted, 1) && sk_parse_url("http://example.com", &o, 1));
    assert(!sk_same_origin(&o, &dotted));
    struct sk_request r = {.url = "https://example.com/a", .method = "POST",
        .initiator = "https://example.com", .resource_type = RT_XHR};
#define VALID(text) (r.headers = (char *)(text), sk_validate(&r, sizeof(text) - 1, &o))
    assert(VALID(""));
    assert(VALID("Origin\0https://example.com\0Content-Type\0application/json\0X-Test\0yes\0"));
    assert(!VALID("Origin\0http://example.com\0"));
    assert(!VALID("Origin\0https://example.com:444\0"));
    assert(!VALID("Origin\0https://other.example\0"));
    assert(!VALID("Origin\0null\0"));
    assert(!VALID("Origin\0https://example.com/\0"));
    assert(!VALID("Origin\0https://example.com\0Origin\0https://example.com\0"));
    r.method = "GET";
    r.initiator = "https://other.example";
    assert(!VALID("Origin\0https://other.example\0Accept\0text/html\0"));
    assert(!VALID("Origin\0https://example.com\0X-Test\0yes\0"));
    r.resource_type = RT_SCRIPT;
    assert(VALID("Origin\0https://other.example\0Accept\0text/javascript\0"));
    assert(!VALID("Origin\0https://other.example\0X-Test\0yes\0"));
    assert(!VALID("X-Test\0yes\0"));
    assert(!VALID("Content-Type\0application/json\0"));
    assert(!VALID("Upgrade-Insecure-Requests\0yes\0"));
    assert(!VALID("Upgrade-Insecure-Requests\0" "1\0"));
    assert(!VALID("Accept\0text/html\0Accept\0text/plain\0"));
    assert(VALID("Content-Type\0text/plain;charset=utf-8\0"));
    assert(!VALID("Accept\0a\r\nb\0"));
    assert(!VALID("Range\0bytes=0-2\0"));
    assert(!VALID("Connection\0Upgrade\0"));
    assert(!VALID("Authorization\0Basic secret\0"));
    assert(!VALID("Host\0attacker.example\0"));
    assert(!VALID("X-Test\0unterminated"));
    assert(!VALID("\0value\0"));
    const char navigation_accept[] = "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7";
    assert(sizeof(navigation_accept) - 1 == 135 && !sk_safelisted("Accept", navigation_accept));
    char long_accept[256] = "Accept";
    memcpy(long_accept + 7, navigation_accept, sizeof(navigation_accept));
    r.headers = long_accept;
    assert(!sk_validate(&r, 7 + sizeof(navigation_accept), &o));
    r.navigation = 1; r.resource_type = RT_MAIN_FRAME; r.initiator = "";
    assert(sk_validate(&r, 7 + sizeof(navigation_accept), &o));
    assert(VALID("Upgrade-Insecure-Requests\0" "1\0"));
    assert(!VALID("Upgrade-Insecure-Requests\0" "2\0"));
    r.resource_type = RT_XHR; assert(!VALID(""));
    r.navigation = 0; r.initiator = "null"; assert(!VALID("Origin\0https://example.com\0"));
    r.resource_type = RT_SCRIPT; assert(!VALID("Origin\0null\0"));
    r.initiator = ""; assert(!VALID(""));
    r.initiator = "file://local"; assert(!VALID(""));
    r.initiator = "https://example.com";
    assert(VALID("X-Test\0yes\0"));
    r.method = "PUT"; assert(!VALID(""));
    r.method = "HEAD"; r.body_len = 1; assert(!VALID(""));
    r.body_len = 0; r.allow_private = 2; assert(!VALID(""));
#undef VALID
    puts("PASS trusted initiator/type/navigation, 135-byte navigation Accept, author-header and Origin spoof rejection");
}

static void fetch_metadata(void) {
    struct sk_curl a;
    assert(sk_curl_load(&a));
    struct sk_origin target;
    struct sk_request q = {.url = "https://example.com/", .initiator = "https://example.com",
        .method = "GET", .resource_type = RT_SCRIPT};
    const struct { int type, navigation; const char *dest, *mode; } cases[] = {
        {RT_MAIN_FRAME, 1, "document", "navigate"}, {RT_SUB_FRAME, 1, "iframe", "navigate"},
        {RT_SCRIPT, 0, "script", "no-cors"}, {RT_STYLESHEET, 0, "style", "no-cors"},
        {RT_FONT_RESOURCE, 0, "font", "cors"}, {RT_IMAGE, 0, "image", "no-cors"},
        {RT_XHR, 0, "empty", "cors"}, {RT_SUB_RESOURCE, 0, "empty", "no-cors"}
    };
    assert(sk_parse_url(q.url, &target, 0));
    for (size_t i = 0; i < sizeof(cases) / sizeof(*cases); ++i) {
        q.resource_type = cases[i].type; q.navigation = cases[i].navigation;
        for (int active = 0; active < 2; ++active) {
            q.user_activation = active;
            struct curl_slist *headers = NULL;
            assert(sk_fetch_metadata(&a, &headers, &q, 0, &target));
            char line[128];
            snprintf(line, sizeof(line), "Sec-Fetch-Dest: %s", cases[i].dest);
            assert(headers && !strcmp(headers->data, line));
            snprintf(line, sizeof(line), "Sec-Fetch-Mode: %s", cases[i].mode);
            assert(headers->next && !strcmp(headers->next->data, line));
            assert(headers->next->next && !strcmp(headers->next->next->data, "Sec-Fetch-Site: same-origin"));
            struct curl_slist *user = headers->next->next->next;
            if (active && q.navigation) assert(user && !strcmp(user->data, "Sec-Fetch-User: ?1") && !user->next);
            else assert(!user);
            a.slist_free_all(headers);
        }
    }
    q.navigation = 0; q.resource_type = RT_SCRIPT;
    const char cors[] = "Origin\0https://example.com\0";
    struct curl_slist *headers = NULL;
    q.headers = (char *)cors;
    assert(sk_fetch_metadata(&a, &headers, &q, sizeof(cors) - 1, &target));
    assert(!strcmp(headers->next->data, "Sec-Fetch-Mode: cors"));
    a.slist_free_all(headers);
    const struct { const char *source, *url, *site; } sites[] = {
        {"", "https://example.com/", "none"}, {"null", "https://example.com/", "cross-site"},
        {"https://EXAMPLE.com:443", "https://example.com/", "same-origin"},
        {"https://example.com:444", "https://example.com/", "same-site"},
        {"http://example.com", "https://example.com/", "cross-site"},
        {"https://a.example.co.uk", "https://b.example.co.uk/", "same-site"},
        {"https://a.github.io", "https://b.github.io/", "cross-site"},
        {"https://other.com", "https://example.com/", "cross-site"},
        {"https://127.0.0.1", "https://127.0.0.2/", "cross-site"},
        {"https://[::1]:444", "https://[::1]/", "same-site"}
    };
    for (size_t i = 0; i < sizeof(sites) / sizeof(*sites); ++i) {
        q.initiator = (char *)sites[i].source;
        assert(sk_parse_url(sites[i].url, &target, 0));
        const char *site = i == 5 && (!a.psl_builtin || !a.psl_registrable_domain) ? "cross-site" : sites[i].site;
        assert(!strcmp(sk_fetch_site(&a, &q, &target), site));
    }
    struct sk_curl no_psl = a;
    no_psl.psl_builtin = NULL; no_psl.psl_registrable_domain = NULL;
    q.initiator = "https://a.example.com";
    assert(sk_parse_url("https://b.example.com/", &target, 0));
    assert(!strcmp(sk_fetch_site(&no_psl, &q, &target), "cross-site"));
    const struct { const char *url; int trusted; } urls[] = {
        {"https://example.com/", 1}, {"http://example.com/", 0},
        {"http://localhost/", 1}, {"http://a.localhost./", 1}, {"http://notlocalhost/", 0},
        {"http://127.0.0.2/", 1}, {"http://127.0.0.1./", 1}, {"http://[::1]/", 1},
        {"http://[::ffff:127.0.0.1]/", 0}
    };
    for (size_t i = 0; i < sizeof(urls) / sizeof(*urls); ++i) {
        assert(sk_parse_url(urls[i].url, &target, 0));
        assert(sk_trustworthy(&target) == urls[i].trusted);
        if (!urls[i].trusted) {
            headers = NULL;
            assert(sk_fetch_metadata(&a, &headers, &q, 0, &target) && !headers);
        }
    }
    dlclose(a.handle);
    puts("PASS Fetch Metadata destinations, CORS libraries, activation, schemeful PSL sites and trustworthy origins");
}

static atomic_int socket_thread_go;
static void *socket_thread(void *unused) {
    (void)unused;
    while (!atomic_load(&socket_thread_go)) pause_ms(1);
    errno = 0;
    assert(socket(AF_INET, SOCK_STREAM, 0) == -1 && errno == EPERM);
    return NULL;
}

static void confinement(void) {
    pid_t child = fork(); assert(child >= 0);
    if (!child) {
        int fd = socket(AF_INET, SOCK_STREAM, 0); assert(fd >= 0);
        struct sock_filter code[] = {
            BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)),
            BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, SYS_getsockname, 0, 1),
            BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | EPERM),
            BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW)
        };
        struct sock_fprog program = {sizeof(code) / sizeof(code[0]), code};
        assert(!prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0));
        assert(!syscall(SYS_seccomp, SECCOMP_SET_MODE_FILTER, 0, &program));
        assert(!sk_web_untrusted_confine()); close(fd); _exit(0);
    }
    child_ok(child);
    child = fork(); assert(child >= 0);
    if (!child) {
        int fd = socket(AF_INET, SOCK_STREAM, 0); assert(fd >= 0);
        assert(!sk_web_untrusted_confine()); close(fd);
        pthread_t thread;
        assert(!pthread_create(&thread, NULL, socket_thread, NULL));
        assert(sk_web_untrusted_confine());
        atomic_store(&socket_thread_go, 1);
        assert(!pthread_join(thread, NULL));
        struct rlimit core; assert(!getrlimit(RLIMIT_CORE, &core));
        assert(!core.rlim_cur && !core.rlim_max && prctl(PR_GET_DUMPABLE) == 1);
        assert(prctl(PR_GET_NO_NEW_PRIVS, 0, 0, 0, 0) == 1);
        const int families[] = {AF_INET, AF_INET6, AF_PACKET, AF_VSOCK};
        for (size_t i = 0; i < sizeof(families) / sizeof(*families); ++i) {
            errno = 0; assert(socket(families[i], SOCK_STREAM, 0) == -1 && errno == EPERM);
        }
        int pair[2];
        errno = 0; assert(socketpair(AF_INET, SOCK_STREAM, 0, pair) == -1 && errno == EPERM);
        errno = 0; assert(socketpair(AF_NETLINK, SOCK_RAW, NETLINK_ROUTE, pair) == -1 && errno == EPERM);
        assert(!socketpair(AF_UNIX, SOCK_STREAM, 0, pair)); close(pair[0]); close(pair[1]);
        fd = socket(AF_UNIX, SOCK_STREAM, 0); assert(fd >= 0); close(fd);
        fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_ROUTE); assert(fd >= 0); close(fd);
        errno = 0; assert(socket(AF_NETLINK, SOCK_RAW, NETLINK_USERSOCK) == -1 && errno == EPERM);
        errno = 0; assert(syscall(SYS_io_uring_setup, 0, NULL) == -1 && errno == EPERM);
        errno = 0; assert(syscall(SYS_io_uring_enter, 0, 0, 0, 0, NULL, 0) == -1 && errno == EPERM);
        errno = 0; assert(syscall(SYS_io_uring_register, 0, 0, NULL, 0) == -1 && errno == EPERM);
        _exit(0);
    }
    child_ok(child);
    child = fork(); assert(child >= 0);
    if (!child) {
        assert(sk_web_untrusted_nondumpable() && !prctl(PR_GET_DUMPABLE));
        assert(sk_web_untrusted_no_core() && !prctl(PR_GET_DUMPABLE));
        struct rlimit core; assert(!getrlimit(RLIMIT_CORE, &core) && !core.rlim_cur && !core.rlim_max);
        _exit(0);
    }
    child_ok(child);
    int control = socket(AF_INET, SOCK_STREAM, 0); assert(control >= 0); close(control);
#if defined(__x86_64__)
    child = fork(); assert(child >= 0);
    if (!child) { assert(sk_web_untrusted_confine()); syscall(0x40000000u | SYS_socket, AF_INET, SOCK_STREAM, 0); _exit(1); }
    int status; assert(waitpid(child, &status, 0) == child);
    assert(WIFSIGNALED(status) && WTERMSIG(status) == SIGSYS);
    child = fork(); assert(child >= 0);
    if (!child) {
        assert(sk_web_untrusted_confine());
        unsigned result = 20; /* i386 getpid via a foreign syscall architecture. */
        __asm__ volatile("int $0x80" : "+a"(result) : : "memory");
        _exit(1);
    }
    assert(waitpid(child, &status, 0) == child);
    assert(WIFSIGNALED(status) && WTERMSIG(status) == SIGSYS);
#endif
    puts("PASS seccomp socket/socketpair/io_uring, inherited-fd refusal, TSYNC, foreign arch/x32 and control");
}

struct server_stats { atomic_uint hits, cookies, posts, dns, origins; };
static struct server_stats *stats;
static atomic_int dns_entered;

/* What the routed-broker tests observe, shared with the fake proxy, the
 * broker and its jobs (all forked from the test). */
struct proxy_stats {
    atomic_uint connections, page_dns, proxy_dns, sockets, foreign_sockets;
    atomic_int observing;
    /* The one address and port a routed job may dial. */
    int expect_family; unsigned char expect_addr[16]; unsigned expect_port;
    unsigned socks_atyp, socks_port;
    char socks_host[256], request_line[512];
};
static struct proxy_stats *pstats;

/* Page hosts the routed tests use: resolvable nowhere, and never asked here. */
#define PAGE_SUFFIX ".sk-proxy.test"
/* A proxy NAME, resolved here to 127.0.0.1 (the broker resolves proxies). */
#define PROXY_NAME "proxy.sk-test.invalid"

static void observe_socket(int purpose, const void *address) {
    if (!pstats || !atomic_load(&pstats->observing)) return;
    const struct curl_sockaddr *a = address;
    atomic_fetch_add(&pstats->sockets, 1);
    unsigned char bytes[16];
    int port = a->family == AF_INET ? ntohs(((const struct sockaddr_in *)&a->addr)->sin_port) :
        a->family == AF_INET6 ? ntohs(((const struct sockaddr_in6 *)&a->addr)->sin6_port) : -1;
    if (purpose != CURLSOCKTYPE_IPCXN || (a->socktype & ~(SOCK_CLOEXEC | SOCK_NONBLOCK)) != SOCK_STREAM ||
        a->family != pstats->expect_family || !sk_address_bytes(&a->addr, bytes) ||
        memcmp(bytes, pstats->expect_addr, 16) || port != (int)pstats->expect_port)
        atomic_fetch_add(&pstats->foreign_sockets, 1);
}

/* Exercise the real curl resolver lane without external DNS traffic. */
int getaddrinfo(const char *name, const char *service, const struct addrinfo *hints, struct addrinfo **result) {
    int (*resolve)(const char *, const char *, const struct addrinfo *, struct addrinfo **) = dlsym(RTLD_NEXT, "getaddrinfo");
    assert(resolve);
    size_t len = name ? strlen(name) : 0;
    if (pstats && len >= sizeof(PAGE_SUFFIX) - 1 && !strcmp(name + len - (sizeof(PAGE_SUFFIX) - 1), PAGE_SUFFIX)) {
        atomic_fetch_add(&pstats->page_dns, 1);
        return EAI_NONAME;
    }
    if (pstats && name && !strcmp(name, PROXY_NAME)) {
        atomic_fetch_add(&pstats->proxy_dns, 1);
        return resolve("127.0.0.1", service, hints, result);
    }
    if (name && !strcmp(name, "sk-slow-dns.test")) {
        assert(stats);
        /* curl may resolve A and AAAA on separate threads in the same job. */
        if (!atomic_exchange(&dns_entered, 1)) atomic_fetch_add(&stats->dns, 1);
        pause_ms(20000);
        return EAI_AGAIN;
    }
    return resolve(name, service, hints, result);
}

static void server(int listener, pid_t parent) {
    close(STDIN_FILENO); close(STDOUT_FILENO); close(STDERR_FILENO);
    assert(!prctl(PR_SET_PDEATHSIG, SIGKILL));
    if (getppid() != parent) _exit(1);
    alarm(120);
    for (;;) {
        int fd = accept4(listener, NULL, NULL, SOCK_CLOEXEC);
        if (fd < 0) { if (errno == EINTR) continue; _exit(1); }
        char input[SK_HEADER_CAP + 1024]; size_t used = 0;
        while (used < sizeof(input) - 1) {
            ssize_t n = recv(fd, input + used, sizeof(input) - 1 - used, 0);
            if (n <= 0) break;
            used += (size_t)n; input[used] = 0;
            if (strstr(input, "\r\n\r\n")) break;
        }
        atomic_fetch_add(&stats->hits, 1);
        if (strstr(input, "Cookie: a=one")) atomic_fetch_add(&stats->cookies, 1);
        if (strstr(input, "Origin: http://other.example")) atomic_fetch_add(&stats->origins, 1);
        if (!strncmp(input, "POST ", 5)) atomic_fetch_add(&stats->posts, 1);
        int64_t deadline = sk_now_ms() + 2000;
        if (strstr(input, " /slow ")) {
            /* Keep independent sockets open without delaying later accepts. */
            continue;
        } else if (strstr(input, " /metadata ")) {
            char response[256];
            int n = snprintf(response, sizeof(response), "HTTP/1.1 200 OK\r\nContent-Length: %zu\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n", used);
            if (sk_io(fd, response, (size_t)n, 1, deadline)) sk_io(fd, input, used, 1, deadline);
        } else if (strstr(input, " /redirect ")) {
            char response[] = "HTTP/1.1 302 Found\r\nLocation: /target\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            sk_io(fd, response, sizeof(response) - 1, 1, deadline);
        } else if (strstr(input, " /static-")) {
            const char *mime = strstr(input, " /static-css ") ? "text/css" :
                strstr(input, " /static-font ") ? "font/woff2" :
                strstr(input, " /static-mime ") ? "text/html" : "text/javascript";
            const char *acao = strstr(input, " /static-no-cors ") ? "" :
                strstr(input, " /static-exact ") ? "Access-Control-Allow-Origin: http://other.example\r\n" :
                strstr(input, " /static-duplicate ") ? "Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Origin: *\r\n" :
                "Access-Control-Allow-Origin: *\r\n";
            const char *corp = strstr(input, " /static-corp ") ? "Cross-Origin-Resource-Policy: same-origin\r\n" : "";
            char response[1024];
            int n = snprintf(response, sizeof(response), "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Type: %s\r\n%s%sSet-Cookie: a=one\r\nConnection: close\r\n\r\nhello", mime, acao, corp);
            sk_io(fd, response, (size_t)n, 1, deadline);
        } else if (strstr(input, " /headers ")) {
            char begin[] = "HTTP/1.1 200 OK\r\n";
            sk_io(fd, begin, sizeof(begin) - 1, 1, deadline);
            char line[1024]; memset(line, 'a', sizeof(line));
            memcpy(line, "X-Big: ", 7); line[1022] = '\r'; line[1023] = '\n';
            for (unsigned i = 0; i < 70; ++i) if (!sk_io(fd, line, sizeof(line), 1, deadline)) break;
        } else if (strstr(input, " /bomb ") || strstr(input, " /gzip ")) {
            z_stream z = {0};
            assert(deflateInit2(&z, 9, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY) == Z_OK);
            unsigned char compressed[65536], block[16384]; memset(block, 'x', sizeof(block));
            z.next_out = compressed; z.avail_out = sizeof(compressed);
            if (strstr(input, " /gzip ")) {
                z.next_in = (unsigned char *)"hello"; z.avail_in = 5;
                assert(deflate(&z, Z_FINISH) == Z_STREAM_END);
            } else {
                for (unsigned i = 0; i < SK_BODY_CAP / sizeof(block); ++i) {
                    z.next_in = block; z.avail_in = sizeof(block); assert(deflate(&z, Z_NO_FLUSH) == Z_OK);
                }
                z.next_in = block; z.avail_in = 1; assert(deflate(&z, Z_FINISH) == Z_STREAM_END);
            }
            unsigned n = (unsigned)z.total_out; deflateEnd(&z);
            char header[256];
            int len = snprintf(header, sizeof(header), "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: %u\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\n\r\n", n);
            if (sk_io(fd, header, (size_t)len, 1, deadline)) sk_io(fd, compressed, n, 1, deadline);
        } else {
            char response[] = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Type: text/plain; charset=utf-8\r\n"
                "Content-Security-Policy: default-src 'none'\r\nContent-Security-Policy: img-src 'self'\r\n"
                "Access-Control-Allow-Origin: https://other.example\r\nSet-Cookie: a=one; HttpOnly\r\nSet-Cookie: b=two\r\n"
                "Connection: close\r\n\r\nhello";
            size_t len = sizeof(response) - 1;
            if (!strncmp(input, "HEAD ", 5)) len -= 5;
            sk_io(fd, response, len, 1, deadline);
        }
        close(fd);
    }
}

static int broker_connect(void) {
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0); assert(fd >= 0);
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    memcpy(address.sun_path, sk_socket_path, sizeof(address.sun_path));
    assert(!connect(fd, (struct sockaddr *)&address, sizeof(address)));
    return fd;
}

static void concurrency(void) {
    int held[SK_JOBS];
    for (unsigned i = 0; i < SK_JOBS; ++i) held[i] = broker_connect();
    /* Leave the 17th unanswered in the backlog: a loader can legitimately
     * connect before its predecessor's job is reaped, so it waits, not fails. */
    int excess = broker_connect();
    struct sk_wire_request w = {.magic = SK_MAGIC, .url_len = SK_URL_CAP + 1, .method_len = 3,
        .budget_ms = SK_TIMEOUT_MS};
    struct sk_wire_response answer;
    assert(sk_io(excess, &w, sizeof(w), 1, sk_now_ms() + 1000));
    assert(!sk_io(excess, &answer, sizeof(answer), 0, sk_now_ms() + 1000));
    unsigned char byte;
    for (unsigned i = 0; i < SK_JOBS; ++i) {
        /* Leave bytes queued for the job: hangup detection must not read them. */
        byte = 0;
        assert(sk_io(held[i], &byte, 1, 1, sk_now_ms() + 1000));
        struct pollfd p = {held[i], POLLIN, 0};
        assert(poll(&p, 1, 0) == 0);
    }
    close(held[0]);
    int64_t before = sk_now_ms();
    assert(sk_io(excess, &answer, sizeof(answer), 0, before + 3000));
    assert(answer.magic == SK_MAGIC && answer.reason == SK_WEB_UNTRUSTED_UNSUPPORTED);
    int64_t admitted_ms = sk_now_ms() - before;
    close(excess);
    for (unsigned i = 1; i < SK_JOBS; ++i) close(held[i]);
    assert(!atomic_load(&stats->hits));
    printf("PASS 16-job broker cap; the 17th connection waits and is served %lldms after a slot frees\n",
        (long long)admitted_ms);
}

static void lifetime(void) {
    int fd = broker_connect();
    unsigned char byte = 0;
    int64_t before = sk_now_ms();
    assert(sk_io(fd, &byte, 1, 1, before + 1000));
    assert(!sk_io(fd, &byte, 1, 0, before + 17000));
    int64_t elapsed = sk_now_ms() - before;
    assert(elapsed >= 14000 && elapsed < 16500);
    close(fd);
    puts("PASS incomplete-request worker lifetime bounded to 15s");
}

static struct sk_response exchange_budget(const char *url, const char *method, const char *headers,
                                         size_t header_len, const void *body, size_t body_len, int allow,
                                         const char *initiator, int navigation, int resource_type,
                                         uint32_t budget_ms) {
    int fd = broker_connect();
    struct sk_wire_request w = {SK_MAGIC, (uint32_t)strlen(url), (uint32_t)strlen(method),
        (uint32_t)header_len, (uint32_t)body_len, (uint32_t)allow,
        (uint32_t)strlen(initiator), (uint32_t)navigation, (uint32_t)resource_type, budget_ms, 0,
        (uint32_t)strlen(initiator)};
    int64_t deadline = sk_now_ms() + 3000;
    assert(sk_io(fd, &w, sizeof(w), 1, deadline));
    assert(sk_io(fd, (void *)url, w.url_len, 1, deadline));
    assert(sk_io(fd, (void *)method, w.method_len, 1, deadline));
    assert(sk_io(fd, (void *)initiator, w.initiator_len, 1, deadline));
    assert(sk_io(fd, (void *)initiator, w.fetch_initiator_len, 1, deadline));
    assert(sk_io(fd, (void *)headers, header_len, 1, deadline));
    assert(sk_io(fd, (void *)body, body_len, 1, deadline));
    struct sk_wire_response answer;
    assert(sk_io(fd, &answer, sizeof(answer), 0, deadline) && answer.magic == SK_MAGIC);
    assert(answer.headers_len <= SK_HEADER_CAP && answer.body_len <= SK_BODY_CAP);
    struct sk_response r = {.reason = (int)answer.reason, .status = (int)answer.status,
        .headers_len = answer.headers_len, .body_len = answer.body_len};
    r.headers = calloc(1, (size_t)answer.headers_len + 1);
    r.body = calloc(1, (size_t)answer.body_len + 1);
    assert(r.headers && r.body);
    assert(sk_io(fd, r.headers, r.headers_len, 0, deadline));
    assert(sk_io(fd, r.body, r.body_len, 0, deadline));
    close(fd);
    return r;
}

static struct sk_response exchange_as(const char *url, const char *method, const char *headers,
                                     size_t header_len, const void *body, size_t body_len, int allow,
                                     const char *initiator, int navigation, int resource_type) {
    return exchange_budget(url, method, headers, header_len, body, body_len, allow, initiator,
        navigation, resource_type, SK_TIMEOUT_MS);
}

static struct sk_response exchange(const char *url, const char *method, const char *headers,
                                   size_t header_len, const void *body, size_t body_len, int allow) {
    return exchange_as(url, method, headers, header_len, body, body_len, allow, "", 1, RT_MAIN_FRAME);
}

static void tls_verification(void) {
    /* A throwaway, self-signed certificate must never deliver HTTP bytes. */
    EVP_PKEY *key = EVP_PKEY_Q_keygen(NULL, NULL, "EC", "prime256v1"); assert(key);
    X509 *cert = X509_new(); assert(cert);
    assert(X509_set_version(cert, 2) && ASN1_INTEGER_set(X509_get_serialNumber(cert), 1));
    assert(X509_gmtime_adj(X509_getm_notBefore(cert), -60) && X509_gmtime_adj(X509_getm_notAfter(cert), 3600));
    assert(X509_set_pubkey(cert, key));
    X509_NAME *subject = X509_get_subject_name(cert);
    assert(X509_NAME_add_entry_by_txt(subject, "CN", MBSTRING_ASC, (unsigned char *)"localhost", -1, -1, 0));
    assert(X509_set_issuer_name(cert, subject));
    X509_EXTENSION *san = X509V3_EXT_conf_nid(NULL, NULL, NID_subject_alt_name, "DNS:localhost,IP:127.0.0.1");
    assert(san && X509_add_ext(cert, san, -1)); X509_EXTENSION_free(san);
    assert(X509_sign(cert, key, EVP_sha256()));
    SSL_CTX *ctx = SSL_CTX_new(TLS_server_method()); assert(ctx);
    assert(SSL_CTX_use_certificate(ctx, cert) && SSL_CTX_use_PrivateKey(ctx, key));
    X509_free(cert); EVP_PKEY_free(key);
    int listener = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0); assert(listener >= 0);
    struct sockaddr_in address = {.sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    assert(!bind(listener, (struct sockaddr *)&address, sizeof(address)) && !listen(listener, 1));
    socklen_t len = sizeof(address); assert(!getsockname(listener, (struct sockaddr *)&address, &len));
    atomic_uint *counts = mmap(NULL, 2 * sizeof(*counts), PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    assert(counts != MAP_FAILED); atomic_init(&counts[0], 0); atomic_init(&counts[1], 0);
    pid_t parent = getpid(), child = fork(); assert(child >= 0);
    if (!child) {
        close(0); close(1); close(2);
        signal(SIGPIPE, SIG_IGN);
        assert(!prctl(PR_SET_PDEATHSIG, SIGKILL));
        if (getppid() != parent) _exit(1);
        alarm(5);
        int fd = accept4(listener, NULL, NULL, SOCK_CLOEXEC); assert(fd >= 0);
        atomic_fetch_add(&counts[0], 1);
        SSL *ssl = SSL_new(ctx); assert(ssl && SSL_set_fd(ssl, fd));
        if (SSL_accept(ssl) == 1) {
            char input[512];
            if (SSL_read(ssl, input, sizeof(input)) > 0) atomic_fetch_add(&counts[1], 1);
        }
        SSL_free(ssl); SSL_CTX_free(ctx); close(fd); close(listener); _exit(0);
    }
    SSL_CTX_free(ctx); close(listener);
    char url[128]; snprintf(url, sizeof(url), "https://127.0.0.1:%u/", ntohs(address.sin_port));
    struct sk_response r = exchange(url, "GET", "", 0, NULL, 0, 1);
    assert(r.reason == SK_WEB_UNTRUSTED_BROKER_FAILURE && !r.body_len && !r.headers_len);
    free(r.headers); free(r.body); child_ok(child);
    assert(atomic_load(&counts[0]) == 1 && atomic_load(&counts[1]) == 0);
    munmap(counts, 2 * sizeof(*counts));
    puts("PASS HTTPS rejects self-signed certificate before HTTP request bytes");
}

static unsigned header_count(struct sk_response *r, const char *key) {
    unsigned n = 0;
    for (size_t at = 0; at < r->headers_len;) {
        const char *name = r->headers + at; at += strlen(name) + 1;
        at += strlen(r->headers + at) + 1;
        if (!strcasecmp(name, key)) ++n;
    }
    return n;
}
static void response_free(struct sk_response *r) { free(r->headers); free(r->body); }

static void broker_metadata(const char *url) {
    char path[512], source[256];
    snprintf(path, sizeof(path), "%smetadata", url);
    snprintf(source, sizeof(source), "%.*s", (int)strlen(url) - 1, url);
    const char spoofed[] = "sec-fetch-dest\0worker\0Sec-Fetch-Mode\0same-origin\0"
        "SEC-FETCH-SITE\0none\0Sec-Fetch-User\0?1\0";
    struct sk_response r = exchange_as(path, "GET", spoofed, sizeof(spoofed) - 1, NULL, 0, 1, source, 0, RT_SCRIPT);
    assert(!r.reason && r.body_len);
    assert(strstr((char *)r.body, "\r\nSec-Fetch-Dest: script\r\n"));
    assert(strstr((char *)r.body, "\r\nSec-Fetch-Mode: no-cors\r\n"));
    assert(strstr((char *)r.body, "\r\nSec-Fetch-Site: same-origin\r\n"));
    assert(!strstr((char *)r.body, "Sec-Fetch-User") && !strstr((char *)r.body, "worker"));
    response_free(&r);
    r = exchange_as(path, "GET", "", 0, NULL, 0, 1, source, 1, RT_SUB_FRAME);
    assert(!r.reason && strstr((char *)r.body, "\r\nSec-Fetch-Dest: iframe\r\n"));
    assert(strstr((char *)r.body, "\r\nSec-Fetch-Mode: navigate\r\n"));
    assert(!strstr((char *)r.body, "Sec-Fetch-User"));
    response_free(&r);
    puts("PASS broker sends reconstructed Fetch Metadata and replaces spoofed fields without duplicates");
}

static unsigned occurrences(const char *text, const char *needle) {
    unsigned n = 0;
    for (const char *at = strstr(text, needle); at; at = strstr(at + 1, needle)) ++n;
    return n;
}

static void broker_post_type(const char *url) {
    char path[512], source[256];
    snprintf(path, sizeof(path), "%smetadata", url);
    snprintf(source, sizeof(source), "%.*s", (int)strlen(url) - 1, url);
    struct sk_response r = exchange_as(path, "POST", "", 0, "abc", 3, 1, source, 0, RT_XHR);
    assert(!r.reason && r.body_len && strstr((char *)r.body, "\r\nContent-Length: 3\r\n"));
    assert(!occurrences((char *)r.body, "Content-Type"));
    response_free(&r);
    const char typed[] = "Content-Type\0text/plain;charset=UTF-8\0";
    r = exchange_as(path, "POST", typed, sizeof(typed) - 1, "abc", 3, 1, source, 0, RT_XHR);
    assert(!r.reason && strstr((char *)r.body, "\r\nContent-Type: text/plain;charset=UTF-8\r\n"));
    assert(occurrences((char *)r.body, "Content-Type") == 1);
    response_free(&r);
    puts("PASS broker sends an untyped POST body untyped, never curl's form default");
}

struct fake_request { cef_request_t cef; atomic_int refs; const char *url, *method, *headers; size_t header_len; cef_post_data_t *post; cef_resource_type_t type; };
static void CEF_CALLBACK req_add(cef_base_ref_counted_t *base) { atomic_fetch_add(&((struct fake_request *)base)->refs, 1); }
static int CEF_CALLBACK req_release(cef_base_ref_counted_t *base) { return atomic_fetch_sub(&((struct fake_request *)base)->refs, 1) == 1; }
static cef_string_userfree_t user_string(const char *text) {
    cef_string_userfree_t s = cef_string_userfree_alloc(); assert(s);
    assert(sk_cef_string(text, strlen(text), s)); return s;
}
static cef_string_userfree_t CEF_CALLBACK req_url(cef_request_t *self) { return user_string(((struct fake_request *)self)->url); }
static cef_string_userfree_t CEF_CALLBACK req_method(cef_request_t *self) { return user_string(((struct fake_request *)self)->method); }
static cef_resource_type_t CEF_CALLBACK req_type(cef_request_t *self) { return ((struct fake_request *)self)->type; }
#define FAKE_REQUEST_ID 4242u
static uint64_t CEF_CALLBACK req_identifier(cef_request_t *self) { (void)self; return FAKE_REQUEST_ID; }
static cef_post_data_t *CEF_CALLBACK req_post(cef_request_t *self) {
    cef_post_data_t *post = ((struct fake_request *)self)->post;
    if (post) post->base.add_ref(&post->base);
    return post;
}
static void CEF_CALLBACK req_headers(cef_request_t *self, cef_string_multimap_t map) {
    struct fake_request *r = (struct fake_request *)self;
    for (size_t at = 0; at < r->header_len;) {
        const char *name = r->headers + at; at += strlen(name) + 1;
        const char *value = r->headers + at; at += strlen(value) + 1;
        cef_string_t k = {0}, v = {0};
        assert(sk_cef_string(name, strlen(name), &k) && sk_cef_string(value, strlen(value), &v));
        assert(cef_string_multimap_append(map, &k, &v)); cef_string_clear(&k); cef_string_clear(&v);
    }
}
static void request_init(struct fake_request *r, const char *url, const char *method) {
    memset(r, 0, sizeof(*r)); atomic_init(&r->refs, 1); r->url = url; r->method = method;
    r->cef.base.size = sizeof(r->cef); r->cef.base.add_ref = req_add; r->cef.base.release = req_release;
    r->cef.get_url = req_url; r->cef.get_method = req_method;
    r->cef.get_header_map = req_headers; r->cef.get_post_data = req_post;
    r->cef.get_resource_type = req_type; r->cef.get_identifier = req_identifier;
}

static void denied(int id, uint64_t request_id, int reason, int unsent);

static cef_resource_handler_t *resource_as(struct fake_request *req, int allow,
                                         const char *initiator, int navigation) {
    cef_string_t source = {0};
    assert(sk_cef_string(initiator, strlen(initiator), &source));
    cef_resource_request_handler_t callbacks = {0};
    cef_resource_request_handler_t *metadata = sk_web_untrusted_request_handler(&callbacks, &req->cef, navigation, 0, &source);
    cef_string_clear(&source);
    assert(metadata && metadata->base.has_one_ref(&metadata->base));
    assert(atomic_load(&req->refs) == 1);
    cef_resource_handler_t *result = sk_web_untrusted_resource(&req->cef, metadata, allow, denied, 17);
    assert(metadata->base.release(&metadata->base));
    return result;
}

static cef_resource_handler_t *resource(struct fake_request *req, int allow) {
    return resource_as(req, allow, "", 1);
}

struct navigation_frame { cef_frame_t cef; const char *url; };
static cef_string_userfree_t CEF_CALLBACK navigation_url(cef_frame_t *self) {
    const char *url = ((struct navigation_frame *)self)->url;
    return url ? user_string(url) : NULL;
}
static cef_transition_type_t CEF_CALLBACK navigation_transition(cef_request_t *self) {
    (void)self; return TT_EXPLICIT;
}

static void navigation_metadata(void) {
    struct fake_request req; request_init(&req, "https://example.com/target", "GET");
    struct navigation_frame frame = {.url = "https://example.com/source?secret"};
    frame.cef.get_url = navigation_url;
    sk_web_untrusted_navigation(&req.cef, &frame.cef, 17, 1);
    cef_resource_handler_t *h = resource_as(&req, 0, "null", 1); assert(h);
    struct sk_handler *internal = (struct sk_handler *)h;
    assert(!strcmp(internal->request.initiator, "null"));
    assert(!strcmp(internal->request.fetch_initiator, "https://example.com"));
    assert(internal->request.user_activation && h->base.release(&h->base));
    sk_web_untrusted_navigation(&req.cef, &frame.cef, 18, 0);
    h = resource_as(&req, 0, "null", 1); assert(h);
    assert(((struct sk_handler *)h)->request.user_activation && h->base.release(&h->base));
    sk_web_untrusted_navigation(&req.cef, &frame.cef, 17, 0);
    h = resource_as(&req, 0, "null", 1); assert(h);
    assert(!((struct sk_handler *)h)->request.user_activation && h->base.release(&h->base));
    req.method = "POST";
    h = resource_as(&req, 0, "null", 1); assert(h);
    assert(((struct sk_handler *)h)->response.reason == SK_WEB_UNTRUSTED_UNSUPPORTED);
    assert(h->base.release(&h->base));
    req.method = "GET";
    req.cef.get_transition_type = navigation_transition;
    sk_web_untrusted_navigation(&req.cef, &frame.cef, 17, 0);
    h = resource_as(&req, 0, "null", 1); assert(h);
    internal = (struct sk_handler *)h;
    assert(!*internal->request.fetch_initiator && internal->request.user_activation);
    assert(h->base.release(&h->base));
    req.cef.get_transition_type = NULL;
    frame.url = NULL;
    sk_web_untrusted_navigation(&req.cef, &frame.cef, 17, 0);
    h = resource_as(&req, 0, "null", 1); assert(h);
    internal = (struct sk_handler *)h;
    assert(!*internal->request.fetch_initiator && internal->request.user_activation);
    assert(atomic_load(&req.refs) == 1 && h->base.release(&h->base));
    memset(sk_navigations, 0, sizeof(sk_navigations));
    puts("PASS native navigation activation/origin attribution, browser isolation, NULL frame URL and unchanged POST authority");
}

struct fake_callback { cef_callback_t cef; atomic_int refs, continued; };
static int CEF_CALLBACK cb_release(cef_base_ref_counted_t *base) { return atomic_fetch_sub(&((struct fake_callback *)base)->refs, 1) == 1; }
static void CEF_CALLBACK cb_cont(cef_callback_t *self) { atomic_fetch_add(&((struct fake_callback *)self)->continued, 1); }
static void callback_init(struct fake_callback *cb) {
    memset(cb, 0, sizeof(*cb)); atomic_init(&cb->refs, 1); atomic_init(&cb->continued, 0);
    cb->cef.base.size = sizeof(cb->cef); cb->cef.base.release = cb_release; cb->cef.cont = cb_cont;
}
static void wait_workers(void) {
    pthread_mutex_lock(&sk_workers_lock);
    while (sk_worker_count) pthread_cond_wait(&sk_workers_done, &sk_workers_lock);
    pthread_mutex_unlock(&sk_workers_lock);
}
static atomic_int denial_count, denial_reason, denial_unsent;
static void denied(int id, uint64_t request_id, int reason, int unsent) {
    assert(id == 17 && request_id == FAKE_REQUEST_ID);
    atomic_store(&denial_reason, reason); atomic_store(&denial_unsent, unsent); atomic_fetch_add(&denial_count, 1);
}

struct fake_element { cef_post_data_element_t cef; int refs; cef_postdataelement_type_t type; size_t size; };
struct fake_post { cef_post_data_t cef; int refs, excluded; struct fake_element element; };
static void CEF_CALLBACK post_add(cef_base_ref_counted_t *base) { ++((struct fake_post *)base)->refs; }
static int CEF_CALLBACK post_release(cef_base_ref_counted_t *base) { return --((struct fake_post *)base)->refs == 0; }
static void CEF_CALLBACK element_add(cef_base_ref_counted_t *base) { ++((struct fake_element *)base)->refs; }
static int CEF_CALLBACK element_release(cef_base_ref_counted_t *base) { return --((struct fake_element *)base)->refs == 0; }
static int CEF_CALLBACK post_excluded(cef_post_data_t *self) { return ((struct fake_post *)self)->excluded; }
static size_t CEF_CALLBACK post_count(cef_post_data_t *self) { (void)self; return 1; }
static void CEF_CALLBACK post_elements(cef_post_data_t *self, size_t *count, cef_post_data_element_t **elements) {
    assert(*count == 1);
    elements[0] = &((struct fake_post *)self)->element.cef;
    element_add(&elements[0]->base);
}
static cef_postdataelement_type_t CEF_CALLBACK element_type(cef_post_data_element_t *self) { return ((struct fake_element *)self)->type; }
static size_t CEF_CALLBACK element_size(cef_post_data_element_t *self) { return ((struct fake_element *)self)->size; }
static size_t CEF_CALLBACK element_bytes(cef_post_data_element_t *self, size_t count, void *out) {
    (void)self; assert(count == 3); memcpy(out, "abc", 3); return 3;
}
static void post_init(struct fake_post *post) {
    memset(post, 0, sizeof(*post)); post->refs = 1; post->element.refs = 1;
    post->cef.base.add_ref = post_add; post->cef.base.release = post_release;
    post->cef.has_excluded_elements = post_excluded; post->cef.get_element_count = post_count;
    post->cef.get_elements = post_elements;
    post->element.cef.base.add_ref = element_add; post->element.cef.base.release = element_release;
    post->element.cef.get_type = element_type; post->element.cef.get_bytes_count = element_size;
    post->element.cef.get_bytes = element_bytes;
    post->element.type = PDE_TYPE_BYTES; post->element.size = 3;
}

static void uploads(const char *url) {
    char headers[SK_URL_CAP + 32];
    size_t origin_len = strlen(url) - 1;
    memcpy(headers, "Origin", 7); memcpy(headers + 7, url, origin_len); headers[7 + origin_len] = 0;
    struct fake_request req; request_init(&req, url, "POST");
    req.type = RT_XHR;
    req.headers = headers; req.header_len = 8 + origin_len;
    struct fake_post post; post_init(&post); req.post = &post.cef;
    cef_resource_handler_t *h = resource_as(&req, 1, headers + 7, 0); assert(h);
    struct sk_handler *internal = (struct sk_handler *)h;
    assert(!internal->response.reason && internal->request.body_len == 3 && !memcmp(internal->request.body, "abc", 3));
    assert(post.refs == 1 && post.element.refs == 1 && atomic_load(&req.refs) == 1);
    struct fake_callback cb; callback_init(&cb); req_add(&req.cef.base);
    int handle; unsigned baseline = atomic_load(&stats->posts);
    assert(h->open(h, &req.cef, &handle, &cb.cef)); wait_workers();
    assert(atomic_load(&cb.continued) == 1 && atomic_load(&cb.refs) == 0);
    assert(atomic_load(&stats->posts) == baseline + 1 && !internal->response.reason);
    assert(h->base.release(&h->base));
    baseline = atomic_load(&stats->hits);
    for (unsigned i = 0; i < 4; ++i) {
        post_init(&post);
        if (!i) post.element.type = PDE_TYPE_FILE;
        if (i == 1) post.excluded = 1;
        if (i == 2) post.element.size = SK_UPLOAD_CAP + 1;
        /* CEF's shape for a Blob/File/stream part: EMPTY, not flagged excluded. */
        if (i == 3) post.element.type = PDE_TYPE_EMPTY;
        h = resource_as(&req, 1, headers + 7, 0); assert(h);
        assert(((struct sk_handler *)h)->response.reason == SK_WEB_UNTRUSTED_UNSUPPORTED);
        assert(post.refs == 1 && post.element.refs == 1);
        assert(h->base.release(&h->base));
    }
    assert(atomic_load(&stats->hits) == baseline);
    puts("PASS CEF POST bytes/element ownership, file/excluded/data-pipe upload rejection and upload cap");
}

struct fake_response { cef_response_t cef; int refs, status, error, length_headers, csp, worker_csp, cookies; char mime[64], charset[64]; };
static int CEF_CALLBACK resp_release(cef_base_ref_counted_t *base) { return --((struct fake_response *)base)->refs == 0; }
static void CEF_CALLBACK resp_status(cef_response_t *self, int value) { ((struct fake_response *)self)->status = value; }
static void CEF_CALLBACK resp_error(cef_response_t *self, cef_errorcode_t value) { ((struct fake_response *)self)->error = value; }
static void CEF_CALLBACK resp_mime(cef_response_t *self, const cef_string_t *value) {
    char *s = sk_utf8(value, 63); assert(s); strcpy(((struct fake_response *)self)->mime, s); free(s);
}
static void CEF_CALLBACK resp_charset(cef_response_t *self, const cef_string_t *value) {
    char *s = sk_utf8(value, 63); assert(s); strcpy(((struct fake_response *)self)->charset, s); free(s);
}
static void CEF_CALLBACK resp_headers(cef_response_t *self, cef_string_multimap_t map) {
    struct fake_response *r = (struct fake_response *)self;
    for (size_t i = 0; i < cef_string_multimap_size(map); ++i) {
        cef_string_t k = {0}, v = {0};
        assert(cef_string_multimap_key(map, i, &k) && cef_string_multimap_value(map, i, &v));
        char *key = sk_utf8(&k, SK_HEADER_CAP), *value = sk_utf8(&v, SK_HEADER_CAP); assert(key && value);
        if (!strcasecmp(key, "Content-Length")) { ++r->length_headers; assert(!strcmp(value, "5")); }
        if (!strcasecmp(key, "Content-Security-Policy")) {
            ++r->csp;
            if (!strcmp(value, "worker-src 'none'")) ++r->worker_csp;
        }
        if (!strcasecmp(key, "Set-Cookie")) ++r->cookies;
        assert(strcasecmp(key, "Content-Encoding") && strcasecmp(key, "Transfer-Encoding"));
        free(key); free(value); cef_string_clear(&k); cef_string_clear(&v);
    }
}

static void handlers(const char *url) {
    atomic_store(&denial_count, 0);
    struct fake_request req; request_init(&req, url, "GET");
    cef_resource_handler_t *h = resource(&req, 1); assert(h);
    assert(atomic_load(&req.refs) == 1 && h->base.has_one_ref(&h->base));
    struct fake_callback cb; callback_init(&cb);
    int handle = 1;
    req_add(&req.cef.base);
    assert(h->open(h, &req.cef, &handle, &cb.cef) && !handle);
    wait_workers();
    assert(atomic_load(&cb.refs) == 0 && atomic_load(&cb.continued) == 1);
    assert(atomic_load(&req.refs) == 1 && !atomic_load(&denial_count));
    struct fake_response response = {.refs = 1};
    response.cef.base.release = resp_release; response.cef.set_status = resp_status;
    response.cef.set_error = resp_error; response.cef.set_header_map = resp_headers;
    response.cef.set_mime_type = resp_mime; response.cef.set_charset = resp_charset;
    int64_t length = -1; cef_string_t redirect = {0};
    h->get_response_headers(h, &response.cef, &length, &redirect);
    assert(!response.refs && response.status == 200 && !response.error && length == 5);
    assert(response.csp == 3 && response.worker_csp == 1 && response.cookies == 2 && response.length_headers == 1);
    assert(!strcmp(response.mime, "text/plain") && !strcmp(response.charset, "utf-8"));
    char data[16]; int n;
    struct fake_callback read_cb; callback_init(&read_cb);
    assert(h->read(h, data, sizeof(data), &n, (cef_resource_read_callback_t *)&read_cb.cef) && n == 5 && !memcmp(data, "hello", 5));
    assert(!atomic_load(&read_cb.refs) && !atomic_load(&read_cb.continued));
    assert(!h->read(h, data, sizeof(data), &n, NULL) && !n);
    callback_init(&read_cb);
    int64_t skipped;
    assert(!h->skip(h, 1, &skipped, (cef_resource_skip_callback_t *)&read_cb.cef));
    assert(skipped == ERR_REQUEST_RANGE_NOT_SATISFIABLE && !atomic_load(&read_cb.refs));
    assert(h->base.release(&h->base));

    request_init(&req, url, "POST");
    h = resource(&req, 1); assert(h);
    assert(atomic_load(&req.refs) == 1 && atomic_load(&denial_reason) == SK_WEB_UNTRUSTED_UNSUPPORTED);
    assert(atomic_load(&denial_unsent) == 1);
    callback_init(&cb); req_add(&req.cef.base);
    assert(!h->open(h, &req.cef, &handle, &cb.cef) && handle);
    assert(atomic_load(&cb.refs) == 0 && !atomic_load(&cb.continued));
    assert(h->base.release(&h->base));

    request_init(&req, url, "GET");
    h = resource(&req, 0); assert(h);
    callback_init(&cb); req_add(&req.cef.base);
    assert(h->open(h, &req.cef, &handle, &cb.cef)); wait_workers();
    assert(atomic_load(&cb.refs) == 0 && atomic_load(&cb.continued) == 1);
    assert(atomic_load(&denial_reason) == SK_WEB_UNTRUSTED_PRIVATE && !atomic_load(&denial_unsent));
    assert(h->base.release(&h->base));
    puts("PASS async handler, borrowed factory request, callback references, duplicate CEF headers and decoded length");
}

static cef_resource_handler_t *CEF_CALLBACK copied_resource_callback(
    cef_resource_request_handler_t *self, cef_browser_t *browser, cef_frame_t *frame, cef_request_t *request) {
    (void)self; (void)browser; (void)frame; (void)request;
    return NULL;
}

static void trusted_metadata(const char *url) {
    struct fake_request req; request_init(&req, url, "GET");
    const char accept[] = "Accept\0text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7\0Upgrade-Insecure-Requests\0" "1\0";
    req.headers = accept; req.header_len = sizeof(accept) - 1;
    cef_resource_handler_t *h = resource(&req, 1); assert(h);
    struct fake_callback cb; callback_init(&cb); req_add(&req.cef.base);
    int handle;
    assert(h->open(h, &req.cef, &handle, &cb.cef) && !handle); wait_workers();
    assert(!((struct sk_handler *)h)->response.reason && ((struct sk_handler *)h)->response.status == 200);
    assert(!atomic_load(&cb.refs) && atomic_load(&cb.continued) == 1);
    assert(atomic_load(&req.refs) == 1 && h->base.release(&h->base));

    cef_resource_request_handler_t callbacks = {0};
    callbacks.get_resource_handler = copied_resource_callback;
    cef_string_t source = {0}; assert(sk_cef_string("http://other.example", 20, &source));
    req.type = RT_SCRIPT;
    cef_resource_request_handler_t *metadata = sk_web_untrusted_request_handler(&callbacks, &req.cef, 0, 0, &source);
    cef_string_clear(&source);
    assert(metadata && metadata->get_resource_handler == callbacks.get_resource_handler && atomic_load(&req.refs) == 1);
    metadata->base.add_ref(&metadata->base);
    assert(!metadata->base.has_one_ref(&metadata->base) && !metadata->base.release(&metadata->base));
    assert(metadata->base.has_one_ref(&metadata->base));
    unsigned baseline = atomic_load(&stats->hits);
    h = sk_web_untrusted_resource(&req.cef, metadata, 1, denied, 17); assert(h);
    assert(((struct sk_handler *)h)->response.reason == SK_WEB_UNTRUSTED_UNSUPPORTED);
    callback_init(&cb); req_add(&req.cef.base);
    assert(!h->open(h, &req.cef, &handle, &cb.cef) && handle);
    assert(!atomic_load(&cb.refs) && !atomic_load(&cb.continued) && h->base.release(&h->base));
    const char author_upgrade[] = "Origin\0http://other.example\0Upgrade-Insecure-Requests\0" "1\0";
    req.headers = author_upgrade; req.header_len = sizeof(author_upgrade) - 1;
    h = sk_web_untrusted_resource(&req.cef, metadata, 1, denied, 17); assert(h);
    assert(((struct sk_handler *)h)->response.reason == SK_WEB_UNTRUSTED_UNSUPPORTED && h->base.release(&h->base));
    req.headers = "Origin\0http://127.0.0.1\0X-Test\0yes\0";
    req.header_len = sizeof("Origin\0http://127.0.0.1\0X-Test\0yes\0") - 1;
    req.type = RT_XHR;
    h = sk_web_untrusted_resource(&req.cef, metadata, 1, denied, 17); assert(h);
    assert(((struct sk_handler *)h)->response.reason == SK_WEB_UNTRUSTED_UNSUPPORTED && h->base.release(&h->base));
    assert(metadata->base.release(&metadata->base));
    h = sk_web_untrusted_resource(&req.cef, &callbacks, 1, denied, 17); assert(h);
    assert(((struct sk_handler *)h)->response.reason == SK_WEB_UNTRUSTED_UNSUPPORTED && h->base.release(&h->base));
    h = sk_web_untrusted_resource(&req.cef, NULL, 1, denied, 17); assert(h);
    assert(((struct sk_handler *)h)->response.reason == SK_WEB_UNTRUSTED_UNSUPPORTED && h->base.release(&h->base));
    req.type = RT_MAIN_FRAME;
    metadata = sk_web_untrusted_request_handler(&callbacks, &req.cef, 1, 1, NULL); assert(metadata);
    h = sk_web_untrusted_resource(&req.cef, metadata, 1, denied, 17); assert(h);
    assert(((struct sk_handler *)h)->response.reason == SK_WEB_UNTRUSTED_UNSUPPORTED && h->base.release(&h->base));
    assert(metadata->base.release(&metadata->base) && atomic_load(&req.refs) == 1);
    assert(atomic_load(&stats->hits) == baseline);
    puts("PASS native navigation, copied callback/initiator ownership, download/type/metadata and author-header refusals");
}

static void cross_origin_contract(const char *url) {
    char path[512], authority[256];
    snprintf(authority, sizeof(authority), "%.*s", (int)strlen(url) - 1, url);
    unsigned baseline = atomic_load(&stats->hits);
    const int rejected[] = {RT_XHR, RT_SUB_RESOURCE, RT_IMAGE, RT_MEDIA, RT_WORKER, RT_SHARED_WORKER,
        RT_OBJECT, RT_PING, RT_CSP_REPORT, RT_SERVICE_WORKER, RT_PREFETCH, RT_FAVICON,
        RT_NAVIGATION_PRELOAD_MAIN_FRAME, RT_NAVIGATION_PRELOAD_SUB_FRAME};
    for (size_t i = 0; i < sizeof(rejected) / sizeof(*rejected); ++i) {
        struct sk_response r = exchange_as(url, "GET", "", 0, NULL, 0, 1, "http://other.example", 0, rejected[i]);
        assert(r.reason == SK_WEB_UNTRUSTED_UNSUPPORTED); response_free(&r);
    }
    assert(atomic_load(&stats->hits) == baseline);
    const char *paths[] = {"static-script", "static-css", "static-font", "static-no-cors", "static-exact",
        "static-duplicate", "static-mime", "static-corp", "redirect"};
    const char headers[] = "Cookie\0a=one\0Referer\0http://other.example/secret\0";
    unsigned cookies = atomic_load(&stats->cookies), origins = atomic_load(&stats->origins);
    for (size_t i = 0; i < sizeof(paths) / sizeof(*paths); ++i) {
        snprintf(path, sizeof(path), "%s%s", url, paths[i]);
        int type = i == 1 ? RT_STYLESHEET : i == 2 ? RT_FONT_RESOURCE : RT_SCRIPT;
        struct sk_response r = exchange_as(path, "GET", headers, sizeof(headers) - 1, NULL, 0, 1, "http://other.example", 0, type);
        if (i < 3) assert(!r.reason && r.status == 200 && r.body_len == 5 && !header_count(&r, "Set-Cookie"));
        else assert(r.reason == SK_WEB_UNTRUSTED_UNSUPPORTED && !r.headers_len && !r.body_len);
        response_free(&r);
    }
    assert(atomic_load(&stats->cookies) == cookies && atomic_load(&stats->origins) == origins + 9);
    assert(atomic_load(&stats->hits) == baseline + 9); /* No redirect target was fetched. */
    struct sk_response r = exchange_as(path, "GET", "", 0, NULL, 0, 1, authority, 0, RT_XHR);
    assert(r.reason == SK_WEB_UNTRUSTED_UNSUPPORTED && !r.headers_len && !r.body_len); response_free(&r);
    snprintf(path, sizeof(path), "%sstatic-script", url);
    for (unsigned i = 0; i < 2; ++i) {
        r = exchange_as(path, "GET", "", 0, NULL, 0, 1, i ? "null" : "", 0, RT_SCRIPT);
        assert(r.reason == SK_WEB_UNTRUSTED_UNSUPPORTED && !r.body_len); response_free(&r);
        r = exchange_as(path, "GET", "", 0, NULL, 0, 1, i ? "null" : "", 0, RT_XHR);
        assert(r.reason == SK_WEB_UNTRUSTED_UNSUPPORTED); response_free(&r);
    }
    puts("PASS cross-origin active/body/canvas lanes fail closed; wildcard MIME-checked credential-free CDN resources and redirect refusal");
}

static void worker_classification(const char *url) {
    char authority[256]; snprintf(authority, sizeof(authority), "%.*s", (int)strlen(url) - 1, url);
    const char *sources[] = {authority, "http://other.example", "null", ""};
    unsigned baseline = atomic_load(&stats->hits);
    struct fake_request req;
    for (unsigned i = 0; i < 2; ++i) {
        for (unsigned j = 0; j < 4; ++j) {
            request_init(&req, url, "GET");
            req.type = i ? RT_SHARED_WORKER : RT_WORKER;
            cef_resource_handler_t *h = resource_as(&req, 1, sources[j], 0); assert(h);
            assert(((struct sk_handler *)h)->response.reason == SK_WEB_UNTRUSTED_UNSUPPORTED);
            struct fake_callback cb; callback_init(&cb); req_add(&req.cef.base);
            int handle;
            assert(!h->open(h, &req.cef, &handle, &cb.cef) && handle);
            assert(!atomic_load(&cb.refs) && !atomic_load(&cb.continued) && atomic_load(&req.refs) == 1);
            assert(h->base.release(&h->base));
        }
    }
    const cef_resource_type_t libraries[] = {RT_SCRIPT, RT_STYLESHEET, RT_FONT_RESOURCE};
    for (unsigned i = 0; i < 3; ++i) {
        for (unsigned j = 0; j < 4; ++j) {
            request_init(&req, url, "GET"); req.type = libraries[i];
            cef_resource_handler_t *h = resource_as(&req, 1, sources[j], 0); assert(h);
            assert(((struct sk_handler *)h)->response.reason == (j < 2 ? 0 : SK_WEB_UNTRUSTED_UNSUPPORTED));
            assert(atomic_load(&req.refs) == 1 && h->base.release(&h->base));
        }
    }
    assert(atomic_load(&stats->hits) == baseline);
    puts("PASS native worker/shared-worker refusals, opaque-initiator denial and document CDN classification/ownership");
}

static unsigned broker_children(void) {
    char path[128]; snprintf(path, sizeof(path), "/proc/%d/task/%d/children", sk_broker_pid, sk_broker_pid);
    FILE *file = fopen(path, "r"); assert(file);
    unsigned count = 0; int pid;
    while (fscanf(file, "%d", &pid) == 1) ++count;
    assert(!ferror(file)); fclose(file);
    return count;
}

static void cancellation_slots(const char *url, int slow_dns) {
    struct fake_request req[SK_JOBS];
    struct fake_callback cb[SK_JOBS];
    cef_resource_handler_t *handlers[SK_JOBS];
    char path[512]; snprintf(path, sizeof(path), "%sslow", url);
    if (slow_dns) strcpy(path, "http://sk-slow-dns.test/");
    unsigned baseline = atomic_load(slow_dns ? &stats->dns : &stats->hits);
    unsigned denials = atomic_load(&denial_count);
    for (unsigned i = 0; i < SK_JOBS; ++i) {
        request_init(&req[i], path, "GET"); callback_init(&cb[i]);
        handlers[i] = resource(&req[i], 1); assert(handlers[i]);
        req_add(&req[i].cef.base); int handle;
        assert(handlers[i]->open(handlers[i], &req[i].cef, &handle, &cb[i].cef) && !handle);
    }
    int64_t deadline = sk_now_ms() + 3000;
    while (atomic_load(slow_dns ? &stats->dns : &stats->hits) < baseline + SK_JOBS && sk_now_ms() < deadline) pause_ms(1);
    if (atomic_load(slow_dns ? &stats->dns : &stats->hits) != baseline + SK_JOBS || broker_children() != SK_JOBS)
        fprintf(stderr, "cancel fixture: slow_dns=%d entered=%u expected=%u denials=%d children=%u\n", slow_dns,
            atomic_load(slow_dns ? &stats->dns : &stats->hits), baseline + SK_JOBS, atomic_load(&denial_count), broker_children());
    assert(atomic_load(slow_dns ? &stats->dns : &stats->hits) == baseline + SK_JOBS && broker_children() == SK_JOBS);
    int64_t before = sk_now_ms();
    for (unsigned i = 0; i < SK_JOBS; ++i) handlers[i]->cancel(handlers[i]);
    wait_workers();
    while (broker_children() && sk_now_ms() - before < 1000) pause_ms(1);
    int64_t canceled_ms = sk_now_ms() - before;
    assert(!broker_children() && canceled_ms < 1000);
    for (unsigned i = 0; i < SK_JOBS; ++i) {
        assert(!atomic_load(&cb[i].refs) && !atomic_load(&cb[i].continued) && atomic_load(&req[i].refs) == 1);
        assert(handlers[i]->base.release(&handlers[i]->base));
    }
    assert(atomic_load(&denial_count) == (int)denials);
    int64_t recovered = sk_now_ms();
    for (unsigned i = 0; i < SK_JOBS; ++i) {
        request_init(&req[i], url, "GET"); callback_init(&cb[i]);
        handlers[i] = resource(&req[i], 1); assert(handlers[i]);
        req_add(&req[i].cef.base); int handle;
        assert(handlers[i]->open(handlers[i], &req[i].cef, &handle, &cb[i].cef));
    }
    wait_workers();
    for (unsigned i = 0; i < SK_JOBS; ++i) {
        assert(!((struct sk_handler *)handlers[i])->response.reason && atomic_load(&cb[i].continued) == 1);
        assert(!atomic_load(&cb[i].refs) && handlers[i]->base.release(&handlers[i]->base));
    }
    int64_t recovered_ms = sk_now_ms() - recovered;
    assert(recovered_ms < 3000 && atomic_load(&denial_count) == (int)denials);
    deadline = sk_now_ms() + 1000;
    while (broker_children() && sk_now_ms() < deadline) pause_ms(1);
    assert(!broker_children());
    printf("PASS 16 concurrent %s cancels kill/reap in %lldms; all 16 slots recover in %lldms\n",
        slow_dns ? "blocked DNS" : "blocked curl", (long long)canceled_ms, (long long)recovered_ms);
}

static void job_deadline(const char *url) {
    /* The job learns the loader's remaining budget and answers TIMEOUT inside it. */
    char path[512]; snprintf(path, sizeof(path), "%sslow", url);
    const uint32_t budget = 2000;
    int64_t before = sk_now_ms();
    struct sk_response r = exchange_budget(path, "GET", "", 0, NULL, 0, 1, "", 1, RT_MAIN_FRAME, budget);
    int64_t elapsed = sk_now_ms() - before;
    assert(r.reason == SK_WEB_UNTRUSTED_TIMEOUT && !r.headers_len && !r.body_len);
    assert(elapsed >= (int64_t)budget - SK_REPLY_MARGIN_MS - 100 && elapsed < (int64_t)budget);
    response_free(&r);
    printf("PASS slow job answers TIMEOUT after %lldms, inside its %ums loader budget\n", (long long)elapsed, budget);
}

static int handler_queued(cef_resource_handler_t *h) {
    pthread_mutex_lock(&sk_workers_lock);
    int queued = ((struct sk_handler *)h)->queued;
    pthread_mutex_unlock(&sk_workers_lock);
    return queued;
}

static void open_handler(struct fake_request *req, struct fake_callback *cb, cef_resource_handler_t **h,
                         const char *url) {
    request_init(req, url, "GET"); callback_init(cb);
    *h = resource(req, 1); assert(*h);
    req_add(&req->cef.base); int handle;
    assert((*h)->open(*h, &req->cef, &handle, &cb->cef) && !handle);
}

static void wait_hits(unsigned want) {
    int64_t deadline = sk_now_ms() + 3000;
    while (atomic_load(&stats->hits) < want && sk_now_ms() < deadline) pause_ms(1);
    assert(atomic_load(&stats->hits) == want);
}

static void queueing(const char *url) {
    char slow[512]; snprintf(slow, sizeof(slow), "%sslow", url);
    struct fake_request req[SK_JOBS], waiting_req, canceled_req;
    struct fake_callback cb[SK_JOBS], waiting_cb, canceled_cb;
    cef_resource_handler_t *h[SK_JOBS], *waiting, *canceled;
    unsigned baseline = atomic_load(&stats->hits);
    int denials = atomic_load(&denial_count);
    for (unsigned i = 0; i < SK_JOBS; ++i) open_handler(&req[i], &cb[i], &h[i], slow);
    wait_hits(baseline + SK_JOBS);
    /* The 17th is accepted and waits instead of failing. */
    open_handler(&waiting_req, &waiting_cb, &waiting, url);
    open_handler(&canceled_req, &canceled_cb, &canceled, url);
    assert(handler_queued(waiting) && handler_queued(canceled));
    /* A queued cancel drops the callback and queue reference without a denial or a fetch. */
    canceled->cancel(canceled);
    assert(!handler_queued(canceled) && !atomic_load(&canceled_cb.refs) && !atomic_load(&canceled_cb.continued));
    assert(canceled->base.release(&canceled->base));
    /* Fill the bounded queue; the next open is refused with a precise reason. */
    struct fake_request *fill_req = calloc(SK_QUEUE_CAP, sizeof(*fill_req));
    struct fake_callback *fill_cb = calloc(SK_QUEUE_CAP, sizeof(*fill_cb));
    cef_resource_handler_t **fill = calloc(SK_QUEUE_CAP, sizeof(*fill));
    assert(fill_req && fill_cb && fill);
    for (unsigned i = 0; i + 1 < SK_QUEUE_CAP; ++i) open_handler(&fill_req[i], &fill_cb[i], &fill[i], url);
    pthread_mutex_lock(&sk_workers_lock);
    assert(sk_queue_count == SK_QUEUE_CAP && sk_worker_count == SK_JOBS);
    pthread_mutex_unlock(&sk_workers_lock);
    struct fake_request full_req; struct fake_callback full_cb;
    request_init(&full_req, url, "GET"); callback_init(&full_cb);
    cef_resource_handler_t *full = resource(&full_req, 1); assert(full);
    req_add(&full_req.cef.base); int handle;
    assert(!full->open(full, &full_req.cef, &handle, &full_cb.cef) && handle);
    assert(((struct sk_handler *)full)->response.reason == SK_WEB_UNTRUSTED_QUEUE_FULL);
    assert(atomic_load(&denial_reason) == SK_WEB_UNTRUSTED_QUEUE_FULL && atomic_load(&denial_count) == denials + 1);
    assert(atomic_load(&denial_unsent) == 1);
    assert(!atomic_load(&full_cb.refs) && !atomic_load(&full_cb.continued) && full->base.release(&full->base));
    for (unsigned i = 0; i + 1 < SK_QUEUE_CAP; ++i) {
        fill[i]->cancel(fill[i]);
        assert(!atomic_load(&fill_cb[i].refs) && !atomic_load(&fill_cb[i].continued));
        assert(fill[i]->base.release(&fill[i]->base));
    }
    free(fill_req); free(fill_cb); free(fill);
    assert(atomic_load(&stats->hits) == baseline + SK_JOBS && handler_queued(waiting));
    /* Freeing one slot starts the waiting request, which then completes. */
    int64_t before = sk_now_ms();
    h[0]->cancel(h[0]);
    while (!atomic_load(&waiting_cb.continued) && sk_now_ms() - before < 3000) pause_ms(1);
    int64_t started_ms = sk_now_ms() - before;
    assert(atomic_load(&waiting_cb.continued) == 1);
    for (unsigned i = 1; i < SK_JOBS; ++i) h[i]->cancel(h[i]);
    wait_workers();
    struct sk_handler *done = (struct sk_handler *)waiting;
    assert(!done->response.reason && done->response.status == 200 && done->response.body_len == 5);
    assert(!atomic_load(&waiting_cb.refs) && waiting->base.release(&waiting->base));
    for (unsigned i = 0; i < SK_JOBS; ++i) {
        assert(!atomic_load(&cb[i].refs) && !atomic_load(&cb[i].continued) && h[i]->base.release(&h[i]->base));
    }
    assert(atomic_load(&stats->hits) == baseline + SK_JOBS + 1 && atomic_load(&denial_count) == denials + 1);
    printf("PASS 17th load queues and completes %lldms after a slot frees; queued cancel; %u-deep queue refuses QUEUE_FULL\n",
        (long long)started_ms, SK_QUEUE_CAP);
}

static void queue_deadline(const char *url) {
    char slow[512]; snprintf(slow, sizeof(slow), "%sslow", url);
    struct fake_request req[SK_JOBS + 1];
    struct fake_callback cb[SK_JOBS + 1];
    cef_resource_handler_t *h[SK_JOBS + 1];
    unsigned baseline = atomic_load(&stats->hits);
    int denials = atomic_load(&denial_count);
    for (unsigned i = 0; i < SK_JOBS; ++i) open_handler(&req[i], &cb[i], &h[i], slow);
    wait_hits(baseline + SK_JOBS);
    int64_t queued_at = sk_now_ms();
    open_handler(&req[SK_JOBS], &cb[SK_JOBS], &h[SK_JOBS], slow);
    assert(handler_queued(h[SK_JOBS]));
    wait_workers();
    int64_t queued_ms = sk_now_ms() - queued_at;
    /* Every slow load and the queued one end with TIMEOUT, the queued one by
     * its own deadline: time spent waiting for a slot counted against it. */
    for (unsigned i = 0; i <= SK_JOBS; ++i) {
        struct sk_handler *x = (struct sk_handler *)h[i];
        assert(x->response.reason == SK_WEB_UNTRUSTED_TIMEOUT && atomic_load(&cb[i].continued) == 1);
        assert(!atomic_load(&cb[i].refs) && h[i]->base.release(&h[i]->base));
    }
    assert(queued_ms < SK_TIMEOUT_MS + 1000);
    assert(atomic_load(&denial_count) == denials + (int)SK_JOBS + 1 && atomic_load(&denial_reason) == SK_WEB_UNTRUSTED_TIMEOUT);
    assert(atomic_load(&stats->hits) <= baseline + SK_JOBS + 1);
    printf("PASS 16 slow loads report TIMEOUT; the queued one too, %lldms after it was opened\n", (long long)queued_ms);
}

static void stdio_null(void) {
    int pipes[2][2];
    assert(!pipe(pipes[0]) && !pipe(pipes[1]));
    pid_t child = fork(); assert(child >= 0);
    if (!child) {
        if (!sk_close_inherited(pipes[0][0], pipes[0][1], pipes[1][0])) _exit(2);
        struct stat null, s;
        if (stat("/dev/null", &null)) _exit(3);
        for (int fd = 0; fd < 3; ++fd)
            if (fstat(fd, &s) || !S_ISCHR(s.st_mode) || s.st_rdev != null.st_rdev) _exit(4);
        /* The three kept descriptors moved to 3-5; nothing above them survives. */
        if (fcntl(6, F_GETFD) != -1 || errno != EBADF) _exit(5);
        _exit(0);
    }
    child_ok(child);
    for (int i = 0; i < 2; ++i) { close(pipes[i][0]); close(pipes[i][1]); }
    puts("PASS broker descriptor table: 0-2 reopened on /dev/null, inherited table closed above 5");
}

static void landlock_job(const char *scratch) {
    int abi = sk_landlock_probe();
    if (!abi) { puts("SKIP Landlock job confinement: kernel reports no Landlock ABI"); return; }
    int allowed = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0), other = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    struct sockaddr_in a = {.sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)}, b = a;
    socklen_t len = sizeof(a);
    assert(allowed >= 0 && other >= 0);
    assert(!bind(allowed, (struct sockaddr *)&a, sizeof(a)) && !listen(allowed, 1) && !getsockname(allowed, (struct sockaddr *)&a, &len));
    assert(!bind(other, (struct sockaddr *)&b, sizeof(b)) && !listen(other, 1) && !getsockname(other, (struct sockaddr *)&b, &len));
    char file[512]; snprintf(file, sizeof(file), "%s/landlock-write", scratch);
    pid_t child = fork(); assert(child >= 0);
    if (!child) {
        assert(!prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0));
        assert(sk_landlock_job(abi, ntohs(a.sin_port), 1));
        errno = 0; assert(open(file, O_WRONLY | O_CREAT | O_CLOEXEC, 0600) == -1 && errno == EACCES);
        errno = 0; assert(mkdir(file, 0700) == -1 && errno == EACCES);
        int fd = open("/proc/self/exe", O_RDONLY | O_CLOEXEC); assert(fd >= 0); close(fd);
        if (abi >= 4) {
            int s = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0); assert(s >= 0);
            errno = 0; assert(connect(s, (struct sockaddr *)&b, sizeof(b)) == -1 && errno == EACCES); close(s);
            s = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0); assert(s >= 0);
            assert(!connect(s, (struct sockaddr *)&a, sizeof(a))); close(s);
        }
        if (abi >= 6) { errno = 0; assert(kill(getppid(), 0) == -1 && errno == EPERM); }
        _exit(0);
    }
    child_ok(child);
    assert(access(file, F_OK) == -1 && errno == ENOENT);
    close(allowed); close(other);
    printf("PASS Landlock ABI %d job: no file writes/creation%s%s; reads still work\n", abi,
        abi >= 4 ? ", TCP connect only to the target port" : "", abi >= 6 ? ", no signals outside the job" : "");
}

static void temp_directory(char *out, size_t cap, const char *name) {
    const char *base = getenv("TMPDIR");
    if (!base || !*base) base = "/tmp";
    int n = snprintf(out, cap, "%s/%s-XXXXXX", base, name);
    assert(n > 0 && (size_t)n < cap && mkdtemp(out));
}

static void broker_tests(void) {
    stats = mmap(NULL, sizeof(*stats), PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    assert(stats != MAP_FAILED);
    atomic_init(&stats->hits, 0); atomic_init(&stats->cookies, 0); atomic_init(&stats->posts, 0);
    atomic_init(&stats->dns, 0); atomic_init(&stats->origins, 0);
    int listener = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0); assert(listener >= 0);
    struct sockaddr_in a = {.sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    assert(!bind(listener, (struct sockaddr *)&a, sizeof(a)) && !listen(listener, 16));
    socklen_t alen = sizeof(a); assert(!getsockname(listener, (struct sockaddr *)&a, &alen));
    pid_t parent = getpid(), http = fork(); assert(http >= 0);
    if (!http) server(listener, parent);
    close(listener);
    char directory[256]; temp_directory(directory, sizeof(directory), "wu");
    assert(!chmod(directory, 0755) && !sk_web_untrusted_start(directory, NULL));
    assert(!chmod(directory, 0700));
    assert(!setenv("http_proxy", "http://127.0.0.1:1", 1));
    assert(!setenv("ALL_PROXY", "socks5h://127.0.0.1:1", 1));
    assert(sk_web_untrusted_start(directory, NULL));
    /* The browser must stay dumpable for Chromium's namespace sandbox. */
    assert(prctl(PR_GET_DUMPABLE) == 1);
    assert(sk_web_untrusted_job_landlock() == (sk_landlock_probe() > 0));
    unsetenv("http_proxy"); unsetenv("ALL_PROXY");
    landlock_job(directory);
    concurrency();
    char url[256]; snprintf(url, sizeof(url), "http://127.0.0.1:%u/", ntohs(a.sin_port));
    struct sk_response r = exchange(url, "GET", "", 0, NULL, 0, 0);
    assert(r.reason == SK_WEB_UNTRUSTED_PRIVATE && !atomic_load(&stats->hits)); response_free(&r);
    char dns_url[256]; snprintf(dns_url, sizeof(dns_url), "http://localhost:%u/", ntohs(a.sin_port));
    r = exchange(dns_url, "GET", "", 0, NULL, 0, 0);
    assert(r.reason == SK_WEB_UNTRUSTED_PRIVATE && !atomic_load(&stats->hits)); response_free(&r);
    const char cookie[] = "Cookie\0a=one\0";
    r = exchange(url, "GET", cookie, sizeof(cookie) - 1, NULL, 0, 1);
    assert(!r.reason && r.status == 200 && r.body_len == 5 && !memcmp(r.body, "hello", 5));
    assert(header_count(&r, "Content-Security-Policy") == 3 && header_count(&r, "Set-Cookie") == 2);
    assert(header_count(&r, "Access-Control-Allow-Origin") == 1 && !header_count(&r, "Content-Length"));
    response_free(&r); assert(atomic_load(&stats->hits) == 1 && atomic_load(&stats->cookies) == 1);
    r = exchange(url, "HEAD", "", 0, NULL, 0, 1);
    assert(!r.reason && !r.body_len); response_free(&r);
    assert(atomic_load(&stats->cookies) == 1); /* No curl jar persisted the prior Set-Cookie. */
    unsigned baseline = atomic_load(&stats->hits);
    const char non_simple[] = "Origin\0https://other.example\0X-Test\0yes\0";
    const char injection[] = "Accept\0text/html\r\nHost: attacker.example\0";
    const char range[] = "Range\0bytes=0-1\0";
    r = exchange(url, "GET", non_simple, sizeof(non_simple) - 1, NULL, 0, 1);
    assert(r.reason == 2); response_free(&r);
    r = exchange(url, "GET", injection, sizeof(injection) - 1, NULL, 0, 1);
    assert(r.reason == 2); response_free(&r);
    r = exchange(url, "GET", range, sizeof(range) - 1, NULL, 0, 1);
    assert(r.reason == 2); response_free(&r);
    r = exchange(url, "PUT", "", 0, NULL, 0, 1); assert(r.reason == 2); response_free(&r);
    r = exchange(url, "POST", "", 0, "abc", 3, 1); assert(r.reason == 2); response_free(&r);
    r = exchange("file:///etc/passwd", "GET", "", 0, NULL, 0, 1); assert(r.reason == 2); response_free(&r);
    for (unsigned i = 0; i < 12; ++i) {
        struct sk_wire_request w = {.magic = SK_MAGIC, .url_len = 1, .method_len = 3, .budget_ms = SK_TIMEOUT_MS};
        if (!i) w.url_len = UINT32_MAX;
        if (i == 1) w.headers_len = SK_HEADER_CAP + 1;
        if (i == 2) w.body_len = SK_UPLOAD_CAP + 1;
        if (i == 3) w.method_len = 7;
        if (i == 4) w.allow_private = 2;
        if (i == 5) w.initiator_len = SK_URL_CAP + 1;
        if (i == 6) w.navigation = 2;
        if (i == 7) w.resource_type = RT_NUM_VALUES;
        if (i == 8) w.budget_ms = 0;
        if (i == 9) w.budget_ms = SK_TIMEOUT_MS + 1;
        if (i == 10) w.user_activation = 2;
        if (i == 11) w.fetch_initiator_len = SK_URL_CAP + 1;
        int fd = broker_connect(); int64_t deadline = sk_now_ms() + 2000;
        assert(sk_io(fd, &w, sizeof(w), 1, deadline));
        struct sk_wire_response answer; assert(sk_io(fd, &answer, sizeof(answer), 0, deadline));
        assert(answer.reason == 2 && !answer.headers_len && !answer.body_len); close(fd);
    }
    assert(atomic_load(&stats->hits) == baseline);
    char headers[512]; const char *origin = "Origin", *type = "Content-Type", *mime = "application/json";
    char authority[256]; snprintf(authority, sizeof(authority), "http://127.0.0.1:%u", ntohs(a.sin_port));
    size_t len = 0;
    memcpy(headers + len, origin, strlen(origin) + 1); len += strlen(origin) + 1;
    memcpy(headers + len, authority, strlen(authority) + 1); len += strlen(authority) + 1;
    memcpy(headers + len, type, strlen(type) + 1); len += strlen(type) + 1;
    memcpy(headers + len, mime, strlen(mime) + 1); len += strlen(mime) + 1;
    r = exchange_as(url, "POST", headers, len, "abc", 3, 1, authority, 0, RT_XHR); assert(!r.reason); response_free(&r);
    assert(atomic_load(&stats->posts) == 1);
    char path[512]; snprintf(path, sizeof(path), "%sredirect", url);
    baseline = atomic_load(&stats->hits);
    r = exchange(path, "GET", "", 0, NULL, 0, 1);
    assert(!r.reason && r.status == 302 && header_count(&r, "Location") == 1); response_free(&r);
    assert(atomic_load(&stats->hits) == baseline + 1);
    snprintf(path, sizeof(path), "%sgzip", url);
    r = exchange(path, "GET", "", 0, NULL, 0, 1);
    assert(!r.reason && r.body_len == 5 && !memcmp(r.body, "hello", 5));
    assert(!header_count(&r, "Content-Encoding") && !header_count(&r, "Content-Length")); response_free(&r);
    snprintf(path, sizeof(path), "%sbomb", url);
    r = exchange(path, "GET", "", 0, NULL, 0, 1); assert(r.reason == 3 && !r.body_len); response_free(&r);
    snprintf(path, sizeof(path), "%sheaders", url);
    r = exchange(path, "GET", "", 0, NULL, 0, 1); assert(r.reason == 3 && !r.headers_len); response_free(&r);
    puts("PASS broker allow/deny with server counters, malformed bounds, POST, cookies, redirect, decompression and caps");
    tls_verification();
    uploads(url);
    handlers(url);
    trusted_metadata(url);
    navigation_metadata();
    broker_metadata(url);
    broker_post_type(url);
    cross_origin_contract(url);
    worker_classification(url);
    cancellation_slots(url, 0);
    cancellation_slots(url, 1);
    job_deadline(url);
    queueing(url);
    queue_deadline(url);
    lifetime();

    /* A real CEF-style resource load still works after Internet socket creation
     * is denied in the browser process; the pre-fork broker stays unconfined. */
    assert(sk_web_untrusted_confine());
    handlers(url);
    snprintf(path, sizeof(path), "%sslow", url);
    struct fake_request req; request_init(&req, path, "GET");
    struct fake_callback cb; callback_init(&cb);
    cef_resource_handler_t *h = resource(&req, 1); assert(h);
    int handle; req_add(&req.cef.base);
    baseline = atomic_load(&stats->hits);
    assert(h->open(h, &req.cef, &handle, &cb.cef));
    int64_t deadline = sk_now_ms() + 2000;
    while (atomic_load(&stats->hits) == baseline && sk_now_ms() < deadline) pause_ms(1);
    assert(atomic_load(&stats->hits) == baseline + 1);
    unsigned prior_denials = atomic_load(&denial_count);
    int64_t before = sk_now_ms(); h->cancel(h); wait_workers();
    assert(sk_now_ms() - before < 1000 && !atomic_load(&cb.refs) && !atomic_load(&cb.continued));
    assert(atomic_load(&denial_count) == (int)prior_denials);
    assert(h->base.release(&h->base));
    pid_t broker = sk_broker_pid;
    /* Stop must drain an active loader too, not just a previously canceled one. */
    request_init(&req, path, "GET"); callback_init(&cb);
    h = resource(&req, 1); assert(h);
    req_add(&req.cef.base); assert(h->open(h, &req.cef, &handle, &cb.cef));
    deadline = sk_now_ms() + 2000;
    int connected = 0;
    while (!connected && sk_now_ms() < deadline) {
        pthread_mutex_lock(&((struct sk_handler *)h)->lock);
        connected = ((struct sk_handler *)h)->fd >= 0;
        pthread_mutex_unlock(&((struct sk_handler *)h)->lock);
        if (!connected) pause_ms(1);
    }
    assert(connected);
    sk_web_untrusted_stop();
    assert(!atomic_load(&cb.refs) && !atomic_load(&cb.continued));
    assert(atomic_load(&denial_count) == (int)prior_denials);
    assert(h->base.release(&h->base));
    assert(waitpid(broker, NULL, WNOHANG) == -1 && errno == ECHILD);
    assert(kill(-broker, 0) == -1 && errno == ESRCH);
    assert(!access(directory, F_OK) && !rmdir(directory));
    kill(http, SIGKILL); int status; assert(waitpid(http, &status, 0) == http);
    munmap(stats, sizeof(*stats));
    puts("PASS confined async fetch, immediate cancellation, broker/worker kill and reap");
}

/* A forward proxy that serves every request itself: SOCKS5 (any ATYP, logged)
 * or HTTP (request line logged). CONNECT is refused 403, so https proves the
 * tunnel target without a certificate. Never connects anywhere. */
static void proxy_conn(int fd) {
    int64_t deadline = sk_now_ms() + 3000;
    unsigned char first;
    char request[2048];
    size_t used = 0;
    if (!sk_io(fd, &first, 1, 0, deadline)) return;
    if (first == 5) {
        unsigned char count, methods[255], head[4], port[2];
        unsigned char choice[2] = {5, 0}, reply[10] = {5, 0, 0, 1, 0, 0, 0, 0, 0, 0};
        if (!sk_io(fd, &count, 1, 0, deadline) || !sk_io(fd, methods, count, 0, deadline) ||
            !sk_io(fd, choice, 2, 1, deadline) || !sk_io(fd, head, 4, 0, deadline)) return;
        pstats->socks_atyp = head[3];
        if (head[3] == 3) {
            unsigned char len;
            if (!sk_io(fd, &len, 1, 0, deadline) || !sk_io(fd, pstats->socks_host, len, 0, deadline)) return;
            pstats->socks_host[len] = 0;
        } else {
            unsigned char raw[16];
            size_t n = head[3] == 1 ? 4 : 16;
            if (!sk_io(fd, raw, n, 0, deadline)) return;
            inet_ntop(head[3] == 1 ? AF_INET : AF_INET6, raw, pstats->socks_host, sizeof(pstats->socks_host));
        }
        if (!sk_io(fd, port, 2, 0, deadline)) return;
        pstats->socks_port = (unsigned)port[0] << 8 | port[1];
        if (!sk_io(fd, reply, sizeof(reply), 1, deadline)) return;
    } else request[used++] = (char)first;
    while (used < sizeof(request) - 1 && !memmem(request, used, "\r\n\r\n", 4)) {
        struct pollfd f = {fd, POLLIN, 0};
        if (poll(&f, 1, 3000) <= 0) break;
        ssize_t n = recv(fd, request + used, sizeof(request) - 1 - used, 0);
        if (n <= 0) break;
        used += (size_t)n;
    }
    request[used] = 0;
    size_t line = strcspn(request, "\r\n");
    if (line >= sizeof(pstats->request_line)) line = sizeof(pstats->request_line) - 1;
    memcpy(pstats->request_line, request, line);
    pstats->request_line[line] = 0;
    atomic_fetch_add(&pstats->connections, 1);
    if (!strncmp(request, "CONNECT ", 8)) {
        const char refused[] = "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        sk_io(fd, (void *)refused, sizeof(refused) - 1, 1, deadline);
        return;
    }
    const char served[] = "HTTP/1.1 200 OK\r\nContent-Length: 7\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\nproxied";
    sk_io(fd, (void *)served, sizeof(served) - 1, 1, deadline);
}

static void proxy_server(int listener, pid_t parent) {
    close(STDIN_FILENO);
    assert(!prctl(PR_SET_PDEATHSIG, SIGKILL));
    if (getppid() != parent) _exit(1);
    signal(SIGPIPE, SIG_IGN);
    alarm(60);
    for (;;) {
        int fd = accept4(listener, NULL, NULL, SOCK_CLOEXEC);
        if (fd < 0) { if (errno == EINTR) continue; _exit(1); }
        proxy_conn(fd);
        close(fd);
    }
}

/* A loopback listener on family's loopback, 0 when the family is absent. */
static int proxy_listener(int family, unsigned *port) {
    int fd = socket(family, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return -1;
    struct sockaddr_storage address = {0};
    socklen_t len;
    if (family == AF_INET) {
        struct sockaddr_in *v4 = (struct sockaddr_in *)&address;
        v4->sin_family = AF_INET; v4->sin_addr.s_addr = htonl(INADDR_LOOPBACK); len = sizeof(*v4);
    } else {
        struct sockaddr_in6 *v6 = (struct sockaddr_in6 *)&address;
        v6->sin6_family = AF_INET6; v6->sin6_addr = in6addr_loopback; len = sizeof(*v6);
    }
    if (bind(fd, (struct sockaddr *)&address, len) || listen(fd, 16) ||
        getsockname(fd, (struct sockaddr *)&address, &len)) { close(fd); return -1; }
    *port = ntohs(family == AF_INET ? ((struct sockaddr_in *)&address)->sin_port : ((struct sockaddr_in6 *)&address)->sin6_port);
    return fd;
}

static void expect_proxy(int family, const char *address, unsigned port) {
    struct sockaddr_storage probe;
    set_address(&probe, address);
    assert(probe.ss_family == family);
    pstats->expect_family = family; pstats->expect_port = port;
    assert(sk_address_bytes((struct sockaddr *)&probe, pstats->expect_addr));
}

/* One routed exchange; returns the response with every observation reset first. */
static struct sk_response routed(const char *url, int allow) {
    pstats->request_line[0] = 0; pstats->socks_host[0] = 0; pstats->socks_atyp = 0; pstats->socks_port = 0;
    atomic_store(&pstats->sockets, 0); atomic_store(&pstats->foreign_sockets, 0);
    atomic_store(&pstats->observing, 1);
    struct sk_response r = exchange(url, "GET", "", 0, NULL, 0, allow);
    atomic_store(&pstats->observing, 0);
    return r;
}

/* sk_open_socket's routed allowance, driven directly: the proxy's address and
 * port, nothing else, whatever its address class. */
static void routed_allowance(void) {
    struct sk_proxy_target target;
    struct sockaddr_storage probe;
    set_address(&target.address, "127.0.0.1");
    struct sk_response r = {.port = 1080, .allow_private = 0, .proxy = &target};
    const struct { const char *address; unsigned port; int family; int opened; } cases[] = {
        {"127.0.0.1", 1080, AF_INET, 1},   /* the proxy: loopback, still allowed */
        {"127.0.0.2", 1080, AF_INET, 0},   /* the neighbour */
        {"127.0.0.1", 1081, AF_INET, 0},   /* another port */
        {"8.8.8.8", 1080, AF_INET, 0},     /* public is no excuse */
        {"::ffff:127.0.0.1", 1080, AF_INET6, 0}, /* same bytes, other family */
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(*cases); ++i) {
        set_address(&probe, cases[i].address);
        union { struct curl_sockaddr c; unsigned char room[sizeof(struct curl_sockaddr) + sizeof(struct sockaddr_storage)]; } u;
        memset(&u, 0, sizeof(u));
        u.c.family = cases[i].family; u.c.socktype = SOCK_STREAM; u.c.protocol = IPPROTO_TCP;
        u.c.addrlen = cases[i].family == AF_INET ? sizeof(struct sockaddr_in) : sizeof(struct sockaddr_in6);
        memcpy(&u.c.addr, &probe, u.c.addrlen);
        if (cases[i].family == AF_INET) ((struct sockaddr_in *)&u.c.addr)->sin_port = htons((uint16_t)cases[i].port);
        else ((struct sockaddr_in6 *)&u.c.addr)->sin6_port = htons((uint16_t)cases[i].port);
        r.port = 1080;
        int fd = sk_open_socket(&r, CURLSOCKTYPE_IPCXN, &u.c);
        assert((fd >= 0) == cases[i].opened);
        if (fd >= 0) close(fd);
        /* A refused candidate is never misreported as a private address. */
        assert(r.reason != SK_WEB_UNTRUSTED_PRIVATE);
        if (cases[i].opened) {
            /* Not for a non-connection purpose, nor a datagram socket. */
            assert(sk_open_socket(&r, CURLSOCKTYPE_ACCEPT, &u.c) == CURL_SOCKET_BAD);
            u.c.socktype = SOCK_DGRAM;
            assert(sk_open_socket(&r, CURLSOCKTYPE_IPCXN, &u.c) == CURL_SOCKET_BAD);
        }
    }
    puts("PASS routed connect allowance: exactly the proxy's address, family and port (loopback allowed, neighbours/ports/public/mapped refused)");
}

static void proxy_routes(void) {
    alarm(60);
    pstats = mmap(NULL, sizeof(*pstats), PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    stats = mmap(NULL, sizeof(*stats), PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    assert(pstats != MAP_FAILED && stats != MAP_FAILED);
    memset(pstats, 0, sizeof(*pstats)); memset(stats, 0, sizeof(*stats));
    routed_allowance();
    pid_t parent = getpid();
    /* The origin a direct path would reach: it must stay at zero hits. */
    int origin = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0); assert(origin >= 0);
    struct sockaddr_in oa = {.sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    socklen_t olen = sizeof(oa);
    assert(!bind(origin, (struct sockaddr *)&oa, sizeof(oa)) && !listen(origin, 16) && !getsockname(origin, (struct sockaddr *)&oa, &olen));
    pid_t origin_pid = fork(); assert(origin_pid >= 0);
    if (!origin_pid) server(origin, parent);
    close(origin);
    unsigned proxy_port = 0, proxy6_port = 0;
    int listener = proxy_listener(AF_INET, &proxy_port); assert(listener >= 0);
    pid_t proxy_pid = fork(); assert(proxy_pid >= 0);
    if (!proxy_pid) proxy_server(listener, parent);
    close(listener);
    int listener6 = proxy_listener(AF_INET6, &proxy6_port);
    pid_t proxy6_pid = -1;
    if (listener6 >= 0) {
        proxy6_pid = fork(); assert(proxy6_pid >= 0);
        if (!proxy6_pid) proxy_server(listener6, parent);
        close(listener6);
    }
    /* A port nothing listens on: bound, then closed. */
    unsigned dead_port = 0;
    int dead = proxy_listener(AF_INET, &dead_port); assert(dead >= 0); close(dead);

    char directory[256]; temp_directory(directory, sizeof(directory), "wp");
    assert(!chmod(directory, 0700));
    char proxy[128], url[256];
    /* Outside the grammar: refused before any broker exists. */
    const char *refused[] = {"socks5://127.0.0.1:1080", "https://127.0.0.1:1080", "http://u@127.0.0.1:1080",
        "http://127.0.0.1", "http://127.0.0.1:", "http://127.0.0.1:1080/", "http://127.0.0.1:0",
        "http://::1:1080", "http://[::1]", "socks5h://127.1:1080"};
    for (size_t i = 0; i < sizeof(refused) / sizeof(*refused); ++i)
        assert(!sk_web_untrusted_start(directory, refused[i]) && !sk_broker_pid && sk_lifetime_fd == -1);
    puts("PASS routed broker refuses socks5 (local DNS), other schemes, credentials, paths and missing/zero ports");

    /* HTTP proxy, plain http: absolute-form forwarding with the HOSTNAME. */
    snprintf(proxy, sizeof(proxy), "http://127.0.0.1:%u", proxy_port);
    assert(sk_web_untrusted_start(directory, proxy) && sk_proxy.on && !sk_proxy.socks);
    expect_proxy(AF_INET, "127.0.0.1", proxy_port);
    struct sk_response r = routed("http://origin" PAGE_SUFFIX ":8080/page", 0);
    assert(!r.reason && r.status == 200 && r.body_len == 7 && !memcmp(r.body, "proxied", 7)); response_free(&r);
    assert(!strcmp(pstats->request_line, "GET http://origin" PAGE_SUFFIX ":8080/page HTTP/1.1"));
    assert(atomic_load(&pstats->sockets) >= 1 && !atomic_load(&pstats->foreign_sockets));
    /* A loopback origin with allow_private 0: the proxy decides, and the real
     * origin listening at that very address sees nothing. */
    snprintf(url, sizeof(url), "http://127.0.0.1:%u/direct-would-hit", ntohs(oa.sin_port));
    r = routed(url, 0);
    assert(!r.reason && r.status == 200 && !memcmp(r.body, "proxied", 7)); response_free(&r);
    char line[300]; snprintf(line, sizeof(line), "GET %s HTTP/1.1", url);
    assert(!strcmp(pstats->request_line, line) && !atomic_load(&pstats->foreign_sockets));
    /* https: a CONNECT naming the host; the proxy's refusal fails the load. */
    r = routed("https://secure" PAGE_SUFFIX "/", 0);
    assert(r.reason == SK_WEB_UNTRUSTED_BROKER_FAILURE && !r.body_len); response_free(&r);
    assert(!strcmp(pstats->request_line, "CONNECT secure" PAGE_SUFFIX ":443 HTTP/1.1"));
    assert(!atomic_load(&pstats->foreign_sockets));
    sk_web_untrusted_stop();
    printf("PASS http proxy route: forward and CONNECT name the host, only %s:%u is dialled, loopback served by the proxy\n",
           "127.0.0.1", proxy_port);

    /* SOCKS5 with remote DNS, the proxy named by a hostname the BROKER resolves. */
    snprintf(proxy, sizeof(proxy), "socks5h://" PROXY_NAME ":%u", proxy_port);
    unsigned proxy_lookups = atomic_load(&pstats->proxy_dns);
    assert(sk_web_untrusted_start(directory, proxy) && sk_proxy.socks);
    r = routed("http://origin" PAGE_SUFFIX ":8080/socks", 0);
    assert(!r.reason && r.status == 200 && !memcmp(r.body, "proxied", 7)); response_free(&r);
    assert(pstats->socks_atyp == 3 && !strcmp(pstats->socks_host, "origin" PAGE_SUFFIX) && pstats->socks_port == 8080);
    assert(!strcmp(pstats->request_line, "GET /socks HTTP/1.1"));
    assert(atomic_load(&pstats->proxy_dns) > proxy_lookups && !atomic_load(&pstats->foreign_sockets));
    /* An IPv4 literal page host travels as written to the proxy (curl sends a
     * literal as ATYP 1; either way no lookup happens here). */
    snprintf(url, sizeof(url), "http://127.0.0.1:%u/literal", ntohs(oa.sin_port));
    r = routed(url, 0);
    assert(!r.reason && !memcmp(r.body, "proxied", 7)); response_free(&r);
    assert((pstats->socks_atyp == 1 || pstats->socks_atyp == 3) && !strcmp(pstats->socks_host, "127.0.0.1"));
    assert(pstats->socks_port == ntohs(oa.sin_port) && !atomic_load(&pstats->foreign_sockets));
    printf("PASS socks5h literal page host forwarded as ATYP %u\n", pstats->socks_atyp);
    sk_web_untrusted_stop();
    puts("PASS socks5h proxy route: CONNECT carries ATYP 3 and the hostname; the proxy name is the broker's only lookup");

    if (proxy6_pid > 0) {
        snprintf(proxy, sizeof(proxy), "socks5h://[::1]:%u", proxy6_port);
        assert(sk_web_untrusted_start(directory, proxy));
        expect_proxy(AF_INET6, "::1", proxy6_port);
        r = routed("http://six" PAGE_SUFFIX "/", 0);
        assert(!r.reason && !memcmp(r.body, "proxied", 7) && !atomic_load(&pstats->foreign_sockets)); response_free(&r);
        assert(pstats->socks_atyp == 3 && !strcmp(pstats->socks_host, "six" PAGE_SUFFIX));
        sk_web_untrusted_stop();
        puts("PASS socks5h proxy route over an IPv6 literal proxy ([::1])");
    } else puts("SKIP IPv6 literal proxy: no ::1 on this host");

    /* Unreachable proxy: the load fails; nothing falls back to the origin. */
    snprintf(proxy, sizeof(proxy), "http://127.0.0.1:%u", dead_port);
    assert(sk_web_untrusted_start(directory, proxy));
    expect_proxy(AF_INET, "127.0.0.1", dead_port);
    snprintf(url, sizeof(url), "http://127.0.0.1:%u/fallback", ntohs(oa.sin_port));
    r = routed(url, 1);
    assert(r.reason == SK_WEB_UNTRUSTED_BROKER_FAILURE && !r.body_len); response_free(&r);
    assert(atomic_load(&pstats->sockets) >= 1 && !atomic_load(&pstats->foreign_sockets));
    sk_web_untrusted_stop();
    puts("PASS unreachable proxy fails the load closed, even with allow_private, and dials nothing else");

    /* Never once did this process family resolve a page host, and the origin
     * the direct path would have reached saw no request at all. */
    assert(!atomic_load(&pstats->page_dns));
    assert(!atomic_load(&stats->hits));
    assert(!rmdir(directory));
    kill(proxy_pid, SIGKILL); assert(waitpid(proxy_pid, NULL, 0) == proxy_pid);
    if (proxy6_pid > 0) { kill(proxy6_pid, SIGKILL); assert(waitpid(proxy6_pid, NULL, 0) == proxy6_pid); }
    kill(origin_pid, SIGKILL); assert(waitpid(origin_pid, NULL, 0) == origin_pid);
    printf("PASS routed broker never resolved a page host (%u lookups) and the origin got %u direct hits\n",
           atomic_load(&pstats->page_dns), atomic_load(&stats->hits));
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    alarm(120);
    struct sk_curl curl;
    if (argc == 2 && !strcmp(argv[1], "--dependency-refusal")) {
        assert(!sk_curl_load(&curl));
        char directory[256]; temp_directory(directory, sizeof(directory), "wu-missing");
        assert(!sk_web_untrusted_start(directory, NULL) && !sk_broker_pid && sk_lifetime_fd == -1);
        assert(!rmdir(directory));
        struct fake_request req; request_init(&req, "https://example.com/", "GET");
        cef_resource_handler_t *h = resource(&req, 0);
        assert(h && atomic_load(&req.refs) == 1 && atomic_load(&denial_reason) == SK_WEB_UNTRUSTED_BROKER_FAILURE);
        struct fake_callback cb; callback_init(&cb); req_add(&req.cef.base);
        int handle; assert(!h->open(h, &req.cef, &handle, &cb.cef) && handle);
        assert(!atomic_load(&cb.refs) && !atomic_load(&cb.continued));
        assert(h->base.release(&h->base));
        puts("PASS missing/unusable libcurl refuses availability and broker startup");
        return 0;
    }
    assert(sk_curl_load(&curl)); dlclose(curl.handle);
    addresses(); own_addresses(); validation(); fetch_metadata(); confinement(); stdio_null();
    /* Its own process: it starts and stops routed brokers before the main
     * broker tests confine this one. */
    pid_t routes = fork(); assert(routes >= 0);
    if (!routes) { proxy_routes(); _exit(0); }
    child_ok(routes);
    broker_tests();
    puts("All web-untrusted native tests passed.");
    return 0;
}
#endif
#endif
