// pnpm dev:client -> /tests/browser/knowledge-pages.html; synthetic data only.
import { createRoot } from "react-dom/client";
import { KnowledgePages } from "@dahlia-ai/ui/screens/KnowledgePages";
import { refreshData } from "@dahlia-ai/ui/api/live-data";
import type { KnowledgePage } from "../../src/memory/pages-model";
import "@dahlia-ai/ui/styles.css";
Object.defineProperty(navigator, "language", { value: "en-US", configurable: true });
const body = 'Synthetic hypothesis <img src="https://invalid.example/track" onerror="alert(1)">';
let page: KnowledgePage = { id: "workspace-insights", workspaceId: "team", projectId: null, title: "Team overview", status: "ready", coverage: "partial", skippedCount: 1, canRefresh: true,
  generatedAt: "2026-09-28T00:00:00Z", body, snippet: "Synthetic hypothesis", instruction: "Synthetic instruction",
  sources: [{ kind: "meeting", id: "meeting", revision: "1", href: "/o/meeting", canonicalExcerpt: "Canonical evidence", truncated: false }] };
let regenerations = 0, forbidden = false, listForbidden = false, projectFilter: string | null = null;
let validation: Promise<void> | undefined;
window.fetch = async (input, init) => {
  if (validation) await validation;
  const request = input instanceof Request ? input : new Request(new URL(input, location.origin), init);
  const path = new URL(request.url).pathname;
  if (listForbidden && path.endsWith("/pages")) return Response.json({ error: "workspace_not_found" }, { status: 404 });
  if (request.method === "POST") assert(await request.text() === "", "Regeneration sent a custom body");
  if (forbidden) return Response.json({ error: "workspace_not_found" }, { status: 404 });
  if (path.endsWith("/projects")) return Response.json({ items: [{ projectId: "project_synthetic", name: "Synthetic project" }] });
  if (path.endsWith("/refresh")) { regenerations++; page = { ...page, status: "generating", body: null, snippet: null, sources: [], generatedAt: null }; return Response.json({ status: "generating" }, { status: 202 }); }
  if (path.endsWith("/pages")) { projectFilter = new URL(request.url).searchParams.get("projectId"); return Response.json({ items: [{ ...page, body: null, sources: [] }], nextCursor: null }); }
  return Response.json(page);
};
const button = (label: string) => [...document.querySelectorAll<HTMLButtonElement>("button")].find((b) => b.textContent === label);
function assert(value: unknown, message: string): asserts value { if (!value) throw new Error(message); }
async function until(predicate: () => unknown) {
  const start = performance.now();
  while (!predicate()) { if (performance.now() - start > 5000) throw new Error("UI timed out"); await new Promise(requestAnimationFrame); }
}
createRoot(document.getElementById("root")!).render(<KnowledgePages workspaceId="team" />);
async function run() {
  await until(() => document.querySelector('option[value="project_synthetic"]'));
  const project = document.querySelector("select")!;
  project.value = "project_synthetic"; project.dispatchEvent(new Event("change", { bubbles: true }));
  await until(() => projectFilter === "project_synthetic");
  project.value = ""; project.dispatchEvent(new Event("change", { bubbles: true }));
  await until(() => projectFilter === null);
  await until(() => button("Team overview")); button("Team overview")!.click();
  await until(() => document.body.textContent.includes("Canonical evidence"));
  assert(document.body.textContent.includes("AI-generated summaries and hypotheses"), "Missing generated label");
  assert(document.body.textContent.includes("Partial ingestion: 1 skipped sources"), "Missing coverage");
  assert(document.querySelector('a[href="/o/meeting"]'), "Missing canonical link");
  assert(document.querySelector('a[download]') && document.querySelector("time"), "Missing export or generation time");
  assert(document.body.textContent.includes(body) && !document.querySelector("img"), "Generated HTML executed");
  assert(!document.querySelector("textarea"), "Unexpected generated-body editor");
  if (new URLSearchParams(location.search).has("preview")) { document.getElementById("result")!.textContent = "PASS: safe text, sources, partial, export and regeneration control"; return; }
  let finishValidation!: () => void;
  validation = new Promise<void>((resolve) => { finishValidation = resolve; });
  refreshData();
  await until(() => document.body.textContent.includes("Validating pages…") && document.body.textContent.includes("Validating page…"));
  assert(!document.body.textContent.includes("Synthetic hypothesis") && !document.body.textContent.includes("Canonical evidence"), "Revalidation kept cached content");
  finishValidation(); validation = undefined;
  await until(() => document.body.textContent.includes("Canonical evidence"));
  button("Regenerate page")!.click();
  await until(() => regenerations === 1 && document.body.textContent.includes("Generating / validating"));
  assert(!document.body.textContent.includes(body) && !document.querySelector("a[download]"), "Generating leaked old content");
  for (const status of ["stale", "source_invalid", "paused", "unavailable", "error", "no_sources"] as const) {
    page = { ...page, status }; refreshData();
    await until(() => button("Team overview") && !document.body.textContent.includes("Validating page…"));
    assert(!document.body.textContent.includes(body), `Leaked content: ${status}`);
  }
  page = { ...page, status: "ready", body, canRefresh: false }; refreshData();
  await until(() => document.body.textContent.includes(body));
  assert(!button("Regenerate page"), "Viewer can regenerate");
  listForbidden = true; refreshData();
  await until(() => document.querySelector('[role="alert"]'));
  assert(!document.body.textContent.includes(body) && !document.querySelector("a[download]"), "List revocation kept detail content");
  listForbidden = false; refreshData();
  await until(() => document.body.textContent.includes(body));
  forbidden = true; refreshData();
  await until(() => document.querySelector('[role="alert"]'));
  assert(!document.body.textContent.includes(body), "Revocation kept cached content");
  document.getElementById("result")!.textContent = "PASS: all page states, safe text, canonical links, partial coverage, admin regeneration and revocation";
}
void run().catch((error: unknown) => { document.getElementById("result")!.textContent = `FAIL: ${String(error)}`; });
