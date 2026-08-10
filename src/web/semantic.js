// Semantic-layer content script for sketerm-web.
//
// This file is a FUNCTION EXPRESSION, not a statement: cefhost's
// render-process handler evaluates it in the V8 context of every main
// frame (on_context_created) and calls the resulting function with the
// two per-process secrets and the native reply function. Everything
// here is engine-agnostic DOM work: the script walks the document,
// assigns per-document engine-local ids (WeakMap + counter) and answers
// commands. It owns NO stable ids and computes NO deltas -- those live
// in src/web/semantic.zig, which diffs the full walks this script
// emits.
//
// Transport: JSON strings both ways. Out through `post`, the V8
// extension's global handed in as an argument here and unpublished
// immediately below, so page script has no reply channel; in through
// the command entry point, installed under the random name SLOT because
// the browser process can only reach a frame by evaluating source in
// it. Every reply is prefixed with NONCE, which the browser checks and
// without which the reply is dropped.
//
// SECURITY: this runs at context creation, BEFORE any page script, so
// the capture below wins the race and the intrinsics captured are the
// pristine ones. Page script can still lie about its OWN DOM (that is
// not defensible from inside the page), but it cannot forge, alter or
// observe a reply.

(function (NONCE, SLOT, post) {
  if (typeof window === "undefined") return;
  if (typeof post !== "function") return;
  if (window[SLOT]) return;

  // Unpublish the transport. `delete` is tried first and fails on a
  // global function declaration (non-configurable); the assignment is
  // what actually bites, and the redefine is there for a future
  // transport declared some other way. Whichever wins, page script must
  // find nothing callable -- smoke-web stage 14 asserts exactly that.
  try {
    delete window.__sketermSemPost;
  } catch (e) {}
  if (typeof window.__sketermSemPost !== "undefined") {
    try {
      window.__sketermSemPost = undefined;
    } catch (e2) {}
  }
  if (typeof window.__sketermSemPost !== "undefined") {
    try {
      Object.defineProperty(window, "__sketermSemPost", {
        value: undefined,
        writable: false,
        configurable: false
      });
    } catch (e3) {}
  }

  // Captured while they are still the originals: a page that later
  // patches JSON.stringify must not get to rewrite our replies.
  var stringify = JSON.stringify;
  var parseJson = JSON.parse;

  // Per-context token: a fresh document means a fresh script instance,
  // which is exactly how the helper detects a navigation.
  var DOC = ((Math.random() * 0x7ffffffe) | 0) + 1;
  var QUIESCE_MS = 120;
  var CLAMP = [40, 160, 4000];
  var MAX_NODES = 4000;
  var VALUE_CLAMP = 200;

  var ids = new WeakMap();
  var nextId = 1;
  var byId = new Map(); // rebuilt by every walk: stale nodes drop out
  var detail = 1;
  var observer = null;
  var quiesce = null;

  // Replies carry the browser's nonce as a bare prefix; concatenation
  // of two primitives is the one step no page patch can intercept.
  function send(obj) {
    try {
      post(NONCE + stringify(obj));
    } catch (e) {}
  }

  function idOf(el) {
    var v = ids.get(el);
    if (!v) {
      v = nextId++;
      ids.set(el, v);
    }
    return v;
  }

  // -- role derivation ------------------------------------------------

  var TAG_ROLE = {
    A: "link",
    ARTICLE: "article",
    ASIDE: "complementary",
    BLOCKQUOTE: "blockquote",
    BUTTON: "button",
    CODE: "code",
    DETAILS: "group",
    DIALOG: "dialog",
    FIELDSET: "group",
    FIGCAPTION: "caption",
    FOOTER: "contentinfo",
    FORM: "form",
    H1: "heading",
    H2: "heading",
    H3: "heading",
    H4: "heading",
    H5: "heading",
    H6: "heading",
    HEADER: "banner",
    HTML: "document",
    IFRAME: "iframe",
    IMG: "image",
    LABEL: "label",
    LEGEND: "label",
    LI: "listitem",
    MAIN: "main",
    NAV: "navigation",
    OL: "list",
    OPTION: "option",
    P: "paragraph",
    PRE: "code",
    PROGRESS: "progressbar",
    SECTION: "region",
    SELECT: "combobox",
    SUMMARY: "summary",
    TABLE: "table",
    TD: "cell",
    TEXTAREA: "textbox",
    TH: "columnheader",
    TR: "row",
    UL: "list"
  };

  var INPUT_ROLE = {
    button: "button",
    checkbox: "checkbox",
    color: "colorpicker",
    file: "button",
    image: "button",
    radio: "radio",
    range: "slider",
    reset: "button",
    submit: "button"
  };

  // Roles whose accessible name is their own text content.
  var TEXTY = {
    blockquote: 1,
    button: 1,
    caption: 1,
    cell: 1,
    code: 1,
    columnheader: 1,
    heading: 1,
    label: 1,
    link: 1,
    listitem: 1,
    option: 1,
    paragraph: 1,
    summary: 1,
    text: 1
  };

  var SKIP_TAG = {
    BASE: 1,
    HEAD: 1,
    LINK: 1,
    META: 1,
    NOSCRIPT: 1,
    SCRIPT: 1,
    STYLE: 1,
    TEMPLATE: 1,
    TITLE: 1
  };

  function roleOf(el) {
    var explicit = el.getAttribute && el.getAttribute("role");
    if (explicit) return explicit.split(/\s+/)[0];
    var tag = el.tagName;
    if (tag === "INPUT") {
      var t = (el.getAttribute("type") || "text").toLowerCase();
      if (t === "hidden") return "";
      return INPUT_ROLE[t] || "textbox";
    }
    if (tag === "A") return el.hasAttribute("href") ? "link" : "generic";
    if (tag === "BODY") return "generic";
    return TAG_ROLE[tag] || "generic";
  }

  function textOf(el) {
    var s = el.textContent || "";
    return s.replace(/\s+/g, " ").trim();
  }

  function labelledBy(el) {
    var ref = el.getAttribute("aria-labelledby");
    if (!ref) return "";
    var parts = [];
    ref.split(/\s+/).forEach(function (id) {
      var target = document.getElementById(id);
      if (target) parts.push(textOf(target));
    });
    return parts.join(" ").trim();
  }

  function fieldLabel(el) {
    if (el.id) {
      var lab = document.querySelector('label[for="' + cssEscape(el.id) + '"]');
      if (lab) return textOf(lab);
    }
    var p = el.parentElement;
    while (p) {
      if (p.tagName === "LABEL") return textOf(p);
      p = p.parentElement;
    }
    return "";
  }

  function cssEscape(s) {
    return s.replace(/["\\]/g, "\\$&");
  }

  // accname-lite: aria-label > aria-labelledby > alt/label > title >
  // placeholder > own text. Deliberately not the full accname spec.
  function nameOf(el, role) {
    var aria = el.getAttribute && el.getAttribute("aria-label");
    if (aria && aria.trim()) return aria.trim();
    var by = labelledBy(el);
    if (by) return by;
    if (el.tagName === "IMG") {
      var alt = el.getAttribute("alt");
      if (alt !== null) return alt.trim();
    }
    if (el.tagName === "INPUT" || el.tagName === "TEXTAREA" || el.tagName === "SELECT") {
      var lab = fieldLabel(el);
      if (lab) return lab;
      if (el.tagName === "INPUT" && (role === "button") && el.value) return String(el.value);
      var ph = el.getAttribute("placeholder");
      if (ph) return ph.trim();
    }
    var title = el.getAttribute && el.getAttribute("title");
    if (title && title.trim()) return title.trim();
    if (role === "document") return (document.title || "").trim();
    if (TEXTY[role]) return textOf(el);
    return "";
  }

  function valueOf(el) {
    var tag = el.tagName;
    if (tag === "INPUT") {
      var t = (el.getAttribute("type") || "text").toLowerCase();
      if (t === "checkbox" || t === "radio") return "";
      return String(el.value || "").slice(0, VALUE_CLAMP);
    }
    if (tag === "TEXTAREA") return String(el.value || "").slice(0, VALUE_CLAMP);
    if (tag === "SELECT") return String(el.value || "").slice(0, VALUE_CLAMP);
    if (tag === "PROGRESS" || tag === "METER") return String(el.value);
    return "";
  }

  function statesOf(el) {
    var out = [];
    if (document.activeElement === el) out.push("focused");
    if (el.disabled) out.push("disabled");
    if (el.checked) out.push("checked");
    if (el.readOnly) out.push("readonly");
    if (el.required) out.push("required");
    if (el.selected) out.push("selected");
    var exp = el.getAttribute && el.getAttribute("aria-expanded");
    if (exp === "true") out.push("expanded");
    if (exp === "false") out.push("collapsed");
    var cur = el.getAttribute && el.getAttribute("aria-current");
    if (cur && cur !== "false") out.push("current");
    return out.join(",");
  }

  function hidden(el) {
    if (el.getAttribute && el.getAttribute("aria-hidden") === "true") return true;
    var st = window.getComputedStyle ? window.getComputedStyle(el) : null;
    if (st && (st.display === "none" || st.visibility === "hidden")) return true;
    return false;
  }

  function ownText(el) {
    for (var i = 0; i < el.childNodes.length; i++) {
      var n = el.childNodes[i];
      if (n.nodeType === 3 && n.nodeValue && n.nodeValue.trim()) return true;
    }
    return false;
  }

  // -- the walk -------------------------------------------------------

  function walkTree(rootEl) {
    var out = [];
    byId = new Map();
    var clamp = CLAMP[detail] || CLAMP[1];

    function emit(el, role, parent) {
      var name = nameOf(el, role);
      var full = name.length;
      if (full > clamp) name = name.slice(0, clamp);
      var r = el.getBoundingClientRect ? el.getBoundingClientRect() : null;
      var id = idOf(el);
      byId.set(id, el);
      out.push({
        id: id,
        parent: parent,
        role: role,
        name: name,
        value: valueOf(el),
        states: statesOf(el),
        x: r ? Math.round(r.left) : 0,
        y: r ? Math.round(r.top) : 0,
        w: r ? Math.round(r.width) : 0,
        h: r ? Math.round(r.height) : 0,
        full: full
      });
      return id;
    }

    function descend(el, parent, depth) {
      if (out.length >= MAX_NODES || depth > 64) return;
      for (var i = 0; i < el.children.length; i++) {
        visit(el.children[i], parent, depth + 1);
        if (out.length >= MAX_NODES) return;
      }
    }

    function visit(el, parent, depth) {
      if (SKIP_TAG[el.tagName]) return;
      if (hidden(el)) return;
      var role = roleOf(el);
      if (role === "generic" && ownText(el)) role = "text";
      if (!role || role === "generic") {
        // Transparent container: its children attach to the nearest
        // emitted ancestor, which is what keeps the tree compact.
        descend(el, parent, depth);
        return;
      }
      var id = emit(el, role, parent);
      descend(el, id, depth);
    }

    var rootId = emit(rootEl, "document", 0);
    descend(rootEl, rootId, 0);
    return out;
  }

  function snapshot(req) {
    send({
      op: "tree",
      req: req,
      doc: DOC,
      url: String(location.href),
      nodes: walkTree(document.documentElement || document.body)
    });
  }

  // -- mutation batching ----------------------------------------------

  function schedule() {
    if (quiesce) clearTimeout(quiesce);
    quiesce = setTimeout(function () {
      quiesce = null;
      snapshot(0);
    }, QUIESCE_MS);
  }

  function observe(on) {
    if (!on) {
      if (observer) observer.disconnect();
      observer = null;
      return;
    }
    if (observer) return;
    observer = new MutationObserver(schedule);
    observer.observe(document.documentElement || document.body, {
      subtree: true,
      childList: true,
      characterData: true,
      attributes: true
    });
  }

  // -- actions --------------------------------------------------------

  function elFor(eid) {
    return byId.get(eid) || null;
  }

  function rectReply(req, el) {
    if (!el) return send({ op: "rect", req: req, ok: 0 });
    try {
      el.scrollIntoView({ block: "center", inline: "center" });
    } catch (e) {}
    var r = el.getBoundingClientRect();
    send({
      op: "rect",
      req: req,
      ok: r.width > 0 && r.height > 0 ? 1 : 0,
      x: Math.round(r.left + r.width / 2),
      y: Math.round(r.top + r.height / 2),
      w: Math.round(r.width),
      h: Math.round(r.height)
    });
  }

  var TYPEABLE = {
    text: 1,
    search: 1,
    url: 1,
    tel: 1,
    email: 1,
    password: 1,
    number: 1,
    "": 1
  };

  function typeable(el) {
    if (el.tagName === "TEXTAREA") return true;
    if (el.isContentEditable) return true;
    if (el.tagName !== "INPUT") return false;
    var t = (el.getAttribute("type") || "text").toLowerCase();
    return !!TYPEABLE[t];
  }

  function setValue(req, eid, arg) {
    var el = elFor(eid);
    if (!el) return send({ op: "setvalue", req: req, ok: 0, typeable: 0, msg: "unknown id" });
    try {
      el.scrollIntoView({ block: "center", inline: "center" });
    } catch (e) {}
    if (typeable(el)) {
      // The helper types the characters as real key events; all this
      // side does is focus and select what is there to be replaced.
      el.focus();
      if (el.select) el.select();
      else if (el.setSelectionRange) el.setSelectionRange(0, (el.value || "").length);
      return send({ op: "setvalue", req: req, ok: 1, typeable: 1, msg: "" });
    }
    // Non-typeable control (select, range, color, ...): the only way in
    // is a scripted assignment, which the reply flags to the client.
    try {
      el.focus();
      el.value = arg;
      el.dispatchEvent(new Event("input", { bubbles: true }));
      el.dispatchEvent(new Event("change", { bubbles: true }));
    } catch (e) {
      return send({ op: "setvalue", req: req, ok: 0, typeable: 0, msg: String(e) });
    }
    send({ op: "setvalue", req: req, ok: 1, typeable: 0, msg: "" });
  }

  function commitValue(req, eid) {
    var el = elFor(eid);
    if (!el) return send({ op: "ack", req: req, ok: 0, msg: "unknown id" });
    try {
      el.dispatchEvent(new Event("change", { bubbles: true }));
    } catch (e) {}
    send({ op: "ack", req: req, ok: 1, msg: String(el.value === undefined ? "" : el.value) });
  }

  function act(req, eid, action) {
    var el = elFor(eid);
    if (!el) return send({ op: "ack", req: req, ok: 0, msg: "unknown id" });
    try {
      if (action === "focus") el.focus();
      else if (action === "scroll") el.scrollIntoView({ block: "center", inline: "center" });
    } catch (e) {
      return send({ op: "ack", req: req, ok: 0, msg: String(e) });
    }
    send({ op: "ack", req: req, ok: 1, msg: action });
  }

  function expand(req, eid, off, len) {
    var el = elFor(eid);
    var whole = el ? textOf(el) : "";
    send({
      op: "text",
      req: req,
      off: off,
      total: whole.length,
      text: whole.slice(off, off + len)
    });
  }

  // -- reader-mode extraction ------------------------------------------
  //
  // Readability-lite: score block candidates by their own text length
  // minus link text (nav blocks are mostly links), prefer an explicit
  // <article>/<main>, then convert that subtree to markdown HERE --
  // the helper would otherwise need the live DOM and its CSS to know
  // what is visible at all.

  function densityScore(el) {
    var text = textOf(el).length;
    if (text < 100) return 0;
    var link = 0;
    var links = el.querySelectorAll("a");
    for (var i = 0; i < links.length; i++) link += textOf(links[i]).length;
    return text - link * 2;
  }

  function mainRegion() {
    var explicit = document.querySelector("article, main, [role=main]");
    if (explicit && textOf(explicit).length > 40) return explicit;
    var best = null;
    var bestScore = 0;
    var all = document.querySelectorAll("div, section, article, main, td");
    for (var i = 0; i < all.length; i++) {
      if (hidden(all[i])) continue;
      var s = densityScore(all[i]);
      if (s > bestScore) {
        bestScore = s;
        best = all[i];
      }
    }
    return best || document.body;
  }

  function inline(el) {
    var out = "";
    for (var i = 0; i < el.childNodes.length; i++) {
      var n = el.childNodes[i];
      if (n.nodeType === 3) {
        out += n.nodeValue.replace(/\s+/g, " ");
        continue;
      }
      if (n.nodeType !== 1) continue;
      var t = n.tagName;
      if (SKIP_TAG[t]) continue;
      if (t === "A" && n.hasAttribute("href")) out += "[" + inline(n).trim() + "](" + n.getAttribute("href") + ")";
      else if (t === "STRONG" || t === "B") out += "**" + inline(n).trim() + "**";
      else if (t === "EM" || t === "I") out += "*" + inline(n).trim() + "*";
      else if (t === "CODE") out += "`" + inline(n).trim() + "`";
      else if (t === "BR") out += "\n";
      else if (t === "IMG") out += "![" + (n.getAttribute("alt") || "") + "](" + (n.getAttribute("src") || "") + ")";
      else out += inline(n);
    }
    return out;
  }

  function markdown(el, depth, out) {
    if (depth > 24) return;
    for (var i = 0; i < el.children.length; i++) {
      var n = el.children[i];
      var t = n.tagName;
      if (SKIP_TAG[t] || hidden(n)) continue;
      if (/^H[1-6]$/.test(t)) {
        out.push(new Array(+t[1] + 1).join("#") + " " + inline(n).trim());
      } else if (t === "P") {
        var p = inline(n).trim();
        if (p) out.push(p);
      } else if (t === "PRE") {
        out.push("```\n" + (n.textContent || "").replace(/\s+$/, "") + "\n```");
      } else if (t === "BLOCKQUOTE") {
        out.push("> " + inline(n).trim());
      } else if (t === "UL" || t === "OL") {
        var items = n.children;
        for (var k = 0; k < items.length; k++) {
          if (items[k].tagName !== "LI") continue;
          out.push((t === "OL" ? k + 1 + ". " : "- ") + inline(items[k]).trim());
        }
      } else if (t === "HR") {
        out.push("---");
      } else if (t === "IMG") {
        out.push("![" + (n.getAttribute("alt") || "") + "](" + (n.getAttribute("src") || "") + ")");
      } else {
        markdown(n, depth + 1, out);
      }
    }
  }

  function read(req) {
    var region = mainRegion();
    var out = [];
    var title = (document.title || "").trim();
    if (title) out.push("# " + title);
    markdown(region, 0, out);
    send({ op: "markdown", req: req, url: String(location.href), md: out.join("\n\n") + "\n" });
  }

  // -- command entry point ---------------------------------------------

  function handle(json) {
    var m;
    try {
      m = parseJson(json);
    } catch (e) {
      return;
    }
    switch (m.op) {
      case "snapshot":
        if (typeof m.detail === "number") detail = m.detail;
        snapshot(m.req || 0);
        break;
      case "observe":
        observe(!!m.on);
        break;
      case "locate":
        rectReply(m.req, elFor(m.eid));
        break;
      case "act":
        act(m.req, m.eid, m.action);
        break;
      case "setvalue":
        setValue(m.req, m.eid, m.arg || "");
        break;
      case "commit":
        commitValue(m.req, m.eid);
        break;
      case "expand":
        expand(m.req, m.eid, m.off || 0, m.len || 4096);
        break;
      case "read":
        read(m.req);
        break;
      default:
        break;
    }
  }

  // The one page-reachable name, and only because a browser-process
  // command can reach a frame ONLY by evaluating source in it. It is
  // random per process, non-writable and takes commands, never replies:
  // the worst a page that finds it can do is ask for a walk of its own
  // document.
  try {
    Object.defineProperty(window, SLOT, {
      value: handle,
      writable: false,
      configurable: false,
      enumerable: false
    });
  } catch (e) {
    window[SLOT] = handle;
  }
})
