// Run with pnpm dev:client, then open /tests/browser/live-data.html.
// All API responses and mutations are local fixtures; no backend is contacted.
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App, SyncedMeeting } from "../../src/client/App";
import { DetailTabs } from "../../src/client/MeetingContent";
import { refreshData } from "../../src/client/live-data";
import "../../src/client/styles.css";

const previewMode = new URLSearchParams(location.search).has("preview");
const previewPage = new URLSearchParams(location.search).get("page") ?? "meeting";
const navigationTest = new URLSearchParams(location.search).has("navigation-test");
Object.defineProperty(navigator, "language", { value: previewMode && new URLSearchParams(location.search).get("lang") === "ja" ? "ja-JP" : "en-US", configurable: true });
const ja = navigator.language.startsWith("ja");
sessionStorage.removeItem("dahlia:sidebar:browser-fixture:organization");

const base = "/api/v1/vaults/v1";
const route = "/meetings/m1";
const sources: EventTarget[] = [];
const requests: string[] = [];
const requestURLs: string[] = [];
const failures = new Map<string, number>();
let caption = "Initial caption";
let summary = "Initial summary";
let transcript = "Initial transcript";
let fileCount = navigationTest ? 5 : 3;
let omittedFile: number | undefined;
const filePageSize = navigationTest ? 2 : 12;
let sharingEnabled = false;
let meetingName = previewMode ? (ja ? "新しいオンボーディング体験のデザインレビュー" : "Design review: a better first-run experience") : "Recording meeting";
const vault = { vaultId: "v1", name: previewMode ? (ja ? "プロダクト開発" : "Product & design") : "Test Vault", role: "owner", hasResources: true, revision: 1, createdAt: "2026-09-07T00:00:00Z" };
const vaults = [vault];
const projects = Array.from({ length: previewMode ? 4 : 40 }, (_, index) => ({ projectId: `p${index}`, vaultId: "v1", name: previewMode ? [ja ? "デザインレビュー" : "Design reviews", ja ? "リサーチ" : "Research", ja ? "リリース計画" : "Release planning", ja ? "チーム定例" : "Team meetings"][index]! : `Project ${index}`, path: previewMode ? [ja ? "デザインレビュー" : "Design reviews", ja ? "リサーチ" : "Research", ja ? "リリース計画" : "Release planning", ja ? "チーム定例" : "Team meetings"][index]! : `Project ${index}`, revision: 1, directMeetingCount: 0, subtreeMeetingCount: 0 }));
const previewSummary = {
  schemaVersion: 3, title: ja ? "初回体験を、もっとシンプルに" : "A simpler first impression", description: ja ? "初めてのユーザーが迷わず最初のミーティングにたどり着くために、案内と操作を見直しました。" : "We reviewed how new users find their first meeting and agreed on a clearer, more focused onboarding flow.",
  tags: ["design", "onboarding"],
  sections: [
    { id: "section-1", heading: ja ? "決まったこと" : "Decisions", blocks: [{ id: "block-1", type: "bulleted_list", items: [
      { text: ja ? "初回は「保管庫を選ぶ」「ミーティングを開く」の2つに操作を絞る。" : "Focus the first visit on two actions: choose a Vault and open a meeting." },
      { text: ja ? "設定は後から変更できるため、初回のフローから外す。" : "Move optional configuration out of the first-run experience." },
      { text: ja ? "空の画面には、次に何をすればよいかを具体的に示す。" : "Give empty screens a clear explanation of what happens next." },
    ] }] },
    { id: "section-2", heading: ja ? "ユーザーリサーチからの気づき" : "What we learned", blocks: [{ id: "block-2", type: "paragraph", content: { text: ja ? "ユーザーは細かな設定よりも、自分の会話がどこに保存され、誰と共有されているかを最初に確認したいと考えています。閲覧と共有の状態が同じ場所で分かる構成が必要です。" : "People want to know where their conversations are saved and who can see them before adjusting individual settings. The library should make that context visible without interrupting reading." } }] },
    { id: "section-3", heading: ja ? "次のステップ" : "Next steps", blocks: [{ id: "block-3", type: "checklist", items: [
      { text: ja ? "改訂したプロトタイプで5名のユーザーテストを実施する" : "Test the revised prototype with five new users", checked: false },
      { text: ja ? "モバイル幅で検索と編集の導線を検証する" : "Validate search and editing on narrow screens", checked: false },
    ] }] },
  ], actionItems: [],
};
const meeting = (id: string) => ({ meetingId: id, vaultId: "v1", projectId: "p0", name: id === "m1" ? meetingName : previewMode ? (ja ? "9月のリリース計画と優先順位" : "September release planning & priorities") : "Other meeting", description: previewMode ? (ja ? "プロダクト・デザインチームの週次レビュー" : "Weekly product and design team review") : "", duration: previewMode ? 2540 : undefined, status: "recording", revision: 1, summaryRevision: 1, createdAt: vault.createdAt, summaryDocument: JSON.stringify(previewMode ? previewSummary : { sections: [{ heading: summary, blocks: [] }] }) });
const image = "data:image/svg+xml," + encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="600" height="400"><rect width="600" height="400" fill="#aaa"/></svg>');
const file = (index: number) => ({ id: `f${index}`, capturedAt: vault.createdAt, file: { id: `f${index}`, vaultId: "v1", name: `Screenshot ${index}.png`, contentType: "image/png", variants: { thumb_480: image, thumb_1568: image }, metadata: { source: navigationTest && (index === 2 || index === 3) ? "upload" : "screenshot", caption: index === 0 ? caption : `Screenshot ${index}` } } });
window.EventSource = class extends EventTarget {
  constructor() { super(); sources.push(this); queueMicrotask(() => this.dispatchEvent(new Event("open"))); }
  close() { sources.splice(sources.indexOf(this), 1); }
} as unknown as typeof EventSource;
window.fetch = async (input, init) => {
  const request = input instanceof Request ? input : new Request(new URL(input, location.origin), init);
  const url = new URL(typeof input === "string" ? input : input instanceof URL ? input.href : input.url, location.origin);
  requests.push(url.pathname);
  requestURLs.push(url.pathname + url.search);
  const failure = failures.get(url.pathname);
  if (failure) return Response.json({ code: `fixture_${failure}` }, { status: failure });
  if (url.pathname === `${base}/search`) return Response.json({
    meetings: [{ id: "m1", kind: "meeting", title: meeting("m1").name, projectPath: "", date: meeting("m1").createdAt, snippet: "" }],
    projects: [{ id: "p0", kind: "project", title: projects[0]!.name, projectPath: projects[0]!.path, date: vault.createdAt, snippet: "" }],
    screenshots: [], limited: { meetings: false, projects: false, screenshots: false },
  });
  if (url.pathname === "/api/v1/account/settings") return Response.json({ settings: null });
  if (url.pathname === "/api/v1/models") return Response.json({ data: [{ id: "gpt-5.4", display_name: "GPT-5.4" }], models: [{ slug: "gpt-5.4", supported_reasoning_levels: [{ effort: "medium" }], default_reasoning_level: "medium" }] });
  if (url.pathname === "/api/v1/capabilities") return Response.json(previewMode ? { meetingSummaryGeneration: { version: 1, sources: ["transcript"] } } : {});
  if (url.pathname === "/api/v1/session") return Response.json({ user: { id: "browser-fixture", name: previewMode ? "Yuki Tanaka" : "Tester", email: "yuki@example.com" }, workspace: { id: "w1", type: "personal" }, capabilities: { sync: true, sharing: true, sessions: false, admin: false } });
  if (url.pathname === "/api/v1/organizations") return Response.json({ items: [{ id: "o1", name: "Test Organization" }], nextCursor: null });
  if (url.pathname === "/api/v1/vaults") return Response.json({ items: vaults });
  if (url.pathname === "/api/v1/vaults/v2/meetings") return Response.json({ items: [] });
  if (url.pathname === "/api/v1/organizations/o1/teams") return Response.json({ items: [], nextCursor: null });
  if (url.pathname === `${base}/permission-targets`) return Response.json({ items: [{ principalType: "organization", principalId: "o1", name: "Example organization", detail: "example" }] });
  if (url.pathname === `${base}/permissions`) return Response.json({ items: sharingEnabled ? [{ principalType: "organization", principalId: "o1", role: "member" }] : [] });
  if (url.pathname === `${base}/permissions/organizations/o1`) {
    sharingEnabled = request.method === "PUT";
    return new Response(null, { status: 204 });
  }
  if (url.pathname === base) return Response.json(vault);
  if (url.pathname.startsWith("/api/v1/projects/")) {
    const project = projects.find((p) => p.projectId === url.pathname.split("/").at(-1));
    return project ? Response.json(project) : Response.json({ error: "project_not_found" }, { status: 404 });
  }
  if (/^\/api\/v1\/meetings\/[^/]+$/.test(url.pathname)) return Response.json(meeting(url.pathname.split("/").at(-1)!));
  if (url.pathname.startsWith("/api/v1/files/")) return Response.json(file(Number(url.pathname.split("/").at(-1)!.slice(1))).file);
  if (url.pathname === `${base}/projects`) return Response.json({ items: projects });
  if (url.pathname.startsWith(`${base}/projects/`)) return Response.json(projects.find((p) => p.projectId === url.pathname.split("/").at(-1)));
  if (url.pathname === `${base}/meetings`) return Response.json({ items: (url.searchParams.get("projectId") === "p0" && projects.some((project) => project.projectId === "p0")) || (!url.searchParams.has("projectId") && !url.searchParams.has("projectScope")) ? [meeting("m1"), meeting("m2")] : [] });
  if (url.pathname.endsWith("/transcripts/latest")) return Response.json({ version: 1, syncRevision: 1, transcript: null, items: [{ segmentId: "s1", startedAt: vault.createdAt, text: transcript }], nextCursor: null });
  if (url.pathname.endsWith("/transcripts")) return Response.json({ items: [] });
  if (url.pathname.endsWith("/summary-jobs/latest")) return Response.json({ job: null });
  if (url.pathname.endsWith("/summaries/latest")) return Response.json({ version: 1, revision: 1, present: true, record: { title: previewMode ? previewSummary.title : "Summary", document: meeting("m1").summaryDocument } });
  if (url.pathname.endsWith("/summaries")) return Response.json({ items: [] });
  if (url.pathname.endsWith("/files")) {
    const offset = Number(url.searchParams.get("cursor") ?? 0);
    const files = Array.from({ length: fileCount }, (_, index) => index).filter((index) => index !== omittedFile);
    const end = Math.min(offset + filePageSize, files.length);
    return Response.json({ items: files.slice(offset, end).map(file), nextCursor: end < files.length ? String(end) : null });
  }
  if (url.pathname.startsWith(`${base}/meetings/`)) return Response.json(meeting(url.pathname.split("/").at(-1)!));
  if (url.pathname === "/api/v1/transactions") {
    const body: { id: string; operations: { entity: string; action: string; entityId: string; baseRevision?: number; data: { name?: string; preservePermissions?: boolean; icon?: string; color?: string } }[] } = await request.json();
    for (const op of body.operations) {
      if (op.entity === "vault" && op.action === "update") Object.assign(vault, op.data);
      if (op.entity === "vault" && op.action === "reset") {
        assert(op.baseRevision === vault.revision && op.data.preservePermissions === false, "Vault deletion must check revision and remove permissions");
        vaults.splice(vaults.findIndex((v) => v.vaultId === op.entityId), 1);
      }
      if (op.entity === "meeting") meetingName = op.data.name!;
      if (op.entity === "project" && op.action === "create") projects.push({ ...projects[0]!, projectId: op.entityId, ...op.data, name: op.data.name!, path: op.data.name! });
      if (op.entity === "project" && op.action === "update" && "parentProjectId" in op.data && op.data.parentProjectId) assert(op.data.icon === undefined && op.data.color === undefined, "Child Project update included appearance");
      if (op.entity === "project" && op.action === "update") Object.assign(projects.find((p) => p.projectId === op.entityId)!, { ...op.data, name: op.data.name!, path: op.data.name! });
      if (op.entity === "project" && op.action === "delete") projects.splice(projects.findIndex((p) => p.projectId === op.entityId), 1);
    }
    return Response.json({ id: body.id, status: "committed" });
  }
  throw new Error(`Unexpected fixture request: ${url.pathname}`);
};

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
async function editDialog(name: string, description = "") {
  await until(() => document.querySelector('.action-dialog input') && !document.querySelector<HTMLButtonElement>('.action-dialog [data-cancel]')?.disabled);
  const input = document.querySelector<HTMLInputElement>('.action-dialog input')!;
  Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(input, name);
  input.dispatchEvent(new Event("input", { bubbles: true }));
  const textarea = document.querySelector<HTMLTextAreaElement>('.action-dialog textarea');
  if (textarea) {
    Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, "value")!.set!.call(textarea, description);
    textarea.dispatchEvent(new Event("input", { bubbles: true }));
  }
  await new Promise(requestAnimationFrame);
  document.querySelector<HTMLButtonElement>('.action-dialog [data-confirm]')!.click();
}
function notify(type = "invalidation") { for (const source of sources) source.dispatchEvent(new Event(type)); }
function options(control: HTMLButtonElement) {
  return [...(document.getElementById(control.getAttribute("aria-controls")!)?.querySelectorAll<HTMLButtonElement>('[role="option"]') ?? [])];
}
function choose(control: HTMLButtonElement, value: string) {
  control.click();
  const option = options(control).find((option) => option.value === value);
  assert(option, `Missing option ${value}`);
  option.click();
}
function selectedTab() { return document.querySelector('[role="tab"][aria-selected="true"]')?.textContent; }

async function verifyMeetingImageNavigation(route: string) {
  const fileLink = document.querySelector<HTMLAnchorElement>('a[href="/files/f1"]')!;
  fileLink.click();
  await until(() => document.querySelector<HTMLDialogElement>(".file-dialog")?.matches(":modal") && document.querySelector<HTMLImageElement>(".file-preview-image")?.complete);
  const dialog = document.querySelector<HTMLDialogElement>(".file-dialog")!;
  assert(location.pathname === route, "Opening modal changed the page URL");
  dialog.querySelector<HTMLButtonElement>('[aria-label="Next image"]')!.click();
  const nextCaption = navigationTest ? "Screenshot 4" : "Screenshot 2";
  await until(() => dialog.querySelector("img")?.getAttribute("alt") === nextCaption);
  const loadedCount = document.querySelectorAll(".screenshot-grid figure").length;
  omittedFile = 1; refreshData();
  await until(() => document.querySelectorAll(".screenshot-grid figure").length === loadedCount - 1 && dialog.querySelector("img")?.getAttribute("alt") === nextCaption);
  omittedFile = undefined; refreshData();
  await until(() => document.querySelectorAll(".screenshot-grid figure").length === loadedCount && dialog.querySelector("img")?.getAttribute("alt") === nextCaption);
  dialog.querySelector<HTMLButtonElement>('[aria-label="Previous image"]')!.click();
  await until(() => dialog.querySelector("img")?.getAttribute("alt") === "Screenshot 1");
  omittedFile = 0; refreshData();
  await until(() => document.querySelectorAll(".screenshot-grid figure").length === loadedCount - 1 && dialog.querySelector("img")?.getAttribute("alt") === "Screenshot 1"
    && dialog.querySelector<HTMLButtonElement>('[aria-label="Previous image"]')?.disabled);
  omittedFile = undefined; refreshData();
  await until(() => document.querySelectorAll(".screenshot-grid figure").length === loadedCount && !dialog.querySelector<HTMLButtonElement>('[aria-label="Previous image"]')?.disabled);
  dialog.querySelector<HTMLButtonElement>('[aria-label="Previous image"]')!.click();
  await until(() => dialog.querySelector("img")?.getAttribute("alt") === caption);
  return { dialog, fileLink: document.querySelector<HTMLAnchorElement>('a[href="/files/f1"]')!, preview: dialog.querySelector("img") };
}

async function verifyTabSelection() {
  const root = createRoot(document.getElementById("root")!);
  const tabs = ["Meetings", "Permissions", "Settings"].map((label) => ({ id: label, label, content: label }));
  root.render(<DetailTabs label="Test tabs" tabs={[tabs[0]!, tabs[2]!]} />);
  await until(() => selectedTab() === "Meetings");
  button("Settings").click();
  await until(() => selectedTab() === "Settings");
  root.render(<DetailTabs label="Test tabs" tabs={tabs} />);
  await until(() => document.querySelectorAll('[role="tab"]').length === 3);
  assert(selectedTab() === "Settings", "Inserted tab replaced the selected tab");
  root.render(<DetailTabs label="Test tabs" tabs={tabs.slice(0, 2)} />);
  await until(() => selectedTab() === "Meetings");
  root.render(<DetailTabs label="Test tabs" tabs={tabs} />);
  await until(() => document.querySelectorAll('[role="tab"]').length === 3);
  assert(selectedTab() === "Meetings", "Returning tab replaced the fallback selection");
  for (const [key, label] of [["End", "Settings"], ["ArrowLeft", "Permissions"], ["Home", "Meetings"]]) {
    document.querySelector<HTMLElement>('[role="tab"][aria-selected="true"]')!.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true }));
    await until(() => selectedTab() === label);
    assert(document.activeElement === button(label!), "Tab keyboard navigation lost focus");
  }
  root.unmount();
}

async function run() {
  if (!previewMode && !navigationTest) await verifyTabSelection();
  if (navigationTest) {
    history.replaceState(null, "", route);
    createRoot(document.getElementById("root")!).render(<StrictMode><SyncedMeeting vaultId="v1" meetingId="m1" /></StrictMode>);
    await until(() => document.querySelector('[role="tab"]'));
    button("Screenshots").click();
    await until(() => document.querySelectorAll(".screenshot-grid figure").length === filePageSize);
    const { dialog, fileLink } = await verifyMeetingImageNavigation(location.pathname);
    dialog.querySelector<HTMLButtonElement>('[aria-label="Close"]')!.click();
    await until(() => !document.querySelector(".file-dialog"));
    assert(document.activeElement === fileLink, "Closing a navigated modal did not restore focus");
    document.body.dataset.testResult = "passed";
    console.log("PASS: meeting image navigation survives live list updates");
    return;
  }
  history.replaceState(null, "", "/vaults/v1/meetings/m1");
  createRoot(document.getElementById("root")!).render(<StrictMode><App /></StrictMode>);
  await until(() => document.querySelector('[role="tab"]') && document.querySelector('.meeting-row a[href="/meetings/m2"]') && ![...document.querySelectorAll(".sidebar-status")].some((node) => node.textContent?.includes("Loading")));
  await document.fonts.ready;
  if (previewMode) {
    const { navigateDashboard } = await import("../../src/client/navigation");
    if (previewPage === "home") navigateDashboard("/dashboard");
    if (previewPage === "vault") navigateDashboard("/vaults/v1");
    if (previewPage === "settings") navigateDashboard("/dashboard/settings");
    return;
  }
  assert(document.querySelector('.unassigned-meetings h2')?.textContent === "Unassigned" && !document.querySelector('.unassigned-meetings .folder-icon'), "Unassigned meetings must have a separate section without a folder icon");
  assert(!document.querySelector('#account-menu a[href^="/vaults"]') && document.querySelector('.primary-navigation a[href="/vaults"]'), "Vault navigation belongs in the sidebar, not the account menu");
  assert(document.querySelector('.identity-copy small')?.textContent === "No organization selected", "Account identity must show the account context instead of the selected Vault");
  const library = document.querySelector(".primary-navigation")!;
  assert(library.querySelector('a[aria-label="Home"] svg') && library.querySelector('a[aria-label="Vaults"] svg') && library.querySelector('button[aria-label="Search"]'), "Library icons and search must remain accessible together");
  const homeLink = library.querySelector<HTMLAnchorElement>('a[aria-label="Home"]')!;
  homeLink.focus();
  const help = document.getElementById(homeLink.getAttribute("aria-describedby")!)!;
  assert(getComputedStyle(help).visibility === "visible", "Keyboard focus must show navigation help");
  homeLink.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  await until(() => getComputedStyle(help).visibility === "hidden");
  const vaultMenu = document.querySelector<HTMLElement>("#vault-menu")!;
  document.querySelector<HTMLButtonElement>(".vault-switcher-trigger")!.click();
  assert(vaultMenu.matches(":popover-open") && vaultMenu.querySelector('a[aria-current="true"]'), "Vault chooser must open with the current selection");
  vaultMenu.hidePopover();
  const { navigateDashboard } = await import("../../src/client/navigation");
  navigateDashboard("/dashboard");
  await until(() => document.querySelector('.recent-meetings a[href="/meetings/m1"]'));
  const recentSelector = () => document.querySelector(".recent-meetings")!.querySelector<HTMLButtonElement>('[role="combobox"]')!;
  const recentRow = document.querySelector('.recent-meetings a[href="/meetings/m1"]');
  const otherVault = { ...vault, vaultId: "v2", name: "Another Vault" };
  vaults.unshift(otherVault); notify();
  await until(() => options(recentSelector()).length === 2);
  assert(recentSelector().value === "v1", "New Vault changed the initial Home selection");
  assert(document.querySelector('.recent-meetings a[href="/meetings/m1"]') === recentRow, "Vault reorder replaced recent meeting rows");
  choose(recentSelector(), "v2");
  await until(() => document.querySelector(".recent-meetings .welcome-empty"));
  vaults.reverse(); notify();
  await until(() => options(recentSelector())[0]?.value === "v1");
  assert(recentSelector().value === "v2", "Vault reorder changed an explicit Home selection");
  vaults.splice(vaults.indexOf(otherVault), 1); notify();
  await until(() => options(recentSelector()).length === 1 && recentSelector().value === "v1");
  vaults.unshift(otherVault); notify();
  await until(() => options(recentSelector()).length === 2);
  assert(recentSelector().value === "v1", "Returning Vault replaced the fallback Home selection");
  failures.set("/api/v1/vaults", 503); notify();
  await until(() => document.querySelector('.workspace [role="alert"]'));
  assert(recentSelector().value === "v1", "Transient Vault failure reset the Home selection");
  failures.clear(); vaults.splice(0, vaults.length, vault); notify();
  await until(() => !document.querySelector('.workspace [role="alert"]'));
  navigateDashboard("/meetings/m1");
  await until(() => document.querySelector('[role="tab"]'));
  const navigation = document.querySelector<HTMLDialogElement>(".sidebar-container")!;
  if (!window.matchMedia("(max-width: 820px)").matches) {
    navigateDashboard(location.pathname);
    assert(navigation.open && !navigation.matches(":modal"), "Same-page navigation closed the desktop sidebar");
  }
  for (const target of ["/meetings/m1", "/projects/p0"]) {
    navigateDashboard(target);
    await until(() => document.querySelector(".meeting-header h1"));
    navigation.close(); navigation.showModal();
    document.querySelector<HTMLButtonElement>(".sidebar-search")!.click();
    await until(() => document.querySelector(".search-result"));
    document.querySelector<HTMLDialogElement>(".search-dialog")!.dispatchEvent(new Event("cancel", { cancelable: true }));
    await until(() => !document.querySelector(".search-dialog"));
    assert(navigation.matches(":modal"), "Canceling search dismissed navigation");
    document.querySelector<HTMLButtonElement>(".sidebar-search")!.click();
    await until(() => document.querySelectorAll(".search-result").length === 2);
    document.querySelectorAll<HTMLButtonElement>(".search-result")[target.startsWith("/meetings/") ? 0 : 1]!.click();
    await until(() => !document.querySelector(".search-dialog"));
    assert(location.pathname === target && !navigation.open, "Same-page search result left navigation open");
  }
  navigateDashboard("/meetings/m1");
  await until(() => [...document.querySelectorAll('[role="tab"]')].some((tab) => tab.textContent === "Screenshots"));
  if (!window.matchMedia("(max-width: 820px)").matches) navigation.show();
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
  const sessionReads = requests.filter((url) => url === "/api/v1/session").length;
  caption = "Updated caption"; summary = "Updated summary"; transcript = "Updated transcript"; fileCount = 4;
  for (let index = 0; index < 20; index++) notify();
  await until(() => document.querySelectorAll(".screenshot-grid figure").length === 4 && document.querySelector("figcaption")?.textContent === caption);
  assert(selectedTab() === "Screenshots", "Tab changed on invalidation");
  assert(tab === button("Screenshots") && img === document.querySelector(".screenshot-grid img"), "Existing tab/image DOM replaced");
  assert(row === document.querySelector('.meeting-row a'), "Sidebar row remounted");
  assert(sidebar.scrollTop === sidebarScroll, `Sidebar scrolled from ${sidebarScroll} to ${sidebar.scrollTop}`);
  assert(documentNode === document.documentElement && main === document.querySelector(".workspace"), "Document/main replaced");
  assert(requests.filter((url) => url === "/api/v1/session").length === sessionReads, "Sync notification refreshed session");
  assert(location.pathname === route, "Legacy URL did not resolve to canonical meeting URL");
  const { dialog, fileLink, preview } = await verifyMeetingImageNavigation(route);
  caption = "Modal updated caption";
  notify();
  await until(() => preview?.getAttribute("alt") === caption);
  assert(preview === dialog.querySelector("img") && dialog.matches(":modal"), "Live refresh replaced or closed modal");
  failures.set("/api/v1/files/f0", 404); notify();
  await until(() => dialog.querySelector('[role="alert"]') && !dialog.querySelector("img"));
  assert(dialog.matches(":modal") && selectedTab() === "Screenshots", "File failure changed its background page");
  failures.clear();
  dialog.querySelector<HTMLButtonElement>('[role="alert"] button')!.click();
  await until(() => dialog.querySelector<HTMLImageElement>("img")?.complete);
  dialog.querySelector<HTMLButtonElement>('[aria-label="Close"]')!.click();
  await until(() => !document.querySelector(".file-dialog"));
  assert(document.activeElement === fileLink, "Closing modal did not restore focus");
  assert(document.body.style.overflow !== "hidden", "Closing modal left scrolling locked");
  const figure = document.querySelector(".screenshot-grid figure")!;
  const neighboringImage = document.querySelectorAll(".screenshot-grid img")[1];
  for (const retry of [() => button("Retry").click(), () => notify("open"), () => notify(), () => window.dispatchEvent(new Event("online"))]) {
    figure.querySelector("img")!.dispatchEvent(new Event("error"));
    await until(() => figure.querySelector('[role="alert"]') && !figure.querySelector("img"));
    retry();
    await until(() => { const image = figure.querySelector("img"); return image?.complete && image.naturalWidth > 0; });
    assert(figure === document.querySelector(".screenshot-grid figure"), "Thumbnail retry replaced figure");
    assert(neighboringImage === document.querySelectorAll(".screenshot-grid img")[1], "Thumbnail retry replaced healthy image");
    assert(selectedTab() === "Screenshots", "Thumbnail retry reset tab");
  }
  document.querySelector<HTMLButtonElement>('[aria-label="Expand Project 1"]')?.click();
  await until(() => [...document.querySelectorAll(".sidebar-status")].some((node) => node.textContent === "No meetings"));
  const emptyRow = [...document.querySelectorAll(".sidebar-status")].find((node) => node.textContent === "No meetings")!;
  let releaseEmpty!: () => void;
  let emptyReadStarted = false;
  const emptyRead = new Promise<void>((resolve) => { releaseEmpty = resolve; });
  const fetchBeforeEmpty = window.fetch.bind(window);
  window.fetch = async (input, init) => {
    const response = await fetchBeforeEmpty(input, init);
    if (new URL(input instanceof Request ? input.url : input, location.origin).searchParams.get("projectId") === "p1") {
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
  failures.set("/api/v1/meetings/m1", 503); notify();
  await until(() => document.querySelector('[role="alert"]')?.textContent?.includes("fixture_503"));
  assert(selectedTab() === "Screenshots", "Transient failure unmounted tabs");
  assert(row === document.querySelector('.meeting-row a'), "Sidebar refresh failure replaced the tree");
  failures.clear();
  for (const retry of [...document.querySelectorAll<HTMLButtonElement>("button")].filter((b) => b.textContent === "Retry")) retry.click();
  await until(() => !document.querySelector('[role="alert"]'));
  failures.set("/api/v1/transactions", 409);
  button("⋯ Actions").click(); button("Edit Meeting").click();
  await editDialog("Failed edit", "Description");
  await until(() => document.querySelector('.action-dialog [role="alert"]')?.textContent?.includes("fixture_409"));
  assert(document.querySelector<HTMLInputElement>('.action-dialog input')?.value === "Failed edit", "Failed save discarded the draft");
  failures.clear();
  await editDialog("Edited meeting", "Description");
  await until(() => document.querySelector(".meeting-header h1")?.textContent === "Edited meeting");
  await until(() => !document.querySelector('.action-dialog'));
  assert(selectedTab() === "Screenshots", "Editing reset tab");
  assert(requests.filter((url) => url === "/api/v1/session").length === sessionReads, "Transaction refreshed session");
  let release!: () => void;
  const held = new Promise<void>((resolve) => { release = resolve; });
  const heldSignals: AbortSignal[] = [];
  const normalFetch = window.fetch.bind(window);
  window.fetch = async (input, init) => {
    const response = await normalFetch(input, init);
    const request = input instanceof Request ? input : new Request(new URL(input, location.origin), init);
    if (new URL(request.url).pathname === "/api/v1/meetings/m1") {
      heldSignals.push(request.signal);
      await held; // Deliberately ignore abort to exercise stale completion guards.
    }
    return response;
  };
  notify();
  await until(() => heldSignals.length >= 2);
  document.querySelector<HTMLAnchorElement>('a[href="/meetings/m2"]')!.click();
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
  button("Permissions").click();
  await until(() => [...document.querySelectorAll("button")].some((button) => button.textContent === "Manage sharing"));
  button("Manage sharing").click();
  await until(() => document.querySelector<HTMLInputElement>(".share-row input"));
  const shareCheckbox = document.querySelector<HTMLInputElement>(".share-row input")!;
  assert(!shareCheckbox.checked, "Sharing fixture started enabled");
  sharingEnabled = true;
  notify();
  await until(() => shareCheckbox.checked);
  assert(shareCheckbox === document.querySelector(".share-row input"), "Sharing update replaced checkbox");
  shareCheckbox.click();
  await until(() => !shareCheckbox.checked && !sharingEnabled);
  button("Done").click();
  button("Meetings").click();
  await until(() => document.querySelector('input[aria-label="Search meetings"]'));
  const search = document.querySelector<HTMLInputElement>('input[aria-label="Search meetings"]')!;
  Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(search, "recording");
  search.dispatchEvent(new Event("input", { bubbles: true }));
  await until(() => requestURLs.some((url) => url.includes("query=recording")));
  notify();
  await new Promise(requestAnimationFrame);
  assert(search.value === "recording", "Live refresh reset search input");
  const filter = document.querySelector<HTMLButtonElement>('[role="combobox"][aria-label="Filter by Project"]')!;
  choose(filter, "p0");
  await until(() => requestURLs.some((url) => url.includes("query=recording&projectId=p0")));
  failures.set(`${base}/projects`, 503); notify();
  await until(() => document.querySelector(".workspace .error")?.textContent?.includes("fixture_503"));
  assert(filter.value === "p0", "Transient Project failure reset filter");
  failures.clear(); notify();
  await until(() => !document.querySelector(".workspace .error"));
  assert(filter.value === "p0", "Refresh reset valid Project filter");
  const removedProjects = projects.splice(0);
  notify();
  await until(() => !document.querySelector('[aria-label="Filter by Project"]') && document.querySelector('.workspace a[href="/meetings/m1"]'));
  assert(search.value === "recording", "Deleted Project reset search text");
  projects.push(...removedProjects); notify();
  await until(() => document.querySelector('[aria-label="Filter by Project"]'));
  assert(document.querySelector<HTMLButtonElement>('[role="combobox"][aria-label="Filter by Project"]')!.value === "", "Deleted Project filter was restored");
  button("Projects").click();
  await until(() => [...document.querySelectorAll("button")].some((b) => b.textContent === "New Project"));
  button("New Project").click(); await editDialog("New project");
  await until(() => document.querySelector("h1")?.textContent === "New project");
  assert(!document.querySelector('[aria-label="Project actions"]'), "Project actions should be in Settings");
  assert(document.querySelector('[role="tab"][aria-selected="true"]')?.textContent === "Meetings", "Project should open Meetings first");
  failures.set("/api/v1/transactions", 409);
  button("Settings").click();
  await until(() => [...document.querySelectorAll("button")].some((button) => button.textContent === "Edit Project"));
  button("Edit Project").click(); await editDialog("Failed project edit", "Description");
  await until(() => document.querySelector(".action-dialog .dialog-error")?.textContent?.includes("fixture_409"));
  failures.clear();
  await editDialog("Edited project", "Description");
  await until(() => document.querySelector("h1")?.textContent === "Edited project");
  await until(() => !document.querySelector('.action-dialog'));
  button("Delete Project").click();
  await until(() => document.querySelector('.action-dialog [data-confirm]'));
  document.querySelector<HTMLButtonElement>('.action-dialog [data-confirm]')!.click();
  await until(() => location.pathname === "/vaults/v1");
  document.querySelector<HTMLButtonElement>('[popoverTarget="account-menu"]')!.click();
  button("Test Organization").click();
  await until(() => location.pathname === "/vaults" && requests.some((url) => url === "/api/v1/vaults"));
  assert(documentNode === document.documentElement, "Organization switch reloaded document");
  document.querySelector<HTMLAnchorElement>('a[href="/meetings/m1"]')?.click();
  // Use the existing internal navigation helper when the newly scoped tree is still loading.
  navigateDashboard("/files/f0");
  await until(() => document.querySelector<HTMLImageElement>(".file-preview-image")?.complete);
  assert(!document.querySelector(".file-dialog"), "Standalone file URL opened a modal");
  navigateDashboard(route);
  await until(() => document.querySelector('[role="tab"]'));
  failures.set("/api/v1/meetings/m1", 403); notify();
  await until(() => !document.querySelector('[role="tab"]'));
  assert(document.querySelector('[role="alert"]')?.textContent?.includes("fixture_403"), "Missing access-denied feedback");
  failures.clear();
  for (const retry of [...document.querySelectorAll<HTMLButtonElement>("button")].filter((b) => b.textContent === "Retry")) retry.click();
  await until(() => document.querySelector('[role="tab"]'));
  failures.set("/api/v1/meetings/m1", 404); notify();
  await until(() => !document.querySelector('[role="tab"]'));
  assert(document.querySelector('[role="alert"]')?.textContent?.includes("fixture_404"), "Deleted meeting remained visible");
  failures.clear();
  navigateDashboard("/vaults/v1");
  await until(() => [...document.querySelectorAll('[role="tab"]')].some((tab) => tab.textContent === "Settings"));
  button("Projects").click();
  await until(() => document.querySelector('.collection-project-name'));
  const projectLabel = document.querySelector('.collection-project-name strong')!.getBoundingClientRect();
  const projectIcon = document.querySelector('.collection-project-name .appearance-icon')!.getBoundingClientRect();
  assert(projectLabel.left - projectIcon.right <= 12, "Project name separated from its icon");
  button("Settings").click();
  await until(() => [...document.querySelectorAll("button")].some((b) => b.textContent === "Delete Vault"));
  button("Edit Vault").click();
  await until(() => document.querySelector('.appearance-trigger'));
  const titleBounds = document.querySelector('.dialog-header h2')!.getBoundingClientRect();
  const symbolBounds = document.querySelector('.dialog-symbol')!.getBoundingClientRect();
  assert(titleBounds.left > symbolBounds.right && Math.abs(titleBounds.top - symbolBounds.top) < 12, "Dialog title is not beside its icon");
  document.querySelector<HTMLButtonElement>('.appearance-trigger')!.click();
  await until(() => document.querySelector('.appearance-popover:popover-open'));
  const paletteBounds = document.querySelector('.appearance-popover')!.getBoundingClientRect();
  const nameBounds = document.querySelector('.appearance-name-field')!.getBoundingClientRect();
  assert(paletteBounds.top >= nameBounds.bottom && paletteBounds.right <= window.innerWidth, "Appearance palette obscures the name or leaves the viewport");
  document.querySelector<HTMLButtonElement>('.appearance-popover button[aria-label="Green"]')!.click();
  await until(() => document.querySelector('.appearance-popover button[aria-label="Green"]')?.getAttribute("aria-pressed") === "true");
  document.querySelector<HTMLButtonElement>('.appearance-popover button[aria-label="Book"]')!.click();
  await until(() => document.querySelector('.appearance-popover button[aria-label="Book"]')?.getAttribute("aria-pressed") === "true");
  document.querySelector<HTMLElement>('.appearance-popover')!.hidePopover();
  document.querySelector<HTMLButtonElement>('.action-dialog [data-confirm]')!.click();
  await until(() => !document.querySelector('.action-dialog') && document.querySelector('h1 .appearance-icon')?.getAttribute("style")?.includes("34, 197, 94"));
  const sidebarIcon = document.querySelector('.vault-switcher-trigger .appearance-icon')!;
  assert(sidebarIcon.getBoundingClientRect().width === 18, "Vault icon expanded into the label space");
  assert(getComputedStyle(document.querySelector('h1 .appearance-icon svg')!).color === getComputedStyle(sidebarIcon).color, "Heading and sidebar icon colors differ");
  const child = { ...projects[1]!, parentProjectId: projects[0]!.projectId, icon: "heart", color: "red" };
  Object.assign(projects[0]!, { icon: "book.closed", color: "green" });
  Object.assign(projects[1]!, child);
  navigateDashboard(`/projects/${child.projectId}`);
  await until(() => document.querySelector("h1")?.textContent === child.name && document.querySelector('h1 .appearance-icon')?.getAttribute("style")?.includes("34, 197, 94"));
  button("Settings").click();
  await until(() => [...document.querySelectorAll("button")].some((button) => button.textContent === "Edit Project"));
  button("Edit Project").click();
  await until(() => document.querySelector('.action-dialog .appearance-trigger'));
  assert(document.querySelector('.action-dialog .appearance-trigger')?.tagName === "SPAN" && !document.querySelector('.appearance-popover'), "Child Project exposed an editable appearance");
  await editDialog("Renamed child");
  await until(() => !document.querySelector('.action-dialog'));
  navigateDashboard("/vaults/v1");
  await until(() => [...document.querySelectorAll('[role="tab"]')].some((tab) => tab.textContent === "Settings"));
  button("Settings").click();
  await until(() => [...document.querySelectorAll("button")].some((b) => b.textContent === "Delete Vault"));
  assert(button("Delete Vault").disabled, "Nonempty Vault allowed deletion");
  vault.hasResources = false;
  notify();
  await until(() => !button("Delete Vault").disabled);
  button("Delete Vault").click();
  await until(() => document.querySelector('.action-dialog [data-confirm]'));
  assert(vaults.some((v) => v.vaultId === "v1"), "Opening confirmation deleted the Vault");
  failures.set("/api/v1/transactions", 409);
  document.querySelector<HTMLButtonElement>('.action-dialog [data-confirm]')!.click();
  await until(() => document.querySelector('.action-dialog .dialog-error'));
  assert(String(location.pathname) === "/vaults/v1" && vaults.some((v) => v.vaultId === "v1"), "Failed deletion left the Vault page");
  failures.clear();
  document.querySelector<HTMLButtonElement>('.action-dialog [data-confirm]')!.click();
  await until(() => location.pathname === "/vaults" && !vaults.some((v) => v.vaultId === "v1"));
  document.body.dataset.testResult = "passed";
  console.log("PASS: live data, DOM identity, scroll, paging, retries, edits, canonical URLs, modal, standalone file, history, create/delete, organization, access revocation");
}
void run().catch((error: unknown) => {
  document.body.dataset.testResult = "failed";
  document.body.dataset.testError = error instanceof Error ? error.stack : String(error);
  console.error(error);
});
