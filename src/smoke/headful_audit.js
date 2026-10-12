// The headful audit: what public bot detectors (fingerprint-scan.com,
// pixelscan.net, bot.sannysoft.com, CreepJS, BotD, devtools-detector)
// read, re-implemented here as our own concise probes. One script runs in
// three realms: the page (every check), the /frame iframe and a dedicated
// Worker (the context facts the page compares against its own). Every
// check reports {id, family, value, detail}: `value` is compared against
// stock Chromium by src/smoke/headful_audit.zig and must therefore be
// normalised (no versions, no raw timings); `detail` is for humans only.
// The page POSTs {phase, checks} to /result; nothing here is installed on
// window beyond the page's own bookkeeping.
'use strict';

const IS_WORKER = typeof WorkerGlobalScope !== 'undefined' && self instanceof WorkerGlobalScope;
const IS_FRAME = !IS_WORKER && window.top !== window;

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

function glInfo(canvas) {
  let gl = null;
  try { gl = canvas.getContext('webgl'); } catch (e) { return { vendor: 'error', renderer: String(e.name) }; }
  if (!gl) return { vendor: 'none', renderer: 'none' };
  const d = gl.getExtension('WEBGL_debug_renderer_info');
  return {
    vendor: d ? gl.getParameter(d.UNMASKED_VENDOR_WEBGL) : gl.getParameter(gl.VENDOR),
    renderer: d ? gl.getParameter(d.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER),
  };
}

// The facts a detector reads in every realm and compares across them.
async function contextFacts() {
  const n = navigator;
  const ro = Intl.DateTimeFormat().resolvedOptions();
  const f = {
    ua: n.userAgent, languages: (n.languages || []).join(','), hardwareConcurrency: n.hardwareConcurrency,
    deviceMemory: n.deviceMemory, platform: n.platform, webdriver: n.webdriver,
    timezone: ro.timeZone, locale: ro.locale,
  };
  if (n.userAgentData) {
    f.brands = n.userAgentData.brands.map(b => b.brand + '/' + b.version).join(',');
    f.mobile = n.userAgentData.mobile;
    f.uaPlatform = n.userAgentData.platform;
    try {
      const h = await n.userAgentData.getHighEntropyValues(['architecture', 'bitness', 'platformVersion', 'fullVersionList']);
      f.architecture = h.architecture; f.bitness = h.bitness; f.platformVersion = h.platformVersion;
      f.fullVersionList = (h.fullVersionList || []).map(b => b.brand + '/' + b.version).join(',');
    } catch (e) { f.highEntropy = 'error:' + e.name; }
  }
  try {
    const gi = glInfo(new OffscreenCanvas(4, 4));
    f.glVendor = gi.vendor; f.glRenderer = gi.renderer;
  } catch (e) { f.glVendor = 'error:' + e.name; }
  return f;
}

if (IS_WORKER) {
  contextFacts().then(f => postMessage({ auditWorker: f }), e => postMessage({ auditWorker: { error: String(e) } }));
} else if (IS_FRAME) {
  contextFacts().then(f => parent.postMessage({ auditFrame: f }, '*'));
} else {
  window.addEventListener('DOMContentLoaded', () => { runAudit(); });
}

function diffFacts(a, b) {
  const keys = Array.from(new Set(Object.keys(a).concat(Object.keys(b)))).sort();
  return keys.filter(k => JSON.stringify(a[k]) !== JSON.stringify(b[k]));
}

const NATIVE_RE = /^function [^(]*\(\) \{\s*\[native code\]\s*\}$/;

async function runAudit() {
  const checks = [];
  const add = (id, family, value, detail) => checks.push(detail === undefined ? { id, family, value } : { id, family, value, detail });
  const safe = async (id, family, fn) => {
    try { await fn(); } catch (e) { add(id, family, 'error:' + (e && e.name), String(e && e.message)); }
  };
  const status = document.getElementById('status');
  const step = (s) => { if (status) status.textContent = s; };
  const main = await contextFacts();

  // ---- automation markers -------------------------------------------
  await safe('auto.webdriver_value', 'automation', () => add('auto.webdriver_value', 'automation', navigator.webdriver));
  await safe('auto.webdriver_where', 'automation', () => {
    const own = Object.getOwnPropertyDescriptor(navigator, 'webdriver');
    const d = Object.getOwnPropertyDescriptor(Navigator.prototype, 'webdriver');
    const where = own ? 'own' : d ? 'proto' : ('webdriver' in navigator ? 'elsewhere' : 'absent');
    const shape = d ? `get:${typeof d.get} set:${typeof d.set} enum:${d.enumerable} conf:${d.configurable}` : '';
    add('auto.webdriver_where', 'automation', where + ' ' + shape);
  });
  await safe('auto.webdriver_write', 'automation', () => {
    // Sloppy-mode assignment, as the detectors do it: a getter-only
    // accessor ignores the write, an own data property takes it.
    const after = Function('try{navigator.webdriver=true}catch(e){return "threw"}return navigator.webdriver')();
    add('auto.webdriver_write', 'automation', after);
  });
  await safe('auto.globals', 'automation', () => {
    const names = ['_Selenium_IDE_Recorder', 'callSelenium', '_selenium', '__webdriver_script_fn', '__driver_evaluate',
      '__webdriver_evaluate', '__selenium_evaluate', '__fxdriver_evaluate', '__driver_unwrapped', '__webdriver_unwrapped',
      '__selenium_unwrapped', '__fxdriver_unwrapped', '__webdriver_script_func', '__lastWatirAlert', '__lastWatirConfirm',
      '__lastWatirPrompt', 'domAutomation', 'domAutomationController', 'callPhantom', '_phantom', 'phantom', '__nightmare',
      '__phantomas', 'Buffer', 'emit', 'spawn', '__playwright__binding__', '__pwInitScripts', '__playwright_evaluation_script__',
      '__puppeteer_evaluation_script__', '_WEBDRIVER_ELEM_CACHE', 'ChromeDriverw', 'awesomium', 'webdriver', '__webdriverFunc',
      'cdc_adoQpoasnfa76pfcZLmcfl_Array', 'cdc_adoQpoasnfa76pfcZLmcfl_Promise', 'cdc_adoQpoasnfa76pfcZLmcfl_Symbol'];
    add('auto.globals', 'automation', names.filter(k => k in window).sort());
  });
  await safe('auto.window_keys', 'automation', () => {
    const re = /^(\$?cdc_|\$wdc_|__webdriver|__selenium|__driver|__fxdriver|__playwright|__pw|__puppeteer|_phantom|callPhantom|__nightmare|domAutomation)|_(Array|Promise|Symbol|JSON|Object|Proxy)$/i;
    const own = Object.getOwnPropertyNames(window).concat(Object.getOwnPropertySymbols(window).map(String));
    add('auto.window_keys', 'automation', own.filter(k => re.test(k)).sort());
  });
  await safe('auto.document_keys', 'automation', () => {
    const re = /\$cdc_|\$wdc_|__webdriver|__selenium|__driver|__fxdriver|webdriver|selenium|driver/i;
    const keys = Object.getOwnPropertyNames(document).filter(k => re.test(k));
    const attrs = Array.from(document.documentElement.attributes).map(a => a.name).filter(k => re.test(k));
    add('auto.document_keys', 'automation', keys.concat(attrs.map(a => '@' + a)).sort());
  });
  await safe('auto.chrome_shape', 'automation', () => {
    const c = window.chrome;
    add('auto.chrome_shape', 'automation', typeof c + ':' + (c ? Object.keys(c).sort().join(',') : ''));
  });
  await safe('auto.chrome_functions', 'automation', () => {
    const c = window.chrome || {};
    const lt = typeof c.loadTimes === 'function' ? Object.keys(c.loadTimes()).sort().join(',') : 'absent';
    const csi = typeof c.csi === 'function' ? Object.keys(c.csi()).sort().join(',') : 'absent';
    const app = c.app ? `isInstalled:${c.app.isInstalled}` : 'absent';
    add('auto.chrome_functions', 'automation', `loadTimes(${lt}) csi(${csi}) app(${app}) runtime:${typeof c.runtime}`);
  });
  await safe('auto.eval_len', 'automation', () => add('auto.eval_len', 'automation', eval.toString().length));
  await safe('auto.error_stack', 'automation', () => {
    const lines = new Error('x').stack.split('\n');
    const shape = lines[0] === 'Error: x' && /^ {4}at /.test(lines[1] || '') ? 'v8' : 'other';
    add('auto.error_stack', 'automation', shape + ' limit:' + Error.stackTraceLimit, lines.slice(0, 3).join(' | '));
  });
  await safe('auto.cdp_stack_getter', 'automation', () => {
    // A CDP Runtime session serialises console arguments eagerly, so a
    // `stack` getter on a logged Error runs; with no session it never does.
    let hits = 0;
    const e = new Error('probe');
    Object.defineProperty(e, 'stack', { configurable: false, enumerable: false, get() { hits++; return ''; } });
    console.debug(e);
    add('auto.cdp_stack_getter', 'automation', hits > 0);
  });

  // ---- native-code / lie checks --------------------------------------
  step('lies');
  const scanTargets = () => {
    const out = [];
    const protoScan = (label, proto) => {
      if (!proto) return;
      for (const k of Object.getOwnPropertyNames(proto)) {
        if (k === 'constructor') continue;
        const d = Object.getOwnPropertyDescriptor(proto, k);
        if (d.get) out.push([label + '.' + k + '(get)', d.get, 'get ' + k]);
        if (d.set) out.push([label + '.' + k + '(set)', d.set, 'set ' + k]);
        if (typeof d.value === 'function') out.push([label + '.' + k, d.value, k]);
      }
    };
    const G = (n) => self[n] && self[n].prototype;
    for (const n of ['Navigator', 'Screen', 'NavigatorUAData', 'HTMLCanvasElement', 'CanvasRenderingContext2D',
      'OffscreenCanvasRenderingContext2D', 'WebGLRenderingContext', 'WebGL2RenderingContext', 'Permissions',
      'MediaDevices', 'AudioBuffer', 'AnalyserNode', 'BaseAudioContext', 'Element', 'HTMLElement', 'Document',
      'Date', 'Function', 'Keyboard', 'Plugin', 'PluginArray', 'MimeTypeArray', 'SpeechSynthesis', 'StorageManager',
      'ScreenOrientation', 'VisualViewport', 'Performance']) protoScan(n, G(n));
    protoScan('Intl.DateTimeFormat', Intl.DateTimeFormat.prototype);
    protoScan('Notification(static)', self.Notification);
    for (const k of ['getOwnPropertyDescriptor', 'getOwnPropertyDescriptors', 'defineProperty', 'getPrototypeOf',
      'getOwnPropertyNames', 'keys']) out.push(['Object.' + k, Object[k], k]);
    for (const k of ['matchMedia', 'setTimeout', 'requestAnimationFrame', 'fetch', 'getComputedStyle', 'atob',
      'postMessage', 'alert', 'open']) out.push(['window.' + k, window[k], k]);
    for (const k of ['outerWidth', 'outerHeight', 'innerWidth', 'innerHeight', 'screenX', 'screenY',
      'devicePixelRatio', 'screen', 'navigator', 'chrome']) {
      const d = Object.getOwnPropertyDescriptor(window, k);
      if (d && d.get) out.push(['window.' + k + '(get)', d.get, 'get ' + k]);
    }
    return out;
  };
  let targets = [];
  await safe('lie.native_scan', 'lies', () => {
    targets = scanTargets();
    const ts = Function.prototype.toString;
    const bad = [];
    for (const [label, fn, name] of targets) {
      let s;
      try { s = ts.call(fn); } catch (e) { bad.push(label + ':threw'); continue; }
      if (!NATIVE_RE.test(s)) bad.push(label);
      else if (!s.startsWith('function ' + name + '()') && typeof name === 'string' && !/^Symbol/.test(name) && fn.name === name) bad.push(label + ':name');
    }
    add('lie.native_scan', 'lies', bad.sort(), targets.length + ' functions scanned');
  });
  await safe('lie.native_scan_cross_realm', 'lies', async () => {
    const ifr = document.createElement('iframe');
    ifr.style.display = 'none';
    document.body.appendChild(ifr);
    const ts = ifr.contentWindow.Function.prototype.toString;
    const bad = targets.filter(([label, fn]) => { try { return !NATIVE_RE.test(ts.call(fn)); } catch (e) { return true; } }).map(t => t[0]);
    ifr.remove();
    add('lie.native_scan_cross_realm', 'lies', bad.sort());
  });
  await safe('lie.tostring_self', 'lies', () => {
    const ts = Function.prototype.toString;
    add('lie.tostring_self', 'lies', [ts.call(ts), ts.toString(), String(ts), ts.call(Function.prototype.call)].join(' / '));
  });
  await safe('lie.tostring_proxy', 'lies', () => {
    const p = new Proxy(function probe() {}, {});
    let thrown = 'none';
    try { Function.prototype.toString.call(Object.create(Function.prototype)); } catch (e) { thrown = e.constructor.name; }
    add('lie.tostring_proxy', 'lies', Function.prototype.toString.call(p) + ' / non-function:' + thrown);
  });
  await safe('lie.getter_shape', 'lies', () => {
    const bad = [];
    const probe = (label, proto, k) => {
      const g = Object.getOwnPropertyDescriptor(proto, k).get;
      if ('prototype' in g) bad.push(label + ':prototype');
      if (Object.getOwnPropertyNames(g).sort().join(',') !== 'length,name') bad.push(label + ':own=' + Object.getOwnPropertyNames(g).join(','));
      if (g.length !== 0) bad.push(label + ':length');
      try { new g(); bad.push(label + ':constructible'); } catch (e) { if (!(e instanceof TypeError)) bad.push(label + ':new-' + e.name); }
      try { g.call(Object.create(proto)); bad.push(label + ':no-illegal-invocation'); } catch (e) { if (!(e instanceof TypeError)) bad.push(label + ':call-' + e.name); }
    };
    for (const k of ['userAgent', 'webdriver', 'platform', 'languages', 'hardwareConcurrency', 'deviceMemory', 'plugins', 'vendor'])
      probe('navigator.' + k, Navigator.prototype, k);
    for (const k of ['width', 'height', 'availWidth', 'colorDepth']) probe('screen.' + k, Screen.prototype, k);
    add('lie.getter_shape', 'lies', bad.sort());
  });
  await safe('lie.own_props', 'lies', () => {
    const v = ['navigator', 'screen', 'history'].map(n => n + ':' + Object.getOwnPropertyNames(window[n]).length);
    add('lie.own_props', 'lies', v.join(' '), Object.getOwnPropertyNames(navigator).join(','));
  });
  await safe('lie.proto_chain', 'lies', () => {
    const chain = (o) => { const out = []; let p = Object.getPrototypeOf(o); while (p) { out.push(p.constructor && p.constructor.name); p = Object.getPrototypeOf(p); } return out.join('>'); };
    add('lie.proto_chain', 'lies', ['navigator=' + chain(navigator), 'screen=' + chain(screen),
      'tag=' + Object.prototype.toString.call(navigator) + Object.prototype.toString.call(screen)].join(' '));
  });

  // ---- context consistency ------------------------------------------
  step('contexts');
  const factKeys = Object.keys(main).sort().join(',');
  await safe('ctx.worker', 'context', async () => {
    const w = new Worker('/audit.js');
    const f = await new Promise((res, rej) => { w.onmessage = (e) => res(e.data.auditWorker); w.onerror = (e) => rej(new Error('worker error ' + e.message)); setTimeout(() => rej(new Error('worker timeout')), 10000); });
    w.terminate();
    add('ctx.worker', 'context', diffFacts(main, f), { main, worker: f });
  });
  await safe('ctx.iframe', 'context', async () => {
    const ifr = document.createElement('iframe');
    ifr.src = '/frame';
    ifr.style.cssText = 'width:10px;height:10px;border:0';
    const got = new Promise((res, rej) => { addEventListener('message', function on(e) { if (e.data && e.data.auditFrame) { removeEventListener('message', on); res(e.data.auditFrame); } }); setTimeout(() => rej(new Error('iframe timeout')), 10000); });
    document.body.appendChild(ifr);
    const f = await got;
    add('ctx.iframe', 'context', diffFacts(main, f), { frame: f });
  });
  let hdrs = null;
  await safe('ctx.headers', 'context', async () => {
    hdrs = await (await fetch('/headers', { cache: 'no-store' })).json();
    add('ctx.headers', 'context', 'fetched', hdrs);
  });
  const hget = (list, name) => { if (!list) return null; const e = list.find(([k]) => k.toLowerCase() === name); return e ? e[1] : null; };
  await safe('ctx.hdr_ua', 'context', () => {
    const bad = ['doc', 'frame', 'worker'].filter(k => hget(hdrs[k], 'user-agent') !== navigator.userAgent);
    add('ctx.hdr_ua', 'context', bad);
  });
  await safe('ctx.hdr_lang', 'context', () => {
    const want = navigator.languages.map((l, i) => i === 0 ? l : `${l};q=${(1 - i / 10).toFixed(1)}`).join(',');
    add('ctx.hdr_lang', 'context', hget(hdrs.doc, 'accept-language') === want, hget(hdrs.doc, 'accept-language') + ' vs ' + want);
  });
  await safe('ctx.hdr_client_hints', 'context', () => {
    const bad = [];
    const brands = navigator.userAgentData.brands.map(b => `"${b.brand}";v="${b.version}"`).join(', ');
    for (const k of ['doc', 'frame', 'worker']) {
      if (hget(hdrs[k], 'sec-ch-ua') !== brands) bad.push(k + ':sec-ch-ua');
      if (hget(hdrs[k], 'sec-ch-ua-mobile') !== (navigator.userAgentData.mobile ? '?1' : '?0')) bad.push(k + ':mobile');
      if (hget(hdrs[k], 'sec-ch-ua-platform') !== `"${navigator.userAgentData.platform}"`) bad.push(k + ':platform');
    }
    add('ctx.hdr_client_hints', 'context', bad);
  });
  const names = (k) => (hdrs[k] || []).map(([n]) => n.toLowerCase()).join(',');
  await safe('ctx.hdr_order_doc', 'context', () => add('ctx.hdr_order_doc', 'context', names('doc')));
  await safe('ctx.hdr_order_frame', 'context', () => add('ctx.hdr_order_frame', 'context', names('frame')));
  await safe('ctx.hdr_order_worker', 'context', () => add('ctx.hdr_order_worker', 'context', names('worker')));
  await safe('ctx.hdr_order_script', 'context', () => add('ctx.hdr_order_script', 'context', names('script')));
  await safe('ctx.hdr_order_fetch', 'context', () => add('ctx.hdr_order_fetch', 'context', names('fetch')));
  await safe('ctx.hdr_fetch_meta_doc', 'context', () => {
    const v = ['sec-fetch-site', 'sec-fetch-mode', 'sec-fetch-user', 'sec-fetch-dest', 'upgrade-insecure-requests', 'accept', 'accept-encoding']
      .map(k => k + '=' + hget(hdrs.doc, k)).join(' ');
    add('ctx.hdr_fetch_meta_doc', 'context', v);
  });

  // ---- window / screen geometry --------------------------------------
  step('geometry');
  const geo = { screen: [screen.width, screen.height, screen.availWidth, screen.availHeight, screen.availLeft, screen.availTop],
    inner: [innerWidth, innerHeight], outer: [outerWidth, outerHeight], pos: [screenX, screenY], dpr: devicePixelRatio };
  add('geo.screen_is_viewport', 'geometry', screen.width === innerWidth && screen.height === innerHeight, geo);
  add('geo.outer_exceeds_inner', 'geometry', outerHeight > innerHeight && outerWidth >= innerWidth, geo);
  add('geo.window_fits_screen', 'geometry', outerWidth <= screen.width && outerHeight <= screen.height && innerWidth <= screen.availWidth);
  add('geo.avail_within_screen', 'geometry', screen.availWidth <= screen.width && screen.availHeight <= screen.height);
  add('geo.window_at_origin', 'geometry', screenX === 0 && screenY === 0, geo.pos);
  add('geo.dpr', 'geometry', devicePixelRatio);
  add('geo.color_depth', 'geometry', screen.colorDepth + '/' + screen.pixelDepth);
  await safe('geo.orientation', 'geometry', () => add('geo.orientation', 'geometry', screen.orientation.type + ':' + screen.orientation.angle));
  add('geo.screen_extended', 'geometry', String(screen.isExtended));
  await safe('geo.visual_viewport', 'geometry', () => add('geo.visual_viewport', 'geometry',
    `scale:${visualViewport.scale} matches_inner:${Math.round(visualViewport.width) <= innerWidth && Math.round(visualViewport.height) <= innerHeight}`));

  // ---- media queries --------------------------------------------------
  const mq = (feature, values) => { const hit = values.filter(v => matchMedia(`(${feature}: ${v})`).matches); return hit.length ? hit.join('|') : 'none-matched'; };
  for (const [f, vals] of [
    ['pointer', ['fine', 'coarse', 'none']], ['hover', ['hover', 'none']], ['any-pointer', ['fine', 'coarse', 'none']],
    ['any-hover', ['hover', 'none']], ['color-gamut', ['rec2020', 'p3', 'srgb']], ['dynamic-range', ['high', 'standard']],
    ['video-dynamic-range', ['high', 'standard']], ['prefers-color-scheme', ['dark', 'light']],
    ['prefers-reduced-motion', ['reduce', 'no-preference']], ['prefers-contrast', ['more', 'less', 'custom', 'no-preference']],
    ['prefers-reduced-transparency', ['reduce', 'no-preference']], ['prefers-reduced-data', ['reduce', 'no-preference']],
    ['forced-colors', ['active', 'none']], ['inverted-colors', ['inverted', 'none']], ['display-mode', ['fullscreen', 'standalone', 'minimal-ui', 'browser']],
    ['scripting', ['enabled', 'initial-only', 'none']], ['update', ['fast', 'slow', 'none']], ['overflow-block', ['scroll', 'paged', 'none']],
  ]) add('mq.' + f, 'media-queries', mq(f, vals));
  add('mq.monochrome', 'media-queries', matchMedia('(monochrome: 0)').matches);

  // ---- focus, visibility, frame pacing -------------------------------
  step('focus');
  add('focus.has_focus', 'focus', document.hasFocus());
  add('focus.visibility', 'focus', document.visibilityState + ' hidden:' + document.hidden);
  await safe('focus.raf_interval', 'focus', async () => {
    const t = [];
    await new Promise(res => { const f = (ts) => { t.push(ts); if (t.length < 41) requestAnimationFrame(f); else res(); }; requestAnimationFrame(f); setTimeout(res, 5000); });
    const d = t.slice(1).map((x, i) => x - t[i]).sort((a, b) => a - b);
    const med = d.length ? d[d.length >> 1] : -1;
    const bucket = med < 0 ? 'no-frames' : med < 12 ? 'faster-than-80hz' : med < 20 ? '50-80hz' : med < 40 ? '25-50hz' : 'below-25hz';
    add('focus.raf_interval', 'focus', bucket, { median_ms: med, frames: t.length });
  });

  // ---- devtools-detector equivalents ---------------------------------
  step('devtools');
  await safe('dt.table_vs_log', 'devtools', () => {
    const o = {}; for (let g = 0; g < 500; g++) o['' + g] = '' + g;
    const a = []; for (let i = 0; i < 50; i++) a.push(o);
    const per = (f) => { const s = performance.now(); for (let i = 0; i < 20; i++) f(a); return (performance.now() - s) / 20; };
    for (let w = 0; w < 3; w++) { console.table(a); console.log(a); }
    let tb = 1e9, lg = 1e9;
    for (let r = 0; r < 5; r++) { tb = Math.min(tb, per(x => console.table(x))); lg = Math.min(lg, per(x => console.log(x))); }
    console.clear();
    const ratio = tb / Math.max(lg, 0.005);
    add('dt.table_vs_log', 'devtools', ratio < 4 ? 'closed' : 'open', { table_ms: tb, log_ms: lg, ratio });
  });
  await safe('dt.debugger_stall', 'devtools', () => {
    let worst = 1e9;
    for (let r = 0; r < 5; r++) { const s = performance.now(); Function('debugger')(); worst = Math.min(worst, performance.now() - s); }
    add('dt.debugger_stall', 'devtools', worst < 50 ? 'none' : 'stalls', { min_ms: worst });
  });
  await safe('dt.lazy_getters', 'devtools', () => {
    // Each trick runs code only when an inspector formats the argument.
    const fired = [];
    const el = document.createElement('div');
    Object.defineProperty(el, 'id', { get() { fired.push('element-id'); return 'x'; } });
    console.log(el);
    const re = /x/; re.toString = () => { fired.push('regexp-tostring'); return ''; };
    console.log(re);
    const d = new Date(); d.toString = () => { fired.push('date-tostring'); return ''; };
    console.log(d);
    const fn = function () {}; fn.toString = () => { fired.push('function-tostring'); return ''; };
    console.log(fn);
    window.devtoolsFormatters = [{ header() { fired.push('custom-formatter'); return null; }, hasBody() { return false; } }];
    console.log({ probe: 1 });
    delete window.devtoolsFormatters;
    console.clear();
    add('dt.lazy_getters', 'devtools', Array.from(new Set(fired)).sort());
  });

  // ---- permissions ----------------------------------------------------
  step('permissions');
  await safe('perm.notifications', 'permissions', async () => {
    const st = (await navigator.permissions.query({ name: 'notifications' })).state;
    add('perm.notifications', 'permissions', (self.Notification ? Notification.permission : 'no-Notification') + '/' + st);
  });
  await safe('perm.states', 'permissions', async () => {
    const out = [];
    for (const d of [{ name: 'geolocation' }, { name: 'camera' }, { name: 'microphone' }, { name: 'clipboard-read' },
      { name: 'clipboard-write' }, { name: 'persistent-storage' }, { name: 'midi' }, { name: 'midi', sysex: true },
      { name: 'push', userVisibleOnly: true }, { name: 'background-sync' }, { name: 'accelerometer' }, { name: 'gyroscope' },
      { name: 'magnetometer' }, { name: 'screen-wake-lock' }, { name: 'local-fonts' }, { name: 'window-management' },
      { name: 'storage-access' }, { name: 'idle-detection' }, { name: 'payment-handler' }]) {
      const label = d.name + (d.sysex ? '+sysex' : '');
      try { out.push(label + ':' + (await navigator.permissions.query(d)).state); } catch (e) { out.push(label + ':' + e.name); }
    }
    add('perm.states', 'permissions', out);
  });

  // ---- graphics and media --------------------------------------------
  step('graphics');
  await safe('gfx.webgl', 'graphics', () => {
    const c = document.createElement('canvas');
    const gi = glInfo(c);
    add('gfx.webgl', 'graphics', gi.vendor + ' / ' + gi.renderer);
  });
  await safe('gfx.webgl2', 'graphics', () => add('gfx.webgl2', 'graphics', !!document.createElement('canvas').getContext('webgl2')));
  await safe('gfx.webgl_params', 'graphics', () => {
    const gl = document.createElement('canvas').getContext('webgl');
    if (!gl) { add('gfx.webgl_params', 'graphics', 'no-context'); return; }
    const p = ['MAX_TEXTURE_SIZE', 'MAX_RENDERBUFFER_SIZE', 'MAX_VIEWPORT_DIMS', 'MAX_VERTEX_ATTRIBS', 'ALIASED_LINE_WIDTH_RANGE', 'SHADING_LANGUAGE_VERSION', 'VERSION']
      .map(k => k + '=' + String(gl.getParameter(gl[k])));
    add('gfx.webgl_params', 'graphics', p.join(' ') + ' ext:' + (gl.getSupportedExtensions() || []).length);
  });
  await safe('gfx.webgpu', 'graphics', async () => {
    let adapter = null;
    if (navigator.gpu) { try { adapter = await Promise.race([navigator.gpu.requestAdapter(), sleep(5000).then(() => 'timeout')]); } catch (e) { adapter = 'error'; } }
    add('gfx.webgpu', 'graphics', `api:${!!navigator.gpu} adapter:${adapter === 'timeout' || adapter === 'error' ? adapter : !!adapter}`);
  });
  const draw = () => {
    const c = document.createElement('canvas'); c.width = 240; c.height = 60;
    const x = c.getContext('2d');
    x.textBaseline = 'top'; x.font = '16px Arial'; x.fillStyle = '#f60'; x.fillRect(100, 1, 62, 20);
    x.fillStyle = '#069'; x.fillText('Cwm fjordbank glyphs vext quiz \u{1F603}', 2, 15);
    x.fillStyle = 'rgba(102,204,0,0.7)'; x.beginPath(); x.arc(50, 30, 20, 0, Math.PI * 2); x.fill();
    return c;
  };
  const hash = (s) => { let h = 2166136261; for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619); } return (h >>> 0).toString(16); };
  await safe('gfx.canvas_stable', 'graphics', () => {
    const a = draw().toDataURL(), b = draw().toDataURL();
    add('gfx.canvas_stable', 'graphics', a === b, { hash: hash(a) });
  });
  await safe('gfx.canvas_hash', 'graphics', () => add('gfx.canvas_hash', 'graphics', hash(draw().toDataURL())));
  await safe('gfx.canvas_pixels', 'graphics', () => {
    const d = draw().getContext('2d').getImageData(0, 0, 240, 60).data;
    let lit = 0; for (let i = 3; i < d.length; i += 4) if (d[i]) lit++;
    add('gfx.canvas_pixels', 'graphics', lit > 500 ? 'drawn' : 'blank', { lit });
  });
  await safe('audio.context', 'media', async () => {
    const ac = new AudioContext();
    const v = { state: ac.state, sampleRate: ac.sampleRate, baseLatency: ac.baseLatency, outputLatency: ac.outputLatency, maxChannels: ac.destination.maxChannelCount };
    await ac.close();
    add('audio.state', 'media', v.state, 'before any user gesture');
    add('audio.sample_rate', 'media', v.sampleRate);
    add('audio.channels', 'media', v.maxChannels);
    add('audio.context', 'media', 'ok', v);
  });
  await safe('audio.offline', 'media', async () => {
    const render = async () => {
      const oc = new OfflineAudioContext(1, 5000, 44100);
      const o = oc.createOscillator(); o.type = 'triangle'; o.frequency.value = 10000;
      const cmp = oc.createDynamicsCompressor();
      o.connect(cmp); cmp.connect(oc.destination); o.start(0);
      const buf = await oc.startRendering();
      const d = buf.getChannelData(0); let s = 0; for (let i = 4500; i < 5000; i++) s += Math.abs(d[i]);
      return s;
    };
    const a = await render(), b = await render();
    add('audio.offline_stable', 'media', a === b, { sum: a });
    add('audio.offline_sum', 'media', a.toFixed(6));
  });
  await safe('media.voices', 'media', async () => {
    let n = speechSynthesis.getVoices().length;
    if (!n) { await Promise.race([new Promise(r => speechSynthesis.addEventListener('voiceschanged', r, { once: true })), sleep(1500)]); n = speechSynthesis.getVoices().length; }
    add('media.voices', 'media', n);
  });
  await safe('media.devices', 'media', async () => {
    const ds = await navigator.mediaDevices.enumerateDevices();
    const kinds = {}; for (const d of ds) kinds[d.kind] = (kinds[d.kind] || 0) + 1;
    add('media.devices', 'media', ['audioinput', 'audiooutput', 'videoinput'].map(k => k + ':' + (kinds[k] || 0)).join(' '),
      ds.map(d => d.kind + ':' + (d.label ? 'labelled' : 'unlabelled') + ':' + (d.deviceId ? 'id' : 'noid')));
  });
  const codecs = (list) => {
    const v = document.createElement('video');
    return list.map(([label, t]) => label + ':' + (v.canPlayType(t) || 'no') + (self.MediaSource ? '/mse:' + MediaSource.isTypeSupported(t) : '')).join(' ');
  };
  await safe('media.codecs_open', 'media', () => add('media.codecs_open', 'media', codecs([
    ['webm-vp8', 'video/webm; codecs="vp8, vorbis"'], ['webm-vp9', 'video/webm; codecs="vp9, opus"'], ['webm-av1', 'video/webm; codecs="av01.0.05M.08"'],
    ['ogg-theora', 'video/ogg; codecs="theora"'], ['ogg-opus', 'audio/ogg; codecs="opus"'], ['flac', 'audio/flac'], ['wav', 'audio/wav; codecs="1"'],
    ['mp4-av1', 'video/mp4; codecs="av01.0.05M.08"'], ['mp4-vp9', 'video/mp4; codecs="vp09.00.10.08"'], ['mp4-flac', 'audio/mp4; codecs="flac"']])));
  await safe('media.codecs_proprietary', 'media', () => add('media.codecs_proprietary', 'media', codecs([
    ['mp4-h264', 'video/mp4; codecs="avc1.42E01E, mp4a.40.2"'], ['mp4-aac', 'audio/mp4; codecs="mp4a.40.2"'], ['mp3', 'audio/mpeg'],
    ['mp4-hevc', 'video/mp4; codecs="hvc1.1.6.L93.B0"']])));
  // Codec-neutral (WebM/VP9) so a build without H.264 does not read as
  // "no key system"; the codecs have checks of their own.
  const keySystem = async (ks) => {
    try {
      await navigator.requestMediaKeySystemAccess(ks, [{ initDataTypes: ['webm'], videoCapabilities: [{ contentType: 'video/webm; codecs="vp9"' }] }]);
      return 'yes';
    } catch (e) { return e.name; }
  };
  await safe('media.clearkey', 'media', async () => add('media.clearkey', 'media', await keySystem('org.w3.clearkey')));
  await safe('media.widevine', 'media', async () => add('media.widevine', 'media', await keySystem('com.widevine.alpha')));
  await safe('kbd.layout_map', 'input-devices', async () => {
    const m = await navigator.keyboard.getLayoutMap();
    add('kbd.layout_map', 'input-devices', m.size > 0 ? 'populated' : 'empty', { size: m.size, KeyA: m.get('KeyA') || null });
  });

  // ---- navigator surface ---------------------------------------------
  step('navigator');
  add('nav.plugins', 'navigator', `${navigator.plugins.length}/${navigator.mimeTypes.length} pdfViewerEnabled:${navigator.pdfViewerEnabled}`,
    Array.from(navigator.plugins).map(p => p.name));
  add('nav.plugin_names', 'navigator', Array.from(navigator.plugins).map(p => p.name + '|' + p.filename).sort().join(';'));
  add('nav.static', 'navigator', [`vendor:${navigator.vendor}`, `productSub:${navigator.productSub}`, `product:${navigator.product}`,
    `appName:${navigator.appName}`, `cookieEnabled:${navigator.cookieEnabled}`, `doNotTrack:${navigator.doNotTrack}`,
    `maxTouchPoints:${navigator.maxTouchPoints}`, `onLine:${navigator.onLine}`, `appVersionMatchesUA:${'Mozilla/' + navigator.appVersion === navigator.userAgent}`].join(' '));
  add('nav.language_consistent', 'navigator', navigator.language === navigator.languages[0] && Intl.DateTimeFormat().resolvedOptions().locale === navigator.language);
  add('nav.languages', 'navigator', navigator.languages.join(','));
  add('nav.hardware', 'navigator', `cores:${navigator.hardwareConcurrency} memory:${navigator.deviceMemory}`);
  add('nav.platform', 'navigator', navigator.platform);
  await safe('nav.connection', 'navigator', () => add('nav.connection', 'navigator',
    navigator.connection ? `${navigator.connection.effectiveType} rtt:${navigator.connection.rtt} saveData:${navigator.connection.saveData}` : 'absent'));
  add('nav.features', 'navigator', ['bluetooth', 'usb', 'hid', 'serial', 'xr', 'gpu', 'keyboard', 'clipboard', 'credentials', 'mediaSession',
    'wakeLock', 'locks', 'storage', 'presentation', 'scheduling', 'ink', 'virtualKeyboard', 'windowControlsOverlay', 'login',
    'userActivation', 'getBattery', 'getGamepads', 'requestMIDIAccess', 'share', 'canShare', 'contacts', 'managed', 'serviceWorker',
    'geolocation', 'mediaCapabilities', 'permissions', 'webkitTemporaryStorage', 'deprecatedRunAdAuctionEnforcesKAnonymity',
    'protectedAudience', 'joinAdInterestGroup', 'setAppBadge', 'getInstalledRelatedApps', 'registerProtocolHandler', 'vibrate']
    .filter(k => !(k in navigator)).map(k => 'missing:' + k));
  add('win.features', 'navigator', ['speechSynthesis', 'webkitSpeechRecognition', 'SpeechRecognition', 'PaymentRequest', 'Notification',
    'IdleDetector', 'EyeDropper', 'showOpenFilePicker', 'showSaveFilePicker', 'showDirectoryPicker', 'documentPictureInPicture',
    'queryLocalFonts', 'getScreenDetails', 'launchQueue', 'BarcodeDetector', 'FaceDetector', 'TextDetector', 'Sanitizer',
    'SharedWorker', 'BroadcastChannel', 'PresentationRequest', 'MediaRecorder', 'RTCPeerConnection', 'PublicKeyCredential',
    'Scheduler', 'TrustedTypePolicy', 'CookieStore', 'ContactsManager', 'NavigatorManagedData', 'DeviceOrientationEvent',
    'TouchEvent', 'Translator', 'LanguageDetector', 'Summarizer', 'ai', 'crossOriginIsolated', 'SharedArrayBuffer', 'webkitRequestFileSystem']
    .map(k => k + ':' + (k in window)).filter(s => s.endsWith(':false')));
  await safe('nav.storage_quota', 'navigator', async () => {
    const e = await navigator.storage.estimate();
    const gb = e.quota / 1073741824;
    add('nav.storage_quota', 'navigator', gb >= 1 ? '>=1GiB' : '<1GiB', { quota: e.quota });
    add('nav.storage_persisted', 'navigator', await navigator.storage.persisted());
  });
  await safe('nav.battery', 'navigator', async () => {
    const b = await navigator.getBattery();
    add('nav.battery', 'navigator', `charging:${b.charging} level:${b.level}`);
  });
  add('intl.timezone', 'intl', Intl.DateTimeFormat().resolvedOptions().timeZone);
  await safe('intl.offset_consistent', 'intl', () => {
    const now = new Date();
    const tz = Intl.DateTimeFormat().resolvedOptions().timeZone;
    const p = Object.fromEntries(new Intl.DateTimeFormat('en-US', { timeZone: tz, hour12: false, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' })
      .formatToParts(now).map(x => [x.type, x.value]));
    const asUtc = Date.UTC(+p.year, +p.month - 1, +p.day, +p.hour % 24, +p.minute);
    const intlOff = Math.round((Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate(), now.getUTCHours(), now.getUTCMinutes()) - asUtc) / 60000);
    add('intl.offset_consistent', 'intl', intlOff === now.getTimezoneOffset(), { intl: intlOff, date: now.getTimezoneOffset() });
  });
  add('intl.locales', 'intl', [Intl.NumberFormat().resolvedOptions().locale, Intl.Collator().resolvedOptions().locale,
    new Intl.DateTimeFormat().resolvedOptions().calendar, Intl.NumberFormat().resolvedOptions().numberingSystem].join(' '));
  await safe('uach.brands', 'ua-client-hints', () => {
    const b = navigator.userAgentData.brands;
    const chromium = b.find(x => x.brand === 'Chromium');
    const grease = b.filter(x => /Not.A.Brand|Not\)A;Brand|Not A\(Brand|Not=A\?Brand|Not\?A_Brand|Not_A Brand/.test(x.brand) || /^Not/.test(x.brand));
    const others = b.filter(x => x !== chromium && !grease.includes(x)).map(x => x.brand).sort();
    add('uach.brands', 'ua-client-hints', `count:${b.length} chromium:${!!chromium} grease:${grease.length} others:${others.join(',') || 'none'} mobile:${navigator.userAgentData.mobile} platform:${navigator.userAgentData.platform}`,
      b.map(x => x.brand + '/' + x.version));
  });
  await safe('uach.ua_string', 'ua-client-hints', () => {
    const re = /^Mozilla\/5\.0 \(X11; Linux x86_64\) AppleWebKit\/537\.36 \(KHTML, like Gecko\) Chrome\/(\d+)\.0\.0\.0 Safari\/537\.36$/;
    const m = navigator.userAgent.match(re);
    const chromium = navigator.userAgentData.brands.find(x => x.brand === 'Chromium');
    add('uach.ua_string', 'ua-client-hints', `reduced-linux:${!!m} major-matches-brand:${!!(m && chromium && chromium.version === m[1])} headless-token:${/Headless/i.test(navigator.userAgent)}`,
      navigator.userAgent);
  });
  await safe('uach.high_entropy', 'ua-client-hints', async () => {
    const h = await navigator.userAgentData.getHighEntropyValues(['architecture', 'bitness', 'model', 'platformVersion', 'uaFullVersion', 'fullVersionList', 'wow64', 'formFactors']);
    const chromium = navigator.userAgentData.brands.find(x => x.brand === 'Chromium');
    const full = (h.fullVersionList || []).find(x => x.brand === 'Chromium');
    add('uach.high_entropy', 'ua-client-hints', [`arch:${h.architecture}`, `bitness:${h.bitness}`, `model:${JSON.stringify(h.model)}`,
      `platformVersion:${h.platformVersion ? 'set' : 'empty'}`, `wow64:${h.wow64}`, `formFactors:${(h.formFactors || []).join('+')}`,
      `full-matches-major:${!!(full && chromium && full.version.split('.')[0] === chromium.version)}`,
      `uaFullVersion-matches:${!!(full && h.uaFullVersion === full.version)}`].join(' '), h);
  });
  await safe('js.engine', 'javascript', () => {
    add('js.engine', 'javascript', [`wasm:${typeof WebAssembly}`, `simd:${WebAssembly.validate(new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0, 1, 5, 1, 96, 0, 1, 123, 3, 2, 1, 0, 10, 10, 1, 8, 0, 65, 0, 253, 15, 253, 98, 11]))}`,
      `isSecureContext:${isSecureContext}`, `crossOriginIsolated:${crossOriginIsolated}`, `memory:${typeof performance.memory}`].join(' '));
  });

  add('meta.fact_keys', 'meta', factKeys);
  document.title = 'audit:passive';
  step('passive done');
  await post({ phase: 'passive', checks });
}

async function post(body) {
  await fetch('/result', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });
}

// ---- input trust: every click on #probe is one round ------------------
if (!IS_WORKER && !IS_FRAME) {
  let log = [];
  let round = 0;
  // Only events AT the probe: a round is how the pointer reached and
  // pressed it, whatever it did elsewhere before.
  const rec = (e) => {
    if (!e.target || e.target.id !== 'probe') return;
    const r = { type: e.type, t: e.timeStamp, trusted: e.isTrusted };
    if (e.type === 'pointerdown') {
      r.props = `pointerType:${e.pointerType} primary:${e.isPrimary} pressure:${e.pressure} buttons:${e.buttons} width:${e.width} height:${e.height} detail:${e.detail}`;
      r.screenOffset = [e.screenX - e.clientX, e.screenY - e.clientY];
    }
    if (e.type === 'pointermove' && e.getCoalescedEvents) r.coalesced = e.getCoalescedEvents().length;
    if (e.type === 'click') r.props = `detail:${e.detail} button:${e.button} buttons:${e.buttons}`;
    log.push(r);
  };
  for (const t of ['pointerover', 'pointerenter', 'pointermove', 'pointerdown', 'pointerup', 'mouseover', 'mouseenter', 'mousemove',
    'mousedown', 'mouseup', 'click']) window.addEventListener(t, rec, { capture: true });
  window.addEventListener('click', async (e) => {
    if (!e.target || e.target.id !== 'probe') return;
    const events = log; log = [];
    round++;
    const checks = [];
    const add = (id, value, detail) => checks.push({ id, family: 'input', value, detail });
    // Pointer events plus the click, repeated moves folded: the shape a
    // detector compares, independent of how many samples the device sent.
    const seq = [];
    for (const ev of events) {
      if (!/^pointer|^click$/.test(ev.type)) continue;
      const name = ev.type.replace(/^pointer/, '');
      if (name === 'move' && seq.length && seq[seq.length - 1] === 'move') continue;
      seq.push(name);
    }
    const twinOk = events.filter(x => /^pointer(over|move|down|up)$/.test(x.type))
      .every(p => events.some(m => m.type === p.type.replace('pointer', 'mouse') && m.t === p.t));
    const down = events.find(x => x.type === 'pointerdown'), up = events.find(x => x.type === 'pointerup');
    const moves = events.filter(x => x.type === 'pointermove' && (!down || x.t <= down.t)).length;
    add('input.trusted', events.every(x => x.trusted), events.filter(x => !x.trusted).map(x => x.type));
    add('input.sequence', seq.join(','), events.map(x => x.type + '@' + x.t.toFixed(1)));
    add('input.mouse_compat', twinOk);
    add('input.has_focus', document.hasFocus());
    add('input.moves_before_down', moves === 0 ? '0' : moves === 1 ? '1' : moves < 5 ? '2-4' : '5+', { moves });
    add('input.hold', down && up ? (up.t - down.t >= 20 ? '>=20ms' : up.t > down.t ? '<20ms' : 'zero') : 'missing', down && up ? { ms: up.t - down.t } : null);
    add('input.timestamps_monotonic', events.every((x, i) => i === 0 || x.t >= events[i - 1].t));
    add('input.pointer_props', down ? down.props : 'no-pointerdown');
    add('input.click_props', (events.find(x => x.type === 'click') || {}).props || 'no-click');
    add('input.screen_offset', down ? JSON.stringify(down.screenOffset) : 'n/a');
    document.title = 'audit:input' + round;
    await post({ phase: 'input', round, checks });
  });
}
