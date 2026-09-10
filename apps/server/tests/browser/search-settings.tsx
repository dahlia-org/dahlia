// pnpm dev:client -> /tests/browser/search-settings.html. Uses an in-memory API, never a live backend.
import { createRoot } from "react-dom/client";
import { AdminSearchSettings } from "../../src/client/App";
import { DEFAULT_SEARCH_SETTINGS, searchSettingsSchema } from "../../src/search/settings-model";
import "../../src/client/styles.css";

Object.defineProperty(navigator, "language", { value: "en-US", configurable: true });
let saved = { ...DEFAULT_SEARCH_SETTINGS };
let failSave = false;
let writes = 0;
window.fetch = async (input, init) => {
  const request = input instanceof Request ? input : new Request(new URL(input, location.origin), init);
  if (new URL(request.url).pathname !== "/api/v1/admin/search-settings") throw new Error("Unexpected request");
  if (request.method === "PUT") {
    writes++;
    if (failSave) return Response.json({ error: "save_failed" }, { status: 503 });
    saved = searchSettingsSchema.parse(await request.json());
  }
  return Response.json(saved);
};
function assert(value: unknown, message: string): asserts value { if (!value) throw new Error(message); }
async function until(predicate: () => unknown) {
  const deadline = performance.now() + 5000;
  while (!predicate()) {
    if (performance.now() > deadline) throw new Error("Timed out waiting for search settings");
    await new Promise(requestAnimationFrame);
  }
}
function title() { return document.querySelector<HTMLInputElement>('input[type="number"]')!; }
function type(value: string) {
  Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(title(), value);
  title().dispatchEvent(new Event("input", { bubbles: true }));
}
async function run() {
  const root = createRoot(document.getElementById("root")!);
  const render = (key: number) => root.render(<main style={{ padding: 24 }}><AdminSearchSettings key={key} /></main>);
  render(0);
  await until(() => document.querySelectorAll('input[type="number"]').length === 6);
  assert([...document.querySelectorAll<HTMLInputElement>("input")].map((input) => input.value).join(",") === "5,3,2,1,1,2", "Wrong defaults");
  assert(title().labels?.[0]?.textContent === "Title", "Missing accessible label");
  const form = () => document.querySelector("form")!;
  type("11"); await new Promise(requestAnimationFrame);
  assert(!form().checkValidity(), "Out-of-range weight accepted");
  type("1.5"); await new Promise(requestAnimationFrame);
  assert(!form().checkValidity(), "Fractional weight accepted");
  type("9"); await new Promise(requestAnimationFrame);
  form().requestSubmit();
  await until(() => document.querySelector('[role="status"]')?.textContent === "Search settings saved.");
  assert(saved.title === 9 && writes === 1, "Save did not reach the API");
  const previousInput = title();
  render(1); await until(() => title() && title() !== previousInput && title().value === "9");
  document.querySelector<HTMLButtonElement>('button[type="button"]')!.click();
  await until(() => title().value === "5");
  assert(saved.title === 9, "Reset saved without submitting");
  failSave = true;
  form().requestSubmit(); await until(() => document.querySelector('[role="alert"]'));
  assert(saved.title === 9 && title().value === "5", "Failed save lost the draft or changed saved settings");
  failSave = false;
  form().requestSubmit(); await until(() => document.querySelector('[role="status"]')?.textContent === "Search settings saved.");
  assert(Number(saved.title) === 5 && !document.querySelector('[role="alert"]'), "Retry failed");
  document.getElementById("result")!.textContent = "PASS: six defaults, accessible labels, integer limits, save/reload, reset, failed save/retry";
}
void run().catch((error: unknown) => { document.getElementById("result")!.textContent = `FAIL: ${String(error)}`; console.error(error); });
