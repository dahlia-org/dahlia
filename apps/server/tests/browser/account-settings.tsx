// Run pnpm dev:client and open /tests/browser/account-settings.html. No backend is contacted.
import { createRoot } from "react-dom/client";
import { ServerSummarySettings } from "../../src/client/SummaryGeneration";
import { DEFAULT_WORKSPACE_GENERATION_SETTINGS, workspaceGenerationSettingsSchema, type WorkspaceGenerationSettings } from "../../src/workspace-generation-settings";
import { modelList } from "../../src/ai-gateway/models";
import { liveDataEvent } from "../../src/client/live-data";
import "../../src/client/styles.css";

Object.defineProperty(navigator, "language", { value: "en-US", configurable: true });
let settings = structuredClone(DEFAULT_WORKSPACE_GENERATION_SETTINGS);
settings.processing.location = "local";
settings.processing.remote.summaryModel = "catalog.ai.unavailable";
settings.liveTranscriptDraft = true;
let role: "admin" | "viewer" = "admin";
let revision = 1;
const workspaceId = "workspace";
const workspace = () => ({ workspaceId, organizationId: "org", name: "Shared", revision,
  role, createdAt: new Date().toISOString(), updatedAt: new Date().toISOString(), generationSettings: settings });
const save = async (previous: { revision: number }, next: WorkspaceGenerationSettings) => {
  const response = await fetch("/api/v1/transactions", { method: "POST", body: JSON.stringify({ revision: previous.revision, settings: next }) });
  if (!response.ok) throw new Error("save_failed");
};
let failPatch = false;
let holdRead = false;
let blockedRead = false;
let releaseRead: (() => void) | undefined;
let failRead = false;
const patches: WorkspaceGenerationSettings[] = [];
window.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
  const request = input instanceof Request ? input : new Request(new URL(input, location.origin), init);
  const path = new URL(request.url).pathname;
  if (path === "/api/v1/transactions") {
    const body: { revision: number; settings: WorkspaceGenerationSettings } = await request.json();
    patches.push(body.settings);
    if (failPatch) return Response.json({ error: "save_failed" }, { status: 503 });
    if (body.revision !== revision) return Response.json({ error: "revision_conflict" }, { status: 409 });
    settings = workspaceGenerationSettingsSchema.parse(body.settings);
    revision++;
    return Response.json({});
  }
  if (path === "/api/v1/capabilities") return Response.json({ meetingSummaryGeneration: { version: 2, sources: ["transcript", "audio"], completeRecordings: true } });
  if (path === "/api/v1/models") return Response.json(modelList([{ id: "system.ai.gpt-5-6-luna" }, { id: "system.ai.gemini-3-8-flash" }]));
  if (path !== `/api/v1/workspaces/${workspaceId}`) throw new Error(`Unexpected fixture request ${path}`);
  if (holdRead) {
    blockedRead = true;
    await new Promise<void>((resolve) => { releaseRead = resolve; });
  }
  if (failRead) return Response.json({ error: "read_failed" }, { status: 503 });
  const snapshot = structuredClone(settings);
  return Response.json({ ...workspace(), generationSettings: snapshot });
});

function assert(value: unknown, message: string): asserts value { if (!value) throw new Error(message); }
async function until(predicate: () => unknown) {
  const deadline = performance.now() + 5000;
  while (!predicate()) {
    if (performance.now() > deadline) throw new Error("Timed out waiting for settings UI");
    await new Promise(requestAnimationFrame);
  }
}
function select(label: string) {
  const element = [...document.querySelectorAll("label")].find((node) => node.firstChild?.textContent === label)?.querySelector<HTMLButtonElement>('[role="combobox"]');
  assert(element, `Missing control ${label}`);
  return element;
}
async function choose(label: string, value: string) {
  const element = select(label);
  await until(() => !element.matches(":disabled"));
  element.click();
  await until(() => document.querySelector('[data-slot="select-content"][data-state="open"]'));
  const option = [...document.querySelectorAll<HTMLElement>('[data-slot="select-content"][data-state="open"] [role="option"]')].find((node) => node.dataset.value === value);
  assert(option, `Missing option ${value}`);
  option.click();
}
function selectedValue(label: string) { return select(label).dataset.value; }
async function ready() { await until(() => document.querySelector<HTMLButtonElement>('[role="combobox"]') && !select("Output language").matches(":disabled")); }
async function run() {
  createRoot(document.getElementById("root")!).render(<ServerSummarySettings workspaceId={workspaceId} onSave={save} />);
  await ready();
  for (const label of ["Transcription location", "After recording"]) {
    assert(!document.body.textContent?.includes(label), `Obsolete setting remained visible: ${label}`);
  }
  assert(document.body.textContent?.includes("Web operations run on the server"), "Web execution boundary was not explained");
  const legacy = structuredClone(settings);
  holdRead = true;
  await choose("Output language", "en");
  await until(() => blockedRead && patches.length === 1);
  assert(select("Output language").matches(":disabled") && select("Summary style").matches(":disabled"),
    "Both sections must stay disabled until the saved revision is reloaded");
  select("Summary style").click();
  await new Promise(requestAnimationFrame);
  assert(patches.length === 1, "A stale revision was submitted during refresh");
  failRead = true; holdRead = false; releaseRead!();
  await until(() => document.querySelector('[role="alert"]'));
  assert(select("Output language").matches(":disabled") && select("Summary style").matches(":disabled"),
    "Failed refresh must not re-enable stale workspace edits");
  failRead = false;
  [...document.querySelectorAll("button")].find((button) => button.textContent === "Retry")!.click();
  await until(() => selectedValue("Output language") === "en");
  await ready();
  assert(JSON.stringify(settings) === JSON.stringify({ ...legacy, outputLanguage: "en" }), "Language save changed legacy preferences");
  assert(patches.at(-1)?.outputLanguage === "en", "Shared language was not saved");

  await choose("Summary style", "standard");
  await until(() => selectedValue("Summary style") === "standard");
  await ready();
  await choose("Summary model", "system.ai.gemini-3-8-flash");
  await until(() => [...document.querySelectorAll("label")].some((node) => node.firstChild?.textContent === "Summary model") && selectedValue("Summary model") === "system.ai.gemini-3-8-flash");
  await ready();
  await choose("Summary reasoning effort", "high");
  await until(() => selectedValue("Summary reasoning effort") === "high");
  await ready();
  assert(settings.processing.remote.summaryModel === "system.ai.gemini-3-8-flash" && settings.processing.remote.reasoningEffort === "high", "Direct audio summary did not save the audio model/effort pair");
  assert(![...document.querySelectorAll("legend")].some((node) => node.textContent === "Transcription"), "Direct audio summary displayed transcription settings");
  await choose("Audio processing method", "transcribeThenSummarize");
  await until(() => selectedValue("Audio processing method") === "transcribeThenSummarize");
  await ready();
  await choose("Transcript summary model", "system.ai.gpt-5-6-luna");
  await until(() => selectedValue("Transcript summary model") === "system.ai.gpt-5-6-luna");
  await ready();
  await choose("Summary reasoning effort", "high");
  await until(() => selectedValue("Summary reasoning effort") === "high");
  await ready();
  await choose("Audio processing method", "combined");
  await until(() => [...document.querySelectorAll("label")].some((node) => node.firstChild?.textContent === "Summary model") && selectedValue("Summary model") === "system.ai.gemini-3-8-flash");
  await ready();
  assert(selectedValue("Summary reasoning effort") === "high", "Direct summary lost the saved audio reasoning effort");
  assert(settings.processing.remote.transcriptSummaryModel === "system.ai.gpt-5-6-luna" && settings.processing.remote.transcriptSummaryReasoningEffort === "high", "Workflow switch changed text summary defaults");
  assert(settings.processing.location === legacy.processing.location && settings.liveTranscriptDraft === legacy.liveTranscriptDraft && JSON.stringify(settings.local) === JSON.stringify(legacy.local), "Server defaults changed Desktop settings");
  assert(settings.processing.remote.transcriptSummaryReasoningEffort === "high", "Server reasoning default was not saved");
  assert(document.querySelectorAll("section").length === 2, "Language and server defaults are not independent sections");
  settings.outputLanguage = "fr";
  window.dispatchEvent(new Event(liveDataEvent));
  await until(() => selectedValue("Output language") === "fr");
  await ready();
  failPatch = true;
  await choose("Output language", "de");
  await until(() => document.querySelector('[role="alert"]'));
  await ready();
  assert(selectedValue("Output language") === "fr", "Failed save discarded confirmed settings");
  failPatch = false;
  await choose("Output language", "de");
  await until(() => selectedValue("Output language") === "de");
  await ready();
  assert(!document.querySelector('[role="alert"]'), "Retry did not clear the save error");
  role = "viewer";
  window.dispatchEvent(new Event(liveDataEvent));
  await until(() => select("Output language").matches(":disabled"));
  document.getElementById("result")!.textContent = "PASS: delayed refresh and failed reload/retry, independent language and server defaults, Desktop/Web boundary, legacy values preserved, settings notification, failed save/retry, viewer read-only";
}
void run().catch((error: unknown) => { document.getElementById("result")!.textContent = `FAIL: ${String(error)}`; console.error(error); });
