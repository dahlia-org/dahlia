// Run pnpm dev:client and open /tests/browser/sidebar-hover.html. No backend is contacted.
import { StrictMode, useState } from "react";
import { createRoot } from "react-dom/client";
import { AppShell, PageHeader } from "../../src/client/layout/AppShell";
import type { SessionInfo } from "../../src/client/App";
import "../../src/client/styles.css";

Object.defineProperty(navigator, "language", { value: "en-US", configurable: true });
const workspace = { workspaceId: "hover-workspace", name: "Workspace", encryption: "none" };
const project = { projectId: "hover-project", workspaceId: workspace.workspaceId, name: "Project", description: "Project preview", directMeetingCount: 1 };
const nested = { ...project, projectId: "hover-nested", parentProjectId: project.projectId, name: "Nested project" };
const longTitle = "Meeting with a long title that must truncate inside the sidebar instead of widening the entire project hierarchy";
const meeting = { meetingId: "hover-meeting", workspaceId: workspace.workspaceId, projectId: nested.projectId,
  name: longTitle, createdAt: "2026-09-29T00:00:00Z", duration: 1200, description: "Meeting preview" };
const session = { user: { id: "sidebar-hover-test", name: "Tester" }, capabilities: { admin: false, sessions: false, sync: true, sharing: false, ai: false } } as SessionInfo;
const respond = (body: unknown, status = 200) => Promise.resolve(Response.json(body, { status }));
globalThis.fetch = (input) => {
  const url = new URL(typeof input === "string" ? input : input instanceof URL ? input : input.url, location.href);
  if (url.pathname === "/api/v1/workspaces") return respond({ items: [workspace], nextCursor: null });
  if (url.pathname.endsWith("/projects")) return respond({ items: [project, nested], nextCursor: null });
  if (url.pathname.endsWith("/meetings")) return respond({ items: url.searchParams.get("projectId") === nested.projectId ? [meeting] : [], nextCursor: null });
  if (url.pathname === `/api/v1/workspaces/${workspace.workspaceId}`) return respond(workspace);
  return respond({ error: "not found" }, 404);
};
function Fixture() {
  const [path, setPath] = useState("/dashboard/settings");
  return <AppShell brand="Dahlia" session={session} extensionPaths={[]} path={path} navigate={(next) => {
    history.pushState(null, "", next); setPath(next);
  }}><PageHeader title={path === "/dashboard/settings" ? "Account settings" : "Home"} />
    <a href={path === "/dashboard/settings" ? "/dashboard" : "/dashboard/settings"}>Change page</a>
    <div style={{ height: 1400 }}>Sidebar preview positioning regression</div>
  </AppShell>;
}
history.replaceState(null, "", "/dashboard/settings");
for (const id of [project.projectId, nested.projectId]) sessionStorage.removeItem(`dahlia:sidebar:${session.user.id}:${workspace.workspaceId}:${id}`);
createRoot(document.getElementById("root")!).render(<StrictMode><Fixture /></StrictMode>);
const assert = (value: unknown, message: string) => { if (!value) throw new Error(message); };
const until = async (test: () => unknown, label: string) => {
  const deadline = performance.now() + 5000;
  while (performance.now() < deadline) { if (test()) return; await new Promise(requestAnimationFrame); }
  throw new Error(`Timed out: ${label}`);
};
const link = (href: string) => document.querySelector<HTMLAnchorElement>(`.sidebar a[href="${href}"]`)!;
const expand = (name: string) => document.querySelector<HTMLButtonElement>(`.sidebar button[aria-label="Expand ${name}"]`)!.click();
async function checkPreview(target: HTMLElement, label: string) {
  target.focus();
  await until(() => document.getElementById(target.getAttribute("aria-describedby") ?? ""), `${label} preview`);
  const card = document.getElementById(target.getAttribute("aria-describedby")!)!;
  await until(() => card.getAnimations().every((animation) => animation.playState === "finished"), "entry animation");
  const anchor = target.closest('[data-state]')!.getBoundingClientRect();
  const bounds = card.getBoundingClientRect();
  const sidebar = document.querySelector(".sidebar")!.getBoundingClientRect();
  assert(anchor.right <= sidebar.right, `${label} anchor exceeds sidebar: ${anchor.right} > ${sidebar.right}`);
  assert(Math.abs(bounds.left - anchor.right - 6) < 1, `${label} gap is ${bounds.left - anchor.right}, expected 6`);
  assert(bounds.right <= innerWidth && bounds.bottom <= innerHeight, `${label} preview exceeds viewport`);
  target.blur();
  await until(() => !document.getElementById(card.id), `${label} closes`);
}
async function run() {
  await until(() => document.querySelector('.sidebar button[aria-label="Expand Workspace"]'), "workspace loaded");
  expand("Workspace");
  await until(() => link(`/o/${project.projectId}`), "projects loaded");
  await checkPreview(link(`/o/${project.projectId}`), "collapsed project");
  expand("Project");
  await until(() => link(`/o/${nested.projectId}`), "nested project");
  expand("Nested project");
  await until(() => link(`/o/${meeting.meetingId}`), "long meeting loaded");
  await checkPreview(link(`/o/${project.projectId}`), "expanded project");
  await checkPreview(link(`/o/${nested.projectId}`), "nested project");
  await checkPreview(link(`/o/${meeting.meetingId}`), "long meeting");
  document.querySelector<HTMLAnchorElement>("main a")!.click();
  await until(() => document.querySelector("h1")?.textContent === "Home", "page navigation");
  window.scrollTo(0, 400);
  await checkPreview(link(`/o/${project.projectId}`), "project after navigation and scrolling");
  await checkPreview(link(`/o/${meeting.meetingId}`), "meeting after navigation and scrolling");
  window.scrollTo(0, 0);
  document.getElementById("result")!.textContent = "PASS: project and meeting anchors stay within sidebar; 6px preview gap before/after expansion, navigation and scrolling";
  document.body.dataset.testResult = "passed";
}
void run().catch((error: unknown) => {
  document.getElementById("result")!.textContent = `FAIL: ${String(error)}`;
  document.body.dataset.testResult = "failed";
});
