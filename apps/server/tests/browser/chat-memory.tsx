// pnpm dev:client -> /tests/browser/chat-memory.html. In-memory API only.
import { createRoot } from "react-dom/client";
import { ChatPreferences, LiveChatContext } from "../../src/client/ChatMemory";
import { emptyPreferences, type PreferenceSettings } from "../../src/agent/context-model";

Object.defineProperty(navigator, "language", { value: "en-US", configurable: true });
let saved: PreferenceSettings = { revision: 0, automatic: true, preferences: { ...emptyPreferences } };
let poll: (() => void) | undefined;
const nativeInterval = window.setInterval.bind(window);
window.setInterval = ((callback: TimerHandler, delay?: number) => {
  if (delay === 15_000) poll = callback as () => void;
  return nativeInterval(callback, delay);
}) as typeof window.setInterval;
let holdRead = false, failWrite = false;
let liveMeeting: string | null = "A", holdLive = false, holdWrite = false;
let releaseLive: (() => void) | undefined, releaseWrite: (() => void) | undefined;
let failMeetings = false, holdMeetings = false;
let releaseMeetings: (() => void) | undefined;
let meetingChoices = [{ meetingId: "A", name: "A", isRecording: true }, { meetingId: "B", name: "B", isRecording: true }];
let releaseRead: (() => void) | undefined;
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
  if (path !== "/api/v1/chat/preferences") throw new Error("Unexpected request");
  if (request.method === "PUT") {
    if (failWrite) return Response.json({ error: "unavailable" }, { status: 503 });
    const next: PreferenceSettings = await request.json();
    if (next.revision !== saved.revision) return Response.json({ error: "memory_revision_conflict" }, { status: 409 });
    saved = { ...next, revision: next.revision + 1 };
  }
  const response = Response.json(saved);
  if (request.method === "GET" && holdRead) {
    holdRead = false;
    await new Promise<void>((resolve) => { releaseRead = resolve; });
  }
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
const explanation = () => document.querySelector("textarea")!;
const select = (index: number) => document.querySelectorAll("select")[index]!;
const button = (text: string) => [...document.querySelectorAll("button")].find((element) => element.textContent === text)!;
async function run() {
  const root = createRoot(document.getElementById("root")!);
  root.render(<ChatPreferences />);
  await until(() => document.querySelector("details"));
  saved = { ...saved, revision: 1, preferences: { ...saved.preferences, language: "ja", explanation: "Explain terms" } };
  document.querySelector("details")!.open = true;
  await until(() => explanation().value === "Explain terms");
  assert(select(0).value === "ja" && !button("Forget").disabled, "Opening did not load learned preferences");
  Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, "value")!.set!.call(explanation(), "My unsaved explanation");
  explanation().dispatchEvent(new Event("input", { bubbles: true }));
  saved = { ...saved, revision: 2, preferences: { ...saved.preferences, format: "bullets", explanation: "Short examples" } };
  poll!();
  await until(() => select(1).value === "bullets");
  assert(explanation().value === "My unsaved explanation", "Refresh erased a dirty draft");
  button("Save explanation preference").click();
  await until(() => saved.preferences.explanation === "My unsaved explanation" && !button("Forget").disabled);
  holdRead = true; poll!();
  await until(() => releaseRead);
  button("Forget").click();
  await until(() => saved.preferences.explanation === null && !select(0).disabled);
  releaseRead!();
  await new Promise(requestAnimationFrame);
  assert(explanation().value === "" && button("Forget").disabled, "An old read resurrected the forgotten preference");
  failWrite = true;
  select(0).value = "en";
  select(0).dispatchEvent(new Event("change", { bubbles: true }));
  await until(() => document.querySelector('[role="alert"]') && !select(0).disabled);
  assert(saved.preferences.language === "ja", "Failed write changed the saved preference");
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
  document.getElementById("result")!.textContent = "PASS: learned preferences on open, background refresh, dirty draft, latest revision save, forget, stale read, failed save; live selection, detach and thread switch races; meeting list retry, newly synced recording, stale list rejection";
}
void run().catch((error: unknown) => { document.getElementById("result")!.textContent = `FAIL: ${String(error)}`; });
