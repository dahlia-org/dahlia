// Open /tests/browser/organizations.html under pnpm dev:client. All requests are mocked.
import { z } from "zod";
import { createRoot } from "react-dom/client";
import { App } from "../../src/client/App";
import { navigateDashboard } from "../../src/client/navigation";
import { clientMutationEvent } from "../../src/client/api";
import "../../src/client/styles.css";

Object.defineProperty(navigator, "language", { value: "en-US", configurable: true });
let accounts = true;
let serverAdmin = false;
let deletions = 0;
let failCreate = true;
let creates = 0;
let edits = 0;
let invites = 0;
let teamCreates = 0;
let candidatesVisible = true;
const organizations = [{ id: "org_00000000000000000000000001", name: "Alpha", slug: "alpha-team", kind: "team" }];
const member = { id: "member-id", userId: "owner", role: "owner", user: { name: "Owner", email: "owner@example.com" } };
const listedMember = { id: "listed-member-id", userId: "listed", role: "member", user: { name: "Listed", email: "listed@example.com" } };
let activeRole = "owner";
let capabilitiesReady = false;
let releaseCapabilities: (() => void) | undefined;
let domains: { domain: string; joinPolicy: "invite_only" | "need_approval" | "auto_join" }[] = [];
const requests = [{ id: "ojr_other", organizationId: organizations[0]!.id, userId: "applicant", userName: "Applicant", userEmail: "applicant@example.com", organizationName: "Alpha", status: "pending" }];
const candidateId = "org_00000000000000000000000004";
const serverUsers = [{ id: "owner", name: "Owner", email: "owner@example.com", role: "admin", createdAt: new Date().toISOString() },
  { id: "second", name: "Second", email: "second@example.com", role: "user", createdAt: new Date().toISOString() }];
window.fetch = async (input, init) => {
  const method = input instanceof Request ? input.method : init?.method ?? "GET";
  const requestBody: unknown = method !== "GET" && method !== "HEAD" ? (input instanceof Request ? await input.clone().json().catch(() => ({})) : JSON.parse(typeof init?.body === "string" ? init.body : "{}")) : undefined;
  const url = new URL(typeof input === "string" ? input : input instanceof URL ? input.href : input.url, location.origin);
  if (url.pathname.endsWith("/domains")) {
    if (method === "PUT") {
      const body = z.object({ domains: z.array(z.object({ domain: z.string(), joinPolicy: z.enum(["invite_only", "need_approval", "auto_join"]) })) }).parse(requestBody);
      if (body.domains.some((row) => row.domain === "gmail.com")) return Response.json({ code: "shared_email_domain" }, { status: 400 });
      domains = body.domains;
    }
    return Response.json({ domains });
  }
  if (url.pathname === "/api/v1/organization-candidates") return Response.json({ items: candidatesVisible ? [{ id: candidateId, name: "Candidate", logo: null, joinPolicy: "need_approval", requestStatus: requests.findLast((request) => request.organizationId === candidateId)?.status ?? null }] : [], nextCursor: null });
  if (url.pathname === "/api/v1/organization-join-requests") return Response.json({ items: requests.filter((request) => request.userId === "owner"), nextCursor: null });
  if (url.pathname.endsWith("/join-requests")) {
    const organizationId = url.pathname.split("/")[4]!;
    if (method === "POST") { requests.push({ id: `ojr_${requests.length}`, organizationId, userId: "owner", userName: "Owner", userEmail: "owner@example.com", organizationName: "Candidate", status: "pending" }); return new Response(null, { status: 204 }); }
    return Response.json({ items: requests.filter((request) => request.organizationId === organizationId), nextCursor: null });
  }
  if (/\/organization-join-requests\/[^/]+\/(cancel|approve|reject)$/.test(url.pathname)) {
    const [, requestId, action] = /\/organization-join-requests\/([^/]+)\/(cancel|approve|reject)$/.exec(url.pathname)!;
    requests.find((request) => request.id === requestId)!.status = action === "approve" ? "approved" : action === "reject" ? "rejected" : "cancelled";
    return new Response(null, { status: 204 });
  }
  if (url.pathname === "/api/v1/admin/users") {
    const query = url.searchParams.get("q")?.toLowerCase() ?? "";
    return Response.json({ items: serverUsers.filter((user) => `${user.name} ${user.email}`.toLowerCase().includes(query)), hasMore: false });
  }
  if (url.pathname === "/api/v1/admin/organizations") return Response.json({ items: organizations.map((org) => ({ ...org, memberCount: 1, teamCount: 1 })), hasMore: false });
  if (url.pathname.startsWith("/api/v1/admin/organizations/")) {
    if (method === "DELETE") { deletions++; organizations.splice(organizations.findIndex((org) => org.id === url.pathname.split("/")[5]), 1); return new Response(null, { status: 204 }); }
    return Response.json({ ...organizations.find((org) => org.id === url.pathname.split("/")[5]), members: [], teams: [], hasMoreMembers: false, hasMoreTeams: false });
  }
  if (url.pathname === "/api/v1/session") return Response.json({ user: { id: "owner", name: "Owner" },
    capabilities: { sessions: accounts, sharing: true, sync: false, admin: serverAdmin } });
  if (url.pathname === "/api/v1/capabilities") {
    if (capabilitiesReady) return Response.json({ workspaceEncryption: { version: 1 } });
    return new Promise<Response>((resolve) => { releaseCapabilities = () => { capabilitiesReady = true; resolve(Response.json({ workspaceEncryption: { version: 1 } })); }; });
  }
  if (url.pathname.endsWith("/get-active-member-role")) return Response.json({ role: activeRole });
  if (url.pathname.endsWith("/invite-member")) {
    invites++;
    return invites === 1 ? Response.json({ error: "Invitation failed" }, { status: 500 }) : Response.json({ id: "invite-id" });
  }
  if (url.pathname.endsWith("/create-team")) { teamCreates++; return Response.json({ id: "created-team", name: "New team" }); }
  if (url.pathname.endsWith("/add-team-member")) return Response.json({ error: "membership_failed" }, { status: 500 });
  if (url.pathname === "/api/v1/organizations" && method === "POST") {
    creates++;
    const body = z.object({ name: z.string(), slug: z.string(), initialOwnerUserId: z.literal("owner") }).parse(requestBody);
    if (failCreate) return Response.json({ error: "slug_already_exists" }, { status: 409 });
    const organization = { id: "org_00000000000000000000000002", kind: "team", name: body.name, slug: body.slug };
    organizations.push(organization);
    return Response.json(organization, { status: 201 });
  }
  if (url.pathname === "/api/auth/organization/update") {
    edits++;
    const body = JSON.parse(typeof init?.body === "string" ? init.body : "{}") as { organizationId: string; data: { slug: string } };
    if (edits === 1) return Response.json({ error: "slug_already_exists" }, { status: 400 });
    const organization = organizations.find((item) => item.id === body.organizationId)!;
    organization.slug = body.data.slug;
    return Response.json(organization);
  }
  if (url.pathname === "/api/v1/organizations") return Response.json({ items: organizations, nextCursor: null, canCreateOrganizations: serverAdmin });
  if (url.pathname.endsWith("/list")) return Response.json(organizations);
  if (url.pathname.endsWith("/workspaces")) return Response.json({ items: [{ workspaceId: "workspace-id", name: "Team workspace", icon: "briefcase", color: "blue", revision: 1, creatorId: "owner" }], nextCursor: null });
  if (url.pathname === "/api/v1/organizations/org_00000000000000000000000001/members") return Response.json({ items: [member], nextCursor: null });
  if (url.pathname === "/api/v1/organizations/org_00000000000000000000000001/teams") return Response.json({ items: [{ id: "team-id", organizationId: "org_00000000000000000000000001", name: "Design" }], nextCursor: null });
  if (url.pathname.endsWith("/list-members") || url.pathname.endsWith("/members")) {
    if (url.pathname.includes("/teams/")) return Response.json({ items: [{ id: "tm", teamId: "team-id", userId: "owner" }], nextCursor: null });
    return Response.json({ members: [listedMember] });
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
  assert(!button("Create organization", main()), "Ordinary user can create organizations");
  assert(!main().querySelector("input"), "Organization creation form leaked into list");
  assert(!main().textContent?.includes("Design"), "Team details leaked into list");
  await until(() => button("Apply", main()));
  button("Apply", main()).click();
  await until(() => document.querySelector(".action-dialog:modal"));
  document.querySelector<HTMLButtonElement>(".action-dialog [data-confirm]")!.click();
  await until(() => !document.querySelector(".action-dialog") && button("Cancel request", main()));
  assert(button("Pending", main()).disabled, "Duplicate join request is enabled");
  button("Cancel request", main()).click();
  await until(() => document.querySelector(".action-dialog:modal"));
  document.querySelector<HTMLButtonElement>(".action-dialog [data-confirm]")!.click();
  await until(() => !document.querySelector(".action-dialog") && button("Apply", main()));
  candidatesVisible = false;
  requests.splice(1);
  window.dispatchEvent(new Event(clientMutationEvent));
  await until(() => ![...main().querySelectorAll("h2")].some((heading) => heading.textContent === "Organizations you can join"));
  await until(() => ![...main().querySelectorAll("h3")].some((heading) => heading.textContent === "Join requests"));
  (document.querySelector('a[href="/orgs/org_00000000000000000000000001"]') as HTMLElement).click();
  await until(() => button("Workspace governance"));
  button("Workspace governance").click();
  await until(() => panel()?.textContent?.includes("Team workspace"));
  const workspaceButton = button("New Workspace", panel());
  assert(workspaceButton, "Organization workspace creation is missing");
  assert(workspaceButton.disabled, "Workspace creation opened before encryption capabilities loaded");
  releaseCapabilities!();
  await until(() => !workspaceButton.disabled);
  workspaceButton.click();
  await until(() => document.querySelector(".action-dialog:modal"));
  assert(!document.querySelector('.action-dialog [aria-label="Organization"]'), "Organization-scoped creation asks for an Organization again");
  button("Cancel", document.querySelector(".action-dialog")!).click();
  await until(() => !document.querySelector(".action-dialog"));
  assert(panel().querySelector(".workspace-governance-identity .appearance-icon"), "Workspace icon is missing");
  assert(!panel().textContent?.includes("workspace-id") && !panel().textContent?.includes("revision 1") && !panel().textContent?.includes("Creator"), "Internal Workspace metadata is visible");
  button("Members").click();
  await until(() => panel()?.textContent?.includes("listed@example.com"));
  assert(button("Leave", panel()).classList.contains("danger-button"), "Leave action depends on the visible member page or is not styled as dangerous");
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
  assert(!button("Delete organization", panel()), "Organization owner can delete from Settings");
  assert(!button("Leave organization", panel()), "Leave action remained in Settings");
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
  assert(!button("Delete organization", panel()), "Slug change exposed deletion");
  await until(() => button("Approve", panel()));
  button("Approve", panel()).click();
  await until(() => document.querySelector(".action-dialog:modal"));
  document.querySelector<HTMLButtonElement>(".action-dialog [data-confirm]")!.click();
  await until(() => !document.querySelector(".action-dialog") && panel().textContent?.includes("Approved"));
  serverAdmin = true;
  window.dispatchEvent(new Event(clientMutationEvent));
  navigateDashboard("/orgs/org_00000000000000000000000003");
  await until(() => main().textContent?.includes("Organization not found"));
  navigateDashboard("/orgs");
  await until(() => document.querySelector('a[href="/orgs/org_00000000000000000000000001"]'));
  assert(!button("Create organization", main()), "Organization creation leaked into memberships");
  navigateDashboard("/admin/orgs");
  await until(() => button("Create organization", main()));
  const createButton = button("Create organization", main());
  createButton.focus();
  createButton.click();
  await until(() => document.querySelector(".action-dialog:modal"));
  button("Cancel", document.querySelector(".action-dialog")!).click();
  await until(() => !document.querySelector(".action-dialog"));
  assert(document.activeElement === createButton, "Closing organization creation did not restore focus");
  createButton.click();
  await until(() => document.querySelector(".action-dialog:modal"));
  const ownerSelect = document.querySelector<HTMLButtonElement>('.action-dialog [role="combobox"]')!;
  assert(ownerSelect.value === "", "Initial owner was selected implicitly");
  ownerSelect.click();
  await until(() => document.querySelector<HTMLInputElement>('.select-menu input[type="search"]'));
  const search = document.querySelector<HTMLInputElement>('.select-menu input[type="search"]')!;
  const ownerMenu = search.closest<HTMLElement>('.select-menu')!;
  Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(search, "missing");
  search.dispatchEvent(new Event("input", { bubbles: true }));
  await until(() => ownerMenu.textContent?.includes("No matching users."));
  search.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
  await until(() => ownerSelect.ariaExpanded === "false");
  assert(!ownerSelect.disabled, "Empty owner search disabled the picker");
  ownerSelect.click();
  await until(() => ownerMenu.matches(":popover-open"));
  Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(search, "second");
  search.dispatchEvent(new Event("input", { bubbles: true }));
  await until(() => ownerMenu.querySelectorAll('[role="option"]').length === 1);
  assert(ownerSelect.value === "", "Filtered owner was selected implicitly");
  ownerMenu.querySelector<HTMLButtonElement>('[role="option"]')!.click();
  await until(() => ownerSelect.value === "second");
  ownerSelect.click();
  await until(() => ownerMenu.matches(":popover-open"));
  Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(search, "");
  search.dispatchEvent(new Event("input", { bubbles: true }));
  await until(() => ownerMenu.querySelectorAll('[role="option"]').length === 2);
  assert(ownerSelect.value === "second", "Owner selection was reset by a live result refresh");
  Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(search, "owner");
  search.dispatchEvent(new Event("input", { bubbles: true }));
  await until(() => ownerMenu.querySelectorAll('[role="option"]').length === 1 && ownerSelect.value === "");
  ownerMenu.querySelector<HTMLButtonElement>('[role="option"]')!.click();
  await until(() => ownerSelect.value === "owner");
  fill("name", "New organization");
  await until(() => document.querySelector<HTMLInputElement>('[name="slug"]')?.value === "new-organization");
  fill("slug", "Invalid Slug");
  fill("name", "Renamed organization");
  assert(document.querySelector<HTMLInputElement>('[name="slug"]')?.value === "Invalid Slug", "Manual slug edit was overwritten");
  await until(() => document.querySelector<HTMLInputElement>('[name="slug"]')?.validity.patternMismatch);
  document.querySelector<HTMLButtonElement>(".action-dialog [data-confirm]")!.click();
  assert(creates === 0, "Invalid slug was submitted");
  fill("slug", "new_team");
  await until(() => document.querySelector<HTMLInputElement>('[name="slug"]')?.value === "new_team");
  document.querySelector<HTMLButtonElement>(".action-dialog [data-confirm]")!.click();
  await until(() => document.querySelector(".action-dialog [role=alert]"));
  assert(document.querySelector<HTMLInputElement>('[name="name"]')?.value === "Renamed organization", "Failure discarded draft");
  failCreate = false;
  document.querySelector<HTMLButtonElement>(".action-dialog [data-confirm]")!.click();
  await until(() => location.pathname === "/admin/orgs" && !document.querySelector(".action-dialog"));
  assert(creates === 2, "Create did not complete exactly once after retry");
  navigateDashboard("/admin/orgs/org_00000000000000000000000002");
  await until(() => button("Settings", main()));
  assert(!main().querySelector(":scope > button.danger-button"), "Organization deletion is detached from Settings");
  button("Settings", main()).click();
  await until(() => button("Delete organization", panel()));
  button("Delete organization", panel()).click();
  await until(() => document.querySelector(".action-dialog:modal"));
  document.querySelector<HTMLButtonElement>(".action-dialog [data-confirm]")!.click();
  await until(() => location.pathname === "/admin/orgs" && !document.querySelector(".action-dialog"));
  assert(deletions === 1, "Server administrator deletion did not run");
  accounts = false;
  window.dispatchEvent(new Event(clientMutationEvent));
  navigateDashboard("/orgs");
  await until(() => document.querySelector('a[href="/orgs/org_00000000000000000000000001"]'));
  assert(!button("Create organization", main()), "Organization creation returned to memberships");
  (document.querySelector('a[href="/orgs/org_00000000000000000000000001"]') as HTMLElement).click();
  await until(() => button("Members"));
  button("Members").click();
  await until(() => panel()?.textContent?.includes("listed@example.com"));
  button("Settings").click();
  await until(() => panel()?.textContent?.includes("external"));
  assert(button("Change slug", panel()), "Header organization slug editor missing");
  await until(() => button("Add domain", panel()));
  button("Add domain", panel()).click();
  await until(() => document.querySelector('.action-dialog input[name="domain"]'));
  const policy = document.querySelector<HTMLButtonElement>('.action-dialog [role="combobox"]')!;
  await until(() => document.getElementById(policy.getAttribute("aria-controls")!));
  assert(policy.value === "invite_only", "New domain is not invitation-only");
  fill("domain", "gmail.com");
  document.querySelector<HTMLButtonElement>(".action-dialog [data-confirm]")!.click();
  await until(() => document.querySelector(".action-dialog")?.textContent?.includes("Shared email domains cannot"));
  fill("domain", "company.example");
  policy.click();
  document.getElementById(policy.getAttribute("aria-controls")!)!.querySelector<HTMLButtonElement>('button[value="auto_join"]')!.click();
  await until(() => policy.value === "auto_join");
  document.querySelector<HTMLButtonElement>(".action-dialog [data-confirm]")!.click();
  await until(() => !document.querySelector(".action-dialog") && panel()?.textContent?.includes("company.example"));
  const domainRow = panel().querySelector<HTMLElement>(".org-domain-row")!;
  assert(domainRow.querySelector(".org-domain-policy")?.textContent === "Auto join", "Domain join policy is unclear");
  assert(button("Remove", domainRow).classList.contains("danger-button"), "Domain removal is not styled as dangerous");
  button("Remove", domainRow).click();
  await until(() => document.querySelector(".action-dialog:modal"));
  document.querySelector<HTMLButtonElement>(".action-dialog [data-confirm]")!.click();
  await until(() => !document.querySelector(".action-dialog") && panel()?.textContent?.includes("No email domains yet"));
  assert(!button("Delete organization", panel()), "Server administrator deletion leaked into the member-facing organization page");
  organizations[0]!.kind = "personal";
  navigateDashboard("/orgs");
  await until(() => main().textContent?.includes("No organizations"));
  assert(main().textContent?.includes("Ask a server administrator"), "Organization empty state suggests an unavailable creation action");
  assert(!document.querySelector('a[href="/orgs/org_00000000000000000000000001"]'), "Personal organization is listed as a joined organization");
  navigateDashboard("/orgs/org_00000000000000000000000001");
  await until(() => button("Settings"));
  assert(!button("New Workspace", panel()), "Personal organization exposed Workspace creation");
  button("Settings").click();
  await until(() => button("Change slug", panel()));
  assert(!button("Add domain", panel()), "Personal organization exposed auto-join settings");
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
  activeRole = "member";
  navigateDashboard("/orgs");
  await until(() => document.querySelector('a[href="/orgs/org_00000000000000000000000001"]'));
  (document.querySelector('a[href="/orgs/org_00000000000000000000000001"]') as HTMLElement).click();
  await until(() => button("Settings"));
  button("Settings").click();
  await until(() => panel()?.textContent?.includes("personal_updated"));
  await until(() => panel()?.textContent?.includes("No email domains yet"));
  assert(!button("Add domain", panel()), "Member can edit auto-join settings");
  assert(!button("Change slug", panel()), "Member can edit organization slug");
  document.body.dataset.testResult = "passed";
}
void run().catch((error: unknown) => { document.body.dataset.testResult = "failed"; document.body.dataset.testError = error instanceof Error ? error.stack : String(error); });
