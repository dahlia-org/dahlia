// Run pnpm dev:client and open /tests/browser/chat-routing.html. No backend is contacted.
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "../../src/client/App";
import { navigateDashboard } from "../../src/client/navigation";
import { encodeId } from "../../src/typeid";
import "../../src/client/styles.css";

Object.defineProperty(navigator, "language", { value: "en-US", configurable: true });

const workspaceId = encodeId("workspace", "01990ab0-0000-7000-8000-000000000001");
const idA = encodeId("aiThread", "01990ab0-0000-7000-8000-000000000010");
const idB = encodeId("aiThread", "01990ab0-0000-7000-8000-000000000011");
const missing = encodeId("aiThread", "01990ab0-0000-7000-8000-000000000099");
const pathA = `/chat/${idA}`;
const pathB = `/chat/${idB}`;
const date = "2026-09-20T00:00:00.000Z";
const threads = new Map([
  [idA, { id: idA, title: "Chat A", workspaceId, createdAt: date, updatedAt: date }],
  [idB, { id: idB, title: "Chat B", workspaceId, createdAt: date, updatedAt: date }],
]);
let creates = 0;
let sends = 0;
let failCreate = false;
let listStatus = 200;
let deferList = false;
const deferredLists: Array<() => void> = [];
let detailStatus = 200;
let deferDelete = false;
let deferredDelete: (() => void) | undefined;
let deferA = false;
let deferredA: (() => void) | undefined;
let stream: ReadableStreamDefaultController<Uint8Array> | undefined;
let streamSignal: AbortSignal | null | undefined;
const reads: string[] = [];
const detail = (id: string) => Response.json({ thread: threads.get(id), hasMore: false,
  messages: [{ id: `message-${id}`, role: "assistant", content: id === idA ? "Saved A" : "Saved B", createdAt: date }] });
const failure = (status: number) => Response.json({ error: "unavailable" }, { status });

globalThis.fetch = async (input, init) => {
  const url = new URL(typeof input === "string" ? input : input instanceof URL ? input : input.url, location.href);
  const path = url.pathname;
  const method = init?.method ?? (input instanceof Request ? input.method : "GET");
  if (path === "/api/v1/session") return Response.json({ user: { id: "user", name: "Tester" },
    capabilities: { admin: false, sessions: false, sharing: false, sync: true, ai: true } });
  if (path === "/api/v1/workspaces") return Response.json({ items: [{ workspaceId, name: "Workspace", encryption: "none" }], nextCursor: null });
  if (path.endsWith("/projects") || path.endsWith("/meetings")) return Response.json({ items: [], nextCursor: null });
  if (path === "/api/v1/chat/models") return Response.json({ items: [{ id: "model", displayName: "Model",
    defaultReasoningEffort: "medium", supportedReasoningEfforts: [{ effort: "medium", description: "Balanced" }] }] });
  if (path === "/api/v1/chat") {
    if (method === "POST") { creates++; return failCreate ? failure(503) : Response.json(threads.get(idA), { status: 201 }); }
    if (deferList) return new Promise<Response>((resolve) => {
      deferredLists.push(() => resolve(Response.json({ items: [threads.get(idA)], hasMore: true })));
    });
    return listStatus === 200 ? Response.json({ items: [...threads.values()], hasMore: false }) : failure(listStatus);
  }
  if (path === `/api/v1/chat/${idA}/messages`) {
    sends++;
    streamSignal = init?.signal;
    return new Response(new ReadableStream<Uint8Array>({ start(controller) {
      stream = controller;
      init?.signal?.addEventListener("abort", () => controller.error(new DOMException("Stopped", "AbortError")), { once: true });
    } }), { headers: { "content-type": "text/event-stream" } });
  }
  const match = path.match(/^\/api\/v1\/chat\/([^/]+)$/);
  if (match) {
    const id = match[1]!;
    if (method === "DELETE") {
      const remove = () => { threads.delete(id); return new Response(null, { status: 204 }); };
      if (deferDelete) return new Promise<Response>((resolve) => { deferredDelete = () => resolve(remove()); });
      return remove();
    }
    reads.push(id);
    if (!threads.has(id)) return failure(404);
    if (detailStatus !== 200) return failure(detailStatus);
    if (id === idA && deferA) return new Promise<Response>((resolve) => { deferredA = () => resolve(detail(id)); });
    return detail(id);
  }
  return failure(404);
};

const assert: (value: unknown, message: string) => asserts value = (value, message) => { if (!value) throw new Error(message); };
const until = async (test: () => unknown, label: string) => {
  const deadline = performance.now() + 5000;
  while (performance.now() < deadline) { if (test()) return; await new Promise((resolve) => setTimeout(resolve, 10)); }
  throw new Error(`Timed out: ${label}`);
};
const messages = () => [...document.querySelectorAll(".ai-message")].map((node) => node.textContent).join("|");
const ready = () => document.querySelector<HTMLTextAreaElement>(".ai-composer textarea:not(:disabled)");
const click = (selector: string) => {
  const element = document.querySelector<HTMLElement>(selector);
  assert(element, `Missing ${selector}`);
  element.click();
};
const submit = async (text: string) => {
  await until(ready, "composer");
  const input = ready()!;
  Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, "value")!.set!.call(input, text);
  input.dispatchEvent(new Event("input", { bubbles: true }));
  input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
};
let root = createRoot(document.getElementById("root")!);
const mount = () => root.render(<StrictMode><App /></StrictMode>);
const reload = () => { root.unmount(); root = createRoot(document.getElementById("root")!); mount(); };
const completeStream = () => {
  stream!.enqueue(new TextEncoder().encode('event: text\ndata: {"text":"Completed A"}\n\nevent: done\ndata: {}\n\n'));
  stream!.close();
};

async function run() {
  history.replaceState(null, "", "/chat");
  mount();
  await until(() => ready() && document.querySelector('[data-ai-picker="reasoning"]')?.getAttribute("data-value") === "medium", "new chat ready");
  assert(Number(creates) === 0 && Number(sends) === 0, "Opening new chat caused a mutation");
  failCreate = true;
  await submit("Keep this draft");
  await until(() => ready()?.value === "Keep this draft", "failed creation restores draft");
  assert(location.pathname === "/chat" && Number(sends) === 0, "Failed create changed URL or sent a message");
  failCreate = false;
  const historyLength = history.length;
  await submit("First question");
  await until(() => location.pathname === pathA && stream, "first-send URL");
  assert(history.length === historyLength, "First send added an extra history entry");
  assert(!streamSignal?.aborted && Number(sends) === 1, "URL adoption aborted or duplicated the stream");
  assert(reads.length === 0, "URL adoption reloaded the thread");
  completeStream();
  await until(() => messages().includes("Completed A"), "stream completes after URL change");
  assert(Number(sends) === 1, "First send was duplicated");
  await submit("Retry this generation");
  await until(() => Number(sends) === 2, "failed generation starts");
  stream!.enqueue(new TextEncoder().encode('event: error\ndata: {"code":"ai_generation_failed"}\n\n'));
  stream!.close();
  await until(() => ready()?.value === "Retry this generation", "failed generation recovers draft");
  assert(location.pathname === pathA && Number(creates) === 2, "Generation failure replaced or recreated the chat");
  const target = document.querySelector<HTMLAnchorElement>(`.ai-history-row a[href="${pathB}"]`);
  assert(target?.href.endsWith(pathB), "Thread selection is not a native deep link");
  click(`.ai-history-row a[href="${pathB}"]`);
  await until(() => location.pathname === pathB && messages() === "Saved B", "select B");
  history.back();
  await until(() => location.pathname === pathA && messages() === "Saved A", "back to A");
  history.forward();
  await until(() => location.pathname === pathB && messages() === "Saved B", "forward to B");
  assert(Number(sends) === 2, "History navigation resubmitted a message");
  reload();
  await until(() => messages() === "Saved B", "reload deep link");
  deferList = true;
  reload();
  await until(() => messages() === "Saved B" && deferredLists.length, "detail before first history page");
  assert(document.querySelector(`.ai-history-row.active a[href="${pathB}"]`), "Deep-linked active row missing before list");
  deferredLists.splice(0).forEach((resolve) => resolve());
  deferList = false;
  await until(() => document.querySelector(`.ai-history-row a[href="${pathA}"]`), "late first history page");
  assert(document.querySelector(`.ai-history-row.active a[href="${pathB}"]`), "Late first page removed the active deep link");
  listStatus = 503;
  reload();
  await until(() => messages() === "Saved B", "detail loads despite history list failure");
  assert(ready(), "List failure disabled an existing thread");
  listStatus = 200;
  navigateDashboard(`/chat/${missing}`);
  await until(() => document.body.textContent?.includes("Chat not found."), "missing thread");
  assert(!ready() && location.pathname.endsWith(missing), "Missing thread became a new chat");
  const readCount = reads.length;
  navigateDashboard("/chat/invalid");
  await until(() => location.pathname === "/chat/invalid" && document.body.textContent?.includes("Chat not found."), "invalid ID");
  assert(reads.length === readCount, "Invalid ID was sent to API");
  detailStatus = 403;
  navigateDashboard(pathB);
  await until(() => document.body.textContent?.includes("Chat not found."), "forbidden thread");
  detailStatus = 503;
  navigateDashboard(pathA);
  await until(() => document.body.textContent?.includes("Could not load this chat."), "transient error");
  detailStatus = 200;
  click(".ai-start button");
  await until(() => messages() === "Saved A", "detail retry");
  navigateDashboard(pathB);
  await until(() => messages() === "Saved B", "B before race");
  deferA = true;
  navigateDashboard(pathA);
  await until(() => deferredA, "delayed A");
  assert(!messages().includes("Saved B"), "Old messages leaked into loading view");
  navigateDashboard(pathB);
  await until(() => messages() === "Saved B", "B wins race");
  deferredA!();
  deferA = false;
  await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
  assert(messages() === "Saved B", "Late A replaced B");
  navigateDashboard(pathA);
  await until(() => messages() === "Saved A", "A before streaming navigation");
  await submit("Stream then leave");
  await until(() => Number(sends) === 3, "second stream");
  click(`.ai-history-row a[href="${pathB}"]`);
  await until(() => messages() === "Saved B", "leave streaming A");
  assert(streamSignal?.aborted, "Leaving a chat kept its receive stream alive");
  click(".ai-history-row.active .ai-history-delete");
  await until(() => document.querySelector('[role="dialog"], [role="alertdialog"]'), "delete dialog");
  const confirm = [...document.querySelectorAll<HTMLButtonElement>('[role="dialog"] button, [role="alertdialog"] button')]
    .find((button) => button.textContent === "Delete chat");
  assert(confirm, "Missing delete confirmation");
  confirm.click();
  await until(() => location.pathname === "/chat" && ready() && !threads.has(idB), "delete current chat");
  assert(messages() === "", "Deleted chat remains visible");
  listStatus = 503;
  reload();
  await until(() => document.body.textContent?.includes("Could not load chat history."), "initial history failure");
  assert(!ready(), "Unknown persistence silently enabled temporary chat");
  listStatus = 200;
  click(".ai-error button");
  await until(ready, "history retry restores new chat");
  navigateDashboard("/dashboard/settings");
  await until(() => !document.querySelector(".ai-chat"), "leave chat before deletion race");
  navigateDashboard(pathA);
  await until(() => messages() === "Saved A", "A before delayed deletion");
  deferDelete = true;
  click(".ai-history-row.active .ai-history-delete");
  await until(() => document.querySelector("[data-confirm]"), "delayed delete dialog");
  click("[data-confirm]");
  await until(() => deferredDelete, "pending deletion");
  history.back();
  await until(() => location.pathname === "/dashboard/settings" && !document.querySelector(".ai-chat"), "leave during deletion");
  deferredDelete!();
  await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
  assert(String(location.pathname) === "/dashboard/settings", "Late deletion redirected after leaving chat");
  assert(!threads.has(idA), "Leaving chat prevented confirmed deletion");
  document.body.dataset.testResult = "passed";
  document.getElementById("result")!.textContent = "PASS: creation/generation failure, URL adoption, uninterrupted stream, native links, Back/Forward, reload, late first-page merge, list failure, missing/forbidden/invalid IDs, retry, stale results, navigation abort, deletion, history readiness recovery, deletion after navigation";
}
void run().catch((error: unknown) => { document.body.dataset.testResult = "failed"; document.getElementById("result")!.textContent = `FAIL: ${String(error)}`; });
