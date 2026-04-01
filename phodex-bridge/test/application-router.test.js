const test = require("node:test");
const assert = require("node:assert/strict");
const { createApplicationRouter } = require("../src/application-router");

test("application router properly delegates requests", async (t) => {
  await t.test("delegates to handshake handler and stops if handled", () => {
    let handshakeCalled = false;
    let handledCount = 0;

    const router = createApplicationRouter({
      handleBridgeManagedHandshakeMessage: (msg, opts) => {
        handshakeCalled = true;
        opts.sendResponse('{"ok":true}');
        return true;
      },
      handleBridgeManagedAccountRequest: () => {
        handledCount++;
        return false;
      },
      getHandshakeState: () => "cold",
      forwardedInitializeRequestIds: new Set(),
      defaultResponseSender: () => {},
      config: {},
      codex: { send: () => handledCount++ },
      voiceHandler: { handleVoiceRequest: () => false },
      notificationsHandler: { handleNotificationsRequest: () => false },
      desktopRefresher: { handleInbound: () => {} },
      rolloutLiveMirror: { observeInbound: () => {} },
      rememberForwardedRequestMethod: () => {},
      rememberThreadFromMessage: () => {},
      rememberAsyncResponseSender: () => {}
    });

    let sentMessage = null;
    router('{"method":"initialize"}', (msg) => { sentMessage = msg; });

    assert.equal(handshakeCalled, true);
    assert.equal(sentMessage, '{"ok":true}');
    assert.equal(handledCount, 0); // No other handlers should be called
  });

  await t.test("falls through to codex when no internal handlers match", () => {
    let codexSent = null;

    const router = createApplicationRouter({
      handleBridgeManagedHandshakeMessage: () => false,
      handleBridgeManagedAccountRequest: () => false,
      getHandshakeState: () => "warm",
      forwardedInitializeRequestIds: new Set(),
      defaultResponseSender: () => {},
      config: { codexBundleId: "com.test", codexAppPath: "/test" },
      codex: { send: (msg) => codexSent = msg },
      voiceHandler: { handleVoiceRequest: () => false },
      notificationsHandler: { handleNotificationsRequest: () => false },
      desktopRefresher: { handleInbound: () => {} },
      rolloutLiveMirror: { observeInbound: () => {} },
      rememberForwardedRequestMethod: () => {},
      rememberThreadFromMessage: () => {},
      rememberAsyncResponseSender: () => {}
    });

    const rawMessage = '{"method":"unknown/method"}';
    router(rawMessage);

    assert.equal(codexSent, rawMessage);
  });
});