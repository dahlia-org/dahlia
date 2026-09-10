// Run pnpm dev:client and open /tests/browser/account-settings.html. No backend is contacted.
import { createRoot } from "react-dom/client";
import { ServerSummarySettings } from "../../src/client/SummaryGeneration";
import { DEFAULT_ACCOUNT_SETTINGS, accountSettingsSchema, type AccountSettingsPatch } from "../../src/account-settings-model";
import { accountSettingsEvent } from "../../src/client/live-data";
import { modelList } from "../../src/ai-gateway/models";
import "../../src/client/styles.css";

Object.defineProperty(navigator, "language", { value: "en-US", configurable: true });
let settings = structuredClone(DEFAULT_ACCOUNT_SETTINGS);
settings.processing.location = "remote";
let remoteCapability = false;
let modelReads = 0;
let failPatch = false;
let patchGate: ReturnType<typeof gate> | undefined;
let readGate: ReturnType<typeof gate> | undefined;
const patches: AccountSettingsPatch[] = [];
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
    return Response.json(modelList([{ id: "gpt-5.4" }, { id: "gemini-3-8-flash" }]));
  }
  if (path !== "/api/v1/account/settings") throw new Error(`Unexpected fixture request ${path}`);
  if (request.method === "PATCH") {
    const patch: AccountSettingsPatch = await request.json();
    patches.push(patch);
    if (failPatch) return Response.json({ error: "save_failed" }, { status: 503 });
    await patchGate?.promise;
    const remote = { ...settings.processing.remote, ...patch.processing?.remote };
    for (const key of ["summaryModel", "transcriptionModel", "reasoningEffort"] as const) {
      if (remote[key] === null) delete remote[key];
    }
    settings = accountSettingsSchema.parse({ ...settings, ...patch,
      summary: { ...settings.summary, ...patch.summary },
      processing: { ...settings.processing, ...patch.processing, remote },
    });
    return Response.json({ settings });
  }
  const snapshot = structuredClone(settings);
  const waiting = readGate;
  readGate = undefined;
  readStarted = true;
  await waiting?.promise;
  return Response.json({ settings: snapshot });
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
function choose(label: string, value: string) {
  const element = select(label);
  assert(!element.matches(":disabled"), `${label} is disabled`);
  element.click();
  const option = document.getElementById(element.getAttribute("aria-controls")!)?.querySelector<HTMLButtonElement>(`button[value="${value}"]`);
  assert(option, `Missing option ${value}`);
  option.click();
}
async function ready() { await until(() => document.querySelector<HTMLButtonElement>('[role="combobox"]') && !select("Output language").matches(":disabled")); }
async function run() {
  const first = createRoot(document.getElementById("root")!);
  first.render(<ServerSummarySettings />);
  await ready();
  choose("Processing location", "local");
  await until(() => settings.processing.location === "local");
  first.unmount();

  remoteCapability = true;
  settings.processing.location = "remote";
  settings.processing.remote.transcriptionModel = "catalog.ai.unavailable";
  createRoot(document.getElementById("root")!).render(<ServerSummarySettings />);
  await ready();
  await until(() => document.querySelectorAll('[role="combobox"]').length >= 5 && modelReads === 1);
  document.querySelector("details")!.open = true;
  assert(select("Transcription model").value === "catalog.ai.unavailable", "Unavailable explicit choice was silently replaced");
  choose("Transcription model", "gemini-3-8-flash");
  await until(() => settings.processing.remote.transcriptionModel === "gemini-3-8-flash");
  await ready();
  choose("Summary style", "concise");
  await until(() => settings.summary.style === "concise");
  await ready();
  assert(JSON.stringify(patches.at(-1)) === '{"summary":{"style":"concise"}}', "Style PATCH must be account scoped");

  // A notification starts an old GET while PATCH is in flight. Its response must not undo the save.
  patchGate = gate();
  choose("Summary style", "standard");
  await until(() => patches.at(-1)?.summary?.style === "standard");
  const staleRead = gate(); readGate = staleRead; readStarted = false;
  window.dispatchEvent(new Event(accountSettingsEvent));
  await until(() => readStarted);
  patchGate.release(); patchGate = undefined;
  await until(() => select("Summary style").value === "standard");
  staleRead.release();
  await ready();
  assert(select("Summary style").value === "standard", "Old GET overwrote PATCH");
  assert(modelReads === 1, "Settings updates reloaded models");

  settings.outputLanguage = "fr";
  window.dispatchEvent(new Event(accountSettingsEvent));
  await until(() => select("Output language").value === "fr");
  await ready();
  failPatch = true;
  choose("Summary style", "detailed");
  await until(() => document.querySelector('[role="alert"]'));
  await ready();
  assert(select("Summary style").value === "standard", "Failed save discarded confirmed settings");
  failPatch = false;
  choose("Summary style", "detailed");
  await until(() => select("Summary style").value === "detailed");
  await ready();
  assert(!document.querySelector('[role="alert"]'), "Retry did not clear the save error");
  assert(modelReads === 1, "Retry reloaded models");
  document.getElementById("result")!.textContent = "PASS: local fallback, invalid transcription model, remote detail, stale GET, settings notification, failed save/retry, stable model catalog";
}
void run().catch((error: unknown) => { document.getElementById("result")!.textContent = `FAIL: ${String(error)}`; console.error(error); });
