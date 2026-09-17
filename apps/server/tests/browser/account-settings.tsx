// Run pnpm dev:client and open /tests/browser/account-settings.html. No backend is contacted.
import { createRoot } from "react-dom/client";
import { ServerSummarySettings } from "../../src/client/SummaryGeneration";
import { DEFAULT_WORKSPACE_GENERATION_SETTINGS, workspaceGenerationSettingsSchema, type WorkspaceGenerationSettings } from "../../src/workspace-generation-settings";
import { liveDataEvent } from "../../src/client/live-data";
import { modelList } from "../../src/ai-gateway/models";
import "../../src/client/styles.css";

Object.defineProperty(navigator, "language", { value: "en-US", configurable: true });
let settings = structuredClone(DEFAULT_WORKSPACE_GENERATION_SETTINGS);
settings.processing.location = "remote";
let remoteCapability = false;
let revision = 1;
const workspaceId = "workspace";
const workspace = () => ({ workspaceId, organizationId: "org", name: "Shared", revision,
  role: "admin" as const, createdAt: new Date().toISOString(), updatedAt: new Date().toISOString(), generationSettings: settings });
const save = async (previous: { revision: number }, next: WorkspaceGenerationSettings) => {
  const response = await fetch("/api/v1/transactions", { method: "POST", body: JSON.stringify({ revision: previous.revision, settings: next }) });
  if (!response.ok) throw new Error("save_failed");
};
let modelReads = 0;
let failPatch = false;
let patchGate: ReturnType<typeof gate> | undefined;
let readGate: ReturnType<typeof gate> | undefined;
const patches: WorkspaceGenerationSettings[] = [];
let readStarted = false;
function gate() {
  let release!: () => void;
  return { promise: new Promise<void>((resolve) => { release = resolve; }), release: () => release() };
}
window.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
  const request = input instanceof Request ? input : new Request(new URL(input, location.origin), init);
  const path = new URL(request.url).pathname;
  if (path === "/api/v1/capabilities") return Response.json(remoteCapability
    ? { meetingSummaryGeneration: { version: 2, sources: ["transcript", "audio"] } }
    : {});
  if (path === "/api/v1/models") {
    modelReads++;
    return Response.json(modelList([{ id: "gpt-5.4" }, { id: "system.ai.gemini-3-8-flash" }]));
  }
  if (path === "/api/v1/transactions") {
    const body: { revision: number; settings: WorkspaceGenerationSettings } = await request.json();
    patches.push(body.settings);
    if (failPatch) return Response.json({ error: "save_failed" }, { status: 503 });
    await patchGate?.promise;
    if (body.revision !== revision) return Response.json({ error: "revision_conflict" }, { status: 409 });
    settings = workspaceGenerationSettingsSchema.parse(body.settings);
    revision++;
    return Response.json({});
  }
  if (path !== `/api/v1/workspaces/${workspaceId}`) throw new Error(`Unexpected fixture request ${path}`);
  const snapshot = structuredClone(settings);
  const waiting = readGate;
  readGate = undefined;
  readStarted = true;
  await waiting?.promise;
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
  assert(!element.matches(":disabled"), `${label} is disabled`);
  await until(() => document.getElementById(element.getAttribute("aria-controls")!));
  element.click();
  const option = document.getElementById(element.getAttribute("aria-controls")!)?.querySelector<HTMLButtonElement>(`button[value="${value}"]`);
  assert(option, `Missing option ${value}`);
  option.click();
}
async function ready() { await until(() => document.querySelector<HTMLButtonElement>('[role="combobox"]') && !select("Output language").matches(":disabled")); }
async function run() {
  const first = createRoot(document.getElementById("root")!);
  first.render(<ServerSummarySettings workspaceId={workspaceId} onSave={save} />);
  await ready();
  await choose("Transcription location", "local");
  await until(() => settings.processing.location === "local");
  first.unmount();

  remoteCapability = true;
  settings.processing.location = "local";
  settings.processing.remote.summaryModel = "gpt-5.4";
  settings.processing.remote.reasoningEffort = "high";
  const legacy = createRoot(document.getElementById("root")!);
  legacy.render(<ServerSummarySettings workspaceId={workspaceId} onSave={save} />);
  await ready();
  await choose("Summary model", "");
  await until(() => settings.processing.remote.summaryModel === undefined);
  await ready();
  await choose("Summary reasoning effort", "");
  await until(() => settings.processing.remote.reasoningEffort === undefined);
  legacy.unmount();

  settings.processing.location = "remote";
  settings.processing.remote.workflow = "transcribeThenSummarize";
  settings.processing.remote.summaryModel = "catalog.ai.unavailable";
  createRoot(document.getElementById("root")!).render(<ServerSummarySettings workspaceId={workspaceId} onSave={save} />);
  await ready();
  await until(() => document.body.textContent?.includes("Summary method") && modelReads === 1);
  await choose("Summary method", "combined");
  await until(() => settings.processing.remote.workflow === "combined");
  await ready();
  assert(!document.body.textContent?.includes("Transcription language"), "Remote language settings remained visible");
  assert(select("Summary model").value === "catalog.ai.unavailable", "Unavailable explicit choice was silently replaced");
  await choose("Summary model", "system.ai.gemini-3-8-flash");
  await until(() => settings.processing.remote.summaryModel === "system.ai.gemini-3-8-flash");
  await ready();
  await choose("Summary style", "concise");
  await until(() => settings.summary.style === "concise");
  await ready();
  assert(patches.at(-1)?.summary.style === "concise", "Shared style was not saved");

  // A notification starts an old GET while PATCH is in flight. Its response must not undo the save.
  patchGate = gate();
  await choose("Summary style", "standard");
  await until(() => patches.at(-1)?.summary?.style === "standard");
  const staleRead = gate(); readGate = staleRead; readStarted = false;
  window.dispatchEvent(new Event(liveDataEvent));
  await until(() => readStarted);
  patchGate.release(); patchGate = undefined;
  await until(() => select("Summary style").value === "standard");
  staleRead.release();
  await ready();
  assert(select("Summary style").value === "standard", "Old GET overwrote PATCH");
  assert(modelReads === 1, "Settings updates reloaded models");

  settings.outputLanguage = "fr";
  window.dispatchEvent(new Event(liveDataEvent));
  await until(() => select("Output language").value === "fr");
  await ready();
  failPatch = true;
  await choose("Summary style", "detailed");
  await until(() => document.querySelector('[role="alert"]'));
  await ready();
  assert(select("Summary style").value === "standard", "Failed save discarded confirmed settings");
  failPatch = false;
  await choose("Summary style", "detailed");
  await until(() => select("Summary style").value === "detailed");
  await ready();
  assert(!document.querySelector('[role="alert"]'), "Retry did not clear the save error");
  assert(modelReads === 1, "Retry reloaded models");
  document.getElementById("result")!.textContent = "PASS: local fallback, unavailable summary model, remote summary method, stale GET, settings notification, failed save/retry, stable model catalog";
}
void run().catch((error: unknown) => { document.getElementById("result")!.textContent = `FAIL: ${String(error)}`; console.error(error); });
