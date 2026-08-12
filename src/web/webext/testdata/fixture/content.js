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
  var resp = await browser.runtime.sendMessage({ q: "ping" });
  await browser.storage.local.set({ saved: "v1" });
  document.title = "reply:" + (resp && resp.n) + ":" + browser.i18n.getMessage("greeting");
})();
