// Run pnpm dev:client and open /tests/browser/chat-routing.html. No backend is contacted.
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "../../src/client/App";
import { dashboardNavigationEvent, navigateDashboard } from "../../src/client/navigation";
import { encodeId } from "../../src/typeid";
import "../../src/client/styles.css";

const initialQuery = location.search;
const previewMode = new URLSearchParams(location.search).has("preview");
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
  messages: [{ id: `message-${id}`, role: "assistant", content: id === idA ? "**Saved A**" : "**Saved B**", createdAt: date }] });
const failure = (status: number) => Response.json({ error: "unavailable" }, { status });

const draftResponse = (content: string) => Response.json({ status: "completed", output: [{ type: "message", content: [{ type: "output_text", text: JSON.stringify({ content }) }] }] });
let draftCalls = 0;
let draftInput: { question: string; answer: string; draft: string } | undefined;
let failDraft = false;
let deferDraft = false;
let finishDraft: (() => void) | undefined;
let draftSignal: AbortSignal | undefined;
let savedContent: string | undefined;
globalThis.fetch = async (input, init) => {
  const url = new URL(typeof input === "string" ? input : input instanceof URL ? input : input.url, location.href);
  const path = url.pathname;
  const method = init?.method ?? (input instanceof Request ? input.method : "GET");
  if (path === "/api/v1/session") return Response.json({ user: { id: "user", name: "Tester" },
    capabilities: { admin: true, sessions: false, sharing: false, sync: true, ai: true } });
  if (path === "/api/v1/workspaces") return Response.json({ items: [{ workspaceId, name: "Workspace", encryption: "none" }], nextCursor: null });
  if (path.endsWith("/projects") || path.endsWith("/meetings")) return Response.json({ items: [], nextCursor: null });
  if (path === "/api/v1/responses") {
    draftCalls++; const body = await (input instanceof Request ? input.clone() : new Request(url, init)).json<{ model: string; input: string; store: boolean }>();
    draftInput = JSON.parse(body.input) as typeof draftInput;
    if (body.model !== "model" || body.store !== false) throw new Error("Invalid draft request");
    if (deferDraft) {
      draftSignal = input instanceof Request ? input.signal : init?.signal ?? undefined;
      return new Promise<Response>(resolve => { finishDraft = () => resolve(draftResponse("Late draft")); });
    }
    return failDraft ? failure(502) : draftResponse("Generated shared note");
  }
  if (path.endsWith("/memory/notes") && method === "POST") { savedContent = (await (input instanceof Request ? input.clone() : new Request(url, init)).json<{ content: string }>()).content; return Response.json({ saved: true }); }
  if (path.endsWith("/memory/analysis/status")) return Response.json({ enabled: true, status: "ready", errorCode: null, skippedCount: 0, skippedSources: [] });
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
const messages = () => [...document.querySelectorAll(".ai-message")].map((node) => (node.querySelector(".chat-markdown") ?? node).textContent).join("|");
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
  stream!.enqueue(new TextEncoder().encode('event: text\ndata: {"text":"**Completed A**"}\n\nevent: done\ndata: {}\n\n'));
  stream!.close();
};

async function run() {
  history.replaceState(null, "", "/chat");
  mount();
  await until(() => ready() && document.querySelector('[data-ai-picker="reasoning"]')?.getAttribute("data-value") === "medium", "new chat ready");
  assert(document.querySelector(".sidebar-scroll .ai-history"), "Chat history is not in the sidebar");
  assert(document.querySelector(".ai-history h2")?.textContent === "Chats", "Chat history heading is missing");
  const newChatButton = document.querySelector<HTMLAnchorElement>(".ai-history-heading .ai-history-new");
  assert(newChatButton?.getAttribute("aria-label") === "New chat" && newChatButton.textContent === "", "New chat must be an accessible icon beside the heading");
  assert(!document.querySelector(".workspace-switcher, .workspace-navigation"), "Workspace navigation remains visible on chat");
  assert(document.querySelector(".server-navigation"), "Server settings navigation disappeared on chat");
  assert(!document.querySelector('.sidebar a[href="/memory"]'), "Memory remains in the sidebar");
  const historyLink = document.querySelector<HTMLAnchorElement>(`.ai-history-row a[href="${pathA}"]`)!;
  assert(!document.querySelector(".ai-history-row time"), "Chat history still shows an inline date");
  assert(historyLink.closest(".ai-history-row")!.getBoundingClientRect().height === 32, "Chat history must be one compact row");
  const historyRows = document.querySelectorAll(".ai-history-row");
  assert(historyRows[1]!.getBoundingClientRect().top - historyRows[0]!.getBoundingClientRect().bottom === 1, "Chat history rows must have a 1px gap");
  historyLink.focus();
  await until(() => document.getElementById(historyLink.getAttribute("aria-describedby") ?? ""), "chat preview on focus");
  const preview = document.getElementById(historyLink.getAttribute("aria-describedby")!)!;
  assert(preview.textContent?.includes("Chat A") && preview.querySelector("time")?.dateTime === date, "Chat preview is missing title or update time");
  if (previewMode) return;
  historyLink.blur();
  await until(() => !document.getElementById(preview.id), "chat preview closed");
  const options = document.querySelector<HTMLButtonElement>('.ai-header button[aria-label="Chat options"]');
  assert(options, "New chat is missing header options");
  options.focus();
  options.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
  await until(() => document.querySelector('[role="menuitem"][href="/memory"]'), "Memory menu link");
  document.querySelector<HTMLElement>('[role="menu"]')!.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  await until(() => !document.querySelector('[role="menu"]'), "options closed");
  let samePageNavigations = 0;
  window.addEventListener(dashboardNavigationEvent, () => { samePageNavigations++; }, { once: true });
  click(".ai-history-new");
  assert(samePageNavigations === 1, "Same-page new chat did not complete navigation");
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
  stream!.enqueue(new TextEncoder().encode('event: text\ndata: {"text":"**Streaming reply**"}\n\n'));
  await until(() => document.querySelector(".ai-message.assistant strong")?.textContent === "Streaming reply", "streamed Markdown");
  completeStream();
  await until(() => messages().includes("Completed A"), "stream completes after URL change");
  assert(Number(sends) === 1, "First send was duplicated");
  await until(() => document.querySelector('.ai-message.assistant button[title="Share this answer to Workspace memory"]'), "share answer action");
  assert(!document.querySelector('.ai-message.user button'), "User message has a share action");
  const share = document.querySelector<HTMLButtonElement>('.ai-message.assistant button[title="Share this answer to Workspace memory"]')!;
  assert(share.getBoundingClientRect().height === 28, "Share action is not compact");
  share.click();
  await until(() => document.querySelector('[role="dialog"] textarea'), "share confirmation");
  assert(document.querySelector<HTMLTextAreaElement>('[role="dialog"] textarea')!.value === "**Streaming reply****Completed A**", "Sharing changed the answer or included other messages");
  const generateDraft = () => [...document.querySelectorAll<HTMLButtonElement>('[role="dialog"] button')].find(button => button.textContent === "Generate memory draft")!;
  failDraft = true;
  generateDraft().click();
  await until(() => document.querySelector('[role="dialog"] [role="alert"]'), "draft generation failure");
  assert(document.querySelector<HTMLTextAreaElement>('[role="dialog"] textarea')!.value === "**Streaming reply****Completed A**", "Failure lost the draft");
  failDraft = false;
  deferDraft = true;
  generateDraft().click();
  await until(() => finishDraft, "pending draft");
  assert((document.querySelector('[role="dialog"] [data-confirm]') as HTMLButtonElement).disabled, "Sharing allowed during generation");
  (document.querySelector('[role="dialog"] [data-cancel]') as HTMLButtonElement).click();
  await until(() => !document.querySelector('[role="dialog"]'), "generation canceled");
  assert(draftSignal?.aborted, "Closing did not cancel generation");
  finishDraft!();
  deferDraft = false;
  share.click();
  await until(generateDraft, "reopen share confirmation");
  assert(document.querySelector<HTMLTextAreaElement>('[role="dialog"] textarea')!.value === "**Streaming reply****Completed A**", "Late response replaced reopened draft");
  generateDraft().click();
  await until(() => document.querySelector<HTMLTextAreaElement>('[role="dialog"] textarea')?.value === "Generated shared note", "generated draft");
  assert(draftCalls === 3 && draftInput?.question === "First question" && draftInput.answer === "**Streaming reply****Completed A**" && draftInput.draft === draftInput.answer, "Draft omitted question, answer or current text");
  assert(savedContent === undefined, "Generation automatically shared the draft");
  if (new URLSearchParams(initialQuery).has("memory-preview")) return;
  (document.querySelector('[role="dialog"] [data-confirm]') as HTMLButtonElement).click();
  await until(() => savedContent === "Generated shared note", "explicit sharing");
  await until(() => !document.querySelector('[role="dialog"]'), "share confirmation closed");
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
  assert(document.querySelector(".ai-message.assistant strong")?.textContent === "Saved B", "Saved reply did not render Markdown");
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
  listStatus = 503;
  confirm.click();
  await until(() => location.pathname === "/chat" && ready() && !threads.has(idB), "delete current chat");
  assert(messages() === "", "Deleted chat remains visible");
  assert(!document.querySelector(`.ai-history-row a[href="${pathB}"]`), "Deleted chat returned to history");
  await until(() => document.body.textContent?.includes("Could not load chat history."), "post-delete history failure");
  listStatus = 200;
  click(".ai-error button");
  await until(() => !document.body.textContent?.includes("Could not load chat history."), "post-delete history retry");
  assert(!document.querySelector(`.ai-history-row a[href="${pathB}"]`), "History retry restored deleted chat");
  listStatus = 503;
  reload();
  await until(() => document.body.textContent?.includes("Could not load chat history."), "initial history failure");
  assert(!ready(), "Unknown persistence silently enabled temporary chat");
  assert(document.querySelector(".ai-history .ai-error") && !document.querySelector(".ai-chat > .ai-error"), "History failure is not next to the sidebar list");
  listStatus = 200;
  click(".ai-history .ai-error button");
  await until(ready, "history retry restores new chat");
  navigateDashboard("/dashboard/settings");
  await until(() => !document.querySelector(".ai-chat"), "leave chat before deletion race");
  assert(document.querySelector(".workspace-switcher, .workspace-navigation"), "Workspace navigation did not return after leaving chat");
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
