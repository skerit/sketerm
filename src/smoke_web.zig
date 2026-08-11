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
//! watchdog, input-to-paint latency), and a clean shutdown on
//! disconnect.
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
//! `--ozone-platform=headless`, so no display is needed. No network is
//! touched — every page is a data: URL and the one popup target is
//! `example.invalid`, which the helper cancels before any load.

const std = @import("std");
const c = @import("c.zig").c;
const proto = @import("web/protocol.zig");
const webhints = @import("web/hints.zig");

const view_id: u32 = 1;
/// The stage-22b view, created directly at a url.
const url_view_id: u32 = 2;
/// The stage-22c view: a page with NO background of its own.
const bare_view_id: u32 = 3;

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

// Cleanup state: `fail` may fire from anywhere, and the helper must
// never be left running nor the temp dir behind. Killed by EXACT pid.
var g_pid: c.pid_t = -1;
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
    popup_url: [1024]u8 = @splat(0),
    popup_len: usize = 0,

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

    fn deinit(self: *Client) void {
        self.unmap();
        if (self.fb_fd >= 0) _ = c.close(self.fb_fd);
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

    /// Paints seen on EITHER frame family: the software path reports
    /// `frame_damage`, the GPU path `frame_dmabuf`, and the pacing
    /// assertions care only that pixels happened.
    fn paintCount(self: *const Client) u32 {
        return self.dmg_seq +% self.dma_seq;
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
                }
            },
            .frame_buffer => {
                const fb = proto.decode(proto.FrameBuffer, frame.payload) catch fail("frame_buffer decode");
                const fd = self.takeFd();
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
                self.dmg_buf = d.buf_id;
                self.dmg_seq += 1;
            },
            .ev_title => {
                const t = proto.decode(proto.EvTitle, frame.payload) catch fail("ev_title decode");
                self.title_len = @min(t.title.len, self.title.len);
                @memcpy(self.title[0..self.title_len], t.title[0..self.title_len]);
            },
            .ev_popup_request => {
                const p = proto.decode(proto.EvPopupRequest, frame.payload) catch fail("ev_popup_request decode");
                self.popup_view = p.view;
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
    const deadline = nowMs() + 10_000;
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
    pass("stage 6 popup request");

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

    cleanup();
    if (gpa_state.deinit() == .leak) {
        say("smoke-web: FAIL leaked memory (see GPA report above)");
        return 1;
    }
    say("smoke-web: PASS");
    return 0;
}
