// pnpm dev:client -> /tests/browser/chat-memory.html. In-memory API only.
import { createRoot } from "react-dom/client";
import { WorkingMemoryEditor, LiveChatContext } from "../../src/client/ChatMemory";
import { type WorkingMemorySettings } from "../../src/agent/context-model";

Object.defineProperty(navigator, "language", { value: "en-US", configurable: true });
let saved: WorkingMemorySettings = { revision: 0, automatic: true, capacityReached: false, manual: "", learned: "" };
let poll: (() => void) | undefined;
const nativeInterval = window.setInterval.bind(window);
window.setInterval = ((callback: TimerHandler, delay?: number) => {
  if (delay === 15_000) poll = callback as () => void;
  return nativeInterval(callback, delay);
}) as typeof window.setInterval;
let liveMeeting: string | null = "A", holdLive = false, holdWrite = false;
let releaseLive: (() => void) | undefined, releaseWrite: (() => void) | undefined;
let failMeetings = false, holdMeetings = false;
let releaseMeetings: (() => void) | undefined;
let meetingChoices = [{ meetingId: "A", name: "A", isRecording: true }, { meetingId: "B", name: "B", isRecording: true }];
window.fetch = async (input, init) => {
  const request = input instanceof Request ? input : new Request(new URL(input, location.origin), init);
  const path = new URL(request.url).pathname;
  if (path.endsWith("/meetings")) {
    if (failMeetings) return Response.json({ error: "unavailable" }, { status: 503 });
    const response = new URL(request.url).searchParams.has("cursor")
      ? Response.json({ items: [{ meetingId: "old", name: "Older meeting", isRecording: false }] })
      : Response.json({ items: meetingChoices, nextCursor: "older" });
    if (holdMeetings) { holdMeetings = false; await new Promise<void>((resolve) => { releaseMeetings = resolve; }); }
    return response;
  }
  if (path.endsWith("/live-context")) {
    if (request.method === "PUT") {
      const next: { meetingId: string | null } = await request.json();
      liveMeeting = next.meetingId;
      if (holdWrite) { holdWrite = false; await new Promise<void>((resolve) => { releaseWrite = resolve; }); }
      return Response.json({});
    }
    const response = Response.json({ meetingId: liveMeeting, status: liveMeeting ? "ready" : "off", updatedAt: null, processedThrough: null });
    if (holdLive) { holdLive = false; await new Promise<void>((resolve) => { releaseLive = resolve; }); }
    return response;
  }
  if (path !== "/api/v1/user/memory/working") throw new Error("Unexpected request");
  if (request.method === "PATCH") {
    const next: { section: "manual" | "learned" | "settings"; content?: string; automatic?: boolean; revision: number } = await request.json();
    if (next.revision !== saved.revision) return Response.json({ error: "memory_revision_conflict" }, { status: 409 });
    saved = { ...saved, [next.section === "settings" ? "automatic" : next.section]: next.section === "settings" ? next.automatic : next.content, revision: next.revision + 1 };
  }
  const response = Response.json(saved);
  return response;
};
function assert(value: unknown, message: string): asserts value { if (!value) throw new Error(message); }
async function until(predicate: () => unknown) {
  const deadline = performance.now() + 5000;
  while (!predicate()) {
    if (performance.now() > deadline) throw new Error("Timed out waiting for preference UI");
    await new Promise(requestAnimationFrame);
  }
}
const textarea = (index: number) => document.querySelectorAll("textarea")[index]!;
const select = (index: number) => document.querySelectorAll("select")[index]!;
const button = (text: string) => [...document.querySelectorAll("button")].find((element) => element.textContent === text)!;
async function run() {
  const root = createRoot(document.getElementById("root")!);
  root.render(<WorkingMemoryEditor />);
  await until(() => document.querySelector("details"));
  saved = { ...saved, revision: 1, manual: "## Profile\nI use Dahlia", learned: "- Japanese replies" };
  document.querySelector("details")!.open = true;
  await until(() => textarea(0).value.includes("Dahlia"));
  assert(textarea(1).value.includes("Japanese"), "Opening did not load learned notes");
  Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, "value")!.set!.call(textarea(0), "My unsaved note");
  textarea(0).dispatchEvent(new Event("input", { bubbles: true }));
  saved = { ...saved, revision: 2, learned: "- Short examples" };
  poll!();
  await until(() => textarea(1).value.includes("Short examples"));
  assert(textarea(0).value === "My unsaved note", "Refresh erased a draft");
  button("Save notes").click();
  await until(() => saved.manual === "My unsaved note");
  await until(() => !textarea(0).disabled);
  Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, "value")!.set!.call(textarea(0), "Concurrent draft");
  textarea(0).dispatchEvent(new Event("input", { bubbles: true }));
  saved = { ...saved, revision: saved.revision + 1, manual: "Updated by another client", learned: "Poll completed" };
  poll!();
  await until(() => textarea(1).value === "Poll completed");
  button("Save notes").click();
  await until(() => document.querySelector("[role=alert]"));
  assert(saved.manual === "Updated by another client", "Concurrent update was overwritten");
  assert(textarea(0).value === "Concurrent draft", "Conflict lost the draft");
  button("Discard drafts and reload").click();
  await until(() => textarea(0).value === "Updated by another client");
  saved = { ...saved, revision: saved.revision + 1, automatic: false, capacityReached: true };
  poll!();
  await until(() => document.body.textContent.includes("reached capacity"));
  failMeetings = true;
  root.render(<LiveChatContext threadId="thread" workspaceId="workspace" disabled={false} />);
  await until(() => document.querySelectorAll("select").length === 1 && select(0).value === "A");
  await until(() => button("Retry"));
  failMeetings = false; button("Retry").click();
  await until(() => [...select(0).options].some((option) => option.value === "B") && !button("Retry"));
  button("More meetings").click();
  await until(() => [...select(0).options].some((option) => option.value === "old"));
  meetingChoices.push({ meetingId: "C", name: "New recording", isRecording: true });
  select(0).dispatchEvent(new FocusEvent("focusin", { bubbles: true }));
  await until(() => [...select(0).options].some((option) => option.value === "C"));
  assert([...select(0).options].some((option) => option.value === "old"), "Opening the picker discarded paged meetings");
  const choose = (value: string) => { select(0).value = value; select(0).dispatchEvent(new Event("change", { bubbles: true })); };
  holdLive = true; poll!();
  await until(() => releaseLive);
  choose("B");
  await until(() => select(0).value === "B" && !select(0).disabled);
  releaseLive!(); releaseLive = undefined;
  await new Promise(requestAnimationFrame);
  assert(select(0).value === "B", "An old poll restored the previous meeting");
  holdLive = true; poll!(); await until(() => releaseLive);
  choose(""); await until(() => select(0).value === "" && !select(0).disabled);
  releaseLive!(); releaseLive = undefined;
  await new Promise(requestAnimationFrame);
  assert(select(0).value === "", "An old poll reattached a meeting");
  holdWrite = true; choose("A"); await until(() => releaseWrite);
  root.render(<LiveChatContext threadId="other" workspaceId="workspace" disabled={false} />);
  liveMeeting = "B";
  await until(() => select(0).value === "B" && !select(0).disabled);
  releaseWrite!(); await new Promise(requestAnimationFrame);
  assert(select(0).value === "B", "An old thread's mutation changed current selection");
  holdMeetings = true;
  select(0).dispatchEvent(new FocusEvent("focusin", { bubbles: true }));
  await until(() => releaseMeetings);
  meetingChoices = [{ meetingId: "D", name: "Other workspace recording", isRecording: true }];
  root.render(<LiveChatContext threadId="third" workspaceId="other-workspace" disabled={false} />);
  await until(() => [...select(0).options].some((option) => option.value === "D"));
  releaseMeetings!(); await new Promise(requestAnimationFrame);
  assert(![...select(0).options].some((option) => option.value === "C"), "An old meeting list crossed workspace scope");
  document.body.dataset.testResult = "passed";
  document.getElementById("result")!.textContent = "PASS: learned notes on open, background refresh, dirty draft, same-section conflict, cross-section save, capacity warning; live selection, detach and thread switch races; meeting list retry, newly synced recording, stale list rejection";
}
void run().catch((error: unknown) => { document.getElementById("result")!.textContent = `FAIL: ${String(error)}`; });
