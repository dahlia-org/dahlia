// Open /tests/browser/organizations.html under pnpm dev:client. All requests are mocked.
import { z } from "zod";
import { createRoot } from "react-dom/client";
import { App } from "../../src/client/App";
import { navigateDashboard } from "../../src/client/navigation";
import { clientMutationEvent } from "../../src/client/api";
import "../../src/client/styles.css";

Object.defineProperty(navigator, "language", { value: "en-US", configurable: true });
let accounts = true;
let failCreate = true;
let creates = 0;
let edits = 0;
let invites = 0;
let teamCreates = 0;
const organizations = [{ id: "org_00000000000000000000000001", name: "Alpha", slug: "alpha-team", kind: "team" }];
const member = { id: "member-id", userId: "owner", role: "owner", user: { name: "Owner", email: "owner@example.com" } };
let autoJoinDomains: string[] = [];
window.fetch = async (input, init) => {
  const requestBody = input instanceof Request && input.method === "PUT" ? z.object({ domains: z.array(z.string()) }).parse(await input.clone().json()) : undefined;
  const url = new URL(typeof input === "string" ? input : input instanceof URL ? input.href : input.url, location.origin);
  if (url.pathname.endsWith("/auto-join-domains")) {
    if (requestBody) {
      if (requestBody.domains.includes("gmail.com")) return Response.json({ code: "shared_email_domain" }, { status: 400 });
      autoJoinDomains = requestBody.domains;
    }
    return Response.json({ domains: autoJoinDomains });
  }
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
    const organization = { id: "org_00000000000000000000000002", kind: "team", ...body };
    organizations.push(organization);
    return Response.json(organization);
  }
  if (url.pathname === "/api/auth/organization/update") {
    edits++;
    const body = JSON.parse(typeof init?.body === "string" ? init.body : "{}") as { organizationId: string; data: { slug: string } };
    if (edits === 1) return Response.json({ error: "slug_already_exists" }, { status: 400 });
    const organization = organizations.find((item) => item.id === body.organizationId)!;
    organization.slug = body.data.slug;
    return Response.json(organization);
  }
  if (url.pathname === "/api/v1/organizations") return Response.json({ items: organizations, nextCursor: null });
  if (url.pathname.endsWith("/list")) return Response.json(organizations);
  if (url.pathname.endsWith("/workspaces")) return Response.json({ items: [], nextCursor: null });
  if (url.pathname === "/api/v1/organizations/org_00000000000000000000000001/members") return Response.json({ items: [member], nextCursor: null });
  if (url.pathname === "/api/v1/organizations/org_00000000000000000000000001/teams") return Response.json({ items: [{ id: "team-id", organizationId: "org_00000000000000000000000001", name: "Design" }], nextCursor: null });
  if (url.pathname.endsWith("/list-members") || url.pathname.endsWith("/members")) {
    if (url.pathname.includes("/teams/")) return Response.json({ items: [{ id: "tm", teamId: "team-id", userId: "owner" }], nextCursor: null });
    return Response.json({ members: [member] });
  }
  if (url.pathname.endsWith("/list-teams") || url.pathname.endsWith("/list-user-teams") || url.pathname.endsWith("/teams")) {
    return Response.json([{ id: "team-id", organizationId: "org_00000000000000000000000001", name: "Design" }]);
  }
  if (url.pathname.endsWith("/list-user-invitations") || url.pathname.endsWith("/list-invitations")) return Response.json([]);
  throw Error(`Unexpected request: ${url.pathname}`);
};
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
  const preview = new URLSearchParams(location.search).has("preview");
  history.replaceState(null, "", preview ? "/orgs/org_00000000000000000000000001" : "/orgs");
  createRoot(document.getElementById("root")!).render(<App />);
  if (preview) return;
  await until(() => document.querySelector('a[href="/orgs/org_00000000000000000000000001"]'));
  assert(document.querySelector('#account-menu a[href="/orgs"]'), "Account menu has no organization list entry");
  assert(document.querySelector('#account-menu a[href="/orgs"][aria-current="page"]'), "Organization list is not selected");
  assert(!main().querySelector("input"), "Organization creation form leaked into list");
  assert(!main().textContent?.includes("Design"), "Team details leaked into list");
  (document.querySelector('a[href="/orgs/org_00000000000000000000000001"]') as HTMLElement).click();
  await until(() => button("Members"));
  button("Members").click();
  await until(() => panel()?.textContent?.includes("owner@example.com"));
  assert(location.pathname === "/orgs/org_00000000000000000000000001", "Detail did not use TypeID");
  assert(document.querySelector('#account-menu a[href="/orgs"][aria-current="page"]'), "Organization detail is not selected");
  await until(() => [...document.querySelectorAll('[role="tab"]')].map((el) => el.textContent).join() === "Workspace governance,Members 1,Teams 1,Settings");
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
  await until(() => !document.querySelector(".action-dialog"));
  assert(teamCreates === 1, "Team creation was duplicated");
  button("Settings").click();
  await until(() => panel()?.textContent?.includes("alpha-team"));
  assert(button("Delete organization", panel()), "Owner deletion missing from Settings");
  assert(button("Rename", panel()).closest("dd")?.previousElementSibling?.textContent === "Organization name", "Rename is detached from its setting");
  assert(button("Change slug", panel()).closest("dd")?.previousElementSibling?.textContent === "slug", "Slug edit is detached from its setting");
  const settings = panel().querySelector<HTMLElement>(".org-settings")!;
  assert(settings.scrollWidth <= settings.clientWidth, "Settings content overflows horizontally");
  button("Change slug", panel()).click();
  await until(() => document.querySelector(".action-dialog:modal"));
  assert(document.querySelector<HTMLInputElement>('[name="slug"]')?.value === "alpha-team", "Slug editor did not show current value");
  fill("slug", "Bad Slug");
  document.querySelector<HTMLButtonElement>(".action-dialog [data-confirm]")!.click();
  assert(edits === 0, "Invalid slug edit submitted");
  fill("slug", "external");
  document.querySelector<HTMLButtonElement>(".action-dialog [data-confirm]")!.click();
  await until(() => document.querySelector(".action-dialog [role=alert]"));
  assert(location.pathname === "/orgs/org_00000000000000000000000001", "Failed edit navigated");
  assert(document.querySelector<HTMLInputElement>('[name="slug"]')?.value === "external", "Failure discarded slug draft");
  document.querySelector<HTMLButtonElement>(".action-dialog [data-confirm]")!.click();
  await until(() => location.pathname === "/orgs/org_00000000000000000000000001" && !document.querySelector(".action-dialog"));
  assert(edits === 2, "Slug update did not complete");
  assert(location.pathname === "/orgs/org_00000000000000000000000001", "Slug edit changed the TypeID URL");
  button("Settings").click();
  await until(() => panel()?.textContent?.includes("external"));
  assert(button("Delete organization", panel()), "Changing the slug to external hid owner deletion");
  navigateDashboard("/orgs/org_00000000000000000000000003");
  await until(() => main().textContent?.includes("Organization not found"));
  navigateDashboard("/orgs");
  await until(() => button("Create organization", main()));
  button("Create organization", main()).click();
  await until(() => document.querySelector(".action-dialog:modal"));
  fill("name", "New organization"); fill("slug", "Invalid Slug");
  await until(() => document.querySelector<HTMLInputElement>('[name="slug"]')?.validity.patternMismatch);
  document.querySelector<HTMLButtonElement>(".action-dialog [data-confirm]")!.click();
  assert(creates === 0, "Invalid slug was submitted");
  fill("slug", "new_team");
  await until(() => document.querySelector<HTMLInputElement>('[name="slug"]')?.value === "new_team");
  document.querySelector<HTMLButtonElement>(".action-dialog [data-confirm]")!.click();
  await until(() => document.querySelector(".action-dialog [role=alert]"));
  assert(document.querySelector<HTMLInputElement>('[name="name"]')?.value === "New organization", "Failure discarded draft");
  failCreate = false;
  document.querySelector<HTMLButtonElement>(".action-dialog [data-confirm]")!.click();
  await until(() => location.pathname === "/orgs/org_00000000000000000000000002" && button("Members"));
  button("Members").click();
  await until(() => panel()?.textContent?.includes("owner@example.com"));
  assert(creates === 2 && !document.querySelector(".action-dialog"), "Create did not close modal and open detail");
  accounts = false;
  window.dispatchEvent(new Event(clientMutationEvent));
  navigateDashboard("/orgs");
  await until(() => document.querySelector('a[href="/orgs/org_00000000000000000000000001"]') && button("Create organization", main()));
  (document.querySelector('a[href="/orgs/org_00000000000000000000000001"]') as HTMLElement).click();
  await until(() => button("Members"));
  button("Members").click();
  await until(() => panel()?.textContent?.includes("owner@example.com"));
  button("Settings").click();
  await until(() => panel()?.textContent?.includes("external"));
  assert(button("Change slug", panel()), "Header organization slug editor missing");
  await until(() => button("Edit domains", panel()));
  button("Edit domains", panel()).click();
  await until(() => document.querySelector('.action-dialog input[name="domains"]'));
  fill("domains", "gmail.com");
  document.querySelector<HTMLButtonElement>(".action-dialog [data-confirm]")!.click();
  await until(() => document.querySelector(".action-dialog")?.textContent?.includes("Shared email domains cannot"));
  fill("domains", "company.example, subsidiary.example");
  document.querySelector<HTMLButtonElement>(".action-dialog [data-confirm]")!.click();
  await until(() => !document.querySelector(".action-dialog") && panel()?.textContent?.includes("company.example, subsidiary.example"));
  button("Edit domains", panel()).click();
  await until(() => document.querySelector('.action-dialog input[name="domains"]'));
  fill("domains", "");
  document.querySelector<HTMLButtonElement>(".action-dialog [data-confirm]")!.click();
  await until(() => !document.querySelector(".action-dialog") && panel()?.textContent?.includes("Disabled"));
  assert(button("Delete organization", panel()), "Team organization owner lost deletion in header mode");
  organizations[0]!.kind = "personal";
  navigateDashboard("/orgs");
  await until(() => document.querySelector('a[href="/orgs/org_00000000000000000000000001"]'));
  (document.querySelector('a[href="/orgs/org_00000000000000000000000001"]') as HTMLElement).click();
  await until(() => button("Settings"));
  button("Settings").click();
  await until(() => button("Change slug", panel()));
  assert(!button("Edit domains", panel()), "Personal organization exposed auto-join settings");
  assert(!button("Delete organization", panel()), "Personal organization exposed deletion");
  button("Change slug", panel()).click();
  await until(() => document.querySelector(".action-dialog:modal"));
  fill("slug", "personal_updated");
  document.querySelector<HTMLButtonElement>(".action-dialog [data-confirm]")!.click();
  await until(() => location.pathname === "/orgs/org_00000000000000000000000001" && !document.querySelector(".action-dialog"));
  assert(edits === 3, "Personal slug update did not complete");
  await until(() => panel()?.textContent?.includes("personal_updated"));
  assert(location.pathname === "/orgs/org_00000000000000000000000001", "Personal slug edit changed the TypeID URL");
  organizations[0]!.kind = "team";
  member.role = "member";
  navigateDashboard("/orgs");
  await until(() => document.querySelector('a[href="/orgs/org_00000000000000000000000001"]'));
  (document.querySelector('a[href="/orgs/org_00000000000000000000000001"]') as HTMLElement).click();
  await until(() => button("Settings"));
  button("Settings").click();
  await until(() => panel()?.textContent?.includes("personal_updated"));
  await until(() => panel()?.textContent?.includes("Disabled"));
  assert(!button("Edit domains", panel()), "Member can edit auto-join settings");
  assert(!button("Change slug", panel()), "Member can edit organization slug");
  document.body.dataset.testResult = "passed";
}
void run().catch((error: unknown) => { document.body.dataset.testResult = "failed"; document.body.dataset.testError = error instanceof Error ? error.stack : String(error); });
