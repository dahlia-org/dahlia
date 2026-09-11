// Run pnpm dev:client and open /tests/browser/summary-generation.html. No backend is contacted.
import { createRoot } from "react-dom/client";
import "../../src/client/styles.css";
import { ServerSummaryGeneration } from "../../src/client/SummaryGeneration";
import { DEFAULT_ACCOUNT_SETTINGS, type AccountSettings } from "../../src/account-settings-model";
import { modelList } from "../../src/ai-gateway/models";
import type { SummaryRequest } from "../../src/summary/service";

Object.defineProperty(navigator, "language", { value: "en-US", configurable: true });
const base = "/api/v1/meetings/meeting";
let uploaded = false;
let reject = true;
let transcriptVersion = 1;
const bodies: SummaryRequest[] = [];
const settings: AccountSettings = {
  ...DEFAULT_ACCOUNT_SETTINGS, processing: { ...DEFAULT_ACCOUNT_SETTINGS.processing, location: "remote", remote: {
    ...DEFAULT_ACCOUNT_SETTINGS.processing.remote,
    summaryModel: "gpt-5-6-luna",
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
  if (path === "/api/v1/account/settings") return Response.json({ settings });
  if (path === "/api/v1/models") return Response.json(modelList([{ id: "gpt-5-6-luna" }]));
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
async function start(count: number) {
  await until(() => button() && !button()!.disabled);
  button()!.click();
  await until(() => bodies.length === count && !button()!.disabled);
}
async function run() {
  createRoot(document.getElementById("root")!).render(<ServerSummaryGeneration meetingId="meeting" />);
  await until(() => document.querySelector<HTMLInputElement>('input[value="transcript"]')?.checked);
  assert(document.querySelector<HTMLInputElement>('input[value="audio"]')?.disabled, "Uploading audio must be disabled");
  await start(1);
  const first = bodies[0];
  assert(first, "First request was not captured");
  assert("input" in first && first.input.type === "transcript" && first.input.version === "1",
    "Latest transcript was not preferred");
  assert("preferences" in first && first.preferences.processing.remote.summaryModel === "gpt-5-6-luna",
    "Compatible transcript model was not preserved");
  transcriptVersion = 2; reject = false;
  await start(2);
  const second = bodies[1];
  assert(second, "Second request was not captured");
  assert(second.id !== first.id, "Rejected request ID was reused");
  assert("input" in second && second.input.type === "transcript" && second.input.version === "2",
    "Rejected transcript request was not rebuilt");
  await start(3);
  assert(JSON.stringify(bodies[2]) === JSON.stringify(second), "Uncertain response must preserve the exact idempotent request");
  uploaded = true;
  window.dispatchEvent(new Event("dahlia:data-changed"));
  const audio = document.querySelector<HTMLInputElement>('input[value="audio"]')!;
  await until(() => !audio.disabled);
  audio.click();
  await start(4);
  const audioRequest = bodies[3]!;
  assert("input" in audioRequest && audioRequest.input.type === "recording"
    && audioRequest.input.recordings[0]!.systemFileId === "system", "Audio request did not include every recording track");
  assert("preferences" in audioRequest && audioRequest.preferences.processing.remote.workflow === "combined",
    "Audio request did not force combined processing");
  assert("preferences" in audioRequest && audioRequest.preferences.processing.remote.summaryModel === undefined
    && audioRequest.preferences.processing.remote.reasoningEffort === undefined,
  "Incompatible audio model and reasoning effort were not reset for this run");
  document.getElementById("result")!.textContent = "PASS: source selection, rejected refresh, and uncertain replay";
}
void run().catch((error: unknown) => { document.getElementById("result")!.textContent = `FAIL: ${String(error)}`; });
