// Run pnpm dev:client and open /tests/browser/ai-chat.html. No backend is contacted.
import { createRoot } from "react-dom/client";

import { AiChat } from "../../src/client/AiChat";
import { AppShell } from "../../src/client/layout/AppShell";
import "../../src/client/styles.css";

const workspaceA = "ws_01k45b0000e008000000000001";
const workspaceB = "ws_01k45b0000e008000000000002";
const requests: Array<{ workspaceId: string; model: string; reasoningEffort: string; messages: Array<{ role: string; content: string }> }> = [];
let chats = 0;

const sse = (answer: string) => new Response(`event: text\ndata: ${JSON.stringify({ text: answer })}\n\nevent: done\ndata: {}\n\n`, {
  headers: { "content-type": "text/event-stream" },
});

globalThis.fetch = async (input, init) => {
  const url = new URL(typeof input === "string" ? input : input instanceof URL ? input : input.url, location.href);
  if (url.pathname === "/api/v1/ai/models") return Response.json({ items: [
    { id: "model-a", displayName: "Model A", defaultReasoningEffort: "medium", supportedReasoningEfforts: [
      { effort: "low", description: "Fast" }, { effort: "medium", description: "Balanced" },
    ] },
    { id: "model-b", displayName: "Model B", defaultReasoningEffort: "high", supportedReasoningEfforts: [
      { effort: "high", description: "Deep" }, { effort: "max", description: "Maximum" },
    ] },
  ] });
  if (url.pathname === "/api/v1/workspaces") return Response.json({ items: [
    { workspaceId: workspaceA, name: "Workspace A" }, { workspaceId: workspaceB, name: "Workspace B" },
  ], nextCursor: null });
  if (url.pathname.endsWith("/projects") || url.pathname.endsWith("/meetings")) return Response.json({ items: [], nextCursor: null });
  if (url.pathname === "/api/v1/ai/chat") {
    if (typeof init?.body !== "string") throw new Error("Missing chat body");
    const request = JSON.parse(init.body) as typeof requests[number];
    requests.push(request);
    chats += 1;
    if (chats === 1) return new Promise<Response>((_resolve, reject) => {
      init?.signal?.addEventListener("abort", () => reject(new DOMException("Stopped", "AbortError")), { once: true });
    });
    if (chats === 2) return new Response("event: done\ndata: {}\n\n", { headers: { "content-type": "text/event-stream" } });
    return sse(chats === 3 ? "Retried answer" : chats === 4 ? "New answer" : "Follow-up answer");
  }
  return Response.json({ error: "not_found" }, { status: 404 });
};

const assert: (value: unknown, message: string) => asserts value = (value, message) => { if (!value) throw new Error(message); };
const frame = () => new Promise<void>((resolve) => setTimeout(resolve, 0));
const until = async (test: () => unknown, label: string) => {
  for (let attempt = 0; attempt < 120; attempt++) { if (test()) return; await frame(); }
  throw new Error(`Timed out: ${label}`);
};
const change = (element: HTMLTextAreaElement, value: string) => {
  Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, "value")!.set!.call(element, value);
  element.dispatchEvent(new Event("input", { bubbles: true }));
};
const press = (element: HTMLTextAreaElement, key: string, shiftKey = false) => element.dispatchEvent(new KeyboardEvent("keydown", {
  key, shiftKey, bubbles: true, cancelable: true,
}));
const controls = () => {
  const workspace = document.querySelector<HTMLButtonElement>('[data-ai-picker="workspace"]');
  const reasoning = document.querySelector<HTMLButtonElement>('[data-ai-picker="reasoning"]');
  const model = document.querySelector<HTMLButtonElement>('[data-ai-picker="model"]');
  if (!workspace || !reasoning || !model) throw new Error("Missing composer selectors");
  return { workspace, reasoning, model };
};
const choose = async (trigger: HTMLButtonElement, value: string) => {
  trigger.click();
  await until(() => document.querySelector<HTMLElement>(`[role="option"][data-value="${value}"]`), `option ${value}`);
  document.querySelector<HTMLElement>(`[role="option"][data-value="${value}"]`)!.click();
  await until(() => trigger.dataset.value === value, `selection ${value}`);
};

async function run() {
  history.replaceState(null, "", "/ai");
  createRoot(document.getElementById("root")!).render(<AppShell brand={<strong>Dahlia</strong>} extensionPaths={[]} navigate={() => {}}
    path="/ai" session={{ capabilities: { admin: false, sessions: false, sharing: false, sync: true, ai: true }, user: { id: "user" } }}>
    <AiChat />
  </AppShell>);
  await until(() => document.querySelector<HTMLElement>('[data-ai-picker="workspace"]')?.dataset.value === workspaceA
    && document.querySelector<HTMLElement>('[data-ai-picker="model"]')?.dataset.value === "model-a"
    && document.querySelector<HTMLElement>('[data-ai-picker="reasoning"]')?.dataset.value === "medium", "initial selection");
  assert(!document.querySelector(".ai-header"), "The initial /ai page must not show a chat header");
  let { workspace, reasoning, model } = controls();
  let textarea = document.querySelector<HTMLTextAreaElement>('.ai-composer textarea')!;
  assert(workspace.dataset.value === workspaceA && model.dataset.value === "model-a" && reasoning.dataset.value === "medium", "Initial selectors were not selected");
  change(textarea, "Line one\nLine two");
  press(textarea, "Enter", true);
  assert(requests.length === 0 && textarea.value.includes("\n"), "Shift+Enter submitted or lost the newline");
  press(textarea, "Enter");
  await until(() => document.querySelector<HTMLButtonElement>("button.ai-send:not(:disabled)"), "stop button");
  const header = document.querySelector(".ai-header")?.textContent ?? "";
  assert(header.includes("Dahlia AI") && header.includes("/") && header.includes("New chat"), "Chat breadcrumb is missing after chat starts");
  const headerBounds = document.querySelector<HTMLElement>(".ai-header")!.getBoundingClientRect();
  const firstMessageBounds = document.querySelector<HTMLElement>(".ai-message")!.getBoundingClientRect();
  assert(firstMessageBounds.top - headerBounds.bottom <= 24, "Chat messages start too far below the header");
  assert(!document.querySelector(".ai-header .secondary"), "The redundant right-side new chat button is still visible");
  ({ workspace, reasoning, model } = controls());
  assert(workspace.disabled && reasoning.disabled && model.disabled, "Selectors remained enabled while responding");
  document.querySelector<HTMLButtonElement>("button.ai-send:not(:disabled)")!.click();
  await until(() => document.querySelector(".ai-error[role=alert]"), "stopped status");
  ({ workspace, reasoning, model } = controls());
  assert(workspace.disabled && !reasoning.disabled && !model.disabled, "Workspace was not fixed or response selectors stayed locked after stopping");
  await choose(model, "model-b");
  await until(() => reasoning.dataset.value === "high", "model reasoning default");
  await choose(reasoning, "max");
  document.querySelector<HTMLButtonElement>(".ai-error button")!.click();
  await until(() => document.querySelector(".ai-error")?.textContent?.includes("stream_incomplete"), "empty response error");
  document.querySelector<HTMLButtonElement>(".ai-error button")!.click();
  await until(() => document.querySelector(".ai-message.assistant")?.textContent === "Retried answer", "retry answer");
  const userMessage = document.querySelector<HTMLElement>(".ai-message.user")!;
  assert(parseFloat(getComputedStyle(userMessage).borderTopLeftRadius) >= userMessage.offsetHeight / 2, "User message is not pill-shaped");
  assert(requests[2]?.model === "model-b" && requests[2]?.reasoningEffort === "max", "Retry did not use the selected model and reasoning effort");
  textarea = document.querySelector<HTMLTextAreaElement>('.ai-composer textarea')!;
  change(textarea, "1\n2");
  await frame();
  const twoLineHeight = textarea.clientHeight;
  change(textarea, Array.from({ length: 10 }, (_, index) => String(index + 1)).join("\n"));
  await frame();
  const tenLineHeight = textarea.clientHeight;
  change(textarea, Array.from({ length: 11 }, (_, index) => String(index + 1)).join("\n"));
  await frame();
  assert(tenLineHeight > twoLineHeight && textarea.clientHeight === tenLineHeight && textarea.scrollHeight > textarea.clientHeight,
    "Composer did not grow from two to ten lines and scroll beyond the limit");
  assert(getComputedStyle(document.querySelector<HTMLElement>(".ai-header")!).position === "sticky", "AI header does not remain fixed while scrolling");
  document.querySelector<HTMLButtonElement>(".ai-new-chat")!.click();
  await until(() => document.querySelector(".ai-start"), "new chat");
  assert(!document.querySelector(".ai-header"), "The chat header remained visible after starting a new chat");
  ({ workspace, reasoning, model } = controls());
  assert(!workspace.disabled && document.querySelectorAll(".ai-message").length === 0, "New chat did not clear history and unlock Workspace");
  await choose(workspace, workspaceB);
  await choose(model, "model-a");
  textarea = document.querySelector<HTMLTextAreaElement>('.ai-composer textarea')!;
  change(textarea, "New question");
  press(textarea, "Enter");
  await until(() => document.querySelector(".ai-message.assistant")?.textContent === "New answer", "new answer");
  assert(requests[3]?.workspaceId === workspaceB && requests[3]?.messages.length === 1, "New chat kept the old Workspace or history");
  model = controls().model;
  await choose(model, "model-b");
  textarea = document.querySelector<HTMLTextAreaElement>('.ai-composer textarea')!;
  change(textarea, "Follow up");
  press(textarea, "Enter");
  await until(() => [...document.querySelectorAll(".ai-message.assistant")].at(-1)?.textContent === "Follow-up answer", "follow-up answer");
  assert(requests[4]?.model === "model-b" && requests[4]?.reasoningEffort === "high"
    && requests[4]?.messages.map(({ role }) => role).join(",") === "user,assistant,user",
    "Per-message model change or alternating page history failed");
  assert(document.querySelector('[aria-live="polite"]'), "Readable response status is missing");
  if (innerWidth < 768) assert(document.querySelector(".ai-bottom")!.getBoundingClientRect().width <= innerWidth, "Mobile composer overflowed");
  document.body.dataset.testResult = "passed";
  document.getElementById("result")!.textContent = "PASS: selectors, Workspace lock, chat controls, empty response retry, two-to-ten-line composer, sticky header, keyboard, stop, retry, mobile width";
}

void run().catch((error: unknown) => { document.getElementById("result")!.textContent = `FAIL: ${String(error)}`; });
