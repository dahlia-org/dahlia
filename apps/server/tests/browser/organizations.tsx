// Open /tests/browser/organizations.html under pnpm dev:client. All requests are mocked.
import { createRoot } from "react-dom/client";
import { App } from "../../src/client/App";
import { navigateDashboard } from "../../src/client/navigation";
import { clientMutationEvent } from "../../src/client/api";
import "../../src/client/styles.css";

Object.defineProperty(navigator, "language", { value: "en-US", configurable: true });
let accounts = true;
let failCreate = true;
let creates = 0;
let invites = 0;
let teamCreates = 0;
const organizations = [{ id: "organization-id", name: "Alpha", slug: "alpha-team" }];
const member = { id: "member-id", userId: "owner", role: "owner", user: { name: "Owner", email: "owner@example.com" } };
window.fetch = (input, init) => Promise.resolve((() => {
  const url = new URL(typeof input === "string" ? input : input instanceof URL ? input.href : input.url, location.origin);
  if (url.pathname === "/api/v1/session") return Response.json({ user: { id: "owner", name: "Owner" },
    capabilities: { sessions: accounts, sharing: true, sync: false, admin: false } });
  if (url.pathname.endsWith("/invite-member")) {
    invites++;
    return invites === 1 ? Response.json({ error: "Invitation failed" }, { status: 500 }) : Response.json({ id: "invite-id" });
  }
  if (url.pathname.endsWith("/create-team")) { teamCreates++; return Response.json({ id: "created-team", name: "New team" }); }
  if (url.pathname.endsWith("/add-team-member")) return Response.json({ error: "membership_failed" }, { status: 500 });
  if (url.pathname === "/api/auth/organization/create") {
    creates++;
    const body = JSON.parse(typeof init?.body === "string" ? init.body : "{}") as { name: string; slug: string };
    if (failCreate) return Response.json({ error: "slug_already_exists" }, { status: 409 });
    const organization = { id: "new-id", ...body };
    organizations.push(organization);
    return Response.json(organization);
  }
  if (url.pathname === "/api/v1/organizations") return Response.json({ items: organizations, nextCursor: null });
  if (url.pathname.endsWith("/list")) return Response.json(organizations);
  if (url.pathname === "/api/v1/organizations/organization-id/members") return Response.json({ items: [member], nextCursor: null });
  if (url.pathname === "/api/v1/organizations/organization-id/teams") return Response.json({ items: [{ id: "team-id", organizationId: "organization-id", name: "Design" }], nextCursor: null });
  if (url.pathname.endsWith("/list-members") || url.pathname.endsWith("/members")) {
    if (url.pathname.includes("/teams/")) return Response.json({ items: [{ id: "tm", teamId: "team-id", userId: "owner" }], nextCursor: null });
    return Response.json({ members: [member] });
  }
  if (url.pathname.endsWith("/list-teams") || url.pathname.endsWith("/list-user-teams") || url.pathname.endsWith("/teams")) {
    return Response.json([{ id: "team-id", organizationId: "organization-id", name: "Design" }]);
  }
  if (url.pathname.endsWith("/list-user-invitations") || url.pathname.endsWith("/list-invitations")) return Response.json([]);
  throw Error(`Unexpected request: ${url.pathname}`);
})());
const assert = (value: unknown, message: string) => { if (!value) throw Error(message); };
async function until(predicate: () => unknown) {
  const deadline = performance.now() + 5000;
  while (!predicate()) {
    if (performance.now() > deadline) throw Error("Timed out waiting for organization UI");
    await new Promise(requestAnimationFrame);
  }
}
const button = (label: string, root: Document | HTMLElement = document) => [...root.querySelectorAll<HTMLButtonElement>("button")].find((el) => el.textContent === label || (el.getAttribute("role") === "tab" && el.textContent?.replace(/ \d+$/, "") === label))!;
const main = () => document.querySelector("main")!;
const panel = () => document.querySelector<HTMLElement>('[role="tabpanel"]:not([hidden])')!;
function fill(name: string, value: string) {
  const input = document.querySelector<HTMLInputElement>(`.action-dialog input[name="${name}"]`)!;
  Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(input, value);
  input.dispatchEvent(new Event("input", { bubbles: true }));
}
async function run() {
  history.replaceState(null, "", "/organizations");
  createRoot(document.getElementById("root")!).render(<App />);
  await until(() => document.querySelector('a[href="/organizations/alpha-team"]'));
  assert(document.querySelector('#account-menu a[href="/organizations"]'), "Account menu has no organization list entry");
  assert(!main().querySelector("input"), "Organization creation form leaked into list");
  assert(!main().textContent?.includes("Design"), "Team details leaked into list");
  (document.querySelector('a[href="/organizations/alpha-team"]') as HTMLElement).click();
  await until(() => button("Members"));
  button("Members").click();
  await until(() => panel()?.textContent?.includes("owner@example.com"));
  assert(location.pathname === "/organizations/alpha-team", "Detail did not use slug");
  assert([...document.querySelectorAll('[role="tab"]')].map((el) => el.textContent).join() === "Members 1,Teams 1,Settings", "Missing organization tabs");
  assert(!panel().querySelector(".org-section-header h3"), "Member heading duplicates tab");
  button("Invite member").click();
  await until(() => document.querySelector(".action-dialog:modal"));
  fill("email", "invalid");
  document.querySelector<HTMLButtonElement>(".action-dialog [data-confirm]")!.click();
  assert(invites === 0, "Invalid email submitted");
  fill("email", "person@example.com");
  document.querySelector<HTMLButtonElement>(".action-dialog [data-confirm]")!.click();
  await until(() => document.querySelector(".action-dialog [role=alert]"));
  assert(document.querySelector<HTMLInputElement>('[name="email"]')?.value === "person@example.com", "Invitation error discarded email");
  document.querySelector<HTMLButtonElement>(".action-dialog [data-confirm]")!.click();
  await until(() => panel()?.textContent?.includes("Invitation link ready"));
  assert(document.querySelector<HTMLInputElement>('[aria-label="Invitation link"]')?.value.endsWith("/accept-invitation/invite-id"), "Created invitation link missing");
  button("Teams").click();
  await until(() => panel()?.textContent?.includes("Design"));
  assert(!panel().querySelector("details[open]"), "Team membership should start collapsed");
  panel().querySelector<HTMLElement>("summary")!.click();
  assert(panel().querySelector('details[open] input[type="checkbox"]'), "Team membership controls missing");
  button("Create team", panel()).click();
  await until(() => document.querySelector(".action-dialog:modal"));
  fill("name", "New team");
  document.querySelector<HTMLButtonElement>(".action-dialog [data-confirm]")!.click();
  await until(() => !document.querySelector(".action-dialog") && main().textContent?.includes("Team created."));
  assert(teamCreates === 1, "Membership failure duplicated team creation");
  button("Settings").click();
  await until(() => panel()?.textContent?.includes("alpha-team"));
  assert(button("Delete organization", panel()), "Owner deletion missing from Settings");
  navigateDashboard("/organizations/missing");
  await until(() => main().textContent?.includes("Organization not found"));
  navigateDashboard("/organizations");
  await until(() => button("Create organization", main()));
  button("Create organization", main()).click();
  await until(() => document.querySelector(".action-dialog:modal"));
  fill("name", "New organization"); fill("slug", "Invalid Slug");
  await until(() => document.querySelector<HTMLInputElement>('[name="slug"]')?.validity.patternMismatch);
  document.querySelector<HTMLButtonElement>(".action-dialog [data-confirm]")!.click();
  assert(creates === 0, "Invalid slug was submitted");
  fill("slug", "new-team");
  await until(() => document.querySelector<HTMLInputElement>('[name="slug"]')?.value === "new-team");
  document.querySelector<HTMLButtonElement>(".action-dialog [data-confirm]")!.click();
  await until(() => document.querySelector(".action-dialog [role=alert]"));
  assert(document.querySelector<HTMLInputElement>('[name="name"]')?.value === "New organization", "Failure discarded draft");
  failCreate = false;
  document.querySelector<HTMLButtonElement>(".action-dialog [data-confirm]")!.click();
  await until(() => location.pathname === "/organizations/new-team" && panel()?.textContent?.includes("owner@example.com"));
  assert(creates === 2 && !document.querySelector(".action-dialog"), "Create did not close modal and open detail");
  accounts = false;
  window.dispatchEvent(new Event(clientMutationEvent));
  navigateDashboard("/organizations");
  await until(() => document.querySelector('a[href="/organizations/alpha-team"]') && !button("Create organization", main()));
  (document.querySelector('a[href="/organizations/alpha-team"]') as HTMLElement).click();
  await until(() => button("Members"));
  button("Members").click();
  await until(() => panel()?.textContent?.includes("owner@example.com"));
  button("Settings").click();
  await until(() => panel()?.textContent?.includes("alpha-team"));
  assert(!button("Delete organization", panel()), "Proxy organization exposed deletion");
  document.body.dataset.testResult = "passed";
}
void run().catch((error: unknown) => { document.body.dataset.testResult = "failed"; document.body.dataset.testError = error instanceof Error ? error.stack : String(error); });
