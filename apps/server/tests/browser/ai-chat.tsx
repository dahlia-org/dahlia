// Run pnpm dev:client and open /tests/browser/ai-chat.html. No backend is contacted.
import { createRoot } from "react-dom/client";

import { AiChat } from "@dahlia-ai/ui/screens/AiChat";
import { AppShell } from "@dahlia-ai/ui/layout/AppShell";
import "@dahlia-ai/ui/styles.css";
import policy from "../../resources/codex/source.json";

Object.defineProperty(navigator, "language", { value: "en-US", configurable: true });

const workspaceA = "ws_01k45b0000e008000000000001";
const workspaceB = "ws_01k45b0000e008000000000002";
const requests: Array<{ sessionId?: string; timeZone?: string; resume?: { tool: string; answer?: string | string[]; action?: string }; workspaceId: string; model: string; reasoningEffort: string; messages: Array<{ role: string; content: string }> }> = [];
let chats = 0;
let bundledModels = false;
let aiCapability = false;
let capabilityFailure: "http" | "network" | undefined;
let deferCapabilities = false;
const deferredCapabilities: Array<(response: Response) => void> = [];
let discoveryFails = false;

const sse = (answer: string) => new Response(`event: text\ndata: ${JSON.stringify({ text: answer })}\n\nevent: done\ndata: {}\n\n`, {
  headers: { "content-type": "text/event-stream" },
});

globalThis.fetch = async (input, init) => {
  const url = new URL(typeof input === "string" ? input : input instanceof URL ? input : input.url, location.href);
  if (url.pathname === "/api/v1/capabilities" && deferCapabilities) return new Promise<Response>((resolve) => {
    deferredCapabilities.push(resolve);
  });
  if (url.pathname === "/api/v1/capabilities" && capabilityFailure === "http") return Response.json({ error: "capability_failed" }, { status: 503 });
  if (url.pathname === "/api/v1/capabilities" && capabilityFailure === "network") throw new Error("capability_network_failed");
  if (url.pathname === "/api/v1/capabilities") return Response.json(aiCapability
    ? { ai: { version: 1, ...(bundledModels ? { bundledModels: "codex" } : {}) } } : {});
  if (url.pathname === "/api/v1/models" && discoveryFails) return Response.json({ error: "discovery_failed" }, { status: 503 });
  if (url.pathname === "/api/v1/models") return Response.json({ data: [
    { id: "model-a", display_name: "Model A" }, { id: "model-b", display_name: "Model B" },
  ], models: [
    { slug: "model-a", display_name: "Model A", supported_in_api: true, visibility: "list",
      default_reasoning_level: "medium", supported_reasoning_levels: [
      { effort: "low", description: "Fast" }, { effort: "medium", description: "Balanced" },
    ] },
    { slug: "model-b", display_name: "Model B", supported_in_api: true, visibility: "list",
      default_reasoning_level: "high", supported_reasoning_levels: [
      { effort: "high", description: "Deep" }, { effort: "max", description: "Maximum" },
    ] },
  ] });
  if (url.pathname === "/api/v1/workspaces") return Response.json({ items: [
    { workspaceId: workspaceA, name: "Workspace A" }, { workspaceId: workspaceB, name: "Workspace B" },
  ], nextCursor: null });
  if (url.pathname.endsWith("/projects") || url.pathname.endsWith("/meetings")) return Response.json({ items: [], nextCursor: null });
  if (url.pathname === "/api/v1/chat/messages") {
    if (typeof init?.body !== "string") throw new Error("Missing chat body");
    const request = JSON.parse(init.body) as typeof requests[number];
    requests.push(request);
    chats += 1;
    if (chats === 1) return new Promise<Response>((_resolve, reject) => {
      init?.signal?.addEventListener("abort", () => reject(new DOMException("Stopped", "AbortError")), { once: true });
    });
    if (chats === 2) return new Response("event: done\ndata: {}\n\n", { headers: { "content-type": "text/event-stream" } });
    if (chats === 13 || chats === 16) throw new Error("transient_resume_failure");
    if (chats === 6 || chats === 8 || chats === 10 || chats === 12 || chats === 15 || chats === 18 || chats === 21 || chats === 25) {
      const interaction = chats === 8 || chats === 15 ? { runId: "plan-run", toolCallId: "plan-call", tool: "submit_plan", title: "Meeting review", path: "plans/review.md", content: "Read the meeting summaries." }
        : { runId: "question-run", toolCallId: "question-call", tool: "ask_user", question: "Which meetings?", ...(chats === 6 ? { options: [{ label: "Planning" }, { label: "Review" }], selectionMode: "multi_select" } : (chats === 12 || chats === 18 || chats === 21 || chats === 25) ? { options: [{ label: "Planning" }] } : {}) };
      return new Response(`event: interaction\ndata: ${JSON.stringify({ interaction })}\n\n${chats === 25 ? 'event: error\ndata: {"code":"after_suspend_failed"}\n\n' : 'event: done\ndata: {}\n\n'}`, { headers: { "content-type": "text/event-stream" } });
    }
    if (chats === 19) return new Response('event: interaction-resumed\ndata: {"runId":"question-run","toolCallId":"question-call"}\n\nevent: error\ndata: {"code":"provider_failed"}\n\n', { headers: { "content-type": "text/event-stream" } });
    if (chats === 22) throw new Error("lost_ack");
    if (chats === 23) return Response.json({ error: "ai_interaction_not_pending" }, { status: 409 });
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
  history.replaceState(null, "", "/chat");
  const root = createRoot(document.getElementById("root")!);
  const render = (key: string) => root.render(<AppShell brand={<strong>Dahlia</strong>} extensionPaths={[]} navigate={() => {}}
    path="/chat" session={{ capabilities: { admin: false, sessions: false, sharing: false, sync: true, ai: true }, user: { id: "user" } }}>
    <AiChat key={key} />
    <span hidden data-fixture-key={key} />
  </AppShell>);
  deferCapabilities = true;
  render("capability-pending");
  await until(() => document.querySelector('[data-fixture-key="capability-pending"]')
    && document.querySelector<HTMLElement>('[data-ai-picker="model"]')?.dataset.value === "model-a", "selection while capability pending");
  await choose(controls().model, "model-b");
  deferredCapabilities.shift()!(Response.json({ ai: { version: 1, bundledModels: "codex" } }));
  controls().model.click();
  await until(() => document.querySelector('[role="option"][data-value="gpt-6.1-sol"]'), "late GPT augmentation");
  assert(controls().model.dataset.value === "model-b", "Late capability changed the selected model");
  document.querySelector<HTMLElement>('[role="option"][data-value="model-b"]')!.click();
  render("capability-stale");
  await until(() => document.querySelector('[data-fixture-key="capability-stale"]')
    && document.querySelector<HTMLElement>('[data-ai-picker="model"]')?.dataset.value === "model-a", "old mount pending capability");
  deferCapabilities = false;
  for (const failure of ["http", "network"] as const) {
    capabilityFailure = failure;
    render(`capability-${failure}`);
    await until(() => document.querySelector(`[data-fixture-key="capability-${failure}"]`)
      && document.querySelector<HTMLElement>('[data-ai-picker="model"]')?.dataset.value === "model-a",
      `remote selection after capability ${failure} failure`);
    assert(!document.querySelector(".ai-error"), "Optional capability failure blocked model discovery");
  }
  capabilityFailure = undefined;
  render("configured");
  await until(() => document.querySelector('[data-fixture-key="configured"]')
    && document.querySelector<HTMLElement>('[data-ai-picker="workspace"]')?.dataset.value === workspaceA
    && document.querySelector<HTMLElement>('[data-ai-picker="model"]')?.dataset.value === "model-a"
    && document.querySelector<HTMLElement>('[data-ai-picker="reasoning"]')?.dataset.value === "medium", "initial selection");
  assert(document.querySelector(".ai-header"), "The initial /chat page must show a chat header");
  let { workspace, reasoning, model } = controls();
  let textarea = document.querySelector<HTMLTextAreaElement>('.ai-composer textarea')!;
  assert(workspace.dataset.value === workspaceA && model.dataset.value === "model-a" && reasoning.dataset.value === "medium", "Initial selectors were not selected");
  assert(!model.textContent?.includes("GPT"), "Missing AI capability opted into bundled GPT models");
  deferredCapabilities.shift()!(Response.json({ ai: { version: 1, bundledModels: "codex" } }));
  model.click();
  await until(() => document.querySelector('[role="option"][data-value="model-a"]'), "picker after old capability completes");
  assert(!document.querySelector('[role="option"][data-value="gpt-6.1-sol"]'), "Aborted mount published its late capability");
  document.querySelector<HTMLElement>('[role="option"][data-value="model-a"]')!.click();
  change(textarea, "Line one\nLine two");
  press(textarea, "Enter", true);
  assert(requests.length === 0 && textarea.value.includes("\n"), "Shift+Enter submitted or lost the newline");
  press(textarea, "Enter");
  await until(() => document.querySelector<HTMLButtonElement>("button.ai-send:not(:disabled)"), "stop button");
  const header = document.querySelector(".ai-header")?.textContent ?? "";
  assert(header.includes("Dahlia AI") && header.includes("/") && header.includes("New chat"), "Chat breadcrumb is missing after chat starts");
  await new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve())));
  const headerBounds = document.querySelector<HTMLElement>(".ai-header")!.getBoundingClientRect();
  const firstMessageBounds = document.querySelector<HTMLElement>(".ai-message")!.getBoundingClientRect();
  const headerContentBounds = document.querySelector<HTMLElement>(".ai-header > div")!.getBoundingClientRect();
  assert(Math.abs(headerBounds.top - headerContentBounds.top) < 1 && Math.abs(headerBounds.bottom - headerContentBounds.bottom) < 1,
    "Chat header reserves space outside its visible toolbar");
  assert(firstMessageBounds.top >= headerBounds.bottom, "First message overlaps the header");
  const transcriptBounds = document.querySelector<HTMLElement>(".ai-transcript")!.getBoundingClientRect();
  assert(transcriptBounds.top - headerBounds.bottom <= 24, "Chat transcript starts too far below the header");
  for (const [selector, pseudo] of [[".ai-header", "::after"], [".ai-bottom", "::before"]] as const) {
    assert(getComputedStyle(document.querySelector<HTMLElement>(selector)!).backdropFilter === "none",
      `${selector} isolates its scroll edge from the messages behind it`);
    const edge = getComputedStyle(document.querySelector<HTMLElement>(selector)!, pseudo);
    assert(edge.backdropFilter.includes("blur(") && edge.maskImage.includes("linear-gradient") && edge.pointerEvents === "none",
      `${selector} is missing its non-interactive blurred scroll edge`);
  }
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
  assert(document.querySelector(".ai-header"), "The chat header disappeared after starting a new chat");
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
  assert(requests[4]?.timeZone === Intl.DateTimeFormat().resolvedOptions().timeZone, "Browser time zone was not sent");
  assert(requests[3]?.sessionId && requests[3].sessionId === requests[4]?.sessionId, "Page session did not survive a follow-up");
  change(textarea, "Compare meetings");
  press(textarea, "Enter");
  await until(() => document.querySelectorAll('.ai-interaction input[type="checkbox"]').length === 2, "multiple choices");
  document.querySelectorAll<HTMLInputElement>('.ai-interaction input[type="checkbox"]').forEach((checkbox) => checkbox.click());
  const button = (label: string) => [...document.querySelectorAll<HTMLButtonElement>(".ai-interaction button")].find((item) => item.textContent === label)!;
  button("Submit selections").click();
  await until(() => requests.length === 7 && !document.querySelector(".ai-interaction"), "question resume");
  assert(JSON.stringify(requests[6]?.resume?.answer) === '["Planning","Review"]', "Multiple selections were not sent as an explicit resume");
  change(textarea, "Make a plan");
  press(textarea, "Enter");
  await until(() => button("Approve plan"), "plan approval");
  const count = requests.length;
  change(textarea, "Do not implicitly approve");
  press(textarea, "Enter");
  assert(requests.length === count, "Typing a message implicitly approved a plan");
  button("Approve plan").click();
  await until(() => requests.length === 9 && !document.querySelector(".ai-interaction"), "plan resume");
  assert(requests[8]?.resume?.action === "approved", "Plan approval was not explicit");
  change(textarea, "Ask a question");
  press(textarea, "Enter");
  await until(() => document.querySelector(".ai-interaction"), "free-text question");
  change(textarea, "The afternoon meeting");
  press(textarea, "Enter");
  await until(() => requests.length === 11 && !document.querySelector(".ai-interaction"), "free-text answer");
  assert(requests[10]?.resume?.answer === "The afternoon meeting", "Free text did not resume the question");
  change(textarea, "Question with a transient failure");
  press(textarea, "Enter");
  await until(() => button("Planning"), "retryable question");
  button("Planning").click();
  await until(() => document.querySelector(".ai-error")?.textContent?.includes("transient_resume_failure"), "failed question resume");
  document.querySelector<HTMLButtonElement>(".ai-error button")!.click();
  await until(() => requests.length === 14 && !document.querySelector(".ai-interaction"), "retry question resume");
  assert(requests[13]?.resume?.answer === "Planning", "Retry lost the explicit question answer");
  change(textarea, "Plan with a transient failure");
  press(textarea, "Enter");
  await until(() => button("Approve plan"), "retryable plan");
  button("Approve plan").click();
  await until(() => document.querySelector(".ai-error")?.textContent?.includes("transient_resume_failure"), "failed plan resume");
  button("Request changes").click();
  await until(() => requests.length === 17 && !document.querySelector(".ai-interaction"), "revised plan response");
  assert(requests[16]?.resume?.action === "rejected", "Changed plan response was not explicit");
  change(textarea, "Question followed by a provider failure");
  press(textarea, "Enter");
  await until(() => button("Planning"), "accepted question");
  button("Planning").click();
  await until(() => document.querySelector(".ai-error")?.textContent?.includes("provider_failed"), "accepted resume failure");
  assert(!document.querySelector(".ai-interaction"), "Consumed question remained visible");
  document.querySelector<HTMLButtonElement>(".ai-error button")!.click();
  await until(() => requests.length === 20 && !document.querySelector(".ai-error"), "ordinary retry after acceptance");
  assert(!requests[19]?.resume, "Retry attempted to consume an already accepted answer");
  change(textarea, "Question whose acceptance event is lost");
  press(textarea, "Enter");
  await until(() => button("Planning"), "lost acknowledgement question");
  button("Planning").click();
  await until(() => document.querySelector(".ai-error")?.textContent?.includes("lost_ack"), "lost acknowledgement");
  document.querySelector<HTMLButtonElement>(".ai-error button")!.click();
  await until(() => document.querySelector(".ai-error")?.textContent?.includes("ai_interaction_not_pending"), "authoritative consumed response");
  assert(!document.querySelector(".ai-interaction"), "Already consumed question was retained after reconciliation");
  document.querySelector<HTMLButtonElement>(".ai-error button")!.click();
  await until(() => requests.length === 24 && !document.querySelector(".ai-error"), "retry after lost acknowledgement");
  assert(!requests[23]?.resume, "Lost acknowledgement recovery retried the consumed answer");
  change(textarea, "Question followed by an interrupted stream");
  press(textarea, "Enter");
  await until(() => document.querySelector(".ai-error")?.textContent?.includes("after_suspend_failed"), "failure after suspension publication");
  button("Planning").click();
  await until(() => requests.length === 26 && !document.querySelector(".ai-interaction"), "answer after interrupted suspension");
  assert(requests[25]?.resume?.answer === "Planning", "Interrupted suspension lost its pending answer");
  for (const request of requests.slice(11)) {
    assert(request.messages.every((message, index) => message.role === (index % 2 ? "assistant" : "user")), "Interaction recovery appended consecutive user messages");
  }
  aiCapability = true;
  bundledModels = true;
  render("databricks");
  await until(() => document.querySelector('[data-fixture-key="databricks"]') && controls().model.dataset.value, "Databricks model selection");
  model = controls().model;
  model.click();
  await until(() => document.querySelector('[role="option"][data-value="gpt-6.1-sol"]'), "bundled GPT options");
  const modelIds = [...document.querySelectorAll<HTMLElement>('[role="option"][data-value]')].map((option) => option.dataset.value);
  assert(modelIds.length === policy.models.length + 2 && policy.models.every((id) => modelIds.includes(id)), "Bundled allowlist or remote merge failed");
  document.querySelector<HTMLElement>('[role="option"][data-value="gpt-6.1-sol"]')!.click();
  await until(() => controls().model.dataset.value === "gpt-6.1-sol", "GPT selection");
  await choose(controls().reasoning, "low");
  textarea = document.querySelector<HTMLTextAreaElement>('.ai-composer textarea')!;
  change(textarea, "Reply only OK");
  press(textarea, "Enter");
  await until(() => requests.length === 27 && document.querySelector(".ai-message.assistant")?.textContent === "Follow-up answer", "bundled GPT response");
  assert(requests[26]?.model === "gpt-6.1-sol" && requests[26]?.reasoningEffort === "low", "GPT slug or upstream default was changed before submission");
  discoveryFails = true;
  render("discovery-failed");
  await until(() => document.querySelector(".ai-error[role=alert]"), "model discovery failure");
  assert(!controls().model.dataset.value && document.querySelector<HTMLButtonElement>("button.ai-send")?.disabled,
    "Failed model discovery fell back to bundled GPT models");
  capabilityFailure = "http";
  render("both-discovery-failed");
  await until(() => document.querySelector('[data-fixture-key="both-discovery-failed"]')
    && document.querySelector(".ai-error[role=alert]"), "both discovery failures");
  assert(!controls().model.dataset.value, "Capability failure hid the model discovery failure");
  document.body.dataset.testResult = "passed";
  document.getElementById("result")!.textContent = "PASS: selectors, Workspace lock, chat controls, empty response retry, composer, keyboard, stop, retry, interactions, pending/missing/failed capabilities do not block models, late GPT augmentation preserves selection, aborted capability cannot publish, Databricks GPT allowlist and reasoning choices, unchanged GPT submission and no fallback after discovery failure";
}

void run().catch((error: unknown) => { document.getElementById("result")!.textContent = `FAIL: ${String(error)}`; });
