//! `zig build smoke-web` — end-to-end smoke for `sketerm-web`, the CEF
//! browser helper, and for `src/web/protocol.zig` as a CLIENT (the rig
//! encodes/decodes with the same module the helper speaks). Spawns the
//! helper on a short private socket with an isolated cache dir and
//! drives it through: handshake, painting into a memfd, a trusted
//! click, keyboard text entry, resize (new buffer), popup requests,
//! back/forward navigation state, the whole semantic layer (snapshot
//! with stable ids, mutation delta, trusted sem_act click, expand,
//! cross-navigation id carrying, reader extraction, query, spontaneous
//! churn coalescing with the history-mode replay), a hostile
//! page that tries to forge semantic replies and hijack the command
//! entry point, script evaluation (values, DOM refs, degradation,
//! throws, awaited promises), dropdowns (native <select> by option
//! text and a custom ARIA listbox, both driven with trusted clicks),
//! form validation state in the walk, HiDPI (physical buffers, logical
//! input), adaptive frame pacing (paints above the old 60fps ceiling, a
//! honoured cap, an idle page costing zero paints, the helper's
//! watchdog, input-to-paint latency), TLS interstitials against a real
//! self-signed server on loopback (a HELD request, cancelled, then
//! proceeded), and a clean shutdown on disconnect.
//!
//! Two stages assert what the ENGINE does rather than what the helper
//! does, because both surfaced as surprises: a gestureless
//! `window.open` never reaches the client at all (Chromium's own popup
//! blocker eats it, stage 6b), and an Alloy windowless browser never
//! asks the client for a permission handler (stage 22g). Each fails if
//! that changes, which is exactly when the client-side policy behind
//! it becomes reachable.
//!
//! The certificate stages need `openssl s_server`; a host without one
//! SKIPS them rather than failing, so the rig stays runnable anywhere.
//!
//! Every stage still drives `frame_request`s (~120/s in `Client.pump`,
//! what the GUI's frame-clock tick does), but since the internal-
//! scheduler default (`externalPacingLatency` in cefhost.zig) they are
//! advisory: paints arrive on the engine's own damage-driven schedule,
//! and the CAP travels as `view_max_fps` instead of as request spacing.
//!
//! The HiDPI stage runs LAST on purpose: its scale changes leave the
//! engine re-laying-out for a while, and running it mid-rig made the
//! popup stage's click miss often enough to matter.
//!
//! Headless by construction: the helper runs CEF with
//! `--ozone-platform=headless`, so no display is needed. Almost no
//! network is touched — every page is a data: URL and the one popup
//! target is `example.invalid`, which the helper cancels before any
//! load. The exception is the certificate stage, which talks to an
//! openssl server this rig started on LOOPBACK; nothing leaves the
//! machine there either.

const std = @import("std");
const c = @import("c.zig").c;
const proto = @import("web/protocol.zig");
const zpool = @import("wlhost/zpool.zig");
const mux_wire = @import("mux/wire.zig");
const webhints = @import("web/hints.zig");
const socks5 = @import("ipc/socks5.zig");

const view_id: u32 = 1;
/// The stage-22b view, created directly at a url.
const url_view_id: u32 = 2;
/// The stage-22c view: a page with NO background of its own.
const bare_view_id: u32 = 3;
/// The stage-22d view: discarded and revived.
const discard_view_id: u32 = 4;
/// The stage-28 view. Cookies need a REAL origin: a data: URL has an
/// opaque one and `document.cookie` there stores nothing at all, so
/// this view is the only one in the rig pointed at a loopback server.
const sitedata_view_id: u32 = 8;
/// The cookie stage 31's page sets from its own script.
const cookie_probe = "sk_probe";
const cookie_probe_value = "abcd1234";
/// Stage-26/27 views, each in its own identity context.
const egress_view_a: u32 = 5;
const egress_view_b: u32 = 6;
const egress_view_c: u32 = 7;

/// Pages under test. `#` MUST be percent-encoded inside a data: URL —
/// a raw one starts the fragment and truncates the document.
const red_page = "data:text/html,<body%20style=%22margin:0;background:%23ff0000%22></body>";
const blue_page = "data:text/html,<body%20style=%22margin:0;background:%230000ff%22></body>";
const click_page =
    "data:text/html,<html><body style=\"margin:0\">" ++
    "<button style=\"position:fixed;left:0;top:0;width:100vw;height:100vh;" ++
    "background:%230000ff;border:0\" " ++
    "onclick=\"document.title='result:trusted='+event.isTrusted+" ++
    "'%20x='+event.clientX+'%20y='+event.clientY+'%20detail='+event.detail\">" ++
    "</button></body></html>";
const input_page =
    "data:text/html,<body><input%20id=i%20autofocus%20" ++
    "oninput=%22document.title='typed:'+this.value%22></body>";
/// Opens a popup with NO user interaction behind it — the pop-under
/// case the GUI's default policy blocks. `window.open` from a load
/// handler carries no gesture, which is exactly what the flag says.
const popup_auto_page =
    "data:text/html,<body%20onload=%22window.open('https://auto.invalid/y')%22>auto</body>";

const popup_page =
    "data:text/html,<body%20style=%22margin:0%22>" ++
    "<div%20style=%22width:100vw;height:100vh%22%20" ++
    "onclick=%22window.open('https://example.invalid/x')%22></div></body>";

/// No background, no script, no styling: what a page looks like when it
/// says nothing about its canvas. The engine's own default has to be
/// opaque white, as in every browser — a windowless CEF browser defaults
/// to TRANSPARENT, which reaches a client as (0,0,0,0) and photographs
/// as a uniformly black page.
const bare_page = "data:text/html,<html><body>hi</body></html>";

/// A full-viewport download anchor, so a trusted centre click starts a
/// real engine download without any network: the payload rides a data:
/// url of its own. The bytes are what stage 22j asserts on disk.
const download_bytes = "HELLODOWNLOADBYTES";
const download_page =
    "data:text/html,<body%20style=%22margin:0%22>" ++
    "<a%20download=%22dl.bin%22%20href=%22data:application/octet-stream," ++ download_bytes ++ "%22%20" ++
    "style=%22display:block;width:100vw;height:100vh%22>save</a></body>";

/// Link-hints page: two on-screen links, a button, a disabled button
/// and a link scrolled far out of the viewport.
const hints_page =
    "data:text/html,<html><body>" ++
    "<a%20href=%22https://example.com/alpha%22>Alpha%20Link</a>%20" ++
    "<a%20href=%22https://example.com/beta%22>Beta%20Link</a>%20" ++
    "<button%20id=b>Press</button>%20" ++
    "<button%20disabled>Dead</button>" ++
    "<a%20href=%22https://example.com/far%22%20style=%22position:absolute;top:9000px%22>Far%20Link</a>" ++
    "</body></html>";
/// Stage 22e: both a checkable TITLE and a checkable COLOUR, so a
/// revived view can be shown to have loaded the SAME url again rather
/// than merely to have produced some pixels.
const discard_page =
    "data:text/html,<html><head><title>discard-me</title></head>" ++
    "<body%20style=%22margin:0;background:%2300ff00%22></body></html>";

/// Repaints on every animation frame, i.e. on every begin frame the
/// rig drives — the page whose achieved rate measures the ceiling.
const anim_page =
    "data:text/html,<body%20style=%22margin:0%22><div%20id=d%20style=%22width:100vw;height:100vh%22></div>" ++
    "<script>var%20i=0;function%20f(){i=(i+7)%25256;" ++
    "d.style.background='rgb('+i+',0,0)';requestAnimationFrame(f)}requestAnimationFrame(f);</script></body>";

/// No script, no animation, no caret: once it has painted it must never
/// paint again, however many frames are requested.
const static_page = "data:text/html,<body%20style=%22margin:0;background:%23336699%22>static</body>";

/// Static until it is clicked, then repaints once: the input-to-paint
/// latency probe.
const click_paint_page =
    "data:text/html,<body%20style=%22margin:0;background:%2300ff00%22%20" ++
    "onmousedown=%22document.body.style.background='%23ff00ff'%22>click</body>";

/// Long enough to be clamped at detail=1 (160 chars) so the truncation
/// marker and `sem_expand` have something to work on.
const long_text =
    "Alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu " ++
    "nu xi omicron pi rho sigma tau upsilon phi chi psi omega and then " ++
    "some more filler so that the clamp certainly bites before the end " ++
    "of this paragraph is reached ENDOFLONG";

/// A small form: heading, nav, labelled field, button that mutates one
/// paragraph and reports whether its click was trusted.
const form_page =
    "data:text/html,<html><body>" ++
    "<h1>Semantic Form</h1>" ++
    "<nav><a href=%23a>Alpha</a><a href=%23b>Beta</a><a href=%23c>Gamma</a></nav>" ++
    "<form><label for=n>Name</label><input id=n>" ++
    "<button id=go onclick=\"document.title='clicked:trusted='+event.isTrusted;" ++
    "document.getElementById('lbl').textContent='after'\">Go</button></form>" ++
    "<p id=lbl>before</p><p id=long>" ++ long_text ++ "</p></body></html>";

/// Two pages sharing a byte-identical nav block: the cross-navigation
/// fingerprint match must carry that block's ids.
const shared_nav =
    "<nav><a href=%23one>One</a><a href=%23two>Two</a><a href=%23three>Three</a>" ++
    "<a href=%23four>Four</a><a href=%23five>Five</a><a href=%23six>Six</a></nav>";
const nav_page_a = "data:text/html,<html><body>" ++ shared_nav ++ "<h1>Alpha Page</h1></body></html>";
const nav_page_b = "data:text/html,<html><body>" ++ shared_nav ++ "<h1>Beta Page</h1></body></html>";

const article_page =
    "data:text/html,<html><head><title>Journal</title></head><body>" ++
    "<nav><a href=%23x>Nav One</a><a href=%23y>Nav Two</a></nav>" ++
    "<article><h1>Article Heading</h1><p>" ++ long_text ++ "</p>" ++
    "<p>A second paragraph so the extractor has real text density.</p></article>" ++
    "</body></html>";

/// Dropdowns: a native <select> and a hand-rolled ARIA combobox whose
/// options only exist in the DOM while it is open. The old
/// browser_choose handled both, so web_act set_value must too.
const dropdown_page =
    "data:text/html,<html><body>" ++
    "<label%20for=cty>Country</label>" ++
    "<select%20id=cty%20onchange=%22document.title='native:'+this.value%22>" ++
    "<option%20value=be>Belgium</option><option%20value=nl>Netherlands</option>" ++
    "<option%20value=fr>France</option></select>" ++
    "<div%20id=combo%20role=combobox%20aria-expanded=false%20aria-haspopup=listbox%20tabindex=0" ++
    "%20style=%22border:1px%20solid%20%23000;width:200px;height:30px%22>Pick%20a%20fruit</div>" ++
    "<div%20id=list%20role=listbox%20style=%22display:none%22></div>" ++
    "<p%20id=chosen>none</p>" ++
    "<script>" ++
    "var%20combo=document.getElementById('combo'),list=document.getElementById('list');" ++
    "combo.addEventListener('click',function(ev){" ++
    "if(!ev.isTrusted){document.title='UNTRUSTED';return;}" ++
    "list.style.display='block';combo.setAttribute('aria-expanded','true');" ++
    "list.innerHTML='';" ++
    "['Apple','Banana','Cherry'].forEach(function(t){" ++
    "var%20o=document.createElement('div');o.setAttribute('role','option');" ++
    "o.style.height='24px';o.textContent=t;" ++
    "o.addEventListener('click',function(e2){" ++
    "if(!e2.isTrusted){document.title='UNTRUSTEDOPT';return;}" ++
    "combo.textContent=t;document.getElementById('chosen').textContent=t;" ++
    "list.style.display='none';combo.setAttribute('aria-expanded','false');" ++
    "document.title='picked:'+t;});" ++
    "list.appendChild(o);});});" ++
    "</script></body></html>";

/// Form validation state: required + empty (so :invalid holds), a
/// disabled control, a checked box and a password with a value.
const validation_page =
    "data:text/html,<html><body><form>" ++
    "<label%20for=em>Email</label><input%20id=em%20type=email%20required%20value=nope>" ++
    "<label%20for=pw>Password</label><input%20id=pw%20type=password%20value=hunter22>" ++
    "<label%20for=tos>Terms</label><input%20id=tos%20type=checkbox%20checked>" ++
    "<button%20id=dis%20disabled>Submit</button>" ++
    "</form></body></html>";

/// A page that mutates on its own: each timer tick rebuilds the SAME
/// six rows under fresh DOM nodes and blinks a popup in and out. Twelve
/// ticks per phase (popup ends removed, list content identical), a
/// phase per trusted click, `churn:done<phase>` in the title when one
/// finishes. What the coalescing stage feeds the shadow tree.
const churn_page =
    "data:text/html,<html><body><h1>Churn</h1><ul%20id=list></ul><p>steady</p>" ++
    "<script>" ++
    "var%20phase=0,cycles=0,timer=null;" ++
    "function%20rows(){var%20l=document.getElementById('list');l.innerHTML='';" ++
    "['Alpha%20row%20one','Beta%20row%20two','Gamma%20row%20three','Delta%20row%20four'," ++
    "'Epsilon%20row%20five','Zeta%20row%20six']" ++
    ".forEach(function(t){var%20li=document.createElement('li');li.textContent=t;l.appendChild(li);});}" ++
    "function%20tick(){cycles++;rows();" ++
    "var%20p=document.getElementById('pop');" ++
    "if(p){p.remove();}else{var%20d=document.createElement('div');d.id='pop';" ++
    "d.setAttribute('role','alert');d.textContent='Popup%20flash';document.body.appendChild(d);}" ++
    "if(cycles>=12){clearInterval(timer);timer=null;document.title='churn:done'+phase;}}" ++
    "function%20start(){phase++;cycles=0;timer=setInterval(tick,180);}" ++
    "rows();" ++
    "document.addEventListener('mousedown',function(e){if(e.isTrusted&&!timer)start();});" ++
    "</script></body></html>";

/// A page that attacks the semantic layer from the inside: at parse
/// time (before its own load event) and again after it, it hunts for
/// any reachable transport, tries to post a forged snapshot through
/// every one it finds, and tries to overwrite the command entry point.
/// It reports what it managed through the title; the real DOM below it
/// is what a snapshot must still show.
const attack_page =
    "data:text/html,<html><body><h1>Attack%20Page</h1><p%20id=truth>REALCONTENT</p><script>" ++
    "(function(){" ++
    "var%20names=[\"__sketermSemPost\",\"__sketermSem\",\"__sketermSemCmd\",\"sketermSem\",\"semPost\"];" ++
    // The marker is assembled from halves so that the page's own URL,
    // which every snapshot header echoes, cannot match the assertion.
    "var%20mark=\"FORGED\"+\"MARKER\";" ++
    "var%20forged='{\"op\":\"tree\",\"req\":REQ,\"doc\":424242,\"url\":\"about:'+'forged\",\"nodes\":" ++
    "[{\"id\":1,\"parent\":0,\"role\":\"document\",\"name\":\"'+mark+'\",\"value\":\"\",\"states\":\"\"," ++
    "\"x\":0,\"y\":0,\"w\":0,\"h\":0,\"full\":12}]}';" ++
    "function%20attack(){" ++
    "var%20hit=0,posted=0,slots=0,ovr=0;" ++
    "for(var%20i=0;i<names.length;i++){" ++
    "var%20f=window[names[i]];" ++
    "if(typeof%20f!==\"undefined\")hit++;" ++
    "if(typeof%20f===\"function\"){try{f(forged.replace(\"REQ\",\"0\"));posted++;}catch(e){}}" ++
    "if(f&&typeof%20f.cmd===\"function\"){try{f.cmd(forged.replace(\"REQ\",\"0\"));posted++;}catch(e){}}}" ++
    "var%20own=Object.getOwnPropertyNames(window);" ++
    "for(var%20k=0;k<own.length;k++){" ++
    "var%20n=own[k];" ++
    "if(!/^[0-9a-f]{32}$/.test(n))continue;" ++
    "var%20g=window[n];" ++
    "if(typeof%20g!==\"function\")continue;" ++
    "slots++;" ++
    "for(var%20r=0;r<4;r++){try{g(forged.replace(\"REQ\",String(r)));}catch(e){}}" ++
    "try{window[n]=function(){};}catch(e){}" ++
    "try{Object.defineProperty(window,n,{value:function(){}});}catch(e){}" ++
    "if(window[n]!==g)ovr++;}" ++
    "return%20\"hit=\"+hit+\"%20posted=\"+posted+\"%20slots=\"+slots+\"%20ovr=\"+ovr;}" ++
    "var%20early=attack();" ++
    "setTimeout(function(){document.title=\"attack%20early:\"+early+\"%20late:\"+attack();},50);" ++
    "})();</script></body></html>";

/// A page whose only subresource is an image on a seeded-blocked host
/// (doubleclick.net is in the built-in seed list). The request is
/// CANCELLED at on_before_resource_load, before any network — so this
/// stays network-free like every other page here, and the blocked
/// entry proves the filter engine ran inline.
const blocked_img_page =
    "data:text/html,<body><img%20src=%22https://doubleclick.net/ad.gif%22></body>";

// Stage 28: one element a cosmetic rule hides, one it must not touch.
const cosmetic_page =
    "data:text/html,<body><div%20class=%22smoke-ad%22>AD</div><div%20id=%22keep%22>KEEP</div></body>";

// Stages 29/30: two distinct pages so a userstyle can prove it
// survives a navigation.
const usc_page_a = "data:text/html,<body%20id=%22pa%22><p>alpha</p></body>";
const usc_page_b = "data:text/html,<body%20id=%22pb%22><p>beta</p></body>";

// A document-end userscript that mutates the DOM. `@include data:*`
// because MV2 match patterns require an authority and data: urls have
// none — the include glob is the covered path here.
const usc_source =
    "// ==UserScript==\n" ++
    "// @name Smoke DOM\n" ++
    "// @include data:*\n" ++
    "// @run-at document-end\n" ++
    "// @grant none\n" ++
    "// ==/UserScript==\n" ++
    "document.title='us-end-ok';" ++
    "var el=document.createElement('div');el.id='usmark';" ++
    "el.textContent='FROM-USERSCRIPT';document.body.appendChild(el);";

// Cleanup state: `fail` may fire from anywhere, and the helper must
// never be left running nor the temp dir behind. Killed by EXACT pid.
var g_pid: c.pid_t = -1;
/// The stage-28 private mux daemon, killed by EXACT pid.
var g_mux_pid: c.pid_t = -1;
var g_dir: [64]u8 = @splat(0);

fn say(msg: []const u8) void {
    _ = c.write(2, msg.ptr, msg.len);
    _ = c.write(2, "\n", 1);
}

fn cleanup() void {
    if (g_pid > 0) {
        _ = c.kill(g_pid, c.SIGKILL);
        var status: c_int = 0;
        _ = c.waitpid(g_pid, &status, 0);
        g_pid = -1;
    }
    if (g_mux_pid > 0) {
        _ = c.kill(g_mux_pid, c.SIGKILL);
        var status: c_int = 0;
        _ = c.waitpid(g_mux_pid, &status, 0);
        g_mux_pid = -1;
    }
    if (g_dir[0] != 0) {
        removeTree(@ptrCast(&g_dir));
        g_dir[0] = 0;
    }
}

fn fail(comptime msg: []const u8) noreturn {
    say("smoke-web: FAIL " ++ msg);
    cleanup();
    std.process.exit(1);
}

/// The whole snapshot line containing `needle`, for asserting on the
/// states of ONE node rather than on the whole log.
fn lineContaining(hay: []const u8, needle: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, hay, needle) orelse return null;
    const start = if (std.mem.lastIndexOfScalar(u8, hay[0..at], '\n')) |i| i + 1 else 0;
    const end = std.mem.indexOfScalarPos(u8, hay, at, '\n') orelse hay.len;
    return hay[start..end];
}

fn pass(comptime msg: []const u8) void {
    say("smoke-web: PASS " ++ msg);
}

fn nowMs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.tv_sec) * 1000 + @divTrunc(ts.tv_nsec, 1_000_000);
}

fn nowUs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.tv_sec) * 1_000_000 + @divTrunc(ts.tv_nsec, 1_000);
}

/// `rm -rf` by subprocess: the cache dir is a Chromium profile, and a
/// hand-rolled recursive unlink buys nothing in a test rig.
fn removeTree(path: [*:0]const u8) void {
    const pid = c.fork();
    if (pid < 0) return;
    if (pid == 0) {
        var argv: [4:null]?[*:0]const u8 = @splat(null);
        argv[0] = "rm";
        argv[1] = "-rf";
        argv[2] = path;
        _ = c.execv("/bin/rm", @ptrCast(@constCast(&argv)));
        c._exit(127);
    }
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
}

/// An in-process SOCKS5 server on loopback that records the FIRST
/// CONNECT it is asked to make and whether it arrived as atyp=domain.
/// It is the probe behind the egress stages: a per-context proxy the
/// engine is pointed at, exactly as the browser spike proved, so a
/// navigation on that context proves its request context routed through
/// the proxy WITH the hostname unresolved (remote DNS). Uses the shared
/// `socks5.zig` codec so the rig exercises the same parser the bridge
/// does. The connection is answered `succeeded` and then closed, so the
/// page load itself fails — the assertion is only that the CONNECT was
/// seen through the proxy.
const ProxyProbe = struct {
    fd: c_int = -1,
    port: u16 = 0,
    thread: ?std.Thread = null,
    stop: std.atomic.Value(bool) = .init(false),
    got: std.atomic.Value(bool) = .init(false),
    host: [256]u8 = @splat(0),
    host_len: usize = 0,
    atyp_domain: bool = false,

    fn start(self: *ProxyProbe) bool {
        const lfd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
        if (lfd < 0) return false;
        var one: c_int = 1;
        _ = c.setsockopt(lfd, c.SOL_SOCKET, c.SO_REUSEADDR, &one, @sizeOf(c_int));
        var sa = std.mem.zeroes(c.struct_sockaddr_in);
        sa.sin_family = c.AF_INET;
        sa.sin_port = std.mem.nativeToBig(u16, 0);
        sa.sin_addr.s_addr = std.mem.nativeToBig(u32, c.INADDR_LOOPBACK);
        if (c.bind(lfd, @ptrCast(&sa), @sizeOf(c.struct_sockaddr_in)) != 0 or c.listen(lfd, 16) != 0) {
            _ = c.close(lfd);
            return false;
        }
        var got = std.mem.zeroes(c.struct_sockaddr_in);
        var glen: c.socklen_t = @sizeOf(c.struct_sockaddr_in);
        if (c.getsockname(lfd, @ptrCast(&got), &glen) != 0) {
            _ = c.close(lfd);
            return false;
        }
        self.fd = lfd;
        self.port = std.mem.bigToNative(u16, got.sin_port);
        self.thread = std.Thread.spawn(.{}, ProxyProbe.serve, .{self}) catch {
            _ = c.close(lfd);
            self.fd = -1;
            return false;
        };
        return true;
    }

    fn serve(self: *ProxyProbe) void {
        while (!self.stop.load(.acquire)) {
            var pfd = c.struct_pollfd{ .fd = self.fd, .events = c.POLLIN, .revents = 0 };
            if (c.poll(@ptrCast(&pfd), 1, 200) <= 0) continue;
            const afd = c.accept(self.fd, null, null);
            if (afd < 0) continue;
            self.handle(afd);
            _ = c.close(afd);
        }
    }

    fn handle(self: *ProxyProbe, afd: c_int) void {
        // Record only the FIRST CONNECT: a browser may open several
        // connections (retries after the tunnel closes, sub-resources),
        // and a later one overwriting the record would race the reader.
        // A later connection is simply refused a no-auth handshake so it
        // closes without disturbing the recorded host.
        if (self.got.load(.acquire)) {
            const mr0 = socks5.methodReply(false);
            _ = c.write(afd, &mr0, mr0.len);
            return;
        }
        var acc: [1024]u8 = undefined;
        var acc_len: usize = 0;
        // Greeting.
        const g = readGreeting(afd, &acc, &acc_len) orelse return;
        const mr = socks5.methodReply(g.offers_no_auth);
        _ = c.write(afd, &mr, mr.len);
        if (!g.offers_no_auth) return;
        std.mem.copyForwards(u8, acc[0 .. acc_len - g.consumed], acc[g.consumed..acc_len]);
        acc_len -= g.consumed;
        // Request.
        const r = readRequest(afd, &acc, &acc_len) orelse return;
        switch (r.addr) {
            .domain => |d| {
                self.host_len = @min(d.len, self.host.len);
                @memcpy(self.host[0..self.host_len], d[0..self.host_len]);
                self.atyp_domain = true;
            },
            .ipv4 => |ip| {
                const s = std.fmt.bufPrint(&self.host, "{d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] }) catch "";
                self.host_len = s.len;
                self.atyp_domain = false;
            },
            .ipv6 => {},
        }
        self.got.store(true, .release);
        const rep = socks5.connectReply(.ok);
        _ = c.write(afd, &rep, rep.len);
    }

    fn fill(afd: c_int, acc: *[1024]u8, acc_len: *usize) bool {
        var pfd = c.struct_pollfd{ .fd = afd, .events = c.POLLIN, .revents = 0 };
        if (c.poll(@ptrCast(&pfd), 1, 500) <= 0) return true;
        if (acc_len.* >= acc.len) return false;
        const n = c.read(afd, acc.ptr + acc_len.*, acc.len - acc_len.*);
        if (n <= 0) return false;
        acc_len.* += @intCast(n);
        return true;
    }

    fn readGreeting(afd: c_int, acc: *[1024]u8, acc_len: *usize) ?socks5.Greeting {
        const deadline = nowMs() + 10_000;
        while (nowMs() < deadline) {
            if (socks5.parseGreeting(acc[0..acc_len.*]) catch return null) |g| return g;
            if (!fill(afd, acc, acc_len)) return null;
        }
        return null;
    }

    fn readRequest(afd: c_int, acc: *[1024]u8, acc_len: *usize) ?socks5.Request {
        const deadline = nowMs() + 10_000;
        while (nowMs() < deadline) {
            if (socks5.parseRequest(acc[0..acc_len.*]) catch return null) |r| return r;
            if (!fill(afd, acc, acc_len)) return null;
        }
        return null;
    }

    fn seenHost(self: *ProxyProbe) ?[]const u8 {
        if (!self.got.load(.acquire)) return null;
        return self.host[0..self.host_len];
    }

    fn shutdown(self: *ProxyProbe) void {
        self.stop.store(true, .release);
        if (self.thread) |t| t.join();
        self.thread = null;
        if (self.fd >= 0) _ = c.close(self.fd);
        self.fd = -1;
    }
};

/// A one-page HTTP server on loopback: the only real ORIGIN this rig
/// serves, and the reason stages 31 and 33 can exist at all. A `data:`
/// URL's origin is opaque, so `document.cookie` on one stores nothing
/// and there would be no cookie to enumerate or clear; content scripts
/// likewise match `http://…` and never a `data:` url, which is where
/// they run in a real browser.
///
/// One document answers every request, favicon probes included, which
/// keeps the server to one branch. `body` is what that document is —
/// the cookie page by default, the WebExtensions fixture page when
/// stage 33 supplies its own. It answers on its own thread and is
/// stopped by `shutdown`.
const HttpProbe = struct {
    fd: c_int = -1,
    port: u16 = 0,
    thread: ?std.Thread = null,
    stop: std.atomic.Value(bool) = .init(false),
    /// Requests answered, so a stage can tell "the engine never asked"
    /// apart from "the engine asked and the cookie did not stick".
    served: std.atomic.Value(u32) = .init(0),
    /// The document served to every request.
    body: []const u8 = page,

    /// Sets the probe cookie from SCRIPT (not from a Set-Cookie
    /// header): what a site's own JavaScript stores is exactly what a
    /// site-data panel has to be able to show and delete.
    const page =
        "<html><head><title>cookie-page</title></head><body>cookies" ++
        "<script>document.cookie=\"" ++ cookie_probe ++ "=" ++ cookie_probe_value ++
        "; path=/; max-age=3600; SameSite=Lax\";" ++
        "document.title=\"cookie:\"+document.cookie;</script></body></html>";

    fn start(self: *HttpProbe) bool {
        const lfd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
        if (lfd < 0) return false;
        var one: c_int = 1;
        _ = c.setsockopt(lfd, c.SOL_SOCKET, c.SO_REUSEADDR, &one, @sizeOf(c_int));
        var sa = std.mem.zeroes(c.struct_sockaddr_in);
        sa.sin_family = c.AF_INET;
        sa.sin_port = std.mem.nativeToBig(u16, 0);
        sa.sin_addr.s_addr = std.mem.nativeToBig(u32, c.INADDR_LOOPBACK);
        if (c.bind(lfd, @ptrCast(&sa), @sizeOf(c.struct_sockaddr_in)) != 0 or c.listen(lfd, 16) != 0) {
            _ = c.close(lfd);
            return false;
        }
        var got = std.mem.zeroes(c.struct_sockaddr_in);
        var glen: c.socklen_t = @sizeOf(c.struct_sockaddr_in);
        if (c.getsockname(lfd, @ptrCast(&got), &glen) != 0) {
            _ = c.close(lfd);
            return false;
        }
        self.fd = lfd;
        self.port = std.mem.bigToNative(u16, got.sin_port);
        self.thread = std.Thread.spawn(.{}, HttpProbe.serve, .{self}) catch {
            _ = c.close(lfd);
            self.fd = -1;
            return false;
        };
        return true;
    }

    fn serve(self: *HttpProbe) void {
        while (!self.stop.load(.acquire)) {
            var pfd = c.struct_pollfd{ .fd = self.fd, .events = c.POLLIN, .revents = 0 };
            if (c.poll(@ptrCast(&pfd), 1, 200) <= 0) continue;
            const afd = c.accept(self.fd, null, null);
            if (afd < 0) continue;
            self.handle(afd);
            _ = c.close(afd);
        }
    }

    fn handle(self: *HttpProbe, afd: c_int) void {
        // Read whatever the request is and ignore it: one document
        // answers every path, which is all these stages need.
        var buf: [4096]u8 = undefined;
        var pfd = c.struct_pollfd{ .fd = afd, .events = c.POLLIN, .revents = 0 };
        if (c.poll(@ptrCast(&pfd), 1, 2000) > 0) _ = c.read(afd, &buf, buf.len);
        var head: [256]u8 = undefined;
        const hdr = std.fmt.bufPrint(
            &head,
            "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {d}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",
            .{self.body.len},
        ) catch return;
        _ = c.write(afd, hdr.ptr, hdr.len);
        _ = c.write(afd, self.body.ptr, self.body.len);
        _ = self.served.fetchAdd(1, .release);
    }

    fn shutdown(self: *HttpProbe) void {
        self.stop.store(true, .release);
        if (self.thread) |t| t.join();
        self.thread = null;
        if (self.fd >= 0) _ = c.close(self.fd);
        self.fd = -1;
    }
};

/// The client half of the v1 protocol: framing over a unix socket plus
/// the last-seen value of every event the stages assert on.
const Client = struct {
    gpa: std.mem.Allocator,
    fd: c_int,
    in: std.ArrayList(u8) = .empty,

    /// Descriptors harvested from SCM_RIGHTS, consumed in order by the
    /// `frame_buffer` frames they accompany.
    fds: [8]c_int = @splat(-1),
    nfds: usize = 0,

    ack_proto: u32 = 0,
    ack_shm: bool = false,
    ack_semantic: bool = false,
    ack_dmabuf: bool = false,
    ack_view_url: bool = false,
    ack_discard: bool = false,
    ack_tls: bool = false,
    ack_permissions: bool = false,
    ack_devtools: bool = false,
    ack_print_pdf: bool = false,
    ack_downloads: bool = false,
    ack_contexts: bool = false,
    ack_webext: bool = false,

    /// Last `ev_webext_state` observed (one extension in the stage).
    we_ok: u8 = 0xff,
    we_enabled: u8 = 0xff,
    we_name: [128]u8 = @splat(0),
    we_name_len: usize = 0,
    we_err: [256]u8 = @splat(0),
    we_err_len: usize = 0,

    /// Last `ev_webext_wreq_stats` observed (stage 34).
    wq_seen: bool = false,
    wq_matched: u32 = 0,
    wq_held: u32 = 0,
    wq_cancelled: u32 = 0,
    wq_redirected: u32 = 0,
    wq_headers_modified: u32 = 0,
    wq_hdr_recv_dropped: u32 = 0,
    wq_timed_out: u32 = 0,
    wq_failed_open: u32 = 0,

    fb: ?proto.FrameBuffer = null,
    fb_fd: c_int = -1,
    fb_seq: u32 = 0,
    map: []align(std.heap.page_size_min) u8 = &.{},

    dmg_buf: u32 = 0,
    dmg_seq: u32 = 0,

    /// Last GPU frame and how many arrived. `dma_ids` records the
    /// DISTINCT pool buffer ids seen, which is how the rig checks that
    /// the helper reports buffer identity rather than a fresh id per
    /// paint (the whole point of caching an import).
    dma: ?proto.FrameDmabuf = null,
    dma_seq: u32 = 0,
    dma_ids: [16]u32 = @splat(0),
    dma_nids: usize = 0,

    /// Frame pacing. The helper runs its browsers with external begin
    /// frames, so NOTHING paints unless this rig asks: every wait loop
    /// drives requests while it waits, exactly as the GUI's frame-clock
    /// tick does.
    have_view: bool = false,
    last_req_us: i64 = 0,
    req_count: u32 = 0,

    title: [1024]u8 = @splat(0),
    title_len: usize = 0,

    popup_view: u32 = 0,
    /// Gesture flag of the LAST popup request seen; the whole point of
    /// the GUI's popup policy, so the rig has to observe both values.
    popup_gesture: u8 = 0xff,
    popup_url: [1024]u8 = @splat(0),
    popup_len: usize = 0,

    /// Certificate errors seen: the held request the TLS interstitial
    /// exists for. `cert_seq` counts them, the rest describe the last.
    cert_seq: u32 = 0,
    cert_view: u32 = 0,
    cert_code: i32 = 0,
    cert_host: [256]u8 = @splat(0),
    cert_host_len: usize = 0,
    cert_fp: [128]u8 = @splat(0),
    cert_fp_len: usize = 0,
    /// Failed main-frame loads (`ev_load_error`), which is what a
    /// cancelled certificate decision produces.
    load_err_seq: u32 = 0,

    /// Permission prompts the helper is holding for us.
    perm_seq: u32 = 0,
    perm_id: u64 = 0,
    perm_types: u32 = 0,
    perm_origin: [256]u8 = @splat(0),
    perm_origin_len: usize = 0,

    nav_back: u8 = 0,
    nav_fwd: u8 = 0,
    nav_seq: u32 = 0,

    /// Main-frame load-finished counter. Waiting on a paint alone is
    /// not a settle: a repaint still queued from the PREVIOUS page (a
    /// resize, a scale change) satisfies it immediately, and the stage
    /// then drives input at a document that has not loaded yet.
    load_seq: u32 = 0,
    /// Finished loads of a BLANK document, whatever view they belong
    /// to. A view created with `view_create` and navigated afterwards
    /// produces one; a view created with `view_create_url` must not.
    blank_load_seq: u32 = 0,

    // Semantic layer. `sem_log` accumulates every payload since the
    // last reset (snapshots arrive unsolicited too, from the mutation
    // observer), while `sem_last` is the most recent one on its own —
    // which is what a "and NOT the siblings" assertion needs.
    sem_log: [64 * 1024]u8 = @splat(0),
    sem_log_len: usize = 0,
    sem_last: [16 * 1024]u8 = @splat(0),
    sem_last_len: usize = 0,
    sem_kind: u8 = 0,
    sem_seq: u32 = 0,

    act_id: u32 = 0,
    act_ok: u8 = 0,
    act_seq: u32 = 0,
    act_msg: [512]u8 = @splat(0),
    act_msg_len: usize = 0,

    exp_text: [8192]u8 = @splat(0),
    exp_len: usize = 0,
    exp_seq: u32 = 0,

    md: [32 * 1024]u8 = @splat(0),
    md_len: usize = 0,
    md_seq: u32 = 0,

    query_out: [16 * 1024]u8 = @splat(0),
    query_len: usize = 0,
    query_seq: u32 = 0,

    eval_json: [32 * 1024]u8 = @splat(0),
    eval_len: usize = 0,
    eval_ok: u8 = 0,
    eval_seq: u32 = 0,

    ack_intercept: bool = false,
    ack_userscripts: bool = false,
    // Interception: last coalesced status counters, and the last log
    // pull rendered to JSON.
    int_enabled: u8 = 1,
    int_blocked: u32 = 0,
    int_total: u32 = 0,
    int_rules: u32 = 0,
    int_status_seq: u32 = 0,
    int_log: [16 * 1024]u8 = @splat(0),
    int_log_len: usize = 0,
    int_log_next: u32 = 0,
    int_log_seq: u32 = 0,
    /// The inspector view the helper minted, and everything that
    /// belongs to IT rather than to the page being inspected. Frames
    /// are routed by view id the moment `dev_view` is known — which is
    /// why the helper announces the id BEFORE the view's first
    /// `frame_buffer`.
    dev_view: u32 = 0,
    dev_reply_seq: u32 = 0,
    dev_reason: [64]u8 = @splat(0),
    dev_reason_len: usize = 0,
    dev_fb: ?proto.FrameBuffer = null,
    dev_fb_fd: c_int = -1,
    dev_fb_seq: u32 = 0,
    dev_dmg_seq: u32 = 0,

    print_ok: u8 = 0,
    print_seq: u32 = 0,
    print_path: [1024]u8 = @splat(0),
    print_path_len: usize = 0,

    /// Downloads: the last held offer, and the last progress frame.
    dl_offer_seq: u32 = 0,
    dl_view: u32 = 0,
    dl_id: u32 = 0,
    dl_total: u64 = 0,
    dl_name: [256]u8 = @splat(0),
    dl_name_len: usize = 0,
    dl_url: [1024]u8 = @splat(0),
    dl_url_len: usize = 0,
    dl_prog_seq: u32 = 0,
    dl_prog_id: u32 = 0,
    dl_received: u64 = 0,
    dl_prog_total: u64 = 0,
    dl_done: u8 = 0,
    dl_failed: u8 = 0,
    ack_a11y: bool = false,
    ack_sitedata: bool = false,
    /// Cookies + site data. `cookie_names` is the last enumeration
    /// rendered one name per line, so an assertion can grep it; the
    /// counters are the last frame's.
    cookie_seq: u32 = 0,
    cookie_req: u32 = 0,
    cookie_ok: u8 = 0,
    cookie_total: u32 = 0,
    cookie_shown: u32 = 0,
    cookie_names: [4096]u8 = @splat(0),
    cookie_names_len: usize = 0,
    /// Cookie flags/scope of the LAST entry carrying `cookie_probe`, so
    /// the stage can assert metadata without a second enumeration.
    cookie_flags: u8 = 0,
    cookie_value_len: u32 = 0,
    site_done_seq: u32 = 0,
    site_done_req: u32 = 0,
    site_done_ok: u8 = 0,
    site_done_kind: u8 = 0,
    site_removed: u32 = 0,
    site_detail: [128]u8 = @splat(0),
    site_detail_len: usize = 0,
    ack_frames_inline: bool = false,
    /// Inline frame family (stage 32): pixels reassembled from
    /// `frame_inline` payloads, plus what the assertions need — the
    /// union area of the LAST frame's rects (damage economy) and
    /// whether deflate encoding was ever used.
    inline_pix: []u8 = &.{},
    iw: u16 = 0,
    ih: u16 = 0,
    inline_seq: u32 = 0,
    inline_last_area: u32 = 0,
    inline_deflate_seen: bool = false,
    /// Accessibility stream: every `ev_a11y_tree` node rendered as one
    /// `[id] role "name"` line, so assertions can grep roles + names.
    ax_log: [64 * 1024]u8 = @splat(0),
    ax_log_len: usize = 0,
    ax_seq: u32 = 0,
    ax_loc_seq: u32 = 0,
    ax_event_seq: u32 = 0,

    fn deinit(self: *Client) void {
        if (self.inline_pix.len != 0) self.gpa.free(self.inline_pix);
        self.unmap();
        if (self.fb_fd >= 0) _ = c.close(self.fb_fd);
        if (self.dev_fb_fd >= 0) _ = c.close(self.dev_fb_fd);
        for (self.fds[0..self.nfds]) |fd| _ = c.close(fd);
        self.in.deinit(self.gpa);
        if (self.fd >= 0) _ = c.close(self.fd);
        self.fd = -1;
    }

    fn unmap(self: *Client) void {
        if (self.map.len == 0) return;
        _ = c.munmap(self.map.ptr, self.map.len);
        self.map = &.{};
    }

    fn send(self: *Client, value: anytype) void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.gpa);
        proto.encode(self.gpa, &buf, value) catch fail("encode");
        var off: usize = 0;
        while (off < buf.items.len) {
            const n = c.write(self.fd, buf.items.ptr + off, buf.items.len - off);
            if (n <= 0) fail("write to helper");
            off += @intCast(n);
        }
    }

    /// Ask the helper for one frame, at most `min_gap_us` after the
    /// previous request.
    fn frameRequest(self: *Client, min_gap_us: i64) void {
        if (!self.have_view) return;
        const now = nowUs();
        if (now - self.last_req_us < min_gap_us) return;
        self.last_req_us = now;
        self.req_count += 1;
        self.send(proto.FrameRequest{ .view = view_id, .flags = 0 });
        // An inspector is an ordinary view: it paints when somebody
        // asks, exactly like the page it inspects.
        if (self.dev_view != 0) self.send(proto.FrameRequest{ .view = self.dev_view, .flags = 0 });
    }

    /// Wait for helper output while driving frames at ~120Hz — what the
    /// GUI's active tick does, and what every stage below needs in
    /// order to see any paint at all.
    fn pump(self: *Client, timeout_ms: c_int) void {
        const deadline = nowMs() + timeout_ms;
        while (true) {
            self.frameRequest(8_000);
            const left = deadline - nowMs();
            const slice: c_int = @intCast(std.math.clamp(left, 0, 8));
            if (self.pumpRaw(slice) or nowMs() >= deadline) return;
        }
    }

    /// Drive begin frames at `target_fps` for `duration_ms` and report
    /// what came back. The measurement primitive of the pacing stages.
    fn drive(self: *Client, duration_ms: i64, target_fps: i64) struct { requests: u32, paints: u32, ms: i64 } {
        const start = nowMs();
        const end = start + duration_ms;
        const req0 = self.req_count;
        const dmg0 = self.paintCount();
        const gap: i64 = if (target_fps <= 0) std.math.maxInt(i64) else @divTrunc(1_000_000, target_fps);
        while (nowMs() < end) {
            if (target_fps > 0) self.frameRequest(gap);
            _ = self.pumpRaw(1);
        }
        return .{
            .requests = self.req_count - req0,
            .paints = self.paintCount() - dmg0,
            .ms = nowMs() - start,
        };
    }

    /// Paints seen on ANY frame family: the software path reports
    /// `frame_damage`, the GPU path `frame_dmabuf`, the remote path
    /// `frame_inline` — the pacing assertions care only that pixels
    /// happened.
    fn paintCount(self: *const Client) u32 {
        return self.dmg_seq +% self.dma_seq +% self.inline_seq;
    }

    /// BGRA pixel of the reassembled INLINE surface.
    fn inlinePixel(self: *Client, x: u32, y: u32) [4]u8 {
        const off = (@as(usize, y) * @as(usize, self.iw) + @as(usize, x)) * 4;
        if (off + 4 > self.inline_pix.len) fail("inline pixel outside the surface");
        return .{ self.inline_pix[off], self.inline_pix[off + 1], self.inline_pix[off + 2], self.inline_pix[off + 3] };
    }

    /// Wait until the inline surface's centre matches `want` (BGR).
    fn waitInlineCenter(self: *Client, want: [3]u8, timeout_ms: i64) bool {
        const deadline = nowMs() + timeout_ms;
        while (true) {
            if (self.iw != 0 and self.ih != 0) {
                const px = self.inlinePixel(self.iw / 2, self.ih / 2);
                if (px[0] == want[0] and px[1] == want[1] and px[2] == want[2]) return true;
            }
            if (nowMs() > deadline) return false;
            self.pump(50);
        }
    }

    /// Read whatever is available (up to `timeout_ms`) and fold it into
    /// the observed state. Sends nothing.
    fn pumpRaw(self: *Client, timeout_ms: c_int) bool {
        var pfd = c.struct_pollfd{ .fd = self.fd, .events = c.POLLIN, .revents = 0 };
        if (c.poll(@ptrCast(&pfd), 1, timeout_ms) <= 0) return false;

        var buf: [64 * 1024]u8 = undefined;
        var iov = c.struct_iovec{ .iov_base = &buf, .iov_len = buf.len };
        var mh = std.mem.zeroes(c.struct_msghdr);
        mh.msg_iov = @ptrCast(&iov);
        mh.msg_iovlen = 1;
        var cbuf: [256]u8 align(@alignOf(c.struct_cmsghdr)) = std.mem.zeroes([256]u8);
        mh.msg_control = &cbuf;
        mh.msg_controllen = cbuf.len;

        const n = c.recvmsg(self.fd, &mh, 0);
        if (n == 0) fail("helper closed the socket");
        if (n < 0) {
            const e = std.c._errno().*;
            if (e == c.EINTR or e == c.EAGAIN) return false;
            fail("recvmsg");
        }
        self.harvestFds(&cbuf, @intCast(mh.msg_controllen));
        self.in.appendSlice(self.gpa, buf[0..@intCast(n)]) catch fail("oom");

        var reader = proto.Reader.init(self.in.items);
        while (reader.next() catch fail("malformed frame")) |frame| self.handle(frame);
        const used = reader.consumed();
        if (used != 0) {
            const rest = self.in.items.len - used;
            std.mem.copyForwards(u8, self.in.items[0..rest], self.in.items[used..]);
            self.in.shrinkRetainingCapacity(rest);
        }
        return true;
    }

    /// Walk the control buffer by hand — CMSG_* are macros translate-c
    /// does not export.
    fn harvestFds(self: *Client, cbuf: []align(@alignOf(c.struct_cmsghdr)) u8, len: usize) void {
        const hdr_size = @sizeOf(c.struct_cmsghdr);
        var off: usize = 0;
        while (off + hdr_size <= len) {
            const hdr: *const c.struct_cmsghdr = @ptrCast(@alignCast(&cbuf[off]));
            const clen: usize = @intCast(hdr.cmsg_len);
            if (clen < hdr_size or off + clen > len) break;
            if (hdr.cmsg_level == c.SOL_SOCKET and hdr.cmsg_type == c.SCM_RIGHTS) {
                var i: usize = 0;
                while (i + @sizeOf(c_int) <= clen - hdr_size) : (i += @sizeOf(c_int)) {
                    var fd: c_int = undefined;
                    @memcpy(std.mem.asBytes(&fd), cbuf[off + hdr_size + i ..][0..@sizeOf(c_int)]);
                    if (self.nfds == self.fds.len) fail("too many descriptors queued");
                    self.fds[self.nfds] = fd;
                    self.nfds += 1;
                }
            }
            off += std.mem.alignForward(usize, clen, @alignOf(c.struct_cmsghdr));
        }
    }

    fn takeFd(self: *Client) c_int {
        if (self.nfds == 0) fail("frame_buffer without an SCM_RIGHTS descriptor");
        const fd = self.fds[0];
        var i: usize = 1;
        while (i < self.nfds) : (i += 1) self.fds[i - 1] = self.fds[i];
        self.nfds -= 1;
        return fd;
    }

    fn handle(self: *Client, frame: proto.Frame) void {
        switch (frame.tag) {
            .hello_ack => {
                const ack = proto.HelloAck.decodeAlloc(frame.payload, self.gpa) catch fail("hello_ack decode");
                defer self.gpa.free(ack.caps);
                self.ack_proto = ack.proto;
                for (ack.caps) |cap| {
                    if (std.mem.eql(u8, cap, proto.CAP_FRAMES_SHM)) self.ack_shm = true;
                    if (std.mem.eql(u8, cap, proto.CAP_SEMANTIC)) self.ack_semantic = true;
                    if (std.mem.eql(u8, cap, proto.CAP_FRAMES_DMABUF)) self.ack_dmabuf = true;
                    if (std.mem.eql(u8, cap, proto.CAP_VIEW_CREATE_URL)) self.ack_view_url = true;
                    if (std.mem.eql(u8, cap, proto.CAP_INTERCEPT)) self.ack_intercept = true;
                    if (std.mem.eql(u8, cap, proto.CAP_DISCARD)) self.ack_discard = true;
                    if (std.mem.eql(u8, cap, proto.CAP_TLS)) self.ack_tls = true;
                    if (std.mem.eql(u8, cap, proto.CAP_PERMISSIONS)) self.ack_permissions = true;
                    if (std.mem.eql(u8, cap, proto.CAP_DEVTOOLS)) self.ack_devtools = true;
                    if (std.mem.eql(u8, cap, proto.CAP_PRINT_PDF)) self.ack_print_pdf = true;
                    if (std.mem.eql(u8, cap, proto.CAP_DOWNLOADS)) self.ack_downloads = true;
                    if (std.mem.eql(u8, cap, proto.CAP_A11Y)) self.ack_a11y = true;
                    if (std.mem.eql(u8, cap, proto.CAP_CONTEXTS)) self.ack_contexts = true;
                    if (std.mem.eql(u8, cap, proto.CAP_USERSCRIPTS)) self.ack_userscripts = true;
                    if (std.mem.eql(u8, cap, proto.CAP_SITEDATA)) self.ack_sitedata = true;
                    if (std.mem.eql(u8, cap, proto.CAP_FRAMES_INLINE)) self.ack_frames_inline = true;
                    if (std.mem.eql(u8, cap, proto.CAP_WEBEXT)) self.ack_webext = true;
                }
            },
            .frame_inline => {
                const fi = proto.FrameInline.decodeAlloc(frame.payload, self.gpa) catch fail("frame_inline decode");
                defer self.gpa.free(fi.rects);
                if (fi.w == 0 or fi.h == 0) fail("frame_inline with a zero surface");
                const size: usize = @as(usize, fi.w) * @as(usize, fi.h) * 4;
                if (fi.w != self.iw or fi.h != self.ih) {
                    if (self.inline_pix.len != 0) self.gpa.free(self.inline_pix);
                    self.inline_pix = self.gpa.alloc(u8, size) catch fail("oom");
                    @memset(self.inline_pix, 0);
                    self.iw = fi.w;
                    self.ih = fi.h;
                }
                var area: u32 = 0;
                for (fi.rects) |r| {
                    if (@as(u32, r.x) + r.w > fi.w or @as(u32, r.y) + r.h > fi.h)
                        fail("frame_inline rect outside the surface");
                    const raw_len: usize = @as(usize, r.w) * @as(usize, r.h) * 4;
                    const row_bytes: usize = @as(usize, r.w) * 4;
                    var decoded: []const u8 = undefined;
                    var scratch: ?[]u8 = null;
                    defer if (scratch) |sc| self.gpa.free(sc);
                    switch (r.enc) {
                        proto.inline_enc_raw => {
                            if (r.data.len != raw_len) fail("frame_inline raw length mismatch");
                            decoded = r.data;
                        },
                        proto.inline_enc_deflate => {
                            const sc = self.gpa.alloc(u8, raw_len) catch fail("oom");
                            scratch = sc;
                            decoded = zpool.decompress(r.data, sc) catch fail("frame_inline deflate corrupt");
                            self.inline_deflate_seen = true;
                        },
                        else => fail("frame_inline unknown encoding"),
                    }
                    var row: usize = 0;
                    while (row < r.h) : (row += 1) {
                        const off = (@as(usize, r.y) + row) * @as(usize, fi.w) * 4 + @as(usize, r.x) * 4;
                        @memcpy(self.inline_pix[off..][0..row_bytes], decoded[row * row_bytes ..][0..row_bytes]);
                    }
                    area += @as(u32, r.w) * @as(u32, r.h);
                }
                self.inline_last_area = area;
                self.inline_seq += 1;
            },
            .ev_a11y_tree => {
                const ev = proto.decode(proto.EvA11yTree, frame.payload) catch fail("ev_a11y_tree decode");
                self.ax_seq += 1;
                var it = proto.A11yNodeIter.init(ev.nodes.s);
                while (it.next() catch fail("ev_a11y_tree node decode")) |n| {
                    var line: [512]u8 = undefined;
                    const s = std.fmt.bufPrint(&line, "[{d}] {s} \"{s}\" s={x}\n", .{ n.id, n.role, n.name, n.state }) catch continue;
                    const room = self.ax_log.len - self.ax_log_len;
                    const take = @min(room, s.len);
                    @memcpy(self.ax_log[self.ax_log_len..][0..take], s[0..take]);
                    self.ax_log_len += take;
                }
            },
            .ev_cookies => {
                const ev = proto.EvCookies.decodeAlloc(frame.payload, self.gpa) catch fail("ev_cookies decode");
                defer self.gpa.free(ev.entries);
                self.cookie_seq += 1;
                self.cookie_req = ev.req;
                self.cookie_ok = ev.ok;
                self.cookie_total = ev.total;
                self.cookie_shown = @intCast(ev.entries.len);
                self.cookie_names_len = 0;
                for (ev.entries) |e| {
                    var line: [512]u8 = undefined;
                    const s = std.fmt.bufPrint(&line, "{s}\n", .{e.name}) catch continue;
                    const room = self.cookie_names.len - self.cookie_names_len;
                    const take = @min(room, s.len);
                    @memcpy(self.cookie_names[self.cookie_names_len..][0..take], s[0..take]);
                    self.cookie_names_len += take;
                    if (std.mem.eql(u8, e.name, cookie_probe)) {
                        self.cookie_flags = e.flags;
                        self.cookie_value_len = e.value_len;
                    }
                }
            },
            .ev_sitedata_done => {
                const ev = proto.decode(proto.EvSitedataDone, frame.payload) catch fail("ev_sitedata_done decode");
                self.site_done_seq += 1;
                self.site_done_req = ev.req;
                self.site_done_ok = ev.ok;
                self.site_done_kind = ev.kind;
                self.site_removed = ev.removed;
                self.site_detail_len = @min(ev.detail.len, self.site_detail.len);
                @memcpy(self.site_detail[0..self.site_detail_len], ev.detail[0..self.site_detail_len]);
            },
            .ev_a11y_loc => {
                _ = proto.decode(proto.EvA11yLoc, frame.payload) catch fail("ev_a11y_loc decode");
                self.ax_loc_seq += 1;
            },
            .ev_a11y_event => {
                _ = proto.decode(proto.EvA11yEvent, frame.payload) catch fail("ev_a11y_event decode");
                self.ax_event_seq += 1;
            },
            .frame_buffer => {
                const fb = proto.decode(proto.FrameBuffer, frame.payload) catch fail("frame_buffer decode");
                const fd = self.takeFd();
                if (self.dev_view != 0 and fb.view == self.dev_view) {
                    if (self.dev_fb_fd >= 0) _ = c.close(self.dev_fb_fd);
                    self.dev_fb_fd = fd;
                    self.dev_fb = fb;
                    self.dev_fb_seq += 1;
                    return;
                }
                self.unmap();
                if (self.fb_fd >= 0) _ = c.close(self.fb_fd);
                self.fb_fd = fd;
                self.fb = fb;
                self.fb_seq += 1;
            },
            .frame_dmabuf => {
                const f = proto.FrameDmabuf.decodeFrom(frame.payload) catch fail("frame_dmabuf decode");
                // One descriptor per plane, and each must name a real
                // object: a frame whose fds do not survive the trip is
                // a leak on one side and a black pane on the other.
                var i: usize = 0;
                while (i < f.nplanes) : (i += 1) {
                    const fd = self.takeFd();
                    var st: c.struct_stat = undefined;
                    if (c.fstat(fd, &st) != 0) fail("frame_dmabuf: a plane descriptor is not a live object");
                    _ = c.close(fd);
                }
                self.dma = f;
                self.dma_seq += 1;
                var known = false;
                for (self.dma_ids[0..self.dma_nids]) |id| {
                    if (id == f.buf_id) known = true;
                }
                if (!known and self.dma_nids < self.dma_ids.len) {
                    self.dma_ids[self.dma_nids] = f.buf_id;
                    self.dma_nids += 1;
                }
            },
            .frame_damage => {
                const d = proto.FrameDamage.decodeAlloc(frame.payload, self.gpa) catch fail("frame_damage decode");
                defer self.gpa.free(d.rects);
                if (self.dev_view != 0 and d.view == self.dev_view) {
                    self.dev_dmg_seq += 1;
                    return;
                }
                self.dmg_buf = d.buf_id;
                self.dmg_seq += 1;
            },
            .ev_devtools_view => {
                const e = proto.decode(proto.EvDevToolsView, frame.payload) catch fail("ev_devtools_view decode");
                self.dev_view = e.devtools;
                self.dev_reason_len = @min(e.reason.len, self.dev_reason.len);
                @memcpy(self.dev_reason[0..self.dev_reason_len], e.reason[0..self.dev_reason_len]);
                self.dev_reply_seq += 1;
            },
            .ev_download_offer => {
                const o = proto.decode(proto.EvDownloadOffer, frame.payload) catch fail("ev_download_offer decode");
                self.dl_view = o.view;
                self.dl_id = o.id;
                self.dl_total = o.total;
                self.dl_name_len = @min(o.name.len, self.dl_name.len);
                @memcpy(self.dl_name[0..self.dl_name_len], o.name[0..self.dl_name_len]);
                self.dl_url_len = @min(o.url.len, self.dl_url.len);
                @memcpy(self.dl_url[0..self.dl_url_len], o.url[0..self.dl_url_len]);
                self.dl_offer_seq += 1;
            },
            .ev_download_progress => {
                const p = proto.decode(proto.EvDownloadProgress, frame.payload) catch fail("ev_download_progress decode");
                self.dl_prog_id = p.id;
                self.dl_received = p.received;
                self.dl_prog_total = p.total;
                self.dl_done = p.done;
                self.dl_failed = p.failed;
                self.dl_prog_seq += 1;
            },
            .ev_print_pdf_done => {
                const p = proto.decode(proto.EvPrintPdfDone, frame.payload) catch fail("ev_print_pdf_done decode");
                self.print_ok = p.ok;
                self.print_path_len = @min(p.path.len, self.print_path.len);
                @memcpy(self.print_path[0..self.print_path_len], p.path[0..self.print_path_len]);
                self.print_seq += 1;
            },
            .ev_webext_state => {
                const st = proto.decode(proto.EvWebextState, frame.payload) catch fail("ev_webext_state decode");
                self.we_ok = st.ok;
                self.we_enabled = st.enabled;
                self.we_name_len = @min(st.name.len, self.we_name.len);
                @memcpy(self.we_name[0..self.we_name_len], st.name[0..self.we_name_len]);
                self.we_err_len = @min(st.err.len, self.we_err.len);
                @memcpy(self.we_err[0..self.we_err_len], st.err[0..self.we_err_len]);
            },
            .ev_webext_wreq_stats => {
                const st = proto.decode(proto.EvWebextWreqStats, frame.payload) catch fail("ev_webext_wreq_stats decode");
                self.wq_seen = true;
                self.wq_matched = st.matched;
                self.wq_held = st.held;
                self.wq_cancelled = st.cancelled;
                self.wq_redirected = st.redirected;
                self.wq_headers_modified = st.headers_modified;
                self.wq_hdr_recv_dropped = st.headers_received_dropped;
                self.wq_timed_out = st.timed_out;
                self.wq_failed_open = st.failed_open;
            },
            .ev_title => {
                const t = proto.decode(proto.EvTitle, frame.payload) catch fail("ev_title decode");
                self.title_len = @min(t.title.len, self.title.len);
                @memcpy(self.title[0..self.title_len], t.title[0..self.title_len]);
            },
            .ev_popup_request => {
                const p = proto.decode(proto.EvPopupRequest, frame.payload) catch fail("ev_popup_request decode");
                self.popup_view = p.view;
                self.popup_gesture = p.user_gesture;
                self.popup_len = @min(p.url.len, self.popup_url.len);
                @memcpy(self.popup_url[0..self.popup_len], p.url[0..self.popup_len]);
            },
            .sem_snapshot => {
                const s = proto.decode(proto.SemSnapshot, frame.payload) catch fail("sem_snapshot decode");
                self.sem_kind = s.kind;
                self.sem_last_len = @min(s.payload.s.len, self.sem_last.len);
                @memcpy(self.sem_last[0..self.sem_last_len], s.payload.s[0..self.sem_last_len]);
                const room = self.sem_log.len - self.sem_log_len;
                const n = @min(s.payload.s.len, room);
                @memcpy(self.sem_log[self.sem_log_len..][0..n], s.payload.s[0..n]);
                self.sem_log_len += n;
                self.sem_seq += 1;
            },
            .sem_act_result => {
                const r = proto.decode(proto.SemActResult, frame.payload) catch fail("sem_act_result decode");
                self.act_id = r.id;
                self.act_ok = r.ok;
                self.act_msg_len = @min(r.msg.len, self.act_msg.len);
                @memcpy(self.act_msg[0..self.act_msg_len], r.msg[0..self.act_msg_len]);
                self.act_seq += 1;
            },
            .sem_expand_result => {
                const e = proto.decode(proto.SemExpandResult, frame.payload) catch fail("sem_expand_result decode");
                self.exp_len = @min(e.text.len, self.exp_text.len);
                @memcpy(self.exp_text[0..self.exp_len], e.text[0..self.exp_len]);
                self.exp_seq += 1;
            },
            .sem_query_result => {
                const q = proto.decode(proto.SemQueryResult, frame.payload) catch fail("sem_query_result decode");
                self.query_len = @min(q.payload.s.len, self.query_out.len);
                @memcpy(self.query_out[0..self.query_len], q.payload.s[0..self.query_len]);
                self.query_seq += 1;
            },
            .sem_eval_result => {
                const e = proto.decode(proto.SemEvalResult, frame.payload) catch fail("sem_eval_result decode");
                self.eval_ok = e.ok;
                self.eval_len = @min(e.json.s.len, self.eval_json.len);
                @memcpy(self.eval_json[0..self.eval_len], e.json.s[0..self.eval_len]);
                self.eval_seq += 1;
            },
            .sem_read_result => {
                const r = proto.decode(proto.SemReadResult, frame.payload) catch fail("sem_read_result decode");
                self.md_len = @min(r.markdown.s.len, self.md.len);
                @memcpy(self.md[0..self.md_len], r.markdown.s[0..self.md_len]);
                self.md_seq += 1;
            },
            .ev_load => {
                const l = proto.decode(proto.EvLoad, frame.payload) catch fail("ev_load decode");
                if (l.state == @intFromEnum(proto.LoadState.finished)) {
                    self.load_seq += 1;
                    if (std.mem.eql(u8, l.url, "about:blank")) self.blank_load_seq += 1;
                }
            },
            .ev_load_error => {
                _ = proto.decode(proto.EvLoadError, frame.payload) catch fail("ev_load_error decode");
                self.load_err_seq += 1;
            },
            .ev_cert_error => {
                const e = proto.decode(proto.EvCertError, frame.payload) catch fail("ev_cert_error decode");
                self.cert_seq += 1;
                self.cert_view = e.view;
                self.cert_code = e.code;
                self.cert_host_len = @min(e.host.len, self.cert_host.len);
                @memcpy(self.cert_host[0..self.cert_host_len], e.host[0..self.cert_host_len]);
                self.cert_fp_len = @min(e.fingerprint.len, self.cert_fp.len);
                @memcpy(self.cert_fp[0..self.cert_fp_len], e.fingerprint[0..self.cert_fp_len]);
            },
            .ev_permission => {
                const e = proto.decode(proto.EvPermission, frame.payload) catch fail("ev_permission decode");
                self.perm_seq += 1;
                self.perm_id = e.prompt;
                self.perm_types = e.types;
                self.perm_origin_len = @min(e.origin.len, self.perm_origin.len);
                @memcpy(self.perm_origin[0..self.perm_origin_len], e.origin[0..self.perm_origin_len]);
            },
            .ev_nav_state => {
                const s = proto.decode(proto.EvNavState, frame.payload) catch fail("ev_nav_state decode");
                self.nav_back = s.can_back;
                self.nav_fwd = s.can_fwd;
                self.nav_seq += 1;
            },
            .intercept_status => {
                const s = proto.decode(proto.InterceptStatus, frame.payload) catch fail("intercept_status decode");
                self.int_enabled = s.enabled;
                self.int_blocked = s.blocked;
                self.int_total = s.total;
                self.int_rules = s.rules;
                self.int_status_seq += 1;
            },
            .intercept_log => {
                const l = proto.InterceptLog.decodeAlloc(frame.payload, self.gpa) catch fail("intercept_log decode");
                defer self.gpa.free(l.entries);
                self.int_log_next = l.next_seq;
                const json = proto.netLogJson(self.gpa, l.next_seq, l.entries) catch fail("intercept_log json");
                defer self.gpa.free(json);
                self.int_log_len = @min(json.len, self.int_log.len);
                @memcpy(self.int_log[0..self.int_log_len], json[0..self.int_log_len]);
                self.int_log_seq += 1;
            },
            else => {},
        }
    }

    /// Map the currently announced buffer read-only.
    fn mapBuffer(self: *Client) void {
        const fb = self.fb orelse fail("no frame_buffer announced");
        self.unmap();
        const size: usize = @as(usize, fb.stride) * @as(usize, fb.h);
        const addr = c.mmap(null, size, c.PROT_READ, c.MAP_SHARED, self.fb_fd, 0);
        if (addr == c.MAP_FAILED) fail("mmap of the frame memfd");
        const bytes: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(addr));
        self.map = bytes[0..size];
    }

    /// BGRA pixel at logical (x, y) in the mapped buffer.
    fn pixel(self: *Client, x: u32, y: u32) [4]u8 {
        const fb = self.fb orelse fail("no frame_buffer announced");
        const off = @as(usize, y) * @as(usize, fb.stride) + @as(usize, x) * 4;
        if (off + 4 > self.map.len) fail("pixel outside the mapped buffer");
        return .{ self.map[off], self.map[off + 1], self.map[off + 2], self.map[off + 3] };
    }

    fn evalPayload(self: *Client) []const u8 {
        return self.eval_json[0..self.eval_len];
    }

    /// Evaluate `code` and wait for the answer; returns the raw JSON.
    fn evalWait(self: *Client, code: []const u8, want_await: bool, timeout_ms: i64) []const u8 {
        const seq = self.eval_seq;
        self.send(proto.SemEval{
            .view = view_id,
            .flags = if (want_await) proto.eval_flag_await else 0,
            .timeout_ms = 5000,
            .code = .{ .s = code },
        });
        if (!self.waitSeq(&self.eval_seq, seq, timeout_ms)) fail("no sem_eval_result");
        return self.evalPayload();
    }

    fn resetTitle(self: *Client) void {
        self.title_len = 0;
    }

    fn titleSlice(self: *Client) []const u8 {
        return self.title[0..self.title_len];
    }

    fn waitTitle(self: *Client, prefix: []const u8, timeout_ms: i64) bool {
        const deadline = nowMs() + timeout_ms;
        while (true) {
            if (std.mem.startsWith(u8, self.titleSlice(), prefix)) return true;
            if (nowMs() > deadline) return false;
            self.pump(50);
        }
    }

    fn waitDamageAfter(self: *Client, seq: u32, timeout_ms: i64) bool {
        const deadline = nowMs() + timeout_ms;
        while (true) {
            if (self.dmg_seq > seq) return true;
            if (nowMs() > deadline) return false;
            self.pump(50);
        }
    }

    fn waitBufferAfter(self: *Client, seq: u32, timeout_ms: i64) bool {
        const deadline = nowMs() + timeout_ms;
        while (true) {
            if (self.fb_seq > seq) return true;
            if (nowMs() > deadline) return false;
            self.pump(50);
        }
    }

    /// Poll intercept status until `min_blocked` requests were blocked
    /// on `view`, driving frames meanwhile.
    fn waitBlocked(self: *Client, min_blocked: u32, timeout_ms: i64) bool {
        const deadline = nowMs() + timeout_ms;
        while (true) {
            self.send(proto.InterceptStatusReq{ .view = view_id });
            if (self.int_blocked >= min_blocked) return true;
            if (nowMs() > deadline) return false;
            self.pump(80);
        }
    }

    /// Pull the log and wait for the reply.
    fn pullLog(self: *Client, since: u32, timeout_ms: i64) bool {
        const before = self.int_log_seq;
        self.send(proto.InterceptLogReq{ .view = view_id, .since = since, .max = 64 });
        const deadline = nowMs() + timeout_ms;
        while (true) {
            if (self.int_log_seq > before) return true;
            if (nowMs() > deadline) return false;
            self.pump(50);
        }
    }

    fn logSlice(self: *Client) []const u8 {
        return self.int_log[0..self.int_log_len];
    }

    fn sawPopup(self: *Client, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.popup_url[0..self.popup_len], needle) != null;
    }

    fn waitPopup(self: *Client, needle: []const u8, timeout_ms: i64) bool {
        const deadline = nowMs() + timeout_ms;
        while (true) {
            if (std.mem.indexOf(u8, self.popup_url[0..self.popup_len], needle) != null) return true;
            if (nowMs() > deadline) return false;
            self.pump(50);
        }
    }

    fn waitCanForward(self: *Client, timeout_ms: i64) bool {
        const deadline = nowMs() + timeout_ms;
        while (true) {
            if (self.nav_fwd == 1) return true;
            if (nowMs() > deadline) return false;
            self.pump(50);
        }
    }

    /// Wait until the centre pixel matches `want` (BGR, alpha ignored),
    /// remapping on every announced buffer so a resize is picked up.
    fn waitCenterColor(self: *Client, want: [3]u8, timeout_ms: i64) bool {
        const deadline = nowMs() + timeout_ms;
        var mapped_seq: u32 = 0;
        while (true) {
            if (self.fb != null and self.fb_seq != mapped_seq) {
                self.mapBuffer();
                mapped_seq = self.fb_seq;
            }
            if (self.map.len != 0) {
                const fb = self.fb.?;
                const px = self.pixel(fb.w / 2, fb.h / 2);
                var ok = true;
                for (0..3) |i| {
                    const diff = @as(i32, px[i]) - @as(i32, want[i]);
                    if (@abs(diff) > 24) ok = false;
                }
                if (ok) return true;
            }
            if (nowMs() > deadline) return false;
            self.pump(50);
        }
    }

    fn clickCenter(self: *Client) void {
        const fb = self.fb orelse fail("no frame_buffer announced");
        const x: i32 = @intCast(fb.w / 2);
        const y: i32 = @intCast(fb.h / 2);
        self.send(proto.InputPointer{ .view = view_id, .kind = @intFromEnum(proto.PointerKind.move), .x = x, .y = y, .button = 0, .clicks = 0, .mods = 0 });
        self.send(proto.InputPointer{ .view = view_id, .kind = @intFromEnum(proto.PointerKind.down), .x = x, .y = y, .button = 0, .clicks = 1, .mods = 0 });
        self.send(proto.InputPointer{ .view = view_id, .kind = @intFromEnum(proto.PointerKind.up), .x = x, .y = y, .button = 0, .clicks = 1, .mods = 0 });
    }

    fn typeKey(self: *Client, keysym: u32, text: []const u8) void {
        self.send(proto.InputKey{ .view = view_id, .kind = @intFromEnum(proto.KeyKind.down), .keyval = keysym, .keycode = 0, .mods = 0, .text = text });
        self.send(proto.InputKey{ .view = view_id, .kind = @intFromEnum(proto.KeyKind.up), .keyval = keysym, .keycode = 0, .mods = 0, .text = "" });
    }

    fn resetSem(self: *Client) void {
        self.sem_log_len = 0;
        self.sem_last_len = 0;
    }

    fn semLog(self: *Client) []const u8 {
        return self.sem_log[0..self.sem_log_len];
    }

    fn semLast(self: *Client) []const u8 {
        return self.sem_last[0..self.sem_last_len];
    }

    fn queryPayload(self: *Client) []const u8 {
        return self.query_out[0..self.query_len];
    }

    /// Wait until some snapshot payload received since the last reset
    /// contains `needle`.
    fn waitSem(self: *Client, needle: []const u8, timeout_ms: i64) bool {
        const deadline = nowMs() + timeout_ms;
        while (true) {
            if (std.mem.indexOf(u8, self.semLog(), needle) != null) return true;
            if (nowMs() > deadline) return false;
            self.pump(50);
        }
    }

    fn waitSeq(self: *Client, which: *u32, seq: u32, timeout_ms: i64) bool {
        const deadline = nowMs() + timeout_ms;
        while (true) {
            if (which.* > seq) return true;
            if (nowMs() > deadline) return false;
            self.pump(50);
        }
    }

    /// Stable id of the node whose rendered line contains `needle`.
    fn idOfLine(self: *Client, needle: []const u8) ?u32 {
        const hay = self.semLog();
        const at = std.mem.indexOf(u8, hay, needle) orelse return null;
        var i = at;
        while (i > 0) : (i -= 1) {
            if (hay[i] == '[') break;
        }
        if (hay[i] != '[') return null;
        const end = std.mem.indexOfScalarPos(u8, hay, i, ']') orelse return null;
        return std.fmt.parseInt(u32, hay[i + 1 .. end], 10) catch null;
    }

    /// Stable id named by a truncation marker, i.e. `expand [N]`.
    fn idOfExpandMarker(self: *Client) ?u32 {
        const hay = self.semLog();
        const at = std.mem.indexOf(u8, hay, "chars, expand [") orelse return null;
        const open = at + "chars, expand [".len;
        const end = std.mem.indexOfScalarPos(u8, hay, open, ']') orelse return null;
        return std.fmt.parseInt(u32, hay[open..end], 10) catch null;
    }

    /// Ask for a snapshot and wait for the payload it produces.
    fn snapshot(self: *Client, mode: u8, detail: u8) void {
        const seq = self.sem_seq;
        self.send(proto.SemSnapshotReq{ .view = view_id, .mode = mode, .detail = detail, .scope = 0 });
        if (!self.waitSeq(&self.sem_seq, seq, 20_000)) fail("no sem_snapshot for the request");
    }

    /// Wait for a TERMINAL progress frame (`done` or `failed`) for
    /// download `id`.
    fn waitDlTerminal(self: *Client, id: u32, timeout_ms: i64) bool {
        const deadline = nowMs() + timeout_ms;
        while (true) {
            if (self.dl_prog_id == id and (self.dl_done != 0 or self.dl_failed != 0)) return true;
            if (nowMs() > deadline) return false;
            self.pump(50);
        }
    }

    /// Navigate, wait for the main frame to finish loading, then for a
    /// paint of it.
    fn navigate(self: *Client, url: []const u8) void {
        const load = self.load_seq;
        const dmg = self.dmg_seq;
        self.resetTitle();
        self.send(proto.Navigate{ .view = view_id, .url = url });
        if (!self.waitSeq(&self.load_seq, load, 20_000)) fail("no load-finished after navigate");
        if (!self.waitDamageAfter(dmg, 20_000)) fail("no paint after navigate");
    }
};

/// State bits of the first ax-log line containing `needle` (the log
/// renders `[id] role "name" s=<hex>` per node), or null.
fn axLineState(log: []const u8, needle: []const u8) ?u64 {
    const at = std.mem.indexOf(u8, log, needle) orelse return null;
    const s_at = std.mem.indexOfPos(u8, log, at, " s=") orelse return null;
    const start = s_at + 3;
    const end = std.mem.indexOfScalarPos(u8, log, start, '\n') orelse log.len;
    return std.fmt.parseInt(u64, log[start..end], 16) catch null;
}

/// Connect to the helper's socket, retrying while it starts CEF up.
fn connectWithRetry(path: [*:0]const u8, path_len: usize) c_int {
    var addr = std.mem.zeroes(c.struct_sockaddr_un);
    addr.sun_family = c.AF_UNIX;
    if (path_len + 1 > @sizeOf(@TypeOf(addr.sun_path))) fail("socket path too long");
    @memcpy(addr.sun_path[0..path_len], path[0..path_len]);

    const deadline = nowMs() + 60_000;
    while (nowMs() < deadline) {
        var status: c_int = 0;
        if (c.waitpid(g_pid, &status, c.WNOHANG) == g_pid) fail("helper exited before it listened");
        const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
        if (fd < 0) fail("socket");
        if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) == 0) return fd;
        _ = c.close(fd);
        _ = c.usleep(100_000);
    }
    fail("timed out connecting to the helper");
}

/// Fork+exec one helper. `extra` is a single additional argv entry (the
/// ozone pin, or "--disable-gpu"), and `no_gpu` sets the environment
/// switch that makes the helper refuse the GPU path outright.
fn spawnHelper(
    exe: [*:0]const u8,
    sock: [*:0]const u8,
    cache: [*:0]const u8,
    extra: ?[*:0]const u8,
    no_gpu: bool,
) c.pid_t {
    const pid = c.fork();
    if (pid < 0) fail("fork");
    if (pid != 0) return pid;
    if (no_gpu) _ = c.setenv("SKETERM_WEB_GPU", "0", 1);
    var vec: [7:null]?[*:0]const u8 = @splat(null);
    vec[0] = exe;
    vec[1] = "--socket";
    vec[2] = sock;
    vec[3] = "--cache-dir";
    vec[4] = cache;
    if (extra) |e| vec[5] = e;
    _ = c.execv(exe, @ptrCast(@constCast(&vec)));
    c._exit(127);
    unreachable;
}

/// Bring a helper down by EXACT pid after its client disconnected.
fn reapHelper(pid: c.pid_t, what: []const u8) void {
    reapHelperTimeout(pid, what, 10_000);
}

/// Like `reapHelperTimeout` but a SIGNAL exit is reported, not failed —
/// for a helper whose CEF shutdown is a known-noisy path. A hang still
/// fails.
fn reapHelperTolerant(pid: c.pid_t, what: []const u8, timeout_ms: i64) void {
    const deadline = nowMs() + timeout_ms;
    var status: c_int = 0;
    while (nowMs() < deadline) {
        if (c.waitpid(pid, &status, c.WNOHANG) == pid) {
            g_pid = -1;
            if (status & 0x7f != 0) {
                std.debug.print("smoke-web: NOTE {s}: helper exited on signal {d} (CEF shutdown artifact)\n", .{ what, status & 0x7f });
            }
            return;
        }
        _ = c.usleep(50_000);
    }
    say(what);
    fail("helper did not exit within its budget of the disconnect");
}

fn reapHelperTimeout(pid: c.pid_t, what: []const u8, timeout_ms: i64) void {
    const deadline = nowMs() + timeout_ms;
    var status: c_int = 0;
    while (nowMs() < deadline) {
        if (c.waitpid(pid, &status, c.WNOHANG) == pid) {
            g_pid = -1;
            if (status & 0x7f != 0) {
                say(what);
                fail("helper died on a signal");
            }
            return;
        }
        _ = c.usleep(50_000);
    }
    say(what);
    fail("helper did not exit within 10s of the disconnect");
}

/// Asks for geolocation the moment it loads (no user gesture is
/// required for that one) and writes the outcome into the title, so
/// the rig can see the DECISION arrive at the page: code 1 is
/// PERMISSION_DENIED, i.e. exactly the answer the client sent.
const geo_page =
    "<html><body>geo<script>navigator.geolocation.getCurrentPosition(" ++
    "function(){document.title='geo:ok'}," ++
    "function(e){document.title='geo:err'+e.code});</script></body></html>";

fn writeFile(dir: []const u8, name: []const u8, body: []const u8) bool {
    var path_buf: [160]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ dir, name }) catch return false;
    const fd = c.open(path.ptr, c.O_WRONLY | c.O_CREAT | c.O_TRUNC, @as(c_uint, 0o644));
    if (fd < 0) return false;
    defer _ = c.close(fd);
    return c.write(fd, body.ptr, body.len) == @as(isize, @intCast(body.len));
}

/// One openssl process serving HTTPS with a throwaway self-signed
/// certificate, or null when the host cannot provide one.
const BadCertServer = struct {
    pid: c.pid_t,
    port: u16,
};

/// Run `openssl` to completion with `args` (argv[0] included). True on
/// a clean exit.
fn runOpenssl(args: []const ?[*:0]const u8) bool {
    const pid = c.fork();
    if (pid < 0) return false;
    if (pid == 0) {
        // stdin from /dev/null: an `openssl req` missing a switch
        // PROMPTS, and a prompting child would hang the whole rig.
        const devnull = c.open("/dev/null", c.O_RDWR);
        if (devnull >= 0) {
            _ = c.dup2(devnull, 0);
            _ = c.dup2(devnull, 1);
            _ = c.dup2(devnull, 2);
        }
        var vec: [20:null]?[*:0]const u8 = @splat(null);
        if (args.len >= vec.len) c._exit(127);
        for (args, 0..) |a, i| vec[i] = a;
        _ = c.execvp("openssl", @ptrCast(@constCast(&vec)));
        c._exit(127);
    }
    var status: c_int = 0;
    if (c.waitpid(pid, &status, 0) != pid) return false;
    return status == 0;
}

/// Mint a self-signed certificate in `dir` and serve it on a loopback
/// port. Null means "not available here" — a missing openssl, a port
/// that never came up — and the caller SKIPS rather than fails.
fn startBadCertServer(dir: []const u8) ?BadCertServer {
    var key_buf: [128]u8 = undefined;
    const key = std.fmt.bufPrintZ(&key_buf, "{s}/k.pem", .{dir}) catch return null;
    var crt_buf: [128]u8 = undefined;
    const crt = std.fmt.bufPrintZ(&crt_buf, "{s}/c.pem", .{dir}) catch return null;
    // `-subj` is not optional: without it `req` prompts for a subject.
    if (!runOpenssl(&[_]?[*:0]const u8{
        "openssl", "req",   "-x509", "-newkey", "rsa:2048",
        "-keyout", key.ptr, "-out",  crt.ptr,   "-days",
        "1",       "-nodes", "-subj", "/CN=localhost",
    })) return null;

    // A port derived from the pid keeps two concurrent rigs apart
    // without a discovery protocol; a busy one simply fails to serve
    // and the stage skips.
    const port: u16 = @intCast(20000 + @mod(c.getpid(), 20000));
    var port_buf: [16]u8 = undefined;
    const port_z = std.fmt.bufPrintZ(&port_buf, "{d}", .{port}) catch return null;

    // The document the two stages load. It has to be a REAL file
    // served over TLS, because a permission prompt needs a secure
    // context and a `data:` url is not one.
    if (!writeFile(dir, "geo.html", geo_page)) return null;

    const pid = c.fork();
    if (pid < 0) return null;
    if (pid == 0) {
        const devnull = c.open("/dev/null", c.O_RDWR);
        if (devnull >= 0) {
            _ = c.dup2(devnull, 0);
            _ = c.dup2(devnull, 1);
            _ = c.dup2(devnull, 2);
        }
        // `-WWW` serves files relative to the CWD, which is how the
        // page above reaches the engine over https.
        var dir_z: [128:0]u8 = @splat(0);
        if (dir.len >= dir_z.len) c._exit(127);
        @memcpy(dir_z[0..dir.len], dir);
        if (c.chdir(&dir_z) != 0) c._exit(127);
        var vec: [12:null]?[*:0]const u8 = @splat(null);
        vec[0] = "openssl";
        vec[1] = "s_server";
        vec[2] = "-key";
        vec[3] = key.ptr;
        vec[4] = "-cert";
        vec[5] = crt.ptr;
        vec[6] = "-accept";
        vec[7] = port_z.ptr;
        vec[8] = "-WWW";
        vec[9] = "-quiet";
        _ = c.execvp("openssl", @ptrCast(@constCast(&vec)));
        c._exit(127);
    }
    // Wait for the port to accept, which is also how a dead openssl
    // (missing binary, busy port) is noticed.
    const deadline = nowMs() + 5000;
    while (nowMs() < deadline) {
        var status: c_int = 0;
        if (c.waitpid(pid, &status, c.WNOHANG) == pid) return null;
        if (probePort(port)) return .{ .pid = pid, .port = port };
        _ = c.usleep(100_000);
    }
    _ = c.kill(pid, c.SIGKILL);
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    return null;
}

fn probePort(port: u16) bool {
    const fd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
    if (fd < 0) return false;
    defer _ = c.close(fd);
    var addr = std.mem.zeroes(c.struct_sockaddr_in);
    addr.sin_family = c.AF_INET;
    addr.sin_port = std.mem.nativeToBig(u16, port);
    addr.sin_addr.s_addr = std.mem.nativeToBig(u32, 0x7f000001);
    return c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_in)) == 0;
}

/// A counter plus the value it must pass: what every wait in the
/// certificate stage is actually watching (Zig has no closures, so the
/// baseline has to travel with the predicate).
const Past = struct { cl: *Client, base: u32 };

/// Drive the client until `pred` holds or the deadline passes.
fn driveUntil(cl: *Client, timeout_ms: i64, ctx: anytype, comptime pred: fn (@TypeOf(ctx)) bool) bool {
    const deadline = nowMs() + timeout_ms;
    while (nowMs() < deadline) {
        if (pred(ctx)) return true;
        _ = cl.drive(150, 120);
    }
    return pred(ctx);
}

/// Stage 22f: the held certificate error, both decisions.
///
/// ORDER MATTERS: the deny goes first. Chromium remembers a PROCEEDED
/// certificate for the rest of the session (its SSL host state), so a
/// second navigation after an allow would not error again and the
/// stage would be asserting on nothing. A DENY is remembered by
/// nobody, which is what makes "error again, then allow" the only
/// ordering that tests both answers.
fn certStage(cl: *Client, dir: []const u8) void {
    const server = startBadCertServer(dir) orelse {
        say("smoke-web: SKIP stage 22f bad certificate (no usable openssl s_server on this host)");
        return;
    };
    defer {
        _ = c.kill(server.pid, c.SIGKILL);
        var status: c_int = 0;
        _ = c.waitpid(server.pid, &status, 0);
    }

    var url_buf: [64]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "https://127.0.0.1:{d}/geo.html", .{server.port}) catch
        fail("stage 22f: url");

    // -- deny --------------------------------------------------------
    var wait = Past{ .cl = cl, .base = cl.cert_seq };
    const errs_before = cl.load_err_seq;
    cl.send(proto.Navigate{ .view = view_id, .url = url });
    if (!driveUntil(cl, 20_000, &wait, struct {
        fn f(w: *Past) bool {
            return w.cl.cert_seq > w.base;
        }
    }.f)) fail("stage 22f: no ev_cert_error for a self-signed certificate");
    if (cl.cert_view != view_id) fail("stage 22f: ev_cert_error named the wrong view");
    if (cl.cert_code == 0) fail("stage 22f: ev_cert_error carried no error code");
    if (!std.mem.eql(u8, cl.cert_host[0..cl.cert_host_len], "127.0.0.1"))
        fail("stage 22f: ev_cert_error did not name the host being visited");
    if (cl.cert_fp_len != 64) fail("stage 22f: ev_cert_error carried no SHA-256 fingerprint");
    const fp_ok = for (cl.cert_fp[0..cl.cert_fp_len]) |ch| {
        if (!std.ascii.isHex(ch)) break false;
    } else true;
    if (!fp_ok) fail("stage 22f: the fingerprint is not lowercase hex");

    cl.send(proto.CertDecision{ .view = view_id, .proceed = 0 });
    wait = .{ .cl = cl, .base = errs_before };
    if (!driveUntil(cl, 20_000, &wait, struct {
        fn f(w: *Past) bool {
            return w.cl.load_err_seq > w.base;
        }
    }.f)) fail("stage 22f: a cancelled certificate decision did not fail the load");

    // -- allow -------------------------------------------------------
    wait = .{ .cl = cl, .base = cl.cert_seq };
    cl.send(proto.Navigate{ .view = view_id, .url = url });
    if (!driveUntil(cl, 20_000, &wait, struct {
        fn f(w: *Past) bool {
            return w.cl.cert_seq > w.base;
        }
    }.f)) fail("stage 22f: a cancelled certificate was remembered — no second ev_cert_error");
    cl.send(proto.CertDecision{ .view = view_id, .proceed = 1 });
    wait = .{ .cl = cl, .base = cl.load_seq };
    if (!driveUntil(cl, 30_000, &wait, struct {
        fn f(w: *Past) bool {
            return w.cl.load_seq > w.base;
        }
    }.f)) fail("stage 22f: the page never loaded after proceeding past the certificate");
    pass("stage 22f bad certificate (held, cancelled, then proceeded)");

    // ── Stage 22g: what the engine does with a permission request ──
    //
    // The page just loaded over TLS is a secure context, so its
    // geolocation call is a real permission request -- the one thing a
    // `data:` url can never produce. MEASURED against the installed
    // CEF: an ALLOY windowless browser never even asks the client for a
    // permission handler, denies the request internally, and the page
    // sees PERMISSION_DENIED (code 1). `ev_permission` is therefore
    // implemented on both sides but unreachable in this configuration.
    //
    // This stage pins that deliberately: the day the engine starts
    // consulting the handler it FAILS and says so, which is when the
    // GUI's permission banner becomes reachable and deserves a real
    // allow/deny round trip in place of this stage.
    _ = cl.drive(3000, 120);
    if (cl.perm_seq != 0) fail(
        "stage 22g: the engine now DOES ask the client for permission -- " ++
            "replace this stage with a real allow/deny round trip",
    );
    if (!std.mem.eql(u8, cl.title[0..cl.title_len], "geo:err1")) {
        std.debug.print("smoke-web: title was '{s}'\n", .{cl.title[0..cl.title_len]});
        fail("stage 22g: a secure-context geolocation call did not end in PERMISSION_DENIED");
    }
    pass("stage 22g permission request (engine-denied; the client is never consulted yet)");

    widevineStage(cl);

    // Leave the view on a data: page: everything after this stage
    // assumes no network is involved.
    cl.send(proto.Navigate{ .view = view_id, .url = red_page });
    _ = cl.drive(500, 120);
}

/// The DRM question the browser spike answered once by hand and nothing
/// pinned afterwards: does the SHIPPED helper configuration grant
/// `com.widevine.alpha` key-system access?
///
/// It runs inside `certStage` and not on its own, because EME is a
/// secure-context API: the https page stage 22f proceeded past is the
/// rig's only secure context, and a `data:` url would reject for the
/// wrong reason and look like a missing CDM.
///
/// This is a CAPABILITY proof, not a playback proof — see
/// `src/web/CLAUDE.md` for what a real playback proof would additionally
/// need. What it does assert unconditionally is that the API ANSWERS:
/// a hang, or an eval that reports failure, is a real regression even on
/// a host with no CDM at all. A resolved access is reported as the pass;
/// a rejection is reported distinctly, with the reason the engine gave,
/// because "this host has no CDM" and "the helper stopped enabling
/// Widevine" are different facts and only the second is a bug.
fn widevineStage(cl: *Client) void {
    // ClearKey is the CONTROL: Chromium implements it in-process, with
    // no CDM to install, so it answers "yes" wherever EME works at all.
    // Without it a Widevine refusal would be unreadable — a missing CDM
    // and an EME-less page look identical from one probe.
    var probe_bufs: [3][256]u8 = undefined;
    const clearkey_webm = emeProbe(cl, "org.w3.clearkey", webm_caps, &probe_bufs[0]);
    if (std.mem.indexOf(u8, clearkey_webm, "eme:ok") == null) {
        std.debug.print("smoke-web: eval said {s}\n", .{clearkey_webm});
        fail("stage 22l widevine: EME itself is unavailable here (ClearKey/WebM was refused) — " ++
            "the page is not a secure context or the build dropped EME, and no Widevine " ++
            "result from this stage would mean anything");
    }

    // Two codec families, because a refusal has two very different
    // causes: upstream CEF ships WITHOUT proprietary codecs, so the
    // mp4/avc1+aac probe can fail on a build whose Widevine CDM is
    // perfectly present, while webm/vp9+opus is available in both the
    // upstream and the distro build.
    const wv_webm = emeProbe(cl, "com.widevine.alpha", webm_caps, &probe_bufs[1]);
    const wv_mp4 = emeProbe(cl, "com.widevine.alpha", mp4_caps, &probe_bufs[2]);
    const webm_ok = std.mem.indexOf(u8, wv_webm, "eme:ok") != null;
    const mp4_ok = std.mem.indexOf(u8, wv_mp4, "eme:ok") != null;
    std.debug.print(
        "smoke-web: MEASURED widevine: webm/vp9 {s}, mp4/avc1 {s}\n",
        .{ wv_webm, wv_mp4 },
    );
    if (webm_ok or mp4_ok) {
        pass("stage 22l widevine (key system access granted, temporary sessions)");
        return;
    }
    // Not a failure: the CDM is a downloaded component and this rig
    // runs on a throwaway cache directory with no component updater
    // pass. What the stage still proved is that EME answers and that
    // the refusal is Widevine-specific, not a broken page.
    pass("stage 22l widevine (no Widevine CDM in this cache/build: refused, ClearKey still granted)");
}

/// Capability sets for `emeProbe`. Written as JS object literals; the
/// escaped quotes are what `contentType` requires around `codecs`.
const webm_caps =
    "initDataTypes:['webm']," ++
    "audioCapabilities:[{contentType:'audio/webm;codecs=\\\"opus\\\"'}]," ++
    "videoCapabilities:[{contentType:'video/webm;codecs=\\\"vp9\\\"'}]";
const mp4_caps =
    "initDataTypes:['cenc']," ++
    "audioCapabilities:[{contentType:'audio/mp4;codecs=\\\"mp4a.40.2\\\"'}]," ++
    "videoCapabilities:[{contentType:'video/mp4;codecs=\\\"avc1.42E01E\\\"'}]";

/// One `requestMediaKeySystemAccess` for `key_system` with `caps`,
/// asking for TEMPORARY sessions. Returns the eval's raw JSON, which
/// carries either `eme:ok:<keySystem>` or `eme:no:<ErrorName>`. The
/// answer is COPIED into `out` because the client keeps exactly one
/// eval payload and the next probe overwrites it. A non-answer is fatal
/// here rather than at every call site: a promise that never settles is
/// the one outcome no caller can read.
fn emeProbe(cl: *Client, key_system: []const u8, caps: []const u8, out: []u8) []const u8 {
    var buf: [768]u8 = undefined;
    const js = std.fmt.bufPrint(
        &buf,
        "navigator.requestMediaKeySystemAccess('{s}',[{{{s},sessionTypes:['temporary']}}])" ++
            ".then(function(a){{return 'eme:ok:'+a.keySystem;}})" ++
            ".catch(function(e){{return 'eme:no:'+e.name;}})",
        .{ key_system, caps },
    ) catch fail("stage 22l widevine: probe script did not fit");
    const json = cl.evalWait(js, true, 30_000);
    if (cl.eval_ok != 1 or std.mem.indexOf(u8, json, "eme:") == null) {
        std.debug.print("smoke-web: eval said {s}\n", .{json});
        fail("stage 22l widevine: requestMediaKeySystemAccess never answered");
    }
    const n = @min(json.len, out.len);
    @memcpy(out[0..n], json[0..n]);
    return out[0..n];
}

// ── Stage 32 plumbing: a mini mux client + a byte bridge ──────────
//
// The stage drives the REAL remote path on one machine: a private
// sketerm-mux spawns the helper via `web_helper_open` and the helper's
// protocol bytes ride a mux byte channel; a thread pumps that channel
// onto a socketpair whose other end the ordinary rig `Client` speaks —
// exactly the GUI's webremote.Bridge shape.

/// Minimal mux-wire client: framed send/recv on a blocking fd.
const MuxLite = struct {
    gpa: std.mem.Allocator,
    fd: c_int,
    in: std.ArrayList(u8) = .empty,

    fn deinit(self: *MuxLite) void {
        self.in.deinit(self.gpa);
        if (self.fd >= 0) _ = c.close(self.fd);
        self.fd = -1;
    }

    fn send(self: *MuxLite, ftype: mux_wire.FrameType, payload: []const u8) void {
        var hdr: [5]u8 = undefined;
        std.mem.writeInt(u32, hdr[0..4], @intCast(payload.len + 1), .little);
        hdr[4] = @intFromEnum(ftype);
        writeAllFd(self.fd, &hdr);
        writeAllFd(self.fd, payload);
    }

    /// Next complete frame (owned payload), or null on timeout.
    fn next(self: *MuxLite, timeout_ms: i64) ?struct { ftype: mux_wire.FrameType, payload: []u8 } {
        const deadline = nowMs() + timeout_ms;
        while (true) {
            if (mux_wire.peelFrame(self.in.items) catch fail("mux frame peel")) |p| {
                const owned = self.gpa.dupe(u8, p.frame.payload) catch fail("oom");
                mux_wire.compactConsumed(&self.in, p.consumed);
                return .{ .ftype = p.frame.ftype, .payload = owned };
            }
            const left = deadline - nowMs();
            if (left <= 0) return null;
            var pfd = c.struct_pollfd{ .fd = self.fd, .events = c.POLLIN, .revents = 0 };
            if (c.poll(@ptrCast(&pfd), 1, @intCast(@min(left, 100))) <= 0) continue;
            var buf: [64 * 1024]u8 = undefined;
            const n = c.read(self.fd, &buf, buf.len);
            if (n == 0) fail("mux daemon closed the connection");
            if (n < 0) {
                const e = std.c._errno().*;
                if (e == c.EINTR or e == c.EAGAIN) continue;
                fail("mux read");
            }
            self.in.appendSlice(self.gpa, buf[0..@intCast(n)]) catch fail("oom");
        }
    }
};

fn writeAllFd(fd: c_int, data: []const u8) void {
    var off: usize = 0;
    while (off < data.len) {
        const n = c.write(fd, data.ptr + off, data.len - off);
        if (n <= 0) {
            if (n < 0 and std.c._errno().* == c.EINTR) continue;
            fail("short write on the mux socket");
        }
        off += @intCast(n);
    }
}

/// The rig's webremote.Bridge: pump chan_data <-> a socketpair end on a
/// thread, so the ordinary `Client` can speak the helper protocol.
const RigBridge = struct {
    gpa: std.mem.Allocator,
    mux: *MuxLite,
    chan: u32,
    fd: c_int,
    thread: ?std.Thread = null,
    stop_flag: std.atomic.Value(bool) = .init(false),

    fn spawn(self: *RigBridge) void {
        self.thread = std.Thread.spawn(.{}, RigBridge.run, .{self}) catch fail("bridge thread");
    }

    fn run(self: *RigBridge) void {
        while (!self.stop_flag.load(.acquire)) {
            var fds: [2]c.struct_pollfd = .{
                .{ .fd = self.mux.fd, .events = c.POLLIN, .revents = 0 },
                .{ .fd = self.fd, .events = c.POLLIN, .revents = 0 },
            };
            if (c.poll(&fds, fds.len, 200) < 0) {
                if (std.c._errno().* == c.EINTR) continue;
                return;
            }
            if (fds[1].revents & (c.POLLIN | c.POLLHUP) != 0) {
                var buf: [32 * 1024]u8 = undefined;
                const n = c.read(self.fd, &buf, buf.len);
                if (n <= 0) return;
                var msg: [4 + 32 * 1024]u8 = undefined;
                std.mem.writeInt(u32, msg[0..4], self.chan, .little);
                @memcpy(msg[4 .. 4 + @as(usize, @intCast(n))], buf[0..@intCast(n)]);
                self.mux.send(.chan_data, msg[0 .. 4 + @as(usize, @intCast(n))]);
            }
            if (fds[0].revents & (c.POLLIN | c.POLLHUP) != 0) {
                const f = self.mux.next(1000) orelse continue;
                defer self.gpa.free(f.payload);
                switch (f.ftype) {
                    .chan_data => {
                        if (f.payload.len < 4) continue;
                        if (std.mem.readInt(u32, f.payload[0..4], .little) != self.chan) continue;
                        writeAllFd(self.fd, f.payload[4..]);
                    },
                    .chan_close => return,
                    else => {},
                }
            }
        }
    }

    fn stop(self: *RigBridge) void {
        // The flag, not a close, is what ends the loop: closing a
        // descriptor does NOT wake a poll already blocked on it in
        // another thread, and a -1 fd is silently ignored by every
        // later poll — so the old close-then-join hung whenever the
        // helper was still alive and idle (nothing sends chan_close),
        // which is a race the stage lost about half the time. The fd
        // is closed only AFTER the join, so the pump can never poll a
        // descriptor another thread has already reused.
        self.stop_flag.store(true, .release);
        if (self.thread) |t| t.join();
        self.thread = null;
        if (self.fd >= 0) _ = c.close(self.fd);
        self.fd = -1;
    }
};

/// A tiny 16x16 animating box on a red page: after the first full
/// frame, steady-state damage must stay a small fraction of the
/// surface — the "no full frames for cursor blinks" property.
const small_anim_page =
    "data:text/html,<body%20style=%22margin:0;background:%23ff0000%22>" ++
    "<div%20id=d%20style=%22position:fixed;left:0;top:0;width:16px;height:16px%22></div>" ++
    "<script>var%20i=0;function%20f(){i=(i+9)%25256;" ++
    "d.style.background='rgb(0,'+i+',0)';requestAnimationFrame(f)}requestAnimationFrame(f);</script></body>";

// The committed fixture extension, embedded so the stage never depends
// on the working directory: it is written to a fresh unpacked directory
// at runtime and loaded from there via `webext_set`.
const fx_manifest = @embedFile("web/webext/testdata/fixture/manifest.json");
const fx_content = @embedFile("web/webext/testdata/fixture/content.js");
const fx_bg = @embedFile("web/webext/testdata/fixture/bg.js");
const fx_css = @embedFile("web/webext/testdata/fixture/content.css");
const fx_messages = @embedFile("web/webext/testdata/fixture/_locales/en/messages.json");

const webext_page =
    "<!doctype html><html><head><title>webext-page</title></head>" ++
    "<body>webext test page</body></html>";

fn mkdirZ(path: []const u8) void {
    var buf: [4096]u8 = undefined;
    if (path.len + 1 > buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    _ = c.mkdir(@ptrCast(&buf), 0o755);
}

/// Write the fixture into `<ext_dir>` as an unpacked extension.
fn writeFixture(ext_dir: []const u8) bool {
    mkdirZ(ext_dir);
    var loc_buf: [4200]u8 = undefined;
    const loc = std.fmt.bufPrint(&loc_buf, "{s}/_locales", .{ext_dir}) catch return false;
    mkdirZ(loc);
    var en_buf: [4300]u8 = undefined;
    const en = std.fmt.bufPrint(&en_buf, "{s}/_locales/en", .{ext_dir}) catch return false;
    mkdirZ(en);
    if (!writeFile(ext_dir, "manifest.json", fx_manifest)) return false;
    if (!writeFile(ext_dir, "content.js", fx_content)) return false;
    if (!writeFile(ext_dir, "bg.js", fx_bg)) return false;
    if (!writeFile(ext_dir, "content.css", fx_css)) return false;
    if (!writeFile(en, "messages.json", fx_messages)) return false;
    return true;
}


// ---------------------------------------------------------------------
// Stage 34: blocking webRequest (MV2)
// ---------------------------------------------------------------------

/// A router, unlike `HttpProbe`: stage 34 needs several distinguishable
/// endpoints (a subresource to cancel, a redirect target, a header echo,
/// a page) and one of the properties under test is which of them the
/// browser actually asked for.
const WreqServer = struct {
    fd: c_int = -1,
    port: u16 = 0,
    page_a: []const u8 = "",
    page_b: []const u8 = "",
    page_c: []const u8 = "",
    thread: ?std.Thread = null,
    stop: std.atomic.Value(bool) = .init(false),
    /// Set if `/blockme` was ever requested — a CANCEL must mean the
    /// request never reached the network, not merely that the page saw
    /// an error.
    blockme_hits: std.atomic.Value(u32) = .init(0),

    fn start(self: *WreqServer) bool {
        const lfd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
        if (lfd < 0) return false;
        var one: c_int = 1;
        _ = c.setsockopt(lfd, c.SOL_SOCKET, c.SO_REUSEADDR, &one, @sizeOf(c_int));
        var sa = std.mem.zeroes(c.struct_sockaddr_in);
        sa.sin_family = c.AF_INET;
        sa.sin_port = std.mem.nativeToBig(u16, 0);
        sa.sin_addr.s_addr = std.mem.nativeToBig(u32, c.INADDR_LOOPBACK);
        if (c.bind(lfd, @ptrCast(&sa), @sizeOf(c.struct_sockaddr_in)) != 0 or c.listen(lfd, 64) != 0) {
            _ = c.close(lfd);
            return false;
        }
        var got = std.mem.zeroes(c.struct_sockaddr_in);
        var glen: c.socklen_t = @sizeOf(c.struct_sockaddr_in);
        if (c.getsockname(lfd, @ptrCast(&got), &glen) != 0) {
            _ = c.close(lfd);
            return false;
        }
        self.fd = lfd;
        self.port = std.mem.bigToNative(u16, got.sin_port);
        self.thread = std.Thread.spawn(.{}, WreqServer.serve, .{self}) catch {
            _ = c.close(lfd);
            self.fd = -1;
            return false;
        };
        return true;
    }

    fn serve(self: *WreqServer) void {
        while (!self.stop.load(.acquire)) {
            var pfd = c.struct_pollfd{ .fd = self.fd, .events = c.POLLIN, .revents = 0 };
            if (c.poll(@ptrCast(&pfd), 1, 100) <= 0) continue;
            const afd = c.accept(self.fd, null, null);
            if (afd < 0) continue;
            self.handle(afd);
            _ = c.close(afd);
        }
    }

    fn handle(self: *WreqServer, afd: c_int) void {
        var req: [8192]u8 = undefined;
        var pfd = c.struct_pollfd{ .fd = afd, .events = c.POLLIN, .revents = 0 };
        if (c.poll(@ptrCast(&pfd), 1, 3000) <= 0) return;
        const n = c.read(afd, &req, req.len);
        if (n <= 0) return;
        const raw = req[0..@intCast(n)];

        var body_buf: [8192]u8 = undefined;
        var body: []const u8 = "ok";
        var ctype: []const u8 = "text/plain";
        if (std.mem.indexOf(u8, raw, "GET /pa") != null) {
            body = self.page_a;
            ctype = "text/html";
        } else if (std.mem.indexOf(u8, raw, "GET /pb") != null) {
            body = self.page_b;
            ctype = "text/html";
        } else if (std.mem.indexOf(u8, raw, "GET /pc") != null) {
            body = self.page_c;
            ctype = "text/html";
        } else if (std.mem.indexOf(u8, raw, "GET /blockme") != null) {
            _ = self.blockme_hits.fetchAdd(1, .release);
            body = "REACHED-THE-NETWORK";
        } else if (std.mem.indexOf(u8, raw, "GET /redirdst") != null) {
            body = "REDIRECTED";
        } else if (std.mem.indexOf(u8, raw, "GET /redirme") != null) {
            body = "ORIGINAL";
        } else if (std.mem.indexOf(u8, raw, "GET /echo") != null) {
            // Echo the request headers, lowercased, so the page can see
            // whether the extension's added header really travelled.
            var w = std.Io.Writer.fixed(&body_buf);
            for (raw) |ch| w.writeByte(std.ascii.toLower(ch)) catch break;
            body = body_buf[0..w.end];
        }

        var head: [256]u8 = undefined;
        const hdr = std.fmt.bufPrint(
            &head,
            "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nCache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\nX-Stage: 34\r\nConnection: close\r\n\r\n",
            .{ ctype, body.len },
        ) catch return;
        _ = c.write(afd, hdr.ptr, hdr.len);
        _ = c.write(afd, body.ptr, body.len);
    }

    fn deinit(self: *WreqServer) void {
        self.stop.store(true, .release);
        if (self.thread) |t| t.join();
        self.thread = null;
        if (self.fd >= 0) _ = c.close(self.fd);
        self.fd = -1;
    }
};

const wq_manifest =
    \\{"manifest_version":2,"name":"sketerm wreq fixture","version":"1",
    \\ "permissions":["webRequest","webRequestBlocking","<all_urls>"],
    \\ "background":{"scripts":["bg.js"],"persistent":true}}
;

/// One extension exercising all three blocking events. `/hangme` and
/// `/slowme` return a Promise that NEVER settles — the two ways a
/// listener can fail to answer, which is what stages 34c and 34d are
/// about.
const wq_bg =
    \\browser.webRequest.onBeforeRequest.addListener(function (d) {
    \\  if (d.url.indexOf("/blockme") >= 0) return { cancel: true };
    \\  if (d.url.indexOf("/redirme") >= 0) {
    \\    return { redirectUrl: d.url.replace("/redirme", "/redirdst") };
    \\  }
    \\  if (d.url.indexOf("/hangme") >= 0 || d.url.indexOf("/slowme") >= 0) {
    \\    return new Promise(function () {});
    \\  }
    \\  return {};
    \\}, { urls: ["<all_urls>"] }, ["blocking"]);
    \\
    \\browser.webRequest.onBeforeSendHeaders.addListener(function (d) {
    \\  if (d.url.indexOf("/echo") < 0) return {};
    \\  var h = (d.requestHeaders || []).slice();
    \\  h.push({ name: "X-Sketerm-Stage34", value: "yes" });
    \\  return { requestHeaders: h };
    \\}, { urls: ["<all_urls>"] }, ["blocking", "requestHeaders"]);
    \\
    \\browser.webRequest.onHeadersReceived.addListener(function (d) {
    \\  var h = d.responseHeaders || [];
    \\  for (var i = 0; i < h.length; i++) {
    \\    if (String(h[i].name).toLowerCase() === "x-stage") self.__sawStageHeader = 1;
    \\  }
    \\  return {};
    \\}, { urls: ["<all_urls>"] }, ["blocking", "responseHeaders"]);
    \\
    \\browser.runtime.onMessage.addListener(function (m) {
    \\  if (m === "sawStageHeader") return Promise.resolve(self.__sawStageHeader || 0);
    \\  return null;
    \\});
;

fn wqPageA(buf: []u8, port: u16) []const u8 {
    return std.fmt.bufPrint(buf,
        \\<!doctype html><html><head><title>wq-a-start</title></head><body><script>
        \\var B = "http://127.0.0.1:{d}";
        \\async function t(u) {{
        \\  try {{ var r = await fetch(u); return await r.text(); }} catch (e) {{ return "ERR"; }}
        \\}}
        \\(async function () {{
        \\  var blocked = (await t(B + "/blockme")) === "ERR" ? 1 : 0;
        \\  var red = (await t(B + "/redirme")).indexOf("REDIRECTED") >= 0 ? 1 : 0;
        \\  var hdr = (await t(B + "/echo")).indexOf("x-sketerm-stage34") >= 0 ? 1 : 0;
        \\  document.title = "wq-a:" + blocked + red + hdr;
        \\}})();
        \\</script></body></html>
    , .{port}) catch fail("stage 34 page a");
}

fn wqPageHang(buf: []u8, port: u16, path: []const u8, tag: []const u8) []const u8 {
    return std.fmt.bufPrint(buf,
        \\<!doctype html><html><head><title>{s}-start</title></head><body><script>
        \\(async function () {{
        \\  try {{ await fetch("http://127.0.0.1:{d}{s}"); }} catch (e) {{}}
        \\  document.title = "{s}-done";
        \\}})();
        \\</script></body></html>
    , .{ tag, port, path, tag }) catch fail("stage 34 hang page");
}

/// Stage 34: MV2 blocking webRequest, end to end against real CEF.
///
///   34a  a blocking listener CANCELS a subresource (and the network
///        never saw it), REDIRECTS another, and a modified request
///        header arrives at the server
///   34b  a request held for a listener that never answers is released
///        when the extension is REMOVED mid-flight
///   34c  the same hold, left alone, is released by the TIMEOUT — and
///        released OPEN, not cancelled
///   34d  the measured `onHeadersReceived` ceiling: the listener runs
///        and sees real response headers, and the helper reports the
///        decision it could not apply
fn runWebrequestStage(gpa: std.mem.Allocator, exe: [*:0]const u8, dir: []const u8) void {
    var data_buf: [4096]u8 = undefined;
    const data_dir = std.fmt.bufPrintZ(&data_buf, "{s}/wqdata", .{dir}) catch fail("stage 34 data path");
    mkdirZ(data_dir);
    _ = c.setenv("XDG_DATA_HOME", data_dir.ptr, 1);
    var cache_buf: [4096]u8 = undefined;
    const cache_dir = std.fmt.bufPrintZ(&cache_buf, "{s}/wqcache", .{dir}) catch fail("stage 34 cache path");
    mkdirZ(cache_dir);

    var ext_buf: [4096]u8 = undefined;
    const ext_dir = std.fmt.bufPrint(&ext_buf, "{s}/wqfix", .{dir}) catch fail("stage 34 ext path");
    mkdirZ(ext_dir);
    if (!writeFile(ext_dir, "manifest.json", wq_manifest)) fail("stage 34: could not write the fixture manifest");
    if (!writeFile(ext_dir, "bg.js", wq_bg)) fail("stage 34: could not write the fixture background");

    var srv = WreqServer{};
    if (!srv.start()) fail("stage 34: loopback HTTP server would not start");
    defer srv.deinit();
    var pa_buf: [2048]u8 = undefined;
    var pb_buf: [1024]u8 = undefined;
    var pc_buf: [1024]u8 = undefined;
    srv.page_a = wqPageA(&pa_buf, srv.port);
    srv.page_b = wqPageHang(&pb_buf, srv.port, "/hangme", "wq-b");
    srv.page_c = wqPageHang(&pc_buf, srv.port, "/slowme", "wq-c");

    var url_a: [96]u8 = undefined;
    var url_b: [96]u8 = undefined;
    var url_c: [96]u8 = undefined;
    const page_a = std.fmt.bufPrint(&url_a, "http://127.0.0.1:{d}/pa", .{srv.port}) catch fail("url");
    const page_b = std.fmt.bufPrint(&url_b, "http://127.0.0.1:{d}/pb", .{srv.port}) catch fail("url");
    const page_c = std.fmt.bufPrint(&url_c, "http://127.0.0.1:{d}/pc", .{srv.port}) catch fail("url");

    const ext_id = "wreqfixture01";

    // ── Helper 1: a deliberately LONG fail-open deadline, so that in
    // 34b it is unambiguously the REMOVAL, and not the timeout, that
    // released the held request.
    {
        _ = c.setenv("SKETERM_WEB_WREQ_TIMEOUT_MS", "20000", 1);
        var sock_buf: [96]u8 = undefined;
        const sock = std.fmt.bufPrintZ(&sock_buf, "{s}/wq1.sock", .{dir}) catch fail("stage 34 sock");
        const pid = spawnHelper(exe, sock.ptr, cache_dir.ptr, "--ozone-platform=headless", false);
        var cl = Client{ .gpa = gpa, .fd = connectWithRetry(sock.ptr, sock.len) };
        cl.send(proto.Hello{ .proto = proto.PROTO_VERSION, .client_name = "smoke-web" });
        {
            const d = nowMs() + 15_000;
            while (cl.ack_proto == 0 and nowMs() < d) cl.pump(100);
        }
        if (!cl.ack_webext) fail("stage 34: hello_ack lacks the webext capability");

        cl.send(proto.WebextSet{ .id = ext_id, .dir = ext_dir, .enabled = 1 });
        {
            const d = nowMs() + 5_000;
            while (cl.we_ok == 0xff and nowMs() < d) cl.pump(100);
        }
        if (cl.we_ok != 1) {
            std.debug.print("stage 34: load error \"{s}\"\n", .{cl.we_err[0..cl.we_err_len]});
            fail("stage 34: the fixture extension failed to load");
        }
        // The background page must be up and its three listeners
        // registered before any request is made, or the stage would be
        // measuring a race instead of the feature.
        {
            const d = nowMs() + 2500;
            while (nowMs() < d) cl.pump(50);
        }

        cl.send(proto.ViewCreate{ .view = view_id, .w = 640, .h = 480, .scale_x1000 = 1000, .context = 0 });
        cl.have_view = true;
        if (!cl.waitBufferAfter(0, 20_000)) fail("stage 34: no frame_buffer for the page view");

        // -- 34a: cancel, redirect, header modification ---------------
        cl.resetTitle();
        cl.send(proto.Navigate{ .view = view_id, .url = page_a });
        if (!cl.waitTitle("wq-a:", 30_000)) {
            std.debug.print("stage 34a: title was \"{s}\"\n", .{cl.titleSlice()});
            fail("stage 34a: the page never reported its results");
        }
        const res = cl.titleSlice();
        if (!std.mem.eql(u8, res, "wq-a:111")) {
            std.debug.print("stage 34a: expected \"wq-a:111\" (cancel/redirect/header), got \"{s}\"\n", .{res});
            fail("stage 34a: a blocking decision did not take effect");
        }
        if (srv.blockme_hits.load(.acquire) != 0) {
            fail("stage 34a: the cancelled request still reached the network");
        }

        // -- 34d: the onHeadersReceived ceiling -----------------------
        cl.wq_seen = false;
        cl.send(proto.WebextWreqStatsReq{});
        {
            const d = nowMs() + 3000;
            while (!cl.wq_seen and nowMs() < d) cl.pump(50);
        }
        if (!cl.wq_seen) fail("stage 34d: the helper never answered webext_wreq_stats");
        if (cl.wq_held == 0) fail("stage 34d: no request was ever held");
        if (cl.wq_cancelled == 0) fail("stage 34d: the cancel was not counted");
        if (cl.wq_redirected == 0) fail("stage 34d: the redirect was not counted");
        if (cl.wq_headers_modified == 0) fail("stage 34d: the header modification was not counted");
        // The CANARY for the measured engine limitation: the
        // onHeadersReceived listener ran (it saw the real X-Stage
        // response header) but the helper counted its decision as
        // undeliverable. If a future CEF grows an async response hook,
        // this assertion is what will fail and say so.
        if (cl.wq_hdr_recv_dropped == 0) {
            fail("stage 34d: onHeadersReceived was never dispatched at all");
        }
        if (cl.wq_timed_out != 0 or cl.wq_failed_open != 0) {
            fail("stage 34d: an ordinary page load should never fail a request open");
        }
        pass("stage 34a blocking webRequest (cancel never hits the network, redirect lands, header arrives)");
        pass("stage 34d onHeadersReceived runs and sees real headers; its decision is counted, not applied");

        // -- 34b: held request survives removal mid-flight ------------
        cl.resetTitle();
        cl.send(proto.Navigate{ .view = view_id, .url = page_b });
        if (!cl.waitTitle("wq-b-start", 30_000)) fail("stage 34b: the hang page never loaded");
        // Let the fetch actually start and be HELD (its listener returns
        // a Promise that never settles).
        {
            const d = nowMs() + 1500;
            while (nowMs() < d) cl.pump(50);
        }
        cl.send(proto.WebextRemove{ .id = ext_id });
        // 20s deadline vs a 10s wait: only the removal can answer here.
        if (!cl.waitTitle("wq-b-done", 10_000)) {
            std.debug.print("stage 34b: title was \"{s}\"\n", .{cl.titleSlice()});
            fail("stage 34b: a request held by a removed extension never completed");
        }
        pass("stage 34b held request released when the extension is removed mid-flight");

        cl.send(proto.ViewDestroy{ .view = view_id });
        cl.have_view = false;
        {
            const d = nowMs() + 2500;
            while (nowMs() < d) cl.pump(50);
        }
        cl.deinit();
        reapHelperTolerant(pid, "stage 34 helper 1", 30_000);
    }

    // ── Helper 2: a SHORT fail-open deadline, so the timeout itself is
    // what releases the request — and releases it open.
    {
        _ = c.setenv("SKETERM_WEB_WREQ_TIMEOUT_MS", "400", 1);
        var sock_buf: [96]u8 = undefined;
        const sock = std.fmt.bufPrintZ(&sock_buf, "{s}/wq2.sock", .{dir}) catch fail("stage 34 sock2");
        const pid = spawnHelper(exe, sock.ptr, cache_dir.ptr, "--ozone-platform=headless", false);
        var cl = Client{ .gpa = gpa, .fd = connectWithRetry(sock.ptr, sock.len) };
        cl.send(proto.Hello{ .proto = proto.PROTO_VERSION, .client_name = "smoke-web" });
        {
            const d = nowMs() + 15_000;
            while (cl.ack_proto == 0 and nowMs() < d) cl.pump(100);
        }
        cl.send(proto.WebextSet{ .id = ext_id, .dir = ext_dir, .enabled = 1 });
        {
            const d = nowMs() + 5_000;
            while (cl.we_ok == 0xff and nowMs() < d) cl.pump(100);
        }
        if (cl.we_ok != 1) fail("stage 34c: the fixture extension failed to load");
        {
            const d = nowMs() + 2500;
            while (nowMs() < d) cl.pump(50);
        }

        cl.send(proto.ViewCreate{ .view = view_id, .w = 640, .h = 480, .scale_x1000 = 1000, .context = 0 });
        cl.have_view = true;
        if (!cl.waitBufferAfter(0, 20_000)) fail("stage 34c: no frame_buffer");
        cl.resetTitle();
        cl.send(proto.Navigate{ .view = view_id, .url = page_c });
        // The extension is untouched: only the deadline can answer, and
        // it must answer CONTINUE — a fail-open. A cancel here would
        // show up as the fetch rejecting, but the page reports done
        // either way, so the counters below are the real assertion.
        if (!cl.waitTitle("wq-c-done", 20_000)) {
            std.debug.print("stage 34c: title was \"{s}\"\n", .{cl.titleSlice()});
            fail("stage 34c: a request held by a listener that never answers hung past its deadline");
        }
        cl.wq_seen = false;
        cl.send(proto.WebextWreqStatsReq{});
        {
            const d = nowMs() + 3000;
            while (!cl.wq_seen and nowMs() < d) cl.pump(50);
        }
        if (!cl.wq_seen) fail("stage 34c: the helper never answered webext_wreq_stats");
        if (cl.wq_timed_out == 0) fail("stage 34c: the timeout path was never taken");
        if (cl.wq_failed_open < cl.wq_timed_out) fail("stage 34c: a timeout must be counted as a fail-open");
        if (cl.wq_cancelled != 0) fail("stage 34c: a timeout must never cancel a request");
        pass("stage 34c a never-answering listener times out and fails OPEN, never cancels");

        cl.send(proto.WebextRemove{ .id = ext_id });
        cl.send(proto.ViewDestroy{ .view = view_id });
        cl.have_view = false;
        {
            const d = nowMs() + 2500;
            while (nowMs() < d) cl.pump(50);
        }
        cl.deinit();
        reapHelperTolerant(pid, "stage 34 helper 2", 30_000);
    }
    _ = c.unsetenv("SKETERM_WEB_WREQ_TIMEOUT_MS");
}

/// Stage 28: the WebExtensions foundation, end to end against real CEF.
/// Run 1 proves content-script injection at document_end (a DOM mutation
/// and a title change) and runtime.sendMessage to the background with a
/// reply; run 2 (a fresh helper, same XDG_DATA_HOME) proves
/// storage.local persisted across the restart.
fn runWebextStage(gpa: std.mem.Allocator, exe: [*:0]const u8, dir: []const u8) void {
    // Isolated data dir for storage.json, and the unpacked extension.
    var data_buf: [4096]u8 = undefined;
    const data_dir = std.fmt.bufPrintZ(&data_buf, "{s}/wedata", .{dir}) catch fail("webext data path");
    mkdirZ(data_dir);
    var cache_buf: [4096]u8 = undefined;
    const cache_dir = std.fmt.bufPrintZ(&cache_buf, "{s}/wecache", .{dir}) catch fail("webext cache path");
    mkdirZ(cache_dir);
    var ext_buf: [4096]u8 = undefined;
    const ext_dir = std.fmt.bufPrint(&ext_buf, "{s}/wefix", .{dir}) catch fail("webext ext path");
    if (!writeFixture(ext_dir)) fail("stage 33 webext: could not write the fixture extension");
    // The helper reads XDG_DATA_HOME for its per-extension storage; a
    // child inherits this, and both runs share it so storage persists.
    _ = c.setenv("XDG_DATA_HOME", data_dir.ptr, 1);

    var srv = HttpProbe{ .body = webext_page };
    if (!srv.start()) fail("stage 33 webext: loopback HTTP server would not start");
    defer srv.shutdown();
    var page_buf: [96]u8 = undefined;
    const page_url = std.fmt.bufPrint(&page_buf, "http://127.0.0.1:{d}/p", .{srv.port}) catch fail("webext url");

    const ext_id = "smokefixture01";

    // ── Run 1: injection + messaging ──────────────────────────────
    {
        var sock_buf: [96]u8 = undefined;
        const sock = std.fmt.bufPrintZ(&sock_buf, "{s}/we1.sock", .{dir}) catch fail("webext sock");
        const pid = spawnHelper(exe, sock.ptr, cache_dir.ptr, "--ozone-platform=headless", false);
        var cl = Client{ .gpa = gpa, .fd = connectWithRetry(sock.ptr, sock.len) };
        cl.send(proto.Hello{ .proto = proto.PROTO_VERSION, .client_name = "smoke-web" });
        {
            const d = nowMs() + 15_000;
            while (cl.ack_proto == 0 and nowMs() < d) cl.pump(100);
        }
        if (!cl.ack_webext) fail("stage 33 webext: hello_ack lacks the webext capability");

        cl.send(proto.WebextSet{ .id = ext_id, .dir = ext_dir, .enabled = 1 });
        {
            const d = nowMs() + 5_000;
            while (cl.we_ok == 0xff and nowMs() < d) cl.pump(100);
        }
        if (cl.we_ok != 1) fail("stage 33 webext: extension failed to load (ok=0)");
        if (cl.we_enabled != 1) fail("stage 33 webext: extension not reported enabled");
        if (!std.mem.eql(u8, cl.we_name[0..cl.we_name_len], "sketerm smoke fixture")) {
            fail("stage 33 webext: manifest name not reported");
        }

        // Give the background page a moment to come up (its listener must
        // exist before the content script's message arrives).
        {
            const d = nowMs() + 1500;
            while (nowMs() < d) cl.pump(50);
        }

        cl.send(proto.ViewCreate{ .view = view_id, .w = 640, .h = 480, .scale_x1000 = 1000, .context = 0 });
        cl.have_view = true;
        if (!cl.waitBufferAfter(0, 20_000)) fail("stage 33 webext: no frame_buffer for the page view");
        cl.resetTitle();
        cl.send(proto.Navigate{ .view = view_id, .url = page_url });
        // "reply:42:hello" proves: content script injected (it set the
        // title), it reached the background over runtime.sendMessage, the
        // background replied {n:42}, AND browser.i18n.getMessage worked.
        if (!cl.waitTitle("reply:42:hello", 25_000)) {
            std.debug.print("stage 33: title was \"{s}\"\n", .{cl.titleSlice()});
            fail("stage 33 webext: content script did not report the background reply");
        }
        pass("stage 33 webext run 1 (content script injected, background messaged, i18n)");

        // Tear the extension down first so its hidden background browser
        // is closed during the normal loop, not left for cef_shutdown.
        cl.send(proto.WebextRemove{ .id = ext_id });
        cl.send(proto.ViewDestroy{ .view = view_id });
        cl.have_view = false;
        {
            const d = nowMs() + 2500;
            while (nowMs() < d) cl.pump(50);
        }
        cl.deinit(); // close the socket so the helper disconnects and exits
        reapHelperTolerant(pid, "stage 33 webext run 1", 30_000);
    }

    // ── Run 2: storage.local persisted across the restart ─────────
    {
        var sock_buf: [96]u8 = undefined;
        const sock = std.fmt.bufPrintZ(&sock_buf, "{s}/we2.sock", .{dir}) catch fail("webext sock2");
        const pid = spawnHelper(exe, sock.ptr, cache_dir.ptr, "--ozone-platform=headless", false);
        var cl = Client{ .gpa = gpa, .fd = connectWithRetry(sock.ptr, sock.len) };
        cl.send(proto.Hello{ .proto = proto.PROTO_VERSION, .client_name = "smoke-web" });
        {
            const d = nowMs() + 15_000;
            while (cl.ack_proto == 0 and nowMs() < d) cl.pump(100);
        }
        cl.send(proto.WebextSet{ .id = ext_id, .dir = ext_dir, .enabled = 1 });
        {
            const d = nowMs() + 5_000;
            while (cl.we_ok == 0xff and nowMs() < d) cl.pump(100);
        }
        if (cl.we_ok != 1) fail("stage 33 webext: extension failed to load on restart");

        cl.send(proto.ViewCreate{ .view = view_id, .w = 640, .h = 480, .scale_x1000 = 1000, .context = 0 });
        cl.have_view = true;
        if (!cl.waitBufferAfter(0, 20_000)) fail("stage 33 webext: no frame_buffer on restart");
        cl.resetTitle();
        cl.send(proto.Navigate{ .view = view_id, .url = page_url });
        // "stored:v1" proves the value the FIRST helper wrote to
        // storage.local survived to this SECOND helper process.
        if (!cl.waitTitle("stored:v1", 25_000)) {
            std.debug.print("stage 33: title was \"{s}\"\n", .{cl.titleSlice()});
            fail("stage 33 webext: storage.local did not persist across the restart");
        }
        pass("stage 33 webext run 2 (storage.local persisted across a helper restart)");

        cl.send(proto.WebextRemove{ .id = ext_id });
        cl.send(proto.ViewDestroy{ .view = view_id });
        cl.have_view = false;
        {
            const d = nowMs() + 2500;
            while (nowMs() < d) cl.pump(50);
        }
        cl.deinit(); // close the socket so the helper disconnects and exits
        reapHelperTolerant(pid, "stage 33 webext run 2", 30_000);
    }
}

pub fn main(init: std.process.Init.Minimal) u8 {
    _ = c.signal(c.SIGPIPE, c.SIG_IGN);
    const argv = init.args.vector;
    if (argv.len < 2) {
        std.debug.print("smoke-web: usage: smoke-web <path-to-sketerm-web>\n", .{});
        return 2;
    }
    const exe = argv[1];
    if (c.access(exe, c.X_OK) != 0) fail("sketerm-web binary is not executable");

    var gpa_state: std.heap.DebugAllocator(.{ .safety = true }) = .{};
    const gpa = gpa_state.allocator();

    // Short private paths: sockaddr_un caps at ~108 bytes, so the
    // socket cannot live under a deep scratch directory.
    const tmpl = "/tmp/skweb-XXXXXX";
    @memcpy(g_dir[0..tmpl.len], tmpl);
    if (c.mkdtemp(@ptrCast(&g_dir)) == null) fail("mkdtemp");
    const dir = std.mem.span(@as([*:0]const u8, @ptrCast(&g_dir)));

    var sock_buf: [96]u8 = undefined;
    const sock = std.fmt.bufPrintZ(&sock_buf, "{s}/w.sock", .{dir}) catch fail("socket path");
    var cache_buf: [96]u8 = undefined;
    const cache = std.fmt.bufPrintZ(&cache_buf, "{s}/cache", .{dir}) catch fail("cache path");

    // ── Spawn the helper ──────────────────────────────────────────
    //
    // Pinned to headless software rendering: 22 of the stages below
    // assert on pixels in the memfd, and the GPU path delivers dma-buf
    // planes instead. The GPU path gets its own helper in stage 24.
    const pid = spawnHelper(exe, sock.ptr, cache.ptr, "--ozone-platform=headless", false);
    g_pid = pid;

    var cl = Client{ .gpa = gpa, .fd = connectWithRetry(sock.ptr, sock.len) };

    // ── Stage 1: handshake ────────────────────────────────────────
    cl.send(proto.Hello{ .proto = proto.PROTO_VERSION, .client_name = "smoke-web" });
    {
        const deadline = nowMs() + 15_000;
        while (cl.ack_proto == 0 and nowMs() < deadline) cl.pump(100);
    }
    if (cl.ack_proto != proto.PROTO_VERSION) fail("stage 1 handshake: no hello_ack with proto 1");
    if (!cl.ack_shm) fail("stage 1 handshake: hello_ack lacks the frames-shm capability");
    if (!cl.ack_tls) fail("stage 1 handshake: hello_ack lacks the tls capability");
    if (!cl.ack_permissions) fail("stage 1 handshake: hello_ack lacks the permissions capability");
    pass("stage 1 handshake");

    // ── Stage 2: paint into the shared memfd ──────────────────────
    cl.send(proto.ViewCreate{ .view = view_id, .w = 800, .h = 600, .scale_x1000 = 1000, .context = 0 });
    cl.have_view = true;
    if (!cl.waitBufferAfter(0, 20_000)) fail("stage 2 paint: no frame_buffer for the new view");
    if (cl.fb.?.w != 800 or cl.fb.?.h != 600) fail("stage 2 paint: frame_buffer geometry is not 800x600");
    cl.navigate(red_page);
    if (!cl.waitCenterColor(.{ 0, 0, 255 }, 20_000)) fail("stage 2 paint: centre pixel never turned red");
    pass("stage 2 paint (memfd frame, centre pixel red)");

    // ── Stage 3: trusted click ────────────────────────────────────
    cl.navigate(click_page);
    if (!cl.waitCenterColor(.{ 255, 0, 0 }, 20_000)) fail("stage 3 click: button page never painted blue");
    cl.send(proto.InputFocus{ .view = view_id, .focused = 1 });
    cl.clickCenter();
    if (!cl.waitTitle("result:trusted=true", 15_000)) {
        std.debug.print("smoke-web: title was \"{s}\"\n", .{cl.titleSlice()});
        fail("stage 3 click: no trusted click reported by the page");
    }
    pass("stage 3 trusted click");

    // ── Stage 4: keyboard text entry ──────────────────────────────
    cl.navigate(input_page);
    cl.send(proto.InputFocus{ .view = view_id, .focused = 1 });
    cl.typeKey(0x68, "h");
    cl.typeKey(0x69, "i");
    if (!cl.waitTitle("typed:hi", 15_000)) {
        std.debug.print("smoke-web: title was \"{s}\"\n", .{cl.titleSlice()});
        fail("stage 4 typing: the page did not receive \"hi\"");
    }
    pass("stage 4 typing");

    // ── Stage 5: resize announces a new buffer ────────────────────
    {
        const old_buf = cl.fb.?.buf_id;
        const seq = cl.fb_seq;
        const dmg = cl.dmg_seq;
        cl.send(proto.ViewResize{ .view = view_id, .w = 640, .h = 480, .scale_x1000 = 1000 });
        if (!cl.waitBufferAfter(seq, 20_000)) fail("stage 5 resize: no new frame_buffer");
        const fb = cl.fb.?;
        if (fb.buf_id == old_buf) fail("stage 5 resize: buf_id was not replaced");
        if (fb.w != 640 or fb.h != 480) fail("stage 5 resize: new buffer is not 640x480");
        if (!cl.waitDamageAfter(dmg, 20_000)) fail("stage 5 resize: no damage for the new buffer");
        cl.mapBuffer();
        _ = cl.pixel(fb.w / 2, fb.h / 2);
        cl.send(proto.FrameRelease{ .view = view_id, .buf_id = old_buf });
        pass("stage 5 resize (new buffer mapped at 640x480)");
    }

    // ── Stage 6: popup request is reported, never opened ───────────
    cl.navigate(popup_page);
    cl.send(proto.InputFocus{ .view = view_id, .focused = 1 });
    // The click is RETRIED: a page whose first compositor frame has not
    // landed yet swallows input, and this stage has always been the one
    // that notices (the HiDPI stage was moved to the end for the same
    // reason). One click plus a settle is a race; five is not.
    {
        var tries: u8 = 0;
        while (tries < 5 and !cl.sawPopup("example.invalid")) : (tries += 1) {
            cl.clickCenter();
            _ = cl.drive(400, 120);
        }
    }
    if (!cl.waitPopup("example.invalid", 15_000)) fail("stage 6 popup: no ev_popup_request for the opened url");
    if (cl.popup_view != view_id) fail("stage 6 popup: ev_popup_request carried the wrong opener view");
    // A popup opened from a click IS gesture-backed: the GUI's default
    // popup policy opens exactly these and blocks the rest, so the flag
    // has to be right in both directions.
    if (cl.popup_gesture != 1) fail("stage 6 popup: a clicked window.open was not reported as a user gesture");
    pass("stage 6 popup request (gesture-backed)");

    // ── Stage 6b: the engine blocks a gestureless popup itself ─────
    // MEASURED, and the reason the GUI's `block-gestureless` policy is
    // a second line of defence rather than the only one: Chromium's own
    // popup blocker eats a `window.open` with no user activation BEFORE
    // on_before_popup runs, so no `ev_popup_request` is posted at all.
    // The wire's gesture flag is still what the policy keys on (a
    // `block-all` policy, and any future engine without a blocker of
    // its own, need it); its absent-means-gesture default is covered by
    // the protocol unit tests, which can produce a payload this engine
    // never will.
    cl.popup_gesture = 0xff;
    cl.popup_len = 0;
    cl.navigate(popup_auto_page);
    _ = cl.drive(3000, 120);
    if (cl.sawPopup("auto.invalid")) fail("stage 6b popup: the engine forwarded a gestureless window.open");
    pass("stage 6b gestureless popup (never reaches the client)");

    // ── Stage 7: history navigation ───────────────────────────────
    cl.navigate(red_page);
    cl.navigate(blue_page);
    cl.send(proto.NavAction{ .view = view_id, .action = @intFromEnum(proto.NavAct.back) });
    if (!cl.waitCanForward(20_000)) fail("stage 7 nav_action: no ev_nav_state with can_fwd=1 after going back");
    pass("stage 7 nav_action back");

    // ── Stage 8: semantic snapshot, ids stable across two requests ─
    if (!cl.ack_semantic) fail("stage 8 semantic: hello_ack lacks the semantic capability");
    cl.navigate(form_page);
    cl.resetSem();
    cl.snapshot(1, 1);
    {
        const want = [_][]const u8{
            "heading \"Semantic Form\"",
            "link \"Alpha\"",
            "textbox \"Name\"",
            "button \"Go\"",
        };
        for (want) |needle| {
            if (!cl.waitSem(needle, 20_000)) {
                std.debug.print("smoke-web: snapshot was:\n{s}\n", .{cl.semLog()});
                fail("stage 8 semantic: the snapshot is missing an expected node");
            }
        }
    }
    const go_id = cl.idOfLine("button \"Go\"") orelse fail("stage 8 semantic: no id on the button line");
    const lbl_id = cl.idOfLine("paragraph \"before\"") orelse fail("stage 8 semantic: no id on the label line");
    const long_id = cl.idOfExpandMarker() orelse fail("stage 8 semantic: the long paragraph was not truncated");
    {
        // A second FULL snapshot must reuse the same ids.
        cl.resetSem();
        cl.snapshot(1, 1);
        if (!cl.waitSem("button \"Go\"", 20_000)) fail("stage 8 semantic: no second snapshot");
        const again = cl.idOfLine("button \"Go\"") orelse fail("stage 8 semantic: no id on the second button line");
        if (again != go_id) fail("stage 8 semantic: the button's stable id changed between snapshots");
    }
    pass("stage 8 semantic snapshot (roles, names, stable ids)");

    // ── Stage 9: trusted sem_act click and the delta it causes ─────
    cl.resetTitle();
    cl.resetSem();
    {
        const seq = cl.act_seq;
        cl.send(proto.SemAction{
            .view = view_id,
            .id = go_id,
            .action = @intFromEnum(proto.SemAct.click),
            .arg = "",
        });
        if (!cl.waitSeq(&cl.act_seq, seq, 20_000)) fail("stage 9 sem_act: no sem_act_result");
        if (cl.act_ok != 1 or cl.act_id != go_id) fail("stage 9 sem_act: the act failed");
        if (!cl.waitTitle("clicked:trusted=true", 15_000)) {
            std.debug.print("smoke-web: title was \"{s}\"\n", .{cl.titleSlice()});
            fail("stage 9 sem_act: the click was not trusted");
        }
    }
    // Coalescing means the delta is ANSWERED, never pushed: ask for it.
    cl.resetSem();
    cl.snapshot(@intFromEnum(proto.SnapMode.auto), 1);
    if (std.mem.indexOf(u8, cl.semLog(), "~ [") == null) fail("stage 9 delta: no changed-node line in the reply");
    if (std.mem.indexOf(u8, cl.semLog(), "after") == null) fail("stage 9 delta: the changed label is missing");
    {
        var mark: [64]u8 = undefined;
        const changed = std.fmt.bufPrint(&mark, "~ [{d}]", .{lbl_id}) catch fail("bufPrint");
        if (std.mem.indexOf(u8, cl.semLog(), changed) == null) {
            std.debug.print("smoke-web: delta was:\n{s}\n", .{cl.semLog()});
            fail("stage 9 delta: the label's own id is not marked changed");
        }
        if (cl.sem_kind != @intFromEnum(proto.SnapKind.delta)) fail("stage 9 delta: the snapshot was not a delta");
        if (std.mem.indexOf(u8, cl.semLast(), "Semantic Form") != null) {
            std.debug.print("smoke-web: delta was:\n{s}\n", .{cl.semLast()});
            fail("stage 9 delta: unchanged siblings leaked into the delta");
        }
    }
    pass("stage 9 sem_act trusted click + delta");

    // ── Stage 10: expand a truncated paragraph ─────────────────────
    {
        const seq = cl.exp_seq;
        cl.send(proto.SemExpand{ .view = view_id, .id = long_id, .off = 0, .len = 4096 });
        if (!cl.waitSeq(&cl.exp_seq, seq, 20_000)) fail("stage 10 sem_expand: no sem_expand_result");
        const text = cl.exp_text[0..cl.exp_len];
        if (std.mem.indexOf(u8, text, "ENDOFLONG") == null) {
            std.debug.print("smoke-web: expand returned \"{s}\"\n", .{text});
            fail("stage 10 sem_expand: the expansion did not reach the end of the paragraph");
        }
    }
    pass("stage 10 sem_expand");

    // ── Stage 11: cross-navigation id carrying ─────────────────────
    cl.navigate(nav_page_a);
    cl.resetSem();
    cl.snapshot(1, 1);
    if (!cl.waitSem("link \"Three\"", 20_000)) fail("stage 11 cross-nav: no snapshot of the first page");
    const three_id = cl.idOfLine("link \"Three\"") orelse fail("stage 11 cross-nav: no id for a nav link");
    cl.navigate(nav_page_b);
    // The carry is reported by the first snapshot CONSUMED after the
    // navigation (nothing is pushed for the navigation itself).
    cl.resetSem();
    cl.snapshot(@intFromEnum(proto.SnapMode.auto), 1);
    if (std.mem.indexOf(u8, cl.semLog(), "carried [") == null) {
        std.debug.print("smoke-web: post-navigation payload was:\n{s}\n", .{cl.semLog()});
        fail("stage 11 cross-nav: the navigation did not carry any ids");
    }
    cl.resetSem();
    cl.snapshot(1, 1);
    if (!cl.waitSem("link \"Three\"", 20_000)) fail("stage 11 cross-nav: no snapshot of the second page");
    {
        const carried = cl.idOfLine("link \"Three\"") orelse fail("stage 11 cross-nav: no id after the navigation");
        if (carried != three_id) fail("stage 11 cross-nav: the shared nav link did not keep its id");
    }
    pass("stage 11 cross-navigation id carrying");

    // ── Stage 12: reader-mode extraction ───────────────────────────
    cl.navigate(article_page);
    {
        const seq = cl.md_seq;
        cl.send(proto.SemRead{ .view = view_id });
        if (!cl.waitSeq(&cl.md_seq, seq, 20_000)) fail("stage 12 sem_read: no sem_read_result");
        const markdown = cl.md[0..cl.md_len];
        if (std.mem.indexOf(u8, markdown, "# Article Heading") == null) {
            std.debug.print("smoke-web: markdown was:\n{s}\n", .{markdown});
            fail("stage 12 sem_read: the article heading is missing from the markdown");
        }
        if (std.mem.indexOf(u8, markdown, "second paragraph") == null) {
            fail("stage 12 sem_read: the article body is missing from the markdown");
        }
    }
    pass("stage 12 sem_read");

    // ── Stage 13: query the shadow tree ────────────────────────────
    // (covered by unit tests too; here it proves the frame round-trips)
    {
        cl.resetSem();
        cl.snapshot(1, 1);
        const seq = cl.query_seq;
        cl.send(proto.SemQueryReq{
            .view = view_id,
            .kind = @intFromEnum(proto.SemQuery.find_text),
            .arg = "Article",
        });
        if (!cl.waitSeq(&cl.query_seq, seq, 20_000)) fail("stage 13 sem_query: no sem_query_result");
        if (std.mem.indexOf(u8, cl.queryPayload(), "Article Heading") == null) {
            std.debug.print("smoke-web: query result was:\n{s}\n", .{cl.queryPayload()});
            fail("stage 13 sem_query: the heading was not found in the shadow tree");
        }
    }
    pass("stage 13 sem_query");

    // ── Stage 13c: link hints (`visible` query = fresh rects + urls) ─
    // The GUI's hint overlay is widget-side and not smokeable here;
    // what this proves is the whole data path it consumes: the query
    // solicits a FRESH walk, the reply carries per-element rects and
    // link urls, and viewport clipping / disabled filtering hold.
    {
        cl.navigate(hints_page);
        const seq = cl.query_seq;
        cl.send(proto.SemQueryReq{
            .view = view_id,
            .kind = @intFromEnum(proto.SemQuery.visible),
            .arg = "800 600",
        });
        if (!cl.waitSeq(&cl.query_seq, seq, 20_000)) fail("stage 13c hints: no sem_query_result");
        const payload = cl.queryPayload();
        if (!std.mem.startsWith(u8, payload, "hints ")) {
            std.debug.print("smoke-web: hints payload was:\n{s}\n", .{payload});
            fail("stage 13c hints: reply is not a hints payload");
        }
        const parsed = (webhints.parse(gpa, payload) catch fail("stage 13c hints: parse error")) orelse
            fail("stage 13c hints: parse refused the payload");
        defer gpa.free(parsed);
        var alpha: ?webhints.Hint = null;
        var press = false;
        for (parsed) |h| {
            if (std.mem.endsWith(u8, h.url, "/alpha")) alpha = h;
            if (std.mem.eql(u8, h.name, "Press")) press = true;
            if (std.mem.endsWith(u8, h.url, "/far")) fail("stage 13c hints: off-viewport link was listed");
            if (std.mem.eql(u8, h.name, "Dead")) fail("stage 13c hints: disabled button was listed");
        }
        const a = alpha orelse fail("stage 13c hints: the alpha link is missing");
        if (!std.mem.eql(u8, a.role, "link")) fail("stage 13c hints: alpha's role is not link");
        if (!std.mem.eql(u8, a.name, "Alpha Link")) fail("stage 13c hints: alpha's name is wrong");
        if (a.w <= 0 or a.h <= 0) fail("stage 13c hints: alpha has no box");
        if (a.y < 0 or a.y >= 600) fail("stage 13c hints: alpha's rect is outside the viewport");
        if (!press) fail("stage 13c hints: the button is missing");
    }
    pass("stage 13c link hints (fresh rects, urls, viewport clip)");

    // ── Stage 13b: spontaneous churn coalesces into ONE delta ──────
    // A page that rebuilds identical rows and blinks a popup on a
    // timer, left alone for several quiesce cycles with nobody
    // consuming. The default snapshot must answer with exactly one
    // delta section in which the cancelled-out churn and the
    // re-rendered rows do not appear; the history opt-in must still
    // replay the churn revision by revision.
    {
        cl.navigate(churn_page);
        cl.resetSem();
        cl.snapshot(@intFromEnum(proto.SnapMode.full), 1); // the consumed baseline
        const row_id = cl.idOfLine("\"Alpha row one\"") orelse fail("stage 13b churn: no id for a list row");

        // Phase 1: churn with nobody consuming, then read the replay.
        cl.resetTitle();
        cl.clickCenter();
        if (!cl.waitTitle("churn:done1", 25_000)) fail("stage 13b churn: phase 1 never finished");
        {
            const until = nowMs() + 700; // the final mutation's quiesce walk
            while (nowMs() < until) cl.pump(50);
        }
        cl.resetSem();
        cl.snapshot(@intFromEnum(proto.SnapMode.history), 1);
        const hist_len = cl.semLast().len;
        if (std.mem.indexOf(u8, cl.semLast(), "Popup flash") == null)
            fail("stage 13b churn: the history replay lost the popup");
        if (std.mem.count(u8, cl.semLast(), "delta rev") < 2)
            fail("stage 13b churn: the history replay is not per-revision");

        // Phase 2: identical churn, consumed with the default mode.
        cl.resetTitle();
        cl.clickCenter();
        if (!cl.waitTitle("churn:done2", 25_000)) fail("stage 13b churn: phase 2 never finished");
        {
            const until = nowMs() + 700;
            while (nowMs() < until) cl.pump(50);
        }
        cl.resetSem();
        cl.snapshot(@intFromEnum(proto.SnapMode.auto), 1);
        const co = cl.semLast();
        if (cl.sem_kind != @intFromEnum(proto.SnapKind.delta))
            fail("stage 13b churn: the coalesced answer was not a delta");
        if (std.mem.count(u8, co, "delta rev") != 1) {
            std.debug.print("smoke-web: coalesced payload was:\n{s}\n", .{co});
            fail("stage 13b churn: expected exactly one delta section");
        }
        if (std.mem.indexOf(u8, co, "Popup") != null)
            fail("stage 13b churn: cancelled-out popup churn leaked into the delta");
        if (std.mem.indexOf(u8, co, "\n+ [") != null or std.mem.indexOf(u8, co, "\n- [") != null) {
            std.debug.print("smoke-web: coalesced payload was:\n{s}\n", .{co});
            fail("stage 13b churn: re-rendered identical rows leaked into the delta");
        }
        if (co.len * 3 >= hist_len) {
            std.debug.print("smoke-web: coalesced {d} bytes vs replay {d} bytes\n", .{ co.len, hist_len });
            fail("stage 13b churn: the coalesced delta is not materially smaller than the replay");
        }
        {
            var line: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&line, "stage 13b sizes: history replay {d} bytes, coalesced delta {d} bytes", .{ hist_len, co.len }) catch unreachable;
            say(msg);
        }
        // The rebuilt rows kept their ids across both phases.
        cl.resetSem();
        cl.snapshot(@intFromEnum(proto.SnapMode.full), 1);
        const again = cl.idOfLine("\"Alpha row one\"") orelse fail("stage 13b churn: the row vanished");
        if (again != row_id) fail("stage 13b churn: a re-rendered identical row lost its stable id");
    }
    pass("stage 13b churn coalescing (one delta, stable ids, history opt-in replays)");

    // ── Stage 14: a hostile page cannot forge or hijack ────────────
    {
        cl.navigate(attack_page);
        if (!cl.waitTitle("attack ", 15_000)) fail("stage 14 hostile page: the page never reported its attempts");
        const report = cl.titleSlice();
        const want = [_][]const u8{
            "early:hit=0 posted=0 slots=1 ovr=0",
            "late:hit=0 posted=0 slots=1 ovr=0",
        };
        for (want) |needle| {
            if (std.mem.indexOf(u8, report, needle) == null) {
                std.debug.print("smoke-web: the page reported \"{s}\"\n", .{report});
                fail("stage 14 hostile page: the page reached something it must not");
            }
        }
        // The true tree must still come back, with nothing of the page's
        // forgery in it.
        cl.resetSem();
        cl.snapshot(1, 1);
        if (!cl.waitSem("REALCONTENT", 20_000)) {
            std.debug.print("smoke-web: snapshot was:\n{s}\n", .{cl.semLog()});
            fail("stage 14 hostile page: the real DOM did not come back");
        }
        if (std.mem.indexOf(u8, cl.semLog(), "FORGEDMARKER") != null or
            std.mem.indexOf(u8, cl.semLog(), "about:forged") != null)
        {
            std.debug.print("smoke-web: snapshot was:\n{s}\n", .{cl.semLog()});
            fail("stage 14 hostile page: a forged reply reached the client");
        }
        // ... and the helper is still answering.
        const seq = cl.md_seq;
        cl.send(proto.SemRead{ .view = view_id });
        if (!cl.waitSeq(&cl.md_seq, seq, 20_000)) fail("stage 14 hostile page: the helper stopped answering");
        if (std.mem.indexOf(u8, cl.md[0..cl.md_len], "Attack Page") == null) {
            fail("stage 14 hostile page: sem_read did not return the real page");
        }
    }
    pass("stage 14 hostile page (no transport, no forgery, no hijack)");

    // ── Stage 15: sem_eval ─────────────────────────────────────────
    //
    // The escape hatch, and the one tool whose whole value is that it
    // degrades instead of failing: undefined, a cycle and a throw all
    // have to come back as something a caller can read, and a DOM
    // element has to come back addressable by web_act.
    {
        cl.navigate(form_page);
        cl.resetSem();
        cl.snapshot(1, 1);
        if (!cl.waitSem("button \"Go\"", 20_000)) fail("stage 15 eval: no full snapshot");
        const go_sid = cl.idOfLine("button \"Go\"") orelse fail("stage 15 eval: no id for the button");

        if (std.mem.indexOf(u8, cl.evalWait("1+1", false, 20_000), "\"value\":2") == null) {
            std.debug.print("smoke-web: eval said {s}\n", .{cl.evalPayload()});
            fail("stage 15 eval: a plain value did not come back");
        }
        if (cl.eval_ok != 1) fail("stage 15 eval: a plain value reported failure");

        // A DOM element serializes to the STABLE id, so the result can
        // be fed straight back into sem_act.
        {
            const json = cl.evalWait("document.getElementById('go')", false, 20_000);
            var want: [64]u8 = undefined;
            const needle = std.fmt.bufPrint(&want, "\"semantic_id\":{d}", .{go_sid}) catch unreachable;
            if (std.mem.indexOf(u8, json, needle) == null or
                std.mem.indexOf(u8, json, "\"role\":\"button\"") == null)
            {
                std.debug.print("smoke-web: eval said {s}\n", .{json});
                fail("stage 15 eval: a DOM node did not serialize to its semantic id");
            }
        }

        if (std.mem.indexOf(u8, cl.evalWait("undefined", false, 20_000), "\"__kind\":\"undefined\"") == null)
            fail("stage 15 eval: undefined did not degrade to a placeholder");
        if (std.mem.indexOf(u8, cl.evalWait("(function(){var a={};a.me=a;return a})()", false, 20_000), "\"__kind\":\"cyclic\"") == null)
            fail("stage 15 eval: a cycle did not degrade to a placeholder");
        {
            const json = cl.evalWait("throw new TypeError('boom')", false, 20_000);
            if (cl.eval_ok != 0) fail("stage 15 eval: a throw was reported as success");
            if (std.mem.indexOf(u8, json, "boom") == null or std.mem.indexOf(u8, json, "\"stack\"") == null) {
                std.debug.print("smoke-web: eval said {s}\n", .{json});
                fail("stage 15 eval: the exception lost its message or stack");
            }
        }
        {
            const json = cl.evalWait(
                "new Promise(function(r){setTimeout(function(){r(42)},50)})",
                true,
                20_000,
            );
            if (std.mem.indexOf(u8, json, "\"value\":42") == null) {
                std.debug.print("smoke-web: eval said {s}\n", .{json});
                fail("stage 15 eval: await did not resolve the promise");
            }
        }
    }
    pass("stage 15 sem_eval (values, DOM refs, degradation, throw, await)");

    // ── Stage 16: dropdowns, native AND custom ─────────────────────
    //
    // browser_choose used to be a tool of its own for exactly this;
    // set_value has to cover both or that capability was dropped.
    {
        cl.navigate(dropdown_page);
        cl.resetSem();
        cl.snapshot(1, 1);
        if (!cl.waitSem("combobox \"Country\"", 20_000)) {
            std.debug.print("smoke-web: snapshot was:\n{s}\n", .{cl.semLog()});
            fail("stage 16 dropdown: no snapshot of the dropdown page");
        }
        const native_id = cl.idOfLine("combobox \"Country\"") orelse
            fail("stage 16 dropdown: no id for the native select");
        const combo_id = cl.idOfLine("combobox \"Pick a fruit\"") orelse {
            std.debug.print("smoke-web: snapshot was:\n{s}\n", .{cl.semLog()});
            fail("stage 16 dropdown: no id for the custom combobox");
        };

        // Native <select>, chosen by option TEXT (not value).
        cl.resetTitle();
        {
            const seq = cl.act_seq;
            cl.send(proto.SemAction{
                .view = view_id,
                .id = native_id,
                .action = @intFromEnum(proto.SemAct.set_value),
                .arg = "Netherlands",
            });
            if (!cl.waitSeq(&cl.act_seq, seq, 20_000)) fail("stage 16 dropdown: no result for the native select");
            if (cl.act_ok != 1) {
                std.debug.print("smoke-web: act said \"{s}\"\n", .{cl.act_msg[0..cl.act_msg_len]});
                fail("stage 16 dropdown: the native select was not set");
            }
        }
        if (!cl.waitTitle("native:nl", 15_000)) {
            std.debug.print("smoke-web: title was \"{s}\"\n", .{cl.titleSlice()});
            fail("stage 16 dropdown: the native select fired no change event for the matching option");
        }

        // Custom ARIA dropdown: opened with a trusted click, its
        // option polled for, then clicked — also trusted. The page
        // reports UNTRUSTED/UNTRUSTEDOPT in its title if either was
        // scripted.
        cl.resetTitle();
        {
            const seq = cl.act_seq;
            cl.send(proto.SemAction{
                .view = view_id,
                .id = combo_id,
                .action = @intFromEnum(proto.SemAct.set_value),
                .arg = "Cherry",
            });
            if (!cl.waitSeq(&cl.act_seq, seq, 20_000)) fail("stage 16 dropdown: no result for the custom dropdown");
            const msg = cl.act_msg[0..cl.act_msg_len];
            if (cl.act_ok != 1 or std.mem.indexOf(u8, msg, "Cherry") == null) {
                std.debug.print("smoke-web: act said \"{s}\"\n", .{msg});
                fail("stage 16 dropdown: the custom dropdown did not report the picked option");
            }
        }
        if (!cl.waitTitle("picked:Cherry", 15_000)) {
            std.debug.print("smoke-web: title was \"{s}\"\n", .{cl.titleSlice()});
            fail("stage 16 dropdown: the custom option was never clicked (or the click was not trusted)");
        }
    }
    pass("stage 16 dropdowns (native select by text, custom ARIA listbox, both trusted)");

    // ── Stage 17: form validation state in the walk ────────────────
    //
    // What browser_form_state used to answer, now carried by every
    // snapshot: required/invalid/checked/disabled and the value —
    // with a password reported as a LENGTH, never its content.
    {
        cl.navigate(validation_page);
        cl.resetSem();
        cl.snapshot(1, 1);
        if (!cl.waitSem("textbox \"Email\"", 20_000)) {
            std.debug.print("smoke-web: snapshot was:\n{s}\n", .{cl.semLog()});
            fail("stage 17 form state: no snapshot of the validation page");
        }
        const log = cl.semLog();
        const email = lineContaining(log, "textbox \"Email\"") orelse fail("stage 17 form state: no email line");
        if (std.mem.indexOf(u8, email, "required") == null or std.mem.indexOf(u8, email, "invalid") == null) {
            std.debug.print("smoke-web: email line was: {s}\n", .{email});
            fail("stage 17 form state: required/invalid are missing from the states");
        }
        const box = lineContaining(log, "checkbox \"Terms\"") orelse fail("stage 17 form state: no checkbox line");
        if (std.mem.indexOf(u8, box, "checked") == null) fail("stage 17 form state: the checkbox is not reported checked");
        const btn = lineContaining(log, "button \"Submit\"") orelse fail("stage 17 form state: no button line");
        if (std.mem.indexOf(u8, btn, "disabled") == null) fail("stage 17 form state: the disabled button is not reported disabled");
        const pw = lineContaining(log, "textbox \"Password\"") orelse fail("stage 17 form state: no password line");
        if (std.mem.indexOf(u8, pw, "hunter22") != null) fail("stage 17 form state: a password VALUE reached the client");
        if (std.mem.indexOf(u8, pw, "(8 chars)") == null) {
            std.debug.print("smoke-web: password line was: {s}\n", .{pw});
            fail("stage 17 form state: the password length is not reported");
        }
    }
    pass("stage 17 form validation state (required/invalid/checked/disabled, masked password)");

    // ── Stage 18: HiDPI — physical buffer, logical input ────────────
    //
    // The scale contract in docs/proposal-browser-protocol.md: w/h on
    // the wire stay LOGICAL, the announced buffer is
    // ceil(logical * scale), and the ENGINE must actually paint into
    // all of it. v1 pinned the scale to 1000 precisely because a
    // mismatched paint size made the helper drop every paint, so a
    // solid-colour page has to fill the far corner, not just the
    // logical-sized top-left quadrant.
    {
        const old_buf = cl.fb.?.buf_id;
        var seq = cl.fb_seq;
        cl.send(proto.ViewResize{ .view = view_id, .w = 400, .h = 300, .scale_x1000 = 2000 });
        if (!cl.waitBufferAfter(seq, 20_000)) fail("stage 18 hidpi: no frame_buffer for scale 2");
        {
            const fb = cl.fb.?;
            if (fb.w != 800 or fb.h != 600) fail("stage 18 hidpi: 400x300 at 2x did not announce an 800x600 buffer");
            if (fb.stride != 3200) fail("stage 18 hidpi: stride is not the physical width times 4");
        }
        cl.send(proto.FrameRelease{ .view = view_id, .buf_id = old_buf });

        cl.navigate(blue_page);
        if (!cl.waitCenterColor(.{ 255, 0, 0 }, 20_000)) fail("stage 18 hidpi: the page never painted at 2x");
        {
            const fb = cl.fb.?;
            cl.mapBuffer();
            const far = cl.pixel(fb.w - 1, fb.h - 1);
            if (far[0] < 200 or far[1] > 64 or far[2] > 64) {
                std.debug.print("smoke-web: far pixel was {any}\n", .{far});
                fail("stage 18 hidpi: the paint did not cover the whole physical buffer");
            }
        }

        // Input stays LOGICAL: a click at the logical centre must reach
        // the page as clientX/clientY 200,150 — physical coordinates
        // would land at 100,75.
        cl.navigate(click_page);
        if (!cl.waitCenterColor(.{ 255, 0, 0 }, 20_000)) fail("stage 18 hidpi: the click page never painted");
        cl.send(proto.InputFocus{ .view = view_id, .focused = 1 });
        cl.resetTitle();
        for ([_]proto.PointerKind{ .move, .down, .up }) |kind| {
            cl.send(proto.InputPointer{
                .view = view_id,
                .kind = @intFromEnum(kind),
                .x = 200,
                .y = 150,
                .button = 0,
                .clicks = if (kind == .move) 0 else 1,
                .mods = 0,
            });
        }
        if (!cl.waitTitle("result:trusted=true x=200 y=150", 15_000)) {
            std.debug.print("smoke-web: title was \"{s}\"\n", .{cl.titleSlice()});
            fail("stage 18 hidpi: input coordinates are not logical at 2x");
        }

        // A fractional scale (KWin/GNOME both do 1.5) rounds UP.
        seq = cl.fb_seq;
        cl.send(proto.ViewResize{ .view = view_id, .w = 101, .h = 100, .scale_x1000 = 1500 });
        if (!cl.waitBufferAfter(seq, 20_000)) fail("stage 18 hidpi: no frame_buffer for scale 1.5");
        {
            const fb = cl.fb.?;
            if (fb.w != 152 or fb.h != 150) fail("stage 18 hidpi: 101x100 at 1.5x is not a 152x150 buffer");
        }

        // ... and back down to 1x, which is a scale change in the other
        // direction and must shrink the buffer again.
        seq = cl.fb_seq;
        cl.send(proto.ViewResize{ .view = view_id, .w = 640, .h = 480, .scale_x1000 = 1000 });
        if (!cl.waitBufferAfter(seq, 20_000)) fail("stage 18 hidpi: no frame_buffer back at 1x");
        if (cl.fb.?.w != 640 or cl.fb.?.h != 480) fail("stage 18 hidpi: the 1x buffer is not 640x480");
        pass("stage 18 hidpi (physical buffer, logical input, fractional scale)");
    }

    // ── Stage 19: paints above the old 60fps ceiling ───────────────
    //
    // CEF's windowless scheduler clamps `windowless_frame_rate` at 60,
    // which is what external begin frames replace. Driving requests
    // faster than that has to produce paints faster than that, or the
    // whole change bought nothing.
    {
        cl.navigate(anim_page);
        _ = cl.drive(500, 240); // let the animation get going
        const hot = cl.drive(2000, 240);
        const req_fps = @divTrunc(@as(i64, hot.requests) * 1000, @max(hot.ms, 1));
        const paint_fps = @divTrunc(@as(i64, hot.paints) * 1000, @max(hot.ms, 1));
        std.debug.print(
            "smoke-web: MEASURED uncapped: {d} begin-frames ({d}/s), {d} paints ({d}/s) over {d} ms\n",
            .{ hot.requests, req_fps, hot.paints, paint_fps, hot.ms },
        );
        if (req_fps <= 60) fail("stage 19 fps: the rig itself never drove above 60 begin-frames/s");
        if (paint_fps <= 65) fail("stage 19 fps: paints did not exceed the old 60fps windowless ceiling");

        // ... and the cap is honoured: `view_max_fps 30` must hold the
        // engine's scheduler to ~30 paints/s however hard the client
        // drives requests.
        cl.send(proto.ViewMaxFps{ .view = view_id, .fps = 30 });
        _ = cl.drive(300, 240); // let the new rate land
        const capped = cl.drive(2000, 240);
        const cap_fps = @divTrunc(@as(i64, capped.paints) * 1000, @max(capped.ms, 1));
        std.debug.print(
            "smoke-web: MEASURED capped at 30: {d} begin-frames, {d} paints ({d}/s) over {d} ms\n",
            .{ capped.requests, capped.paints, cap_fps, capped.ms },
        );
        if (cap_fps < 20 or cap_fps > 40) fail("stage 19 fps: view_max_fps 30 did not produce ~30 paints/s");
        cl.send(proto.ViewMaxFps{ .view = view_id, .fps = 0 });
    }
    pass("stage 19 frame rate (above 60fps uncapped, ~30fps under view_max_fps 30)");

    // ── Stage 20: an idle page paints nothing ──────────────────────
    //
    // The other half of the deal: asking for frames is not the same as
    // producing them, so a page with nothing to show must cost zero
    // paints no matter how hard it is driven.
    {
        cl.navigate(static_page);
        _ = cl.drive(1000, 120); // let the load's own paints finish
        const quiet = cl.drive(3000, 120);
        std.debug.print(
            "smoke-web: MEASURED static page: {d} begin-frames, {d} paints over {d} ms\n",
            .{ quiet.requests, quiet.paints, quiet.ms },
        );
        if (quiet.requests < 200) fail("stage 20 idle: the rig did not actually drive frames");
        if (quiet.paints != 0) fail("stage 20 idle: a static page painted while nothing changed");
    }
    pass("stage 20 idle page (hundreds of begin-frames, zero paints)");

    // ── Stage 21: no client, page still alive — and boundable ──────
    //
    // Under the internal-scheduler default a client that stops asking
    // costs nothing: the engine paces itself. The page must stay alive
    // with ZERO requests, and `view_max_fps` must still bound it — the
    // lever the GUI would use on a view it cannot present.
    {
        cl.navigate(anim_page);
        _ = cl.drive(300, 120);
        const abandoned = cl.drive(1500, 0);
        std.debug.print(
            "smoke-web: MEASURED unattended: {d} paints in {d} ms with ZERO client requests\n",
            .{ abandoned.paints, abandoned.ms },
        );
        if (abandoned.requests != 0) fail("stage 21 unattended: the rig kept asking for frames");
        if (abandoned.paints == 0) fail("stage 21 unattended: the page froze once the client stopped asking");
        cl.send(proto.ViewMaxFps{ .view = view_id, .fps = 5 });
        _ = cl.drive(300, 0);
        const floored = cl.drive(1500, 0);
        std.debug.print(
            "smoke-web: MEASURED floored at 5: {d} paints in {d} ms\n",
            .{ floored.paints, floored.ms },
        );
        if (floored.paints > 15) fail("stage 21 unattended: view_max_fps 5 did not bound an unattended page");
        cl.send(proto.ViewMaxFps{ .view = view_id, .fps = 0 });
    }
    pass("stage 21 unattended (page alive with no client, bounded by view_max_fps)");

    // ── Stage 22: input paints immediately ─────────────────────────
    {
        cl.navigate(click_paint_page);
        _ = cl.drive(700, 120);
        const settled = cl.drive(300, 120);
        if (settled.paints != 0) fail("stage 22 promotion: the probe page was not quiet before the click");

        const before = cl.dmg_seq;
        const t0 = nowMs();
        cl.send(proto.InputFocus{ .view = view_id, .focused = 1 });
        cl.clickCenter();
        var latency: i64 = -1;
        while (nowMs() - t0 < 2000) {
            cl.frameRequest(8_000);
            _ = cl.pumpRaw(1);
            if (cl.dmg_seq > before) {
                latency = nowMs() - t0;
                break;
            }
        }
        if (latency < 0) fail("stage 22 promotion: a click on a static page produced no paint");
        std.debug.print("smoke-web: MEASURED click-to-paint latency: {d} ms\n", .{latency});
        if (latency > 150) fail("stage 22 promotion: the paint after a click took more than 150 ms");
    }
    pass("stage 22 input promotion (click paints within a frame or two)");

    // ── Stage 22b: a view created AT a url mints ONE document ──────
    //
    // `view_create` + `navigate` always loads about:blank first, and a
    // client settling on "a url loaded and nothing is in flight" can be
    // answered by that blank document — which is how `web_open` once
    // returned a first snapshot of an empty page. `view_create_url`
    // (capability `view-create-url`) removes the blank document
    // instead of asking every client to see past it.
    {
        if (!cl.ack_view_url) fail("stage 22b: hello_ack lacks the view-create-url capability");
        // View 1 was created blank at stage 2: the contrast this stage
        // exists for has to be REAL, not assumed.
        if (cl.blank_load_seq == 0) fail("stage 22b: no blank load was ever seen (the contrast is not being measured)");
        const blank_before = cl.blank_load_seq;
        const load_before = cl.load_seq;
        cl.resetSem();
        cl.send(proto.ViewCreateUrl{
            .view = url_view_id,
            .w = 400,
            .h = 300,
            .scale_x1000 = 1000,
            .context = 0,
            .url = form_page,
        });
        if (!cl.waitSeq(&cl.load_seq, load_before, 20_000)) fail("stage 22b: the view never finished a load");
        // The FIRST document is the page: doc 1 in the snapshot header.
        // A preceding about:blank would make it doc 2 — the exact shape
        // of the field report this stage guards.
        const seq = cl.sem_seq;
        cl.send(proto.SemSnapshotReq{
            .view = url_view_id,
            .mode = @intFromEnum(proto.SnapMode.full),
            .detail = 1,
            .scope = 0,
        });
        if (!cl.waitSeq(&cl.sem_seq, seq, 20_000)) fail("stage 22b: no sem_snapshot for the created-at-url view");
        if (std.mem.indexOf(u8, cl.semLast(), "button \"Go\"") == null) {
            std.debug.print("smoke-web: snapshot was:\n{s}\n", .{cl.semLast()});
            fail("stage 22b: the first snapshot does not describe the requested page");
        }
        if (!std.mem.startsWith(u8, cl.semLast(), "doc 1 ")) {
            std.debug.print("smoke-web: snapshot header was:\n{s}\n", .{cl.semLast()[0..@min(cl.semLast().len, 80)]});
            fail("stage 22b: the requested page is not the view's FIRST document");
        }
        if (cl.blank_load_seq != blank_before)
            fail("stage 22b: a blank document was loaded anyway");
        cl.send(proto.ViewDestroy{ .view = url_view_id });
    }
    pass("stage 22b view_create_url (one document, never about:blank)");

    // ── Stage 22c: a page with no background of its own ────────────
    //
    // Windowless CEF paints TRANSPARENT unless the browser is given an
    // opaque background_color, and a transparent frame reaches a client
    // as all-zero pixels — a screenshot of a perfectly healthy page,
    // uniformly black. Every other stage here styles its background, so
    // nothing caught it; this one deliberately does not.
    {
        const fbseq = cl.fb_seq;
        cl.send(proto.ViewCreateUrl{
            .view = bare_view_id,
            .w = 400,
            .h = 300,
            .scale_x1000 = 1000,
            .context = 0,
            .url = bare_page,
        });
        if (!cl.waitBufferAfter(fbseq, 20_000)) fail("stage 22c: no frame_buffer for the unstyled view");
        if (!cl.waitCenterColor(.{ 255, 255, 255 }, 20_000)) {
            const px = cl.pixel(cl.fb.?.w / 2, cl.fb.?.h / 2);
            std.debug.print("smoke-web: centre pixel was {any}\n", .{px});
            fail("stage 22c: an unstyled page did not paint on an opaque white canvas");
        }
        cl.send(proto.ViewDestroy{ .view = bare_view_id });
    }
    pass("stage 22c unstyled page (opaque white canvas, not a transparent/black frame)");

    // ── Stage 22d: request interception (content blocking) ─────────
    //
    // A seeded filter (||doubleclick.net^) must block a matching
    // subresource inline in the helper, and the counters + request log
    // must report it. No network is touched: the request is cancelled
    // at on_before_resource_load, before it ever leaves the process.
    {
        if (!cl.ack_intercept) fail("stage 22d: hello_ack lacks the intercept capability");
        cl.navigate(blocked_img_page);
        if (!cl.waitBlocked(1, 20_000)) {
            std.debug.print("smoke-web: intercept status blocked={d} total={d} rules={d}\n", .{ cl.int_blocked, cl.int_total, cl.int_rules });
            fail("stage 22d: the seeded filter did not block the doubleclick.net image");
        }
        if (cl.int_rules == 0) fail("stage 22d: no filter rules were loaded");
        if (!cl.pullLog(0, 15_000)) fail("stage 22d: the request log never answered");
        const log = cl.logSlice();
        if (std.mem.indexOf(u8, log, "doubleclick.net") == null)
            fail("stage 22d: the request log does not mention the blocked url");
        if (std.mem.indexOf(u8, log, "\"blocked\":true") == null)
            fail("stage 22d: the request log does not mark the entry blocked");

        // Disabling blocking for the view must stop new verdicts: reload
        // and the same image is no longer counted as blocked.
        const blocked_before = cl.int_blocked;
        cl.send(proto.InterceptSet{ .view = view_id, .enabled = 0 });
        cl.navigate(blocked_img_page);
        // Give the reload a moment; the counter must NOT climb.
        var i: usize = 0;
        while (i < 40) : (i += 1) {
            cl.send(proto.InterceptStatusReq{ .view = view_id });
            cl.pump(50);
        }
        if (cl.int_enabled != 0) fail("stage 22d: intercept_set(disable) was not reflected in the status");
        if (cl.int_blocked != blocked_before)
            fail("stage 22d: a request was blocked while blocking was disabled");
        // Re-enable so the view is left in the default state.
        cl.send(proto.InterceptSet{ .view = view_id, .enabled = 1 });
    }
    pass("stage 22d request interception (seeded filter blocks, log reports, toggle honoured)");

    // ── Stage 28: cosmetic filtering ───────────────────────────────
    //
    // A `##.smoke-ad` rule loaded through `intercept_lists` must hide
    // the matching element (display:none via the injected sheet) and
    // leave its sibling alone; the per-view shield toggle must gate
    // the hiding exactly like the network verdicts, and re-enabling
    // must bring it back on the next navigation.
    {
        if (!writeFile(dir, "cos.txt", "! smoke cosmetic list\n##.smoke-ad\n"))
            fail("stage 28: could not write the cosmetic list");
        var list_buf: [96]u8 = undefined;
        const list_path = std.fmt.bufPrint(&list_buf, "{s}/cos.txt", .{dir}) catch
            fail("stage 28: list path");
        const paths = [_][]const u8{list_path};
        cl.send(proto.InterceptLists{ .paths = &paths });

        cl.navigate(cosmetic_page);
        const hidden = cl.evalWait(
            "getComputedStyle(document.querySelector('.smoke-ad')).display",
            false,
            20_000,
        );
        if (std.mem.indexOf(u8, hidden, "\"value\":\"none\"") == null) {
            std.debug.print("smoke-web: eval said {s}\n", .{hidden});
            fail("stage 28: the cosmetic rule did not hide the matching element");
        }
        const kept = cl.evalWait(
            "getComputedStyle(document.getElementById('keep')).display",
            false,
            20_000,
        );
        if (std.mem.indexOf(u8, kept, "\"value\":\"block\"") == null) {
            std.debug.print("smoke-web: eval said {s}\n", .{kept});
            fail("stage 28: an unmatched element was hidden too");
        }

        // Shield off for the view = no cosmetic hiding either.
        cl.send(proto.InterceptSet{ .view = view_id, .enabled = 0 });
        cl.navigate(cosmetic_page);
        const shown = cl.evalWait(
            "getComputedStyle(document.querySelector('.smoke-ad')).display",
            false,
            20_000,
        );
        if (std.mem.indexOf(u8, shown, "\"value\":\"block\"") == null) {
            std.debug.print("smoke-web: eval said {s}\n", .{shown});
            fail("stage 28: the shield toggle did not disable cosmetic hiding");
        }
        cl.send(proto.InterceptSet{ .view = view_id, .enabled = 1 });
        cl.navigate(cosmetic_page);
        const rehidden = cl.evalWait(
            "getComputedStyle(document.querySelector('.smoke-ad')).display",
            false,
            20_000,
        );
        if (std.mem.indexOf(u8, rehidden, "\"value\":\"none\"") == null)
            fail("stage 28: re-enabling the shield did not restore cosmetic hiding");
    }
    pass("stage 28 cosmetic filtering (rule hides, sibling kept, shield gates)");

    // ── Stage 29: userscripts ──────────────────────────────────────
    //
    // A document-end userscript pushed via `us_script_set` must run on
    // a matching page and mutate the DOM; an empty replace-all set
    // must clear it so the next navigation runs nothing.
    {
        if (!cl.ack_userscripts) fail("stage 29: hello_ack lacks the userscripts capability");
        const scripts = [_]proto.UsScript{.{ .id = 1, .source = .{ .s = usc_source } }};
        cl.send(proto.UsScriptSet{ .scripts = &scripts });
        cl.navigate(usc_page_a);
        const marked = cl.evalWait(
            "(document.getElementById('usmark')||{}).textContent+'/'+document.title",
            false,
            20_000,
        );
        if (std.mem.indexOf(u8, marked, "FROM-USERSCRIPT/us-end-ok") == null) {
            std.debug.print("smoke-web: eval said {s}\n", .{marked});
            fail("stage 29: the document-end userscript did not mutate the DOM");
        }

        cl.send(proto.UsScriptSet{ .scripts = &.{} });
        cl.navigate(usc_page_a);
        const cleared = cl.evalWait("!!document.getElementById('usmark')", false, 20_000);
        if (std.mem.indexOf(u8, cleared, "\"value\":false") == null) {
            std.debug.print("smoke-web: eval said {s}\n", .{cleared});
            fail("stage 29: an empty replace-all set did not clear the userscript");
        }
    }
    pass("stage 29 userscripts (document-end DOM mutation, replace-all clears)");

    // ── Stage 30: userstyles ───────────────────────────────────────
    //
    // A pushed userstyle must apply INSTANTLY to the live page (no
    // reload), still be there after a navigation, and disappear from
    // the live page when the set is cleared.
    {
        const styles = [_]proto.UsStyle{.{
            .id = 1,
            .host = "",
            .css = .{ .s = "body{background-color:rgb(1,2,3) !important}" },
        }};
        cl.send(proto.UsStyleSet{ .styles = &styles });
        // No navigation between push and check: this asserts the
        // instant-apply path.
        const live = cl.evalWait(
            "getComputedStyle(document.body).backgroundColor",
            false,
            20_000,
        );
        if (std.mem.indexOf(u8, live, "rgb(1, 2, 3)") == null) {
            std.debug.print("smoke-web: eval said {s}\n", .{live});
            fail("stage 30: the userstyle did not apply to the live page");
        }

        cl.navigate(usc_page_b);
        const after_nav = cl.evalWait(
            "getComputedStyle(document.body).backgroundColor",
            false,
            20_000,
        );
        if (std.mem.indexOf(u8, after_nav, "rgb(1, 2, 3)") == null) {
            std.debug.print("smoke-web: eval said {s}\n", .{after_nav});
            fail("stage 30: the userstyle did not survive a navigation");
        }

        cl.send(proto.UsStyleSet{ .styles = &.{} });
        const gone = cl.evalWait(
            "getComputedStyle(document.body).backgroundColor",
            false,
            20_000,
        );
        if (std.mem.indexOf(u8, gone, "rgb(1, 2, 3)") != null) {
            std.debug.print("smoke-web: eval said {s}\n", .{gone});
            fail("stage 30: clearing the set did not remove the live style");
        }
    }
    pass("stage 30 userstyles (instant apply, survives navigation, clear removes)");
    // ── Stage 22e: discard destroys the browser, show brings it back ─
    //
    // `view_hide` only pauses the painting; `view_discard` (capability
    // `discard`) destroys the BROWSER and keeps the view record. The
    // properties that matter to a client are all checked here: the id
    // survives, a semantic request against a discarded view is ANSWERED
    // rather than left hanging, and the next `view_show` produces a
    // fresh frame buffer plus the same page again.
    {
        if (!cl.ack_discard) fail("stage 22e: hello_ack lacks the discard capability");
        cl.resetTitle();
        const fb_before = cl.fb_seq;
        cl.send(proto.ViewCreateUrl{
            .view = discard_view_id,
            .w = 400,
            .h = 300,
            .scale_x1000 = 1000,
            .context = 0,
            .url = discard_page,
        });
        if (!cl.waitBufferAfter(fb_before, 20_000)) fail("stage 22e: no frame_buffer for the new view");
        if (!cl.waitTitle("discard-me", 20_000)) fail("stage 22e: the page never reported its title");
        if (!cl.waitCenterColor(.{ 0, 255, 0 }, 20_000)) fail("stage 22e: the page never painted green");

        const fb_at_discard = cl.fb_seq;
        cl.send(proto.ViewHide{ .view = discard_view_id });
        cl.send(proto.ViewDiscard{ .view = discard_view_id });

        // A semantic request now has no page to reach. The helper must
        // still answer it: a silent drop is a client-side timeout, and
        // this rig would sit out the whole 20s below rather than fail
        // in one line.
        cl.resetSem();
        const sem_before = cl.sem_seq;
        cl.send(proto.SemSnapshotReq{
            .view = discard_view_id,
            .mode = @intFromEnum(proto.SnapMode.full),
            .detail = 1,
            .scope = 0,
        });
        if (!cl.waitSeq(&cl.sem_seq, sem_before, 20_000))
            fail("stage 22e: a discarded view never answered a snapshot request (it must not hang)");
        if (std.mem.indexOf(u8, cl.semLast(), "discarded") == null) {
            std.debug.print("smoke-web: snapshot of a discarded view was:\n{s}\n", .{cl.semLast()});
            fail("stage 22e: the discarded view's answer does not say it is discarded");
        }
        // Nothing may paint for a view with no browser.
        if (cl.fb_seq != fb_at_discard) fail("stage 22e: a discarded view announced a new buffer");

        // The revival: SAME view id, no re-create, no re-navigate.
        cl.resetTitle();
        cl.send(proto.ViewShow{ .view = discard_view_id });
        if (!cl.waitBufferAfter(fb_at_discard, 20_000))
            fail("stage 22e: showing a discarded view produced no fresh frame buffer");
        if (!cl.waitTitle("discard-me", 20_000))
            fail("stage 22e: the revived view did not load the url it was discarded holding");
        if (!cl.waitCenterColor(.{ 0, 255, 0 }, 20_000))
            fail("stage 22e: the revived view never repainted the page");
        cl.send(proto.ViewDestroy{ .view = discard_view_id });
    }
    pass("stage 22e view_discard (browser destroyed, answered while discarded, revived on show)");

    // ── Stage 22f: a bad certificate is HELD, not failed ───────────
    //
    // A real TLS server with a self-signed certificate, on loopback:
    // the only honest way to exercise `on_certificate_error`, since
    // nothing about a held request can be simulated from this side.
    // The whole stage SKIPS (never fails) when the host has no
    // `openssl`, because the rig must stay runnable without one.
    certStage(&cl, dir);
    // ── Stage 22d: print the page to a PDF file ────────────────────
    //
    // The helper writes the file itself (it is the process with the
    // page), so the assertion is on BYTES ON DISK, not on a reply: a
    // done event for a file that never appeared would be the whole bug
    // this stage exists to catch.
    {
        if (!cl.ack_print_pdf) fail("stage 22h print_pdf: hello_ack lacks the print-pdf capability");
        cl.navigate(article_page);
        var pdf_buf: [128]u8 = undefined;
        const pdf = std.fmt.bufPrintZ(&pdf_buf, "{s}/page.pdf", .{dir}) catch fail("pdf path");
        const seq = cl.print_seq;
        cl.send(proto.PrintPdf{
            .view = view_id,
            .flags = proto.print_flag_background,
            .paper = @intFromEnum(proto.Paper.a4),
            .path = pdf,
        });
        if (!cl.waitSeq(&cl.print_seq, seq, 30_000)) fail("stage 22h print_pdf: no ev_print_pdf_done");
        if (cl.print_ok != 1) fail("stage 22h print_pdf: the helper reported a failure");
        if (!std.mem.eql(u8, cl.print_path[0..cl.print_path_len], pdf))
            fail("stage 22h print_pdf: the done event echoed a different path");

        const f = c.fopen(pdf.ptr, "rb") orelse fail("stage 22h print_pdf: no file at the requested path");
        defer _ = c.fclose(f);
        var head: [5]u8 = @splat(0);
        const n = c.fread(&head, 1, head.len, f);
        if (n != head.len or !std.mem.eql(u8, &head, "%PDF-"))
            fail("stage 22h print_pdf: the file does not start with a PDF magic header");
        _ = c.fseek(f, 0, c.SEEK_END);
        const size = c.ftell(f);
        if (size < 1000) fail("stage 22h print_pdf: the PDF is too small to hold a rendered page");
        std.debug.print("smoke-web: MEASURED pdf {d} bytes\n", .{size});

        // A path nothing can write must come back as a FAILED print,
        // not as silence: a client waiting on a save would hang.
        const bad_seq = cl.print_seq;
        cl.send(proto.PrintPdf{
            .view = view_id,
            .flags = 0,
            .paper = 0,
            .path = "/proc/sketerm-no-such-dir/x.pdf",
        });
        if (!cl.waitSeq(&cl.print_seq, bad_seq, 30_000))
            fail("stage 22h print_pdf: an unwritable path produced no answer at all");
        if (cl.print_ok != 0) fail("stage 22h print_pdf: an unwritable path was reported as success");

        // A view that does not exist is answered too, for the same
        // reason.
        const gone_seq = cl.print_seq;
        cl.send(proto.PrintPdf{ .view = 9999, .flags = 0, .paper = 0, .path = pdf });
        if (!cl.waitSeq(&cl.print_seq, gone_seq, 10_000))
            fail("stage 22h print_pdf: an unknown view produced no answer at all");
        if (cl.print_ok != 0) fail("stage 22h print_pdf: an unknown view was reported as success");
    }
    pass("stage 22h print_pdf (real PDF on disk, failures answered)");

    // ── Stage 22e: DevTools ────────────────────────────────────────
    //
    // `devtools_show` asks for the inspector as ANOTHER WINDOWLESS
    // VIEW: its own id, its own frame buffer, resizable and closable
    // through the frames every view uses, and no debugging PORT
    // anywhere. Whether the engine can do that is the engine's answer,
    // and BOTH answers are asserted here, because both are shipped
    // behaviour:
    //
    //   - a view id  -> it must really paint, resize and close;
    //   - `devtools = 0` + reason `windowed` -> the inspector is open
    //     in a window the ENGINE made (CEF 151 always lands here; see
    //     cefhost.adoptBrowser for the measurement).
    //
    // Either way the client is ANSWERED, which is the property that
    // keeps a GUI from waiting forever on a menu item.
    {
        if (!cl.ack_devtools) fail("stage 22i devtools: hello_ack lacks the devtools capability");
        cl.navigate(form_page);
        const seq = cl.dev_reply_seq;
        cl.send(proto.DevToolsShow{ .view = view_id, .x = 0, .y = 0 });
        if (!cl.waitSeq(&cl.dev_reply_seq, seq, 30_000)) fail("stage 22i devtools: no ev_devtools_view");

        if (cl.dev_view == 0) {
            const why = cl.dev_reason[0..cl.dev_reason_len];
            if (!std.mem.eql(u8, why, "windowed")) {
                std.debug.print("smoke-web: devtools refused with reason \"{s}\"\n", .{why});
                fail("stage 22i devtools: the helper opened no inspector at all");
            }
            std.debug.print(
                "smoke-web: MEASURED devtools: engine refused windowless rendering, inspector opened in its own window\n",
                .{},
            );
            // The refusal must not have taken the inspected view with
            // it, and asking again must still be answered.
            const again = cl.dev_reply_seq;
            cl.send(proto.DevToolsShow{ .view = view_id, .x = 0, .y = 0 });
            if (!cl.waitSeq(&cl.dev_reply_seq, again, 20_000))
                fail("stage 22i devtools: a second request went unanswered");
            const dmg = cl.dmg_seq;
            cl.navigate(blue_page);
            if (!cl.waitDamageAfter(dmg, 20_000)) fail("stage 22i devtools: the inspected view stopped painting");
            pass("stage 22i devtools (engine window fallback, answered and non-destructive)");
        } else {
            if (cl.dev_view < proto.DEVTOOLS_VIEW_BASE)
                fail("stage 22i devtools: the inspector id is inside the client-allocated range");

            // It paints. The id must arrive BEFORE the buffer (a client
            // cannot place a frame for a view it has not been told
            // about), and pixels must follow.
            if (!cl.waitSeq(&cl.dev_fb_seq, 0, 30_000)) fail("stage 22i devtools: no frame_buffer for the inspector");
            if (!cl.waitSeq(&cl.dev_dmg_seq, 0, 30_000)) fail("stage 22i devtools: the inspector never painted");
            {
                const fb = cl.dev_fb.?;
                const size: usize = @as(usize, fb.stride) * @as(usize, fb.h);
                const addr = c.mmap(null, size, c.PROT_READ, c.MAP_SHARED, cl.dev_fb_fd, 0);
                if (addr == c.MAP_FAILED) fail("stage 22i devtools: the inspector buffer will not map");
                const bytes: [*]const u8 = @ptrCast(addr);
                var nonzero: usize = 0;
                var i: usize = 0;
                while (i < size) : (i += 997) {
                    if (bytes[i] != 0) nonzero += 1;
                }
                _ = c.munmap(@constCast(@ptrCast(bytes)), size);
                if (nonzero == 0) fail("stage 22i devtools: the inspector's frame is entirely blank");
            }

            // Resizing it is the ordinary view frame, with the ordinary
            // replacement buffer.
            {
                const fbseq = cl.dev_fb_seq;
                cl.send(proto.ViewResize{ .view = cl.dev_view, .w = 500, .h = 400, .scale_x1000 = 1000 });
                if (!cl.waitSeq(&cl.dev_fb_seq, fbseq, 20_000))
                    fail("stage 22i devtools: resizing the inspector announced no new buffer");
                const fb = cl.dev_fb.?;
                if (fb.w != 500 or fb.h != 400) fail("stage 22i devtools: the inspector buffer is not the requested size");
            }

            // Asking again while it is open hands back the SAME view
            // rather than a second inspector for one page.
            {
                const again = cl.dev_reply_seq;
                const first = cl.dev_view;
                cl.send(proto.DevToolsShow{ .view = view_id, .x = 0, .y = 0 });
                if (!cl.waitSeq(&cl.dev_reply_seq, again, 20_000)) fail("stage 22i devtools: no answer to a second request");
                if (cl.dev_view != first) fail("stage 22i devtools: a second request opened another inspector");
            }

            cl.send(proto.ViewDestroy{ .view = cl.dev_view });
            cl.dev_view = 0;
            // Closing the inspector must not take its target down.
            {
                const dmg = cl.dmg_seq;
                cl.navigate(blue_page);
                if (!cl.waitDamageAfter(dmg, 20_000)) fail("stage 22i devtools: the inspected view stopped painting");
            }
            pass("stage 22i devtools (inspector view: paints, resizes, deduplicates, closes)");
        }

        // A request for a view that does not exist is refused, not
        // ignored — the same "always answer" property, on the path
        // where nothing can be opened at all.
        {
            const bad = cl.dev_reply_seq;
            cl.send(proto.DevToolsShow{ .view = 9999, .x = 0, .y = 0 });
            if (!cl.waitSeq(&cl.dev_reply_seq, bad, 10_000))
                fail("stage 22i devtools: an unknown view produced no answer at all");
            if (cl.dev_view != 0) fail("stage 22i devtools: an unknown view was answered with an inspector");
        }
    }

    // ── Stage 22j: downloads ───────────────────────────────────────
    //
    // The offer is HELD (the engine decides no target until the client
    // answers), a decided path lands the exact bytes on disk with a
    // terminal `done` progress frame, and a decide-with-empty-path
    // cancels with a terminal `failed` frame — the "always answered"
    // property every held decision on this wire keeps.
    {
        if (!cl.ack_downloads) fail("stage 22j downloads: hello_ack lacks the downloads capability");

        // -- accept ----------------------------------------------------
        cl.navigate(download_page);
        const offer0 = cl.dl_offer_seq;
        cl.clickCenter();
        if (!cl.waitSeq(&cl.dl_offer_seq, offer0, 20_000))
            fail("stage 22j downloads: a clicked download anchor produced no ev_download_offer");
        if (cl.dl_view != view_id) fail("stage 22j downloads: the offer named the wrong view");
        if (!std.mem.eql(u8, cl.dl_name[0..cl.dl_name_len], "dl.bin"))
            fail("stage 22j downloads: the offer did not carry the anchor's download name");
        if (!std.mem.startsWith(u8, cl.dl_url[0..cl.dl_url_len], "data:"))
            fail("stage 22j downloads: the offer did not carry the source url");
        const first_id = cl.dl_id;

        var dl_buf: [128]u8 = undefined;
        const dl_path = std.fmt.bufPrintZ(&dl_buf, "{s}/dl1.bin", .{dir}) catch fail("dl path");
        cl.send(proto.DownloadDecide{ .view = view_id, .id = first_id, .path = dl_path });
        if (!cl.waitDlTerminal(first_id, 30_000))
            fail("stage 22j downloads: no terminal ev_download_progress after deciding a path");
        if (cl.dl_done != 1) fail("stage 22j downloads: the decided download ended failed, not done");
        if (cl.dl_received != download_bytes.len)
            fail("stage 22j downloads: the done frame's received count is not the payload size");

        const f = c.fopen(dl_path.ptr, "rb") orelse fail("stage 22j downloads: no file at the decided path");
        var got: [64]u8 = @splat(0);
        const n = c.fread(&got, 1, got.len, f);
        _ = c.fclose(f);
        if (n != download_bytes.len or !std.mem.eql(u8, got[0..n], download_bytes))
            fail("stage 22j downloads: the file's bytes are not the downloaded payload");

        // -- cancel at the offer ---------------------------------------
        // A fresh document (data: urls have a unique origin each) keeps
        // Chromium's multiple-download gating out of the picture.
        cl.navigate(download_page);
        const offer1 = cl.dl_offer_seq;
        cl.clickCenter();
        if (!cl.waitSeq(&cl.dl_offer_seq, offer1, 20_000))
            fail("stage 22j downloads: no second offer after a reload");
        const second_id = cl.dl_id;
        if (second_id == first_id) fail("stage 22j downloads: the second download reused the first id");
        cl.send(proto.DownloadDecide{ .view = view_id, .id = second_id, .path = "" });
        if (!cl.waitDlTerminal(second_id, 30_000))
            fail("stage 22j downloads: a cancelled decide produced no terminal progress frame");
        if (cl.dl_prog_id == second_id and cl.dl_done != 0)
            fail("stage 22j downloads: a cancelled decide was reported as done");

        // -- unknown ids are ignored, not fatal ------------------------
        cl.send(proto.DownloadCancel{ .view = view_id, .id = 0xdead_beef });
        cl.send(proto.DownloadDecide{ .view = view_id, .id = 0xdead_beef, .path = dl_path });
        const dmg = cl.dmg_seq;
        cl.navigate(blue_page);
        if (!cl.waitDamageAfter(dmg, 20_000))
            fail("stage 22j downloads: the helper stopped serving after unknown-id download frames");
    }
    pass("stage 22j downloads (offer held, decided path lands bytes, cancel answered)");
    // ── Stage 22j: the accessibility tree, only on demand ──────────
    {
        if (!cl.ack_a11y) fail("stage 22k a11y: hello_ack lacks the a11y capability");
        const ax_page = "data:text/html,<html><body style='background:%23fff'>" ++
            "<h1>Axheading</h1><button>Axgo</button>" ++
            "<input type=checkbox checked aria-label=Axcheck>" ++
            "<button disabled>Axoff</button></body></html>";
        cl.navigate(ax_page);
        // Backlog rule: nothing may stream before a11y_enable.
        cl.pump(1_500);
        if (cl.ax_seq != 0) fail("stage 22k a11y: tree events streamed before a11y_enable");
        cl.send(proto.A11yEnable{ .view = view_id, .enabled = 1 });
        const deadline = nowMs() + 20_000;
        while (nowMs() < deadline) {
            const log = cl.ax_log[0..cl.ax_log_len];
            if (std.mem.indexOf(u8, log, "heading \"Axheading\"") != null and
                std.mem.indexOf(u8, log, "button \"Axgo\"") != null and
                std.mem.indexOf(u8, log, "document") != null) break;
            cl.pump(100);
        }
        const log = cl.ax_log[0..cl.ax_log_len];
        if (std.mem.indexOf(u8, log, "heading \"Axheading\"") == null or
            std.mem.indexOf(u8, log, "button \"Axgo\"") == null)
        {
            std.debug.print("smoke-web: ax log was:\n{s}\n", .{log});
            fail("stage 22k a11y: no heading/button nodes in the streamed tree");
        }
        if (std.mem.indexOf(u8, log, "document") == null)
            fail("stage 22k a11y: no document root in the streamed tree");
        // State-bit translation: checkedState -> ax_checked and
        // restriction -> ax_disabled must survive the engine's
        // serializer (these were designed from Chromium's enums; this
        // is the assertion that keeps them true).
        if (axLineState(log, "checkbox \"Axcheck\"")) |st| {
            if (st & proto.ax_checked == 0) fail("stage 22k a11y: checked checkbox lacks the checked bit");
        } else fail("stage 22k a11y: no checkbox node in the streamed tree");
        if (axLineState(log, "button \"Axoff\"")) |st| {
            if (st & proto.ax_disabled == 0) fail("stage 22k a11y: disabled button lacks the disabled bit");
        } else fail("stage 22k a11y: no disabled-button node in the streamed tree");
        // Disable stops the stream: churn the page and expect silence.
        cl.send(proto.A11yEnable{ .view = view_id, .enabled = 0 });
        cl.pump(500);
        const seq_after_off = cl.ax_seq;
        cl.navigate("data:text/html,<html><body style='background:%23fff'><p>quiet</p></body></html>");
        cl.pump(1_500);
        if (cl.ax_seq != seq_after_off)
            fail("stage 22k a11y: tree events kept streaming after disable");
        pass("stage 22k a11y (enable-gated tree, roles+names, disable silences)");
    }

    // ── Stage 28: cookies + site data ─────────────────────────────
    //
    // The whole 0xC8 block against a REAL origin on loopback: a page
    // whose own script stores a cookie, an enumeration that finds it
    // with its scope and flags (and its value's LENGTH, never the
    // value), a clear that removes it, and an enumeration that then
    // finds nothing. The `sitedata` capability gates all of it.
    {
        if (!cl.ack_sitedata) fail("stage 31 site data: hello_ack lacks the sitedata capability");
        var http = HttpProbe{};
        if (!http.start()) fail("stage 31 site data: could not start the loopback http probe");
        defer http.shutdown();
        var url_buf: [64]u8 = undefined;
        const site_url = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{http.port}) catch unreachable;

        cl.send(proto.ViewCreate{
            .view = sitedata_view_id,
            .w = 320,
            .h = 240,
            .scale_x1000 = 1000,
            .context = 0,
        });
        cl.send(proto.Navigate{ .view = sitedata_view_id, .url = site_url });
        // The page's own script writes the cookie and then puts
        // `document.cookie` in the TITLE, so the title is both the
        // settle and the proof the write took: waiting on the shared
        // load counter would be satisfied by another view's load.
        if (!cl.waitTitle("cookie:", 20_000)) {
            std.debug.print(
                "smoke-web: served {d} http requests, last title was \"{s}\"\n",
                .{ http.served.load(.acquire), cl.titleSlice() },
            );
            fail("stage 31 site data: the loopback page never ran its cookie script");
        }
        if (std.mem.indexOf(u8, cl.titleSlice(), cookie_probe) == null) {
            std.debug.print("smoke-web: title was \"{s}\"\n", .{cl.titleSlice()});
            fail("stage 31 site data: the page could not store its own cookie");
        }

        // -- enumerate ------------------------------------------------
        const req_list: u32 = 901;
        const list0 = cl.cookie_seq;
        cl.send(proto.CookiesReq{ .view = sitedata_view_id, .req = req_list, .url = site_url });
        if (!cl.waitSeq(&cl.cookie_seq, list0, 10_000))
            fail("stage 31 site data: no ev_cookies answered the enumeration");
        if (cl.cookie_req != req_list) fail("stage 31 site data: ev_cookies echoed the wrong request id");
        if (cl.cookie_ok == 0) fail("stage 31 site data: the cookie store could not be read");
        const names = cl.cookie_names[0..cl.cookie_names_len];
        if (std.mem.indexOf(u8, names, cookie_probe) == null) {
            std.debug.print("smoke-web: cookies were:\n{s}\n", .{names});
            fail("stage 31 site data: the page's own cookie was not enumerated");
        }
        if (cl.cookie_total == 0) fail("stage 31 site data: a cookie was listed but the total says zero");
        // Metadata, and the value's length INSTEAD of the value.
        if (cl.cookie_value_len != cookie_probe_value.len)
            fail("stage 31 site data: the probe cookie's value length is wrong");
        if (cl.cookie_flags & proto.cookie_session != 0)
            fail("stage 31 site data: a max-age cookie was reported as a session cookie");
        if (cl.cookie_flags & proto.cookie_secure != 0)
            fail("stage 31 site data: a cookie set over http was reported as secure");
        // The VALUE must never appear anywhere in what crossed the wire.
        if (std.mem.indexOf(u8, names, cookie_probe_value) != null)
            fail("stage 31 site data: a cookie VALUE reached the client");

        // -- clear ----------------------------------------------------
        const req_clear: u32 = 902;
        const done_before = cl.site_done_seq;
        cl.send(proto.CookiesClear{ .view = sitedata_view_id, .req = req_clear, .url = site_url });
        if (!cl.waitSeq(&cl.site_done_seq, done_before, 10_000))
            fail("stage 31 site data: no ev_sitedata_done answered the clear");
        if (cl.site_done_req != req_clear) fail("stage 31 site data: ev_sitedata_done echoed the wrong request id");
        if (cl.site_done_ok == 0) fail("stage 31 site data: the clear reported failure");
        if (cl.site_done_kind != @intFromEnum(proto.SitedataKind.cookies_clear))
            fail("stage 31 site data: the clear was answered under the wrong kind");
        if (cl.site_removed == 0) fail("stage 31 site data: the clear removed nothing");

        // -- enumerate again ------------------------------------------
        const req_after: u32 = 903;
        const list_before = cl.cookie_seq;
        cl.send(proto.CookiesReq{ .view = sitedata_view_id, .req = req_after, .url = site_url });
        if (!cl.waitSeq(&cl.cookie_seq, list_before, 10_000))
            fail("stage 31 site data: no ev_cookies answered the second enumeration");
        if (cl.cookie_ok == 0) fail("stage 31 site data: the cookie store went unreadable after the clear");
        if (cl.cookie_total != 0 or cl.cookie_shown != 0) {
            std.debug.print("smoke-web: cookies left:\n{s}\n", .{cl.cookie_names[0..cl.cookie_names_len]});
            fail("stage 31 site data: cookies survived the clear");
        }

        // A view id nobody created is answered, not ignored: a client
        // waiting on a reply must never wait forever.
        const orphan_before = cl.cookie_seq;
        cl.send(proto.CookiesReq{ .view = 4242, .req = 904, .url = site_url });
        if (!cl.waitSeq(&cl.cookie_seq, orphan_before, 5_000))
            fail("stage 31 site data: a request for an unknown view was never answered");
        if (cl.cookie_ok != 0) fail("stage 31 site data: an unknown view reported a readable cookie store");

        cl.send(proto.ViewDestroy{ .view = sitedata_view_id });
        cl.pump(300);
        pass("stage 31 site data (script-set cookie enumerated with metadata, cleared, gone)");
    }

    // ── Stage 23: teardown ────────────────────────────────────────
    cl.have_view = false;
    cl.send(proto.ViewDestroy{ .view = view_id });
    cl.deinit();
    {
        const deadline = nowMs() + 10_000;
        var status: c_int = 0;
        var gone = false;
        while (nowMs() < deadline) {
            if (c.waitpid(pid, &status, c.WNOHANG) == pid) {
                gone = true;
                break;
            }
            _ = c.usleep(50_000);
        }
        if (!gone) fail("stage 23 teardown: helper did not exit within 10s of the disconnect");
        g_pid = -1;
        if (status & 0x7f != 0) fail("stage 23 teardown: helper died on a signal");
        if ((status >> 8) & 0xff != 0) fail("stage 23 teardown: helper exited nonzero");
        pass("stage 23 teardown (helper exited 0 on disconnect)");
    }

    // ── Stage 24: GPU frames, or the fallback that replaces them ───
    //
    // A SECOND helper, this time with nothing pinned, so it makes the
    // same runtime decision the GUI's helper makes: a reachable Wayland
    // compositor plus a render node buys `--ozone-platform=wayland` and
    // dma-buf frames, anything else stays headless and software. BOTH
    // outcomes are asserted here — the point of the stage is that the
    // client gets working frames either way, which is what a CI box
    // with no compositor must also prove.
    {
        var sock2_buf: [96]u8 = undefined;
        const sock2 = std.fmt.bufPrintZ(&sock2_buf, "{s}/g.sock", .{dir}) catch fail("socket path");
        const gpu_pid = spawnHelper(exe, sock2.ptr, cache.ptr, null, false);
        g_pid = gpu_pid;
        var gc = Client{ .gpa = gpa, .fd = connectWithRetry(sock2.ptr, sock2.len) };
        gc.send(proto.Hello{ .proto = proto.PROTO_VERSION, .client_name = "smoke-web-gpu" });
        {
            const deadline = nowMs() + 20_000;
            while (gc.ack_proto == 0 and nowMs() < deadline) gc.pump(100);
        }
        if (gc.ack_proto != proto.PROTO_VERSION) fail("stage 24 gpu: no hello_ack from the auto-mode helper");
        if (!gc.ack_shm) fail("stage 24 gpu: frames-shm must stay advertised even in GPU mode");

        // 640x480 logical at 1.5 = 960x720 physical, which is also the
        // scale contract the GPU path has to reproduce THROUGH a
        // different mechanism (browser zoom instead of the screen
        // info's device scale factor).
        gc.send(proto.ViewCreate{ .view = view_id, .w = 640, .h = 480, .scale_x1000 = 1500, .context = 0 });
        gc.have_view = true;
        gc.send(proto.Navigate{ .view = view_id, .url = anim_page });
        _ = gc.drive(3000, 120);
        const run = gc.drive(2000, 120);

        if (gc.ack_dmabuf) {
            std.debug.print(
                "smoke-web: MEASURED gpu mode: {d} dma-buf frames, {d} memfd frames, {d} distinct pool buffers, fourcc 0x{x} modifier 0x{x} planes {d}\n",
                .{ gc.dma_seq, gc.dmg_seq, gc.dma_nids, gc.dma.?.fourcc, gc.dma.?.modifier, gc.dma.?.nplanes },
            );
            if (gc.dma_seq == 0) fail("stage 24 gpu: frames-dmabuf advertised but no dma-buf frame ever arrived");
            const f = gc.dma.?;
            if (f.w != 960 or f.h != 720) {
                std.debug.print("smoke-web: dma-buf was {d}x{d}\n", .{ f.w, f.h });
                fail("stage 24 gpu: the GPU frame is not the PHYSICAL size (the scale contract)");
            }
            if (f.nplanes == 0 or f.nplanes > proto.MAX_PLANES) fail("stage 24 gpu: implausible plane count");
            if (f.planes[0].stride < @as(u32, f.w) * 4) fail("stage 24 gpu: plane 0 cannot hold a row of pixels");
            if (f.fourcc == 0) fail("stage 24 gpu: no DRM format on the wire");
            if (run.paints == 0) fail("stage 24 gpu: the animating page produced no frames");
            // Pool identity: several frames out of a handful of
            // buffers. One id per paint would mean the client cannot
            // cache its import at all.
            if (gc.dma_seq > 8 and gc.dma_nids >= gc.dma_seq) {
                fail("stage 24 gpu: every frame announced a new buffer id, so the pool is not identified");
            }
            pass("stage 24 gpu frames (dma-buf planes, physical geometry, identified pool)");
        } else {
            if (gc.dma_seq != 0) fail("stage 24 gpu: dma-buf frames without the capability");
            if (run.paints == 0) fail("stage 24 gpu: no GPU here and the software fallback painted nothing");
            if (gc.fb == null) fail("stage 24 gpu: the software fallback announced no memfd buffer");
            if (gc.fb.?.w != 960 or gc.fb.?.h != 720) fail("stage 24 gpu: the fallback buffer is not physical");
            pass("stage 24 gpu frames (no GPU available: automatic software fallback, memfd frames)");
        }
        gc.have_view = false;
        gc.send(proto.ViewDestroy{ .view = view_id });
        gc.deinit();
        reapHelper(gpu_pid, "stage 24 gpu");
    }

    // ── Stage 25: the GPU path can be refused ─────────────────────
    //
    // `SKETERM_WEB_GPU=0` is the escape hatch for a driver quirk no
    // fallback caught: same binary, same host, no shared textures, no
    // capability, and the memfd path serving pixels as before.
    {
        var sock3_buf: [96]u8 = undefined;
        const sock3 = std.fmt.bufPrintZ(&sock3_buf, "{s}/s.sock", .{dir}) catch fail("socket path");
        const sw_pid = spawnHelper(exe, sock3.ptr, cache.ptr, null, true);
        g_pid = sw_pid;
        var sc = Client{ .gpa = gpa, .fd = connectWithRetry(sock3.ptr, sock3.len) };
        sc.send(proto.Hello{ .proto = proto.PROTO_VERSION, .client_name = "smoke-web-sw" });
        {
            const deadline = nowMs() + 20_000;
            while (sc.ack_proto == 0 and nowMs() < deadline) sc.pump(100);
        }
        if (sc.ack_proto != proto.PROTO_VERSION) fail("stage 25 forced software: no hello_ack");
        if (sc.ack_dmabuf) fail("stage 25 forced software: frames-dmabuf advertised despite SKETERM_WEB_GPU=0");
        sc.send(proto.ViewCreate{ .view = view_id, .w = 320, .h = 240, .scale_x1000 = 1000, .context = 0 });
        sc.have_view = true;
        sc.send(proto.Navigate{ .view = view_id, .url = red_page });
        const run = sc.drive(4000, 120);
        if (sc.dma_seq != 0) fail("stage 25 forced software: a dma-buf frame arrived anyway");
        if (run.paints == 0 or sc.fb == null) fail("stage 25 forced software: nothing painted into a memfd");
        pass("stage 25 forced software (no capability, no GPU frames, memfd path intact)");
        sc.have_view = false;
        sc.send(proto.ViewDestroy{ .view = view_id });
        sc.deinit();
        reapHelper(sw_pid, "stage 25 forced software");
    }

    // ── Stages 26/27: per-context egress + isolation ──────────────
    //
    // On their OWN helper, AFTER the main teardown, because a request
    // context pointed at a proxy leaves Chromium network state that
    // makes cef_shutdown slower than the 10s the teardown stage allows
    // — isolating it here keeps stage 23 pristine and the egress helper
    // gets a longer, tolerant reap of its own.
    {
        var sock4_buf: [96]u8 = undefined;
        const sock4 = std.fmt.bufPrintZ(&sock4_buf, "{s}/x.sock", .{dir}) catch fail("socket path");
        var cache4_buf: [128]u8 = undefined;
        const cache4 = std.fmt.bufPrintZ(&cache4_buf, "{s}/cache-egress", .{dir}) catch fail("cache path");
        const eg_pid = spawnHelper(exe, sock4.ptr, cache4.ptr, "--ozone-platform=headless", false);
        g_pid = eg_pid;
        var ec = Client{ .gpa = gpa, .fd = connectWithRetry(sock4.ptr, sock4.len) };
        ec.send(proto.Hello{ .proto = proto.PROTO_VERSION, .client_name = "smoke-web-egress" });
        {
            const deadline = nowMs() + 20_000;
            while (ec.ack_proto == 0 and nowMs() < deadline) ec.pump(100);
        }
        if (ec.ack_proto != proto.PROTO_VERSION) fail("stage 26 egress: no hello_ack from the egress helper");
        if (!ec.ack_contexts) fail("stage 26 egress: hello_ack lacks the contexts capability");

        // Stage 26: a dedicated identity context pointed at a SOCKS5
        // proxy. Its navigation must reach the proxy with the hostname
        // UNRESOLVED (atyp=domain) — DNS resolves at the proxy end, the
        // "browse via server X" property.
        {
            var probe = ProxyProbe{};
            if (!probe.start()) fail("stage 26 egress: could not start the in-process SOCKS5 probe");
            defer probe.shutdown();
            var proxy_buf: [64]u8 = undefined;
            const proxy_url = std.fmt.bufPrint(&proxy_buf, "socks5://127.0.0.1:{d}", .{probe.port}) catch unreachable;
            ec.send(proto.ContextCreate{ .id = 10, .ephemeral = 1, .name = "egress-a", .proxy = proxy_url });
            ec.send(proto.ViewCreate{ .view = egress_view_a, .w = 320, .h = 240, .scale_x1000 = 1000, .context = 10 });
            ec.send(proto.Navigate{ .view = egress_view_a, .url = "http://cookie-a.example/" });
            const deadline = nowMs() + 20_000;
            while (probe.seenHost() == null and nowMs() < deadline) ec.pump(100);
            const host = probe.seenHost() orelse
                fail("stage 26 egress: the proxied context never reached the SOCKS5 probe");
            if (!probe.atyp_domain) fail("stage 26 egress: the CONNECT did not arrive as atyp=domain (remote DNS lost)");
            if (!std.mem.eql(u8, host, "cookie-a.example")) {
                std.debug.print("smoke-web: proxy saw host \"{s}\"\n", .{host});
                fail("stage 26 egress: the proxy saw the wrong host");
            }
            pass("stage 26 egress (per-context SOCKS5 proxy, atyp=domain, remote DNS)");
        }

        // Stage 27: two contexts pointed at two DIFFERENT proxies; each
        // view's traffic leaves through ITS OWN context's proxy and no
        // other — the per-tab identity property proven directly.
        {
            var probe_a = ProxyProbe{};
            var probe_b = ProxyProbe{};
            if (!probe_a.start() or !probe_b.start()) fail("stage 27 isolation: could not start the SOCKS5 probes");
            defer probe_a.shutdown();
            defer probe_b.shutdown();
            var buf_a: [64]u8 = undefined;
            var buf_b: [64]u8 = undefined;
            const url_a = std.fmt.bufPrint(&buf_a, "socks5://127.0.0.1:{d}", .{probe_a.port}) catch unreachable;
            const url_b = std.fmt.bufPrint(&buf_b, "socks5://127.0.0.1:{d}", .{probe_b.port}) catch unreachable;
            ec.send(proto.ContextCreate{ .id = 11, .ephemeral = 1, .name = "iso-a", .proxy = url_a });
            ec.send(proto.ContextCreate{ .id = 12, .ephemeral = 1, .name = "iso-b", .proxy = url_b });
            ec.send(proto.ViewCreate{ .view = egress_view_b, .w = 320, .h = 240, .scale_x1000 = 1000, .context = 11 });
            ec.send(proto.ViewCreate{ .view = egress_view_c, .w = 320, .h = 240, .scale_x1000 = 1000, .context = 12 });
            ec.send(proto.Navigate{ .view = egress_view_b, .url = "http://only-in-a.example/" });
            ec.send(proto.Navigate{ .view = egress_view_c, .url = "http://only-in-b.example/" });
            const deadline = nowMs() + 20_000;
            while ((probe_a.seenHost() == null or probe_b.seenHost() == null) and nowMs() < deadline) ec.pump(100);
            const ha = probe_a.seenHost() orelse fail("stage 27 isolation: context A never reached its proxy");
            const hb = probe_b.seenHost() orelse fail("stage 27 isolation: context B never reached its proxy");
            if (!std.mem.eql(u8, ha, "only-in-a.example")) {
                std.debug.print("smoke-web: proxy A saw \"{s}\", proxy B saw \"{s}\"\n", .{ ha, hb });
                fail("stage 27 isolation: proxy A saw the wrong host");
            }
            if (!std.mem.eql(u8, hb, "only-in-b.example")) {
                std.debug.print("smoke-web: proxy A saw \"{s}\", proxy B saw \"{s}\"\n", .{ ha, hb });
                fail("stage 27 isolation: proxy B saw the wrong host");
            }
            if (std.mem.eql(u8, ha, hb)) fail("stage 27 isolation: both proxies saw the same host (contexts not isolated)");
            pass("stage 27 isolation (two contexts, two proxies, independent egress)");
        }

        // Destroy the browsers FIRST and pump so their async close
        // finishes, THEN destroy the contexts (also exercising
        // context_destroy and freeing the ephemeral in-memory stores),
        // then pump again — a proxied browser still half-closed at
        // cef_shutdown is what makes CEF exit on a signal.
        ec.send(proto.ViewDestroy{ .view = egress_view_a });
        ec.send(proto.ViewDestroy{ .view = egress_view_b });
        ec.send(proto.ViewDestroy{ .view = egress_view_c });
        ec.have_view = false;
        {
            const d = nowMs() + 4000;
            while (nowMs() < d) ec.pump(50);
        }
        ec.send(proto.ContextDestroy{ .id = 10 });
        ec.send(proto.ContextDestroy{ .id = 11 });
        ec.send(proto.ContextDestroy{ .id = 12 });
        {
            const d = nowMs() + 2000;
            while (nowMs() < d) ec.pump(50);
        }
        ec.deinit();
        // Reap TOLERANTLY: CEF's cef_shutdown raises a signal whenever
        // the process ever created a proxied request context, even after
        // every view and context is destroyed and drained — a known
        // shutdown-path artifact of the engine, not a functional defect
        // (the whole feature was just proven above). What still MUST hold
        // is that the process terminates rather than hangs.
        reapHelperTolerant(eg_pid, "stages 26/27 egress", 30_000);
    }

    // ── Stage 28: remote helper — inline frames over a mux channel ──
    //
    // The whole remote-browsing path on one machine: a PRIVATE
    // sketerm-mux daemon is asked (`web_helper_open`) to spawn the
    // helper with `--socket-fd`/`--frames-inline`; the helper protocol
    // then rides a mux byte channel bridged onto a socketpair, and the
    // ordinary rig Client proves frames arrive IN-BAND (no descriptor
    // ever crosses), damage stays partial, and input works end to end.
    if (argv.len >= 3) {
        var msock_buf: [96]u8 = undefined;
        const msock = std.fmt.bufPrintZ(&msock_buf, "{s}/m.sock", .{dir}) catch fail("mux socket path");
        var cache5_buf: [128]u8 = undefined;
        const cache5 = std.fmt.bufPrintZ(&cache5_buf, "{s}/cache-rmt", .{dir}) catch fail("cache path");
        _ = cache5;
        var state_buf: [128:0]u8 = undefined;
        const state_dir = std.fmt.bufPrintZ(&state_buf, "{s}/state", .{dir}) catch fail("state path");
        _ = c.mkdir(state_dir.ptr, 0o700);
        {
            const mpid = c.fork();
            if (mpid < 0) fail("stage 32: fork mux");
            if (mpid == 0) {
                // The daemon resolves the helper through findbin; the
                // env pin points it at the freshly built binary.
                _ = c.setenv("SKETERM_WEB_BIN", exe, 1);
                _ = c.setenv("XDG_STATE_HOME", state_dir.ptr, 1);
                _ = c.setenv("SKETERM_MUX_NO_WAYLAND", "1", 1);
                var vec: [4:null]?[*:0]const u8 = @splat(null);
                vec[0] = argv[2];
                vec[1] = "--socket";
                vec[2] = msock.ptr;
                _ = c.execv(argv[2], @ptrCast(@constCast(&vec)));
                c._exit(127);
            }
            g_mux_pid = mpid;
        }

        // Connect with retry while the daemon binds.
        var mux = MuxLite{ .gpa = gpa, .fd = -1 };
        {
            var addr = std.mem.zeroes(c.struct_sockaddr_un);
            addr.sun_family = c.AF_UNIX;
            @memcpy(addr.sun_path[0..msock.len], msock);
            const deadline = nowMs() + 15_000;
            while (mux.fd < 0) {
                if (nowMs() > deadline) fail("stage 32: mux daemon never listened");
                const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
                if (fd < 0) fail("socket");
                if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) == 0) {
                    mux.fd = fd;
                } else {
                    _ = c.close(fd);
                    _ = c.usleep(100_000);
                }
            }
        }

        // hello -> welcome, which must advertise the capability.
        mux.send(.hello, "{\"proto\":6,\"min_proto\":1,\"negotiation\":1}");
        {
            const f = mux.next(10_000) orelse fail("stage 32: no welcome");
            defer gpa.free(f.payload);
            if (f.ftype != .welcome) fail("stage 32: first frame was not the welcome");
            if (std.mem.indexOf(u8, f.payload, "\"web_helper\":true") == null)
                fail("stage 32: welcome lacks web_helper:true");
        }

        // web_helper_open -> chan_open (kind web_helper) + ok reply.
        mux.send(.web_helper_open, "{\"req\":9}");
        var chan: u32 = 0;
        var got_reply = false;
        {
            const deadline = nowMs() + 20_000;
            while (!got_reply or chan == 0) {
                if (nowMs() > deadline) fail("stage 32: no web_helper_reply");
                const f = mux.next(1_000) orelse continue;
                defer gpa.free(f.payload);
                switch (f.ftype) {
                    .chan_open => {
                        const co = mux_wire.decodeChanOpen(f.payload) orelse fail("stage 32: bad chan_open");
                        if (co.kind != .web_helper) fail("stage 32: wrong channel kind");
                        chan = co.id;
                    },
                    .web_helper_reply => {
                        if (std.mem.indexOf(u8, f.payload, "\"ok\":true") == null) {
                            say(f.payload);
                            fail("stage 32: web_helper_open refused");
                        }
                        got_reply = true;
                    },
                    else => {},
                }
            }
        }

        // Bridge the channel onto a socketpair and speak the helper
        // protocol on the other end.
        var pair: [2]c_int = .{ -1, -1 };
        if (c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &pair) != 0) fail("stage 32: socketpair");
        var bridge = RigBridge{ .gpa = gpa, .mux = &mux, .chan = chan, .fd = pair[1] };
        bridge.spawn();
        var rc = Client{ .gpa = gpa, .fd = pair[0] };
        rc.send(proto.Hello{ .proto = proto.PROTO_VERSION, .client_name = "smoke-web-remote" });
        rc.send(proto.FrameMode{ .mode = proto.frame_mode_inline });
        {
            const deadline = nowMs() + 30_000;
            while (rc.ack_proto == 0 and nowMs() < deadline) rc.pump(100);
        }
        if (rc.ack_proto != proto.PROTO_VERSION) fail("stage 32: no hello_ack over the bridge");
        if (!rc.ack_frames_inline) fail("stage 32: hello_ack lacks the frames-inline capability");

        // Paint: the red page must arrive as in-band pixels, with NO
        // memfd announcement and NO descriptor ever crossing.
        rc.send(proto.ViewCreate{ .view = view_id, .w = 320, .h = 240, .scale_x1000 = 1000, .context = 0 });
        rc.have_view = true;
        rc.send(proto.Navigate{ .view = view_id, .url = red_page });
        if (!rc.waitInlineCenter(.{ 0, 0, 255 }, 30_000)) fail("stage 32: no red inline frame");
        if (rc.fb_seq != 0) fail("stage 32: a frame_buffer crossed the bridge (memfd family leaked through)");
        if (rc.nfds != 0) fail("stage 32: a descriptor crossed the bridge");
        if (!rc.inline_deflate_seen) fail("stage 32: a flat red page never compressed (deflate path unused)");
        pass("stage 32a remote helper (inline frames over a mux byte channel, no descriptors)");

        // Damage economy: after the small-box page settles, steady
        // frames must cover a small fraction of the surface.
        rc.send(proto.Navigate{ .view = view_id, .url = small_anim_page });
        if (!rc.waitInlineCenter(.{ 0, 0, 255 }, 30_000)) fail("stage 32: the animating page never painted");
        {
            const deadline = nowMs() + 10_000;
            var small_seen = false;
            var settle_frames: u32 = 0;
            const surface_area: u32 = @as(u32, rc.iw) * @as(u32, rc.ih);
            while (nowMs() < deadline and !small_seen) {
                const seq = rc.inline_seq;
                rc.pump(100);
                if (rc.inline_seq != seq) {
                    settle_frames += 1;
                    // Skip the first few (navigation repaints in full).
                    if (settle_frames > 4 and rc.inline_last_area * 8 <= surface_area) small_seen = true;
                }
            }
            if (!small_seen) fail("stage 32: every inline frame was (near-)full — damage economy lost");
        }
        pass("stage 32b inline damage economy (steady frames stay partial)");

        // Input rides the bridge: a mousedown flips the page colour.
        rc.send(proto.Navigate{ .view = view_id, .url = click_paint_page });
        if (!rc.waitInlineCenter(.{ 0, 255, 0 }, 30_000)) fail("stage 32: click page never painted green");
        rc.send(proto.InputPointer{
            .view = view_id,
            .kind = @intFromEnum(proto.PointerKind.down),
            .x = 160,
            .y = 120,
            .button = 0,
            .clicks = 1,
            .mods = 0,
        });
        rc.send(proto.InputPointer{
            .view = view_id,
            .kind = @intFromEnum(proto.PointerKind.up),
            .x = 160,
            .y = 120,
            .button = 0,
            .clicks = 1,
            .mods = 0,
        });
        if (!rc.waitInlineCenter(.{ 255, 0, 255 }, 15_000)) fail("stage 32: the click never repainted magenta");
        pass("stage 32c input over the bridge (mousedown repaints)");

        // Teardown: closing the protocol socket ends the channel; the
        // daemon kills the helper (it dies with the channel) and the
        // daemon itself goes by exact pid.
        rc.have_view = false;
        rc.deinit(); // closes pair[0]; the bridge sees EOF and exits
        bridge.stop();
        mux.deinit();
        _ = c.kill(g_mux_pid, c.SIGTERM);
        {
            const deadline = nowMs() + 10_000;
            var status: c_int = 0;
            var reaped = false;
            while (nowMs() < deadline) {
                if (c.waitpid(g_mux_pid, &status, c.WNOHANG) == g_mux_pid) {
                    reaped = true;
                    break;
                }
                _ = c.usleep(50_000);
            }
            if (!reaped) {
                _ = c.kill(g_mux_pid, c.SIGKILL);
                _ = c.waitpid(g_mux_pid, &status, 0);
                fail("stage 32: the private daemon did not exit on SIGTERM");
            }
            g_mux_pid = -1;
        }
        pass("stage 32 remote helper teardown (helper died with the channel, daemon reaped by pid)");
    } else {
        say("smoke-web: NOTE stage 32 skipped (no sketerm-mux path in argv[2])");
    }
    // ── Stage 28: WebExtensions foundation ────────────────────────
    runWebextStage(gpa, exe, dir);
    runWebrequestStage(gpa, exe, dir);

    cleanup();
    if (gpa_state.deinit() == .leak) {
        say("smoke-web: FAIL leaked memory (see GPA report above)");
        return 1;
    }
    say("smoke-web: PASS");
    return 0;
}
