// Run with pnpm dev:client, then open /tests/browser/live-data.html.
// All API responses and mutations are local fixtures; no backend is contacted.
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "../../src/client/App";
import "../../src/client/styles.css";

Object.defineProperty(navigator, "language", { value: "en-US", configurable: true });
sessionStorage.removeItem("dahlia:sidebar:browser-fixture:organization");

const base = "/api/v1/vaults/v1";
const route = "/vaults/v1/meetings/m1";
const sources: EventTarget[] = [];
const requests: string[] = [];
const requestURLs: string[] = [];
const failures = new Map<string, number>();
const answers: string[] = [];
let caption = "Initial caption";
let summary = "Initial summary";
let transcript = "Initial transcript";
let fileCount = 3;
let sharingEnabled = false;
let meetingName = "Recording meeting";
const vault = { vaultId: "v1", name: "Test Vault", role: "owner", revision: 1, createdAt: "2026-09-07T00:00:00Z" };
const projects = Array.from({ length: 40 }, (_, index) => ({ projectId: `p${index}`, name: `Project ${index}`, path: `Project ${index}`, revision: 1, directMeetingCount: 0, subtreeMeetingCount: 0 }));
const meeting = (id: string) => ({ meetingId: id, vaultId: "v1", projectId: "p0", name: id === "m1" ? meetingName : "Other meeting", description: "", status: "recording", revision: 1, summaryRevision: 1, createdAt: vault.createdAt, summaryDocument: JSON.stringify({ sections: [{ heading: summary, blocks: [] }] }) });
const image = "data:image/svg+xml," + encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="600" height="400"><rect width="600" height="400" fill="#aaa"/></svg>');
const file = (index: number) => ({ id: `f${index}`, capturedAt: vault.createdAt, file: { id: `f${index}`, content_type: "image/png", variants: { thumb_360: image }, metadata: { source: "screenshot", caption: index === 0 ? caption : `Screenshot ${index}` } } });
window.prompt = () => answers.shift() ?? null;
window.confirm = () => true;
window.EventSource = class extends EventTarget {
  constructor() { super(); sources.push(this); queueMicrotask(() => this.dispatchEvent(new Event("open"))); }
  close() { sources.splice(sources.indexOf(this), 1); }
} as unknown as typeof EventSource;
window.fetch = (input, init) => Promise.resolve((() => {
  const url = new URL(typeof input === "string" ? input : input instanceof URL ? input.href : input.url, location.origin);
  requests.push(url.pathname);
  requestURLs.push(url.pathname + url.search);
  const failure = failures.get(url.pathname);
  if (failure) return Response.json({ error: `fixture_${failure}` }, { status: failure });
  if (url.pathname === "/api/session") return Response.json({ user: { id: "browser-fixture", name: "Tester" }, workspace: { id: "w1", type: "personal" }, capabilities: { sync: true, sharing: true, sessions: false, admin: false } });
  if (url.pathname === "/api/v1/organizations") return Response.json([{ id: "o1", name: "Test Organization" }]);
  if (url.pathname === "/api/v1/vaults") return Response.json({ items: [vault] });
  if (url.pathname === "/api/v1/organizations/o1/teams") return Response.json([]);
  if (url.pathname === `${base}/permissions`) return Response.json({ items: sharingEnabled ? [{ principalType: "organization", principalId: "o1", role: "member" }] : [] });
  if (url.pathname === `${base}/permissions/organizations/o1`) {
    sharingEnabled = init?.method === "PUT";
    return new Response(null, { status: 204 });
  }
  if (url.pathname === base) return Response.json(vault);
  if (url.pathname === `${base}/projects`) return Response.json({ items: projects });
  if (url.pathname.startsWith(`${base}/projects/`)) return Response.json(projects.find((p) => p.projectId === url.pathname.split("/").at(-1)));
  if (url.pathname === `${base}/meetings`) return Response.json({ items: (url.searchParams.get("projectId") === "p0" && projects.some((project) => project.projectId === "p0")) || (!url.searchParams.has("projectId") && !url.searchParams.has("projectScope")) ? [meeting("m1"), meeting("m2")] : [] });
  if (url.pathname.endsWith("/transcript")) return Response.json({ items: [{ segmentId: "s1", startTime: vault.createdAt, text: transcript }] });
  if (url.pathname.endsWith("/files")) {
    const offset = Number(url.searchParams.get("cursor") ?? 0);
    const end = Math.min(offset + 12, fileCount);
    return Response.json({ items: Array.from({ length: end - offset }, (_, index) => file(offset + index)), nextCursor: end < fileCount ? String(end) : null });
  }
  if (url.pathname.startsWith(`${base}/meetings/`)) return Response.json(meeting(url.pathname.split("/").at(-1)!));
  if (url.pathname === "/api/v1/transactions") {
    const body = JSON.parse(init?.body as string) as { id: string; operations: { entity: string; action: string; entityId: string; data: { name?: string } }[] };
    for (const op of body.operations) {
      if (op.entity === "meeting") meetingName = op.data.name!;
      if (op.entity === "project" && op.action === "create") projects.push({ ...projects[0]!, projectId: op.entityId, name: op.data.name!, path: op.data.name! });
      if (op.entity === "project" && op.action === "update") Object.assign(projects.find((p) => p.projectId === op.entityId)!, { name: op.data.name!, path: op.data.name! });
      if (op.entity === "project" && op.action === "delete") projects.splice(projects.findIndex((p) => p.projectId === op.entityId), 1);
    }
    return Response.json({ id: body.id, status: "committed" });
  }
  throw new Error(`Unexpected fixture request: ${url.pathname}`);
})());

function assert(value: unknown, message: string): asserts value { if (!value) throw new Error(message); }
async function until(predicate: () => unknown) {
  const deadline = performance.now() + 5000;
  while (!predicate()) {
    if (performance.now() > deadline) throw new Error("Timed out waiting for UI");
    await new Promise(requestAnimationFrame);
  }
}
function button(text: string) {
  const element = [...document.querySelectorAll<HTMLButtonElement>("button")].find((b) => [text, `${text} ⌄`].includes(b.textContent?.trim() ?? ""));
  assert(element, `Missing button: ${text}`);
  return element;
}
function notify(type = "invalidation") { for (const source of sources) source.dispatchEvent(new Event(type)); }
function selectedTab() { return document.querySelector('[role="tab"][aria-selected="true"]')?.textContent; }

async function run() {
  history.replaceState(null, "", route);
  createRoot(document.getElementById("root")!).render(<StrictMode><App /></StrictMode>);
  await until(() => document.querySelector('[role="tab"]') && document.querySelector('.meeting-row a[href="/vaults/v1/meetings/m2"]') && ![...document.querySelectorAll(".sidebar-status")].some((node) => node.textContent?.includes("Loading")));
  await document.fonts.ready;
  button("Screenshots").click();
  await until(() => document.querySelectorAll(".screenshot-grid figure").length === 3);
  const tab = button("Screenshots");
  const img = document.querySelector(".screenshot-grid img");
  const row = document.querySelector('.meeting-row a');
  const sidebar = document.querySelector<HTMLElement>(".sidebar-scroll")!;
  const main = document.querySelector<HTMLElement>(".workspace")!;
  sidebar.scrollTop = 180;
  const sidebarScroll = sidebar.scrollTop;
  const documentNode = document.documentElement;
  const sessionReads = requests.filter((url) => url === "/api/session").length;
  caption = "Updated caption"; summary = "Updated summary"; transcript = "Updated transcript"; fileCount = 4;
  for (let index = 0; index < 20; index++) notify();
  await until(() => document.querySelectorAll(".screenshot-grid figure").length === 4 && document.querySelector("figcaption")?.textContent === caption);
  assert(selectedTab() === "Screenshots", "Tab changed on invalidation");
  assert(tab === button("Screenshots") && img === document.querySelector(".screenshot-grid img"), "Existing tab/image DOM replaced");
  assert(row === document.querySelector('.meeting-row a'), "Sidebar row remounted");
  assert(sidebar.scrollTop === sidebarScroll, `Sidebar scrolled from ${sidebarScroll} to ${sidebar.scrollTop}`);
  assert(documentNode === document.documentElement && main === document.querySelector(".workspace"), "Document/main replaced");
  assert(requests.filter((url) => url === "/api/session").length === sessionReads, "Sync notification refreshed session");
  document.querySelector<HTMLButtonElement>('[aria-label="Expand Project 1"]')?.click();
  await until(() => [...document.querySelectorAll(".sidebar-status")].some((node) => node.textContent === "No meetings"));
  const emptyRow = [...document.querySelectorAll(".sidebar-status")].find((node) => node.textContent === "No meetings")!;
  let releaseEmpty!: () => void;
  let emptyReadStarted = false;
  const emptyRead = new Promise<void>((resolve) => { releaseEmpty = resolve; });
  const fetchBeforeEmpty = window.fetch.bind(window);
  window.fetch = async (input, init) => {
    const response = await fetchBeforeEmpty(input, init);
    if (typeof input === "string" && input.includes("projectId=p1&")) {
      emptyReadStarted = true;
      await emptyRead;
    }
    return response;
  };
  notify();
  await until(() => emptyReadStarted);
  await new Promise(requestAnimationFrame);
  assert(emptyRow.isConnected && emptyRow.textContent === "No meetings", "Empty project row disappeared during refresh");
  window.fetch = fetchBeforeEmpty;
  releaseEmpty();
  button("Transcript").click();
  await until(() => document.querySelector(".transcript-document")?.textContent?.includes(transcript));
  button("Summary").click();
  await until(() => document.querySelector(".summary-document")?.textContent?.includes(summary));
  button("Screenshots").click();
  fileCount = 26; notify();
  await until(() => document.querySelectorAll(".screenshot-grid figure").length === 12);
  button("Load more").click();
  await until(() => document.querySelectorAll(".screenshot-grid figure").length === 24);
  window.scrollTo(0, 300);
  await until(() => [...document.querySelectorAll<HTMLImageElement>(".screenshot-grid img")].every((img) => {
    const rect = img.getBoundingClientRect();
    return rect.bottom <= 0 || rect.top >= innerHeight || img.complete;
  }));
  const mainScroll = window.scrollY;
  assert(mainScroll > 0, "Main scroll fixture did not scroll");
  caption = "Reconnected"; notify("open");
  await until(() => document.querySelector("figcaption")?.textContent === caption);
  assert(document.querySelectorAll(".screenshot-grid figure").length === 24, "Loaded range collapsed");
  assert(window.scrollY === mainScroll, `Main scrolled from ${mainScroll} to ${window.scrollY}`);
  fileCount = 13; caption = "After deletion"; notify();
  await until(() => document.querySelectorAll(".screenshot-grid figure").length === 13);
  assert(![...document.querySelectorAll("button")].some((b) => b.textContent === "Load more"), "Deleted tail left a stale cursor");
  failures.set("/api/v1/vaults", 503);
  failures.set(`${base}/meetings/m1`, 503); notify();
  await until(() => document.querySelector('[role="alert"]')?.textContent?.includes("fixture_503"));
  assert(selectedTab() === "Screenshots", "Transient failure unmounted tabs");
  assert(row === document.querySelector('.meeting-row a'), "Sidebar refresh failure replaced the tree");
  failures.clear();
  for (const retry of [...document.querySelectorAll<HTMLButtonElement>("button")].filter((b) => b.textContent === "Retry")) retry.click();
  await until(() => !document.querySelector('[role="alert"]'));
  failures.set("/api/v1/transactions", 409);
  answers.push("Failed edit", "Description");
  button("⋯ Actions").click(); button("Edit Meeting").click();
  await until(() => document.querySelector('.meeting-detail > [role="alert"]')?.textContent?.includes("fixture_409"));
  failures.clear();
  answers.push("Edited meeting", "Description");
  button("Edit Meeting").click();
  await until(() => document.querySelector(".meeting-header h1")?.textContent === "Edited meeting");
  assert(!document.querySelector('.meeting-detail > [role="alert"]'), "Successful meeting retry retained an old error");
  assert(selectedTab() === "Screenshots", "Editing reset tab");
  assert(requests.filter((url) => url === "/api/session").length === sessionReads, "Transaction refreshed session");
  let release!: () => void;
  const held = new Promise<void>((resolve) => { release = resolve; });
  const heldSignals: AbortSignal[] = [];
  const normalFetch = window.fetch.bind(window);
  window.fetch = async (input, init) => {
    const response = await normalFetch(input, init);
    if (input === `${base}/meetings/m1`) {
      if (init?.signal) heldSignals.push(init.signal);
      await held; // Deliberately ignore abort to exercise stale completion guards.
    }
    return response;
  };
  notify();
  await until(() => heldSignals.length >= 2);
  document.querySelector<HTMLAnchorElement>('a[href="/vaults/v1/meetings/m2"]')!.click();
  await until(() => document.querySelector(".meeting-header h1")?.textContent === "Other meeting");
  assert(selectedTab() === "Summary", "Different meeting did not reset tab");
  assert(heldSignals.every((signal) => signal.aborted), "Obsolete detail/sidebar reads were not aborted");
  window.fetch = normalFetch;
  release();
  await new Promise(requestAnimationFrame);
  assert(document.querySelector(".meeting-header h1")?.textContent === "Other meeting", "Stale response overwrote current meeting");
  history.back();
  await until(() => document.querySelector(".meeting-header h1")?.textContent === "Edited meeting");
  history.forward();
  await until(() => document.querySelector(".meeting-header h1")?.textContent === "Other meeting");
  document.querySelector<HTMLAnchorElement>('a[href="/vaults/v1"]')!.click();
  await until(() => document.querySelector('input[aria-label="Search meetings"]'));
  await until(() => document.querySelector<HTMLInputElement>(".share-row input"));
  const shareCheckbox = document.querySelector<HTMLInputElement>(".share-row input")!;
  assert(!shareCheckbox.checked, "Sharing fixture started enabled");
  sharingEnabled = true;
  notify();
  await until(() => shareCheckbox.checked);
  assert(shareCheckbox === document.querySelector(".share-row input"), "Sharing update replaced checkbox");
  shareCheckbox.click();
  await until(() => !shareCheckbox.checked && !sharingEnabled);
  const search = document.querySelector<HTMLInputElement>('input[aria-label="Search meetings"]')!;
  Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(search, "recording");
  search.dispatchEvent(new Event("input", { bubbles: true }));
  await until(() => requestURLs.some((url) => url.includes("q=recording")));
  notify();
  await new Promise(requestAnimationFrame);
  assert(search.value === "recording", "Live refresh reset search input");
  const filter = document.querySelector("select")!;
  filter.value = "p0"; filter.dispatchEvent(new Event("change", { bubbles: true }));
  await until(() => requestURLs.some((url) => url.includes("q=recording&projectId=p0")));
  failures.set(`${base}/projects`, 503); notify();
  await until(() => document.querySelector(".workspace .error")?.textContent?.includes("fixture_503"));
  assert(filter.value === "p0", "Transient Project failure reset filter");
  failures.clear(); notify();
  await until(() => !document.querySelector(".workspace .error"));
  assert(filter.value === "p0", "Refresh reset valid Project filter");
  const removedProjects = projects.splice(0);
  notify();
  await until(() => !document.querySelector('[aria-label="Filter by Project"]') && document.querySelector('.workspace a[href="/vaults/v1/meetings/m1"]'));
  assert(search.value === "recording", "Deleted Project reset search text");
  projects.push(...removedProjects); notify();
  await until(() => document.querySelector('[aria-label="Filter by Project"]'));
  assert(document.querySelector("select")!.value === "", "Deleted Project filter was restored");
  answers.push("New project"); button("New Project").click();
  await until(() => document.querySelector("h1")?.textContent === "New project");
  failures.set("/api/v1/transactions", 409);
  answers.push("Failed project edit", "Description"); button("Edit Project").click();
  await until(() => document.querySelector(".workspace .error")?.textContent?.includes("fixture_409"));
  failures.clear();
  answers.push("Edited project", "Description"); button("Edit Project").click();
  await until(() => document.querySelector("h1")?.textContent === "Edited project");
  assert(!document.querySelector(".workspace .error"), "Successful project retry retained an old error");
  button("Delete Project").click();
  await until(() => location.pathname === "/vaults/v1");
  document.querySelector<HTMLButtonElement>('[popoverTarget="account-menu"]')!.click();
  button("Test Organization").click();
  await until(() => location.pathname === "/vaults" && requests.some((url) => url === "/api/v1/vaults"));
  assert(documentNode === document.documentElement, "Organization switch reloaded document");
  document.querySelector<HTMLAnchorElement>('a[href="/vaults/v1/meetings/m1"]')?.click();
  // Use the existing internal navigation helper when the newly scoped tree is still loading.
  const { navigateDashboard } = await import("../../src/client/navigation");
  navigateDashboard(route);
  await until(() => document.querySelector('[role="tab"]'));
  failures.set(`${base}/meetings/m1`, 403); notify();
  await until(() => !document.querySelector('[role="tab"]'));
  assert(document.querySelector('[role="alert"]')?.textContent?.includes("fixture_403"), "Missing access-denied feedback");
  failures.clear();
  for (const retry of [...document.querySelectorAll<HTMLButtonElement>("button")].filter((b) => b.textContent === "Retry")) retry.click();
  await until(() => document.querySelector('[role="tab"]'));
  failures.set(`${base}/meetings/m1`, 404); notify();
  await until(() => !document.querySelector('[role="tab"]'));
  assert(document.querySelector('[role="alert"]')?.textContent?.includes("fixture_404"), "Deleted meeting remained visible");
  document.body.dataset.testResult = "passed";
  console.log("PASS: live data, DOM identity, scroll, paging, retries, edits, history, create/delete, organization, access revocation");
}
void run().catch((error: unknown) => {
  document.body.dataset.testResult = "failed";
  document.body.dataset.testError = String(error);
  console.error(error);
});
