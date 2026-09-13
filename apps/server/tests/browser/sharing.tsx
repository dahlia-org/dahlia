// Open /tests/browser/sharing.html with pnpm dev:client. All requests are mocked.
import { createRoot } from "react-dom/client";
import { SidebarProvider, useSidebar } from "../../src/client/Sidebar";
import { WorkspaceSharing } from "../../src/client/WorkspaceSharing";
import type { SyncedWorkspaceInfo } from "../../src/client/api";
import "../../src/client/styles.css";

const targets = [
  { principalType: "organization", principalId: "org", name: "Example Org", detail: "example" },
  { principalType: "team", principalId: "team", name: "Design", detail: "Example Org" },
  { principalType: "user", principalId: "user", name: "Yuki Tanaka", detail: "yuki@example.test" },
  ...Array.from({ length: 51 }, (_, index) => ({ principalType: "team", principalId: `team${index}`, name: "Repeated team", detail: "Example Org" })),
];
const grants = new Map<string, string>([["team50", "viewer"]]);
let fail = false;
window.fetch = async (input, init) => {
  const request = new Request(input instanceof Request ? input : new URL(String(input), location.origin), init);
  const url = new URL(request.url);
  if (url.pathname === "/api/auth/organization/list") return Promise.resolve(Response.json([
    { id: "personal-org", name: "Personal", kind: "personal", slug: "personal-me" },
    { id: "org", name: "Example Org", kind: "team", slug: "example" },
  ]));
  if (url.pathname === "/api/v1/workspaces") return Promise.resolve(Response.json({ items: [] }));
  if (url.pathname.endsWith("/permission-targets")) {
    const q = (url.searchParams.get("q") ?? "").toLowerCase();
    const offset = Number(url.searchParams.get("cursor") ?? 0);
    const groups = ["organization", "team", "user"].map((type) => targets.filter((target) => target.principalType === type
      && `${target.name} ${target.detail}`.toLowerCase().includes(q)));
    return Promise.resolve(Response.json({ items: groups.flatMap((items) => items.slice(offset, offset + 50)),
      nextCursor: groups.some((items) => items.length > offset + 50) ? String(offset + 50) : null }));
  }
  if (url.pathname.endsWith("/permissions")) return Promise.resolve(Response.json({ items: targets.filter((target) => grants.has(target.principalId)).map((target) => ({ ...target, role: grants.get(target.principalId) })) }));
  const target = targets.find((target) => url.pathname.endsWith(`/${target.principalId}`));
  if (!target || !["PUT", "DELETE"].includes(request.method)) throw new Error(`Unexpected request ${request.method} ${url.pathname}`);
  if (fail) return Promise.resolve(Response.json({ error: "test_failed" }, { status: 500 }));
  if (request.method === "PUT") grants.set(target.principalId, (await request.json<{ role: string }>()).role); else grants.delete(target.principalId);
  return Promise.resolve(new Response(null, { status: 204 }));
};
const assert = (ok: unknown, message: string) => { if (!ok) throw new Error(message); };
async function until(predicate: () => unknown) {
  const deadline = performance.now() + 5000;
  while (!predicate()) { if (performance.now() > deadline) throw new Error("Timed out"); await new Promise(requestAnimationFrame); }
}
const pickers = () => [...document.querySelectorAll(".sharing-results select")] as unknown as HTMLSelectElement[];
const choose = (picker: HTMLSelectElement, role: string) => {
  Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, "value")!.set!.call(picker, role);
  picker.dispatchEvent(new Event("change", { bubbles: true }));
};
function ScopeProbe() {
  const { organizationId, select } = useSidebar();
  return <><output id="scope">{organizationId}</output><button id="all-workspaces" onClick={() => select("")}>All Workspaces</button></>;
}
async function run() {
  const workspace: SyncedWorkspaceInfo = { workspaceId: "workspace", organizationId: "org", name: "Shared", role: "admin", revision: 1,
    createdAt: new Date().toISOString(), updatedAt: new Date().toISOString() };
  sessionStorage.removeItem("dahlia:sidebar:me:organization");
  const fixture = <SidebarProvider session={{ user: { id: "me" },
    capabilities: { admin: false, sessions: false, sharing: true, sync: true } }}><ScopeProbe /><WorkspaceSharing workspace={workspace} /></SidebarProvider>;
  let root = createRoot(document.getElementById("root")!);
  root.render(fixture);
  await until(() => document.getElementById("scope")?.textContent === "personal-org");
  document.getElementById("all-workspaces")!.click();
  await until(() => document.getElementById("scope")?.textContent === "");
  root.unmount(); root = createRoot(document.getElementById("root")!); root.render(fixture);
  await until(() => document.getElementById("scope")?.textContent === "");
  await until(() => document.querySelector(".collection-heading button"));
  const opener = document.querySelector<HTMLButtonElement>(".collection-heading button")!;
  opener.focus(); opener.click();
  await until(() => pickers().length === 52);
  assert(document.querySelector("dialog")?.open, "Button opens native modal");
  const search = document.querySelector<HTMLInputElement>('input[type="search"]')!;
  assert(document.activeElement === search, "Search receives focus");
  assert(search.getAttribute("aria-label"), "Search has an accessible name");
  const iconPaths = [...document.querySelectorAll(".sharing-results .share-row > svg path")].map((path) => path.getAttribute("d"));
  assert(new Set(iconPaths).size === 3, "Organizations, teams, and users have distinct icons");
  const searchFor = (value: string) => {
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(search, value);
    search.dispatchEvent(new Event("input", { bubbles: true }));
  };
  searchFor("Repeated team");
  await until(() => pickers().length === 50 && !pickers()[0]!.disabled);
  document.querySelector<HTMLButtonElement>(".sharing-results button")!.click();
  await until(() => pickers().length === 51 && !pickers().at(-1)!.disabled);
  assert(pickers().at(-1)!.value === "viewer", "Existing grant beyond first page is visible");
  choose(pickers().at(-1)!, "");
  await until(() => pickers().at(-1)!.value === "" && !pickers().at(-1)!.disabled);
  assert(!grants.has("team50"), "Grant beyond first page can be revoked");
  searchFor("yuki@");
  await until(() => pickers().length === 1 && !pickers()[0]!.disabled);
  for (const role of ["viewer", "editor", "admin"]) {
    choose(pickers()[0]!, role);
    await until(() => grants.get("user") === role && !pickers()[0]!.disabled);
    assert(pickers()[0]!.value === role, "Selected role is persisted");
  }
  fail = true; choose(pickers()[0]!, "");
  await until(() => document.querySelector('[role="alert"]') && !pickers()[0]!.disabled);
  assert(pickers()[0]!.value === "admin" && grants.has("user"), "Failed revoke preserves existing access");
  fail = false; choose(pickers()[0]!, "");
  await until(() => pickers()[0]!.value === "" && !pickers()[0]!.disabled);
  assert(!grants.has("user"), "Retry revokes direct user grant");
  document.querySelector<HTMLButtonElement>(".dialog-footer button")!.click();
  await until(() => !document.querySelector("dialog")?.open);
  assert(document.activeElement === opener, "Closing restores focus");
  document.getElementById("result")!.textContent = "PASS: initial Personal, saved all-Workspace scope, modal, focus, org/team/user search, 51 identical targets, all three roles, revoke beyond first page, failed revoke/retry";
}
void run().catch((error: unknown) => { document.getElementById("result")!.textContent = `FAIL: ${String(error)}`; });
