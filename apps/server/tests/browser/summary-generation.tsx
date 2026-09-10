// Run pnpm dev:client and open /tests/browser/summary-generation.html. No backend is contacted.
import { createRoot } from "react-dom/client";
import { ServerSummaryGeneration } from "../../src/client/SummaryGeneration";
import { DEFAULT_ACCOUNT_SETTINGS, type AccountSettings } from "../../src/account-settings-model";
import type { SummaryRequest } from "../../src/summary/service";

Object.defineProperty(navigator, "language", { value: "en-US", configurable: true });
const base = "/api/v1/meetings/meeting";
let uploaded = false;
let reject = true;
const bodies: SummaryRequest[] = [];
const settings: AccountSettings = {
  ...DEFAULT_ACCOUNT_SETTINGS, processing: { ...DEFAULT_ACCOUNT_SETTINGS.processing, location: "remote" },
};
window.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
  await Promise.resolve();
  const request = input instanceof Request ? input : new Request(new URL(input, location.origin), init);
  const path = new URL(request.url).pathname;
  if (path === "/api/v1/capabilities") return Response.json({ meetingSummaryGeneration: { version: 2, sources: ["transcript", "audio"] } });
  if (path === "/api/v1/account/settings") return Response.json({ settings });
  if (path.endsWith("/recordings")) return Response.json({ items: [{ audio: {
    mic: { fileId: "mic" }, ...(uploaded ? { system: { fileId: "system" } } : {}),
  } }], nextCursor: null });
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
  await start(1);
  uploaded = true; reject = false;
  await start(2);
  assert(bodies[1]!.id !== bodies[0]!.id, "Rejected request ID was reused");
  const retried = bodies[1]!;
  assert("input" in retried && retried.input.type === "recording"
    && retried.input.recordings[0]!.systemFileId === "system", "Retry reused incomplete recording pair");
  uploaded = false;
  await start(3);
  assert(JSON.stringify(bodies[2]) === JSON.stringify(bodies[1]), "Uncertain response must preserve the exact idempotent request");
  document.getElementById("result")!.textContent = "PASS: rejected input refreshed; uncertain request preserved";
}
void run().catch((error: unknown) => { document.getElementById("result")!.textContent = `FAIL: ${String(error)}`; });
