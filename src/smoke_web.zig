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
const builtin = @import("builtin");
const c = @import("c.zig").c;
const smoke_tls = @import("smoke_tls.zig");
const tcpserver = @import("smoke/tcpserver.zig");
const unixsock = @import("smoke/unixsock.zig");
const proto = @import("web/protocol.zig");
const zpool = @import("wlhost/zpool.zig");
const mux_wire = @import("mux/wire.zig");
const webhints = @import("web/hints.zig");
const axtree = @import("web/axtree.zig");
const socks5 = @import("ipc/socks5.zig");
const zip = @import("web/webext/zip.zig");
const filtersub = @import("web/filtersub.zig");
const extmanifest = @import("web/webext/manifest.zig");

/// `SKETERM_SMOKE_WEB_CONSOLE=1` echoes every page console message.
/// Off by default because 30-odd stages would drown in Chromium noise;
/// on, it is the only window into a hidden background page.
var g_echo_console = false;

/// One tab as stage 35 describes it to the helper.
const TabSpec = struct {
    id: u32,
    view: u32,
    active: bool = false,
    url: []const u8 = "",
    title: []const u8 = "",
};

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

/// Stage 41 (cross-instance cookie sync). Two names, because the two
/// OBSERVERS in the helper cover different writes and the stage has to
/// be able to say which one carried which: `sync_hdr_cookie` arrives on
/// a `Set-Cookie` response header, `sync_js_cookie` is written by
/// `document.cookie` and no header ever mentions it.
const sync_hdr_cookie = "sk_sync_hdr";
const sync_hdr_value = "hdr-value-9f3a";
const sync_js_cookie = "sk_sync_js";
const sync_js_value = "js-value-71c2";
/// The synthetic cookie the attribute round trip is measured on: it
/// carries every attribute at a NON-DEFAULT value, so a silently
/// dropped one cannot be mistaken for a default.
const sync_attr_cookie = "sk_sync_attr";
const sync_attr_value = "attr-value-5d10";
const sync_attr_url = "https://sync-attr.example/deep/path";
const sync_attr_domain = "sync-attr.example";
const sync_attr_path = "/deep/path";
/// MEASURED (CEF 151 / Chromium): a cookie expiry is CLAMPED to 400
/// days from now, per Chromium's `kMaxCookieExpirationTime` — a 2100
/// date came back as today plus 400 days, which read as "the expiry
/// was dropped" until it was looked at. The stage therefore asks for
/// 30 days, well inside the cap, so the assertion measures OUR round
/// trip and not the engine's policy.
fn syncAttrExpiresMs() u64 {
    const ms = @import("util/clock.zig").wallMs();
    const base: u64 = if (ms <= 0) 0 else @intCast(ms);
    return base + 30 * 24 * 60 * 60 * 1000;
}
/// Cookies applied to prove the dump PAGES rather than truncating.
const sync_bulk_count: u32 = 140;
const sync_bulk_url = "https://sync-bulk.example/";
const sync_view_a: u32 = 42;

/// Stage-26/27 views, each in its own identity context.
const egress_view_a: u32 = 5;
const egress_view_b: u32 = 6;
const egress_view_c: u32 = 7;
const egress_unknown_view: u32 = 11;
const egress_proxy_fail_view: u32 = 12;
/// The negative-control view on a direct instance (stage 27).
const egress_direct_view: u32 = 14;

/// Stage-37 views. Both are pointed at the SAME loopback origin in two
/// different containers: origin separation would explain a cookie not
/// crossing, so only one origin can prove the JAR is what separates them.
const jar_view_a: u32 = 9;
const jar_view_b: u32 = 10;
const jar_cookie = "sk_jar37";
const jar_cookie_value = "only-in-a";
/// One document for both containers; the QUERY STRING decides whether it
/// writes the cookie, and the title prefix says which side reported, so
/// the two settles cannot be confused for one another.
const jar_page =
    "<html><head><title>jar</title></head><body>jar" ++
    "<script>var s=location.search.indexOf('set')>=0;" ++
    "if(s)document.cookie=\"" ++ jar_cookie ++ "=" ++ jar_cookie_value ++
    "; path=/; max-age=3600; SameSite=Lax\";" ++
    "document.title=(s?\"jarA:\":\"jarB:\")+document.cookie;</script></body></html>";

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

/// A same-document route transition shaped like a client-side app: a
/// trusted link click changes history and replaces enough visible DOM for
/// Chromium's soft-navigation heuristic to report it.
const spa_page =
    "<!doctype html><html><head><title>spa:start</title></head><body>" ++
    "<nav><a id=learn href=/learn>Learn SPA Route</a></nav>" ++
    "<main id=app><h1>SPA Start</h1><p>Initial route content.</p></main>" ++
    "<script>learn.addEventListener('click',function(e){e.preventDefault();" ++
    "history.pushState({},'',this.href);" ++
    "var next=document.createElement('main');next.id='app';" ++
    "var h=document.createElement('h1');h.textContent='SPA Destination';next.appendChild(h);" ++
    "for(var i=0;i<120;i++){var p=document.createElement('p');" ++
    "p.textContent='Destination route content row '+i;next.appendChild(p)}" ++
    "document.getElementById('app').replaceWith(next);" ++
    "document.title='spa:trusted='+e.isTrusted+':'+location.pathname;" ++
    "});</script></body></html>";
/// Served with a CSP that lacks 'unsafe-eval': the spliced-eval lane,
/// the act echoes and the landed-value read all prove out here. The
/// input replaces itself on the first keystroke, the way a framework
/// re-render does, so the commit read must follow focus to the
/// successor and say the control was replaced.
const csp_eval_page =
    "<!doctype html><html><head><title>csp-fix</title></head><body>" ++
    "<a href=\"#x\">CSP Link</a>" ++
    "<input aria-label=\"vfield\" id=f>" ++
    "<script>var swapped=false;" ++
    "document.getElementById('f').addEventListener('input',function(e){" ++
    "if(swapped)return;swapped=true;" ++
    "var el=e.target;var c=el.cloneNode(true);el.replaceWith(c);c.focus();});" ++
    "</script></body></html>";
const csp_header =
    "Content-Security-Policy: script-src 'self' 'unsafe-inline'; object-src 'none'\r\n";
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

/// A page whose confirmation dialog makes everything else inert
/// (aria-hidden), the way a modal does: the walk stops listing the
/// page while the dialog is up and lists it again afterwards.
const modal_page =
    "data:text/html,<html><head><title>Hosts</title></head><body>" ++
    "<nav id=n><a href=%23a>Dashboard</a><a href=%23b>Hosts</a><a href=%23c>Settings</a></nav>" ++
    "<main id=m><h1>Hosts</h1><button>Delete</button></main>" ++
    "<div id=dlg role=alertdialog aria-label=Confirm style=display:none><p>Delete this host?</p>" ++
    "<button>Cancel</button><button>Confirm</button></div>" ++
    "<script>function openDlg(){n.setAttribute('aria-hidden','true');m.setAttribute('aria-hidden','true');" ++
    "dlg.style.display='block';}function closeDlg(){n.removeAttribute('aria-hidden');" ++
    "m.removeAttribute('aria-hidden');dlg.style.display='none';}</script></body></html>";

const article_page =
    "data:text/html,<html><head><title>Journal</title></head><body>" ++
    "<nav><a href=%23x>Nav One</a><a href=%23y>Nav Two</a></nav>" ++
    "<article><h1>Article Heading</h1><p>" ++ long_text ++ "</p>" ++
    "<p>A second paragraph so the extractor has real text density.</p>" ++
    "<table><tr><th>Name</th><th>Type</th></tr><tr><td>local</td><td>Docker</td></tr>" ++
    "<tr><td>remote</td><td>SSH</td></tr></table>" ++
    "<label>Owner <input value=jelle></label>" ++
    "<label>Tier <select><option>Free</option><option selected>Pro</option></select></label>" ++
    "<label><input type=checkbox checked> Enabled</label>" ++
    "<div role=table aria-label=Fleet><div role=row><span role=columnheader>Host</span></div>" ++
    "<div role=row><span role=cell>aria cell</span></div></div></article>" ++
    "</body></html>";

/// A div grid, the shape of a router's device list: no <table>, no role,
/// six identical rows with an Edit each. Row 5's address CONTAINS row
/// 3's, the near-miss that opened the wrong device in the field.
const grid_page =
    "data:text/html,<html><head><title>Grid</title></head><body><h1>Devices</h1>" ++
    "<div id=list><div class=hint>Six devices are known</div>" ++
    "<div class=r><div class=c>PC-1</div><div class=c>LAN 1</div><div class=c>10.47.1.1</div><div class=c><button onclick=\"document.title='edit:1'\">Edit</button></div></div>" ++
    "<div class=r><div class=c>PC-2</div><div class=c>LAN 2</div><div class=c>10.47.1.2</div><div class=c><button onclick=\"document.title='edit:2'\">Edit</button></div></div>" ++
    "<div class=r><div class=c>PC-3</div><div class=c>LAN 3</div><div class=c>10.47.1.3</div><div class=c><button onclick=\"document.title='edit:3'\">Edit</button></div></div>" ++
    "<div class=r><div class=c>PC-4</div><div class=c>LAN 4</div><div class=c>10.47.1.4</div><div class=c><button onclick=\"document.title='edit:4'\">Edit</button></div></div>" ++
    "<div class=r><div class=c>PC-5</div><div class=c>LAN 5</div><div class=c>10.47.1.30</div><div class=c><button onclick=\"document.title='edit:5'\">Edit</button></div></div>" ++
    "<div class=r><div class=c>PC-6</div><div class=c>LAN 6</div><div class=c>10.47.1.6</div><div class=c><button onclick=\"document.title='edit:6'\">Edit</button></div></div>" ++
    "</div><div class=note><span>Footer text in a span</span></div></body></html>";

/// Rich reader proof: the only actionable node returned by reader mode
/// changes the title on a trusted click. Its sibling mutation button is
/// outside <article>, so it never appears as a reader entity.
const reader_ids_page =
    "data:text/html,<html><head><title>Reader IDs</title></head><body>" ++
    "<article><h1>Reader Target</h1><p><a id=reader-go role=button href=%23done " ++
    "onclick=\"document.title='reader:trusted='+event.isTrusted;return false\">Activate Reader Target</a></p>" ++
    "<p>Enough article text for useful reader extraction and a stable result.</p></article>" ++
    "<button id=reader-mutate onclick=\"document.getElementById('reader-go').href='%23changed';" ++
    "document.title='reader:mutated'\">Mutate</button></body></html>";

const reader_nav_page =
    "data:text/html,<html><head><title>Reader After Navigation</title></head><body>" ++
    "<article><h1>Reader After Navigation</h1>" ++
    "<p>NAVIGATION-READ-MARKER enough article text to make reader extraction deterministic.</p>" ++
    "</article></body></html>";

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
    if (g_pid_b > 0) {
        _ = c.kill(g_pid_b, c.SIGKILL);
        var status: c_int = 0;
        _ = c.waitpid(g_pid_b, &status, 0);
        g_pid_b = -1;
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

const nowMs = @import("util/clock.zig").nowMs;

const nowUs = @import("util/clock.zig").nowUs;

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
    lis: tcpserver.Listener = .{ .backlog = 16, .poll_ms = 200 },
    got: std.atomic.Value(bool) = .init(false),
    host: [256]u8 = @splat(0),
    host_len: usize = 0,
    atyp_domain: bool = false,
    port: u16 = 0,
    /// Nonzero relays matching CONNECTs to this loopback HTTP port.
    tunnel_port: u16 = 0,
    route_a: std.atomic.Value(bool) = .init(false),
    route_b: std.atomic.Value(bool) = .init(false),
    request_probe: [2048]u8 = @splat(0),
    request_probe_len: usize = 0,

    fn start(self: *ProxyProbe) bool {
        return self.lis.start(self, &onConn);
    }

    fn onConn(ctx: ?*anyopaque, afd: c_int) bool {
        const self: *ProxyProbe = @ptrCast(@alignCast(ctx.?));
        self.handle(afd);
        return false;
    }

    fn handle(self: *ProxyProbe, afd: c_int) void {
        // Record only the FIRST CONNECT: a browser may open several
        // connections (retries after the tunnel closes, sub-resources),
        // and a later one overwriting the record would race the reader.
        // A later connection is simply refused a no-auth handshake so it
        // closes without disturbing the recorded host.
        if (self.tunnel_port == 0 and self.got.load(.acquire)) {
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
        if (r.cmd != .connect) return;
        if (self.tunnel_port != 0 and r.port != self.tunnel_port) return;
        switch (r.addr) {
            .domain => |d| {
                // Chromium itself phones home through a fresh context
                // (component/service fetches to google.com and friends)
                // and can win the race for the FIRST slot. The rig only
                // ever navigates to `.example` hosts, so anything else
                // is engine noise: refuse the tunnel unrecorded and
                // keep the slot for the test's own navigation.
                if (!std.mem.endsWith(u8, d, ".example")) return;
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
        self.port = r.port;
        self.got.store(true, .release);
        if (self.tunnel_port != 0) {
            const upstream = connectLoopback(self.tunnel_port) orelse {
                const failed = socks5.connectReply(.host_unreachable);
                _ = c.write(afd, &failed, failed.len);
                return;
            };
            defer _ = c.close(upstream);
            const rep = socks5.connectReply(.ok);
            if (!writeAll(afd, &rep)) return;
            const initial = acc[r.consumed..acc_len];
            self.relay(afd, upstream, initial);
            return;
        }
        const rep = socks5.connectReply(.ok);
        _ = c.write(afd, &rep, rep.len);
    }

    fn connectLoopback(port: u16) ?c_int {
        const fd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
        if (fd < 0) return null;
        var sa = std.mem.zeroes(c.struct_sockaddr_in);
        sa.sin_family = c.AF_INET;
        sa.sin_port = std.mem.nativeToBig(u16, port);
        sa.sin_addr.s_addr = std.mem.nativeToBig(u32, c.INADDR_LOOPBACK);
        if (c.connect(fd, @ptrCast(&sa), @sizeOf(c.struct_sockaddr_in)) != 0) {
            _ = c.close(fd);
            return null;
        }
        return fd;
    }

    fn writeAll(fd: c_int, bytes: []const u8) bool {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = c.write(fd, bytes.ptr + off, bytes.len - off);
            if (n < 0 and std.c._errno().* == c.EINTR) continue;
            if (n <= 0) return false;
            off += @intCast(n);
        }
        return true;
    }

    fn noteRequest(self: *ProxyProbe, bytes: []const u8) void {
        const take = @min(bytes.len, self.request_probe.len - self.request_probe_len);
        if (take != 0) {
            @memcpy(self.request_probe[self.request_probe_len..][0..take], bytes[0..take]);
            self.request_probe_len += take;
        }
        const seen = self.request_probe[0..self.request_probe_len];
        if (std.mem.indexOf(u8, seen, "route-a") != null) self.route_a.store(true, .release);
        if (std.mem.indexOf(u8, seen, "route-b") != null) self.route_b.store(true, .release);
    }

    fn relay(self: *ProxyProbe, client: c_int, upstream: c_int, initial: []const u8) void {
        if (initial.len != 0) {
            self.noteRequest(initial);
            if (!writeAll(upstream, initial)) return;
        }
        var client_open = true;
        var upstream_open = true;
        const deadline = nowMs() + 15_000;
        var buf: [16 * 1024]u8 = undefined;
        while ((client_open or upstream_open) and nowMs() < deadline) {
            var pfds = [_]c.struct_pollfd{
                .{ .fd = client, .events = if (client_open) c.POLLIN else 0, .revents = 0 },
                .{ .fd = upstream, .events = if (upstream_open) c.POLLIN else 0, .revents = 0 },
            };
            if (c.poll(@ptrCast(&pfds), pfds.len, 200) <= 0) continue;
            if (client_open and pfds[0].revents != 0) {
                const n = c.read(client, &buf, buf.len);
                if (n <= 0) {
                    client_open = false;
                    _ = c.shutdown(upstream, c.SHUT_WR);
                } else {
                    const bytes = buf[0..@intCast(n)];
                    self.noteRequest(bytes);
                    if (!writeAll(upstream, bytes)) client_open = false;
                }
            }
            if (upstream_open and pfds[1].revents != 0) {
                const n = c.read(upstream, &buf, buf.len);
                if (n <= 0) {
                    upstream_open = false;
                    _ = c.shutdown(client, c.SHUT_WR);
                } else if (!writeAll(client, buf[0..@intCast(n)])) {
                    upstream_open = false;
                }
            }
        }
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

    /// Forget the recorded CONNECT so the NEXT one is recorded. Only
    /// meaningful between navigations from the main thread: a late
    /// retry of the previous page can win the slot, which is why
    /// `waitProbeHost` re-arms rather than asserting on the first host.
    fn arm(self: *ProxyProbe) void {
        self.host_len = 0;
        self.got.store(false, .release);
    }

    fn shutdown(self: *ProxyProbe) void {
        self.lis.deinit();
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
    lis: tcpserver.Listener = .{ .backlog = 16, .poll_ms = 200 },
    /// Requests answered, so a stage can tell "the engine never asked"
    /// apart from "the engine asked and the cookie did not stick".
    served: std.atomic.Value(u32) = .init(0),
    /// The document served to every request.
    body: []const u8 = page,
    /// Extra response headers ("Name: v\r\n" each), e.g. a CSP.
    extra_headers: []const u8 = "",
    /// Stage 39 turns the otherwise one-document probe into a tiny
    /// filter-list/resource router.
    filter_router: bool = false,
    /// Stage 41 turns it into the cookie-sync fixture router.
    cookie_router: bool = false,
    filter_mode: std.atomic.Value(u8) = .init(@intFromEnum(FilterMode.good)),
    list_hits: std.atomic.Value(u32) = .init(0),
    blocked_hits: std.atomic.Value(u32) = .init(0),
    control_hits: std.atomic.Value(u32) = .init(0),
    slow_hits: std.atomic.Value(u32) = .init(0),
    workers: std.atomic.Value(u32) = .init(0),

    const FilterMode = enum(u8) { good, http_error, malformed, oversize };

    /// Sets the probe cookie from SCRIPT (not from a Set-Cookie
    /// header): what a site's own JavaScript stores is exactly what a
    /// site-data panel has to be able to show and delete.
    const page =
        "<html><head><title>cookie-page</title></head><body>cookies" ++
        "<script>document.cookie=\"" ++ cookie_probe ++ "=" ++ cookie_probe_value ++
        "; path=/; max-age=3600; SameSite=Lax\";" ++
        "document.title=\"cookie:\"+document.cookie;</script></body></html>";

    fn start(self: *HttpProbe) bool {
        return self.lis.start(self, &onConn);
    }

    /// Stage 39 needs concurrency (a slow list must not block the page),
    /// so the router mode hands the fd to a detached worker and keeps it
    /// open; the one-document mode answers inline.
    fn onConn(ctx: ?*anyopaque, afd: c_int) bool {
        const self: *HttpProbe = @ptrCast(@alignCast(ctx.?));
        if (self.filter_router) {
            _ = self.workers.fetchAdd(1, .release);
            const t = std.Thread.spawn(.{}, HttpProbe.handleAndClose, .{ self, afd }) catch {
                _ = self.workers.fetchSub(1, .release);
                return false;
            };
            t.detach();
            return true;
        }
        self.handle(afd);
        return false;
    }

    fn handleAndClose(self: *HttpProbe, afd: c_int) void {
        defer _ = self.workers.fetchSub(1, .release);
        self.handle(afd);
        _ = c.close(afd);
    }

    /// Stage 41 needs three DISTINGUISHABLE documents plus one real
    /// `Set-Cookie` response header — the only way to exercise the
    /// header observer and the script observer against the same origin.
    fn handleCookieSync(self: *HttpProbe, afd: c_int, raw: []const u8) void {
        _ = self.served.fetchAdd(1, .release);
        if (std.mem.indexOf(u8, raw, "GET /hdr") != null) {
            tcpserver.respondOk(afd, "text/html", hdr_page, hdr_set_cookie);
            return;
        }
        if (std.mem.indexOf(u8, raw, "GET /js") != null) {
            tcpserver.respondOk(afd, "text/html", js_page, "");
            return;
        }
        if (std.mem.indexOf(u8, raw, "GET /del") != null) {
            tcpserver.respondOk(afd, "text/html", del_page, "");
            return;
        }
        tcpserver.respondOk(afd, "text/html", "<html><head><title>ck:ready</title></head><body>ck</body></html>", "");
    }

    /// HttpOnly so the round trip has something a page could never
    /// forge back, SameSite=Strict and a real Max-Age so a dropped
    /// attribute is visible rather than merely wrong.
    const hdr_set_cookie =
        "Set-Cookie: " ++ sync_hdr_cookie ++ "=" ++ sync_hdr_value ++
        "; Path=/; Max-Age=86400; HttpOnly; SameSite=Strict\r\n";

    const hdr_page =
        "<html><head><title>hdr:ok</title></head><body>hdr</body></html>";

    /// A `document.cookie` write: no response header carries it, which
    /// is exactly the coverage gap stage 41 measures.
    const js_page =
        "<html><head><title>js:wait</title></head><body>js<script>" ++
        "document.cookie=\"" ++ sync_js_cookie ++ "=" ++ sync_js_value ++
        "; path=/; max-age=86400; SameSite=Lax\";" ++
        "document.title=\"js:\"+document.cookie;</script></body></html>";

    /// The script-side deletion: an expiry in the past.
    const del_page =
        "<html><head><title>del:wait</title></head><body>del<script>" ++
        "document.cookie=\"" ++ sync_js_cookie ++ "=; path=/; max-age=0\";" ++
        "document.title=\"del:[\"+document.cookie+\"]\";</script></body></html>";

    fn handle(self: *HttpProbe, afd: c_int) void {
        // Read whatever the request is and ignore it: one document
        // answers every path, which is all these stages need.
        var buf: [4096]u8 = undefined;
        var pfd = c.struct_pollfd{ .fd = afd, .events = c.POLLIN, .revents = 0 };
        var n: isize = 0;
        if (c.poll(@ptrCast(&pfd), 1, 2000) > 0) n = c.read(afd, &buf, buf.len);
        const raw = if (n > 0) buf[0..@intCast(n)] else "";
        if (self.filter_router) {
            self.handleFilter(afd, raw);
            return;
        }
        if (self.cookie_router) {
            self.handleCookieSync(afd, raw);
            return;
        }
        tcpserver.respondOk(afd, "text/html", self.body, self.extra_headers);
        _ = self.served.fetchAdd(1, .release);
    }

    fn handleFilter(self: *HttpProbe, afd: c_int, raw: []const u8) void {
        if (std.mem.indexOf(u8, raw, "GET /list.txt") != null) {
            _ = self.list_hits.fetchAdd(1, .release);
            const mode: FilterMode = @enumFromInt(self.filter_mode.load(.acquire));
            switch (mode) {
                .good => self.reply(afd, "200 OK", "text/plain", filter_body),
                .http_error => self.reply(afd, "503 Service Unavailable", "text/plain", filter_body),
                .malformed => self.reply(afd, "200 OK", "text/html", "<!doctype html><html><body>captive portal</body></html>"),
                .oversize => self.replyOversize(afd),
            }
            return;
        }
        if (std.mem.indexOf(u8, raw, "GET /slow.txt") != null) {
            _ = self.slow_hits.fetchAdd(1, .release);
            while (!self.lis.stop.load(.acquire)) _ = c.usleep(20_000);
            _ = self.slow_hits.fetchSub(1, .release);
            return;
        }
        if (std.mem.indexOf(u8, raw, "GET /blocked.js") != null) {
            _ = self.blocked_hits.fetchAdd(1, .release);
            self.reply(afd, "200 OK", "text/plain", "blocked-resource");
            return;
        }
        if (std.mem.indexOf(u8, raw, "GET /control.js") != null) {
            _ = self.control_hits.fetchAdd(1, .release);
            self.reply(afd, "200 OK", "text/plain", "control-resource");
            return;
        }
        self.reply(afd, "200 OK", "text/html", filter_page);
    }

    fn reply(_: *HttpProbe, afd: c_int, status: []const u8, ctype: []const u8, body: []const u8) void {
        var head: [256]u8 = undefined;
        const hdr = std.fmt.bufPrint(
            &head,
            "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",
            .{ status, ctype, body.len },
        ) catch return;
        writeHttp(afd, hdr);
        writeHttp(afd, body);
    }

    fn replyOversize(_: *HttpProbe, afd: c_int) void {
        const total: usize = 16 * 1024 * 1024 + 1;
        var head: [256]u8 = undefined;
        const hdr = std.fmt.bufPrint(
            &head,
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",
            .{total},
        ) catch return;
        writeHttp(afd, hdr);
        var chunk: [64 * 1024]u8 = @splat('!');
        @memcpy(chunk[0..filter_body.len], filter_body);
        var sent: usize = 0;
        while (sent < total) {
            const take = @min(chunk.len, total - sent);
            const n = c.write(afd, &chunk, take);
            if (n <= 0) return;
            sent += @intCast(n);
        }
    }

    fn setFilterMode(self: *HttpProbe, mode: FilterMode) void {
        self.filter_mode.store(@intFromEnum(mode), .release);
    }

    fn writeHttp(fd: c_int, bytes: []const u8) void {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = c.write(fd, bytes.ptr + off, bytes.len - off);
            if (n < 0 and std.c._errno().* == c.EINTR) continue;
            if (n <= 0) return;
            off += @intCast(n);
        }
    }

    fn resetResourceHits(self: *HttpProbe) void {
        self.blocked_hits.store(0, .release);
        self.control_hits.store(0, .release);
    }

    const filter_body =
        "[Adblock Plus 2.0]\n" ++
        "! Title: smoke-web stage 39\n" ++
        "blocked.js\n";

    const filter_page =
        "<!doctype html><html><head><title>fs-start</title></head><body><script>" ++
        "var q=location.search;Promise.all([" ++
        "fetch('/control.js'+q).then(function(r){return r.text()}).catch(function(){return 'control-error'})," ++
        "fetch('/blocked.js'+q).then(function(){return 'hit'},function(){return 'blocked'})" ++
        "]).then(function(r){document.title='fs'+q+':'+r[0]+':'+r[1]});" ++
        "</script></body></html>";

    fn shutdown(self: *HttpProbe) void {
        self.lis.deinit();
        const deadline = nowMs() + 2_000;
        while (self.workers.load(.acquire) != 0 and nowMs() < deadline) _ = c.usleep(10_000);
        if (self.workers.load(.acquire) != 0) fail("HTTP probe workers did not stop");
    }
};

/// One cookie the way stage 41 has to hold it: OWNED bytes, because a
/// change observed on instance A is applied to instance B several
/// frames later and the decode borrowed from a buffer long since
/// reused.
const CkCookie = struct {
    name: [128]u8 = @splat(0),
    name_len: usize = 0,
    value: [256]u8 = @splat(0),
    value_len: usize = 0,
    domain: [128]u8 = @splat(0),
    domain_len: usize = 0,
    path: [128]u8 = @splat(0),
    path_len: usize = 0,
    url: [256]u8 = @splat(0),
    url_len: usize = 0,
    context: u32 = 0,
    cause: u8 = 0,
    removed: u8 = 0,
    flags: u8 = 0,
    same_site: u8 = 0,
    priority: u8 = 0,
    creation_ms: u64 = 0,
    last_access_ms: u64 = 0,
    expires_ms: u64 = 0,

    fn put(dst: []u8, len: *usize, src: []const u8) void {
        const n = @min(dst.len, src.len);
        @memcpy(dst[0..n], src[0..n]);
        len.* = n;
    }

    fn fill(self: *CkCookie, ck: proto.SyncCookie) void {
        put(&self.name, &self.name_len, ck.name);
        put(&self.value, &self.value_len, ck.value);
        put(&self.domain, &self.domain_len, ck.domain);
        put(&self.path, &self.path_len, ck.path);
        self.flags = ck.flags;
        self.same_site = ck.same_site;
        self.priority = ck.priority;
        self.creation_ms = ck.creation_ms;
        self.last_access_ms = ck.last_access_ms;
        self.expires_ms = ck.expires_ms;
    }

    fn nameSlice(self: *const CkCookie) []const u8 {
        return self.name[0..self.name_len];
    }
    fn valueSlice(self: *const CkCookie) []const u8 {
        return self.value[0..self.value_len];
    }
    fn urlSlice(self: *const CkCookie) []const u8 {
        return self.url[0..self.url_len];
    }

    fn wire(self: *const CkCookie) proto.SyncCookie {
        return .{
            .name = self.name[0..self.name_len],
            .value = self.value[0..self.value_len],
            .domain = self.domain[0..self.domain_len],
            .path = self.path[0..self.path_len],
            .flags = self.flags,
            .same_site = self.same_site,
            .priority = self.priority,
            .creation_ms = self.creation_ms,
            .last_access_ms = self.last_access_ms,
            .expires_ms = self.expires_ms,
        };
    }
};

/// Stage 41's per-connection cookie-sync state. HEAP-allocated and
/// attached only by that stage: every other stage would otherwise carry
/// a quarter of a megabyte of buffers it never reads.
const CkState = struct {
    /// Every `ev_cookie_change` this connection ever received, in
    /// order. `seq` keeps counting past the ring so a "did it stop
    /// growing?" assertion is exact even if the ring wrapped.
    q: [96]CkCookie = @splat(.{}),
    head: usize = 0,
    seq: u32 = 0,
    apply_seq: u32 = 0,
    apply_req: u32 = 0,
    apply_ok: u8 = 0,
    apply_reason: [64]u8 = @splat(0),
    apply_reason_len: usize = 0,
    dump_seq: u32 = 0,
    dump_req: u32 = 0,
    dump_ok: u8 = 0,
    dump_cursor: u32 = 0,
    dump_next: u32 = 0,
    dump_more: u8 = 0,
    dump_total: u32 = 0,
    dump: [256]CkCookie = @splat(.{}),
    dump_n: usize = 0,

    /// The most recent change carrying `name`, or null.
    fn lastChange(self: *const CkState, name: []const u8) ?*const CkCookie {
        var i = self.head;
        var n: usize = 0;
        while (n < self.q.len) : (n += 1) {
            i = if (i == 0) self.q.len - 1 else i - 1;
            if (self.q[i].name_len == 0) continue;
            if (std.mem.eql(u8, self.q[i].nameSlice(), name)) return &self.q[i];
        }
        return null;
    }

    /// How many changes ever named `name` (the ping-pong counter).
    fn countChanges(self: *const CkState, name: []const u8) u32 {
        var n: u32 = 0;
        for (&self.q) |*e| {
            if (e.name_len != 0 and std.mem.eql(u8, e.nameSlice(), name)) n += 1;
        }
        return n;
    }

    fn dumpFind(self: *const CkState, name: []const u8) ?*const CkCookie {
        for (self.dump[0..self.dump_n]) |*e| {
            if (std.mem.eql(u8, e.nameSlice(), name)) return e;
        }
        return null;
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
    ack_reader_ids: bool = false,
    ack_semantic_request_ids: bool = false,
    ack_dmabuf: bool = false,
    ack_view_url: bool = false,
    ack_discard: bool = false,
    ack_tls: bool = false,
    ack_permissions: bool = false,
    ack_devtools: bool = false,
    ack_print_pdf: bool = false,
    ack_downloads: bool = false,
    ack_contexts: bool = false,
    ack_contexts_fail_closed: bool = false,
    ack_webext: bool = false,
    ack_webext_tabs: bool = false,
    ack_filter_subscribe: bool = false,
    ack_webext_action: bool = false,
    ack_webext_transaction: bool = false,
    ack_multi_client: bool = false,
    ack_presenter: bool = false,
    ack_flush: bool = false,
    /// Bumped per `ev_flushed`; the token it carried.
    flushed_seq: u32 = 0,
    last_flush_token: u32 = 0,

    /// Last `ev_net_policy` observed (the multi-client budget stage),
    /// plus a pinned probe: dirty policy status streams one frame per
    /// view, so "the last event" is not "the answer to my question" —
    /// a stage asks about ONE view by setting `pol_probe_view` first.
    pol_seq: u32 = 0,
    pol_view: u32 = 0,
    pol_serial: u32 = 0,
    pol_active: u8 = 0xff,
    pol_probe_view: u32 = 0,
    pol_probe_seq: u32 = 0,
    pol_probe_active: u8 = 0xff,
    pol_probe_serial: u32 = 0,

    action_seq: u32 = 0,
    action_view: u32 = 0,
    action_json: [4096]u8 = @splat(0),
    action_json_len: usize = 0,
    ext_popup_seq: u32 = 0,
    ext_popup_owner: u32 = 0,
    ext_popup_view: u32 = 0,
    ext_popup_state: u8 = 0,
    ext_popup_detail: [2048]u8 = @splat(0),
    ext_popup_detail_len: usize = 0,
    ext_popup_fb: ?proto.FrameBuffer = null,
    ext_popup_fb_fd: c_int = -1,
    ext_popup_fb_seq: u32 = 0,
    ext_popup_dmg_seq: u32 = 0,
    open_popup_seq: u32 = 0,
    open_popup_view: u32 = 0,
    open_popup_req: u32 = 0,
    open_popup_id: [64]u8 = @splat(0),
    open_popup_id_len: usize = 0,

    /// Last `ev_webext_state` observed (one extension in the stage).
    we_seq: u32 = 0,
    we_ok: u8 = 0xff,
    we_enabled: u8 = 0xff,
    we_name: [128]u8 = @splat(0),
    we_name_len: usize = 0,
    we_err: [256]u8 = @splat(0),
    we_err_len: usize = 0,
    we_prepare_seq: u32 = 0,
    we_prepare_req: u32 = 0,
    we_prepare_ok: u8 = 0xff,
    we_prepare_err: [128]u8 = @splat(0),
    we_prepare_err_len: usize = 0,

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
    /// View id the last `ev_title` named — under multi-client this must
    /// arrive in the CLIENT's namespace, so the stage asserts on it.
    title_view: u32 = 0,

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
    view_create_fail_seq: u32 = 0,
    view_create_fail_view: u32 = 0,
    view_create_fail_context: u32 = 0,
    view_create_fail_reason: [128]u8 = @splat(0),
    view_create_fail_reason_len: usize = 0,

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
    rich_doc: u32 = 0,
    rich_rev: u32 = 0,
    rich_id: u32 = 0,
    rich_guard: u64 = 0,
    rich_kind: [32]u8 = @splat(0),
    rich_kind_len: usize = 0,
    rich_text: [256]u8 = @splat(0),
    rich_text_len: usize = 0,
    sem_result_request: u32 = 0,

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
    sub_done_seq: u32 = 0,
    sub_serial: u32 = 0,
    sub_active: u16 = 0,
    sub_fetched: u16 = 0,
    sub_updated: u16 = 0,
    sub_failed: u16 = 0,
    sub_rules: u32 = 0,
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
    ack_a11y_caret: bool = false,
    ack_sitedata: bool = false,
    ack_cookie_sync: bool = false,
    /// Stage 41 only; null everywhere else.
    ck: ?*CkState = null,
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
    /// The same mirror the GUI keeps, so a stage can resolve a node's
    /// absolute rect exactly the way the projection does.
    ax_mirror: axtree.Tree = undefined,
    ax_mirror_live: bool = false,
    ax_caret_seq: u32 = 0,
    ax_caret_focus_id: u32 = 0,
    ax_caret_focus_off: i32 = 0,
    ax_caret_anchor_off: i32 = 0,
    /// The last NON-COLLAPSED caret seen. A selection assertion must
    /// not depend on the final state: focusing a field and selecting
    /// in it produces several caret frames, and the engine may well
    /// collapse again afterwards.
    ax_sel_seen: bool = false,
    ax_sel_anchor: i32 = 0,
    ax_sel_focus: i32 = 0,
    /// Every caret frame as one line, so a failure can show what the
    /// engine actually reported instead of just the last value.
    ax_caret_log: [4 * 1024]u8 = @splat(0),
    ax_caret_log_len: usize = 0,
    /// Only context teardown enables this: CEF may terminate on a signal
    /// after the last context-backed browser closes, which the stage's
    /// tolerant reaper already accepts.
    teardown_allow_close: bool = false,

    fn deinit(self: *Client) void {
        if (self.ax_mirror_live) {
            self.ax_mirror.deinit();
            self.ax_mirror_live = false;
        }
        if (self.inline_pix.len != 0) self.gpa.free(self.inline_pix);
        self.unmap();
        if (self.fb_fd >= 0) _ = c.close(self.fb_fd);
        if (self.dev_fb_fd >= 0) _ = c.close(self.dev_fb_fd);
        if (self.ext_popup_fb_fd >= 0) _ = c.close(self.ext_popup_fb_fd);
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

    fn sendSemantic(self: *Client, request: u32, value: anytype) void {
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.gpa);
        proto.encodePayload(self.gpa, &payload, value) catch fail("semantic payload encode");
        self.send(proto.SemRequest{
            .request = request,
            .kind = @intFromEnum(@TypeOf(value).tag),
            .payload = .{ .s = payload.items },
        });
    }

    /// Ask the helper for one frame, at most `min_gap_us` after the
    /// previous request.
    fn frameRequest(self: *Client, min_gap_us: i64) void {
        if (!self.have_view or self.fd < 0) return;
        const now = nowUs();
        if (now - self.last_req_us < min_gap_us) return;
        self.last_req_us = now;
        self.req_count += 1;
        self.send(proto.FrameRequest{ .view = view_id, .flags = 0 });
        // An inspector is an ordinary view: it paints when somebody
        // asks, exactly like the page it inspects.
        if (self.dev_view != 0) self.send(proto.FrameRequest{ .view = self.dev_view, .flags = 0 });
        if (self.ext_popup_view != 0 and self.ext_popup_state == proto.webext_popup_opened)
            self.send(proto.FrameRequest{ .view = self.ext_popup_view, .flags = 0 });
    }

    /// Wait for helper output while driving frames at ~120Hz — what the
    /// GUI's active tick does, and what every stage below needs in
    /// order to see any paint at all.
    fn pump(self: *Client, timeout_ms: c_int) void {
        if (self.fd < 0) return;
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
        if (n == 0) {
            if (self.teardown_allow_close) {
                _ = c.close(self.fd);
                self.fd = -1;
                return false;
            }
            fail("helper closed the socket");
        }
        if (n < 0) {
            const e = std.c._errno().*;
            if (e == c.EINTR or e == c.EAGAIN) return false;
            if (self.teardown_allow_close and (e == c.ECONNRESET or e == c.EPIPE)) {
                _ = c.close(self.fd);
                self.fd = -1;
                return false;
            }
            std.debug.print("smoke-web: recvmsg errno {d} on client fd {d}\n", .{ e, self.fd });
            if (g_pid > 0) {
                var st: c_int = 0;
                const r = c.waitpid(g_pid, &st, c.WNOHANG);
                if (r == g_pid) {
                    std.debug.print("smoke-web: helper pid {d} exited, status 0x{x} (signal {d})\n", .{ g_pid, st, st & 0x7f });
                } else {
                    std.debug.print("smoke-web: helper pid {d} still alive after the reset\n", .{g_pid});
                }
            }
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
                    if (std.mem.eql(u8, cap, proto.CAP_READER_IDS)) self.ack_reader_ids = true;
                    if (std.mem.eql(u8, cap, proto.CAP_SEMANTIC_REQUEST_IDS)) self.ack_semantic_request_ids = true;
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
                    if (std.mem.eql(u8, cap, proto.CAP_A11Y_CARET)) self.ack_a11y_caret = true;
                    if (std.mem.eql(u8, cap, proto.CAP_CONTEXTS)) self.ack_contexts = true;
                    if (std.mem.eql(u8, cap, proto.CAP_CONTEXTS_FAIL_CLOSED)) self.ack_contexts_fail_closed = true;
                    if (std.mem.eql(u8, cap, proto.CAP_USERSCRIPTS)) self.ack_userscripts = true;
                    if (std.mem.eql(u8, cap, proto.CAP_SITEDATA)) self.ack_sitedata = true;
                    if (std.mem.eql(u8, cap, proto.CAP_COOKIE_SYNC)) self.ack_cookie_sync = true;
                    if (std.mem.eql(u8, cap, proto.CAP_FRAMES_INLINE)) self.ack_frames_inline = true;
                    if (std.mem.eql(u8, cap, proto.CAP_WEBEXT)) self.ack_webext = true;
                    if (std.mem.eql(u8, cap, proto.CAP_WEBEXT_TABS)) self.ack_webext_tabs = true;
                    if (std.mem.eql(u8, cap, proto.CAP_FILTER_SUBSCRIBE)) self.ack_filter_subscribe = true;
                    if (std.mem.eql(u8, cap, proto.CAP_WEBEXT_ACTION)) self.ack_webext_action = true;
                    if (std.mem.eql(u8, cap, proto.CAP_WEBEXT_TRANSACTION)) self.ack_webext_transaction = true;
                    if (std.mem.eql(u8, cap, proto.CAP_MULTI_CLIENT)) self.ack_multi_client = true;
                    if (std.mem.eql(u8, cap, proto.CAP_PRESENTER)) self.ack_presenter = true;
                    if (std.mem.eql(u8, cap, proto.CAP_FLUSH)) self.ack_flush = true;
                }
            },
            .ev_flushed => {
                const f = proto.decode(proto.EvFlushed, frame.payload) catch fail("ev_flushed decode");
                self.last_flush_token = f.token;
                self.flushed_seq += 1;
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
                if (!self.ax_mirror_live) {
                    self.ax_mirror = axtree.Tree.init(self.gpa);
                    self.ax_mirror_live = true;
                }
                // A dropped tree leaves the mirror STALE, and stages 22k
                // and 36 then assert against the previous snapshot and
                // pass for the wrong reason.
                self.ax_mirror.applyTree(ev) catch |e| {
                    std.debug.print(
                        "smoke-web: ev_a11y_tree #{d} (view {d}, root {d}, {d} node bytes) rejected: {s}\n",
                        .{ self.ax_seq, ev.view, ev.root_id, ev.nodes.s.len, @errorName(e) },
                    );
                    fail("ev_a11y_tree could not be applied to the mirror");
                };
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
            .ev_cookie_change => {
                const ev = proto.decode(proto.EvCookieChange, frame.payload) catch fail("ev_cookie_change decode");
                const st = self.ck orelse return;
                st.seq += 1;
                var e: CkCookie = .{};
                e.fill(ev.cookie);
                e.context = ev.context;
                e.cause = ev.cause;
                e.removed = ev.removed;
                CkCookie.put(&e.url, &e.url_len, ev.url);
                st.q[st.head] = e;
                st.head = (st.head + 1) % st.q.len;
            },
            .ev_cookie_apply_done => {
                const ev = proto.decode(proto.EvCookieApplyDone, frame.payload) catch fail("ev_cookie_apply_done decode");
                const st = self.ck orelse return;
                st.apply_seq += 1;
                st.apply_req = ev.req;
                st.apply_ok = ev.ok;
                st.apply_reason_len = @min(ev.reason.len, st.apply_reason.len);
                @memcpy(st.apply_reason[0..st.apply_reason_len], ev.reason[0..st.apply_reason_len]);
            },
            .ev_cookie_dump => {
                const ev = proto.EvCookieDump.decodeAlloc(frame.payload, self.gpa) catch fail("ev_cookie_dump decode");
                defer self.gpa.free(ev.cookies);
                const st = self.ck orelse return;
                st.dump_seq += 1;
                st.dump_req = ev.req;
                st.dump_ok = ev.ok;
                st.dump_cursor = ev.cursor;
                st.dump_next = ev.next_cursor;
                st.dump_more = ev.more;
                st.dump_total = ev.total;
                st.dump_n = @min(ev.cookies.len, st.dump.len);
                for (ev.cookies[0..st.dump_n], 0..) |ck, i| {
                    st.dump[i] = .{};
                    st.dump[i].fill(ck);
                    st.dump[i].context = ev.context;
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
            .ev_a11y_caret => {
                const ev = proto.decode(proto.EvA11yCaret, frame.payload) catch fail("ev_a11y_caret decode");
                self.ax_caret_seq += 1;
                self.ax_caret_focus_id = ev.focus_id;
                self.ax_caret_focus_off = ev.focus_offset;
                self.ax_caret_anchor_off = ev.anchor_offset;
                if (ev.anchor_offset != ev.focus_offset or ev.anchor_id != ev.focus_id) {
                    self.ax_sel_seen = true;
                    self.ax_sel_anchor = ev.anchor_offset;
                    self.ax_sel_focus = ev.focus_offset;
                }
                var cline: [128]u8 = undefined;
                const cs = std.fmt.bufPrint(&cline, "a={d}@{d} f={d}@{d}\n", .{
                    ev.anchor_id, ev.anchor_offset, ev.focus_id, ev.focus_offset,
                }) catch "";
                const croom = self.ax_caret_log.len - self.ax_caret_log_len;
                const ctake = @min(croom, cs.len);
                @memcpy(self.ax_caret_log[self.ax_caret_log_len..][0..ctake], cs[0..ctake]);
                self.ax_caret_log_len += ctake;
                if (self.ax_mirror_live) self.ax_mirror.applyCaret(ev);
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
                if (fb.view >= proto.WEBEXT_POPUP_VIEW_BASE) {
                    if (self.ext_popup_fb_fd >= 0) _ = c.close(self.ext_popup_fb_fd);
                    self.ext_popup_fb_fd = fd;
                    self.ext_popup_fb = fb;
                    self.ext_popup_fb_seq += 1;
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
                if (self.ext_popup_view != 0 and d.view == self.ext_popup_view) {
                    self.ext_popup_dmg_seq += 1;
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
                self.we_seq += 1;
            },
            .ev_webext_install_prepared => {
                const ev = proto.decode(proto.EvWebextInstallPrepared, frame.payload) catch fail("ev_webext_install_prepared decode");
                self.we_prepare_req = ev.req;
                self.we_prepare_ok = ev.ok;
                self.we_prepare_err_len = @min(ev.err.len, self.we_prepare_err.len);
                @memcpy(self.we_prepare_err[0..self.we_prepare_err_len], ev.err[0..self.we_prepare_err_len]);
                self.we_prepare_seq += 1;
            },
            .ev_webext_actions => {
                const ev = proto.decode(proto.EvWebextActions, frame.payload) catch fail("ev_webext_actions decode");
                self.action_view = ev.view;
                self.action_json_len = @min(ev.actions_json.len, self.action_json.len);
                @memcpy(self.action_json[0..self.action_json_len], ev.actions_json[0..self.action_json_len]);
                self.action_seq += 1;
            },
            .ev_webext_popup => {
                const ev = proto.decode(proto.EvWebextPopup, frame.payload) catch fail("ev_webext_popup decode");
                self.ext_popup_owner = ev.owner_view;
                self.ext_popup_view = ev.popup_view;
                self.ext_popup_state = ev.state;
                self.ext_popup_detail_len = @min(ev.detail.len, self.ext_popup_detail.len);
                @memcpy(self.ext_popup_detail[0..self.ext_popup_detail_len], ev.detail[0..self.ext_popup_detail_len]);
                self.ext_popup_seq += 1;
            },
            .ev_webext_open_popup => {
                const ev = proto.decode(proto.EvWebextOpenPopup, frame.payload) catch fail("ev_webext_open_popup decode");
                self.open_popup_view = ev.view;
                self.open_popup_req = ev.req;
                self.open_popup_id_len = @min(ev.id.len, self.open_popup_id.len);
                @memcpy(self.open_popup_id[0..self.open_popup_id_len], ev.id[0..self.open_popup_id_len]);
                self.open_popup_seq += 1;
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
            .ev_console => {
                // Only echoed when asked for. A WebExtensions failure is
                // almost always a page-console error inside the
                // background page, which is otherwise invisible: the
                // page is hidden and never announced.
                if (g_echo_console) {
                    const m = proto.decode(proto.EvConsole, frame.payload) catch return;
                    std.debug.print("  [console v{d} l{d}] {s}\n", .{ m.view, m.level, m.msg });
                }
            },
            .ev_title => {
                const t = proto.decode(proto.EvTitle, frame.payload) catch fail("ev_title decode");
                self.title_view = t.view;
                self.title_len = @min(t.title.len, self.title.len);
                @memcpy(self.title[0..self.title_len], t.title[0..self.title_len]);
            },
            .ev_net_policy => {
                const p = proto.decode(proto.EvNetPolicy, frame.payload) catch fail("ev_net_policy decode");
                self.pol_seq += 1;
                self.pol_view = p.view;
                self.pol_serial = p.serial;
                self.pol_active = p.active;
                if (p.view == self.pol_probe_view) {
                    self.pol_probe_seq += 1;
                    self.pol_probe_active = p.active;
                    self.pol_probe_serial = p.serial;
                }
            },
            .ev_popup_request => {
                const p = proto.decode(proto.EvPopupRequest, frame.payload) catch fail("ev_popup_request decode");
                self.popup_view = p.view;
                self.popup_gesture = p.user_gesture;
                self.popup_len = @min(p.url.len, self.popup_url.len);
                @memcpy(self.popup_url[0..self.popup_len], p.url[0..self.popup_len]);
            },
            .sem_result => {
                const result = proto.decode(proto.SemResult, frame.payload) catch fail("sem_result decode");
                self.sem_result_request = result.request;
                self.handle(.{ .tag = @enumFromInt(result.kind), .payload = result.payload.s });
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
            .sem_read_ids_result => {
                const r = proto.SemReadIdsResult.decodeAlloc(frame.payload, self.gpa) catch fail("sem_read_ids_result decode");
                defer self.gpa.free(r.entities);
                self.md_len = @min(r.markdown.s.len, self.md.len);
                @memcpy(self.md[0..self.md_len], r.markdown.s[0..self.md_len]);
                self.rich_doc = r.doc_gen;
                self.rich_rev = r.rev;
                self.rich_id = 0;
                for (r.entities) |entity| {
                    if (!std.mem.eql(u8, entity.text, "Activate Reader Target")) continue;
                    self.rich_id = entity.id;
                    self.rich_guard = entity.guard;
                    self.rich_kind_len = @min(entity.kind.len, self.rich_kind.len);
                    @memcpy(self.rich_kind[0..self.rich_kind_len], entity.kind[0..self.rich_kind_len]);
                    self.rich_text_len = @min(entity.text.len, self.rich_text.len);
                    @memcpy(self.rich_text[0..self.rich_text_len], entity.text[0..self.rich_text_len]);
                }
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
                const e = proto.decode(proto.EvLoadError, frame.payload) catch fail("ev_load_error decode");
                self.load_err_seq += 1;
                if (g_echo_console) {
                    std.debug.print("  [load-error v{d} code {d}] {s}: {s}\n", .{ e.view, e.code, e.url, e.msg });
                }
            },
            .ev_view_create_failed => {
                const e = proto.decode(proto.EvViewCreateFailed, frame.payload) catch fail("ev_view_create_failed decode");
                self.view_create_fail_view = e.view;
                self.view_create_fail_context = e.context;
                self.view_create_fail_reason_len = @min(e.reason.len, self.view_create_fail_reason.len);
                @memcpy(self.view_create_fail_reason[0..self.view_create_fail_reason_len], e.reason[0..self.view_create_fail_reason_len]);
                self.view_create_fail_seq += 1;
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
            .ev_intercept_subscribe_done => {
                const d = proto.decode(proto.EvInterceptSubscribeDone, frame.payload) catch fail("ev_intercept_subscribe_done decode");
                self.sub_serial = d.serial;
                self.sub_active = d.active;
                self.sub_fetched = d.fetched;
                self.sub_updated = d.updated;
                self.sub_failed = d.failed;
                self.sub_rules = d.rules;
                self.sub_done_seq += 1;
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
        return self.evalWaitView(view_id, code, want_await, timeout_ms);
    }

    fn evalWaitView(self: *Client, view: u32, code: []const u8, want_await: bool, timeout_ms: i64) []const u8 {
        const seq = self.eval_seq;
        self.send(proto.SemEval{
            .view = view,
            .flags = if (want_await) proto.eval_flag_await else 0,
            .timeout_ms = 5000,
            .code = .{ .s = code },
        });
        if (!self.waitSeq(&self.eval_seq, seq, timeout_ms)) fail("no sem_eval_result");
        return self.evalPayload();
    }

    /// Post the whole tab list (`webext_tabs`), the seam that makes
    /// `browser.tabs` and `sender.tab` real. Replace-all by design.
    fn sendTabs(self: *Client, tabs: []const TabSpec) void {
        var buf: [4096]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        w.writeByte('[') catch return;
        for (tabs, 0..) |t, i| {
            if (i != 0) w.writeByte(',') catch return;
            w.print(
                "{{\"id\":{d},\"view\":{d},\"windowId\":0,\"index\":{d},\"active\":{s},\"focusedWindow\":true,\"url\":\"{s}\",\"title\":\"{s}\",\"loading\":false}}",
                .{ t.id, t.view, i, if (t.active) "true" else "false", t.url, t.title },
            ) catch return;
        }
        w.writeByte(']') catch return;
        self.send(proto.WebextTabs{ .tabs_json = buf[0..w.end] });
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

    fn subscribeWait(self: *Client, hours: u32, urls: []const []const u8, timeout_ms: i64) bool {
        const seq = self.sub_done_seq;
        self.send(proto.InterceptSubscribe{ .update_hours = hours, .urls = urls });
        return self.waitSeq(&self.sub_done_seq, seq, timeout_ms);
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
/// A node id from the mirrored tree by role and (optionally) name.
/// An empty `name` matches the first node of that role.
fn axFindNode(cl: *Client, role: []const u8, name: []const u8) u32 {
    if (!cl.ax_mirror_live) return 0;
    var it = cl.ax_mirror.nodes.iterator();
    while (it.next()) |e| {
        const n = e.value_ptr;
        if (!std.mem.eql(u8, n.role, role)) continue;
        if (name.len != 0 and !std.mem.eql(u8, n.name, name)) continue;
        return n.id;
    }
    return 0;
}

/// Absolute rect of a node, resolved through the offset-container
/// chain — the same walk `a11y/webproj.zig` does for GetExtents, which
/// is what a projected press aims at.
fn axAbsRect(tree: *const axtree.Tree, id: u32) ?[4]i32 {
    const n = tree.get(id) orelse return null;
    var x = n.x;
    var y = n.y;
    var cur = n.offset_container;
    var depth: u32 = 0;
    while (cur != 0 and depth < 64) : (depth += 1) {
        const p = tree.get(cur) orelse break;
        x += p.x;
        y += p.y;
        cur = p.offset_container;
    }
    return .{ x, y, n.w, n.h };
}

fn axLineState(log: []const u8, needle: []const u8) ?u64 {
    const at = std.mem.indexOf(u8, log, needle) orelse return null;
    const s_at = std.mem.indexOfPos(u8, log, at, " s=") orelse return null;
    const start = s_at + 3;
    const end = std.mem.indexOfScalarPos(u8, log, start, '\n') orelse log.len;
    return std.fmt.parseInt(u64, log[start..end], 16) catch null;
}

/// Connect to the helper's socket, retrying while it starts CEF up.
fn connectWithRetry(path: [*:0]const u8, path_len: usize) c_int {
    return unixsock.connectWithRetry(path, path_len, g_pid, 60_000) catch |e| switch (e) {
        error.PathTooLong => fail("socket path too long"),
        error.Socket => fail("socket"),
        error.PeerExited => fail("helper exited before it listened"),
        error.Timeout => fail("timed out connecting to the helper"),
    };
}

/// Fork+exec one helper. `extra` is a single additional argv entry (the
/// ozone pin, or "--disable-gpu"), and `no_gpu` sets the environment
/// switch that makes the helper refuse the GPU path outright.
///
/// Stripping the inherited proxy environment is not optional: every
/// fixture this rig serves is on loopback, and a developer environment
/// that exports `HTTP_PROXY` / `HTTPS_PROXY` sends them through it.
/// Chromium's implicit bypass covers a literal `127.0.0.1` url but NOT a
/// named host mapped there by `--host-resolver-rules`, so the https
/// fixtures lose their TLS handshake to a CONNECT the proxy cannot
/// complete and no certificate error ever reaches the client (stage 40).
/// It is done by environment rather than with `--no-proxy-server`
/// because that switch also disables the INSTANCE proxy (`--proxy`)
/// stage 26 configures, and this rig has to test proxying while not
/// being proxied itself.
/// Drop an inherited proxy environment in the forked child (see the
/// docblock above); one home for both spawners.
fn scrubProxyEnv() void {
    for ([_][*:0]const u8{
        "http_proxy", "https_proxy", "all_proxy", "ftp_proxy", "no_proxy",
        "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "FTP_PROXY", "NO_PROXY",
    }) |name| _ = c.unsetenv(name);
}

fn spawnHelper(
    exe: [*:0]const u8,
    sock: [*:0]const u8,
    cache: [*:0]const u8,
    extra: ?[*:0]const u8,
    extra2: ?[*:0]const u8,
    no_gpu: bool,
) c.pid_t {
    const pid = c.fork();
    if (pid < 0) fail("fork");
    if (pid != 0) return pid;
    if (no_gpu) _ = c.setenv("SKETERM_WEB_GPU", "0", 1);
    scrubProxyEnv();
    var vec: [10:null]?[*:0]const u8 = @splat(null);
    var n: usize = 0;
    for ([_]?[*:0]const u8{ exe, "--socket", sock, "--cache-dir", cache, extra, extra2 }) |a| {
        if (a) |arg| {
            vec[n] = arg;
            n += 1;
        }
    }
    _ = c.execv(exe, @ptrCast(@constCast(&vec)));
    c._exit(127);
    unreachable;
}

/// Pump `cl` until `probe` records a CONNECT for `expected`. A probe
/// keeps only its FIRST CONNECT, so a stale one (a retry of the page
/// before) is discarded by re-arming until the expected host lands or
/// the deadline passes.
fn waitProbeHost(probe: *ProxyProbe, cl: *Client, expected: []const u8, timeout_ms: i64) bool {
    const deadline = nowMs() + timeout_ms;
    while (nowMs() < deadline) {
        if (probe.seenHost()) |h| {
            if (std.mem.eql(u8, h, expected)) return true;
            std.debug.print("smoke-web: proxy saw \"{s}\" while waiting for \"{s}\"; re-arming\n", .{ h, expected });
            probe.arm();
        }
        cl.pump(100);
    }
    return false;
}

/// Bring a helper down by EXACT pid after its client disconnected.
fn reapHelper(pid: c.pid_t, what: []const u8) void {
    reapHelperTimeout(pid, what, 10_000);
}

/// Reap by exact pid and demand a CLEAN death: neither a signal nor a
/// nonzero exit code, within `timeout_ms` of the client disconnect.
///
/// There is deliberately no signal-tolerating variant: a helper dying on
/// a signal is never expected, because `cef_shutdown` (a `defer` around
/// `srv.run()` in `src/web/main.zig`) cannot run after a crash. The
/// tolerant reap that used to stand here read a use-after-free in our own
/// helper as a CEF shutdown artifact and printed PASS over SIGSEGV on
/// nine separate days.
fn reapHelperTimeout(pid: c.pid_t, what: []const u8, timeout_ms: i64) void {
    const deadline = nowMs() + timeout_ms;
    var status: c_int = 0;
    while (nowMs() < deadline) {
        if (c.waitpid(pid, &status, c.WNOHANG) == pid) {
            g_pid = -1;
            if (status & 0x7f != 0) {
                std.debug.print("smoke-web: {s}: helper signal {d}\n", .{ what, status & 0x7f });
                say(what);
                fail("helper died on a signal");
            }
            if ((status >> 8) & 0xff != 0) {
                std.debug.print("smoke-web: {s}: helper exit code {d}\n", .{ what, (status >> 8) & 0xff });
                say(what);
                fail("helper exited nonzero");
            }
            return;
        }
        _ = c.usleep(50_000);
    }
    say(what);
    fail("helper did not exit within its budget of the disconnect");
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
    // The document the two stages load. It has to be a REAL file
    // served over TLS, because a permission prompt needs a secure
    // context and a `data:` url is not one.
    if (!writeFile(dir, "geo.html", geo_page)) fail("cannot write geo.html");
    const server = smoke_tls.start(dir) orelse {
        say("smoke-web: SKIP stage 22f bad certificate (no usable openssl s_server on this host)");
        return;
    };
    defer server.stop();

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
    // MEASURED divergence (2026-08-20): on macOS the same engine DOES
    // consult the client — `ev_permission` arrives for this geolocation
    // request — so there the stage is the real round trip the comment
    // above promised: answer DENY, and the page must still end at
    // PERMISSION_DENIED (code 1). Linux keeps the pin.
    if (builtin.os.tag == .macos) {
        var pwait: Past = .{ .cl = cl, .base = 0 };
        if (!driveUntil(cl, 15_000, &pwait, struct {
            fn f(w: *Past) bool {
                return w.cl.perm_seq > 0;
            }
        }.f)) fail("stage 22g: no ev_permission for a secure-context geolocation call");
        cl.send(proto.PermissionDecision{ .view = view_id, .prompt = cl.perm_id, .allow = 0 });
        var twait: Past = .{ .cl = cl, .base = 0 };
        if (!driveUntil(cl, 15_000, &twait, struct {
            fn f(w: *Past) bool {
                return std.mem.eql(u8, w.cl.title[0..w.cl.title_len], "geo:err1");
            }
        }.f)) {
            std.debug.print("smoke-web: title was '{s}'\n", .{cl.title[0..cl.title_len]});
            fail("stage 22g: a DENIED geolocation request did not end in PERMISSION_DENIED");
        }
        pass("stage 22g permission request (client consulted, denied, page sees code 1)");
    } else {
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
    }

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
    lis: tcpserver.Listener = .{ .backlog = 64, .poll_ms = 100 },
    page_a: []const u8 = "",
    page_b: []const u8 = "",
    page_c: []const u8 = "",
    /// Set if `/blockme` was ever requested — a CANCEL must mean the
    /// request never reached the network, not merely that the page saw
    /// an error.
    blockme_hits: std.atomic.Value(u32) = .init(0),

    fn start(self: *WreqServer) bool {
        return self.lis.start(self, &onConn);
    }

    fn onConn(ctx: ?*anyopaque, afd: c_int) bool {
        const self: *WreqServer = @ptrCast(@alignCast(ctx.?));
        self.handle(afd);
        return false;
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

        tcpserver.respondOk(afd, ctype, body, tcpserver.CORS ++ "X-Stage: 34\r\n");
    }

    fn deinit(self: *WreqServer) void {
        self.lis.deinit();
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
    srv.page_a = wqPageA(&pa_buf, srv.lis.port);
    srv.page_b = wqPageHang(&pb_buf, srv.lis.port, "/hangme", "wq-b");
    srv.page_c = wqPageHang(&pc_buf, srv.lis.port, "/slowme", "wq-c");

    var url_a: [96]u8 = undefined;
    var url_b: [96]u8 = undefined;
    var url_c: [96]u8 = undefined;
    const page_a = std.fmt.bufPrint(&url_a, "http://127.0.0.1:{d}/pa", .{srv.lis.port}) catch fail("url");
    const page_b = std.fmt.bufPrint(&url_b, "http://127.0.0.1:{d}/pb", .{srv.lis.port}) catch fail("url");
    const page_c = std.fmt.bufPrint(&url_c, "http://127.0.0.1:{d}/pc", .{srv.lis.port}) catch fail("url");

    const ext_id = "wreqfixture01";

    // ── Helper 1: a deliberately LONG fail-open deadline, so that in
    // 34b it is unambiguously the REMOVAL, and not the timeout, that
    // released the held request.
    {
        _ = c.setenv("SKETERM_WEB_WREQ_TIMEOUT_MS", "20000", 1);
        var sock_buf: [96]u8 = undefined;
        const sock = std.fmt.bufPrintZ(&sock_buf, "{s}/wq1.sock", .{dir}) catch fail("stage 34 sock");
        const pid = spawnHelper(exe, sock.ptr, cache_dir.ptr, "--ozone-platform=headless", null, false);
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
        reapHelperTimeout(pid, "stage 34 helper 1", 30_000);
    }

    // ── Helper 2: a SHORT fail-open deadline, so the timeout itself is
    // what releases the request — and releases it open.
    {
        _ = c.setenv("SKETERM_WEB_WREQ_TIMEOUT_MS", "400", 1);
        var sock_buf: [96]u8 = undefined;
        const sock = std.fmt.bufPrintZ(&sock_buf, "{s}/wq2.sock", .{dir}) catch fail("stage 34 sock2");
        const pid = spawnHelper(exe, sock.ptr, cache_dir.ptr, "--ozone-platform=headless", null, false);
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
        reapHelperTimeout(pid, "stage 34 helper 2", 30_000);
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
    var reject_buf: [4096]u8 = undefined;
    const reject_dir = std.fmt.bufPrintZ(&reject_buf, "{s}/we-reject", .{dir}) catch fail("webext reject path");
    mkdirZ(reject_dir);
    if (!writeFile(reject_dir, "manifest.json", fx_manifest)) fail("stage 33 webext: could not write reject fixture");
    // The helper reads XDG_DATA_HOME for its per-extension storage; a
    // child inherits this, and both runs share it so storage persists.
    _ = c.setenv("XDG_DATA_HOME", data_dir.ptr, 1);

    var srv = HttpProbe{ .body = webext_page };
    if (!srv.start()) fail("stage 33 webext: loopback HTTP server would not start");
    defer srv.shutdown();
    var page_buf: [96]u8 = undefined;
    const page_url = std.fmt.bufPrint(&page_buf, "http://127.0.0.1:{d}/p", .{srv.lis.port}) catch fail("webext url");

    const ext_id = "smokefixture01";

    // ── Run 1: injection + messaging ──────────────────────────────
    {
        var sock_buf: [96]u8 = undefined;
        const sock = std.fmt.bufPrintZ(&sock_buf, "{s}/we1.sock", .{dir}) catch fail("webext sock");
        const pid = spawnHelper(exe, sock.ptr, cache_dir.ptr, "--ozone-platform=headless", null, false);
        var cl = Client{ .gpa = gpa, .fd = connectWithRetry(sock.ptr, sock.len) };
        cl.send(proto.Hello{ .proto = proto.PROTO_VERSION, .client_name = "smoke-web" });
        {
            const d = nowMs() + 15_000;
            while (cl.ack_proto == 0 and nowMs() < d) cl.pump(100);
        }
        if (!cl.ack_webext) fail("stage 33 webext: hello_ack lacks the webext capability");
        if (!cl.ack_webext_transaction) fail("stage 33 webext: hello_ack lacks the webext transaction capability");

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

        // The candidate has a valid matching manifest but none of its
        // declared assets. The helper must reject it before quiescing the
        // currently running extension.
        const prepare_before = cl.we_prepare_seq;
        cl.send(proto.WebextInstallPrepare{
            .req = 901,
            .id = ext_id,
            .dir = reject_dir,
            .version = "1.0",
        });
        {
            const d = nowMs() + 5_000;
            while (cl.we_prepare_seq == prepare_before and nowMs() < d) cl.pump(100);
        }
        if (cl.we_prepare_seq == prepare_before or cl.we_prepare_req != 901 or
            cl.we_prepare_ok != 0 or cl.we_prepare_err_len == 0)
            fail("stage 33 webext: invalid staged upgrade was not refused");
        cl.we_ok = 0xff;
        cl.send(proto.WebextListReq{});
        {
            const d = nowMs() + 5_000;
            while (cl.we_ok == 0xff and nowMs() < d) cl.pump(100);
        }
        if (cl.we_ok != 1 or cl.we_enabled != 1)
            fail("stage 33 webext: helper refusal disturbed the working extension");
        pass("stage 33c transactional helper refusal preserves the working extension");

        // A head start for the background page, NOT the guarantee: the
        // fixture's content script retries its sendMessage until the
        // background answers, because "the listener exists by now" is a
        // wall-clock bet that loses on a loaded machine (observed as
        // `reply:null:hello` — i18n and storage fine, reply missing).
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
        reapHelperTimeout(pid, "stage 33 webext run 1", 30_000);
    }

    // ── Run 2: storage.local persisted across the restart ─────────
    {
        var sock_buf: [96]u8 = undefined;
        const sock = std.fmt.bufPrintZ(&sock_buf, "{s}/we2.sock", .{dir}) catch fail("webext sock2");
        const pid = spawnHelper(exe, sock.ptr, cache_dir.ptr, "--ozone-platform=headless", null, false);
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
        if (!cl.waitTitle("stored:v1:rotated", 25_000)) {
            std.debug.print("stage 33: title was \"{s}\"\n", .{cl.titleSlice()});
            fail("stage 33 webext: storage did not persist or the helper reused an extension capability");
        }
        pass("stage 33 webext run 2 (storage.local persisted and capability rotated across helper restart)");

        cl.send(proto.WebextRemove{ .id = ext_id });
        cl.send(proto.ViewDestroy{ .view = view_id });
        cl.have_view = false;
        {
            const d = nowMs() + 2500;
            while (nowMs() < d) cl.pump(50);
        }
        cl.deinit(); // close the socket so the helper disconnects and exits
        reapHelperTimeout(pid, "stage 33 webext run 2", 30_000);
    }
}

// ---------------------------------------------------------------------
// Stage 40: browser-action toolbar activations and extension popups
// ---------------------------------------------------------------------

const action_manifest =
    \\{"manifest_version":2,"name":"sketerm action fixture","version":"1",
    \\ "browser_specific_settings":{"gecko":{"id":"action@sketerm.test"}},
    \\ "permissions":["tabs"],
    \\ "background":{"scripts":["bg.js"],"persistent":true},
    \\ "content_scripts":[{"matches":["http://127.0.0.1/*"],"js":["probe.js"]}],
    \\ "browser_action":{"default_title":"Action Default","default_popup":"popup.html"}}
;

const action_bg =
    \\async function securityChecks() {
    \\  var helperRejected = false, unsupportedRejected = false, impersonationRejected = false;
    \\  try { await browser.tabs.get(4294967295); } catch (e) { helperRejected = String(e).includes("no such tab"); }
    \\  try { await browser.windows.getCurrent(); } catch (e) { unsupportedRejected = String(e).includes("windows.getCurrent is not supported"); }
    \\  try {
    \\    var source = await (await fetch(browser.runtime.getURL("__sketerm-extapi.js"))).text();
    \\    var tok = source.match(/tok:"([0-9a-f]{32})"/);
    \\    var cap = source.match(/,cap:"([0-9a-f]{32})"/);
    \\    var slot = source.match(/window\["([0-9a-f]{32})"\]/);
    \\    if (!tok || !cap || !slot || typeof window[slot[1]] !== "function") throw new Error("bootstrap parse");
    \\    window.__sketermImpersonation = "pending";
    \\    var attack = "browser.storage.local.set({stolen:true}).then(function(){window.__sketermImpersonation='resolved'},function(e){window.__sketermImpersonation='rejected:'+String(e)})";
    \\    window[slot[1]](JSON.stringify({op:"ext-inject",tok:tok[1],ext:"click@sketerm.test",cap:cap[1],base:browser.runtime.getURL(""),manifest:{},scripts:[attack],css:[]}));
    \\    for (var i=0;i<100 && window.__sketermImpersonation==="pending";i++) await new Promise(function(r){setTimeout(r,25)});
    \\    impersonationRejected = String(window.__sketermImpersonation).includes("extension capability does not authorize");
    \\  } catch (e) {}
    \\  browser.browserAction.setTitle({title:helperRejected && unsupportedRejected && impersonationRejected ? "Security Checks Passed" : "Security Checks Failed"});
    \\}
    \\if (typeof browser.pageAction !== "undefined" || typeof browser.action !== "undefined") throw new Error("wrong browser action namespace");
    \\browser.browserAction.setBadgeText({ text: "界界界界界界界界界界界界" });
    \\browser.browserAction.setBadgeTextColor({ color: [1,2,3,255] });
    \\browser.browserAction.setBadgeBackgroundColor({ color: "#aabbccdd" });
    \\var openPopupChecks = 0;
    \\browser.tabs.onActivated.addListener(function () {
    \\  if (openPopupChecks++ >= 2) return;
    \\  browser.browserAction.openPopup().then(function(){
    \\    browser.browserAction.setBadgeText({text:"OPEN"});
    \\    browser.browserAction.setTitle({title:"Security Checks Passed"});
    \\  },function(){
    \\    browser.browserAction.setBadgeText({text:"DENY"});
    \\    browser.browserAction.setTitle({title:"Popup Denied: "+String(arguments[0])});
    \\  });
    \\});
    \\browser.browserAction.onClicked.addListener(function (tab) {
    \\  browser.browserAction.setBadgeText({ tabId: tab.id, text: "C" });
    \\});
    \\securityChecks();
;

const action_probe =
    \\window.__sketermCapProbe = window.__sketermCapProbe || {apis:[],runs:0};
    \\window.__sketermCapProbe.apis.push(browser);
    \\window.__sketermCapProbe.current = browser;
    \\window.__sketermCapProbe.runs++;
;

const action_popup =
    \\<!doctype html><html><head><title>action popup</title></head><body>
    \\<script>
    \\document.body.textContent = "popup:" + browser.runtime.getManifest().name;
    \\if (location.search === "?open") browser.browserAction.openPopup();
    \\</script></body></html>
;

const hostile_origin_page =
    \\<!doctype html><title>origin probe</title>
    \\<script src="sketerm-extension://__ORIGIN_HOST__/__sketerm-extapi.js"></script>
    \\<script>document.title = [typeof browser, typeof(globalThis.chrome&&chrome.runtime), typeof(globalThis.chrome&&chrome.browserAction)].join(":")</script>
;

const no_popup_manifest =
    \\{"manifest_version":2,"name":"sketerm click fixture","version":"1",
    \\ "browser_specific_settings":{"gecko":{"id":"click@sketerm.test"}},
    \\ "background":{"scripts":["bg.js"],"persistent":true},
    \\ "browser_action":{"default_title":"Click Action"}}
;

const no_popup_bg =
    \\browser.browserAction.onClicked.addListener(function (tab) {
    \\  browser.browserAction.setBadgeText({ tabId: tab.id, text: "K" });
    \\});
;

const missing_popup_manifest =
    \\{"manifest_version":2,"name":"sketerm missing popup fixture","version":"1",
    \\ "browser_specific_settings":{"gecko":{"id":"missing@sketerm.test"}},
    \\ "browser_action":{"default_title":"Missing Popup","default_popup":"gone.html"}}
;

const page_action_manifest =
    \\{"manifest_version":2,"name":"sketerm page action fixture","version":"1",
    \\ "browser_specific_settings":{"gecko":{"id":"page@sketerm.test"}},
    \\ "background":{"scripts":["bg.js"],"persistent":true},
    \\ "page_action":{"default_title":"Page Only"}}
;

const page_action_bg =
    \\if (typeof browser.browserAction !== "undefined" || typeof browser.action !== "undefined" ||
    \\    typeof browser.pageAction.setBadgeText !== "undefined" || typeof browser.pageAction.enable !== "undefined") {
    \\  throw new Error("wrong page action namespace");
    \\}
    \\browser.tabs.query({active:true}).then(function(tabs){
    \\  if (tabs[0]) return browser.pageAction.show(tabs[0].id);
    \\});
    \\browser.pageAction.onClicked.addListener(function(tab){
    \\  browser.pageAction.setTitle({tabId:tab.id,title:"Page Clicked"});
    \\});
;

fn writeActionFixture(dir: []const u8, manifest_json: []const u8, background: []const u8, popup: ?[]const u8) bool {
    mkdirZ(dir);
    return writeFile(dir, "manifest.json", manifest_json) and
        (background.len == 0 or writeFile(dir, "bg.js", background)) and
        writeFile(dir, "probe.js", action_probe) and
        (popup == null or writeFile(dir, "popup.html", popup.?));
}

fn actionListHas(cl: *Client, id: []const u8, title: []const u8, popup: bool, badge: []const u8) bool {
    const json = cl.action_json[0..cl.action_json_len];
    var parsed = std.json.parseFromSlice(std.json.Value, cl.gpa, json, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .array) return false;
    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const o = item.object;
        const got_id = o.get("id") orelse continue;
        if (got_id != .string or !std.mem.eql(u8, got_id.string, id)) continue;
        const got_title = o.get("title") orelse return false;
        const got_popup = o.get("popup") orelse return false;
        const got_badge = o.get("badge") orelse return false;
        return got_title == .string and std.mem.eql(u8, got_title.string, title) and
            got_popup == .bool and got_popup.bool == popup and
            got_badge == .string and std.mem.eql(u8, got_badge.string, badge);
    }
    return false;
}

fn actionColorsAre(cl: *Client, id: []const u8, fg: []const u8, bg: []const u8) bool {
    const json = cl.action_json[0..cl.action_json_len];
    const at = std.mem.indexOf(u8, json, id) orelse return false;
    const end = std.mem.indexOfScalarPos(u8, json, at, '}') orelse json.len;
    return std.mem.indexOf(u8, json[at..end], fg) != null and std.mem.indexOf(u8, json[at..end], bg) != null;
}

fn waitActionColors(cl: *Client, id: []const u8, fg: []const u8, bg: []const u8, timeout_ms: i64) bool {
    const deadline = nowMs() + timeout_ms;
    while (true) {
        if (actionColorsAre(cl, id, fg, bg)) return true;
        if (nowMs() > deadline) return false;
        cl.pump(50);
    }
}

fn waitAction(cl: *Client, id: []const u8, title: []const u8, popup: bool, badge: []const u8, timeout_ms: i64) bool {
    return waitActionView(cl, view_id, id, title, popup, badge, timeout_ms);
}

fn waitActionView(cl: *Client, view: u32, id: []const u8, title: []const u8, popup: bool, badge: []const u8, timeout_ms: i64) bool {
    const deadline = nowMs() + timeout_ms;
    while (true) {
        if (cl.action_view == view and actionListHas(cl, id, title, popup, badge)) return true;
        if (nowMs() > deadline) return false;
        cl.pump(50);
    }
}

fn waitExtPopupState(cl: *Client, popup_view: u32, state: u8, timeout_ms: i64) bool {
    const deadline = nowMs() + timeout_ms;
    while (true) {
        if (cl.ext_popup_view == popup_view and cl.ext_popup_state == state) return true;
        if (nowMs() > deadline) return false;
        cl.pump(50);
    }
}

fn waitCapRuns(cl: *Client, runs: u32, timeout_ms: i64) bool {
    var code_buf: [192]u8 = undefined;
    const code = std.fmt.bufPrint(&code_buf, "!!window.__sketermCapProbe&&window.__sketermCapProbe.runs>={d}", .{runs}) catch return false;
    const deadline = nowMs() + timeout_ms;
    while (nowMs() < deadline) {
        const result = cl.evalWaitView(view_id, code, false, 5000);
        if (std.mem.indexOf(u8, result, "\"value\":true") != null) return true;
        cl.pump(50);
    }
    return false;
}

fn staleApiRejects(cl: *Client, api_index: u32, timeout_ms: i64) bool {
    var code_buf: [512]u8 = undefined;
    const code = std.fmt.bufPrint(&code_buf, "(async()=>{{try{{await window.__sketermCapProbe.apis[{d}].storage.local.get(null);return 'STALE_RESOLVED'}}catch(e){{return 'STALE_REJECTED:'+String(e)}}}})()", .{api_index}) catch return false;
    const result = cl.evalWaitView(view_id, code, true, timeout_ms);
    return std.mem.indexOf(u8, result, "STALE_REJECTED:Error: extension context") != null;
}

fn runActionStage(gpa: std.mem.Allocator, exe: [*:0]const u8, dir: []const u8) void {
    var data_buf: [4096]u8 = undefined;
    const data_dir = std.fmt.bufPrintZ(&data_buf, "{s}/acdata", .{dir}) catch fail("stage 40 data path");
    mkdirZ(data_dir);
    _ = c.setenv("XDG_DATA_HOME", data_dir.ptr, 1);
    var cache_buf: [4096]u8 = undefined;
    const cache_dir = std.fmt.bufPrintZ(&cache_buf, "{s}/accache", .{dir}) catch fail("stage 40 cache path");
    mkdirZ(cache_dir);

    var popup_dir_buf: [4096]u8 = undefined;
    var click_dir_buf: [4096]u8 = undefined;
    var missing_dir_buf: [4096]u8 = undefined;
    var page_action_dir_buf: [4096]u8 = undefined;
    const popup_dir = std.fmt.bufPrint(&popup_dir_buf, "{s}/acpopup", .{dir}) catch fail("stage 40 popup fixture path");
    const click_dir = std.fmt.bufPrint(&click_dir_buf, "{s}/acclick", .{dir}) catch fail("stage 40 click fixture path");
    const missing_dir = std.fmt.bufPrint(&missing_dir_buf, "{s}/acmissing", .{dir}) catch fail("stage 40 missing fixture path");
    const page_action_dir = std.fmt.bufPrint(&page_action_dir_buf, "{s}/acpage", .{dir}) catch fail("stage 40 page fixture path");
    if (!writeActionFixture(popup_dir, action_manifest, action_bg, action_popup)) fail("stage 40: could not write popup fixture");
    if (!writeActionFixture(click_dir, no_popup_manifest, no_popup_bg, action_popup)) fail("stage 40: could not write click fixture");
    if (!writeActionFixture(missing_dir, missing_popup_manifest, "", null)) fail("stage 40: could not write missing fixture");
    if (!writeActionFixture(page_action_dir, page_action_manifest, page_action_bg, action_popup)) fail("stage 40: could not write page action fixture");

    var host_buf: [16]u8 = undefined;
    const origin_host = extmanifest.originHost("action@sketerm.test", &host_buf);
    const hostile_page = std.mem.replaceOwned(u8, gpa, hostile_origin_page, "__ORIGIN_HOST__", origin_host) catch
        fail("stage 40: could not build hostile origin fixture");
    defer gpa.free(hostile_page);
    if (!writeFile(dir, "origin.html", hostile_page)) fail("stage 40: could not write hostile origin fixture");

    var srv = HttpProbe{ .body = "<!doctype html><title>action page</title><body>ordinary page</body>" };
    if (!srv.start()) fail("stage 40: loopback HTTP server would not start");
    defer srv.shutdown();
    var hostile_srv = HttpProbe{ .body = hostile_page };
    if (!hostile_srv.start()) fail("stage 40: hostile-origin HTTP server would not start");
    defer hostile_srv.shutdown();
    var page_buf: [96]u8 = undefined;
    const page_url = std.fmt.bufPrint(&page_buf, "http://127.0.0.1:{d}/p", .{srv.lis.port}) catch fail("stage 40 page url");

    var sock_buf: [96]u8 = undefined;
    const sock = std.fmt.bufPrintZ(&sock_buf, "{s}/ac.sock", .{dir}) catch fail("stage 40 socket path");
    var resolver_buf: [128:0]u8 = undefined;
    const resolver = std.fmt.bufPrintZ(&resolver_buf, "--host-resolver-rules=MAP * 127.0.0.1", .{}) catch fail("stage 40 resolver rule");
    const pid = spawnHelper(exe, sock.ptr, cache_dir.ptr, "--ozone-platform=headless", resolver.ptr, false);
    g_pid = pid;
    var cl = Client{ .gpa = gpa, .fd = connectWithRetry(sock.ptr, sock.len) };
    cl.send(proto.Hello{ .proto = proto.PROTO_VERSION, .client_name = "smoke-web" });
    {
        const deadline = nowMs() + 15_000;
        while (cl.ack_proto == 0 and nowMs() < deadline) cl.pump(100);
    }
    if (!cl.ack_webext_action) fail("stage 40: hello_ack lacks the webext-action capability");

    const bad_set_before = cl.we_seq;
    cl.send(proto.WebextSet{ .id = "../bad", .dir = popup_dir, .enabled = 1 });
    {
        const deadline = nowMs() + 5000;
        while (cl.we_seq == bad_set_before and nowMs() < deadline) cl.pump(50);
    }
    if (cl.we_seq == bad_set_before or cl.we_ok != 0 or
        std.mem.indexOf(u8, cl.we_err[0..cl.we_err_len], "invalid extension id") == null)
        fail("stage 40: malformed wire extension id was not rejected");
    const long_set_before = cl.we_seq;
    cl.send(proto.WebextSet{ .id = "x" ** (extmanifest.MAX_ID_LEN + 1), .dir = popup_dir, .enabled = 1 });
    {
        const deadline = nowMs() + 5000;
        while (cl.we_seq == long_set_before and nowMs() < deadline) cl.pump(50);
    }
    if (cl.we_seq == long_set_before or cl.we_ok != 0 or
        std.mem.indexOf(u8, cl.we_err[0..cl.we_err_len], "invalid extension id") == null)
        fail("stage 40: overlong wire extension id was not rejected");

    cl.send(proto.ViewCreate{ .view = view_id, .w = 640, .h = 480, .scale_x1000 = 1000, .context = 0 });
    cl.have_view = true;
    if (!cl.waitBufferAfter(0, 20_000)) fail("stage 40: no frame_buffer for the page view");
    cl.send(proto.Navigate{ .view = view_id, .url = page_url });
    cl.sendTabs(&.{.{ .id = 40, .view = view_id, .active = true, .url = page_url, .title = "action" }});

    const bad_popup_seq = cl.ext_popup_seq;
    const bad_popup_view = proto.WEBEXT_POPUP_VIEW_BASE + 30;
    cl.send(proto.WebextActionActivate{
        .view = view_id,
        .id = "x" ** (extmanifest.MAX_ID_LEN + 1),
        .popup_view = bad_popup_view,
        .w = 360,
        .h = 420,
        .scale_x1000 = 1000,
    });
    {
        const deadline = nowMs() + 5000;
        while (cl.ext_popup_seq == bad_popup_seq and nowMs() < deadline) cl.pump(50);
    }
    if (cl.ext_popup_seq == bad_popup_seq or cl.ext_popup_view != bad_popup_view or
        cl.ext_popup_state != proto.webext_popup_error or
        std.mem.indexOf(u8, cl.ext_popup_detail[0..cl.ext_popup_detail_len], "invalid extension id") == null)
        fail("stage 40: overlong wire action id was not rejected");
    pass("stage 40h malformed and overlong wire extension ids are rejected before registry or popup use");

    cl.send(proto.WebextSet{ .id = "action@sketerm.test", .dir = popup_dir, .enabled = 1 });
    cl.send(proto.WebextSet{ .id = "click@sketerm.test", .dir = click_dir, .enabled = 1 });
    cl.send(proto.WebextSet{ .id = "missing@sketerm.test", .dir = missing_dir, .enabled = 1 });
    cl.send(proto.WebextSet{ .id = "page@sketerm.test", .dir = page_action_dir, .enabled = 1 });
    if (!waitAction(&cl, "action@sketerm.test", "Security Checks Passed", true, "界界界界界界界界界界界界", 15_000))
        fail("stage 40: helper/local Promise rejection or two-extension impersonation check failed");
    if (!waitActionColors(&cl, "action@sketerm.test", "\"badgeTextColor\":[1,2,3,255]", "\"badgeBackgroundColor\":[170,187,204,221]", 10_000))
        fail("stage 40: badge colors were not published to the toolbar");
    if (!waitAction(&cl, "click@sketerm.test", "Click Action", false, "", 15_000))
        fail("stage 40: no-popup action was not reported for the active page");
    {
        const deadline = nowMs() + 1200;
        while (nowMs() < deadline) cl.pump(50);
    }
    if (!waitAction(&cl, "page@sketerm.test", "Page Only", false, "", 10_000))
        fail("stage 40: pageAction.show did not reveal the action for its tab");
    pass("stage 40i helper errors reject Promises, unsupported APIs reject locally, and one extension cannot impersonate another");

    cl.send(proto.WebextActionActivate{
        .view = view_id,
        .id = "page@sketerm.test",
        .popup_view = 0,
        .w = 0,
        .h = 0,
        .scale_x1000 = 1000,
    });
    if (!waitAction(&cl, "page@sketerm.test", "Page Clicked", false, "", 10_000))
        fail("stage 40: no-popup activation did not fire pageAction.onClicked");

    if (!waitCapRuns(&cl, 1, 10_000)) fail("stage 40: content capability probe never initialized");
    var state_before = cl.we_seq;
    cl.send(proto.WebextSet{ .id = "action@sketerm.test", .dir = popup_dir, .enabled = 1 });
    {
        const deadline = nowMs() + 5000;
        while (cl.we_seq == state_before and nowMs() < deadline) cl.pump(50);
    }
    if (cl.we_seq == state_before) fail("stage 40: reinstall produced no extension state");
    if (!waitCapRuns(&cl, 2, 15_000) or !staleApiRejects(&cl, 0, 10_000))
        fail("stage 40: reinstall did not rotate and revoke the old extension capability");

    state_before = cl.we_seq;
    cl.send(proto.WebextSet{ .id = "action@sketerm.test", .dir = popup_dir, .enabled = 0 });
    {
        const deadline = nowMs() + 5000;
        while (cl.we_seq == state_before and nowMs() < deadline) cl.pump(50);
    }
    if (cl.we_seq == state_before or !staleApiRejects(&cl, 1, 10_000))
        fail("stage 40: disabling an extension did not revoke its capability");
    cl.send(proto.WebextSet{ .id = "action@sketerm.test", .dir = popup_dir, .enabled = 1 });
    if (!waitCapRuns(&cl, 3, 15_000)) fail("stage 40: re-enabling an extension did not mint a new capability");

    const reload_start = cl.evalWaitView(view_id, "window.__sketermCapProbe.apis[2].runtime.reload().catch(function(){});'reload-started'", false, 10_000);
    if (std.mem.indexOf(u8, reload_start, "reload-started") == null or !waitCapRuns(&cl, 4, 15_000) or
        !staleApiRejects(&cl, 2, 10_000))
        fail("stage 40: runtime.reload did not rotate and revoke the old extension capability");
    if (!waitAction(&cl, "action@sketerm.test", "Security Checks Passed", true, "界界界界界界界界界界界界", 15_000))
        fail("stage 40: reloaded action instance did not finish its security checks");
    pass("stage 40j reinstall, disable/enable and runtime.reload rotate capabilities and reject stale API objects");

    // A stale/background page cannot activate an action for the mirrored
    // tab, and a requested popup always receives a lifecycle answer.
    const rejected_view = proto.WEBEXT_POPUP_VIEW_BASE + 1;
    cl.send(proto.WebextActionActivate{
        .view = 99,
        .id = "action@sketerm.test",
        .popup_view = rejected_view,
        .w = 360,
        .h = 420,
        .scale_x1000 = 1000,
    });
    if (!waitExtPopupState(&cl, rejected_view, proto.webext_popup_error, 10_000))
        fail("stage 40: rejected popup activation produced no lifecycle error");
    if (cl.ext_popup_fb_seq != 0) fail("stage 40: a stale/background view created a popup buffer");

    const popup_view = proto.WEBEXT_POPUP_VIEW_BASE + 2;
    cl.send(proto.WebextActionActivate{
        .view = view_id,
        .id = "action@sketerm.test",
        .popup_view = popup_view,
        .w = 360,
        .h = 420,
        .scale_x1000 = 1000,
    });
    if (!waitExtPopupState(&cl, popup_view, proto.webext_popup_opened, 20_000))
        fail("stage 40: trusted toolbar activation did not open the declared popup");
    if (cl.ext_popup_detail_len == 0 or
        std.mem.indexOf(u8, cl.ext_popup_detail[0..cl.ext_popup_detail_len], "/popup.html") == null)
        fail("stage 40: popup lifecycle did not name its extension page");
    {
        const deadline = nowMs() + 20_000;
        while ((cl.ext_popup_fb_seq == 0 or cl.ext_popup_dmg_seq == 0) and nowMs() < deadline) cl.pump(50);
    }
    if (cl.ext_popup_fb_seq == 0 or cl.ext_popup_dmg_seq == 0)
        fail("stage 40: the real extension popup never painted");
    var manifest_ok = false;
    var manifest_last: []const u8 = "";
    const manifest_deadline = nowMs() + 15_000;
    while (!manifest_ok and nowMs() < manifest_deadline) {
        const manifest_result = cl.evalWaitView(
            popup_view,
            "typeof browser==='object' ? browser.runtime.getManifest().name : 'not-ready'",
            false,
            5000,
        );
        manifest_last = manifest_result;
        manifest_ok = std.mem.indexOf(u8, manifest_result, "\"value\":\"sketerm action fixture\"") != null;
        if (!manifest_ok) cl.pump(100);
    }
    if (!manifest_ok) {
        std.debug.print("stage 40: popup manifest eval returned {s}\n", .{manifest_last});
        fail("stage 40: popup extension origin did not receive runtime.getManifest");
    }
    pass("stage 40a trusted browser action opens a painted extension-origin popup with runtime APIs");

    cl.send(proto.ViewDestroy{ .view = popup_view });
    if (!waitExtPopupState(&cl, popup_view, proto.webext_popup_closed, 10_000))
        fail("stage 40: client popup close did not produce a lifecycle close");

    // Re-activate the mirrored tab so the BACKGROUND page's onActivated
    // listener calls openPopup. The helper must identify the active page
    // rather than trying to map the hidden background view to a tab.
    const open_before = cl.open_popup_seq;
    cl.sendTabs(&.{.{ .id = 40, .view = view_id, .active = false, .url = page_url, .title = "action" }});
    cl.sendTabs(&.{.{ .id = 40, .view = view_id, .active = true, .url = page_url, .title = "action" }});
    const open_deadline = nowMs() + 10_000;
    while (cl.open_popup_seq == open_before and nowMs() < open_deadline) cl.pump(50);
    if (cl.open_popup_seq == open_before or cl.open_popup_view != view_id or
        !std.mem.eql(u8, cl.open_popup_id[0..cl.open_popup_id_len], "action@sketerm.test"))
        fail("stage 40: background browserAction.openPopup produced no helper-to-GUI request");
    cl.send(proto.WebextOpenPopupResult{
        .view = cl.open_popup_view,
        .id = cl.open_popup_id[0..cl.open_popup_id_len],
        .req = cl.open_popup_req +% 1,
        .ok = 1,
        .detail = "wrong request",
    });
    {
        const deadline = nowMs() + 500;
        while (nowMs() < deadline) cl.pump(50);
    }
    if (actionListHas(&cl, "action@sketerm.test", "Security Checks Passed", true, "OPEN"))
        fail("stage 40: a mismatched popup acknowledgement settled openPopup");
    cl.send(proto.WebextOpenPopupResult{
        .view = cl.open_popup_view,
        .id = cl.open_popup_id[0..cl.open_popup_id_len],
        .req = cl.open_popup_req,
        .ok = 0,
        .detail = "native refusal 界",
    });
    if (!waitAction(&cl, "action@sketerm.test", "Popup Denied: Error: native refusal 界", true, "DENY", 10_000))
        fail("stage 40: openPopup did not reject after the GUI refusal acknowledgement");

    const open_again = cl.open_popup_seq;
    cl.sendTabs(&.{.{ .id = 40, .view = view_id, .active = false, .url = page_url, .title = "action" }});
    cl.sendTabs(&.{.{ .id = 40, .view = view_id, .active = true, .url = page_url, .title = "action" }});
    const open_again_deadline = nowMs() + 10_000;
    while (cl.open_popup_seq == open_again and nowMs() < open_again_deadline) cl.pump(50);
    if (cl.open_popup_seq == open_again) fail("stage 40: second openPopup request never reached the GUI");
    cl.send(proto.WebextOpenPopupResult{
        .view = cl.open_popup_view,
        .id = cl.open_popup_id[0..cl.open_popup_id_len],
        .req = cl.open_popup_req,
        .ok = 1,
        .detail = "",
    });
    if (!waitAction(&cl, "action@sketerm.test", "Security Checks Passed", true, "OPEN", 10_000))
        fail("stage 40: openPopup did not resolve after the GUI success acknowledgement");
    pass("stage 40g browserAction.openPopup remains pending until a correlated GUI acknowledgement resolves or rejects it");

    cl.send(proto.WebextActionActivate{
        .view = view_id,
        .id = "click@sketerm.test",
        .popup_view = 0,
        .w = 0,
        .h = 0,
        .scale_x1000 = 1000,
    });
    if (!waitAction(&cl, "click@sketerm.test", "Click Action", false, "K", 10_000))
        fail("stage 40: no-popup activation did not fire browserAction.onClicked");
    pass("stage 40b action without a popup fires onClicked for the active tab");

    const missing_view = proto.WEBEXT_POPUP_VIEW_BASE + 3;
    cl.send(proto.WebextActionActivate{
        .view = view_id,
        .id = "missing@sketerm.test",
        .popup_view = missing_view,
        .w = 360,
        .h = 420,
        .scale_x1000 = 1000,
    });
    if (!waitExtPopupState(&cl, missing_view, proto.webext_popup_error, 10_000))
        fail("stage 40: missing popup asset produced no error lifecycle");
    if (std.mem.indexOf(u8, cl.ext_popup_detail[0..cl.ext_popup_detail_len], "not found") == null)
        fail("stage 40: missing popup error did not explain the missing asset");
    const missing_fb = cl.ext_popup_fb_seq;
    const missing_dmg = cl.ext_popup_dmg_seq;
    const quiet_deadline = nowMs() + 1000;
    while (nowMs() < quiet_deadline) cl.pump(50);
    if (cl.ext_popup_fb_seq != missing_fb or cl.ext_popup_dmg_seq != missing_dmg)
        fail("stage 40: missing popup created a helper view/frame");
    pass("stage 40c missing popup asset fails visibly without creating a view");

    var fetch_buf: [512]u8 = undefined;
    const fetch_probe = std.fmt.bufPrint(
        &fetch_buf,
        "(async()=>{{try{{let r=await fetch('sketerm-extension://{s}/__sketerm-extapi.js');return [r.status,await r.text()]}}catch(e){{return [0,String(e)]}}}})()",
        .{origin_host},
    ) catch fail("stage 40 fetch probe");
    const ordinary_fetch = cl.evalWaitView(view_id, fetch_probe, true, 10_000);
    if (std.mem.indexOf(u8, ordinary_fetch, "200") != null or
        std.mem.indexOf(u8, ordinary_fetch, "ext-inject") != null or
        std.mem.indexOf(u8, ordinary_fetch, "tok") != null)
        fail("stage 40: an ordinary page fetched the privileged extension bootstrap");
    const globals_probe = "[typeof browser,typeof(globalThis.chrome&&chrome.runtime),typeof(globalThis.chrome&&chrome.browserAction)]";
    const ordinary_globals = cl.evalWaitView(view_id, globals_probe, false, 10_000);
    if (std.mem.indexOf(u8, ordinary_globals, "\"value\":[\"undefined\",\"undefined\",\"undefined\"]") == null)
        fail("stage 40: an ordinary page received extension globals");

    const blank_view: u32 = 41;
    var load_before = cl.load_seq;
    cl.send(proto.ViewCreate{ .view = blank_view, .w = 320, .h = 240, .scale_x1000 = 1000, .context = 0 });
    {
        const deadline = nowMs() + 20_000;
        while (cl.load_seq == load_before and nowMs() < deadline) cl.pump(50);
    }
    if (cl.load_seq == load_before) fail("stage 40: about:blank view never loaded");
    const blank_fetch = cl.evalWaitView(blank_view, fetch_probe, true, 10_000);
    if (std.mem.indexOf(u8, blank_fetch, "200") != null or
        std.mem.indexOf(u8, blank_fetch, "ext-inject") != null or
        std.mem.indexOf(u8, blank_fetch, "tok") != null)
        fail("stage 40: about:blank fetched the privileged extension bootstrap");
    load_before = cl.load_seq;
    cl.send(proto.Navigate{ .view = blank_view, .url = "data:text/html,<title>data-probe</title>data" });
    {
        const deadline = nowMs() + 20_000;
        while (cl.load_seq == load_before and nowMs() < deadline) cl.pump(50);
    }
    if (cl.load_seq == load_before) fail("stage 40: data URL view never loaded");
    const data_fetch = cl.evalWaitView(blank_view, fetch_probe, true, 10_000);
    if (std.mem.indexOf(u8, data_fetch, "200") != null or
        std.mem.indexOf(u8, data_fetch, "ext-inject") != null or
        std.mem.indexOf(u8, data_fetch, "tok") != null)
        fail("stage 40: a data URL fetched the privileged extension bootstrap");
    const data_globals = cl.evalWaitView(blank_view, globals_probe, false, 10_000);
    if (std.mem.indexOf(u8, data_globals, "\"value\":[\"undefined\",\"undefined\",\"undefined\"]") == null)
        fail("stage 40: a data URL received extension globals");
    cl.send(proto.ViewDestroy{ .view = blank_view });

    // A direct same-host HTTP fixture proves the privileged check keys on
    // BOTH scheme and host. Loading the bootstrap as a classic script is
    // load-bearing: a fetch can be hidden by CORS even if the scheme
    // handler served the nonce-bearing body.
    var same_http_buf: [2048]u8 = undefined;
    const same_http = std.fmt.bufPrint(&same_http_buf, "http://{s}:{d}/p", .{ origin_host, hostile_srv.lis.port }) catch fail("stage 40 same-host HTTP URL");
    const scheme_view: u32 = 44;
    load_before = cl.load_seq;
    cl.send(proto.ViewCreateUrl{ .view = scheme_view, .w = 320, .h = 240, .scale_x1000 = 1000, .context = 0, .url = same_http });
    {
        const deadline = nowMs() + 20_000;
        while (cl.load_seq == load_before and nowMs() < deadline) cl.pump(50);
    }
    if (cl.load_seq == load_before) fail("stage 40: same-host HTTP fixture never loaded");
    const http_globals = cl.evalWaitView(scheme_view, globals_probe, false, 10_000);
    if (std.mem.indexOf(u8, http_globals, "\"value\":[\"undefined\",\"undefined\",\"undefined\"]") == null)
        fail("stage 40: http://same-extension-host received extension globals");
    cl.send(proto.ViewDestroy{ .view = scheme_view });

    // Repeat with HTTPS against the rig's self-signed loopback server.
    // The document uses the extension HOST itself; accepting its cert for
    // this request must not grant the extension origin's privileges.
    if (smoke_tls.start(dir)) |server| {
        defer server.stop();
        var same_https_buf: [256]u8 = undefined;
        const same_https = std.fmt.bufPrint(&same_https_buf, "https://{s}:{d}/origin.html", .{ origin_host, server.port }) catch
            fail("stage 40 same-host HTTPS URL");
        const https_view: u32 = 45;
        const cert_before = cl.cert_seq;
        load_before = cl.load_seq;
        cl.send(proto.ViewCreateUrl{ .view = https_view, .w = 320, .h = 240, .scale_x1000 = 1000, .context = 0, .url = same_https });
        const cert_deadline = nowMs() + 20_000;
        while (cl.cert_seq == cert_before and nowMs() < cert_deadline) cl.pump(50);
        if (cl.cert_seq == cert_before or cl.cert_view != https_view)
            fail("stage 40: same-host HTTPS fixture produced no certificate decision");
        cl.send(proto.CertDecision{ .view = https_view, .proceed = 1 });
        const load_deadline = nowMs() + 20_000;
        while (cl.load_seq == load_before and nowMs() < load_deadline) cl.pump(50);
        if (cl.load_seq == load_before) fail("stage 40: same-host HTTPS fixture never loaded");
        const https_globals = cl.evalWaitView(https_view, globals_probe, false, 10_000);
        if (std.mem.indexOf(u8, https_globals, "\"value\":[\"undefined\",\"undefined\",\"undefined\"]") == null) {
            std.debug.print("stage 40: same-host HTTPS globals were {s}\n", .{https_globals});
            fail("stage 40: https://same-extension-host received extension globals");
        }
        cl.send(proto.ViewDestroy{ .view = https_view });
    } else {
        fail("stage 40: no usable openssl s_server for the required same-host HTTPS origin proof");
    }

    var click_host_buf: [16]u8 = undefined;
    const click_host = extmanifest.originHost("click@sketerm.test", &click_host_buf);
    var foreign_url_buf: [128]u8 = undefined;
    const foreign_url = std.fmt.bufPrint(&foreign_url_buf, "sketerm-extension://{s}/popup.html", .{click_host}) catch
        fail("stage 40 foreign extension url");
    const foreign_view: u32 = 42;
    load_before = cl.load_seq;
    cl.send(proto.ViewCreateUrl{
        .view = foreign_view,
        .w = 320,
        .h = 240,
        .scale_x1000 = 1000,
        .context = 0,
        .url = foreign_url,
    });
    {
        const deadline = nowMs() + 20_000;
        while (cl.load_seq == load_before and nowMs() < deadline) cl.pump(50);
    }
    if (cl.load_seq == load_before) fail("stage 40: foreign extension page never loaded");
    const foreign_fetch = cl.evalWaitView(foreign_view, fetch_probe, true, 10_000);
    if (std.mem.indexOf(u8, foreign_fetch, "200") != null or
        std.mem.indexOf(u8, foreign_fetch, "ext-inject") != null or
        std.mem.indexOf(u8, foreign_fetch, "tok") != null)
        fail("stage 40: one extension fetched another extension's bootstrap");
    cl.send(proto.ViewDestroy{ .view = foreign_view });
    pass("stage 40d ordinary, blank, data, same-host HTTP/HTTPS and foreign-extension origins cannot read the privileged bootstrap");

    const owner_view: u32 = 43;
    cl.send(proto.ViewCreate{ .view = owner_view, .w = 320, .h = 240, .scale_x1000 = 1000, .context = 0 });
    cl.sendTabs(&.{
        .{ .id = 40, .view = view_id, .active = false, .url = page_url, .title = "action" },
        .{ .id = 43, .view = owner_view, .active = true, .url = page_url, .title = "owner" },
    });
    if (!waitActionView(&cl, owner_view, "action@sketerm.test", "Security Checks Passed", true, "OPEN", 10_000))
        fail("stage 40: action snapshot did not follow the active owner view");
    const owner_popup = proto.WEBEXT_POPUP_VIEW_BASE + 4;
    cl.send(proto.WebextActionActivate{
        .view = owner_view,
        .id = "action@sketerm.test",
        .popup_view = owner_popup,
        .w = 360,
        .h = 420,
        .scale_x1000 = 1000,
    });
    if (!waitExtPopupState(&cl, owner_popup, proto.webext_popup_opened, 20_000))
        fail("stage 40: owner popup did not open");
    cl.send(proto.ViewDestroy{ .view = owner_view });
    if (!waitExtPopupState(&cl, owner_popup, proto.webext_popup_closed, 10_000))
        fail("stage 40: destroying the owner did not close its popup");
    pass("stage 40e destroying a page closes every popup it owns");

    cl.sendTabs(&.{.{ .id = 40, .view = view_id, .active = true, .url = page_url, .title = "action" }});
    if (!waitAction(&cl, "action@sketerm.test", "Security Checks Passed", true, "OPEN", 10_000))
        fail("stage 40: action snapshot did not return to the original page");

    const popup_view_2 = proto.WEBEXT_POPUP_VIEW_BASE + 5;
    cl.send(proto.WebextActionActivate{
        .view = view_id,
        .id = "action@sketerm.test",
        .popup_view = popup_view_2,
        .w = 360,
        .h = 420,
        .scale_x1000 = 1000,
    });
    if (!waitExtPopupState(&cl, popup_view_2, proto.webext_popup_opened, 20_000))
        fail("stage 40: second popup did not open before extension teardown");
    cl.send(proto.WebextRemove{ .id = "action@sketerm.test" });
    if (!waitExtPopupState(&cl, popup_view_2, proto.webext_popup_closed, 10_000))
        fail("stage 40: removing an extension did not close its popup");
    if (!staleApiRejects(&cl, 3, 10_000))
        fail("stage 40: removing an extension did not revoke its last capability");
    pass("stage 40f extension removal closes its live popup");

    cl.send(proto.WebextRemove{ .id = "click@sketerm.test" });
    cl.send(proto.WebextRemove{ .id = "missing@sketerm.test" });
    cl.send(proto.WebextRemove{ .id = "page@sketerm.test" });
    cl.send(proto.ViewDestroy{ .view = view_id });
    cl.have_view = false;
    {
        const deadline = nowMs() + 2500;
        while (nowMs() < deadline) cl.pump(50);
    }
    cl.deinit();
    reapHelperTimeout(pid, "stage 40", 30_000);
}

// ─────────────────────────────────────────────────────────────────────
// Stage 35: real MV2 extensions
// ─────────────────────────────────────────────────────────────────────
//
// Stage 33's fixture proves our own code paths run. It cannot prove that
// a REAL extension runs, and the four tier-1 ones all failed on things a
// fixture never exercises: an ES-module background page, a
// `chrome-extension://` origin its own code fetches from, a
// `runtime.connect` Port its content script tears itself down without.
//
// 35a is a fixture SHAPED LIKE uBO — module background page with a real
// static import, a Port from the content script, storage defaults, i18n
// placeholders, `all_frames` — so the machinery is proven with no
// network and no third-party download.
//
// 35b is the real uBlock Origin, and the only thing that can answer the
// question the stage exists to answer: does it block a request. It is
// SKIPPED, loudly, when the pinned XPI is absent (`zig build
// fetch-webext-fixtures`), because a smoke run must not download.

/// A routing loopback server for stage 35: it can tell the page apart
/// from the resource uBO should block, and COUNTS hits on the latter, so
/// "blocked" means the network never saw it rather than merely that the
/// page reported an error.
const UboServer = struct {
    lis: tcpserver.Listener = .{ .backlog = 64, .poll_ms = 100 },
    page: []const u8 = "",
    frame: []const u8 = "",
    /// `/adspop.js` — matched by a generic path rule in uBO's OWN
    /// bundled `assets/ublock/filters.min.txt`, which is always enabled
    /// and needs no download. A rule with a `$domain=` option could
    /// never match a loopback page.
    ad_hits: std.atomic.Value(u32) = .init(0),
    /// The control resource, which must still arrive: a stage where
    /// EVERYTHING failed would also report the ad as blocked.
    ok_hits: std.atomic.Value(u32) = .init(0),

    fn start(self: *UboServer) bool {
        return self.lis.start(self, &onConn);
    }

    fn onConn(ctx: ?*anyopaque, afd: c_int) bool {
        const self: *UboServer = @ptrCast(@alignCast(ctx.?));
        self.handle(afd);
        return false;
    }

    fn handle(self: *UboServer, afd: c_int) void {
        var req: [8192]u8 = undefined;
        var pfd = c.struct_pollfd{ .fd = afd, .events = c.POLLIN, .revents = 0 };
        if (c.poll(@ptrCast(&pfd), 1, 3000) <= 0) return;
        const n = c.read(afd, &req, req.len);
        if (n <= 0) return;
        const raw = req[0..@intCast(n)];

        var body: []const u8 = "ok";
        var ctype: []const u8 = "text/plain";
        if (std.mem.indexOf(u8, raw, "GET /p ") != null or std.mem.indexOf(u8, raw, "GET /p?") != null) {
            body = self.page;
            ctype = "text/html";
        } else if (std.mem.indexOf(u8, raw, "GET /sub") != null) {
            body = self.frame;
            ctype = "text/html";
        } else if (std.mem.indexOf(u8, raw, "GET /adspop.js") != null) {
            _ = self.ad_hits.fetchAdd(1, .release);
            body = "REACHED-THE-NETWORK";
            ctype = "text/javascript";
        } else if (std.mem.indexOf(u8, raw, "GET /control.js") != null) {
            _ = self.ok_hits.fetchAdd(1, .release);
            body = "CONTROL-OK";
            ctype = "text/javascript";
        }

        tcpserver.respondOk(afd, ctype, body, tcpserver.CORS);
    }

    fn deinit(self: *UboServer) void {
        self.lis.deinit();
    }
};

// -- 35a fixture: uBlock Origin's LOADING SHAPE ------------------------

const shape_manifest =
    \\{"manifest_version":2,"name":"sketerm shape fixture","version":"1",
    \\ "default_locale":"en",
    \\ "browser_specific_settings":{"gecko":{"id":"shape@sketerm.test"}},
    \\ "permissions":["storage","tabs","webRequest","webRequestBlocking","<all_urls>"],
    \\ "web_accessible_resources":["/war/*"],
    \\ "background":{"page":"background.html","persistent":true},
    \\ "content_scripts":[{"matches":["http://*/*"],"js":["cs.js"],
    \\   "all_frames":true,"run_at":"document_end"}]}
;

/// The document shape uBO uses: a classic script, then a MODULE with a
/// static import. Neither could run before — the classic one was never
/// read (only `background.scripts` was), and the module is a
/// SyntaxError under `new Function` no matter what.
const shape_bg_html =
    \\<!DOCTYPE html>
    \\<html><head><meta charset="utf-8"><title>shape bg</title></head>
    \\<body>
    \\<script src="lib/classic.js"></script>
    \\<script src="js/start.js" type="module"></script>
    \\</body></html>
;

const shape_classic_js =
    \\self.__classicRan = 1;
;

/// A real ES module with a real static import, fetched over
/// `chrome-extension://` — the thing `js/start.js` does 20 times.
const shape_start_js =
    \\import { mark, VALUE } from "./dep.js";
    \\self.__moduleRan = 1;
    \\self.__depValue = VALUE;
    \\mark();
    \\
    \\// A fetch of our own package over the extension origin, which is
    \\// how uBO reads its bundled filter lists.
    \\self.__assetText = "";
    \\fetch(browser.runtime.getURL("assets/list.txt"))
    \\  .then(function (r) { return r.text(); })
    \\  .then(function (t) { self.__assetText = t.trim(); })
    \\  .catch(function () { self.__assetText = "FETCH-FAILED"; });
    \\
    \\self.__ports = 0;
    \\self.__portMsg = "";
    \\browser.runtime.onConnect.addListener(function (port) {
    \\  self.__ports += 1;
    \\  port.onMessage.addListener(function (m) {
    \\    self.__portMsg = String(m);
    \\    port.postMessage("pong:" + m);
    \\  });
    \\});
    \\
    \\// storage.local.get with OBJECT DEFAULTS, uBO's settings bootstrap.
    \\self.__defaults = "";
    \\browser.storage.local.get({ shapeSetting: "author-default", other: 7 })
    \\  .then(function (o) {
    \\    self.__defaults = String(o && o.shapeSetting) + "/" + String(o && o.other);
    \\  });
    \\
    \\browser.runtime.onMessage.addListener(function (m) {
    \\  if (m !== "report") return null;
    \\  return Promise.resolve({
    \\    classic: self.__classicRan || 0,
    \\    module: self.__moduleRan || 0,
    \\    dep: self.__depValue || "",
    \\    marked: self.__marked || 0,
    \\    asset: self.__assetText,
    \\    ports: self.__ports,
    \\    portMsg: self.__portMsg,
    \\    defaults: self.__defaults,
    \\    i18n: browser.i18n.getMessage("blockedCount", ["12", "example.com"]),
    \\    frames: self.__frames || 0
    \\  });
    \\});
;

const shape_dep_js =
    \\export const VALUE = "dep-loaded";
    \\export function mark() { self.__marked = 1; }
;

const shape_asset_txt = "bundled-asset-body\n";

/// The content script. Its FIRST act is `runtime.connect`, exactly as
/// uBO's `js/vapi-client.js` does — and uBO calls `vAPI.shutdown.exec()`
/// when that throws, which is why a missing Port API is fatal rather
/// than merely limiting.
const shape_cs_js =
    \\(function () {
    \\  var port;
    \\  try {
    \\    port = browser.runtime.connect({ name: "shape" });
    \\  } catch (e) {
    \\    document.title = "cs:connect-threw";
    \\    return;
    \\  }
    \\  if (!port || typeof port.postMessage !== "function") {
    \\    document.title = "cs:no-port";
    \\    return;
    \\  }
    \\  var isTop = window.top === window;
    \\  port.onMessage.addListener(function (m) {
    \\    if (!isTop) return;
    \\    window.__portReply = String(m);
    \\  });
    \\  port.postMessage(isTop ? "top" : "sub");
    \\  if (!isTop) return;
    \\  // The top frame reports once the background has seen both frames.
    \\  var tries = 0;
    \\  var timer = setInterval(function () {
    \\    tries += 1;
    \\    browser.runtime.sendMessage("report").then(function (r) {
    \\      if (!r) return;
    \\      if (r.ports < 2 && tries < 40) return;
    \\      clearInterval(timer);
    \\      document.title = "shape:" + r.classic + r.module +
    \\        (r.dep === "dep-loaded" ? 1 : 0) + r.marked +
    \\        (r.asset === "bundled-asset-body" ? 1 : 0) +
    \\        (r.ports >= 2 ? 1 : 0) +
    \\        (r.portMsg === "top" || r.portMsg === "sub" ? 1 : 0) +
    \\        (r.defaults === "author-default/7" ? 1 : 0) +
    \\        (r.i18n === "Blocked 12 requests on example.com" ? 1 : 0) +
    \\        (window.__portReply && window.__portReply.indexOf("pong:") === 0 ? 1 : 0);
    \\    });
    \\  }, 250);
    \\})();
;

const shape_messages =
    \\{"blockedCount":{"message":"Blocked $count$ requests on $site$",
    \\  "placeholders":{"count":{"content":"$1"},"site":{"content":"$2"}}}}
;

fn shapePage(buf: []u8, port: u16) []const u8 {
    return std.fmt.bufPrint(buf,
        \\<!doctype html><html><head><title>shape-start</title></head><body>
        \\<iframe src="http://127.0.0.1:{d}/sub"></iframe>
        \\</body></html>
    , .{port}) catch fail("stage 35 shape page");
}

const shape_frame = "<!doctype html><html><body>sub</body></html>";

fn writeShapeFixture(dir: []const u8) bool {
    mkdirZ2(dir);
    // Separate buffers: these slices all stay live to the end of the
    // function, so one shared scratch buffer would leave every earlier
    // path pointing at the last one written into it.
    var lib_buf: [160]u8 = undefined;
    var js_buf: [160]u8 = undefined;
    var as_buf: [160]u8 = undefined;
    var loc_buf: [160]u8 = undefined;
    var en_buf: [160]u8 = undefined;
    const lib = std.fmt.bufPrint(&lib_buf, "{s}/lib", .{dir}) catch return false;
    const js = std.fmt.bufPrint(&js_buf, "{s}/js", .{dir}) catch return false;
    const assets = std.fmt.bufPrint(&as_buf, "{s}/assets", .{dir}) catch return false;
    const locales = std.fmt.bufPrint(&loc_buf, "{s}/_locales", .{dir}) catch return false;
    const en = std.fmt.bufPrint(&en_buf, "{s}/_locales/en", .{dir}) catch return false;
    mkdirZ2(lib);
    mkdirZ2(js);
    mkdirZ2(assets);
    mkdirZ2(locales);
    mkdirZ2(en);
    return writeFile(dir, "manifest.json", shape_manifest) and
        writeFile(dir, "background.html", shape_bg_html) and
        writeFile(dir, "cs.js", shape_cs_js) and
        writeFile(lib, "classic.js", shape_classic_js) and
        writeFile(js, "start.js", shape_start_js) and
        writeFile(js, "dep.js", shape_dep_js) and
        writeFile(assets, "list.txt", shape_asset_txt) and
        writeFile(en, "messages.json", shape_messages);
}

fn mkdirZ2(path: []const u8) void {
    var buf: [4096]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return;
    _ = c.mkdir(z.ptr, 0o700);
}

/// Stage 35a — the loading SHAPE of a real MV2 extension.
fn runShapeStage(gpa: std.mem.Allocator, exe: [*:0]const u8, dir: []const u8) void {
    var data_buf: [4096]u8 = undefined;
    const data_dir = std.fmt.bufPrintZ(&data_buf, "{s}/shdata", .{dir}) catch fail("stage 35a data path");
    mkdirZ(data_dir);
    _ = c.setenv("XDG_DATA_HOME", data_dir.ptr, 1);
    var cache_buf: [4096]u8 = undefined;
    const cache_dir = std.fmt.bufPrintZ(&cache_buf, "{s}/shcache", .{dir}) catch fail("stage 35a cache path");
    mkdirZ(cache_dir);
    var ext_buf: [4096]u8 = undefined;
    const ext_dir = std.fmt.bufPrint(&ext_buf, "{s}/shfix", .{dir}) catch fail("stage 35a ext path");
    if (!writeShapeFixture(ext_dir)) fail("stage 35a: could not write the fixture");

    var srv = UboServer{};
    if (!srv.start()) fail("stage 35a: loopback HTTP server would not start");
    defer srv.deinit();
    var page_body: [512]u8 = undefined;
    srv.page = shapePage(&page_body, srv.lis.port);
    srv.frame = shape_frame;
    var url_buf: [96]u8 = undefined;
    const page_url = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/p", .{srv.lis.port}) catch fail("url");

    var sock_buf: [96]u8 = undefined;
    const sock = std.fmt.bufPrintZ(&sock_buf, "{s}/sh.sock", .{dir}) catch fail("stage 35a sock");
    const pid = spawnHelper(exe, sock.ptr, cache_dir.ptr, "--ozone-platform=headless", null, false);
    var cl = Client{ .gpa = gpa, .fd = connectWithRetry(sock.ptr, sock.len) };
    cl.send(proto.Hello{ .proto = proto.PROTO_VERSION, .client_name = "smoke-web" });
    {
        const d = nowMs() + 15_000;
        while (cl.ack_proto == 0 and nowMs() < d) cl.pump(100);
    }
    if (!cl.ack_webext) fail("stage 35a: hello_ack lacks the webext capability");
    if (!cl.ack_webext_tabs) fail("stage 35a: hello_ack lacks the webext-tabs capability");

    cl.send(proto.WebextSet{ .id = "shape@sketerm.test", .dir = ext_dir, .enabled = 1 });
    {
        const d = nowMs() + 5_000;
        while (cl.we_ok == 0xff and nowMs() < d) cl.pump(100);
    }
    if (cl.we_ok != 1) {
        std.debug.print("stage 35a: load error \"{s}\"\n", .{cl.we_err[0..cl.we_err_len]});
        fail("stage 35a: the fixture failed to load");
    }
    {
        const d = nowMs() + 2500;
        while (nowMs() < d) cl.pump(50);
    }

    cl.send(proto.ViewCreate{ .view = view_id, .w = 640, .h = 480, .scale_x1000 = 1000, .context = 0 });
    cl.have_view = true;
    if (!cl.waitBufferAfter(0, 20_000)) fail("stage 35a: no frame_buffer for the page view");

    // Publish a tab for the view BEFORE navigating: `sender.tab` is what
    // Dark Reader keys its per-tab state on, and it is only right if the
    // client told us the mapping.
    cl.sendTabs(&.{.{ .id = 77, .view = view_id, .active = true, .url = page_url, .title = "shape" }});

    cl.resetTitle();
    cl.send(proto.Navigate{ .view = view_id, .url = page_url });
    if (!cl.waitTitle("shape:", 40_000)) {
        std.debug.print("stage 35a: title was \"{s}\"\n", .{cl.titleSlice()});
        fail("stage 35a: the fixture never reported (background page did not run)");
    }
    const res = cl.titleSlice();
    const want = "shape:1111111111";
    if (!std.mem.eql(u8, res, want)) {
        std.debug.print(
            "stage 35a: expected \"{s}\", got \"{s}\"\n" ++
                "  digits: classic module dep marked asset ports portMsg defaults i18n portReply\n",
            .{ want, res },
        );
        fail("stage 35a: part of the real-extension loading shape does not work");
    }
    pass("stage 35a loading shape (module background page at its own origin, static import, " ++
        "package fetch, Ports from two frames, storage defaults, i18n placeholders)");

    cl.send(proto.WebextRemove{ .id = "shape@sketerm.test" });
    cl.send(proto.ViewDestroy{ .view = view_id });
    cl.have_view = false;
    {
        const d = nowMs() + 2500;
        while (nowMs() < d) cl.pump(50);
    }
    cl.deinit();
    reapHelperTimeout(pid, "stage 35a", 30_000);
}

fn uboPage(buf: []u8, port: u16) []const u8 {
    return std.fmt.bufPrint(buf,
        \\<!doctype html><html><head><title>ubo-start</title></head><body><script>
        \\var B = "http://127.0.0.1:{d}";
        \\async function t(u) {{
        \\  try {{ var r = await fetch(u); return await r.text(); }} catch (e) {{ return "ERR"; }}
        \\}}
        \\(async function () {{
        \\  var ad = await t(B + "/adspop.js");
        \\  var ok = await t(B + "/control.js");
        \\  document.title = "ubo:" + (ad === "ERR" ? 1 : 0) + (ok.indexOf("CONTROL-OK") >= 0 ? 1 : 0);
        \\}})();
        \\</script></body></html>
    , .{port}) catch fail("stage 35 ubo page");
}

/// Stage 35b — the real uBlock Origin.
///
/// Skipped rather than failed when the pinned XPI is absent: a smoke run
/// must not download, and `zig build fetch-webext-fixtures` is what puts
/// it there. Reported either way, so a green run never hides the fact
/// that the only real-extension assertion did not execute.
fn runUboStage(gpa: std.mem.Allocator, exe: [*:0]const u8, dir: []const u8, pinned_xpi: []const u8) void {
    // A DEVELOPER escape hatch, not part of the gate: point the stage at
    // any other MV2 XPI to see how far it gets. It then REPORTS instead
    // of asserting, because "blocks /adspop.js" is a statement about
    // uBlock Origin and nothing else.
    const probe: ?[]const u8 = if (c.getenv("SKETERM_SMOKE_WEBEXT_XPI")) |p| std.mem.span(p) else null;
    const probe_id: []const u8 = if (c.getenv("SKETERM_SMOKE_WEBEXT_ID")) |p| std.mem.span(p) else "probe@sketerm.test";
    const xpi_path = probe orelse pinned_xpi;
    if (xpi_path.len == 0 or c.access(xpi_path.ptr, c.R_OK) != 0) {
        std.debug.print(
            "smoke-web: SKIP stage 35b (real uBlock Origin): no XPI at \"{s}\"\n" ++
                "           run `zig build fetch-webext-fixtures` to enable it\n",
            .{xpi_path},
        );
        return;
    }

    const ext_id: []const u8 = if (probe != null) probe_id else "uBlock0@raymondhill.net";

    var data_buf: [4096]u8 = undefined;
    const data_dir = std.fmt.bufPrintZ(&data_buf, "{s}/ubdata", .{dir}) catch fail("stage 35b data path");
    mkdirZ(data_dir);
    _ = c.setenv("XDG_DATA_HOME", data_dir.ptr, 1);
    var cache_buf: [4096]u8 = undefined;
    const cache_dir = std.fmt.bufPrintZ(&cache_buf, "{s}/ubcache", .{dir}) catch fail("stage 35b cache path");
    mkdirZ(cache_dir);

    var ext_buf: [4096]u8 = undefined;
    const ext_dir = std.fmt.bufPrint(&ext_buf, "{s}/ubo", .{dir}) catch fail("stage 35b ext path");
    mkdirZ2(ext_dir);
    if (!unpackXpi(gpa, xpi_path, ext_dir)) fail("stage 35b: could not unpack the uBlock Origin XPI");
    if (c.getenv("SKETERM_SMOKE_UBO_TRACE") != null) uboTrace(gpa, ext_dir);

    // Seed uBO's OWN settings through the same `storage.local` file the
    // helper persists, so the stage measures ONE named filter list
    // rather than whatever the shipped EasyList copy happens to contain
    // this month. It also keeps the assertion honest: the rule the page
    // trips (`/adspop.js`) is in `ublock-filters`, the list selected
    // here, and nothing else is loaded to accidentally block the page
    // itself.
    {
        var sdir_buf: [4096]u8 = undefined;
        const sdir = std.fmt.bufPrint(&sdir_buf, "{s}/sketerm/webext/{s}", .{ data_dir, ext_id }) catch
            fail("stage 35b storage dir");
        mkdirAllZ(sdir);
        var spath_buf: [4096]u8 = undefined;
        const spath = std.fmt.bufPrintZ(&spath_buf, "{s}/storage.json", .{sdir}) catch fail("stage 35b storage path");
        if (!writeWholeFile(spath,
            \\{"selectedFilterLists":["ublock-filters"],
            \\ "userSettings":{"advancedUserEnabled":false},
            \\ "hiddenSettings":{"cacheStorageAPI":"browser.storage.local"}}
        )) fail("stage 35b: could not seed uBlock Origin's settings");
    }

    var srv = UboServer{};
    if (!srv.start()) fail("stage 35b: loopback HTTP server would not start");
    defer srv.deinit();
    var page_body: [1024]u8 = undefined;
    srv.page = uboPage(&page_body, srv.lis.port);
    srv.frame = shape_frame;
    var url_buf: [96]u8 = undefined;
    const page_url = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/p", .{srv.lis.port}) catch fail("url");

    var sock_buf: [96]u8 = undefined;
    const sock = std.fmt.bufPrintZ(&sock_buf, "{s}/ub.sock", .{dir}) catch fail("stage 35b sock");
    const pid = spawnHelper(exe, sock.ptr, cache_dir.ptr, "--ozone-platform=headless", null, false);
    var cl = Client{ .gpa = gpa, .fd = connectWithRetry(sock.ptr, sock.len) };
    cl.send(proto.Hello{ .proto = proto.PROTO_VERSION, .client_name = "smoke-web" });
    {
        const d = nowMs() + 15_000;
        while (cl.ack_proto == 0 and nowMs() < d) cl.pump(100);
    }
    if (!cl.ack_webext) fail("stage 35b: hello_ack lacks the webext capability");

    cl.send(proto.WebextSet{ .id = ext_id, .dir = ext_dir, .enabled = 1 });
    {
        const d = nowMs() + 10_000;
        while (cl.we_ok == 0xff and nowMs() < d) cl.pump(100);
    }
    if (cl.we_ok != 1) {
        std.debug.print("stage 35b: load error \"{s}\"\n", .{cl.we_err[0..cl.we_err_len]});
        fail("stage 35b: uBlock Origin's manifest did not load");
    }

    cl.send(proto.ViewCreate{ .view = view_id, .w = 800, .h = 600, .scale_x1000 = 1000, .context = 0 });
    cl.have_view = true;
    if (!cl.waitBufferAfter(0, 20_000)) fail("stage 35b: no frame_buffer for the page view");
    // The tab's url must be CURRENT: it is what `documentUrl` reports
    // for every subresource, and uBO decides first-vs-third party from
    // it. A GUI client re-posts the list on every navigation.
    cl.sendTabs(&.{.{ .id = 1, .view = view_id, .active = true, .url = page_url, .title = "ubo" }});

    // uBO parses ~4MB of bundled filter lists before its first verdict.
    // Poll rather than sleep a fixed time: the stage retries the page
    // until the block takes effect or the budget runs out, so a slow
    // machine costs time and never a false failure.
    var blocked = false;
    const budget = nowMs() + 120_000;
    var attempts: u32 = 0;
    // Baseline for THIS attempt. The assertion below is per-attempt, not
    // cumulative: earlier attempts legitimately reach the network while
    // uBO is still parsing its lists, so only the attempt that reports a
    // block has to show zero new hits.
    var ad_before = srv.ad_hits.load(.acquire);
    while (nowMs() < budget and !blocked) {
        attempts += 1;
        cl.resetTitle();
        ad_before = srv.ad_hits.load(.acquire);
        cl.send(proto.Navigate{ .view = view_id, .url = page_url });
        if (!cl.waitTitle("ubo:", 30_000)) {
            std.debug.print("stage 35b: attempt {d}: title was \"{s}\"\n", .{ attempts, cl.titleSlice() });
            continue;
        }
        const res = cl.titleSlice();
        if (std.mem.eql(u8, res, "ubo:11")) {
            blocked = true;
            break;
        }
        if (!std.mem.eql(u8, res, "ubo:01")) {
            std.debug.print("stage 35b: attempt {d}: unexpected result \"{s}\"\n", .{ attempts, res });
        }
        const wait = nowMs() + 4000;
        while (nowMs() < wait) cl.pump(50);
    }

    if (!blocked and probe != null) {
        cl.wq_seen = false;
        cl.send(proto.WebextWreqStatsReq{});
        {
            const d = nowMs() + 3000;
            while (!cl.wq_seen and nowMs() < d) cl.pump(50);
        }
        std.debug.print(
            "stage 35b PROBE \"{s}\": no block after {d} attempts " ++
                "(helper: matched={d} held={d} cancelled={d} timed_out={d} failed_open={d})\n",
            .{ ext_id, attempts, cl.wq_matched, cl.wq_held, cl.wq_cancelled, cl.wq_timed_out, cl.wq_failed_open },
        );
    } else if (!blocked) {
        // The helper's own counters say WHICH half failed: no `matched`
        // means uBO never registered a filter that saw the request; a
        // `cancelled` on a page that stayed blank means it cancelled the
        // wrong thing.
        cl.wq_seen = false;
        cl.send(proto.WebextWreqStatsReq{});
        {
            const d = nowMs() + 3000;
            while (!cl.wq_seen and nowMs() < d) cl.pump(50);
        }
        std.debug.print(
            "stage 35b: after {d} attempts uBO never blocked /adspop.js " ++
                "(ad_hits={d}, control_hits={d}; helper: matched={d} held={d} " ++
                "cancelled={d} redirected={d} timed_out={d} failed_open={d})\n",
            .{
                attempts,         srv.ad_hits.load(.acquire), srv.ok_hits.load(.acquire),
                cl.wq_matched,    cl.wq_held,                 cl.wq_cancelled,
                cl.wq_redirected, cl.wq_timed_out,            cl.wq_failed_open,
            },
        );
        fail("stage 35b: real uBlock Origin did not block a request");
    }
    // A cancel must mean the request never reached the network. The
    // LAST attempt is the one that blocked; earlier attempts may have
    // let it through while uBO was still parsing, so what is asserted
    // is that the blocking attempt added no hit.
    // GUARDED on `blocked`. Probe mode is report-only and returns here
    // with blocked == false, so falling through printed "no block after
    // N attempts" and then "blocked on attempt N" for the same run, and
    // could abort the whole smoke from a mode documented not to. The
    // teardown below is shared by both exits and must still run.
    if (blocked) {
        const hits_at_block = srv.ad_hits.load(.acquire);
        if (srv.ok_hits.load(.acquire) == 0) {
            // Probe mode is REPORT-ONLY for a THIRD-PARTY extension, so
            // it diagnoses rather than aborting the whole smoke run.
            if (probe != null) {
                std.debug.print("stage 35b PROBE \"{s}\": the control resource never arrived either\n", .{ext_id});
            } else fail("stage 35b: the control resource never arrived either — the page, not uBO, failed");
        }
        // The claim this stage exists to make. Without it the stage
        // passes whenever the page's fetch merely REJECTS — a cancel
        // landing after dispatch, a redirect-to-abort, or an unrelated
        // socket reset all look identical from the page — while the
        // request did reach the network. src/web/CLAUDE.md cites this
        // stage as proof that it did not, so the proof has to be here.
        if (hits_at_block != ad_before) {
            std.debug.print(
                "stage 35b: the blocking attempt still hit the network ({d} -> {d})\n",
                .{ ad_before, hits_at_block },
            );
            if (probe != null) {
                std.debug.print("stage 35b PROBE \"{s}\": blocked but the request still hit the network\n", .{ext_id});
            } else fail("stage 35b: uBO reported a block but the request reached the server");
        }
        std.debug.print(
            "stage 35b: blocked on attempt {d} (ad reached the network {d} time(s) while uBO was still loading)\n",
            .{ attempts, hits_at_block },
        );
        if (probe != null) {
            std.debug.print("stage 35b PROBE \"{s}\": blocked on attempt {d}\n", .{ ext_id, attempts });
        } else pass("stage 35b REAL uBlock Origin 1.73.0 blocks a request on a loopback page");
    }

    cl.send(proto.WebextRemove{ .id = ext_id });
    cl.send(proto.ViewDestroy{ .view = view_id });
    cl.have_view = false;
    {
        const d = nowMs() + 4000;
        while (nowMs() < d) cl.pump(50);
    }
    cl.deinit();
    reapHelperTimeout(pid, "stage 35b", 60_000);
}

/// Unpack an XPI into `dest`, refusing any entry that escapes it.
fn unpackXpi(gpa: std.mem.Allocator, xpi_path: []const u8, dest: []const u8) bool {
    const bytes = readWholeFile(gpa, xpi_path) orelse return false;
    defer gpa.free(bytes);
    var arc = zip.read(gpa, bytes) catch return false;
    defer arc.deinit();
    for (arc.entries) |entry| {
        if (entry.is_dir) continue;
        if (std.mem.indexOf(u8, entry.name, "..") != null) continue;
        var full_buf: [4096]u8 = undefined;
        const full = std.fmt.bufPrintZ(&full_buf, "{s}/{s}", .{ dest, entry.name }) catch continue;
        if (std.fs.path.dirname(full)) |d| mkdirAllZ(d);
        // A LOOPING write, not the rig's `writeFile`: uBO's EasyList
        // copy is 2.2MB and a single `write()` is free to come back
        // short, which read as "unpack failed" for the whole archive.
        if (!writeWholeFile(full, entry.data)) return false;
    }
    return true;
}

fn writeWholeFile(path: [*:0]const u8, body: []const u8) bool {
    const fd = c.open(path, c.O_WRONLY | c.O_CREAT | c.O_TRUNC, @as(c_uint, 0o644));
    if (fd < 0) return false;
    defer _ = c.close(fd);
    var off: usize = 0;
    while (off < body.len) {
        const n = c.write(fd, body.ptr + off, body.len - off);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

/// `SKETERM_SMOKE_UBO_TRACE=1`: splice `console.log` calls into the
/// UNPACKED copy of uBO's traffic.js, so its own verdict shows up in the
/// helper's console stream. Diagnostic only — never on by default, and
/// it modifies the throwaway unpack, never the pinned XPI.
fn uboTrace(gpa: std.mem.Allocator, ext_dir: []const u8) void {
    // uBO narrates its own boot through `ubolog`, which is silenced
    // unless a hidden setting turns it on. Making the SILENT arm log
    // instead is the smallest possible patch that yields the whole
    // startup sequence, and it is the fastest way to see exactly where
    // an extension stops working under this host.
    var path_buf: [4096]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/js/console.js", .{ext_dir}) catch return;
    const src = readWholeFile(gpa, path) orelse return;
    defer gpa.free(src);
    // Two arms silence it: the "ignore" one after an explicit disable,
    // and the initial BUFFERING one that never flushes unless enabled.
    // Patching the buffer is what catches the whole boot.
    const needle = "    const store = function(...args) {\n        pending.push(args);\n    };";
    const at = std.mem.indexOf(u8, src, needle) orelse {
        std.debug.print("ubo-trace: anchor not found in console.js\n", .{});
        return;
    };
    const replacement =
        \\    const store = function(...args) {
        \\        pending.push(args);
        \\        try { console.info('[uBO]', ...args); } catch(e){}
        \\    };
    ;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    out.appendSlice(gpa, src[0..at]) catch return;
    out.appendSlice(gpa, replacement) catch return;
    out.appendSlice(gpa, src[at + needle.len ..]) catch return;
    // The OTHER silent arm: once uBO calls `ubologSet(false)` the whole
    // narrative stops mid-boot, which reads exactly like a hang.
    const ign = "function ubologIgnore() {\n}";
    if (std.mem.indexOf(u8, out.items, ign)) |i| {
        const repl = "function ubologIgnore(...args) { try { console.info('[uBO]', ...args); } catch(e){} }";
        var out2: std.ArrayList(u8) = .empty;
        defer out2.deinit(gpa);
        out2.appendSlice(gpa, out.items[0..i]) catch return;
        out2.appendSlice(gpa, repl) catch return;
        out2.appendSlice(gpa, out.items[i + ign.len ..]) catch return;
        _ = writeWholeFile(path, out2.items);
        std.debug.print("ubo-trace: patched {s} (both arms)\n", .{path});
        return;
    }
    _ = writeWholeFile(path, out.items);
    std.debug.print("ubo-trace: patched {s}\n", .{path});
}

fn mkdirAllZ(path: []const u8) void {
    var buf: [4096]u8 = undefined;
    if (path.len + 1 > buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i != path.len and buf[i] != '/') continue;
        const save = buf[i];
        buf[i] = 0;
        _ = c.mkdir(@ptrCast(&buf), 0o700);
        buf[i] = save;
    }
}

fn readWholeFile(gpa: std.mem.Allocator, path: []const u8) ?[]u8 {
    var zbuf: [4096]u8 = undefined;
    const z = std.fmt.bufPrintZ(&zbuf, "{s}", .{path}) catch return null;
    const fd = c.open(z.ptr, c.O_RDONLY);
    if (fd < 0) return null;
    defer _ = c.close(fd);
    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) != 0) return null;
    const size: usize = @intCast(@max(st.st_size, 0));
    if (size == 0 or size > 64 * 1024 * 1024) return null;
    const buf = gpa.alloc(u8, size) catch return null;
    var got: usize = 0;
    while (got < size) {
        const n = c.read(fd, buf.ptr + got, size - got);
        if (n <= 0) break;
        got += @intCast(n);
    }
    if (got != size) {
        gpa.free(buf);
        return null;
    }
    return buf;
}

fn markFileStale(path: []const u8) bool {
    var pbuf: [4096]u8 = undefined;
    const p = std.fmt.bufPrintZ(&pbuf, "{s}", .{path}) catch return false;
    const times: [2]c.struct_timespec = .{
        .{ .tv_sec = 1, .tv_nsec = 0 },
        .{ .tv_sec = 1, .tv_nsec = 0 },
    };
    return c.utimensat(c.AT_FDCWD, p.ptr, &times, 0) == 0;
}

fn waitHttpCount(cl: *Client, value: *std.atomic.Value(u32), min: u32, timeout_ms: i64) bool {
    const deadline = nowMs() + timeout_ms;
    while (value.load(.acquire) < min) {
        if (nowMs() > deadline) return false;
        cl.pump(50);
    }
    return true;
}

/// Stage 39: subscription fetch, atomic replacement, live reload and teardown.
fn runFilterSubscriptionStage(gpa: std.mem.Allocator, exe: [*:0]const u8, dir: []const u8) void {
    var old_config_buf: [4096:0]u8 = undefined;
    const had_config_home = if (c.getenv("XDG_CONFIG_HOME")) |raw| blk: {
        const old = std.mem.span(raw);
        if (old.len >= old_config_buf.len) fail("stage 39 prior config path too long");
        @memcpy(old_config_buf[0..old.len], old);
        old_config_buf[old.len] = 0;
        break :blk true;
    } else false;
    defer {
        if (had_config_home) {
            _ = c.setenv("XDG_CONFIG_HOME", &old_config_buf, 1);
        } else {
            _ = c.unsetenv("XDG_CONFIG_HOME");
        }
    }

    var config_buf: [4096]u8 = undefined;
    const config_home = std.fmt.bufPrintZ(&config_buf, "{s}/filter-config", .{dir}) catch fail("stage 39 config path");
    mkdirAllZ(config_home);
    _ = c.setenv("XDG_CONFIG_HOME", config_home.ptr, 1);
    var cache_buf: [4096]u8 = undefined;
    const cache = std.fmt.bufPrintZ(&cache_buf, "{s}/filter-cache", .{dir}) catch fail("stage 39 cache path");
    mkdirAllZ(cache);
    var sock_buf: [96]u8 = undefined;
    const sock = std.fmt.bufPrintZ(&sock_buf, "{s}/f39.sock", .{dir}) catch fail("stage 39 socket path");

    var http = HttpProbe{ .filter_router = true };
    if (!http.start()) fail("stage 39: loopback HTTP server would not start");
    defer http.shutdown();

    var list_buf: [96]u8 = undefined;
    const list_url = std.fmt.bufPrint(&list_buf, "http://127.0.0.1:{d}/list.txt", .{http.lis.port}) catch fail("stage 39 list url");
    var page_buf: [96]u8 = undefined;
    const page_base = std.fmt.bufPrint(&page_buf, "http://127.0.0.1:{d}/page", .{http.lis.port}) catch fail("stage 39 page url");
    var slow_buf: [96]u8 = undefined;
    const slow_url = std.fmt.bufPrint(&slow_buf, "http://127.0.0.1:{d}/slow.txt", .{http.lis.port}) catch fail("stage 39 slow url");

    var cache_name_buf: [filtersub.MAX_NAME]u8 = undefined;
    const cache_name = filtersub.cacheName(list_url, &cache_name_buf) catch fail("stage 39 cache name");
    var cache_path_buf: [4096]u8 = undefined;
    const cache_path = std.fmt.bufPrint(&cache_path_buf, "{s}/sketerm/filters/{s}", .{ config_home, cache_name }) catch fail("stage 39 cache file path");

    const pid = spawnHelper(exe, sock.ptr, cache.ptr, "--ozone-platform=headless", null, false);
    g_pid = pid;
    var cl = Client{ .gpa = gpa, .fd = connectWithRetry(sock.ptr, sock.len) };
    cl.send(proto.Hello{ .proto = proto.PROTO_VERSION, .client_name = "smoke-web-filter-sub" });
    {
        const deadline = nowMs() + 20_000;
        while (cl.ack_proto == 0 and nowMs() < deadline) cl.pump(100);
    }
    if (cl.ack_proto != proto.PROTO_VERSION) fail("stage 39: no hello_ack");
    if (!cl.ack_filter_subscribe) fail("stage 39: fetching is disabled (no filter-subscribe capability)");

    cl.send(proto.ViewCreate{ .view = view_id, .w = 320, .h = 240, .scale_x1000 = 1000, .context = 0 });
    cl.have_view = true;
    if (!cl.waitBufferAfter(0, 20_000)) fail("stage 39: no page view buffer");

    // The target must reach the server BEFORE subscription. This fails
    // if an old local file already happens to contain the probe rule.
    http.resetResourceHits();
    cl.resetTitle();
    var baseline_buf: [128]u8 = undefined;
    const baseline = std.fmt.bufPrint(&baseline_buf, "{s}?baseline", .{page_base}) catch fail("stage 39 baseline url");
    cl.send(proto.Navigate{ .view = view_id, .url = baseline });
    if (!cl.waitTitle("fs?baseline:control-resource:hit", 20_000)) {
        std.debug.print("stage 39 baseline title was \"{s}\"\n", .{cl.titleSlice()});
        fail("stage 39: target was blocked before the fetched rule existed");
    }
    if (http.blocked_hits.load(.acquire) == 0 or http.control_hits.load(.acquire) == 0)
        fail("stage 39: baseline resources did not both reach the server");

    // Duplicate URLs are reconciled once. Completion is the stateful
    // boundary: it is posted only after the accepted file was reloaded.
    const duplicate_urls = [_][]const u8{ list_url, list_url };
    if (!cl.subscribeWait(1, &duplicate_urls, 30_000)) fail("stage 39: initial subscription never completed");
    if (cl.sub_active != 1 or cl.sub_fetched != 1 or cl.sub_updated != 1 or cl.sub_failed != 0)
        fail("stage 39: initial completion counters do not describe one successful fetch");
    if (http.list_hits.load(.acquire) != 1) fail("stage 39: duplicate subscription fetched more than once");
    const cached = readWholeFile(gpa, cache_path) orelse fail("stage 39: accepted list was not cached");
    defer gpa.free(cached);
    if (!std.mem.eql(u8, cached, HttpProbe.filter_body)) fail("stage 39: cached list bytes differ from the response");

    http.resetResourceHits();
    cl.resetTitle();
    var blocked_buf: [128]u8 = undefined;
    const blocked_page = std.fmt.bufPrint(&blocked_buf, "{s}?fetched", .{page_base}) catch fail("stage 39 blocked url");
    cl.send(proto.Navigate{ .view = view_id, .url = blocked_page });
    if (!cl.waitTitle("fs?fetched:control-resource:blocked", 20_000)) fail("stage 39: fetched rule never became active");
    if (http.blocked_hits.load(.acquire) != 0) fail("stage 39: blocked resource still reached the server");
    if (http.control_hits.load(.acquire) == 0) fail("stage 39: control request did not reach the server");

    // Empty replace-all removes the cache and reloads immediately.
    if (!cl.subscribeWait(1, &.{}, 10_000)) fail("stage 39: empty replacement never completed");
    if (cl.sub_active != 0 or cl.sub_fetched != 0 or cl.sub_updated != 0 or cl.sub_failed != 0)
        fail("stage 39: empty replacement completion was not empty");
    if (readWholeFile(gpa, cache_path)) |left| {
        gpa.free(left);
        fail("stage 39: removed subscription left its cache file behind");
    }
    http.resetResourceHits();
    cl.resetTitle();
    var removed_buf: [128]u8 = undefined;
    const removed_page = std.fmt.bufPrint(&removed_buf, "{s}?removed", .{page_base}) catch fail("stage 39 removed url");
    cl.send(proto.Navigate{ .view = view_id, .url = removed_page });
    if (!cl.waitTitle("fs?removed:control-resource:hit", 20_000)) fail("stage 39: removed rule remained live");

    // Re-establish the good cache, then try three replacement failures.
    const one_url = [_][]const u8{list_url};
    http.setFilterMode(.good);
    if (!cl.subscribeWait(1, &one_url, 30_000) or cl.sub_updated != 1 or cl.sub_failed != 0)
        fail("stage 39: could not re-establish the good cache");
    const failures = [_]HttpProbe.FilterMode{ .http_error, .malformed, .oversize };
    for (failures) |mode| {
        if (!markFileStale(cache_path)) fail("stage 39: could not age the cache for a replacement test");
        http.setFilterMode(mode);
        if (!cl.subscribeWait(1, &one_url, 30_000)) fail("stage 39: rejected replacement never completed");
        if (cl.sub_fetched != 1 or cl.sub_updated != 0 or cl.sub_failed != 1)
            fail("stage 39: rejected replacement completion counters are wrong");
        const kept = readWholeFile(gpa, cache_path) orelse fail("stage 39: rejected response deleted the previous cache");
        const unchanged = std.mem.eql(u8, kept, HttpProbe.filter_body);
        gpa.free(kept);
        if (!unchanged) fail("stage 39: rejected response overwrote the previous cache");
    }
    http.resetResourceHits();
    cl.resetTitle();
    var kept_buf: [128]u8 = undefined;
    const kept_page = std.fmt.bufPrint(&kept_buf, "{s}?kept", .{page_base}) catch fail("stage 39 kept url");
    cl.send(proto.Navigate{ .view = view_id, .url = kept_page });
    if (!cl.waitTitle("fs?kept:control-resource:blocked", 20_000)) fail("stage 39: a rejected response disabled the previous rule");
    if (http.blocked_hits.load(.acquire) != 0 or http.control_hits.load(.acquire) == 0)
        fail("stage 39: stale-good failure-open network assertions failed");

    // Disconnect while a URLRequest has no response. The Host cancels
    // it and drains the transferred CEF reference before shutdown.
    const slow_urls = [_][]const u8{slow_url};
    const seq = cl.sub_done_seq;
    cl.send(proto.InterceptSubscribe{ .update_hours = 1, .urls = &slow_urls });
    if (!waitHttpCount(&cl, &http.slow_hits, 1, 10_000)) fail("stage 39: slow teardown fetch never started");
    if (cl.sub_done_seq != seq) fail("stage 39: slow fetch completed before teardown could exercise cancellation");
    cl.have_view = false;
    cl.deinit();
    reapHelperTimeout(pid, "stage 39 filter subscription", 15_000);
    pass("stage 39 filter subscription (fetch/reload, zero-hit block, rejected replacements, removal, teardown)");
}

/// SIGPIPE "ignore" via a no-op handler, the `sigNoop` pattern from
/// mux_main.zig. `c.SIG_IGN` is a `@compileError` on Darwin (a
/// function-pointer cast translate-c cannot render) and its raw value
/// (1) violates fn-pointer alignment on aarch64-macos, so referencing
/// it stops this rig building on macOS entirely. For SIGPIPE the no-op
/// is equivalent: write() still returns EPIPE, the process just does
/// not die.
fn sigNoop(_: c_int) callconv(.c) void {}

/// Multi-client serving (capability "multi-client"): two connections on
/// one engine, colliding client view ids kept apart, view-scoped events
/// routed to their owner only, a wedged reader costing nobody else, the
/// shared policy budget refusing fail-closed, the engine surviving one
/// client's death and exiting with the last.
fn runMultiClientStage(gpa: std.mem.Allocator, exe: [*:0]const u8, dir: []const u8) void {
    var sock_buf: [96]u8 = undefined;
    const sock = std.fmt.bufPrintZ(&sock_buf, "{s}/mc.sock", .{dir}) catch fail("mc sock path");
    var cache_buf: [96]u8 = undefined;
    const cache = std.fmt.bufPrintZ(&cache_buf, "{s}/mc-cache", .{dir}) catch fail("mc cache path");
    const pid = spawnHelper(exe, sock.ptr, cache.ptr, "--ozone-platform=headless", null, false);
    g_pid = pid;

    const alpha_page = "data:text/html,<html><head><title>mc:alpha</title></head><body>alpha</body></html>";
    const beta_page = "data:text/html,<html><head><title>mc:beta</title></head><body>beta</body></html>";
    const gamma_page = "data:text/html,<html><head><title>mc:gamma</title></head><body>gamma</body></html>";

    // ── mc1: two clients, both greeted ────────────────────────────
    var a = Client{ .gpa = gpa, .fd = connectWithRetry(sock.ptr, sock.len) };
    a.send(proto.Hello{ .proto = proto.PROTO_VERSION, .client_name = "smoke-web-mc-a" });
    {
        const d = nowMs() + 15_000;
        while (a.ack_proto == 0 and nowMs() < d) a.pump(100);
    }
    if (a.ack_proto != proto.PROTO_VERSION) fail("stage mc1: client A got no hello_ack");
    if (!a.ack_multi_client) fail("stage mc1: hello_ack lacks the multi-client capability");
    // Negative control: a helper nobody started as a session client
    // must not present. This rig's helpers inherit the rig's own
    // WAYLAND_DISPLAY when there is one, and toplevels on the user's
    // desktop for every hidden view would be the bug the env flag exists
    // to prevent.
    if (a.ack_presenter) fail("stage mc1: a helper started without SKETERM_WEB_PRESENTER advertised the presenter");
    var b = Client{ .gpa = gpa, .fd = connectWithRetry(sock.ptr, sock.len) };
    b.send(proto.Hello{ .proto = proto.PROTO_VERSION, .client_name = "smoke-web-mc-b" });
    {
        const d = nowMs() + 15_000;
        while (b.ack_proto == 0 and nowMs() < d) {
            b.pump(50);
            a.pump(0);
        }
    }
    if (b.ack_proto != proto.PROTO_VERSION) fail("stage mc1: client B got no hello_ack (second client refused)");
    pass("stage mc1 two clients greeted on one engine");

    // ── mc2: colliding view ids, own pages, own events ────────────
    // BOTH clients mint view id 1. Each must get its own page and see
    // its title event under ITS id — the namespace round trip.
    a.send(proto.ViewCreate{ .view = 1, .w = 320, .h = 240, .scale_x1000 = 1000, .context = 0 });
    a.have_view = true;
    b.send(proto.ViewCreate{ .view = 1, .w = 320, .h = 240, .scale_x1000 = 1000, .context = 0 });
    b.have_view = true;
    a.send(proto.Navigate{ .view = 1, .url = alpha_page });
    b.send(proto.Navigate{ .view = 1, .url = beta_page });
    {
        const d = nowMs() + 30_000;
        while (nowMs() < d) {
            a.pump(20);
            b.pump(20);
            if (std.mem.startsWith(u8, a.titleSlice(), "mc:alpha") and
                std.mem.startsWith(u8, b.titleSlice(), "mc:beta")) break;
        }
    }
    if (!std.mem.startsWith(u8, a.titleSlice(), "mc:alpha")) fail("stage mc2: client A never saw its own page title");
    if (!std.mem.startsWith(u8, b.titleSlice(), "mc:beta")) fail("stage mc2: client B never saw its own page title");
    if (a.title_view != 1) fail("stage mc2: client A's title event was not translated back to view 1");
    if (b.title_view != 1) fail("stage mc2: client B's title event was not translated back to view 1");
    if (std.mem.startsWith(u8, a.titleSlice(), "mc:beta")) fail("stage mc2: client A received client B's page");
    pass("stage mc2 colliding view ids stay separate (events in each owner's namespace)");

    // ── mc3: shared policy budget refuses fail-closed ─────────────
    // Two real views hold two intercept slots; policy frames may
    // precede their view_create, so bare ids fill the rest of the
    // 32-slot pool without paying for 30 browsers. The 33rd policied
    // id must be REFUSED (active=0), never left unpoliced.
    const empty_hosts: []const []const u8 = &.{};
    var idx: u32 = 0;
    while (idx < 15) : (idx += 1) {
        a.send(proto.NetPolicySet{
            .view = 100 + idx,
            .serial = 1000 + idx,
            .flags = 0,
            .block_types = 0,
            .allow_schemes = 0x3,
            .max_requests = 10,
            .max_bytes = 1024 * 1024,
            .max_navigations = 1,
            .deadline_ms = 60_000,
            .allow_top = empty_hosts,
            .allow_sub = empty_hosts,
        });
        b.send(proto.NetPolicySet{
            .view = 100 + idx,
            .serial = 2000 + idx,
            .flags = 0,
            .block_types = 0,
            .allow_schemes = 0x3,
            .max_requests = 10,
            .max_bytes = 1024 * 1024,
            .max_navigations = 1,
            .deadline_ms = 60_000,
            .allow_top = empty_hosts,
            .allow_sub = empty_hosts,
        });
    }
    // Probe one slot per client: both sides' policies must be ACTIVE
    // (the pool is shared fairly). The success path also streams dirty
    // ev_net_policy status for every fresh slot, so each wait matches
    // on the VIEW it asked about, never on "any policy event".
    {
        const d = nowMs() + 10_000;
        a.pol_probe_view = 100;
        a.send(proto.NetPolicyReq{ .view = 100 });
        while (a.pol_probe_seq == 0 and nowMs() < d) {
            a.pump(50);
            b.pump(0);
        }
        if (a.pol_probe_seq == 0 or a.pol_probe_active != 1) fail("stage mc3: client A's policy slot is not active");
        b.pol_probe_view = 100;
        b.send(proto.NetPolicyReq{ .view = 100 });
        while (b.pol_probe_seq == 0 and nowMs() < d) {
            b.pump(50);
            a.pump(0);
        }
        if (b.pol_probe_seq == 0 or b.pol_probe_active != 1) fail("stage mc3: client B's policy slot is not active");
    }
    {
        b.pol_probe_view = 900;
        b.pol_probe_seq = 0;
        b.pol_probe_active = 0xff;
        b.send(proto.NetPolicySet{
            .view = 900,
            .serial = 3000,
            .flags = 0,
            .block_types = 0,
            .allow_schemes = 0x3,
            .max_requests = 10,
            .max_bytes = 1024 * 1024,
            .max_navigations = 1,
            .deadline_ms = 60_000,
            .allow_top = empty_hosts,
            .allow_sub = empty_hosts,
        });
        const d = nowMs() + 10_000;
        while (b.pol_probe_seq == 0 and nowMs() < d) {
            b.pump(50);
            a.pump(0);
        }
        if (b.pol_probe_seq == 0 or b.pol_probe_serial != 3000) fail("stage mc3: no answer for the 33rd policied view");
        if (b.pol_probe_active != 0) fail("stage mc3: the 33rd policied view was not refused (budget not fail-closed)");
    }
    pass("stage mc3 shared policy budget refuses fail-closed across clients");

    // ── mc4: a wedged client stalls nobody ────────────────────────
    // A stops reading entirely; B must still complete a full
    // navigate-and-title round trip well inside its budget.
    b.send(proto.Navigate{ .view = 1, .url = gamma_page });
    if (!b.waitTitle("mc:gamma", 20_000)) fail("stage mc4: client B's round trip stalled behind a non-reading client A");
    pass("stage mc4 a non-reading client does not stall the others");

    // ── mc5: engine survives A's death, exits with B's ────────────
    a.have_view = false;
    a.deinit();
    // The engine must NOT exit: B is still there. Give the reap a
    // moment, then prove both liveness and B's continued service.
    _ = c.usleep(300_000);
    {
        var status: c_int = 0;
        if (c.waitpid(pid, &status, c.WNOHANG) == pid) {
            g_pid = -1;
            fail("stage mc5: the engine exited with the FIRST client instead of the last");
        }
    }
    b.send(proto.Navigate{ .view = 1, .url = beta_page });
    if (!b.waitTitle("mc:beta", 20_000)) fail("stage mc5: client B lost service when client A died");
    b.have_view = false;
    b.deinit();
    reapHelperTimeout(pid, "stage mc5 last-client exit", 30_000);
    pass("stage mc5 engine survived one client's death and exited with the last");
}

/// Spawn a helper with an explicit argv tail — the flush/linger stages
/// need three extra tokens (`--ozone-platform=headless --linger-ms N`),
/// which outgrows spawnHelper's two optional slots.
fn spawnHelperArgs(exe: [*:0]const u8, sock: [*:0]const u8, cache: [*:0]const u8, tail: []const [*:0]const u8) c.pid_t {
    const pid = c.fork();
    if (pid < 0) fail("fork");
    if (pid != 0) return pid;
    _ = c.setenv("SKETERM_WEB_GPU", "0", 1);
    scrubProxyEnv();
    var vec: [12:null]?[*:0]const u8 = @splat(null);
    var n: usize = 0;
    for ([_][*:0]const u8{ exe, "--socket", sock, "--cache-dir", cache }) |a| {
        vec[n] = a;
        n += 1;
    }
    for (tail) |a| {
        vec[n] = a;
        n += 1;
    }
    _ = c.execv(exe, @ptrCast(@constCast(&vec)));
    c._exit(127);
    unreachable;
}

/// View 1 in `ctx_id`, navigated to `url`, waiting for a title with
/// `prefix` — with ONE retry when the engine answers
/// `ev_view_create_failed` instead. A predecessor SIGKILLed mid-write
/// can leave the profile in recovery and CEF then refuses the FIRST
/// browser transiently (reproduced ~1 in 3 focused runs); the refusal
/// is described and a single retry succeeds, which is exactly the
/// contract this helper pins.
fn openInProfile(cl: *Client, ctx_id: u32, url: []const u8, prefix: []const u8, comptime what: []const u8) void {
    var attempt: u32 = 0;
    while (true) : (attempt += 1) {
        const fail_seq = cl.view_create_fail_seq;
        cl.send(proto.ViewCreate{ .view = 1, .w = 320, .h = 240, .scale_x1000 = 1000, .context = ctx_id });
        cl.have_view = true;
        cl.send(proto.Navigate{ .view = 1, .url = url });
        const d = nowMs() + 20_000;
        var refused = false;
        while (nowMs() < d) {
            cl.pump(50);
            if (std.mem.startsWith(u8, cl.titleSlice(), prefix)) return;
            if (cl.view_create_fail_seq != fail_seq) {
                refused = true;
                break;
            }
        }
        if (!refused) fail(what ++ ": the page never reached its title");
        if (attempt >= 1) fail(what ++ ": browser create refused twice (bring-up not deterministic)");
        std.debug.print("smoke-web: NOTE {s}: browser create refused (\"{s}\"), retrying once\n", .{ what, cl.view_create_fail_reason[0..cl.view_create_fail_reason_len] });
        cl.have_view = false;
        _ = c.usleep(1_000_000);
    }
}

/// Flush + linger (capabilities "flush-store" and `--linger-ms`, the
/// broker-owned lifecycle): an explicit flush makes a persistent jar
/// survive a kill -9 INSIDE Chromium's ~30s commit window; a lingering
/// engine survives its last client, serves a successor the same live
/// jar, and its TTL reap is the graceful drain (proven by the cookie
/// being on disk afterwards with no explicit flush in between).
fn runFlushLingerStage(gpa: std.mem.Allocator, exe: [*:0]const u8, dir: []const u8) void {
    var sock_buf: [96]u8 = undefined;
    const sock = std.fmt.bufPrintZ(&sock_buf, "{s}/fl.sock", .{dir}) catch fail("fl sock path");
    var cache_buf: [96]u8 = undefined;
    const cache = std.fmt.bufPrintZ(&cache_buf, "{s}/fl-cache", .{dir}) catch fail("fl cache path");

    var http = HttpProbe{ .body = jar_page };
    if (!http.start()) fail("stage fl: could not start the loopback http probe");
    defer http.shutdown();
    var set_buf: [72]u8 = undefined;
    const set_url = std.fmt.bufPrint(&set_buf, "http://127.0.0.1:{d}/?set", .{http.lis.port}) catch unreachable;
    var plain_buf: [72]u8 = undefined;
    const plain_url = std.fmt.bufPrint(&plain_buf, "http://127.0.0.1:{d}/?plain", .{http.lis.port}) catch unreachable;

    const ctx_id: u32 = 5;

    // ── fl1: explicit flush beats kill -9 ─────────────────────────
    {
        const pid = spawnHelperArgs(exe, sock.ptr, cache.ptr, &.{"--ozone-platform=headless"});
        g_pid = pid;
        var a = Client{ .gpa = gpa, .fd = connectWithRetry(sock.ptr, sock.len) };
        a.send(proto.Hello{ .proto = proto.PROTO_VERSION, .client_name = "smoke-web-fl-a" });
        {
            const d = nowMs() + 15_000;
            while (a.ack_proto == 0 and nowMs() < d) a.pump(100);
        }
        if (a.ack_proto != proto.PROTO_VERSION) fail("stage fl1: no hello_ack");
        if (!a.ack_flush) fail("stage fl1: hello_ack lacks the flush-store capability");
        a.send(proto.ContextCreate{ .id = ctx_id, .ephemeral = 0, .name = "flushdemo", .proxy = "" });
        openInProfile(&a, ctx_id, set_url, "jarA:", "stage fl1");
        if (std.mem.indexOf(u8, a.titleSlice(), jar_cookie) == null)
            fail("stage fl1: the persistent context could not store its cookie");

        const seq = a.flushed_seq;
        a.send(proto.FlushReq{ .token = 77 });
        if (!a.waitSeq(&a.flushed_seq, seq, 15_000)) fail("stage fl1: flush_req was never answered");
        if (a.last_flush_token != 77) fail("stage fl1: ev_flushed carried the wrong token");

        // The kill lands seconds after the write — squarely inside the
        // ~30s window Phase 0 measured cookies being LOST in without a
        // flush. Survival here is the flush frame working.
        _ = c.kill(pid, c.SIGKILL);
        var status: c_int = 0;
        _ = c.waitpid(pid, &status, 0);
        g_pid = -1;
        a.have_view = false;
        a.teardown_allow_close = true;
        a.deinit();
    }
    pass("stage fl1 explicit flush answered, engine killed -9 inside the commit window");

    // ── fl2: the flushed jar came back from disk ──────────────────
    {
        const pid = spawnHelperArgs(exe, sock.ptr, cache.ptr, &.{"--ozone-platform=headless"});
        g_pid = pid;
        var b = Client{ .gpa = gpa, .fd = connectWithRetry(sock.ptr, sock.len) };
        b.send(proto.Hello{ .proto = proto.PROTO_VERSION, .client_name = "smoke-web-fl-b" });
        {
            const d = nowMs() + 15_000;
            while (b.ack_proto == 0 and nowMs() < d) b.pump(100);
        }
        if (b.ack_proto != proto.PROTO_VERSION) fail("stage fl2: no hello_ack");
        b.send(proto.ContextCreate{ .id = ctx_id, .ephemeral = 0, .name = "flushdemo", .proxy = "" });
        openInProfile(&b, ctx_id, plain_url, "jarB:", "stage fl2");
        if (std.mem.indexOf(u8, b.titleSlice(), jar_cookie) == null) {
            std.debug.print("smoke-web: post-kill title was \"{s}\"\n", .{b.titleSlice()});
            fail("stage fl2: the flushed cookie did not survive kill -9 (flush_store did not reach disk)");
        }
        b.have_view = false;
        b.deinit();
        reapHelperTimeout(pid, "stage fl2 teardown", 30_000);
    }
    pass("stage fl2 the flushed cookie survived kill -9");

    // ── fl3: linger — the engine outlives its last client ─────────
    const lingered: c.pid_t = blk: {
        const pid = spawnHelperArgs(exe, sock.ptr, cache.ptr, &.{ "--ozone-platform=headless", "--linger-ms", "6000" });
        g_pid = pid;
        var a = Client{ .gpa = gpa, .fd = connectWithRetry(sock.ptr, sock.len) };
        a.send(proto.Hello{ .proto = proto.PROTO_VERSION, .client_name = "smoke-web-fl-c" });
        {
            const d = nowMs() + 15_000;
            while (a.ack_proto == 0 and nowMs() < d) a.pump(100);
        }
        if (a.ack_proto != proto.PROTO_VERSION) fail("stage fl3: no hello_ack");
        a.send(proto.ContextCreate{ .id = ctx_id, .ephemeral = 0, .name = "flushdemo", .proxy = "" });
        openInProfile(&a, ctx_id, set_url, "jarA:", "stage fl3");
        a.have_view = false;
        a.teardown_allow_close = true;
        a.deinit();

        // Last client gone; a lingering engine must NOT exit.
        _ = c.usleep(700_000);
        var status: c_int = 0;
        if (c.waitpid(pid, &status, c.WNOHANG) == pid) {
            g_pid = -1;
            fail("stage fl3: the engine exited with its last client despite --linger-ms");
        }

        // A successor inside the window gets the same LIVE jar.
        var b = Client{ .gpa = gpa, .fd = connectWithRetry(sock.ptr, sock.len) };
        b.send(proto.Hello{ .proto = proto.PROTO_VERSION, .client_name = "smoke-web-fl-d" });
        {
            const d = nowMs() + 15_000;
            while (b.ack_proto == 0 and nowMs() < d) b.pump(100);
        }
        if (b.ack_proto != proto.PROTO_VERSION) fail("stage fl3: the lingering engine refused a successor client");
        b.send(proto.ContextCreate{ .id = ctx_id, .ephemeral = 0, .name = "flushdemo", .proxy = "" });
        openInProfile(&b, ctx_id, plain_url, "jarB:", "stage fl3 successor");
        if (std.mem.indexOf(u8, b.titleSlice(), jar_cookie) == null)
            fail("stage fl3: the successor did not see the lingering engine's live jar");
        b.have_view = false;
        b.teardown_allow_close = true;
        b.deinit();
        break :blk pid;
    };
    pass("stage fl3 the engine lingered past its last client and served a successor the same jar");

    // ── fl4: the TTL reap is graceful and flushes ─────────────────
    // Nobody reconnects; the engine must exit ON ITS OWN within the
    // linger window plus the drain budget, through the clean path.
    {
        // Linger window (6s) + the server's 5s drain budget + slack.
        const deadline = nowMs() + 6_000 + 5_000 + 10_000;
        var status: c_int = 0;
        var reaped = false;
        while (nowMs() < deadline) {
            if (c.waitpid(lingered, &status, c.WNOHANG) == lingered) {
                reaped = true;
                break;
            }
            _ = c.usleep(100_000);
        }
        g_pid = -1;
        if (!reaped) {
            _ = c.kill(lingered, c.SIGKILL);
            _ = c.waitpid(lingered, &status, 0);
            fail("stage fl4: the lingering engine never reaped itself after its TTL");
        }
        if (status & 0x7f != 0)
            std.debug.print("smoke-web: NOTE stage fl4: TTL reap exited on signal {d} (CEF shutdown artifact)\n", .{status & 0x7f});

        // The reap ran cef_shutdown (or the entry flush): fl3's cookie
        // must be on disk with no explicit flush ever sent for it.
        const pid = spawnHelperArgs(exe, sock.ptr, cache.ptr, &.{"--ozone-platform=headless"});
        g_pid = pid;
        var d2 = Client{ .gpa = gpa, .fd = connectWithRetry(sock.ptr, sock.len) };
        d2.send(proto.Hello{ .proto = proto.PROTO_VERSION, .client_name = "smoke-web-fl-e" });
        {
            const d = nowMs() + 15_000;
            while (d2.ack_proto == 0 and nowMs() < d) d2.pump(100);
        }
        if (d2.ack_proto != proto.PROTO_VERSION) fail("stage fl4: no hello_ack after the TTL reap");
        d2.send(proto.ContextCreate{ .id = ctx_id, .ephemeral = 0, .name = "flushdemo", .proxy = "" });
        openInProfile(&d2, ctx_id, plain_url, "jarB:", "stage fl4");
        if (std.mem.indexOf(u8, d2.titleSlice(), jar_cookie) == null)
            fail("stage fl4: the TTL reap lost the jar (the reap was not the graceful path)");
        d2.have_view = false;
        d2.deinit();
        reapHelperTimeout(pid, "stage fl4 teardown", 30_000);
    }
    pass("stage fl4 the TTL reap was graceful: the jar survived with no explicit flush");
}

// ── Stage 42: cross-instance cookie synchronisation ─────────────────
//
// TWO REAL HELPERS with SEPARATE `--cache-dir`s, i.e. two profiles and
// two jars — the shape sketerm runs when it puts one helper on each
// network route. This rig plays the part the GUI will play: it
// subscribes to both, and forwards a change observed on one as a
// `cookie_apply` to the other.
//
// What it measures, in order:
//   a. a `Set-Cookie` RESPONSE HEADER in A reaches B with every
//      attribute intact, HttpOnly included;
//   b. a `document.cookie` write in A reaches B — and WHICH observer
//      carried it, printed either way, because that is the coverage
//      question this feature turns on;
//   c. a script-side deletion reaches B;
//   d. with forwarding turned on in BOTH directions, the traffic
//      CONVERGES instead of ping-ponging;
//   e. an HttpOnly cookie is still HttpOnly after the round trip, and
//      so is every other attribute, measured on a synthetic cookie
//      that sets each one to a non-default value;
//   f. the dump PAGES a jar bigger than one page instead of truncating
//      it or building one enormous frame.
/// The second helper of stage 42, killed by EXACT pid like the first.
var g_pid_b: c.pid_t = -1;

fn pumpBoth(a: *Client, b: *Client, ms: c_int) void {
    a.pump(ms);
    b.pump(0);
}

/// Pump both connections until `pred` or the deadline.
fn waitBoth(a: *Client, b: *Client, timeout_ms: i64, ctx: anytype, pred: *const fn (@TypeOf(ctx)) bool) bool {
    const deadline = nowMs() + timeout_ms;
    while (true) {
        if (pred(ctx)) return true;
        if (nowMs() > deadline) return false;
        pumpBoth(a, b, 25);
    }
}

/// Hand one observed change to the other instance and wait for the
/// correlated answer. Returns false when the apply was refused.
fn forwardChange(from: *Client, to: *Client, ck: *const CkCookie, req: u32) bool {
    const st = to.ck.?;
    const seq = st.apply_seq;
    to.send(proto.CookieApply{
        .req = req,
        .context = 0,
        .remove = ck.removed,
        .url = ck.urlSlice(),
        .cookie = ck.wire(),
    });
    const Ctx = struct { st: *CkState, seq: u32 };
    var wc = Ctx{ .st = st, .seq = seq };
    const ok = waitBoth(from, to, 15_000, &wc, struct {
        fn f(x: *Ctx) bool {
            return x.st.apply_seq > x.seq;
        }
    }.f);
    if (!ok) return false;
    if (st.apply_req != req) fail("stage 42: ev_cookie_apply_done echoed the wrong request id");
    return st.apply_ok != 0;
}

/// One full dump of a context, following the cursor to the end.
/// Returns the number of PAGES it took, so the paging assertion has
/// something to check besides the contents.
fn dumpAll(a: *Client, b: *Client, target: *Client, req_base: u32, out: *std.ArrayList(CkCookie), gpa: std.mem.Allocator) u32 {
    const st = target.ck.?;
    out.clearRetainingCapacity();
    var cursor: u32 = 0;
    var pages: u32 = 0;
    while (true) {
        const seq = st.dump_seq;
        target.send(proto.CookieDumpReq{ .req = req_base + pages, .context = 0, .cursor = cursor });
        const Ctx = struct { st: *CkState, seq: u32 };
        var wc = Ctx{ .st = st, .seq = seq };
        if (!waitBoth(a, b, 15_000, &wc, struct {
            fn f(x: *Ctx) bool {
                return x.st.dump_seq > x.seq;
            }
        }.f)) fail("stage 42: a cookie_dump_req was never answered");
        if (st.dump_ok == 0) fail("stage 42: the cookie store could not be dumped");
        pages += 1;
        for (st.dump[0..st.dump_n]) |e| out.append(gpa, e) catch fail("stage 42: dump out of memory");
        if (st.dump_more == 0) break;
        if (st.dump_next == cursor) fail("stage 42: the dump cursor did not advance but claimed more");
        cursor = st.dump_next;
        if (pages > 64) fail("stage 42: the dump never terminated");
    }
    return pages;
}

fn findCookie(list: []const CkCookie, name: []const u8) ?*const CkCookie {
    for (list) |*e| {
        if (std.mem.eql(u8, e.nameSlice(), name)) return e;
    }
    return null;
}

fn runCookieSyncStage(gpa: std.mem.Allocator, exe: [*:0]const u8, dir: []const u8) void {
    var sock_a_buf: [96]u8 = undefined;
    var sock_b_buf: [96]u8 = undefined;
    const sock_a = std.fmt.bufPrintZ(&sock_a_buf, "{s}/cka.sock", .{dir}) catch fail("stage 42 socket path");
    const sock_b = std.fmt.bufPrintZ(&sock_b_buf, "{s}/ckb.sock", .{dir}) catch fail("stage 42 socket path");
    var cache_a_buf: [128]u8 = undefined;
    var cache_b_buf: [128]u8 = undefined;
    // SEPARATE profile directories: two jars is the whole premise.
    const cache_a = std.fmt.bufPrintZ(&cache_a_buf, "{s}/cache-cka", .{dir}) catch fail("stage 42 cache path");
    const cache_b = std.fmt.bufPrintZ(&cache_b_buf, "{s}/cache-ckb", .{dir}) catch fail("stage 42 cache path");

    // 1500ms rather than the 3s default: fast enough that the whole
    // stage runs in seconds, slow enough that a Set-Cookie header is
    // reliably attributed to the HEADER observer instead of racing the
    // reconcile that would also have found it. `SKETERM_SMOKE_CK_MS`
    // pushes it out of the way entirely, which is how the coverage
    // measurement in 42b was taken: with the reconcile at 600s, 42a
    // still passes and 42b finds NOTHING, which is the proof that
    // `can_save_cookie` sees response headers and not script writes.
    _ = c.setenv("SKETERM_WEB_COOKIE_SYNC_MS", c.getenv("SKETERM_SMOKE_CK_MS") orelse "1500", 1);
    const pid_a = spawnHelperArgs(exe, sock_a.ptr, cache_a.ptr, &.{"--ozone-platform=headless"});
    g_pid = pid_a;
    const pid_b = spawnHelperArgs(exe, sock_b.ptr, cache_b.ptr, &.{"--ozone-platform=headless"});
    g_pid_b = pid_b;
    _ = c.unsetenv("SKETERM_WEB_COOKIE_SYNC_MS");

    var st_a = gpa.create(CkState) catch fail("stage 42: out of memory");
    defer gpa.destroy(st_a);
    var st_b = gpa.create(CkState) catch fail("stage 42: out of memory");
    defer gpa.destroy(st_b);
    st_a.* = .{};
    st_b.* = .{};

    var a = Client{ .gpa = gpa, .fd = connectWithRetry(sock_a.ptr, sock_a.len), .ck = st_a };
    // connectWithRetry watches g_pid; B is up by now or never.
    var b = Client{ .gpa = gpa, .fd = connectWithRetry(sock_b.ptr, sock_b.len), .ck = st_b };

    a.send(proto.Hello{ .proto = proto.PROTO_VERSION, .client_name = "smoke-web-cksync-a" });
    b.send(proto.Hello{ .proto = proto.PROTO_VERSION, .client_name = "smoke-web-cksync-b" });
    {
        const d = nowMs() + 25_000;
        while ((a.ack_proto == 0 or b.ack_proto == 0) and nowMs() < d) pumpBoth(&a, &b, 100);
    }
    if (a.ack_proto != proto.PROTO_VERSION or b.ack_proto != proto.PROTO_VERSION)
        fail("stage 42 cookie sync: one of the two helpers never answered hello");
    if (!a.ack_cookie_sync or !b.ack_cookie_sync)
        fail("stage 42 cookie sync: hello_ack lacks the cookie-sync capability");

    var http = HttpProbe{ .cookie_router = true };
    if (!http.start()) fail("stage 42 cookie sync: could not start the loopback HTTP probe");
    defer http.shutdown();

    a.send(proto.CookieSyncEnable{ .enable = 1 });
    b.send(proto.CookieSyncEnable{ .enable = 1 });
    a.send(proto.ViewCreate{ .view = sync_view_a, .w = 320, .h = 240, .scale_x1000 = 1000, .context = 0 });
    a.have_view = true;

    // ── 41a: a Set-Cookie response header in A ────────────────────
    var url_buf: [96]u8 = undefined;
    const hdr_url = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/hdr", .{http.lis.port}) catch unreachable;
    a.send(proto.Navigate{ .view = sync_view_a, .url = hdr_url });
    if (!waitBoth(&a, &b, 25_000, st_a, struct {
        fn f(x: *CkState) bool {
            return x.lastChange(sync_hdr_cookie) != null;
        }
    }.f)) fail("stage 42a: instance A never observed its own Set-Cookie header");
    const hdr_change = st_a.lastChange(sync_hdr_cookie).?;
    if (hdr_change.cause != @intFromEnum(proto.CookieCause.response_header)) {
        std.debug.print("smoke-web: stage 42a cause was {d}\n", .{hdr_change.cause});
        fail("stage 42a: a Set-Cookie header was not attributed to the header observer");
    }
    if (!std.mem.eql(u8, hdr_change.valueSlice(), sync_hdr_value))
        fail("stage 42a: the observed value is not what the header set");
    if (hdr_change.flags & proto.cookie_httponly == 0)
        fail("stage 42a: HttpOnly was lost on the way out of the engine");
    if (hdr_change.same_site != @intFromEnum(proto.SameSite.strict))
        fail("stage 42a: SameSite=Strict was lost on the way out of the engine");
    if (hdr_change.expires_ms == 0 or hdr_change.flags & proto.cookie_session != 0)
        fail("stage 42a: a Max-Age cookie was observed as a session cookie");
    if (!forwardChange(&a, &b, hdr_change, 4101))
        fail("stage 42a: instance B refused the forwarded header cookie");

    var got: std.ArrayList(CkCookie) = .empty;
    defer got.deinit(gpa);
    _ = dumpAll(&a, &b, &b, 4110, &got, gpa);
    const in_b = findCookie(got.items, sync_hdr_cookie) orelse
        fail("stage 42a: the header cookie never reached instance B's jar");
    if (!std.mem.eql(u8, in_b.valueSlice(), sync_hdr_value))
        fail("stage 42a: the value changed crossing between instances");
    // (e): the security-relevant attributes, on the far side.
    if (in_b.flags & proto.cookie_httponly == 0)
        fail("stage 42e: an HttpOnly cookie stopped being HttpOnly after the round trip");
    if (in_b.same_site != @intFromEnum(proto.SameSite.strict))
        fail("stage 42e: SameSite=Strict was dropped in the round trip");
    if (in_b.expires_ms != hdr_change.expires_ms)
        fail("stage 42e: the expiry changed in the round trip (a persistent cookie would become a session cookie)");
    pass("stage 42a Set-Cookie header observed in A, applied to B with value, HttpOnly, SameSite and expiry intact");

    // ── 41b: document.cookie, and WHICH observer sees it ──────────
    //
    // This is the measurement the feature turns on. `can_save_cookie`
    // is a filter on cookies carried BY REQUESTS; a `document.cookie`
    // write never touches the network stack, so the expectation is
    // that only the reconcile sees it. Whatever actually happens is
    // reported rather than assumed.
    const js_url = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/js", .{http.lis.port}) catch unreachable;
    a.send(proto.Navigate{ .view = sync_view_a, .url = js_url });
    if (!waitBoth(&a, &b, 25_000, st_a, struct {
        fn f(x: *CkState) bool {
            return x.lastChange(sync_js_cookie) != null;
        }
    }.f)) fail("stage 42b: a document.cookie write reached NEITHER observer — the JS gap is not covered");
    const js_change = st_a.lastChange(sync_js_cookie).?;
    switch (@as(proto.CookieCause, @enumFromInt(js_change.cause))) {
        .response_header => say("smoke-web: stage 42b MEASURED: can_save_cookie DOES fire for document.cookie on this CEF"),
        .reconcile => say("smoke-web: stage 42b MEASURED: can_save_cookie does NOT fire for document.cookie; the reconcile covered it"),
        else => fail("stage 42b: the change arrived under an unknown cause"),
    }
    if (!std.mem.eql(u8, js_change.valueSlice(), sync_js_value))
        fail("stage 42b: the script-set value was not observed correctly");
    if (!forwardChange(&a, &b, js_change, 4102))
        fail("stage 42b: instance B refused the forwarded script-set cookie");
    _ = dumpAll(&a, &b, &b, 4120, &got, gpa);
    if (findCookie(got.items, sync_js_cookie) == null)
        fail("stage 42b: the script-set cookie never reached instance B's jar");
    pass("stage 42b document.cookie write in A reached B");

    // ── 41c: deletion propagates ──────────────────────────────────
    const del_seq = st_a.seq;
    const del_url = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/del", .{http.lis.port}) catch unreachable;
    a.send(proto.Navigate{ .view = sync_view_a, .url = del_url });
    const DelCtx = struct { st: *CkState, from: u32 };
    var dc = DelCtx{ .st = st_a, .from = del_seq };
    if (!waitBoth(&a, &b, 25_000, &dc, struct {
        fn f(x: *DelCtx) bool {
            if (x.st.seq <= x.from) return false;
            const e = x.st.lastChange(sync_js_cookie) orelse return false;
            return e.removed != 0;
        }
    }.f)) fail("stage 42c: a script-side deletion was never observed (no observer covers deletion)");
    const del_change = st_a.lastChange(sync_js_cookie).?;
    if (del_change.cause != @intFromEnum(proto.CookieCause.reconcile))
        say("smoke-web: stage 42c NOTE: the deletion was attributed to the header observer");
    if (!forwardChange(&a, &b, del_change, 4103))
        fail("stage 42c: instance B refused the forwarded deletion");
    _ = dumpAll(&a, &b, &b, 4130, &got, gpa);
    if (findCookie(got.items, sync_js_cookie) != null)
        fail("stage 42c: the deleted cookie is still in instance B's jar");
    pass("stage 42c a script-side deletion in A removed the cookie in B");

    // ── 41e: every attribute, at a non-default value ──────────────
    //
    // Applied rather than served, because the attribute matrix needs a
    // Secure cookie and an https origin — which a loopback HTTP
    // fixture cannot provide and which no engine will store off one.
    const expires = syncAttrExpiresMs();
    const attr = proto.SyncCookie{
        .name = sync_attr_cookie,
        .value = sync_attr_value,
        .domain = sync_attr_domain,
        .path = sync_attr_path,
        .flags = proto.cookie_secure | proto.cookie_httponly,
        .same_site = @intFromEnum(proto.SameSite.strict),
        .priority = @intFromEnum(proto.CookiePriority.high),
        .creation_ms = 1_600_000_000_000,
        .last_access_ms = 1_600_000_100_000,
        .expires_ms = expires,
    };
    {
        const seq = st_b.apply_seq;
        b.send(proto.CookieApply{
            .req = 4104,
            .context = 0,
            .remove = 0,
            .url = sync_attr_url,
            .cookie = attr,
        });
        const Ctx = struct { st: *CkState, seq: u32 };
        var wc = Ctx{ .st = st_b, .seq = seq };
        if (!waitBoth(&a, &b, 15_000, &wc, struct {
            fn f(x: *Ctx) bool {
                return x.st.apply_seq > x.seq;
            }
        }.f)) fail("stage 42e: the attribute-matrix apply was never answered");
        if (st_b.apply_ok == 0) {
            std.debug.print("smoke-web: stage 42e apply said \"{s}\"\n", .{st_b.apply_reason[0..st_b.apply_reason_len]});
            fail("stage 42e: the engine refused a fully-specified cookie");
        }
    }
    _ = dumpAll(&a, &b, &b, 4140, &got, gpa);
    const back = findCookie(got.items, sync_attr_cookie) orelse
        fail("stage 42e: the fully-specified cookie is not in the jar it was written to");
    var lost: [512]u8 = undefined;
    var lost_len: usize = 0;
    const note = struct {
        fn f(buf: []u8, len: *usize, what: []const u8) void {
            if (len.* + what.len + 1 > buf.len) return;
            if (len.* != 0) {
                buf[len.*] = ',';
                len.* += 1;
            }
            @memcpy(buf[len.*..][0..what.len], what);
            len.* += what.len;
        }
    }.f;
    if (!std.mem.eql(u8, back.valueSlice(), sync_attr_value)) note(&lost, &lost_len, "value");
    if (back.flags & proto.cookie_secure == 0) note(&lost, &lost_len, "secure");
    if (back.flags & proto.cookie_httponly == 0) note(&lost, &lost_len, "httponly");
    if (back.same_site != @intFromEnum(proto.SameSite.strict)) note(&lost, &lost_len, "samesite");
    if (back.priority != @intFromEnum(proto.CookiePriority.high)) note(&lost, &lost_len, "priority");
    if (back.expires_ms != expires) note(&lost, &lost_len, "expires");
    if (back.flags & proto.cookie_session != 0) note(&lost, &lost_len, "persistence");
    if (!std.mem.eql(u8, back.path[0..back.path_len], sync_attr_path)) note(&lost, &lost_len, "path");
    if (std.mem.indexOf(u8, back.domain[0..back.domain_len], sync_attr_domain) == null) note(&lost, &lost_len, "domain");
    if (lost_len != 0) {
        std.debug.print(
            "smoke-web: stage 42e attributes NOT preserved: {s} (asked expiry {d}, got {d})\n",
            .{ lost[0..lost_len], expires, back.expires_ms },
        );
        fail("stage 42e: an attribute did not survive apply -> jar -> dump");
    }
    // `creation` and `last_access` are engine-populated on write; the
    // wire carries them, the engine does not honour them, and that is
    // reported rather than asserted either way.
    if (back.creation_ms != attr.creation_ms)
        say("smoke-web: stage 42e NOTE: the engine re-stamps creation on set_cookie (wire value not honoured)");
    pass("stage 42e value, Secure, HttpOnly, SameSite, priority, path, domain and expiry all survive apply -> jar -> dump");

    // ── 41f: the dump PAGES a big jar ─────────────────────────────
    {
        var i: u32 = 0;
        var last_seq = st_b.apply_seq;
        while (i < sync_bulk_count) : (i += 1) {
            var nbuf: [64]u8 = undefined;
            const name = std.fmt.bufPrint(&nbuf, "sk_bulk_{d}", .{i}) catch unreachable;
            b.send(proto.CookieApply{
                .req = 4200 + i,
                .context = 0,
                .remove = 0,
                .url = sync_bulk_url,
                .cookie = .{
                    .name = name,
                    .value = "bulk",
                    .domain = "sync-bulk.example",
                    .path = "/",
                    .flags = 0,
                    .same_site = @intFromEnum(proto.SameSite.lax),
                    .priority = @intFromEnum(proto.CookiePriority.medium),
                    .creation_ms = 0,
                    .last_access_ms = 0,
                    .expires_ms = expires,
                },
            });
            pumpBoth(&a, &b, 0);
        }
        const Ctx = struct { st: *CkState, want: u32 };
        var wc = Ctx{ .st = st_b, .want = last_seq + sync_bulk_count };
        if (!waitBoth(&a, &b, 60_000, &wc, struct {
            fn f(x: *Ctx) bool {
                return x.st.apply_seq >= x.want;
            }
        }.f)) fail("stage 42f: not every bulk apply was answered");
        last_seq = st_b.apply_seq;
    }
    const pages = dumpAll(&a, &b, &b, 4400, &got, gpa);
    if (pages < 2) {
        std.debug.print("smoke-web: stage 42f dumped {d} cookies in {d} page(s)\n", .{ got.items.len, pages });
        fail("stage 42f: a jar past one page was not paged");
    }
    if (got.items.len < sync_bulk_count)
        fail("stage 42f: the paged dump lost cookies");
    {
        var missing: u32 = 0;
        var i: u32 = 0;
        while (i < sync_bulk_count) : (i += 1) {
            var nbuf: [64]u8 = undefined;
            const name = std.fmt.bufPrint(&nbuf, "sk_bulk_{d}", .{i}) catch unreachable;
            if (findCookie(got.items, name) == null) missing += 1;
        }
        if (missing != 0) {
            std.debug.print("smoke-web: stage 42f {d} of {d} bulk cookies missing\n", .{ missing, sync_bulk_count });
            fail("stage 42f: the paged dump did not carry every cookie");
        }
    }
    pass("stage 42f a jar past one page dumps in bounded pages, losing nothing");

    // ── 41d: no ping-pong ─────────────────────────────────────────
    //
    // Forwarding is turned on in BOTH directions now, which is the
    // production fan-out and the only shape a loop can appear in. A
    // ping-pong is UNBOUNDED GROWTH, so the assertion is that the
    // traffic stops: whatever settles in the first window must not
    // grow in the second.
    {
        // Seed REAL traffic first, or "it converged" would be a
        // statement about a rig that never sent anything: A writes the
        // script cookie again, which A observes, the rig forwards, B
        // applies — the exact cycle a loop would live in.
        const again_url = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/js", .{http.lis.port}) catch unreachable;
        a.send(proto.Navigate{ .view = sync_view_a, .url = again_url });

        var forwarded: u32 = 0;
        var seen_a = st_a.seq;
        var seen_b = st_b.seq;
        const window_ms: i64 = 2_500;

        var round: u32 = 0;
        var first_window: u32 = 0;
        while (round < 2) : (round += 1) {
            const deadline = nowMs() + window_ms;
            var in_window: u32 = 0;
            while (nowMs() < deadline) {
                pumpBoth(&a, &b, 25);
                while (st_a.seq > seen_a) {
                    seen_a += 1;
                    const idx = (st_a.head + st_a.q.len - 1) % st_a.q.len;
                    const e = st_a.q[idx];
                    b.send(proto.CookieApply{
                        .req = 4600 + forwarded,
                        .context = 0,
                        .remove = e.removed,
                        .url = e.urlSlice(),
                        .cookie = e.wire(),
                    });
                    forwarded += 1;
                    in_window += 1;
                }
                while (st_b.seq > seen_b) {
                    seen_b += 1;
                    const idx = (st_b.head + st_b.q.len - 1) % st_b.q.len;
                    const e = st_b.q[idx];
                    a.send(proto.CookieApply{
                        .req = 4800 + forwarded,
                        .context = 0,
                        .remove = e.removed,
                        .url = e.urlSlice(),
                        .cookie = e.wire(),
                    });
                    forwarded += 1;
                    in_window += 1;
                }
            }
            if (round == 0) {
                first_window = in_window;
                if (in_window == 0)
                    fail("stage 42d: nothing was forwarded at all — the convergence assertion would be vacuous");
            } else if (in_window != 0) {
                std.debug.print(
                    "smoke-web: stage 42d forwarded {d} then {d} changes in consecutive {d}ms windows\n",
                    .{ first_window, in_window, window_ms },
                );
                fail("stage 42d: cookie changes kept arriving with both directions forwarding — that is a ping-pong");
            }
        }
        std.debug.print(
            "smoke-web: stage 42d MEASURED: {d} change(s) forwarded in the first {d}ms window, 0 in the second\n",
            .{ first_window, window_ms },
        );
    }
    pass("stage 42d applying a synced cookie does not re-emit it (bidirectional forwarding converges)");

    // ── teardown ──────────────────────────────────────────────────
    a.send(proto.CookieSyncEnable{ .enable = 0 });
    b.send(proto.CookieSyncEnable{ .enable = 0 });
    a.send(proto.ViewDestroy{ .view = sync_view_a });
    a.have_view = false;
    a.teardown_allow_close = true;
    b.teardown_allow_close = true;
    {
        const d = nowMs() + 2_000;
        while (nowMs() < d) pumpBoth(&a, &b, 50);
    }
    a.deinit();
    b.deinit();
    reapHelperTimeout(pid_a, "stage 42 teardown A", 30_000);
    g_pid = -1;
    reapHelperTimeout(pid_b, "stage 42 teardown B", 30_000);
    g_pid_b = -1;
}

pub fn main(init: std.process.Init.Minimal) u8 {
    _ = c.signal(c.SIGPIPE, &sigNoop);
    const argv = init.args.vector;
    if (argv.len < 2) {
        std.debug.print("smoke-web: usage: smoke-web <path-to-sketerm-web>\n", .{});
        return 2;
    }
    const exe = argv[1];
    if (c.access(exe, c.X_OK) != 0) fail("sketerm-web binary is not executable");
    // Stage 32's private mux daemon (and anything it forks) shuts down
    // when this process is gone, by any exit path; `cleanup` is the
    // orderly version.
    if (!@import("util/lifetime.zig").arm()) fail("lifetime fence");
    // argv[3] is stage 35b's real-extension fixture: a PATH that may
    // legitimately not exist (the stage then reports itself skipped).
    const ubo_xpi: []const u8 = if (argv.len > 3) std.mem.span(argv[3]) else "";
    g_echo_console = c.getenv("SKETERM_SMOKE_WEB_CONSOLE") != null;

    var gpa_state: std.heap.DebugAllocator(.{ .safety = true }) = .{};
    const gpa = gpa_state.allocator();

    // Short private paths: sockaddr_un caps at ~108 bytes, so the
    // socket cannot live under a deep scratch directory.
    const tmpl = "/tmp/skweb-XXXXXX";
    @memcpy(g_dir[0..tmpl.len], tmpl);
    if (c.mkdtemp(@ptrCast(&g_dir)) == null) fail("mkdtemp");
    const dir = std.mem.span(@as([*:0]const u8, @ptrCast(&g_dir)));

    // Focused run for the flush/linger family (iterating on a late
    // stage without paying the ~35 before it), the
    // SKETERM_SMOKE_MCP_WEBSHARED_ONLY precedent.
    if (c.getenv("SKETERM_SMOKE_WEB_FL_ONLY") != null) {
        runFlushLingerStage(gpa, exe, dir);
        cleanup();
        if (gpa_state.deinit() == .leak) {
            say("smoke-web: FAIL leaked memory (see GPA report above)");
            return 1;
        }
        say("smoke-web: PASS (fl only)");
        return 0;
    }
    if (c.getenv("SKETERM_SMOKE_WEB_COOKIE_SYNC_ONLY") != null) {
        runCookieSyncStage(gpa, exe, dir);
        cleanup();
        if (gpa_state.deinit() == .leak) {
            say("smoke-web: FAIL leaked memory (see GPA report above)");
            return 1;
        }
        say("smoke-web: PASS (cookie sync only)");
        return 0;
    }

    var sock_buf: [96]u8 = undefined;
    const sock = std.fmt.bufPrintZ(&sock_buf, "{s}/w.sock", .{dir}) catch fail("socket path");
    var cache_buf: [96]u8 = undefined;
    const cache = std.fmt.bufPrintZ(&cache_buf, "{s}/cache", .{dir}) catch fail("cache path");

    // ── Spawn the helper ──────────────────────────────────────────
    //
    // Pinned to headless software rendering: 22 of the stages below
    // assert on pixels in the memfd, and the GPU path delivers dma-buf
    // planes instead. The GPU path gets its own helper in stage 24.
    const pid = spawnHelper(exe, sock.ptr, cache.ptr, "--ozone-platform=headless", null, false);
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
    if (!cl.ack_reader_ids) fail("stage 1 handshake: hello_ack lacks the reader-ids capability");
    if (!cl.ack_semantic_request_ids) fail("stage 1 handshake: hello_ack lacks semantic request ids");
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

    // ── Stage 3b: a trusted SPA route change keeps the helper alive ─
    // CEF 151.3.18 crashes in ReadAnythingSoftNavigationObserver after
    // this transition unless ImmersiveReadAnything is disabled: Alloy
    // windowless WebContents has no Chrome TabInterface, but that
    // observer used the crash-only GetFromContents accessor.
    {
        var http = HttpProbe{ .body = spa_page };
        if (!http.start()) fail("stage 3b SPA: HTTP fixture did not start");
        var url_buf: [128]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{http.lis.port}) catch fail("stage 3b SPA url");
        cl.navigate(url);
        cl.resetSem();
        cl.snapshot(@intFromEnum(proto.SnapMode.full), 1);
        const learn_id = cl.idOfLine("link \"Learn SPA Route\"") orelse {
            std.debug.print("smoke-web: stage 3b snapshot was:\n{s}\n", .{cl.semLog()});
            fail("stage 3b SPA: route link was absent from the semantic tree");
        };
        const acted = cl.act_seq;
        cl.send(proto.SemAction{
            .view = view_id,
            .id = learn_id,
            .action = @intFromEnum(proto.SemAct.click),
            .arg = "",
        });
        if (!cl.waitSeq(&cl.act_seq, acted, 20_000) or cl.act_ok != 1)
            fail("stage 3b SPA: trusted semantic click failed");
        if (!cl.waitTitle("spa:trusted=true:/learn", 15_000))
            fail("stage 3b SPA: the trusted route transition did not finish");
        _ = cl.drive(2_000, 120);
        const path = cl.evalWait("location.pathname", false, 15_000);
        if (std.mem.indexOf(u8, path, "/learn") == null)
            fail("stage 3b SPA: helper survived but lost the soft-navigation route");
        http.shutdown();
    }
    pass("stage 3b trusted SPA soft navigation");

    // ── Stage 3c: CSP without unsafe-eval - the spliced lane ───────
    // eval() of a string dies under `script-src` with no 'unsafe-eval';
    // the helper re-sends the code compiled INTO the command script, so
    // an EXPRESSION still answers and a statement list gets a described
    // refusal instead of a 120s timeout. The same page proves the act
    // echoes (what a click resolved to) and the landed-value read after
    // a framework-style input recreation.
    {
        var http = HttpProbe{ .body = csp_eval_page, .extra_headers = csp_header };
        if (!http.start()) fail("stage 3c CSP: HTTP fixture did not start");
        var url_buf: [128]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{http.lis.port}) catch fail("stage 3c CSP url");
        cl.navigate(url);
        cl.resetSem();
        cl.snapshot(@intFromEnum(proto.SnapMode.full), 1);
        if (!cl.waitSem("link \"CSP Link\"", 20_000)) fail("stage 3c CSP: no snapshot of the fixture");

        const two = cl.evalWait("1+1", false, 20_000);
        if (std.mem.indexOf(u8, two, "\"value\":2") == null) {
            std.debug.print("smoke-web: CSP eval said {s}\n", .{two});
            fail("stage 3c CSP: an expression did not evaluate under CSP");
        }
        const dom = cl.evalWait("document.querySelectorAll('a').length", false, 20_000);
        if (std.mem.indexOf(u8, dom, "\"value\":1") == null)
            fail("stage 3c CSP: a DOM-reading expression did not evaluate under CSP");
        const stmt = cl.evalWait("var x = 3; x + 1", false, 20_000);
        if (std.mem.indexOf(u8, stmt, "one expression") == null) {
            std.debug.print("smoke-web: CSP statement eval said {s}\n", .{stmt});
            fail("stage 3c CSP: a statement list did not get the described expression-only refusal");
        }

        const link_id = cl.idOfLine("link \"CSP Link\"") orelse fail("stage 3c CSP: no id for the link");
        {
            const seq = cl.act_seq;
            cl.send(proto.SemAction{
                .view = view_id,
                .id = link_id,
                .action = @intFromEnum(proto.SemAct.click),
                .arg = "",
            });
            if (!cl.waitSeq(&cl.act_seq, seq, 20_000) or cl.act_ok != 1) fail("stage 3c CSP: click failed");
            const msg = cl.act_msg[0..cl.act_msg_len];
            if (std.mem.indexOf(u8, msg, "on link \"CSP Link\"") == null) {
                std.debug.print("smoke-web: click said \"{s}\"\n", .{msg});
                fail("stage 3c CSP: the click result did not echo what the id resolved to");
            }
        }

        const field_id = cl.idOfLine("textbox \"vfield\"") orelse fail("stage 3c CSP: no id for the input");
        {
            const seq = cl.act_seq;
            cl.send(proto.SemAction{
                .view = view_id,
                .id = field_id,
                .action = @intFromEnum(proto.SemAct.set_value),
                .arg = "abcdef",
            });
            if (!cl.waitSeq(&cl.act_seq, seq, 20_000)) fail("stage 3c CSP: no set_value result");
            const msg = cl.act_msg[0..cl.act_msg_len];
            if (cl.act_ok != 1 or std.mem.indexOf(u8, msg, "replaced while typing") == null) {
                std.debug.print("smoke-web: set_value said \"{s}\"\n", .{msg});
                fail("stage 3c CSP: a recreated input did not report the replacement with its landed value");
            }
        }
        http.shutdown();
    }
    pass("stage 3c CSP spliced eval, act echoes, landed value");

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

    // ── Stage 11b: a modal hides the page; closing it restores ids ─
    // The differ binds ids to the element for the document's lifetime,
    // so the chrome that a modal made inert comes back under its old
    // ids and is summarised on one line instead of re-sent in full.
    cl.navigate(modal_page);
    // A query BEFORE any walk of this document solicits one instead of
    // answering "no snapshot yet": act-by-name right after an open with
    // the first snapshot skipped must not cost a snapshot turn.
    {
        const seq = cl.query_seq;
        cl.send(proto.SemQueryReq{ .view = view_id, .kind = @intFromEnum(proto.SemQuery.find_text), .arg = "Hosts" });
        if (!cl.waitSeq(&cl.query_seq, seq, 20_000)) fail("stage 11b modal: no sem_query_result before the first walk");
        if (std.mem.indexOf(u8, cl.queryPayload(), "link \"Hosts\"") == null) {
            std.debug.print("smoke-web: query result was:\n{s}\n", .{cl.queryPayload()});
            fail("stage 11b modal: a query before the first walk did not solicit one");
        }
    }
    cl.resetSem();
    cl.snapshot(@intFromEnum(proto.SnapMode.full), 1);
    if (!cl.waitSem("link \"Hosts\"", 20_000)) fail("stage 11b modal: no snapshot of the page");
    const hosts_link = cl.idOfLine("link \"Hosts\"") orelse fail("stage 11b modal: no id for the nav link");
    _ = cl.evalWait("openDlg(); 1", false, 20_000);
    cl.resetSem();
    cl.snapshot(@intFromEnum(proto.SnapMode.auto), 1);
    if (!cl.waitSem("alertdialog", 20_000)) fail("stage 11b modal: the dialog never appeared in a snapshot");
    if (std.mem.indexOf(u8, cl.semLog(), "link \"Hosts\"") != null) fail("stage 11b modal: inert chrome was still listed");
    _ = cl.evalWait("closeDlg(); 1", false, 20_000);
    // A peek in between (what web_wait polls with) must not consume
    // the base: the restore is still owed to the next real snapshot.
    cl.resetSem();
    cl.snapshot(@intFromEnum(proto.SnapMode.peek), 1);
    if (std.mem.indexOf(u8, cl.semLog(), "restored") != null or std.mem.indexOf(u8, cl.semLog(), "[") != null)
        fail("stage 11b modal: a peek snapshot carried tree content");
    cl.resetSem();
    cl.snapshot(@intFromEnum(proto.SnapMode.auto), 1);
    if (!cl.waitSem("restored unchanged:", 20_000)) {
        std.debug.print("smoke-web: post-close payload was:\n{s}\n", .{cl.semLog()});
        fail("stage 11b modal: closing the dialog did not report the page as restored");
    }
    if (std.mem.indexOf(u8, cl.semLog(), "+ [") != null) fail("stage 11b modal: restored chrome was re-sent as additions");
    if (std.mem.indexOf(u8, cl.semLog(), "- [") == null) fail("stage 11b modal: the dialog's removal was not reported");
    cl.resetSem();
    cl.snapshot(@intFromEnum(proto.SnapMode.full), 1);
    if (!cl.waitSem("link \"Hosts\"", 20_000)) fail("stage 11b modal: no snapshot after the dialog closed");
    {
        const after = cl.idOfLine("link \"Hosts\"") orelse fail("stage 11b modal: no id after the dialog closed");
        if (after != hosts_link) fail("stage 11b modal: the nav link did not keep its id across the modal");
    }
    pass("stage 11b modal hide/restore");

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
        // Tables and form controls are what an admin page is made of;
        // reader mode used to reduce such a page to its heading.
        if (std.mem.indexOf(u8, markdown, "| Name | Type |\n| --- | --- |\n| local | Docker |\n| remote | SSH |") == null) {
            std.debug.print("smoke-web: markdown was:\n{s}\n", .{markdown});
            fail("stage 12 sem_read: the table is missing from the markdown");
        }
        // A component library's list is an ARIA table built from divs.
        if (std.mem.indexOf(u8, markdown, "**Fleet**\n| Host |\n| --- |\n| aria cell |") == null) {
            std.debug.print("smoke-web: markdown was:\n{s}\n", .{markdown});
            fail("stage 12 sem_read: the ARIA table is missing from the markdown");
        }
        if (std.mem.indexOf(u8, markdown, "- Owner: jelle") == null or
            std.mem.indexOf(u8, markdown, "- Tier: Pro") == null or
            std.mem.indexOf(u8, markdown, "- [x] Enabled") == null)
        {
            std.debug.print("smoke-web: markdown was:\n{s}\n", .{markdown});
            fail("stage 12 sem_read: form controls are missing from the markdown");
        }
    }
    // The form query: what Apply would submit, from the live tree, with
    // values and states, no DOM script.
    {
        cl.resetSem();
        cl.snapshot(@intFromEnum(proto.SnapMode.full), 1);
        if (!cl.waitSem("textbox \"Owner\"", 20_000)) fail("stage 12 form: no snapshot of the article page");
        const seq = cl.query_seq;
        cl.send(proto.SemQueryReq{ .view = view_id, .kind = @intFromEnum(proto.SemQuery.form), .arg = "" });
        if (!cl.waitSeq(&cl.query_seq, seq, 20_000)) fail("stage 12 form: no form query result");
        const payload = cl.queryPayload();
        if (std.mem.indexOf(u8, payload, "textbox \"Owner\" value=\"jelle\"") == null or
            std.mem.indexOf(u8, payload, "checkbox \"Enabled\" (checked)") == null or
            std.mem.indexOf(u8, payload, "combobox \"Tier\"") == null)
        {
            std.debug.print("smoke-web: form query result was:\n{s}\n", .{payload});
            fail("stage 12 form: the controls are not listed with their values and states");
        }
    }
    pass("stage 12 sem_read");

    // ── Stage 12b: a div grid — rows, reader table, within_text, echo ──
    // FRITZ!OS shape: 688 divs, zero <tr>, no roles. Both readers were
    // blind to the one thing on the page, and the only way to a row's
    // Edit was an nth index over identical buttons.
    cl.navigate(grid_page);
    cl.resetSem();
    cl.snapshot(@intFromEnum(proto.SnapMode.full), 1);
    if (!cl.waitSem("row \"PC-3 / LAN 3 / 10.47.1.3 / Edit\"", 20_000)) {
        std.debug.print("smoke-web: grid snapshot was:\n{s}\n", .{cl.semLog()});
        fail("stage 12b grid: repeated div siblings were not listed as rows");
    }
    if (std.mem.indexOf(u8, cl.semLog(), "] list {6 children}") == null and std.mem.indexOf(u8, cl.semLog(), "] list ") == null)
        fail("stage 12b grid: the rows' container is not a list");
    {
        const seq = cl.md_seq;
        cl.send(proto.SemRead{ .view = view_id });
        if (!cl.waitSeq(&cl.md_seq, seq, 20_000)) fail("stage 12b grid: no sem_read_result");
        const markdown = cl.md[0..cl.md_len];
        if (std.mem.indexOf(u8, markdown, "| PC-3 | LAN 3 | 10.47.1.3 | Edit |") == null or
            std.mem.indexOf(u8, markdown, "| PC-1 | LAN 1 | 10.47.1.1 | Edit |\n| --- | --- | --- | --- |") == null)
        {
            std.debug.print("smoke-web: markdown was:\n{s}\n", .{markdown});
            fail("stage 12b grid: the div rows are not a table in the markdown");
        }
        // A bare div with text beside the rows is a paragraph, not
        // nothing (the footer OUTSIDE the densest region is dropped by
        // the reader's region choice, deliberately).
        if (std.mem.indexOf(u8, markdown, "Six devices are known") == null) {
            std.debug.print("smoke-web: markdown was:\n{s}\n", .{markdown});
            fail("stage 12b grid: leaf div text is missing from the markdown");
        }
    }
    // within_text: the Edit in the row that says 10.47.1.30, and ONLY
    // that one; "10.47.1.3" is in two rows and must be refused.
    var edit5: u32 = 0;
    {
        const seq = cl.query_seq;
        cl.send(proto.SemQueryReq{ .view = view_id, .kind = @intFromEnum(proto.SemQuery.within_text), .arg = "{\"text\":\"10.47.1.30\",\"name\":\"Edit\",\"role\":\"button\"}" });
        if (!cl.waitSeq(&cl.query_seq, seq, 20_000)) fail("stage 12b grid: no within_text result");
        const payload = cl.queryPayload();
        if (std.mem.indexOf(u8, payload, "anchor [") == null or std.mem.indexOf(u8, payload, "row \"PC-5 / LAN 5 / 10.47.1.30 / Edit\" 1 matches") == null) {
            std.debug.print("smoke-web: within_text result was:\n{s}\n", .{payload});
            fail("stage 12b grid: within_text did not anchor on the one row carrying the text");
        }
        const line = std.mem.indexOf(u8, payload, "] button \"Edit\"") orelse fail("stage 12b grid: no Edit candidate line");
        const open = std.mem.lastIndexOfScalar(u8, payload[0..line], '[') orelse fail("stage 12b grid: malformed candidate line");
        edit5 = std.fmt.parseInt(u32, payload[open + 1 .. line], 10) catch fail("stage 12b grid: candidate id did not parse");
    }
    {
        const seq = cl.query_seq;
        cl.send(proto.SemQueryReq{ .view = view_id, .kind = @intFromEnum(proto.SemQuery.within_text), .arg = "{\"text\":\"10.47.1.3\",\"name\":\"Edit\"}" });
        if (!cl.waitSeq(&cl.query_seq, seq, 20_000)) fail("stage 12b grid: no second within_text result");
        if (std.mem.indexOf(u8, cl.queryPayload(), "ambiguous") == null) {
            std.debug.print("smoke-web: within_text result was:\n{s}\n", .{cl.queryPayload()});
            fail("stage 12b grid: a substring shared by two rows was not refused as ambiguous");
        }
    }
    // The click lands in row 5 and the echo SAYS row 5.
    {
        const seq = cl.act_seq;
        cl.send(proto.SemAction{ .view = view_id, .id = edit5, .action = @intFromEnum(proto.SemAct.click), .arg = "" });
        if (!cl.waitSeq(&cl.act_seq, seq, 20_000) or cl.act_ok != 1) fail("stage 12b grid: click on the row's Edit failed");
        const msg = cl.act_msg[0..cl.act_msg_len];
        if (std.mem.indexOf(u8, msg, "in row \"PC-5 / LAN 5 / 10.47.1.30 / Edit\"") == null) {
            std.debug.print("smoke-web: click said \"{s}\"\n", .{msg});
            fail("stage 12b grid: the click echo does not name the row");
        }
        if (!cl.waitTitle("edit:5", 20_000)) fail("stage 12b grid: the click did not land on row 5's Edit");
    }
    // An id nobody issued is refused with a reason, not a bare "unknown id".
    {
        const seq = cl.act_seq;
        cl.send(proto.SemAction{ .view = view_id, .id = 900_000, .action = @intFromEnum(proto.SemAct.click), .arg = "" });
        if (!cl.waitSeq(&cl.act_seq, seq, 20_000) or cl.act_ok != 0) fail("stage 12b grid: a bogus id was acted on");
        if (std.mem.indexOf(u8, cl.act_msg[0..cl.act_msg_len], "never issued") == null) {
            std.debug.print("smoke-web: bogus act said \"{s}\"\n", .{cl.act_msg[0..cl.act_msg_len]});
            fail("stage 12b grid: the unknown-id refusal does not say why");
        }
    }
    pass("stage 12b div grid");

    // ── Stage 41: reader ids activate one exact, fresh entity ──────
    cl.navigate(reader_ids_page);
    {
        const seq = cl.md_seq;
        cl.sem_result_request = 0;
        cl.sendSemantic(4101, proto.SemReadIds{ .view = view_id });
        if (!cl.waitSeq(&cl.md_seq, seq, 20_000)) fail("stage 41 reader ids: no sem_read_ids_result");
        if (cl.sem_result_request != 4101) fail("stage 41 reader ids: rich read lost its request id");
        if (cl.rich_id == 0 or cl.rich_doc == 0 or cl.rich_rev == 0)
            fail("stage 41 reader ids: the actionable reader link has no stable revision-stamped id");
        if (!std.mem.eql(u8, cl.rich_kind[0..cl.rich_kind_len], "link"))
            fail("stage 41 reader ids: the reader entity kind is not link");
        if (!std.mem.eql(u8, cl.rich_text[0..cl.rich_text_len], "Activate Reader Target"))
            fail("stage 41 reader ids: the reader entity text names the wrong node");
        cl.resetTitle();
        const acted = cl.act_seq;
        cl.sem_result_request = 0;
        cl.sendSemantic(4102, proto.SemActGuarded{
            .view = view_id,
            .doc_gen = cl.rich_doc,
            .rev = cl.rich_rev,
            .id = cl.rich_id,
            .guard = cl.rich_guard,
            .action = @intFromEnum(proto.SemAct.click),
            .arg = "",
        });
        if (!cl.waitSeq(&cl.act_seq, acted, 20_000)) fail("stage 41 reader ids: no guarded act result");
        if (cl.sem_result_request != 4102) fail("stage 41 reader ids: guarded action lost its request id");
        if (cl.act_ok != 1 or cl.act_id != cl.rich_id) fail("stage 41 reader ids: guarded act failed");
        if (!cl.waitTitle("reader:trusted=true", 15_000)) {
            std.debug.print("stage 41 reader ids: title was {s}\n", .{cl.titleSlice()});
            fail("stage 41 reader ids: reader id did not activate exactly its trusted target");
        }

        // Two same-kind operations can overlap on the correlated wire.
        // Delay the first so the second answers first, then prove both
        // late callbacks retain their own client request identity.
        _ = cl.evalWait("window.__sketerm_test_hooks=true;document.documentElement.setAttribute('data-sketerm-delay-read','1200');'armed'", false, 20_000);
        const concurrent = cl.md_seq;
        cl.sendSemantic(4103, proto.SemReadIds{ .view = view_id });
        cl.sendSemantic(4104, proto.SemReadIds{ .view = view_id });
        if (!cl.waitSeq(&cl.md_seq, concurrent, 20_000)) fail("stage 41 reader ids: concurrent rich read did not answer");
        if (cl.sem_result_request != 4104) fail("stage 41 reader ids: immediate rich reply matched the older request");
        if (!cl.waitSeq(&cl.md_seq, concurrent + 1, 20_000)) fail("stage 41 reader ids: delayed rich callback never arrived");
        if (cl.sem_result_request != 4103) fail("stage 41 reader ids: delayed rich callback lost its request id");

        // Re-read, mutate only the target href, then prove the action
        // fingerprint refuses it even though semantic revisions
        // deliberately ignore href changes for ordinary snapshot ids.
        const read2 = cl.md_seq;
        cl.send(proto.SemReadIds{ .view = view_id });
        if (!cl.waitSeq(&cl.md_seq, read2, 20_000)) fail("stage 41 reader ids: no second rich read");
        const doc = cl.rich_doc;
        const rev = cl.rich_rev;
        const id = cl.rich_id;
        const guard = cl.rich_guard;
        _ = cl.evalWait("document.getElementById('reader-go').href='#changed';'mutated'", false, 20_000);
        const stale = cl.act_seq;
        cl.send(proto.SemActGuarded{
            .view = view_id,
            .doc_gen = doc,
            .rev = rev,
            .id = id,
            .guard = guard,
            .action = @intFromEnum(proto.SemAct.click),
            .arg = "",
        });
        if (!cl.waitSeq(&cl.act_seq, stale, 20_000)) fail("stage 41 reader ids: no stale act result");
        if (cl.act_ok != 0 or std.mem.indexOf(u8, cl.act_msg[0..cl.act_msg_len], "stale reader id") == null) {
            std.debug.print("stage 41 reader ids: stale act ok={d} msg={s}\n", .{ cl.act_ok, cl.act_msg[0..cl.act_msg_len] });
            fail("stage 41 reader ids: a changed entity was not honestly refused as stale");
        }

        // A legacy read and a rich read sent into a context that then
        // navigates must be reissued against the new context, not hang
        // or accept the old page's late reply.
        cl.navigate(reader_ids_page);
        _ = cl.evalWait("window.__sketerm_test_hooks=true;document.documentElement.setAttribute('data-sketerm-delay-read','1200');'armed'", false, 20_000);
        const legacy_nav = cl.md_seq;
        cl.send(proto.SemRead{ .view = view_id });
        cl.send(proto.Navigate{ .view = view_id, .url = reader_nav_page });
        if (!cl.waitSeq(&cl.md_seq, legacy_nav, 20_000)) fail("stage 41 reader ids: legacy read hung across navigation");
        if (std.mem.indexOf(u8, cl.md[0..cl.md_len], "NAVIGATION-READ-MARKER") == null)
            fail("stage 41 reader ids: legacy read was not reissued on the new document");

        cl.navigate(reader_ids_page);
        _ = cl.evalWait("window.__sketerm_test_hooks=true;document.documentElement.setAttribute('data-sketerm-delay-read','1200');'armed'", false, 20_000);
        const rich_nav = cl.md_seq;
        cl.send(proto.SemReadIds{ .view = view_id });
        cl.send(proto.Navigate{ .view = view_id, .url = reader_nav_page });
        if (!cl.waitSeq(&cl.md_seq, rich_nav, 20_000)) fail("stage 41 reader ids: rich read hung across navigation");
        if (std.mem.indexOf(u8, cl.md[0..cl.md_len], "NAVIGATION-READ-MARKER") == null)
            fail("stage 41 reader ids: rich read was not reissued on the new document");

        // Navigation while the guarded action is waiting on its fresh
        // validation walk must answer stale explicitly and must not
        // activate a lookalike in the new page.
        cl.navigate(reader_ids_page);
        const read3 = cl.md_seq;
        cl.send(proto.SemReadIds{ .view = view_id });
        if (!cl.waitSeq(&cl.md_seq, read3, 20_000)) fail("stage 41 reader ids: no rich read for guarded navigation race");
        _ = cl.evalWait("window.__sketerm_test_hooks=true;document.documentElement.setAttribute('data-sketerm-delay-snapshot','1200');'armed'", false, 20_000);
        const interrupted = cl.act_seq;
        cl.send(proto.SemActGuarded{
            .view = view_id,
            .doc_gen = cl.rich_doc,
            .rev = cl.rich_rev,
            .id = cl.rich_id,
            .guard = cl.rich_guard,
            .action = @intFromEnum(proto.SemAct.click),
            .arg = "",
        });
        cl.send(proto.Navigate{ .view = view_id, .url = reader_nav_page });
        if (!cl.waitSeq(&cl.act_seq, interrupted, 20_000)) fail("stage 41 reader ids: guarded action hung across navigation");
        if (cl.act_ok != 0 or std.mem.indexOf(u8, cl.act_msg[0..cl.act_msg_len], "stale reader id") == null)
            fail("stage 41 reader ids: guarded navigation race was not explicitly stale");
        if (std.mem.indexOf(u8, cl.title[0..cl.title_len], "reader:trusted") != null)
            fail("stage 41 reader ids: guarded navigation race clicked the old target");

        // A queued read behind an in-flight navigation is explicitly
        // canceled by stop_load. ERR_ABORTED must not leave the semantic
        // loading bit set or strand the client until its deadline.
        const stop_page = "data:text/html,<script>var t=Date.now();while(Date.now()-t<3000)</script><article><p>STOPPED</p></article>";
        const stopped = cl.md_seq;
        cl.send(proto.Navigate{ .view = view_id, .url = stop_page });
        cl.sendSemantic(4105, proto.SemReadIds{ .view = view_id });
        cl.send(proto.NavAction{ .view = view_id, .action = @intFromEnum(proto.NavAct.stop) });
        if (!cl.waitSeq(&cl.md_seq, stopped, 20_000)) fail("stage 41 reader ids: stopped navigation stranded a rich read");
        if (cl.sem_result_request != 4105 or std.mem.indexOf(u8, cl.md[0..cl.md_len], "loading was stopped") == null)
            fail("stage 41 reader ids: stop_load did not correlate the canceled rich read");
    }
    pass("stage 41 reader ids correlate overlap, refuse stale, and recover navigation/stop races");
    if (c.getenv("SKETERM_SMOKE_WEB_READER_ONLY") != null) {
        cl.have_view = false;
        cl.send(proto.ViewDestroy{ .view = view_id });
        cl.deinit();
        reapHelperTimeout(pid, "reader-only teardown", 15_000);
        pass("reader-only semantic request correlation");
        cleanup();
        return 0;
    }

    // ── Stage 13: query the shadow tree ────────────────────────────
    // (covered by unit tests too; here it proves the frame round-trips)
    {
        cl.navigate(article_page);
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

    // ── Stage 38: a truncated list SAYS it was truncated ───────────
    //
    // The walk used to stop with no trace, and a caller cannot tell
    // "described in full" from "cut off here" — which is how it
    // concludes a control is not on the page. Three assertions, and the
    // middle one is what makes this stage fail if the feature is
    // removed: without the cap every row is described.
    // Built STATICALLY rather than by a script in a data: url — the
    // point of the stage is the walk, and a page whose content depends
    // on script execution adds a second thing that can fail.
    const listPage = struct {
        fn build(buf: []u8, rows: u32) []const u8 {
            var w = std.Io.Writer.fixed(buf);
            w.writeAll("data:text/html,<body><ul>") catch fail("stage 38: page buffer");
            var n: u32 = 1;
            while (n <= rows) : (n += 1) w.print("<li>row{d}</li>", .{n}) catch fail("stage 38: page buffer");
            w.writeAll("</ul></body>") catch fail("stage 38: page buffer");
            return buf[0..w.end];
        }
    }.build;

    // BELOW the cap first. It is the control: it proves the page shape
    // and the snapshot path are fine, so a failure on the long list
    // below is about the collapsing and nothing else.
    var rows_buf: [4096]u8 = undefined;
    const p20 = listPage(&rows_buf, 20);
    cl.navigate(p20);
    cl.resetSem();
    {
        const sq = cl.sem_seq;
        cl.send(proto.SemSnapshotReq{ .view = view_id, .mode = @intFromEnum(proto.SnapMode.full), .detail = 1, .scope = 0 });
        if (!cl.waitSeq(&cl.sem_seq, sq, 20_000)) {
            std.debug.print("stage 38: NO snapshot for the 20-row page ({d} bytes of url)\n", .{p20.len});
            fail("stage 38 truncation: no snapshot for the short list");
        }
    }
    if (!cl.waitSem("\"row20\"", 20_000)) fail("stage 38 truncation: the short list never reached the snapshot");
    // The page URL is echoed in the snapshot header and contains every
    // row verbatim, so assert on the NODE form (names render quoted)
    // rather than on the raw substring.
    if (std.mem.indexOf(u8, cl.semLog(), " more") != null)
        fail("stage 38 truncation: a list UNDER the cap was collapsed");

    var rows_buf2: [4096]u8 = undefined;
    cl.navigate(listPage(&rows_buf2, 60));
    cl.resetSem();
    {
        const sq = cl.sem_seq;
        cl.send(proto.SemSnapshotReq{ .view = view_id, .mode = @intFromEnum(proto.SnapMode.full), .detail = 1, .scope = 0 });
        if (!cl.waitSeq(&cl.sem_seq, sq, 20_000)) fail("stage 38 truncation: no snapshot for the long list");
    }
    if (!cl.waitSem("\"row50\"", 20_000)) fail("stage 38 truncation: the long list never reached the snapshot");
    {
        const log = cl.semLog();
        if (std.mem.indexOf(u8, log, "\"row60\"") != null)
            fail("stage 38 truncation: a row PAST the cap was described — nothing was collapsed");
        if (std.mem.indexOf(u8, log, "and 10 more") == null) {
            std.debug.print("smoke-web: snapshot was:\n{s}\n", .{log});
            fail("stage 38 truncation: the omitted rows were not reported as a `more` node");
        }
    }
    pass("stage 38 a truncated list reports the omitted count");

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
                _ = c.munmap(@ptrCast(@constCast(bytes)), size);
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
        // Retried like the stage-6 popup click: a page whose first
        // compositor frame has not landed yet swallows the click, and
        // under load one click plus a settle is a race; five are not.
        {
            var tries: u8 = 0;
            while (tries < 5 and cl.dl_offer_seq == offer1) : (tries += 1) {
                cl.clickCenter();
                _ = cl.drive(400, 120);
            }
        }
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

    // ── Stage 36: a11y geometry drives real input; the caret is real ──
    //
    // The ENGINE half of screen-reader actions and braille. Stage 22k
    // proved a tree arrives; this proves the two things a reader
    // actually does with it:
    //
    //   a) PRESS. A projected `Action.DoAction` resolves the node to a
    //      point and posts `input_pointer` — so this stage takes the
    //      button's rect FROM THE STREAMED TREE, clicks its centre,
    //      and requires the page's own handler to have run. That is
    //      the whole routing, against a real engine: if AX geometry
    //      were wrong or the click were synthetic, the count stays 0.
    //   b) CARET. `ev_a11y_caret` must carry a real caret and a real
    //      selection, and must COALESCE — Chromium restates tree_data
    //      on every update, so an uncoalesced caret would post a frame
    //      per unrelated tree change.
    {
        if (!cl.ack_a11y_caret) fail("stage 36 a11y: hello_ack lacks the a11y-caret capability");
        const page = "data:text/html,<html><body style='background:%23fff;margin:0'>" ++
            "<button id=b style='position:absolute;left:40px;top:60px;width:140px;height:44px'>Axpress</button>" ++
            "<input id=t style='position:absolute;left:40px;top:160px;width:240px' value='Axcaret text'>" ++
            "<div id=e contenteditable style='position:absolute;left:40px;top:220px;width:240px'>Axeditable text</div>" ++
            "<script>window.hits=0;" ++
            "document.getElementById('b').addEventListener('click',function(){window.hits++});" ++
            "</script></body></html>";
        cl.navigate(page);
        // Re-enable after 22k turned it off; this also exercises the
        // helper restating a caret it had already coalesced away.
        cl.send(proto.A11yEnable{ .view = view_id, .enabled = 1 });

        // Wait for the button to appear in the mirrored tree.
        var btn: u32 = 0;
        var field: u32 = 0;
        const tree_deadline = nowMs() + 20_000;
        while (nowMs() < tree_deadline and (btn == 0 or field == 0)) {
            btn = axFindNode(&cl, "button", "Axpress");
            field = axFindNode(&cl, "textbox", "");
            if (btn != 0 and field != 0) break;
            cl.pump(100);
        }
        if (btn == 0) {
            std.debug.print("smoke-web: ax log was:\n{s}\n", .{cl.ax_log[0..cl.ax_log_len]});
            fail("stage 36 a11y: the button never appeared in the streamed tree");
        }
        if (field == 0) fail("stage 36 a11y: the text field never appeared in the streamed tree");

        // (a) Press it, exactly the way a projected DoAction does.
        const r = axAbsRect(&cl.ax_mirror, btn) orelse
            fail("stage 36 a11y: the button node carried no resolvable rect");
        if (r[2] <= 0 or r[3] <= 0) fail("stage 36 a11y: the button node has an empty rect");
        const cx = r[0] + @divTrunc(r[2], 2);
        const cy = r[1] + @divTrunc(r[3], 2);
        for ([_]proto.PointerKind{ .move, .down, .up }) |kind| {
            cl.send(proto.InputPointer{
                .view = view_id,
                .kind = @intFromEnum(kind),
                .x = cx,
                .y = cy,
                .button = 0,
                .clicks = 1,
                .mods = 0,
            });
        }
        var pressed = false;
        const press_deadline = nowMs() + 10_000;
        while (nowMs() < press_deadline) {
            cl.pump(100);
            const js = cl.evalWait("window.hits", false, 5_000);
            if (std.mem.indexOf(u8, js, "\"value\":1") != null) {
                pressed = true;
                break;
            }
        }
        if (!pressed) {
            std.debug.print("smoke-web: rect {d},{d} {d}x{d} -> click {d},{d}\n", .{ r[0], r[1], r[2], r[3], cx, cy });
            fail("stage 36 a11y: a click at the AX node's centre never reached the page");
        }

        // (b) A real caret, then a real selection.
        _ = cl.evalWait("(function(){var t=document.getElementById('t');t.focus();t.setSelectionRange(3,3);return 1})()", false, 5_000);
        var caret_ok = false;
        const caret_deadline = nowMs() + 15_000;
        while (nowMs() < caret_deadline) {
            cl.pump(150);
            if (cl.ax_caret_seq != 0 and cl.ax_caret_focus_id != 0 and
                cl.ax_caret_focus_off == 3 and cl.ax_caret_anchor_off == 3)
            {
                caret_ok = true;
                break;
            }
        }
        if (!caret_ok) {
            std.debug.print(
                "smoke-web: caret frames={d} focus_id={d} off={d} anchor={d}\n",
                .{ cl.ax_caret_seq, cl.ax_caret_focus_id, cl.ax_caret_focus_off, cl.ax_caret_anchor_off },
            );
            fail("stage 36 a11y: no ev_a11y_caret reported the collapsed caret at offset 3");
        }

        // (c) SELECTION EXTENT: a MEASURED ENGINE CEILING, reported
        // rather than asserted — the same shape as the Widevine probe.
        //
        // MEASURED on CEF 151.3.16 (2026-08-12): tree_data reports a
        // text selection COLLAPSED to its anchor. Tried three ways and
        // every caret frame came back anchor == focus:
        //   - an <input> via setSelectionRange(2,6)  -> a=2@2 f=2@2
        //   - a contenteditable via a DOM Range 2..6 -> a=5@2 f=5@2
        //   - real shift+Right key events            -> no frame at all
        // The node attributes carry no textSelStart/textSelEnd either.
        //
        // The wire, the mirror and org.a11y.atspi.Text all carry and
        // serve a real range — smoke-webax proves that whole path
        // against a live bus — so this is the ENGINE's half alone. A
        // braille display following this browser gets the caret, not
        // the selected range. Passing while saying so keeps the stage
        // honest, and it starts announcing the day an engine reports
        // an extent.
        cl.ax_sel_seen = false;
        _ = cl.evalWait("(function(){var t=document.getElementById('t');t.focus();t.setSelectionRange(2,6);return 1})()", false, 5_000);
        cl.pump(1_500);
        _ = cl.evalWait(
            "(function(){var e=document.getElementById('e');e.focus();" ++
                "var r=document.createRange();var n=e.firstChild;" ++
                "r.setStart(n,2);r.setEnd(n,6);" ++
                "var s=window.getSelection();s.removeAllRanges();s.addRange(r);return 1})()",
            false,
            5_000,
        );
        cl.pump(1_500);
        if (cl.ax_sel_seen) {
            say("smoke-web: NOTE stage 36 the engine now reports a selection EXTENT; the ceiling is gone");
        } else {
            say("smoke-web: NOTE stage 36 selection extent unavailable (CEF reports it collapsed) - caret only");
        }
        if (cl.ax_caret_seq == 0) fail("stage 36 a11y: no caret frame at all");

        // Coalescing: churn the DOM without touching the caret and
        // require silence on the caret channel.
        const before = cl.ax_caret_seq;
        _ = cl.evalWait("(function(){for(var i=0;i<12;i++){var d=document.createElement('p');d.textContent='churn'+i;document.body.appendChild(d)}return 1})()", false, 5_000);
        cl.pump(2_500);
        if (cl.ax_caret_seq != before) {
            std.debug.print("smoke-web: caret frames {d} -> {d} on unrelated churn\n", .{ before, cl.ax_caret_seq });
            fail("stage 36 a11y: an unchanged caret was re-posted on unrelated tree churn");
        }

        cl.send(proto.A11yEnable{ .view = view_id, .enabled = 0 });
        cl.pump(300);
        pass("stage 36 a11y (AX rect drives a trusted click; caret reported and coalesced)");
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
        const site_url = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{http.lis.port}) catch unreachable;

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
        // The hand-rolled copy this used to be was the ONLY reap that
        // looked at the exit code; `reapHelperTimeout` now checks both,
        // so there is no second implementation to keep in step.
        reapHelperTimeout(pid, "stage 23 teardown", 10_000);
        pass("stage 23 teardown (helper exited 0 on disconnect)");
    }

    runFilterSubscriptionStage(gpa, exe, dir);

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
        const gpu_pid = spawnHelper(exe, sock2.ptr, cache.ptr, null, null, false);
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
        const sw_pid = spawnHelper(exe, sock3.ptr, cache.ptr, null, null, true);
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

    // ── Stages 26/27: route instances ────────────────────────────
    //
    // A network route is a whole helper INSTANCE started with `--proxy`
    // (src/web/route.zig): every view in it — the context-0 default jar
    // AND every container context — leaves through that proxy, and a
    // context-level `proxy` on the wire is ignored. On their OWN helpers,
    // AFTER the main teardown, because a proxied request context leaves
    // Chromium network state that makes cef_shutdown slower than the 10s
    // the teardown stage allows.
    {
        var probe_a = ProxyProbe{};
        var probe_b = ProxyProbe{};
        if (!probe_a.start() or !probe_b.start()) fail("stage 26 route: could not start the SOCKS5 probes");
        defer probe_a.shutdown();
        defer probe_b.shutdown();
        var url_a_z: [64:0]u8 = undefined;
        var url_b_z: [64:0]u8 = undefined;
        const url_a = std.fmt.bufPrintZ(&url_a_z, "socks5://127.0.0.1:{d}", .{probe_a.lis.port}) catch unreachable;
        const url_b = std.fmt.bufPrintZ(&url_b_z, "socks5://127.0.0.1:{d}", .{probe_b.lis.port}) catch unreachable;

        var sock4_buf: [96]u8 = undefined;
        const sock4 = std.fmt.bufPrintZ(&sock4_buf, "{s}/x.sock", .{dir}) catch fail("socket path");
        var cache4_buf: [128]u8 = undefined;
        const cache4 = std.fmt.bufPrintZ(&cache4_buf, "{s}/cache-egress", .{dir}) catch fail("cache path");
        const eg_pid = spawnHelperArgs(exe, sock4.ptr, cache4.ptr, &[_][*:0]const u8{ "--ozone-platform=headless", "--proxy", url_a.ptr });
        g_pid = eg_pid;
        var ec = Client{ .gpa = gpa, .fd = connectWithRetry(sock4.ptr, sock4.len) };
        ec.send(proto.Hello{ .proto = proto.PROTO_VERSION, .client_name = "smoke-web-egress" });
        {
            const deadline = nowMs() + 20_000;
            while (ec.ack_proto == 0 and nowMs() < deadline) ec.pump(100);
        }
        if (ec.ack_proto != proto.PROTO_VERSION) fail("stage 26 route: no hello_ack from the routed helper");
        if (!ec.ack_contexts) fail("stage 26 route: hello_ack lacks the contexts capability");
        if (!ec.ack_contexts_fail_closed) fail("stage 26 route: hello_ack lacks the contexts-fail-closed capability");

        // A nonzero context that was never created must not resolve to the
        // global context. The helper reports only this view's failure and
        // stays alive for the route stages below.
        {
            const seq = ec.view_create_fail_seq;
            ec.send(proto.ViewCreate{
                .view = egress_unknown_view,
                .w = 320,
                .h = 240,
                .scale_x1000 = 1000,
                .context = 999,
            });
            if (!ec.waitSeq(&ec.view_create_fail_seq, seq, 10_000))
                fail("stage 26 fail-closed: an unknown context did not fail the view");
            if (ec.view_create_fail_view != egress_unknown_view or ec.view_create_fail_context != 999)
                fail("stage 26 fail-closed: the failure named the wrong view or context");
            if (ec.view_create_fail_reason_len == 0)
                fail("stage 26 fail-closed: the creation failure had no reason");
            pass("stage 26 fail-closed unknown context (no global direct fallback)");
        }

        // Stage 26a: a CONTEXT-0 view of the routed instance. Its
        // navigation must reach the instance's proxy with the hostname
        // UNRESOLVED (atyp=domain): DNS resolves at the proxy end, the
        // "browse via server X" property, and the default jar is not a
        // way around the route.
        ec.send(proto.ViewCreate{ .view = egress_view_a, .w = 320, .h = 240, .scale_x1000 = 1000, .context = 0 });
        ec.send(proto.Navigate{ .view = egress_view_a, .url = "http://cookie-a.example/" });
        if (!waitProbeHost(&probe_a, &ec, "cookie-a.example", 20_000))
            fail("stage 26 route: a context-0 view of a routed instance never reached the SOCKS5 probe");
        if (!probe_a.atyp_domain) fail("stage 26 route: the CONNECT did not arrive as atyp=domain (remote DNS lost)");
        pass("stage 26 route (context-0 view egresses through the instance proxy, atyp=domain, remote DNS)");

        // Stage 26b: a CONTAINER view of the same instance, whose
        // context_create names a different, dead proxy. The field is
        // ignored — the route is the instance — so the view still
        // reaches the instance's probe, never port 9 and never direct.
        ec.send(proto.ContextCreate{ .id = 10, .ephemeral = 1, .name = "egress-a", .proxy = "socks5://127.0.0.1:9" });
        ec.send(proto.ViewCreate{ .view = egress_view_b, .w = 320, .h = 240, .scale_x1000 = 1000, .context = 10 });
        ec.send(proto.Navigate{ .view = egress_view_b, .url = "http://cookie-b.example/" });
        if (!waitProbeHost(&probe_a, &ec, "cookie-b.example", 20_000))
            fail("stage 26 route: a container view of a routed instance never reached the instance proxy");
        pass("stage 26 route (container view egresses through the instance proxy; a context-level proxy never overrides the route)");

        // Stage 27: a SECOND routed instance on another proxy, with the
        // SAME container id: each instance's view leaves through its own
        // proxy and no other — isolation is per instance, which is what
        // makes a route correct by construction.
        var sock5_buf: [96]u8 = undefined;
        const sock5 = std.fmt.bufPrintZ(&sock5_buf, "{s}/y.sock", .{dir}) catch fail("socket path");
        var cache5_buf: [128]u8 = undefined;
        const cache5 = std.fmt.bufPrintZ(&cache5_buf, "{s}/cache-egress-b", .{dir}) catch fail("cache path");
        const eg_b_pid = spawnHelperArgs(exe, sock5.ptr, cache5.ptr, &[_][*:0]const u8{ "--ozone-platform=headless", "--proxy", url_b.ptr });
        var eb = Client{ .gpa = gpa, .fd = connectWithRetry(sock5.ptr, sock5.len) };
        eb.send(proto.Hello{ .proto = proto.PROTO_VERSION, .client_name = "smoke-web-egress-b" });
        {
            const deadline = nowMs() + 20_000;
            while (eb.ack_proto == 0 and nowMs() < deadline) {
                eb.pump(50);
                ec.pump(50);
            }
        }
        if (eb.ack_proto != proto.PROTO_VERSION) fail("stage 27 isolation: no hello_ack from the second routed helper");
        probe_a.arm();
        eb.send(proto.ContextCreate{ .id = 10, .ephemeral = 1, .name = "egress-a", .proxy = "" });
        eb.send(proto.ViewCreate{ .view = egress_view_c, .w = 320, .h = 240, .scale_x1000 = 1000, .context = 10 });
        eb.send(proto.Navigate{ .view = egress_view_c, .url = "http://only-in-b.example/" });
        if (!waitProbeHost(&probe_b, &eb, "only-in-b.example", 20_000))
            fail("stage 27 isolation: the second instance's view never reached its own proxy");
        if (probe_a.seenHost()) |h| {
            if (std.mem.eql(u8, h, "only-in-b.example")) fail("stage 27 isolation: instance B's traffic reached instance A's proxy");
        }
        pass("stage 27 isolation (two route instances, two proxies; the same container id egresses per instance)");

        // Destroy the browsers FIRST and pump so their async close
        // finishes, THEN destroy the contexts (also exercising
        // context_destroy and freeing the ephemeral in-memory stores),
        // then pump again: a proxied browser still half-closed when the
        // last client goes away is the shape this stage has to unwind
        // cleanly, and the strict reap below is what proves it did.
        eb.send(proto.ViewDestroy{ .view = egress_view_c });
        eb.have_view = false;
        eb.teardown_allow_close = true;
        ec.send(proto.ViewDestroy{ .view = egress_view_a });
        ec.send(proto.ViewDestroy{ .view = egress_view_b });
        ec.have_view = false;
        ec.teardown_allow_close = true;
        {
            const d = nowMs() + 4000;
            while (nowMs() < d) {
                ec.pump(50);
                eb.pump(50);
            }
        }
        if (ec.fd >= 0) {
            ec.send(proto.ContextDestroy{ .id = 10 });
            const d = nowMs() + 2000;
            while (nowMs() < d and ec.fd >= 0) ec.pump(50);
        }
        if (eb.fd >= 0) {
            eb.send(proto.ContextDestroy{ .id = 10 });
            const d = nowMs() + 2000;
            while (nowMs() < d and eb.fd >= 0) eb.pump(50);
        }
        eb.deinit();
        reapHelperTimeout(eg_b_pid, "stage 27 second route instance", 30_000);
        g_pid = eg_pid;
        ec.deinit();
        reapHelperTimeout(eg_pid, "stages 26/27 route instance", 30_000);
    }

    // Negative control: on a DIRECT instance a context-level `proxy`
    // alone routes nothing. The field is still on the wire (older
    // clients send it); if it ever came back as a per-context override,
    // a container would follow it OUT of a Tor instance, so this stage
    // pins it inert.
    {
        var probe_c = ProxyProbe{};
        if (!probe_c.start()) fail("stage 27 negative control: could not start the SOCKS5 probe");
        defer probe_c.shutdown();
        var url_c_buf: [64]u8 = undefined;
        const url_c = std.fmt.bufPrint(&url_c_buf, "socks5://127.0.0.1:{d}", .{probe_c.lis.port}) catch unreachable;
        var sock_d_buf: [96]u8 = undefined;
        const sock_d = std.fmt.bufPrintZ(&sock_d_buf, "{s}/xd.sock", .{dir}) catch fail("socket path");
        var cache_d_buf: [128]u8 = undefined;
        const cache_d = std.fmt.bufPrintZ(&cache_d_buf, "{s}/cache-direct-ctx", .{dir}) catch fail("cache path");
        const d_pid = spawnHelper(exe, sock_d.ptr, cache_d.ptr, "--ozone-platform=headless", null, false);
        g_pid = d_pid;
        var dc = Client{ .gpa = gpa, .fd = connectWithRetry(sock_d.ptr, sock_d.len) };
        dc.send(proto.Hello{ .proto = proto.PROTO_VERSION, .client_name = "smoke-web-direct-ctx" });
        {
            const deadline = nowMs() + 20_000;
            while (dc.ack_proto == 0 and nowMs() < deadline) dc.pump(100);
        }
        if (dc.ack_proto != proto.PROTO_VERSION) fail("stage 27 negative control: no hello_ack");
        dc.send(proto.ContextCreate{ .id = 14, .ephemeral = 1, .name = "ctx-proxy-only", .proxy = url_c });
        dc.send(proto.ViewCreate{ .view = egress_direct_view, .w = 320, .h = 240, .scale_x1000 = 1000, .context = 14 });
        dc.have_view = true;
        // The host does not resolve, so a direct navigation ends in a
        // load error; that (or a load, or 6s) is the bound the probe is
        // held against.
        const load0 = dc.load_seq;
        const err0 = dc.load_err_seq;
        dc.send(proto.Navigate{ .view = egress_direct_view, .url = "http://never-proxied.example/" });
        {
            const deadline = nowMs() + 6000;
            while (nowMs() < deadline and dc.load_seq == load0 and dc.load_err_seq == err0) dc.pump(100);
        }
        if (probe_c.seenHost()) |h| {
            std.debug.print("smoke-web: the context-only proxy saw \"{s}\"\n", .{h});
            fail("stage 27 negative control: a context-level proxy routed traffic on a direct instance");
        }
        pass("stage 27 negative control (a context-level proxy alone routes nothing: the route is the instance)");
        dc.have_view = false;
        dc.send(proto.ViewDestroy{ .view = egress_direct_view });
        dc.deinit();
        reapHelper(d_pid, "stage 27 negative control");
    }

    // An instance whose route proxy is refused on a container context
    // rolls that context back before it enters the registry. The
    // immediately following view therefore fails exactly like any other
    // missing context and never gets a buffer.
    {
        var sock_fail_buf: [96]u8 = undefined;
        const sock_fail = std.fmt.bufPrintZ(&sock_fail_buf, "{s}/xf.sock", .{dir}) catch fail("socket path");
        var cache_fail_buf: [128]u8 = undefined;
        const cache_fail = std.fmt.bufPrintZ(&cache_fail_buf, "{s}/cache-egress-fail", .{dir}) catch fail("cache path");
        _ = c.setenv("SKETERM_WEB_FAIL_PROXY", "1", 1);
        const fail_pid = spawnHelperArgs(exe, sock_fail.ptr, cache_fail.ptr, &[_][*:0]const u8{ "--ozone-platform=headless", "--proxy", "socks5://127.0.0.1:9" });
        _ = c.unsetenv("SKETERM_WEB_FAIL_PROXY");
        g_pid = fail_pid;
        var fc = Client{ .gpa = gpa, .fd = connectWithRetry(sock_fail.ptr, sock_fail.len) };
        fc.send(proto.Hello{ .proto = proto.PROTO_VERSION, .client_name = "smoke-web-egress-fail" });
        {
            const deadline = nowMs() + 20_000;
            while (fc.ack_proto == 0 and nowMs() < deadline) fc.pump(100);
        }
        if (!fc.ack_contexts or !fc.ack_contexts_fail_closed)
            fail("stage 26 proxy refusal: helper lacks strict context support");
        fc.send(proto.ContextCreate{
            .id = 13,
            .ephemeral = 1,
            .name = "proxy-refused",
            .proxy = "",
        });
        fc.send(proto.ViewCreate{
            .view = egress_proxy_fail_view,
            .w = 320,
            .h = 240,
            .scale_x1000 = 1000,
            .context = 13,
        });
        if (!fc.waitSeq(&fc.view_create_fail_seq, 0, 10_000))
            fail("stage 26 proxy refusal: the view did not report creation failure");
        if (fc.view_create_fail_view != egress_proxy_fail_view or fc.view_create_fail_context != 13)
            fail("stage 26 proxy refusal: the failure named the wrong view or context");
        if (fc.fb_seq != 0 or fc.dma_seq != 0 or fc.inline_seq != 0)
            fail("stage 26 proxy refusal: a failed egress view still received a frame buffer");
        pass("stage 26 proxy refusal (instance proxy refused on a container context: rollback, view creation fails closed)");
        fc.deinit();
        reapHelper(fail_pid, "stage 26 proxy refusal");
    }

    // ── Stage 37: cookie JAR isolation between containers ─────
    //
    // Stages 26/27 prove two containers EGRESS independently. They say
    // nothing about storage, which is the other half of what an identity
    // context is for and the half a user actually notices: staying
    // logged into two accounts on one site at once.
    //
    // Both views load the SAME loopback origin, so same-origin policy
    // cannot be the thing keeping the cookie apart -- only the request
    // context can. The query string decides which side writes it.
    //
    // Own helper, after the main teardown, for the same reason the
    // egress stages have one: a rig that has created extra request
    // contexts makes cef_shutdown slower and noisier than stage 23's
    // budget allows.
    {
        var sock5_buf: [96]u8 = undefined;
        const sock5 = std.fmt.bufPrintZ(&sock5_buf, "{s}/j.sock", .{dir}) catch fail("socket path");
        var cache5_buf: [128]u8 = undefined;
        const cache5 = std.fmt.bufPrintZ(&cache5_buf, "{s}/cache-jar", .{dir}) catch fail("cache path");
        const jar_pid = spawnHelper(exe, sock5.ptr, cache5.ptr, "--ozone-platform=headless", null, false);
        g_pid = jar_pid;
        var jc = Client{ .gpa = gpa, .fd = connectWithRetry(sock5.ptr, sock5.len) };
        jc.send(proto.Hello{ .proto = proto.PROTO_VERSION, .client_name = "smoke-web-jar" });
        {
            const deadline = nowMs() + 20_000;
            while (jc.ack_proto == 0 and nowMs() < deadline) jc.pump(100);
        }
        if (jc.ack_proto != proto.PROTO_VERSION) fail("stage 37 jars: no hello_ack from the jar helper");
        if (!jc.ack_contexts) fail("stage 37 jars: hello_ack lacks the contexts capability");
        if (!jc.ack_sitedata) fail("stage 37 jars: hello_ack lacks the sitedata capability");

        var http = HttpProbe{ .body = jar_page };
        if (!http.start()) fail("stage 37 jars: could not start the loopback http probe");
        defer http.shutdown();
        var base_buf: [64]u8 = undefined;
        const base_url = std.fmt.bufPrint(&base_buf, "http://127.0.0.1:{d}/", .{http.lis.port}) catch unreachable;
        var set_buf: [72]u8 = undefined;
        const set_url = std.fmt.bufPrint(&set_buf, "http://127.0.0.1:{d}/?set", .{http.lis.port}) catch unreachable;
        var plain_buf: [72]u8 = undefined;
        const plain_url = std.fmt.bufPrint(&plain_buf, "http://127.0.0.1:{d}/?plain", .{http.lis.port}) catch unreachable;

        jc.send(proto.ContextCreate{ .id = 20, .ephemeral = 1, .name = "jar-a", .proxy = "" });
        jc.send(proto.ContextCreate{ .id = 21, .ephemeral = 1, .name = "jar-b", .proxy = "" });

        // -- container A writes the cookie ---------------------------
        jc.send(proto.ViewCreate{ .view = jar_view_a, .w = 320, .h = 240, .scale_x1000 = 1000, .context = 20 });
        jc.send(proto.Navigate{ .view = jar_view_a, .url = set_url });
        if (!jc.waitTitle("jarA:", 20_000)) {
            std.debug.print(
                "smoke-web: served {d} http requests, last title was \"{s}\"\n",
                .{ http.served.load(.acquire), jc.titleSlice() },
            );
            fail("stage 37 jars: container A never ran the cookie script");
        }
        if (std.mem.indexOf(u8, jc.titleSlice(), jar_cookie) == null)
            fail("stage 37 jars: container A could not store its own cookie");

        // Snapshot A's enumeration before asking about B: the client's
        // cookie fields are one slot and the second reply overwrites it.
        const req_a: u32 = 971;
        const seq_a = jc.cookie_seq;
        jc.send(proto.CookiesReq{ .view = jar_view_a, .req = req_a, .url = base_url });
        if (!jc.waitSeq(&jc.cookie_seq, seq_a, 10_000))
            fail("stage 37 jars: no ev_cookies answered container A");
        if (jc.cookie_ok == 0) fail("stage 37 jars: container A's cookie store could not be read");
        var names_a_buf: [4096]u8 = undefined;
        const na = @min(jc.cookie_names_len, names_a_buf.len);
        @memcpy(names_a_buf[0..na], jc.cookie_names[0..na]);
        const names_a = names_a_buf[0..na];
        if (std.mem.indexOf(u8, names_a, jar_cookie) == null) {
            std.debug.print("smoke-web: container A cookies were:\n{s}\n", .{names_a});
            fail("stage 37 jars: container A's own cookie was not enumerated");
        }

        // -- container B, same origin, must see none of it ------------
        jc.send(proto.ViewCreate{ .view = jar_view_b, .w = 320, .h = 240, .scale_x1000 = 1000, .context = 21 });
        jc.send(proto.Navigate{ .view = jar_view_b, .url = plain_url });
        if (!jc.waitTitle("jarB:", 20_000)) {
            std.debug.print(
                "smoke-web: served {d} http requests, last title was \"{s}\"\n",
                .{ http.served.load(.acquire), jc.titleSlice() },
            );
            fail("stage 37 jars: container B never loaded the shared origin");
        }
        // The DOM's own view: the page running IN container B, on the
        // very origin container A wrote to, cannot read that cookie.
        if (std.mem.indexOf(u8, jc.titleSlice(), jar_cookie) != null) {
            std.debug.print("smoke-web: container B title was \"{s}\"\n", .{jc.titleSlice()});
            fail("stage 37 jars: container B's document.cookie exposed container A's cookie");
        }

        const req_b: u32 = 972;
        const seq_b = jc.cookie_seq;
        jc.send(proto.CookiesReq{ .view = jar_view_b, .req = req_b, .url = base_url });
        if (!jc.waitSeq(&jc.cookie_seq, seq_b, 10_000))
            fail("stage 37 jars: no ev_cookies answered container B");
        if (jc.cookie_ok == 0) fail("stage 37 jars: container B's cookie store could not be read");
        const names_b = jc.cookie_names[0..jc.cookie_names_len];
        if (std.mem.indexOf(u8, names_b, jar_cookie) != null) {
            std.debug.print(
                "smoke-web: container A saw:\n{s}\ncontainer B saw:\n{s}\n",
                .{ names_a, names_b },
            );
            fail("stage 37 jars: container A's cookie was enumerated in container B (jars not isolated)");
        }

        jc.send(proto.ViewDestroy{ .view = jar_view_a });
        jc.send(proto.ViewDestroy{ .view = jar_view_b });
        jc.have_view = false;
        jc.teardown_allow_close = true;
        {
            const d = nowMs() + 3000;
            while (nowMs() < d) jc.pump(50);
        }
        if (jc.fd >= 0) {
            jc.send(proto.ContextDestroy{ .id = 20 });
            jc.send(proto.ContextDestroy{ .id = 21 });
            const d = nowMs() + 2000;
            while (nowMs() < d and jc.fd >= 0) jc.pump(50);
        }
        jc.deinit();
        reapHelperTimeout(jar_pid, "stage 37 jars", 30_000);
        pass("stage 37 jars (same origin in two containers, cookie confined to the one that wrote it)");
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
    runActionStage(gpa, exe, dir);
    runWebrequestStage(gpa, exe, dir);
    // ── Stage 35: real MV2 extensions ─────────────────────────────
    runShapeStage(gpa, exe, dir);
    runUboStage(gpa, exe, dir, ubo_xpi);
    // ── Stage mc: multi-client serving ────────────────────────────
    runMultiClientStage(gpa, exe, dir);
    // ── Stage fl: flush + linger (broker-owned lifecycle) ─────────
    runFlushLingerStage(gpa, exe, dir);
    // ── Stage 42: cross-instance cookie sync (two real helpers) ───
    runCookieSyncStage(gpa, exe, dir);

    cleanup();
    if (gpa_state.deinit() == .leak) {
        say("smoke-web: FAIL leaked memory (see GPA report above)");
        return 1;
    }
    say("smoke-web: PASS");
    return 0;
}
