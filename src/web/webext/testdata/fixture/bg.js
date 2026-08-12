// Background script for the smoke fixture. Hosted in the hidden
// off-screen page. Replies to the content script's runtime.sendMessage.
browser.runtime.onMessage.addListener(function (msg, sender, sendResponse) {
  if (msg && msg.q === "ping") {
    sendResponse({ n: 42, pong: true, from: sender && sender.id });
    return true; // response already delivered synchronously
  }
});
