// Run pnpm dev:client and open /tests/browser/summary-generation.html. No backend is contacted.
import { createRoot } from "react-dom/client";
import "../../src/client/styles.css";
import { ServerSummaryGeneration } from "../../src/client/SummaryGeneration";
import { DEFAULT_WORKSPACE_GENERATION_SETTINGS, type WorkspaceGenerationSettings } from "../../src/workspace-generation-settings";
import { cloudflareModels } from "../../src/ai-gateway/cloudflare";
import type { SummaryRequest } from "../../src/summary/service";

Object.defineProperty(navigator, "language", { value: "en-US", configurable: true });
const base = "/api/v1/meetings/meeting";
let uploaded = false;
let reject = true;
let transcriptVersion = 1;
let phase = "initializing";
const bodies: SummaryRequest[] = [];
const settings: WorkspaceGenerationSettings = {
  ...DEFAULT_WORKSPACE_GENERATION_SETTINGS, processing: { ...DEFAULT_WORKSPACE_GENERATION_SETTINGS.processing, location: "remote", remote: {
    ...DEFAULT_WORKSPACE_GENERATION_SETTINGS.processing.remote,
    summaryModel: "gemini-3-flash",
    reasoningEffort: "high",
  } },
};
window.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
  await Promise.resolve();
  const request = input instanceof Request ? input : new Request(new URL(input, location.origin), init);
  const path = new URL(request.url).pathname;
  if (path === "/api/v1/capabilities") return Response.json({
    meetingSummaryGeneration: { version: 2, sources: ["transcript", "audio"], completeRecordings: true },
  });
  if (path === "/api/v1/workspaces/workspace") return Response.json({ workspaceId: "workspace", generationSettings: settings, role: "editor" });
  if (path === "/api/v1/models") return Response.json(cloudflareModels(["gpt-4.1", "gemini-3-flash"]));
  if (path.endsWith("/transcripts/latest")) return Response.json({
    formatVersion: 1, version: transcriptVersion, entityId: "meeting", present: true, count: 1, byteCount: 10,
    sha256: "test", entity: "transcript", syncRevision: transcriptVersion, transcript: {}, nextCursor: null,
    items: [{ segmentId: "segment", startedAt: "2026-09-09T00:00:00Z", endedAt: null, text: "Transcript", createdAt: null,
      audioSource: null, speakerLabel: null }],
  });
  if (path.endsWith("/recordings")) return Response.json({ items: [{
    audio: uploaded ? { mic: { fileId: "mic" }, system: { fileId: "system" } } : {},
  }], nextCursor: null });
  if (path === `${base}/summary-jobs/latest`) return Response.json({ job: null });
  if (path === `${base}/summary-jobs` && request.method === "POST") {
    bodies.push(await request.json());
    if (reject) return Response.json({ type: "about:blank", title: "Incomplete audio", status: 400, code: "summary_audio_pair_incomplete" }, { status: 400 });
    throw new TypeError("Connection lost after sending request");
  }
  throw new Error(`Unexpected fixture request ${path}`);
});
function assert(value: unknown, message: string): asserts value { if (!value) throw new Error(message); }
async function until(predicate: () => unknown) {
  const deadline = performance.now() + 5000;
  while (!predicate()) {
    if (performance.now() > deadline) throw new Error("Timed out waiting for summary UI");
    await new Promise(requestAnimationFrame);
  }
}
function button() { return [...document.querySelectorAll("button")].find((node) => node.textContent === "Generate summary"); }
async function select(label: string, value: string) {
  phase = `selecting ${label}: ${value}`;
  const field = [...document.querySelectorAll("label")].find((node) => node.childNodes[0]?.textContent === label);
  const trigger = field?.querySelector<HTMLButtonElement>('[role="combobox"]');
  assert(trigger, `Missing ${label} picker`);
  trigger.click();
  await until(() => document.querySelector<HTMLButtonElement>(`[role="option"][value="${value}"]`));
  document.querySelector<HTMLButtonElement>(`[role="option"][value="${value}"]`)!.click();
}
async function start(count: number) {
  phase = `starting request ${count}`;
  await until(() => button() && !button()!.disabled);
  button()!.click();
  await until(() => bodies.length === count && !button()!.disabled);
}
async function run() {
  createRoot(document.getElementById("root")!).render(<ServerSummaryGeneration workspaceId="workspace" meetingId="meeting" />);
  await until(() => document.querySelector<HTMLButtonElement>(".summary-generation-trigger"));
  document.querySelector<HTMLButtonElement>(".summary-generation-trigger")!.click();
  const dialog = document.querySelector<HTMLDialogElement>("dialog")!;
  await until(() => dialog.open);
  dialog.dispatchEvent(new MouseEvent("click", { bubbles: true, detail: 2, clientX: 0, clientY: 0 }));
  assert(dialog.open, "A trigger double-click must not close the dialog through its backdrop");
  await until(() => document.querySelector<HTMLInputElement>('input[value="transcript"]')?.checked);
  const audioInput = document.querySelector<HTMLInputElement>('input[value="audio"]');
  assert(audioInput?.disabled, "Uploading audio must be disabled");
  assert(audioInput.closest("label")?.querySelectorAll("small").length === 1, "Unavailable reason must not change the card height");
  assert(audioInput.closest(".tooltip")?.querySelector('[role="tooltip"]')?.textContent === "Some recording audio is still uploading.",
    "Unavailable reason must be shown as help");
  await select("Summary model", "gpt-4.1");
  const effort = [...document.querySelectorAll("label")].find((node) => node.childNodes[0]?.textContent === "Reasoning effort")
    ?.querySelector<HTMLButtonElement>('[role="combobox"]');
  assert(effort?.value === "", "Changing models must reset reasoning effort to Automatic");
  effort.click();
  const effortMenu = document.getElementById(effort.getAttribute("aria-controls")!);
  const effortDefault = effortMenu?.querySelector<HTMLButtonElement>('[role="option"][value="__default"]');
  assert(effortDefault?.disabled,
    "A reasoning-effort default must stay paired with its Workspace model");
  effortMenu?.querySelector<HTMLButtonElement>('[role="option"][value=""]')?.click();
  await start(1);
  const first = bodies[0];
  assert(first, "First request was not captured");
  assert("input" in first && first.input.type === "transcript" && first.input.version === "1",
    "Latest transcript was not preferred");
  assert("preferences" in first && first.preferences.processing.remote.summaryModel === "gpt-4.1"
    && first.preferences.processing.remote.reasoningEffort === undefined,
  "Changing models must not send the Workspace reasoning effort");
  transcriptVersion = 2; reject = false;
  await start(2);
  const second = bodies[1];
  assert(second, "Second request was not captured");
  assert(second.id !== first.id, "Rejected request ID was reused");
  assert("input" in second && second.input.type === "transcript" && second.input.version === "2",
    "Rejected transcript request was not rebuilt");
  await start(3);
  assert(JSON.stringify(bodies[2]) === JSON.stringify(second), "Uncertain response must preserve the exact idempotent request");
  await select("Summary model", "__default");
  uploaded = true;
  window.dispatchEvent(new Event("dahlia:data-changed"));
  phase = "waiting for uploaded audio";
  await until(() => !document.querySelector<HTMLInputElement>('input[value="audio"]')?.disabled);
  document.querySelector<HTMLInputElement>('input[value="audio"]')!.click();
  await start(4);
  const audioRequest = bodies[3]!;
  assert("input" in audioRequest && audioRequest.input.type === "recording"
    && audioRequest.input.recordings[0]!.systemFileId === "system", "Audio request did not include every recording track");
  assert("preferences" in audioRequest && audioRequest.preferences.processing.remote.workflow === "combined",
    "Audio request did not force combined processing");
  assert("preferences" in audioRequest && audioRequest.preferences.processing.remote.summaryModel === settings.processing.remote.summaryModel
    && audioRequest.preferences.processing.remote.reasoningEffort === settings.processing.remote.reasoningEffort,
  "Explicit model and reasoning effort must remain unchanged");
  await select("Reasoning effort", "high");
  document.querySelector<HTMLInputElement>('input[value="transcript"]')!.click();
  assert([...document.querySelectorAll("label")].find((node) => node.childNodes[0]?.textContent === "Reasoning effort")
    ?.querySelector<HTMLButtonElement>('[role="combobox"]')?.value === "__default", "Changing sources must reset the model-effort pair");
  await start(5);
  const switchedRequest = bodies[4]!;
  assert("preferences" in switchedRequest && switchedRequest.preferences.processing.remote.summaryModel === undefined
    && switchedRequest.preferences.processing.remote.reasoningEffort === undefined,
  "An audio effort must not leak into transcript generation");
  document.getElementById("result")!.textContent = "PASS: source selection, paired defaults, rejected refresh, and uncertain replay";
}
void run().catch((error: unknown) => { document.getElementById("result")!.textContent = `FAIL (${phase}): ${String(error)}`; });
