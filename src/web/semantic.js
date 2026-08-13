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
  var NAVGEN = 0;
  var QUIESCE_MS = 120;
  var CLAMP = [40, 160, 4000];
  var MAX_NODES = 4000;
  var VALUE_CLAMP = 200;

  // How many children of ONE list-ish container get described before the
  // rest collapse to a single marker. 500 table rows cost 450 rows of
  // tokens to say what the first 50 already said.
  var LIST_CAP = 50;
  // Gated on tag OR aria role, and both are needed: a <table>'s rows are
  // children of a role-less <tbody>, which reaches `descend` as a
  // transparent "generic" container, so a role-only gate would miss the
  // single biggest case.
  var LIST_TAGS = { UL: 1, OL: 1, DL: 1, MENU: 1, TABLE: 1, TBODY: 1, SELECT: 1, DATALIST: 1 };
  var LIST_ROLES = { list: 1, listbox: 1, table: 1, grid: 1, menu: 1, menubar: 1, tablist: 1, tree: 1, feed: 1, rowgroup: 1 };

  var ids = new WeakMap();
  // Marker ids, keyed on the CONTAINER element so a re-walk reuses one.
  var moreIds = new WeakMap();
  // Exact raw href state stays renderer-local. The bounded token changes
  // whenever the same element's target changes, without putting an
  // attacker-sized href into every semantic walk.
  var linkGuards = new WeakMap();
  var nextId = 1;
  var nextLinkGuard = 1;
  var byId = new Map(); // rebuilt by every walk: stale nodes drop out
  var detail = 1;
  var observer = null;
  var quiesce = null;

  // Test-only latency hook used by smoke-web to put a navigation
  // deterministically between command receipt and reply production.
  function delayed(kind, req, fn) {
    if (!window.__sketerm_test_hooks) return false;
    var attr = document.documentElement && document.documentElement.getAttribute("data-sketerm-delay-" + kind);
    var ms = attr ? parseInt(attr, 10) : 0;
    if (ms > 0) {
      document.documentElement.removeAttribute("data-sketerm-delay-" + kind);
      setTimeout(fn, Math.min(ms, 5000));
      return true;
    }
    return false;
  }

  // Replies carry the browser's nonce as a bare prefix; concatenation
  // of two primitives is the one step no page patch can intercept.
  function send(obj) {
    try {
      obj.doc = DOC;
      obj.gen = NAVGEN;
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
    // Last resort for custom widgets (a div with role=combobox, a
    // menu item, a switch): its own short text is what a user reads
    // off it, and a nameless node is unusable to an agent.
    if (ownText(el)) {
        var own = textOf(el);
        if (own && own.length <= 120) return own;
    }
    return "";
  }

  // A password's CURRENT VALUE never leaves the page: the agent-facing
  // answer is its length, which is all a "did the fill land" check
  // needs (the old browser_form_state made the same call).
  function valueOf(el) {
    var tag = el.tagName;
    if (tag === "INPUT") {
      var t = (el.getAttribute("type") || "text").toLowerCase();
      if (t === "checkbox" || t === "radio") return "";
      if (t === "password") {
        var n = String(el.value || "").length;
        return n ? "(" + n + " chars)" : "";
      }
      return String(el.value || "").slice(0, VALUE_CLAMP);
    }
    if (tag === "TEXTAREA") return String(el.value || "").slice(0, VALUE_CLAMP);
    if (tag === "SELECT") return String(el.value || "").slice(0, VALUE_CLAMP);
    if (tag === "PROGRESS" || tag === "METER") return String(el.value);
    var vn = el.getAttribute && el.getAttribute("aria-valuenow");
    if (vn) return String(vn).slice(0, VALUE_CLAMP);
    return "";
  }

  // Form-validation state travels in `states`, so one snapshot answers
  // what the old browser_form_state tool answered: required, invalid,
  // checked, disabled -- plus the ARIA spellings custom controls use,
  // since a div-based widget has none of the DOM properties.
  function aria(el, name) {
    return (el.getAttribute && el.getAttribute(name)) || "";
  }

  function invalidOf(el) {
    if (aria(el, "aria-invalid") === "true") return true;
    try {
      if (el.willValidate && el.validity && el.validity.valid === false) return true;
    } catch (e) {}
    return false;
  }

  function statesOf(el) {
    var out = [];
    if (document.activeElement === el) out.push("focused");
    if (el.disabled || aria(el, "aria-disabled") === "true") out.push("disabled");
    if (el.checked || aria(el, "aria-checked") === "true") out.push("checked");
    if (aria(el, "aria-checked") === "mixed") out.push("mixed");
    if (el.readOnly || aria(el, "aria-readonly") === "true") out.push("readonly");
    if (el.required || aria(el, "aria-required") === "true") out.push("required");
    if (el.selected || aria(el, "aria-selected") === "true") out.push("selected");
    if (invalidOf(el)) out.push("invalid");
    var exp = aria(el, "aria-expanded");
    if (exp === "true") out.push("expanded");
    if (exp === "false") out.push("collapsed");
    var cur = aria(el, "aria-current");
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
      var node = {
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
      };
      // The resolved link target, for "open this hint in a new tab"
      // (and any consumer that wants the destination without a click).
      // Only anchors carry one; String() flattens SVG's animated href.
      if ((role === "link" || el.tagName === "A" || el.tagName === "a") && el.href) {
        try {
          var u = String(el.href);
          if (u) node.url = u.slice(0, 300);
          var raw = String(el.getAttribute("href") || "");
          var guard = linkGuards.get(el);
          if (!guard || guard.href !== raw) {
            guard = { href: raw, token: nextLinkGuard++ };
            linkGuards.set(el, guard);
          }
          node.guard = String(guard.token);
        } catch (e) {}
      }
      out.push(node);
      return id;
    }

    // Open shadow roots are walked as part of the tree: a custom
    // element's real controls live there, and a walk that stopped at
    // the host would report a page of empty <pl-input> boxes.
    // A synthetic "N more" marker. It stands for children the walk
    // deliberately did NOT describe, so it is not registered in `byId`:
    // there is no element behind it and `web_act` must refuse it rather
    // than act on something arbitrary.
    //
    // Its id is keyed on the PARENT element, not minted per walk, or a
    // re-walk would report the marker as removed-and-added every time
    // and the delta stream would churn on a list that never changed.
    function emitMore(el, parent, label) {
      var id = moreIds.get(el);
      if (!id) {
        id = nextId++;
        moreIds.set(el, id);
      }
      out.push({
        id: id,
        parent: parent,
        role: "more",
        name: label,
        value: "",
        // A STRING, like every other node's: `statesOf` returns
        // `join(",")` and the Zig side declares `states: []const u8`.
        // Emitting 0 here made the whole snapshot payload fail to parse,
        // so the frame was dropped and the client waited forever — a
        // hang that only appeared once a list crossed the cap.
        states: "",
        x: 0,
        y: 0,
        w: 0,
        h: 0,
        full: 0
      });
    }

    function descend(el, parent, depth, role) {
      if (out.length >= MAX_NODES || depth > 64) return;
      var root = el.shadowRoot;
      if (root && root.children) {
        for (var s = 0; s < root.children.length; s++) {
          visit(root.children[s], parent, depth + 1);
          if (out.length >= MAX_NODES) return;
        }
      }
      // Collapse a LONG LIST to its first `LIST_CAP` rows plus a
      // marker. Gated on the container's role rather than applied to
      // every element: a page body legitimately has many children and
      // truncating it would hide the page, whereas a 500-row table
      // describes its shape in the first 50 and costs tokens for the
      // other 450. `role` is the emitted role of `el`; a transparent
      // container arrives here as "generic" and is never collapsed.
      var kids = el.children;
      var stop = kids.length;
      var omitted = 0;
      if (stop > LIST_CAP && (LIST_TAGS[el.tagName] || LIST_ROLES[role])) {
        omitted = stop - LIST_CAP;
        stop = LIST_CAP;
      }
      for (var i = 0; i < stop; i++) {
        visit(kids[i], parent, depth + 1);
        if (out.length >= MAX_NODES) return;
      }
      if (omitted) emitMore(el, parent, "\u2026 and " + omitted + " more");
    }

    function visit(el, parent, depth) {
      if (SKIP_TAG[el.tagName]) return;
      if (hidden(el)) return;
      var role = roleOf(el);
      if (role === "generic" && ownText(el)) role = "text";
      if (!role || role === "generic") {
        // Transparent container: its children attach to the nearest
        // emitted ancestor, which is what keeps the tree compact.
        descend(el, parent, depth, "generic");
        return;
      }
      var id = emit(el, role, parent);
      descend(el, id, depth, role);
    }

    var rootId = emit(rootEl, "document", 0);
    descend(rootEl, rootId, 0, "document");
    // The GLOBAL cap used to stop the walk with no trace, so a client
    // could not tell a page that ends here from one truncated here —
    // and "the element is not in the tree" reads as "it is not on the
    // page". The count is unknown by construction (we stopped looking),
    // so say that rather than invent one.
    if (out.length >= MAX_NODES)
      emitMore(rootEl, rootId, "\u2026 and more: the walk stopped at " + MAX_NODES + " nodes");
    return out;
  }

  function snapshot(req) {
    if (req && delayed("snapshot", req, function () { snapshot(req); })) return;
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

  // -- dropdowns (native <select> AND ARIA/custom listboxes) ----------
  //
  // Carries over what browser_choose did: a native select is picked by
  // option TEXT or value, and a custom dropdown is opened with a
  // trusted click (synthesized helper-side from the rect this file
  // reports), its appearing [role=option] items polled for through open
  // shadow roots, and the match clicked -- also trusted.

  function collectDeep(root, sel, out) {
    if (!root || !root.querySelectorAll) return;
    var list = root.querySelectorAll(sel);
    for (var i = 0; i < list.length; i++) out.push(list[i]);
    var all = root.querySelectorAll("*");
    for (var j = 0; j < all.length && out.length < 500; j++) {
      if (all[j].shadowRoot) collectDeep(all[j].shadowRoot, sel, out);
    }
  }

  function deepAll(sel) {
    var out = [];
    collectDeep(document, sel, out);
    return out;
  }

  function norm(s) {
    return String(s == null ? "" : s).replace(/\s+/g, " ").trim().toLowerCase();
  }

  // Exact (case-insensitive) wins over prefix, prefix over substring:
  // "Belgium" must not be beaten by "Belgium (BE) - shipping".
  function bestMatch(items, want, textOf2) {
    var w = norm(want);
    if (!w) return null;
    var pref = null;
    var sub = null;
    for (var i = 0; i < items.length; i++) {
      var t = norm(textOf2(items[i]));
      if (!t) continue;
      if (t === w) return items[i];
      if (!pref && t.indexOf(w) === 0) pref = items[i];
      if (!sub && t.indexOf(w) >= 0) sub = items[i];
    }
    return pref || sub;
  }

  function optionTexts(items, cap) {
    var out = [];
    for (var i = 0; i < items.length && out.length < cap; i++) {
      var t = textOf(items[i]) || items[i].getAttribute("aria-label") || "";
      if (t) out.push(t.slice(0, 60));
    }
    return out;
  }

  function nativeSelect(el) {
    if (el.tagName === "SELECT") return el;
    if (el.shadowRoot && el.shadowRoot.querySelector) return el.shadowRoot.querySelector("select");
    return null;
  }

  function chooseNative(req, sel, arg) {
    var opts = [];
    for (var i = 0; i < sel.options.length; i++) opts.push(sel.options[i]);
    var hit =
      bestMatch(opts, arg, function (o) {
        return o.textContent;
      }) ||
      bestMatch(opts, arg, function (o) {
        return o.value;
      });
    if (!hit) {
      return send({
        op: "setvalue",
        req: req,
        ok: 0,
        typeable: 0,
        msg: 'no option matches "' + arg + '"; visible options: ' + optionTexts(opts, 12).join(" | ")
      });
    }
    try {
      sel.focus();
      sel.selectedIndex = hit.index;
      sel.dispatchEvent(new Event("input", { bubbles: true }));
      sel.dispatchEvent(new Event("change", { bubbles: true }));
    } catch (e) {
      return send({ op: "setvalue", req: req, ok: 0, typeable: 0, msg: String(e) });
    }
    send({
      op: "setvalue",
      req: req,
      ok: 1,
      typeable: 0,
      msg:
        'selected "' +
        String(hit.textContent).replace(/\s+/g, " ").trim() +
        '" (value "' +
        hit.value +
        '") in a native <select>'
    });
  }

  // A control that opens a popup list rather than holding a value.
  function listish(el) {
    var r = norm(aria(el, "role"));
    if (r === "combobox" || r === "listbox" || r === "menu" || r === "select") return true;
    if (aria(el, "aria-haspopup")) return true;
    if (el.getAttribute && el.hasAttribute("aria-expanded")) return true;
    if (aria(el, "aria-controls") || aria(el, "aria-owns")) return true;
    return false;
  }

  var OPTION_SEL = "[role=option],[role=menuitem],[role=menuitemradio],option,li[role]";

  function visibleOptions() {
    var all = deepAll(OPTION_SEL);
    var out = [];
    for (var i = 0; i < all.length; i++) {
      var el = all[i];
      if (hidden(el)) continue;
      var r = el.getBoundingClientRect ? el.getBoundingClientRect() : null;
      if (!r || r.width <= 0 || r.height <= 0) continue;
      out.push(el);
    }
    return out;
  }

  function optionText(el) {
    return el.getAttribute("aria-label") || textOf(el) || el.getAttribute("data-value") || el.value || "";
  }

  // Poll for the options to appear: a custom dropdown animates open,
  // so the first look after the click routinely sees nothing.
  function pickOption(req, arg, budget) {
    var deadline = Date.now() + (budget || 4000);
    function attempt() {
      var opts = visibleOptions();
      var hit = bestMatch(opts, arg, optionText);
      if (hit) {
        try {
          hit.scrollIntoView({ block: "center", inline: "center" });
        } catch (e) {}
        var r = hit.getBoundingClientRect();
        return send({
          op: "optrect",
          req: req,
          ok: 1,
          x: Math.round(r.left + r.width / 2),
          y: Math.round(r.top + r.height / 2),
          text: String(optionText(hit)).replace(/\s+/g, " ").trim().slice(0, 120)
        });
      }
      if (Date.now() < deadline) return setTimeout(attempt, 100);
      send({
        op: "optrect",
        req: req,
        ok: 0,
        x: 0,
        y: 0,
        text: "",
        seen: optionTexts(visibleOptions(), 12).join(" | ")
      });
    }
    attempt();
  }

  // What the control reads as after a pick, for the act result.
  function controlState(req, eid) {
    var el = elFor(eid);
    if (!el) return send({ op: "ack", req: req, ok: 1, msg: "" });
    var v = valueOf(el);
    if (!v) {
      var owned = aria(el, "aria-activedescendant");
      if (owned) {
        var t = document.getElementById(owned);
        if (t) v = textOf(t);
      }
    }
    if (!v) v = textOf(el).slice(0, 120);
    send({ op: "ack", req: req, ok: 1, msg: String(v).slice(0, 200) });
  }

  function setValue(req, eid, arg) {
    var el = elFor(eid);
    if (!el) return send({ op: "setvalue", req: req, ok: 0, typeable: 0, msg: "unknown id" });
    try {
      el.scrollIntoView({ block: "center", inline: "center" });
    } catch (e) {}
    // A native select -- including one inside a custom element's open
    // shadow root -- is picked by option text or value.
    var sel = nativeSelect(el);
    if (sel) return chooseNative(req, sel, arg);
    if (!typeable(el) && listish(el)) {
      var r = el.getBoundingClientRect();
      if (r.width <= 0 || r.height <= 0) {
        return send({ op: "setvalue", req: req, ok: 0, typeable: 0, msg: "dropdown has no box to click" });
      }
      // The helper clicks HERE (trusted), then asks for the option.
      return send({
        op: "setvalue",
        req: req,
        ok: 1,
        typeable: 0,
        custom: 1,
        x: Math.round(r.left + r.width / 2),
        y: Math.round(r.top + r.height / 2),
        msg: "custom dropdown"
      });
    }
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

  function readerEntity(el, kind, entities) {
    if (entities.length >= MAX_NODES) return;
    var entity = {
      eid: idOf(el),
      kind: kind,
      text: textOf(el).slice(0, 300),
      url: ""
    };
    if (kind === "link") {
      try {
        entity.url = String(el.href || el.getAttribute("href") || "").slice(0, 1000);
      } catch (e) {}
    }
    entities.push(entity);
  }

  function inline(el, entities) {
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
      if (t === "A" && n.hasAttribute("href")) {
        readerEntity(n, "link", entities);
        out += "[" + inline(n, entities).trim() + "](" + n.getAttribute("href") + ")";
      } else if (t === "STRONG" || t === "B") out += "**" + inline(n, entities).trim() + "**";
      else if (t === "EM" || t === "I") out += "*" + inline(n, entities).trim() + "*";
      else if (t === "CODE") out += "`" + inline(n, entities).trim() + "`";
      else if (t === "BR") out += "\n";
      else if (t === "IMG") out += "![" + (n.getAttribute("alt") || "") + "](" + (n.getAttribute("src") || "") + ")";
      else out += inline(n, entities);
    }
    return out;
  }

  function markdown(el, depth, out, entities) {
    if (depth > 24) return;
    for (var i = 0; i < el.children.length; i++) {
      var n = el.children[i];
      var t = n.tagName;
      if (SKIP_TAG[t] || hidden(n)) continue;
      if (/^H[1-6]$/.test(t)) {
        readerEntity(n, "heading", entities);
        out.push(new Array(+t[1] + 1).join("#") + " " + inline(n, entities).trim());
      } else if (t === "P") {
        var p = inline(n, entities).trim();
        if (p) out.push(p);
      } else if (t === "PRE") {
        out.push("```\n" + (n.textContent || "").replace(/\s+$/, "") + "\n```");
      } else if (t === "BLOCKQUOTE") {
        out.push("> " + inline(n, entities).trim());
      } else if (t === "UL" || t === "OL") {
        var items = n.children;
        for (var k = 0; k < items.length; k++) {
          if (items[k].tagName !== "LI") continue;
          readerEntity(items[k], "item", entities);
          out.push((t === "OL" ? k + 1 + ". " : "- ") + inline(items[k], entities).trim());
        }
      } else if (t === "HR") {
        out.push("---");
      } else if (t === "IMG") {
        out.push("![" + (n.getAttribute("alt") || "") + "](" + (n.getAttribute("src") || "") + ")");
      } else {
        markdown(n, depth + 1, out, entities);
      }
    }
  }

  function read(req, withIds) {
    if (req && delayed("read", req, function () { read(req, withIds); })) return;
    var region = mainRegion();
    var out = [];
    var entities = [];
    var nodes = withIds ? walkTree(document.documentElement || document.body) : null;
    var title = (document.title || "").trim();
    if (title) out.push("# " + title);
    if (withIds && /^(ARTICLE|MAIN|SECTION)$/.test(region.tagName || "")) readerEntity(region, "section", entities);
    markdown(region, 0, out, entities);
    var reply = { op: "markdown", req: req, url: String(location.href), md: out.join("\n\n") + "\n" };
    if (withIds) {
      reply.doc = DOC;
      reply.nodes = nodes;
      reply.entities = entities;
    }
    send(reply);
  }

  // -- script evaluation ------------------------------------------------
  //
  // The escape hatch. Everything here degrades rather than fails: a
  // getter that throws, a cyclic object, a function, `undefined` -- all
  // become a described placeholder, because a caller debugging a page
  // needs an answer far more than it needs a clean type.

  var EVAL_MAXSTR = 4000;
  var EVAL_MAXITEMS = 200;
  var EVAL_MAXDEPTH = 6;

  function nodeRef(el) {
    var role = roleOf(el);
    var known = ids.get(el);
    // Only an id the CURRENT walk emitted can be fed back to web_act;
    // eid 0 tells the helper to answer semantic_id null.
    if (!known || !byId.has(known)) known = 0;
    return { __kind: "node", eid: known, role: role, name: String(nameOf(el, role) || "").slice(0, 200) };
  }

  function encodeVal(v, depth, seen) {
    var t = typeof v;
    if (v === undefined) return { __kind: "undefined" };
    if (v === null) return null;
    if (t === "boolean") return v;
    if (t === "number") return isFinite(v) ? v : { __kind: "number", text: String(v) };
    if (t === "string") return v.length > EVAL_MAXSTR ? v.slice(0, EVAL_MAXSTR) : v;
    if (t === "bigint") return { __kind: "bigint", text: String(v) };
    if (t === "symbol") return { __kind: "symbol", text: String(v) };
    if (t === "function") return { __kind: "function", name: String(v.name || "(anonymous)") };
    if (t !== "object") return { __kind: "unknown", text: String(t) };
    for (var s = 0; s < seen.length; s++) if (seen[s] === v) return { __kind: "cyclic" };
    if (depth >= EVAL_MAXDEPTH) return { __kind: "truncated", note: "max depth " + EVAL_MAXDEPTH };
    try {
      if (v.nodeType === 1) return nodeRef(v);
      if (v.nodeType) return { __kind: "node", node_type: v.nodeType, text: String(v.nodeValue || "").slice(0, 200) };
      if (v instanceof Error) {
        return { __kind: "error", message: String(v.message || v), stack: String(v.stack || "") };
      }
      if (v instanceof Date) return { __kind: "date", text: v.toISOString() };
      if (v instanceof RegExp) return { __kind: "regexp", text: String(v) };
    } catch (e) {}
    seen.push(v);
    try {
      var arrayish =
        Object.prototype.toString.call(v) === "[object Array]" ||
        (typeof v.length === "number" && typeof v.item === "function");
      if (arrayish) {
        var arr = [];
        var n = Math.min(v.length, EVAL_MAXITEMS);
        for (var i = 0; i < n; i++) {
          try {
            arr.push(encodeVal(v[i], depth + 1, seen));
          } catch (e2) {
            arr.push({ __kind: "throwing", text: String(e2) });
          }
        }
        if (v.length > n) arr.push({ __kind: "truncated", note: v.length - n + " more items" });
        return arr;
      }
      var obj = {};
      var keys;
      try {
        keys = Object.keys(v);
      } catch (e3) {
        keys = [];
      }
      var kn = Math.min(keys.length, EVAL_MAXITEMS);
      for (var k = 0; k < kn; k++) {
        try {
          obj[keys[k]] = encodeVal(v[keys[k]], depth + 1, seen);
        } catch (e4) {
          obj[keys[k]] = { __kind: "throwing", text: String(e4) };
        }
      }
      if (keys.length > kn) obj.__truncated = keys.length - kn + " more keys";
      if (kn === 0 && keys.length === 0) {
        var tag = Object.prototype.toString.call(v);
        if (tag !== "[object Object]") return { __kind: "opaque", text: tag };
      }
      return obj;
    } finally {
      seen.pop();
    }
  }

  function evalJson(payload) {
    try {
      return stringify(payload);
    } catch (e) {
      return '{"value":{"__kind":"unserializable","text":' + stringify(String(e)) + "}}";
    }
  }

  function sendEvalOk(req, v) {
    var body;
    try {
      body = { value: encodeVal(v, 0, []) };
    } catch (e) {
      body = { value: { __kind: "unserializable", text: String(e) } };
    }
    send({ op: "eval", req: req, ok: 1, json: evalJson(body) });
  }

  function sendEvalErr(req, e, note) {
    var msg = "";
    var stack = "";
    try {
      msg = String((e && e.message) || e);
      stack = String((e && e.stack) || "");
    } catch (e2) {
      msg = "non-reportable exception";
    }
    send({
      op: "eval",
      req: req,
      ok: 0,
      json: evalJson({ error: msg, stack: stack.slice(0, 4000), note: note || "" })
    });
  }

  function evaluate(req, code, wantAwait, timeout) {
    var v;
    try {
      // Indirect eval: global scope, so `var` declarations and function
      // hoisting behave the way a console user expects.
      v = (0, eval)(code);
    } catch (e) {
      return sendEvalErr(req, e, "thrown while evaluating");
    }
    if (!wantAwait || !v || typeof v.then !== "function") return sendEvalOk(req, v);
    var done = false;
    var timer = setTimeout(function () {
      if (done) return;
      done = true;
      sendEvalErr(req, new Error("await timed out after " + timeout + "ms"), "the promise never settled");
    }, timeout);
    try {
      v.then(
        function (r) {
          if (done) return;
          done = true;
          clearTimeout(timer);
          sendEvalOk(req, r);
        },
        function (e) {
          if (done) return;
          done = true;
          clearTimeout(timer);
          sendEvalErr(req, e, "the promise rejected");
        }
      );
    } catch (e3) {
      if (done) return;
      done = true;
      clearTimeout(timer);
      sendEvalErr(req, e3, "thenable refused a callback");
    }
  }

  // -- WebExtensions content-script runtime ----------------------------
  //
  // Reuses this SAME authenticated channel: the browser process injects
  // an extension's content scripts by evaluating source in this frame's
  // SLOT (op "ext-inject"), the injected `browser`/`chrome` object posts
  // async calls back over the nonce-prefixed transport, and replies
  // arrive as further SLOT commands. Each extension runs in its own
  // closure with its own `browser`, so extensions do not see each
  // other's state. This is NOT a separate V8 world (a CEF OSR limit,
  // see src/web/CLAUDE.md): the closure isolates the API surface, not
  // the intrinsics, so page and content script still share globals.
  var extReqSeq = 1;
  var extPending = {}; // req -> resolve fn
  var extCtx = {}; // ext id -> { listeners:[], changed:[] }
  var extApiOf = {}; // ext id -> the `browser` object built for it

  // `SKETERM_WEB_EXT_DEBUG=1` in the helper: log every browser.* call
  // and its reply. A hung extension is almost always a Promise this
  // bridge never settled, and the pairing is invisible without this.
  var extDebug = false;

  function extApiCall(extId, ns, method, args) {
    var req = extReqSeq++;
    if (extDebug) {
      try {
        console.log("SKEXT call#" + req + " " + ns + "." + method + " " +
          JSON.stringify(args).slice(0, 200));
      } catch (e) {}
    }
    return new Promise(function (resolve) {
      extPending[req] = resolve;
      send({ op: "ext-call", ext: extId, ns: ns, method: method, args: args, req: req });
    });
  }

  function extSendMessage(extId, msg) {
    var req = extReqSeq++;
    return new Promise(function (resolve) {
      extPending[req] = resolve;
      send({ op: "ext-send", ext: extId, req: req, msg: msg });
    });
  }

  function extEvent() {
    var fns = [];
    return {
      _fns: fns,
      addListener: function (fn) {
        if (typeof fn === "function" && fns.indexOf(fn) < 0) fns.push(fn);
      },
      removeListener: function (fn) {
        var i = fns.indexOf(fn);
        if (i >= 0) fns.splice(i, 1);
      },
      hasListener: function (fn) {
        return fns.indexOf(fn) >= 0;
      }
    };
  }

  // -- blocking webRequest (MV2) ---------------------------------------
  //
  // The listener FUNCTIONS live here, in the background page's renderer;
  // only their RequestFilter and extraInfoSpec go to the browser
  // process, which is what lets it decide whether a request needs JS at
  // all without asking. A held request arrives as one "ext-wreq"
  // command and is answered by exactly one "ext-wreq-decision" — the
  // browser process is holding a real network request open across that
  // gap, so every path below answers, including the ones that throw.
  var extWreqSeq = 1;

  function extWebRequestEvent(extId, ctx, eventName) {
    var entries = []; // {fn, id, blocking}
    ctx.wreq[eventName] = entries;
    return {
      addListener: function (fn, filter, extraInfoSpec) {
        if (typeof fn !== "function") return;
        for (var i = 0; i < entries.length; i++) {
          if (entries[i].fn === fn) return;
        }
        var spec = extraInfoSpec || [];
        var id = extWreqSeq++;
        entries.push({
          fn: fn,
          id: id,
          blocking: spec.indexOf("blocking") >= 0
        });
        extApiCall(extId, "webRequest", "addListener", [
          eventName, id, filter || {}, spec
        ]);
      },
      removeListener: function (fn) {
        for (var i = 0; i < entries.length; i++) {
          if (entries[i].fn !== fn) continue;
          var id = entries[i].id;
          entries.splice(i, 1);
          extApiCall(extId, "webRequest", "removeListener", [id]);
          return;
        }
      },
      hasListener: function (fn) {
        for (var i = 0; i < entries.length; i++) {
          if (entries[i].fn === fn) return true;
        }
        return false;
      }
    };
  }

  // MV2's ResourceType enum. uBlock Origin reads this object directly
  // (`browser.webRequest.ResourceType.WEBSOCKET`) to decide whether it
  // may filter websockets at all, so it is a value, not a stub.
  var extResourceType = {
    MAIN_FRAME: "main_frame",
    SUB_FRAME: "sub_frame",
    STYLESHEET: "stylesheet",
    SCRIPT: "script",
    IMAGE: "image",
    FONT: "font",
    OBJECT: "object",
    XMLHTTPREQUEST: "xmlhttprequest",
    PING: "ping",
    CSP_REPORT: "csp_report",
    MEDIA: "media",
    WEBSOCKET: "websocket",
    OTHER: "other"
  };

  // The NOTIFICATION-ONLY webRequest events. They accept listeners and
  // never fire: nothing in the helper delivers them yet.
  //
  // They exist because their ABSENCE was fatal, not because they work.
  // uBlock Origin's `webRequest.start()` calls
  // `browser.webRequest.onResponseStarted.addListener(...)` — an
  // unconditional property access — and a TypeError there aborts the
  // REST of uBO's boot sequence from inside its own startup, leaving a
  // half-initialised filtering engine that then cancelled every
  // top-level navigation. An inert event object is a limitation; an
  // undefined one is a broken extension.
  //
  // The cost is named: `onResponseStarted` is where uBO injects its
  // scriptlets, so scriptlet injection does not happen.
  function inertEvent() {
    var ev = extEvent();
    var add = ev.addListener;
    ev.addListener = function (fn) {
      add(fn);
    };
    return ev;
  }

  function makeWebRequest(extId, ctx) {
    return {
      ResourceType: extResourceType,
      MAX_HANDLER_BEHAVIOR_CHANGED_CALLS_PER_10_MINUTES: 20,
      onBeforeRequest: extWebRequestEvent(extId, ctx, "onBeforeRequest"),
      onBeforeSendHeaders: extWebRequestEvent(extId, ctx, "onBeforeSendHeaders"),
      onHeadersReceived: extWebRequestEvent(extId, ctx, "onHeadersReceived"),
      onSendHeaders: inertEvent(),
      onResponseStarted: inertEvent(),
      onBeforeRedirect: inertEvent(),
      onCompleted: inertEvent(),
      onErrorOccurred: inertEvent(),
      onAuthRequired: inertEvent(),
      handlerBehaviorChanged: function () {
        return extApiCall(extId, "webRequest", "handlerBehaviorChanged", []);
      }
    };
  }

  // One held request. Runs the matching listeners in registration order
  // and answers with the FIRST decisive BlockingResponse; a cancel beats
  // a redirect, matching Firefox's own resolution. A listener that
  // throws is skipped, never fatal — the browser process would fail the
  // request open on a timeout anyway, and answering promptly is better.
  function extWebRequest(m) {
    var answered = false;
    // An "obs" notification is a mailbox drop: the browser process has
    // already continued the request and retired its slot, so answering
    // would name a hold that no longer exists.
    var wantAnswer = m.obs !== true;
    function answer(d) {
      if (answered) return;
      answered = true;
      if (!wantAnswer) return;
      try {
        send({ op: "ext-wreq-decision", hid: m.hid, d: d || {} });
      } catch (e) {}
    }
    var ctx = extCtx[m.ext];
    if (!ctx || !ctx.wreq) {
      answer(null);
      return;
    }
    var entries = ctx.wreq[m.event];
    if (!entries || entries.length === 0) {
      answer(null);
      return;
    }
    var details = m.details || {};
    var pending = null;
    var merged = null;
    // ONLY the listeners whose own RequestFilter matched. The browser
    // process evaluated each filter and names the survivors in `lids`;
    // an absent list means "all", which is only the case for commands
    // predating this field.
    var lids = m.lids;
    for (var i = 0; i < entries.length; i++) {
      if (lids && lids.indexOf(entries[i].id) < 0) continue;
      var r;
      try {
        r = entries[i].fn(details);
      } catch (e) {
        if (m.dbg) {
          try {
            console.log("SKWREQ listener " + i + " THREW on " + details.url + ": " +
              (e && e.stack ? e.stack : String(e)));
          } catch (e9) {}
        }
        continue;
      }
      if (m.dbg) {
        try {
          console.log("SKWREQ listener " + i + "/" + entries.length +
            " blocking=" + entries[i].blocking + " on " + details.url +
            " -> " + JSON.stringify(r));
        } catch (e8) {}
      }
      if (!entries[i].blocking) continue;
      if (r && typeof r.then === "function") {
        // Firefox lets a blocking listener return a Promise. Take the
        // first one and let it decide; the browser process's deadline
        // is the backstop if it never settles.
        pending = r;
        break;
      }
      if (!r || typeof r !== "object") continue;
      if (r.cancel === true) {
        answer({ cancel: true });
        return;
      }
      if (typeof r.redirectUrl === "string" && r.redirectUrl.length) {
        answer({ redirectUrl: r.redirectUrl });
        return;
      }
      if (r.requestHeaders || r.responseHeaders) merged = r;
    }
    if (pending) {
      pending.then(function (r2) {
        answer(r2 && typeof r2 === "object" ? r2 : null);
      }, function () {
        answer(null);
      });
      return;
    }
    answer(merged);
  }

  function makeBrowser(extId, baseUrl, manifestObj, messages) {
    var ctx = {
      listeners: extEvent(),
      changed: extEvent(),
      wreq: {},
      connect: extEvent(),
      ports: {},
      pending_ports: {}
    };
    extCtx[extId] = ctx;
    var storageLocal = {
      get: function (keys) {
        return extApiCall(extId, "storage", "get", [keys === undefined ? null : keys]);
      },
      set: function (obj) {
        return extApiCall(extId, "storage", "set", [obj]);
      },
      remove: function (keys) {
        return extApiCall(extId, "storage", "remove", [keys]);
      },
      clear: function () {
        return extApiCall(extId, "storage", "clear", []);
      },
      onChanged: ctx.changed
    };
    var api = {
      runtime: {
        id: extId,
        lastError: null,
        getManifest: function () {
          return manifestObj;
        },
        getURL: function (path) {
          return baseUrl + String(path == null ? "" : path).replace(/^\//, "");
        },
        sendMessage: function (msg) {
          // The 1-arg form; an extension id / options arg is tolerated
          // by ignoring everything but the last message-shaped arg.
          var m = arguments.length > 1 ? arguments[arguments.length - 1] : msg;
          return extSendMessage(extId, m);
        },
        connect: function (a, b) {
          // MV2: connect(connectInfo) or connect(extensionId, connectInfo).
          var info = (b && typeof b === "object") ? b : (a && typeof a === "object" ? a : {});
          return extConnect(extId, ctx, info.name || "");
        },
        onConnect: ctx.connect,
        onMessage: ctx.listeners
      },
      storage: { local: storageLocal, onChanged: ctx.changed },
      webRequest: makeWebRequest(extId, ctx),
      i18n: {
        // Resolved from the inlined catalogue when it can be — this is
        // the SYNCHRONOUS form the API promises and a Promise would
        // break every caller. `$1`/`$name$` substitution matches the
        // browser-process implementation in webext/i18n.zig; keeping
        // both is the price of a synchronous getMessage.
        getMessage: function (key, subs) {
          var e = messages && messages[key];
          if (!e || typeof e.message !== "string") return "";
          return extExpandMessage(e.message, e.placeholders, subs);
        },
        getUILanguage: function () {
          return extUiLanguage;
        }
      },
      tabs: {
        query: function (q) {
          return extApiCall(extId, "tabs", "query", [q || {}]);
        },
        get: function (id) {
          return extApiCall(extId, "tabs", "get", [id]);
        },
        sendMessage: function (id, msg) {
          return extApiCall(extId, "tabs", "sendMessage", [id, msg]);
        },
        update: function (a, b) {
          // update(props) or update(tabId, props).
          var id = typeof a === "number" ? a : -1;
          var props = (typeof a === "object" ? a : b) || {};
          return extApiCall(extId, "tabs", "update", [id, props]);
        },
        create: function (props) {
          return extApiCall(extId, "tabs", "create", [props || {}]);
        },
        reload: function (id) {
          return extApiCall(extId, "tabs", "reload", [typeof id === "number" ? id : -1]);
        },
        remove: noopAsync,
        insertCSS: noopAsync,
        removeCSS: noopAsync,
        executeScript: noopAsyncValue([]),
        getZoom: noopAsyncValue(1),
        setZoom: noopAsync,
        onUpdated: extEvent(),
        onRemoved: extEvent(),
        onActivated: extEvent(),
        onCreated: extEvent()
      }
    };
    addExtStubs(api, extId, ctx);
    ctx.tabs = api.tabs;
    extApiOf[extId] = api;
    return api;
  }

  // The UI language, filled in by the first ext-inject that carries one.
  var extUiLanguage = "en";

  // -- extension namespaces ----------------------------------------------
  //
  // MV2 surfaces a real extension calls UNCONDITIONALLY, on paths it
  // does not feature-detect. uBlock Origin's very first act after its
  // module graph loads is `browserAction.setIcon`, and an `undefined`
  // there is a TypeError that takes the whole background page down —
  // an extension that is "enabled" and does nothing at all.
  //
  // browserAction is real: state crosses the bridge and trusted clicks
  // come back from GTK. The remaining namespaces below are benign stubs
  // and are meant to read as stubs. What they buy is that an extension
  // RUNS instead of dying on line one. Anything an extension feature-
  // detects (`privacy`, `dns`, `contentScripts`, `storage.sync`/`managed`,
  // `filterResponseData`) is deliberately LEFT ABSENT, because degrading
  // gracefully is what that detection is for and a stub would defeat it.
  function noopAsync() {
    return Promise.resolve();
  }
  function noopAsyncValue(v) {
    return function () {
      return Promise.resolve(v);
    };
  }

  function addExtStubs(api, extId, ctx) {
    var action = {
      setIcon: function (d) { return extApiCall(extId, "browserAction", "setIcon", [d || {}]); },
      setTitle: function (d) { return extApiCall(extId, "browserAction", "setTitle", [d || {}]); },
      setBadgeText: function (d) { return extApiCall(extId, "browserAction", "setBadgeText", [d || {}]); },
      setBadgeTextColor: function (d) { return extApiCall(extId, "browserAction", "setBadgeTextColor", [d || {}]); },
      setBadgeBackgroundColor: function (d) { return extApiCall(extId, "browserAction", "setBadgeBackgroundColor", [d || {}]); },
      setPopup: function (d) { return extApiCall(extId, "browserAction", "setPopup", [d || {}]); },
      getPopup: function (d) { return extApiCall(extId, "browserAction", "getPopup", [d || {}]); },
      getBadgeText: function (d) { return extApiCall(extId, "browserAction", "getBadgeText", [d || {}]); },
      getTitle: function (d) { return extApiCall(extId, "browserAction", "getTitle", [d || {}]); },
      enable: function (tabId) { return extApiCall(extId, "browserAction", "enable", tabId === undefined ? [] : [tabId]); },
      disable: function (tabId) { return extApiCall(extId, "browserAction", "disable", tabId === undefined ? [] : [tabId]); },
      isEnabled: function (d) { return extApiCall(extId, "browserAction", "isEnabled", d && d.tabId !== undefined ? [d.tabId] : []); },
      openPopup: noopAsync,
      onClicked: extEvent()
    };
    api.browserAction = action;
    api.pageAction = action;
    api.action = action;

    var menus = {
      create: function () {
        return 0;
      },
      update: noopAsync,
      remove: noopAsync,
      removeAll: noopAsync,
      refresh: noopAsync,
      onClicked: extEvent(),
      onShown: extEvent(),
      onHidden: extEvent(),
      ACTION_MENU_TOP_LEVEL_LIMIT: 6
    };
    api.menus = menus;
    api.contextMenus = menus;

    // Alarms: real, because they are pure timers and an extension that
    // schedules its housekeeping on them would otherwise never do it.
    var alarms = {};
    api.alarms = {
      create: function (name, info) {
        var n = typeof name === "string" ? name : "";
        var opts = (typeof name === "object" ? name : info) || {};
        var delay = opts.when ? Math.max(0, opts.when - Date.now())
          : (opts.delayInMinutes || opts.periodInMinutes || 0) * 60000;
        if (alarms[n]) clearTimeout(alarms[n].timer);
        var period = (opts.periodInMinutes || 0) * 60000;
        var fire = function () {
          fireAll(api.alarms.onAlarm, [{ name: n, scheduledTime: Date.now() }]);
          if (period > 0) alarms[n] = { timer: setTimeout(fire, period), period: period };
          else delete alarms[n];
        };
        alarms[n] = { timer: setTimeout(fire, delay || period || 60000), period: period };
      },
      clear: function (name) {
        var n = typeof name === "string" ? name : "";
        if (alarms[n]) {
          clearTimeout(alarms[n].timer);
          delete alarms[n];
        }
        return Promise.resolve(true);
      },
      clearAll: function () {
        for (var k in alarms) clearTimeout(alarms[k].timer);
        alarms = {};
        return Promise.resolve(true);
      },
      get: noopAsyncValue(undefined),
      getAll: noopAsyncValue([]),
      onAlarm: extEvent()
    };

    api.windows = {
      WINDOW_ID_NONE: -1,
      WINDOW_ID_CURRENT: -2,
      get: noopAsyncValue(null),
      getCurrent: noopAsyncValue({ id: 0, focused: true, type: "normal" }),
      getLastFocused: noopAsyncValue({ id: 0, focused: true, type: "normal" }),
      getAll: noopAsyncValue([{ id: 0, focused: true, type: "normal" }]),
      create: noopAsyncValue(null),
      update: noopAsync,
      remove: noopAsync,
      onCreated: extEvent(),
      onRemoved: extEvent(),
      onFocusChanged: extEvent()
    };

    // webNavigation: the EVENTS exist so a listener can be registered
    // without throwing; nothing fires them yet, which is why an
    // extension relying on them for per-frame bookkeeping stays empty.
    api.webNavigation = {
      getFrame: noopAsyncValue(null),
      getAllFrames: noopAsyncValue([]),
      onBeforeNavigate: extEvent(),
      onCommitted: extEvent(),
      onDOMContentLoaded: extEvent(),
      onCompleted: extEvent(),
      onErrorOccurred: extEvent(),
      onCreatedNavigationTarget: extEvent(),
      onHistoryStateUpdated: extEvent(),
      onReferenceFragmentUpdated: extEvent()
    };

    api.notifications = {
      create: noopAsyncValue("0"),
      clear: noopAsyncValue(true),
      getAll: noopAsyncValue({}),
      onClicked: extEvent(),
      onClosed: extEvent(),
      onButtonClicked: extEvent()
    };

    api.commands = {
      getAll: noopAsyncValue([]),
      onCommand: extEvent()
    };

    api.permissions = {
      contains: noopAsyncValue(true),
      getAll: noopAsyncValue({ permissions: [], origins: [] }),
      request: noopAsyncValue(false),
      remove: noopAsyncValue(false),
      onAdded: extEvent(),
      onRemoved: extEvent()
    };

    api.extension = {
      getURL: api.runtime.getURL,
      getViews: function () {
        return [];
      },
      isAllowedFileSchemeAccess: noopAsyncValue(false),
      inIncognitoContext: false
    };

    // `storage.session` is a real in-memory store — cheap, and an
    // extension that keeps its hot state there otherwise loses it on
    // every write. `sync` and `managed` stay ABSENT on purpose: an
    // extension feature-detects them and degrades, and a stub that
    // silently drops synced settings would be worse than neither.
    var session = {};
    api.storage.session = {
      get: function (keys) {
        var out = {};
        if (keys === undefined || keys === null) {
          for (var k in session) out[k] = session[k];
        } else if (typeof keys === "string") {
          if (keys in session) out[keys] = session[keys];
        } else if (keys && keys.length !== undefined) {
          for (var i = 0; i < keys.length; i++) {
            if (keys[i] in session) out[keys[i]] = session[keys[i]];
          }
        } else if (keys) {
          for (var d in keys) out[d] = (d in session) ? session[d] : keys[d];
        }
        return Promise.resolve(out);
      },
      set: function (obj) {
        for (var k2 in obj) session[k2] = obj[k2];
        return Promise.resolve();
      },
      remove: function (keys) {
        var list = typeof keys === "string" ? [keys] : (keys || []);
        for (var i2 = 0; i2 < list.length; i2++) delete session[list[i2]];
        return Promise.resolve();
      },
      clear: function () {
        session = {};
        return Promise.resolve();
      },
      onChanged: extEvent()
    };

    api.runtime.getPlatformInfo = noopAsyncValue({ os: "linux", arch: "x86-64" });
    api.runtime.getBrowserInfo = noopAsyncValue({
      name: "sketerm", vendor: "sketerm", version: "1.0", buildID: "0"
    });
    api.runtime.setUninstallURL = noopAsync;
    api.runtime.openOptionsPage = noopAsync;
    // REAL, not a stub: an extension that asks to restart and is not
    // restarted simply stops. uBO's first run ends on this call.
    api.runtime.reload = function () {
        return extApiCall(extId, "runtime", "reload", []);
    };
    api.runtime.onInstalled = extEvent();
    api.runtime.onStartup = extEvent();
    api.runtime.onSuspend = extEvent();
    api.runtime.onUpdateAvailable = extEvent();
    api.runtime.onConnectExternal = extEvent();
    api.runtime.onMessageExternal = extEvent();


  }

  // `$1`..`$9` and `$name$` expansion. Named placeholders resolve to
  // their `content` FIRST, then every numbered marker resolves once —
  // doing it the other way round would let a substitution's own text be
  // re-read as a placeholder.
  function extExpandMessage(message, placeholders, subs) {
    var list = [];
    if (typeof subs === "string") list = [subs];
    else if (subs && subs.length) {
      for (var i = 0; i < subs.length; i++) list.push(String(subs[i]));
    }
    var named = String(message).replace(/\$([A-Za-z0-9_@]+)\$/g, function (whole, name) {
      if (!placeholders) return "";
      var lower = String(name).toLowerCase();
      for (var k in placeholders) {
        if (String(k).toLowerCase() !== lower) continue;
        var p = placeholders[k];
        return (p && typeof p.content === "string") ? p.content : "";
      }
      return "";
    });
    return named.replace(/\$(\$|[1-9])/g, function (whole, d) {
      if (d === "$") return "$";
      var idx = Number(d) - 1;
      return idx < list.length ? list[idx] : "";
    });
  }

  // -- runtime.connect Ports --------------------------------------------
  //
  // Every content script of uBlock Origin and Violentmonkey opens one as
  // its first act and TEARS ITSELF DOWN if it throws
  // (`vAPI.shutdown.exec()`), so "no Port API" is not a missing feature
  // to those extensions, it is a fatal one.
  //
  // The browser process mints the global id, because only it can see
  // both ends. A Port is therefore usable IMMEDIATELY but not yet
  // numbered: posts before the id arrives queue in `pre`, and are
  // flushed in order once `ext-port-open` lands. Firefox has the same
  // observable behaviour (a Port is returned synchronously and delivery
  // is asynchronous), so nothing here is a workaround for the delay.
  var extPortSeq = 1;

  function makePort(extId, ctx, name, sender) {
    var port = {
      name: name || "",
      sender: sender || null,
      gid: 0,
      pre: [],
      dead: false,
      onMessage: extEvent(),
      onDisconnect: extEvent(),
      postMessage: function (msg) {
        if (port.dead) return;
        if (!port.gid) {
          port.pre.push(msg);
          return;
        }
        send({ op: "ext-port-msg", gid: port.gid, msg: msg === undefined ? null : msg });
      },
      disconnect: function () {
        if (port.dead) return;
        port.dead = true;
        if (port.gid) {
          delete ctx.ports[port.gid];
          send({ op: "ext-port-close", gid: port.gid });
        }
      }
    };
    return port;
  }

  function extConnect(extId, ctx, name) {
    var lid = extPortSeq++;
    var port = makePort(extId, ctx, name, null);
    ctx.pending_ports[lid] = port;
    send({ op: "ext-connect", ext: extId, lid: lid, name: name || "" });
    return port;
  }

  /// The browser process numbered a port we opened: flush anything the
  /// caller already posted, in order.
  function extPortOpen(m) {
    var ctx = extCtx[m.ext];
    if (!ctx) return;
    var port = ctx.pending_ports[m.lid];
    if (!port) return;
    delete ctx.pending_ports[m.lid];
    if (!m.gid) {
      // Nothing on the other end. MV2 answers that with an immediate
      // onDisconnect rather than a hang.
      port.dead = true;
      fireAll(port.onDisconnect, [port]);
      return;
    }
    port.gid = m.gid;
    ctx.ports[m.gid] = port;
    var queued = port.pre;
    port.pre = [];
    for (var i = 0; i < queued.length; i++) {
      send({ op: "ext-port-msg", gid: m.gid, msg: queued[i] === undefined ? null : queued[i] });
    }
  }

  /// Somebody connected TO this frame: build the receiving Port and hand
  /// it to `runtime.onConnect`.
  function extPortIncoming(m) {
    var ctx = extCtx[m.ext];
    if (!ctx) {
      send({ op: "ext-port-close", gid: m.gid });
      return;
    }
    var port = makePort(m.ext, ctx, m.name || "", m.sender || null);
    port.gid = m.gid;
    ctx.ports[m.gid] = port;
    fireAll(ctx.connect, [port]);
  }

  function extPortRecv(m) {
    var ctx = extCtx[m.ext];
    if (!ctx) return;
    var port = ctx.ports[m.gid];
    if (!port) return;
    fireAll(port.onMessage, [m.msg, port]);
  }

  function extPortClosed(m) {
    var ctx = extCtx[m.ext];
    if (!ctx) return;
    var port = ctx.ports[m.gid];
    if (!port) return;
    delete ctx.ports[m.gid];
    port.dead = true;
    fireAll(port.onDisconnect, [port]);
  }

  function fireAll(ev, args) {
    var fns = ev._fns.slice();
    for (var i = 0; i < fns.length; i++) {
      try {
        fns[i].apply(null, args);
      } catch (e) {}
    }
  }

  /// A `tabs.on*` event pushed from the browser process.
  function extTabEvent(m) {
    var ctx = extCtx[m.ext];
    if (!ctx || !ctx.tabs) return;
    var ev = ctx.tabs[m.ev];
    if (!ev) return;
    fireAll(ev, m.args || []);
  }

  function extActionClicked(m) {
    var api = extApiOf[m.ext];
    if (!api || !api.browserAction) return;
    fireAll(api.browserAction.onClicked, [m.tab || {}]);
  }

  // An `ext-inject` carrying the process NONCE is PRIVILEGED: it may
  // publish `browser`/`chrome` as real globals on this document, which
  // is what an extension page (background, popup, options) needs before
  // its own first statement runs. The nonce is the same secret every
  // reply is authenticated with, and only the browser process — which
  // generated the served document — knows it.
  //
  // Without it, `ext-inject` still runs its scripts in a closure, as it
  // always has. That distinction matters because `window[SLOT]` is a
  // non-enumerable but discoverable own property: a page can find it
  // and call it. Being able to run its OWN code in its OWN closure
  // costs a page nothing, but a `browser` object bound to an installed
  // extension's id would reach that extension's `storage.local`, so
  // that half is gated.
  // The nonce AUTHENTICATES an ext-inject; `priv` AUTHORIZES the
  // globals. Both are needed and they are not the same question.
  function extAuthentic(m) {
    return typeof m.tok === "string" && m.tok === NONCE;
  }

  function extPrivileged(m) {
    return m.priv === true && extAuthentic(m);
  }

  function extInject(m) {
    // EVERY ext-inject must carry the nonce, not just the privileged
    // one. The scripts this runs are handed `api` — a live `browser.*`
    // bound to `m.ext` — as their `browser`/`chrome`/`self` arguments,
    // so the closure isolates NOTHING from a caller who chose the
    // script text. `window[SLOT]` is a discoverable own property, so
    // before this check any page could post
    // `{op:"ext-inject",ext:"uBlock0@raymondhill.net",scripts:[...]}`
    // and read the user's whole tab list, navigate the active tab, or
    // rewrite that extension's storage.local. Only the browser process
    // knows the nonce, and it is on all three legitimate producers.
    if (!extAuthentic(m)) return;
    var extId = m.ext;
    if (m.dbg) extDebug = true;
    if (typeof m.uilang === "string" && m.uilang) extUiLanguage = m.uilang;
    if (m.css) {
      for (var i = 0; i < m.css.length; i++) {
        try {
          var style = document.createElement("style");
          style.textContent = m.css[i];
          (document.head || document.documentElement).appendChild(style);
        } catch (e) {}
      }
    }
    var privileged = extPrivileged(m);
    if (!m.scripts || !m.scripts.length) {
      // A background page with no scripts to run here, or css-only
      // content: still register the ctx so messages can be delivered.
      var api0 = extCtx[extId]
        ? extApiOf[extId]
        : makeBrowser(extId, m.base || "", m.manifest || {}, m.messages || null);
      if (privileged) publishGlobals(api0);
      return;
    }
    var api = extCtx[extId]
      ? extApiOf[extId]
      : makeBrowser(extId, m.base || "", m.manifest || {}, m.messages || null);
    if (privileged) publishGlobals(api);
    for (var j = 0; j < m.scripts.length; j++) {
      try {
        var fn = new Function("browser", "chrome", "self", m.scripts[j]);
        fn(api, api, api);
      } catch (e2) {
        try {
          send({ op: "ext-error", ext: extId, msg: String(e2 && e2.message || e2) });
        } catch (e3) {}
      }
    }
  }

  // `browser` and `chrome` as real globals, for a document that IS the
  // extension. An author script says `browser.runtime.getManifest()` at
  // top level and there is no closure to hand it one.
  function publishGlobals(api) {
    if (!api) return;
    try {
      if (!window.browser) window.browser = api;
    } catch (e) {}
    try {
      if (!window.chrome) window.chrome = api;
    } catch (e2) {}
  }

  // A runtime message routed to THIS frame's listeners (the background
  // receives a content script's sendMessage this way). A listener may
  // return a value, a Promise, or call the sendResponse callback; the
  // first defined response wins and is posted back under `gid`.
  function extDeliver(m) {
    var ctx = extCtx[m.ext];
    if (!ctx) {
      send({ op: "ext-reply", gid: m.gid, resp: null });
      return;
    }
    var fns = ctx.listeners._fns.slice();
    var answered = false;
    function respond(resp) {
      if (answered) return;
      answered = true;
      send({ op: "ext-reply", gid: m.gid, resp: resp === undefined ? null : resp });
    }
    var sender = m.sender || {};
    for (var i = 0; i < fns.length; i++) {
      var r;
      try {
        r = fns[i](m.msg, sender, respond);
      } catch (e) {
        continue;
      }
      if (r && typeof r.then === "function") {
        r.then(respond, function () {
          respond(null);
        });
        return;
      }
      if (r !== undefined && r !== true) {
        respond(r);
        return;
      }
      // `true` means the listener will call respond asynchronously; keep
      // waiting for it rather than answering now.
      if (r === true) return;
    }
    if (!answered) respond(null);
  }

  function extResult(m) {
    var fn = extPending[m.req];
    if (extDebug) {
      try {
        console.log("SKEXT result#" + m.req + " ok=" + m.ok + " pending=" + !!fn +
          " " + JSON.stringify(m.result).slice(0, 160));
      } catch (e) {}
    }
    if (!fn) return;
    delete extPending[m.req];
    fn(m.ok === false ? undefined : m.result);
  }

  function extChanged(m) {
    var ctx = extCtx[m.ext];
    if (!ctx) return;
    var fns = ctx.changed._fns.slice();
    for (var i = 0; i < fns.length; i++) {
      try {
        fns[i](m.changes || {}, m.area || "local");
      } catch (e) {}
    }
  }

  // -- command entry point ---------------------------------------------

  function handle(json, navgen) {
    if (typeof navgen === "number" && navgen > 0) NAVGEN = navgen;
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
        read(m.req, !!m.ids);
        break;
      case "pickoption":
        pickOption(m.req, m.arg || "", m.timeout || 4000);
        break;
      case "chosen":
        controlState(m.req, m.eid);
        break;
      case "eval":
        evaluate(m.req, String(m.code || ""), !!m.await, m.timeout || 10000);
        break;
      case "ext-inject":
        extInject(m);
        break;
      case "ext-message":
        extDeliver(m);
        break;
      case "ext-wreq":
        extWebRequest(m);
        break;
      case "ext-result":
        extResult(m);
        break;
      case "ext-changed":
        extChanged(m);
        break;
      case "ext-port-open":
        extPortOpen(m);
        break;
      case "ext-port-incoming":
        extPortIncoming(m);
        break;
      case "ext-port-recv":
        extPortRecv(m);
        break;
      case "ext-port-closed":
        extPortClosed(m);
        break;
      case "ext-tab-event":
        extTabEvent(m);
        break;
      case "ext-action-clicked":
        extActionClicked(m);
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
