// Open /tests/browser/sharing.html with pnpm dev:client. All requests are mocked.
import { createRoot } from "react-dom/client";
import { VaultSharing } from "../../src/client/VaultSharing";
import type { SyncedVaultInfo } from "../../src/client/api";
import "../../src/client/styles.css";

const targets = [
  { principalType: "organization", principalId: "org", name: "Example Org", detail: "example" },
  { principalType: "team", principalId: "team", name: "Design", detail: "Example Org" },
  { principalType: "user", principalId: "user", name: "Yuki Tanaka", detail: "yuki@example.test" },
  ...Array.from({ length: 51 }, (_, index) => ({ principalType: "team", principalId: `team${index}`, name: "Repeated team", detail: "Example Org" })),
];
const grants = new Set<string>(["team50"]);
let fail = false;
window.fetch = (input, init) => {
  const request = new Request(input instanceof Request ? input : new URL(String(input), location.origin), init);
  const url = new URL(request.url);
  if (url.pathname.endsWith("/permission-targets")) {
    const q = (url.searchParams.get("q") ?? "").toLowerCase();
    const offset = Number(url.searchParams.get("cursor") ?? 0);
    const groups = ["organization", "team", "user"].map((type) => targets.filter((target) => target.principalType === type
      && `${target.name} ${target.detail}`.toLowerCase().includes(q)));
    return Promise.resolve(Response.json({ items: groups.flatMap((items) => items.slice(offset, offset + 50)),
      nextCursor: groups.some((items) => items.length > offset + 50) ? String(offset + 50) : null }));
  }
  if (url.pathname.endsWith("/permissions")) return Promise.resolve(Response.json({ items: targets.filter((target) => grants.has(target.principalId)).map((target) => ({ ...target, role: "member" })) }));
  const target = targets.find((target) => url.pathname.endsWith(`/${target.principalId}`));
  if (!target || !["PUT", "DELETE"].includes(request.method)) throw new Error(`Unexpected request ${request.method} ${url.pathname}`);
  if (fail) return Promise.resolve(Response.json({ error: "test_failed" }, { status: 500 }));
  if (request.method === "PUT") grants.add(target.principalId); else grants.delete(target.principalId);
  return Promise.resolve(new Response(null, { status: 204 }));
};
const assert = (ok: unknown, message: string) => { if (!ok) throw new Error(message); };
async function until(predicate: () => unknown) {
  const deadline = performance.now() + 5000;
  while (!predicate()) { if (performance.now() > deadline) throw new Error("Timed out"); await new Promise(requestAnimationFrame); }
}
const checkbox = () => document.querySelector<HTMLInputElement>('input[type="checkbox"]')!;
async function run() {
  createRoot(document.getElementById("root")!).render(<VaultSharing vault={{ vaultId: "vault", role: "owner" } as SyncedVaultInfo} />);
  await until(() => document.querySelector("button"));
  const opener = document.querySelector<HTMLButtonElement>("button")!;
  opener.focus(); opener.click();
  await until(() => document.querySelectorAll('input[type="checkbox"]').length === 52);
  assert(document.querySelector("dialog")?.open, "Button opens native modal");
  const search = document.querySelector<HTMLInputElement>('input[type="search"]')!;
  assert(document.activeElement === search, "Search receives focus");
  assert(search.getAttribute("aria-label"), "Search retains an accessible name without a visible label");
  const iconPaths = [...document.querySelectorAll(".sharing-results .share-row > svg path")].map((path) => path.getAttribute("d"));
  assert(new Set(iconPaths).size === 3, "Organizations, teams, and users have distinct icons");
  const searchFor = (value: string) => {
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(search, value);
    search.dispatchEvent(new Event("input", { bubbles: true }));
  };
  searchFor("Repeated team");
  await until(() => document.querySelectorAll('input[type="checkbox"]').length === 50 && !checkbox().disabled);
  document.querySelector<HTMLButtonElement>(".sharing-results button")!.click();
  const lastCheckbox = () => [...document.querySelectorAll<HTMLInputElement>('input[type="checkbox"]')].at(-1)!;
  await until(() => document.querySelectorAll('input[type="checkbox"]').length === 51 && !lastCheckbox().disabled);
  assert(lastCheckbox().checked, "Existing grant beyond first page is visible");
  lastCheckbox().click();
  await until(() => !lastCheckbox().checked && !lastCheckbox().disabled);
  assert(!grants.has("team50"), "Grant beyond first page can be revoked");
  searchFor("yuki@");
  await until(() => document.querySelectorAll('input[type="checkbox"]').length === 1 && !checkbox().disabled);
  checkbox().click();
  await until(() => checkbox().checked && !checkbox().disabled);
  assert(grants.has("user"), "User grant is persisted");
  fail = true; checkbox().click();
  await until(() => document.querySelector('[role="alert"]') && !checkbox().disabled);
  assert(checkbox().checked && grants.has("user"), "Failed revoke preserves existing access");
  fail = false; checkbox().click();
  await until(() => !checkbox().checked && !checkbox().disabled);
  assert(!grants.has("user"), "Retry revokes direct user grant");
  document.querySelector<HTMLButtonElement>(".dialog-footer button")!.click();
  await until(() => !document.querySelector("dialog")?.open);
  assert(document.activeElement === opener, "Closing restores focus");
  document.getElementById("result")!.textContent = "PASS: modal, focus, org/team/user search, 51 identical targets, revoke beyond first page, direct grant, failed revoke/retry";
}
void run().catch((error: unknown) => { document.getElementById("result")!.textContent = `FAIL: ${String(error)}`; });
