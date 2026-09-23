// pnpm dev:client -> /tests/browser/dahlia-memory.html. No real user data.
import { createRoot } from "react-dom/client";
import { DahliaMemoryPage } from "../../src/client/DahliaMemory";
import { emptyPreferences } from "../../src/agent/context-model";
import "../../src/client/styles.css";
Object.defineProperty(navigator, "language", { value: "en-US", configurable: true });
type Note = { id: string; content: string; revision: number; protected: boolean; updatedAt: string };
const rows: Record<string, Note[]> = { personal: [{ id: "test", content: "Private lesson", revision: 1, protected: true, updatedAt: new Date().toISOString() }], team: [] };
const writes: Array<{ scope: string; workspaceId?: string; explicit: boolean }> = [];
let failSave = false;
window.fetch = async (input, init) => {
  const request = input instanceof Request ? input : new Request(new URL(input, location.origin), init);
  const path = new URL(request.url).pathname;
  if (path.endsWith("/preferences")) return Response.json({ revision: 0, automatic: true, preferences: emptyPreferences });
  if (path.endsWith("/scopes")) return Response.json({ scopes: [{ scope: "personal", name: "Personal", writable: true }, { scope: "workspace", workspaceId: "team", name: "Team", writable: true }] });
  const body: { scope: string; workspaceId?: string; content: string; id: string; revision: number; explicit: boolean } = await request.json();
  const key = body.scope === "personal" ? "personal" : body.workspaceId!;
  if (path.endsWith("/list")) return Response.json({ items: rows[key], nextCursor: null });
  if (path.endsWith("/status")) return Response.json({ enabled: false, status: "unavailable", skippedCount: 0 });
  if (path.endsWith("/save")) {
    if (failSave) return Response.json({ error: "memory_revision_conflict" }, { status: 409 });
    writes.push(body); rows[key] = [...rows[key]!.filter((n) => n.id !== body.id), { ...body, protected: true, revision: body.revision + 1, updatedAt: new Date().toISOString() }];
    return Response.json({ saved: true });
  }
  if (path.endsWith("/delete")) { writes.push(body); rows[key] = rows[key]!.filter((n) => n.id !== body.id); return Response.json({ deleted: true }); }
  if (path.endsWith("/reflect")) return Response.json({ results: [{ result: { hypothesis: "Possible lesson", coverage: "partial", sources: [{ id: "test", canonicalExcerpt: "Verified source", truncated: false }] } }] });
  throw new Error(`Unexpected test path ${path}`);
};
const button = (label: string) => [...document.querySelectorAll<HTMLButtonElement>("button")].find((b) => b.textContent === label)!;
function assert(value: unknown, message: string): asserts value { if (!value) throw new Error(message); }
async function until(predicate: () => unknown) {
  const start = performance.now();
  while (!predicate()) { if (performance.now() - start > 5000) throw new Error("UI timed out"); await new Promise(requestAnimationFrame); }
}
function text(input: HTMLInputElement | HTMLTextAreaElement, value: string) {
  const prototype = input instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
  Object.getOwnPropertyDescriptor(prototype, "value")!.set!.call(input, value);
  input.dispatchEvent(new Event("input", { bubbles: true }));
}
createRoot(document.getElementById("root")!).render(<DahliaMemoryPage />);
async function run() {
  await until(() => button("Edit"));
  assert(document.body.textContent.includes("Personal · Only you"), "Private audience missing");
  button("Edit").click(); await until(() => document.querySelector("textarea"));
  text(document.querySelector("textarea")!, "Corrected private lesson");
  failSave = true; await until(() => !button("Save").disabled); button("Save").click();
  await until(() => document.querySelector("[role=dialog] [role=alert]"));
  assert(document.querySelector("textarea")!.value === "Corrected private lesson", "Conflict discarded edit");
  failSave = false; button("Save").click(); await until(() => !document.querySelector("[role=dialog]"));
  await until(() => document.body.textContent.includes("Corrected private lesson"));
  const share = document.querySelectorAll("select")[1]!; share.value = "team"; share.dispatchEvent(new Event("change", { bubbles: true }));
  await until(() => document.querySelector("[role=dialog]"));
  assert(document.querySelector("[role=dialog]")!.textContent.includes("Share with members of Team"), "Sharing audience missing");
  assert(rows.team!.length === 0, "Sharing occurred before confirmation");
  button("Save").click(); await until(() => !document.querySelector("[role=dialog]"));
  assert(rows.personal!.length === 1 && Number(rows.team!.length) === 1, "Copy changed source");
  const scope = document.querySelector("select")!; scope.value = "team"; scope.dispatchEvent(new Event("change", { bubbles: true }));
  await until(() => document.body.textContent.includes("Team · Shared") && button("Delete"));
  const query = document.querySelector<HTMLInputElement>("section form input")!; text(query, "lesson");
  await until(() => !button("Insights").disabled); button("Insights").click();
  await until(() => document.body.textContent.includes("Verified source"));
  assert(document.body.textContent.includes("Interpretation · verify sources"), "Hypothesis not labelled");
  button("Delete").click(); await until(() => document.querySelector("[data-confirm]"));
  (document.querySelector("[data-confirm]") as HTMLButtonElement).click();
  await until(() => !document.querySelector("[role=dialog]") && rows.team!.length === 0);
  assert(writes.every((w) => w.explicit), "Missing explicit confirmation");
  document.getElementById("result")!.textContent = "PASS: scope, conflict preservation, explicit sharing copy, sources and deletion";
}
void run().catch((error: unknown) => { document.getElementById("result")!.textContent = `FAIL: ${String(error)}`; });
