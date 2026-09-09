// Run pnpm dev:client and open /tests/browser/account-settings.html. No backend is contacted.
import { createRoot } from "react-dom/client";
import { ServerSummarySettings } from "../../src/client/SummaryGeneration";
import { DEFAULT_ACCOUNT_SETTINGS, type AccountSettingsPatch } from "../../src/account-settings-model";
import { accountSettingsEvent } from "../../src/client/live-data";
import { modelList } from "../../src/ai-gateway/models";
import "../../src/client/styles.css";

Object.defineProperty(navigator, "language", { value: "en-US", configurable: true });
let settings = structuredClone(DEFAULT_ACCOUNT_SETTINGS);
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
  if (path === "/api/v1/capabilities") return Response.json({ meetingSummaryGeneration: { version: 1, sources: ["transcript", "audio"] } });
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
    settings = { ...settings, ...patch, summary: { ...settings.summary, ...patch.summary,
      methodSettings: { transcript: { ...settings.summary.methodSettings.transcript, ...patch.summary?.methodSettings?.transcript },
        audio: { ...settings.summary.methodSettings.audio, ...patch.summary?.methodSettings?.audio } } } };
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
  createRoot(document.getElementById("root")!).render(<ServerSummarySettings />);
  await ready();
  await until(() => document.querySelectorAll('[role="combobox"]').length === 5 && modelReads === 1);
  choose("Detail", "low");
  await until(() => settings.summary.detail === "low");
  await ready();
  assert(JSON.stringify(patches.at(-1)) === '{"summary":{"detail":"low"}}', "Detail PATCH must be common");
  choose("Summary source", "audio");
  await until(() => settings.summary.method === "audio");
  await ready();
  assert(select("Detail").value === "low", "Switching method changed detail");

  // A notification starts an old GET while PATCH is in flight. Its response must not undo the save.
  patchGate = gate();
  choose("Detail", "medium");
  await until(() => patches.at(-1)?.summary?.detail === "medium");
  const staleRead = gate(); readGate = staleRead; readStarted = false;
  window.dispatchEvent(new Event(accountSettingsEvent));
  await until(() => readStarted);
  patchGate.release(); patchGate = undefined;
  await until(() => select("Detail").value === "medium");
  staleRead.release();
  await ready();
  assert(select("Detail").value === "medium", "Old GET overwrote PATCH");
  assert(modelReads === 1, "Settings updates reloaded models");

  settings.outputLanguage = "fr";
  window.dispatchEvent(new Event(accountSettingsEvent));
  await until(() => select("Output language").value === "fr");
  await ready();
  failPatch = true;
  choose("Detail", "high");
  await until(() => document.querySelector('[role="alert"]'));
  await ready();
  assert(select("Detail").value === "medium", "Failed save discarded confirmed settings");
  failPatch = false;
  choose("Detail", "high");
  await until(() => select("Detail").value === "high");
  await ready();
  assert(!document.querySelector('[role="alert"]'), "Retry did not clear the save error");
  assert(modelReads === 1, "Retry reloaded models");
  document.getElementById("result")!.textContent = "PASS: common detail, method switch, stale GET, settings notification, failed save/retry, stable model catalog";
}
void run().catch((error: unknown) => { document.getElementById("result")!.textContent = `FAIL: ${String(error)}`; console.error(error); });
