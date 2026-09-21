import { DEFAULT_WORKSPACE_GENERATION_SETTINGS } from "../../src/workspace-generation-settings";
// Open /tests/browser/sharing.html with pnpm dev:client. All requests are mocked.
import { createRoot } from "react-dom/client";
import { SidebarProvider } from "../../src/client/Sidebar";
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
let targetReads = 0;
window.fetch = async (input, init) => {
  const request = new Request(input instanceof Request ? input : new URL(String(input), location.origin), init);
  const url = new URL(request.url);
  if (url.pathname === "/api/auth/organization/list") return Promise.resolve(Response.json([
    { id: "org", name: "Example Org", slug: "example" },
  ]));
  if (url.pathname === "/api/v1/workspaces") return Promise.resolve(Response.json({ items: [] }));
  if (url.pathname.endsWith("/permission-targets")) {
    targetReads++;
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
const pickers = () => [...document.querySelectorAll<HTMLButtonElement>('[data-slot="dialog-content"] [role="combobox"]')];
const pickerValue = (picker: HTMLButtonElement) => picker.dataset.value === "__dahlia_empty__" ? "" : picker.dataset.value;
const choose = async (picker: HTMLButtonElement, role: string) => {
  picker.click();
  await until(() => document.querySelector('[data-slot="select-content"][data-state="open"]'));
  [...document.querySelectorAll<HTMLElement>('[data-slot="select-content"][data-state="open"] [role="option"]')]
    .find((option) => option.dataset.value === role)!.click();
};
async function run() {
  const workspace: SyncedWorkspaceInfo = { personalUserId: null, meetingDeletionGraceDays: 7, generationSettings: DEFAULT_WORKSPACE_GENERATION_SETTINGS, workspaceId: "workspace", organizationId: "org", organizationName: "Example Org", name: "Shared", role: "admin", revision: 1,
    createdAt: new Date().toISOString(), updatedAt: new Date().toISOString() };
  const fixture = <SidebarProvider session={{ user: { id: "me" },
    capabilities: { admin: false, sessions: false, sharing: true, sync: true } }}><WorkspaceSharing workspace={workspace} /></SidebarProvider>;
  const root = createRoot(document.getElementById("root")!);
  root.render(fixture);
  await until(() => [...document.querySelectorAll("button")].some((button) => button.textContent === "共有先を追加"));
  const opener = [...document.querySelectorAll<HTMLButtonElement>("button")].find((button) => button.textContent === "共有先を追加")!;
  opener.focus(); opener.click();
  await until(() => document.querySelector('[data-slot="dialog-content"]'));
  const search = document.querySelector<HTMLInputElement>('input[type="search"]')!;
  assert(pickers().length === 0 && targetReads === 0, "Targets load before a search is entered");
  assert(document.querySelector('[data-slot="dialog-content"]')?.textContent?.includes("名前またはメールアドレスを入力"), "Empty search guidance is missing");
  assert(document.activeElement === search, "Search receives focus");
  assert(search.getAttribute("aria-label"), "Search has an accessible name");
  const searchFor = (value: string) => {
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(search, value);
    search.dispatchEvent(new Event("input", { bubbles: true }));
  };
  searchFor("example");
  await until(() => pickers().length === 52);
  const iconPaths = pickers().map((picker) => picker.parentElement?.querySelector(":scope > svg path")?.getAttribute("d"));
  assert(new Set(iconPaths).size === 3, "Organizations, teams, and users have distinct icons");
  searchFor("nothing matches");
  await until(() => document.querySelector('[data-slot="dialog-content"] [role="status"]'));
  assert(pickers().length === 0, "No-result search kept stale targets");
  searchFor("Repeated team");
  await new Promise(requestAnimationFrame);
  assert(pickers().length === 0, "Results from the previous search remain actionable during debounce");
  await until(() => pickers().length === 50 && !pickers()[0]!.disabled);
  [...document.querySelectorAll<HTMLButtonElement>('[data-slot="dialog-content"] button')].find((button) => button.textContent === "さらに表示")!.click();
  await until(() => pickers().length === 51 && !pickers().at(-1)!.disabled);
  assert(pickerValue(pickers().at(-1)!) === "viewer", "Existing grant beyond first page is visible");
  await choose(pickers().at(-1)!, "");
  await until(() => pickerValue(pickers().at(-1)!) === "" && !pickers().at(-1)!.disabled);
  assert(!grants.has("team50"), "Grant beyond first page can be revoked");
  searchFor("yuki@");
  await until(() => pickers().length === 1 && !pickers()[0]!.disabled);
  for (const role of ["viewer", "editor", "admin"]) {
    await choose(pickers()[0]!, role);
    await until(() => grants.get("user") === role && !pickers()[0]!.disabled);
    assert(pickerValue(pickers()[0]!) === role, "Selected role is persisted");
  }
  fail = true; await choose(pickers()[0]!, "");
  await until(() => document.querySelector('[role="alert"]') && !pickers()[0]!.disabled);
  assert(pickerValue(pickers()[0]!) === "admin" && grants.has("user"), "Failed revoke preserves existing access");
  fail = false; await choose(pickers()[0]!, "");
  await until(() => pickerValue(pickers()[0]!) === "" && !pickers()[0]!.disabled);
  assert(!grants.has("user"), "Retry revokes direct user grant");
  [...document.querySelectorAll<HTMLButtonElement>('[data-slot="dialog-content"] button')].find((button) => button.textContent === "完了")!.click();
  await until(() => !document.querySelector('[data-slot="dialog-content"]'));
  assert(document.activeElement === opener, "Closing restores focus");
  document.getElementById("result")!.textContent = "PASS: modal, focus, org/team/user search, 51 identical targets, all three roles, revoke beyond first page, failed revoke/retry";
}
void run().catch((error: unknown) => { document.getElementById("result")!.textContent = `FAIL: ${String(error)}`; });
