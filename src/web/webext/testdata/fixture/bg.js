// Background script for the smoke fixture. Hosted in the hidden
// off-screen page. Replies to the content script's runtime.sendMessage.
var capabilityReady = (async function () {
  var source = await (await fetch(browser.runtime.getURL("__sketerm-extapi.js"))).text();
  var found = source.match(/,cap:"([0-9a-f]{32})"/);
  if (!found) throw new Error("extension capability missing from bootstrap");
  var previous = await browser.storage.local.get("lastCapability");
  await browser.storage.local.set({ lastCapability: found[1] });
  return !previous.lastCapability || previous.lastCapability !== found[1];
})();

browser.runtime.onMessage.addListener(async function (msg, sender) {
  if (msg && msg.q === "ping") {
    return { n: 42, pong: true, from: sender && sender.id, rotated: await capabilityReady };
  }
});
