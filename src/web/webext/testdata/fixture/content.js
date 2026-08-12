// Content script for the smoke fixture. Runs at document_end. Proves
// three things the smoke stage asserts by watching document.title:
//   1. injection + DOM mutation (a marker element, and the title),
//   2. runtime.sendMessage to the background and its reply,
//   3. storage.local persisted across a helper restart.
document.title = "cs-start";
(async function () {
  var marker = document.createElement("div");
  marker.id = "webext-marker";
  marker.textContent = "injected";
  (document.body || document.documentElement).appendChild(marker);

  // If a previous run persisted a value, report it and stop: this is the
  // post-restart assertion.
  var got = await browser.storage.local.get("saved");
  if (got && got.saved) {
    document.title = "stored:" + got.saved;
    return;
  }

  // First run: talk to the background, then persist a value for the next.
  //
  // RETRY rather than assume the background is up. The background page
  // is a separate hidden browser and its listener is registered when
  // ITS document finishes loading, so "has the listener appeared yet"
  // is a race the content script cannot otherwise win. The stage used
  // to cover it with a fixed 1500ms sleep, which held on an idle
  // machine and failed on a loaded one as "reply:null:hello" — i18n and
  // storage working, only the reply missing. A bounded retry makes the
  // assertion mean "the message got through", not "it got through
  // within a wall-clock budget".
  var resp = null;
  for (var i = 0; i < 40 && !(resp && resp.n); i++) {
    if (i) await new Promise(function (r) { setTimeout(r, 250); });
    resp = await browser.runtime.sendMessage({ q: "ping" });
  }
  await browser.storage.local.set({ saved: "v1" });
  document.title = "reply:" + (resp && resp.n) + ":" + browser.i18n.getMessage("greeting");
})();
