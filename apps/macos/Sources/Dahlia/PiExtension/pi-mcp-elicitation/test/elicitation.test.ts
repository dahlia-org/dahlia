import assert from "node:assert/strict";
import { test } from "node:test";
import { pageURL, URL_ELICITATION_REQUIRED, withElicitation } from "../elicitation.ts";
import { browserCommand } from "../browser.ts";

/** A transport whose server side the test plays. */
function fakeTransport() {
  const sent: any[] = [];
  let deliver: (message: any) => void = () => {};
  const closeListeners = new Set<() => void>();
  const disconnect = () => { for (const listener of closeListeners) listener(); };
  return {
    sent,
    receive: (message: any) => deliver(message),
    start: async () => {},
    send: async (message: any) => void sent.push(message),
    close: async () => disconnect(),
    disconnect,
    onMessage: (listener: any) => { deliver = listener; return () => {}; },
    onError: () => () => {},
    onClose: (listener: () => void) => { closeListeners.add(listener); return () => closeListeners.delete(listener); },
  };
}

const settle = () => new Promise((resolve) => setImmediate(resolve));

function setup(answers: { open: boolean; finished?: boolean }) {
  const inner = fakeTransport();
  const opened: string[] = [];
  const asked: string[] = [];
  const prompt = {
    open: async (_server: string, url: URL) => { asked.push(`open ${url.href}`); return answers.open; },
    finished: async () => { asked.push("finished"); return answers.finished ?? false; },
  };
  const transport = withElicitation(inner, "gateway", prompt, (url) => { opened.push(url); });
  const received: any[] = [];
  transport.onMessage((message: any) => received.push(message));
  return { inner, transport, opened, asked, received };
}

const urlError = (id: string | number, url = "https://example.com/approve?x=1") => ({
  jsonrpc: "2.0", id,
  error: { code: URL_ELICITATION_REQUIRED, message: "approval required", data: { elicitations: [{ mode: "url", elicitationId: "e1", url, message: "Approve" }] } },
});

test("declares URL mode elicitation in initialize", async () => {
  const { inner, transport } = setup({ open: false });
  await transport.send({ jsonrpc: "2.0", id: 0, method: "initialize", params: { capabilities: { roots: {} } } });
  assert.deepEqual(inner.sent[0].params.capabilities, { roots: {}, elicitation: { url: {} } });
});

test("opens the page only after consent and accepts", async () => {
  const { inner, opened } = setup({ open: true });
  inner.receive({ jsonrpc: "2.0", id: 7, method: "elicitation/create", params: { mode: "url", url: "https://example.com/sign-in", message: "Sign in" } });
  await settle();
  assert.deepEqual(opened, ["https://example.com/sign-in"]);
  assert.deepEqual(inner.sent, [{ jsonrpc: "2.0", id: 7, result: { action: "accept" } }]);
});

test("declines without opening when the user refuses", async () => {
  const { inner, opened } = setup({ open: false });
  inner.receive({ jsonrpc: "2.0", id: 7, method: "elicitation/create", params: { mode: "url", url: "https://example.com/sign-in" } });
  await settle();
  assert.deepEqual(opened, []);
  assert.deepEqual(inner.sent[0].result, { action: "decline" });
});

test("rejects form mode and non-web URLs without asking", async () => {
  const { inner, asked } = setup({ open: true });
  inner.receive({ jsonrpc: "2.0", id: 1, method: "elicitation/create", params: { message: "Name?", requestedSchema: {} } });
  inner.receive({ jsonrpc: "2.0", id: 2, method: "elicitation/create", params: { mode: "url", url: "file:///etc/passwd" } });
  await settle();
  assert.deepEqual(asked, []);
  assert.deepEqual(inner.sent.map((message) => message.error?.code), [-32602, -32602]);
  assert.equal(pageURL("http://127.0.0.1:8080/cb")?.host, "127.0.0.1:8080");
  assert.equal(pageURL("http://example.com"), undefined);
});

test("sends a request again after the user finished on the page", async () => {
  const { inner, transport, opened, asked, received } = setup({ open: true, finished: true });
  const call = { jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "send", _meta: { progressToken: 3 } } };
  await transport.send(call);
  inner.receive(urlError(3));
  await settle();
  assert.deepEqual(opened, ["https://example.com/approve?x=1"]);
  assert.deepEqual(asked, ["open https://example.com/approve?x=1", "finished"]);
  assert.equal(inner.sent.length, 2);
  const retry = inner.sent[1];
  assert.notEqual(retry.id, call.id);
  assert.deepEqual({ ...retry, id: call.id }, call);
  assert.deepEqual(received, []);
  inner.receive({ jsonrpc: "2.0", id: retry.id, result: { content: [] } });
  assert.deepEqual(received, [{ jsonrpc: "2.0", id: 3, result: { content: [] } }]);
});

test("repeated retries correlate responses, concurrent calls, and cancellation", async () => {
  const { inner, transport, received } = setup({ open: true, finished: true });
  await transport.send({ jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "first" } });
  await transport.send({ jsonrpc: "2.0", id: 4, method: "tools/call", params: { name: "other" } });
  inner.receive(urlError(3));
  await settle();
  const firstRetry = inner.sent[2].id;
  inner.receive(urlError(firstRetry));
  await settle();
  const secondRetry = inner.sent[3].id;
  assert.equal(new Set([3, firstRetry, secondRetry]).size, 3);
  inner.receive({ jsonrpc: "2.0", id: 3, result: { stale: true } });
  assert.deepEqual(received, []);
  inner.receive({ jsonrpc: "2.0", id: 4, result: { other: true } });
  assert.deepEqual(received, [{ jsonrpc: "2.0", id: 4, result: { other: true } }]);
  await transport.send({ jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: 3, reason: "stopped" } });
  assert.deepEqual(inner.sent[4].params, { requestId: secondRetry, reason: "stopped" });
  await transport.close();
});

test("a failed retry delivers its error to the original caller", async () => {
  const { inner, transport, received } = setup({ open: true, finished: true });
  await transport.send({ jsonrpc: "2.0", id: "original", method: "tools/call" });
  inner.receive(urlError("original"));
  await settle();
  const error = { code: -32603, message: "failed after authorization" };
  inner.receive({ jsonrpc: "2.0", id: inner.sent[1].id, error });
  assert.deepEqual(received, [{ jsonrpc: "2.0", id: "original", error }]);
});

test("send-signal abort before the client's cancellation notification cancels the current wire ID once", async () => {
  const { inner, transport, received } = setup({ open: true, finished: true });
  const controller = new AbortController();
  await transport.send({ jsonrpc: "2.0", id: 3, method: "tools/call" }, { signal: controller.signal });
  inner.receive(urlError(3));
  await settle();
  const wireID = inner.sent[1].id;
  controller.abort();
  await transport.send({ jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: 3 } });
  assert.deepEqual(inner.sent.slice(2), [{ jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: wireID } }]);
  assert.deepEqual(received, []);
  await transport.close();
});

test("retry send failure preserves the original error only for a live caller", async () => {
  for (const cancelled of [false, true]) {
    const inner = fakeTransport();
    const received: any[] = [];
    let failSend: (error: Error) => void = () => {};
    const send = inner.send;
    inner.send = (message) => {
      if (message.method === "tools/call" && message.id !== 3) {
        return new Promise<void>((_resolve, reject) => { failSend = reject; });
      }
      return send(message);
    };
    const transport = withElicitation(inner, "gateway", { open: async () => true, finished: async () => true }, () => {});
    transport.onMessage((message) => received.push(message));
    await transport.send({ jsonrpc: "2.0", id: 3, method: "tools/call" });
    const error = urlError(3);
    inner.receive(error);
    await settle();
    if (cancelled) await transport.send({ jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: 3 } });
    failSend(new Error("transport failed"));
    await settle();
    assert.deepEqual(received, cancelled ? [] : [error]);
    await transport.close();
  }
});

test("cancelling during browser launch prevents accept and retry follow-up", async () => {
  for (const direct of [true, false]) {
    const inner = fakeTransport();
    const received: any[] = [];
    let finishLaunch: () => void = () => {};
    let finished = false;
    const transport = withElicitation(inner, "gateway", {
      open: async () => true,
      finished: async () => { finished = true; return true; },
    }, () => new Promise<void>((resolve) => { finishLaunch = resolve; }));
    transport.onMessage((message) => received.push(message));
    if (direct) inner.receive({ jsonrpc: "2.0", id: 7, method: "elicitation/create", params: { mode: "url", url: "https://example.com" } });
    else {
      await transport.send({ jsonrpc: "2.0", id: 7, method: "tools/call" });
      inner.receive(urlError(7));
    }
    await settle();
    if (direct) inner.receive({ jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: 7 } });
    else await transport.send({ jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: 7 } });
    finishLaunch();
    await settle();
    assert.equal(finished, false);
    assert.deepEqual(received, []);
    assert.equal(inner.sent.filter((message) => message.result || message.method === "tools/call").length, direct ? 0 : 1);
    await transport.close();
  }
});

test("launcher failure cancels direct elicitation and preserves the URL-required error", async () => {
  for (const launch of [() => { throw new Error("missing opener"); }, async () => { throw new Error("opener failed"); }]) {
    const inner = fakeTransport();
    const received: any[] = [];
    let finished = false;
    const transport = withElicitation(inner, "gateway", {
      open: async () => true,
      finished: async () => { finished = true; return true; },
    }, launch);
    transport.onMessage((message) => received.push(message));
    inner.receive({ jsonrpc: "2.0", id: 7, method: "elicitation/create", params: { mode: "url", url: "https://example.com" } });
    await settle();
    assert.deepEqual(inner.sent[0].result, { action: "cancel" });
    await transport.send({ jsonrpc: "2.0", id: 3, method: "tools/call" });
    const error = urlError(3);
    inner.receive(error);
    await settle();
    assert.deepEqual(received, [error]);
    assert.equal(finished, false);
    assert.equal(inner.sent.length, 2);
    await transport.close();
  }
});

test("passes the error on when the user does not continue", async () => {
  for (const answers of [{ open: false }, { open: true, finished: false }]) {
    const { inner, transport, received } = setup(answers);
    await transport.send({ jsonrpc: "2.0", id: 4, method: "tools/call", params: {} });
    inner.receive(urlError(4));
    await settle();
    assert.equal(inner.sent.length, 1);
    assert.equal(received[0].error.code, URL_ELICITATION_REQUIRED);
  }
});

test("passes an error with a non-web URL on without asking", async () => {
  const { inner, transport, asked, received } = setup({ open: true, finished: true });
  await transport.send({ jsonrpc: "2.0", id: 5, method: "tools/call", params: {} });
  inner.receive(urlError(5, "javascript:alert(1)"));
  await settle();
  assert.deepEqual(asked, []);
  assert.equal(received[0].error.code, URL_ELICITATION_REQUIRED);
});

test("close and disconnect stop progress and invalidate old consent", async (context) => {
  context.mock.timers.enable({ apis: ["setInterval"] });
  for (const remote of [false, true]) {
    const inner = fakeTransport();
    const opened: string[] = [];
    let answer: (value: boolean) => void = () => {};
    const transport = withElicitation(inner, "gateway", {
      open: () => new Promise((resolve) => { answer = resolve; }),
      finished: async () => true,
    }, (url) => { opened.push(url); });
    const received: any[] = [];
    transport.onMessage((message) => received.push(message));
    await transport.send({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { _meta: { progressToken: 1 } } });
    inner.receive({ jsonrpc: "2.0", id: 7, method: "elicitation/create", params: { mode: "url", url: "https://example.com" } });
    context.mock.timers.tick(15_000);
    assert.equal(received.length, 1);
    if (remote) inner.disconnect(); else await transport.close();
    context.mock.timers.tick(15_000);
    answer(true);
    await settle();
    assert.equal(received.length, 1);
    assert.deepEqual(opened, []);
    assert.equal(inner.sent.length, 1);
  }
});

test("protocol cancellation and AbortSignal invalidate both retry prompts", async () => {
  for (const cancelWithSignal of [false, true]) {
    for (const cancelAt of ["open", "finished"]) {
      const inner = fakeTransport();
      const opened: string[] = [];
      let answer: (value: boolean) => void = () => {};
      let promptSignal: AbortSignal | undefined;
      const pending = (signal?: AbortSignal) => {
        promptSignal = signal;
        return new Promise<boolean>((resolve) => { answer = resolve; });
      };
      const transport = withElicitation(inner, "gateway", {
        open: async (_server, _url, _message, signal) => cancelAt === "open" ? pending(signal) : true,
        finished: (_server, _url, signal) => pending(signal),
      }, (url) => { opened.push(url); });
      const controller = new AbortController();
      await transport.send({ jsonrpc: "2.0", id: 2, method: "tools/call", params: {} }, cancelWithSignal ? { signal: controller.signal } : undefined);
      inner.receive(urlError(2));
      await settle();
      if (cancelWithSignal) controller.abort();
      else await transport.send({ jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: 2 } });
      assert.equal(promptSignal?.aborted, true);
      answer(true);
      await settle();
      assert.equal(inner.sent.filter((message) => message.method === "tools/call").length, 1);
      assert.equal(opened.length, cancelAt === "open" ? 0 : 1);
      await transport.close();
    }
  }
});

test("server cancellation invalidates its confirmation without closing the connection", async (context) => {
  context.mock.timers.enable({ apis: ["setInterval"] });
  const inner = fakeTransport();
  const opened: string[] = [];
  const received: any[] = [];
  let answer: (value: boolean) => void = () => {};
  let signal: AbortSignal | undefined;
  const transport = withElicitation(inner, "gateway", {
    open: async (_server, url, _message, cancellation) => {
      if (url.pathname === "/next") return true;
      signal = cancellation;
      return new Promise((resolve) => { answer = resolve; });
    },
    finished: async () => true,
  }, (url) => { opened.push(url); });
  transport.onMessage((message) => received.push(message));
  // Client and server IDs may be equal; cancelling the server's request must not cancel the client call.
  await transport.send({ jsonrpc: "2.0", id: 7, method: "tools/call", params: { _meta: { progressToken: 7 } } });
  inner.receive({ jsonrpc: "2.0", id: 7, method: "elicitation/create", params: { mode: "url", url: "https://example.com/old" } });
  context.mock.timers.tick(15_000);
  assert.equal(received.length, 1);
  inner.receive({ jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: 7 } });
  assert.equal(signal?.aborted, true);
  answer(true);
  await settle();
  context.mock.timers.tick(15_000);
  assert.equal(received.length, 1);
  assert.deepEqual(opened, []);
  assert.equal(inner.sent.length, 1);
  inner.receive({ jsonrpc: "2.0", id: 8, method: "elicitation/create", params: { mode: "url", url: "https://example.com/next" } });
  await settle();
  assert.deepEqual(opened, ["https://example.com/next"]);
  assert.deepEqual(inner.sent[1], { jsonrpc: "2.0", id: 8, result: { action: "accept" } });
  inner.receive({ jsonrpc: "2.0", id: 7, result: {} });
  assert.deepEqual(received[1], { jsonrpc: "2.0", id: 7, result: {} });
  await transport.close();
});

test("cancellation queued between consent resolution and browser opening wins", async () => {
  const inner = fakeTransport();
  const opened: string[] = [];
  const transport = withElicitation(inner, "gateway", {
    open: async () => {
      queueMicrotask(() => queueMicrotask(() => queueMicrotask(() => inner.receive({
        jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: 7 },
      }))));
      return true;
    },
    finished: async () => true,
  }, (url) => { opened.push(url); });
  inner.receive({ jsonrpc: "2.0", id: 7, method: "elicitation/create", params: { mode: "url", url: "https://example.com" } });
  await settle();
  assert.deepEqual(opened, []);
  assert.deepEqual(inner.sent, []);
  await transport.close();
});

test("malformed elicitation errors stay errors without prompting", async () => {
  const { inner, transport, received, asked } = setup({ open: true, finished: true });
  await transport.send({ jsonrpc: "2.0", id: 3, method: "tools/call" });
  const response = urlError(3);
  (response.error.data as any).elicitations = {};
  inner.receive(response);
  await settle();
  assert.deepEqual(asked, []);
  assert.deepEqual(received, [response]);
});

test("browser commands pass the complete URL as one argument without a shell", () => {
  const url = "https://example.com/approve?one=1&two=2";
  assert.deepEqual(browserCommand(url, "darwin"), ["open", [url]]);
  assert.deepEqual(browserCommand(url, "win32"), ["rundll32.exe", ["url.dll,FileProtocolHandler", url]]);
  assert.deepEqual(browserCommand(url, "linux"), ["xdg-open", [url]]);
});
