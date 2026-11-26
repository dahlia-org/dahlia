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
  const transport = withElicitation(inner, "gateway", prompt, (url) => opened.push(url));
  const received: any[] = [];
  transport.onMessage((message: any) => received.push(message));
  return { inner, transport, opened, asked, received };
}

const urlError = (id: number, url = "https://example.com/approve?x=1") => ({
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
  assert.deepEqual(inner.sent, [call, call]);
  assert.deepEqual(received, []);
  inner.receive({ jsonrpc: "2.0", id: 3, result: { content: [] } });
  assert.deepEqual(received, [{ jsonrpc: "2.0", id: 3, result: { content: [] } }]);
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
    }, (url) => opened.push(url));
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
      }, (url) => opened.push(url));
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
  }, (url) => opened.push(url));
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
  }, (url) => opened.push(url));
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
