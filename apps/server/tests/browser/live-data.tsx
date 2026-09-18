// Run with pnpm dev:client, then open /tests/browser/live-data.html.
// All API responses and mutations are local fixtures; no backend is contacted.
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App, SyncedMeeting } from "../../src/client/App";
import { DetailTabs } from "../../src/client/MeetingContent";
import { refreshData } from "../../src/client/live-data";
import { encodeId } from "../../src/typeid";
import "../../src/client/styles.css";

const previewMode = new URLSearchParams(location.search).has("preview");
const previewPage = new URLSearchParams(location.search).get("page") ?? "meeting";
const navigationTest = new URLSearchParams(location.search).has("navigation-test");
const performanceTest = new URLSearchParams(location.search).has("performance-test");
Object.defineProperty(navigator, "language", { value: previewMode && new URLSearchParams(location.search).get("lang") === "ja" ? "ja-JP" : "en-US", configurable: true });
const ja = navigator.language.startsWith("ja");
sessionStorage.removeItem("dahlia:sidebar:browser-fixture:organization");

const workspaceId = encodeId("workspace", "019d3f46-8a00-77f1-b232-93726eec3e9e");
const otherWorkspaceId = encodeId("workspace", "019d3f46-8a00-77f1-b232-93726eec3e9f");
const projectId = (index: number) => encodeId("project", `019d3f46-8c00-7000-8000-${String(index).padStart(12, "0")}`);
const fileId = (index: number) => encodeId("file", `019d3f46-8d00-7000-8000-${String(index).padStart(12, "0")}`);
const base = `/api/v1/workspaces/${workspaceId}`;
const primaryMeetingId = encodeId("meeting", "019d3f46-8b72-77f1-b232-93726eec3e9e");
const secondaryMeetingId = encodeId("meeting", "019d3f46-8b72-77f1-b232-93726eec3e9f");
const route = `/meetings/${primaryMeetingId}`;
const sources: EventTarget[] = [];
const requests: string[] = [];
const requestURLs: string[] = [];
const meetingDetailSignals = new Set<AbortSignal>();
let maxConcurrentMeetingDetailReads = 0;
const failures = new Map<string, number>();
let caption = "Initial caption";
let summary = "Initial summary";
let transcript = "Initial transcript";
let fileCount = navigationTest ? 5 : 3;
let omittedFile: number | undefined;
const filePageSize = navigationTest ? 2 : 12;
let sharingEnabled = false;
let meetingName = previewMode ? (ja ? "新しいオンボーディング体験のデザインレビュー" : "Design review: a better first-run experience") : "Recording meeting";
const workspace = { workspaceId, organizationId: "o1", organizationName: previewMode ? (ja ? "ダリア製品チーム" : "Dahlia Product Team") : "Test Organization", name: previewMode ? (ja ? "プロダクト開発" : "Product & design") : "Test Workspace", role: "admin", hasResources: true, meetingDeletionGraceDays: 30, revision: 1, createdAt: "2026-09-07T00:00:00Z" };
const workspaces = [workspace];
const projects = Array.from({ length: previewMode ? 4 : 40 }, (_, index) => ({ projectId: projectId(index), workspaceId, parentProjectId: null as string | null, name: previewMode ? [ja ? "デザインレビュー" : "Design reviews", ja ? "リサーチ" : "Research", ja ? "リリース計画" : "Release planning", ja ? "チーム定例" : "Team meetings"][index]! : `Project ${index}`, path: previewMode ? [ja ? "デザインレビュー" : "Design reviews", ja ? "リサーチ" : "Research", ja ? "リリース計画" : "Release planning", ja ? "チーム定例" : "Team meetings"][index]! : `Project ${index}`, revision: 1, directMeetingCount: 0, subtreeMeetingCount: 0 }));
const previewSummary = {
  schemaVersion: 3, title: ja ? "初回体験を、もっとシンプルに" : "A simpler first impression", description: ja ? "初めてのユーザーが迷わず最初のミーティングにたどり着くために、案内と操作を見直しました。" : "We reviewed how new users find their first meeting and agreed on a clearer, more focused onboarding flow.",
  tags: ["design", "onboarding"],
  sections: [
    { id: "section-1", heading: ja ? "決まったこと" : "Decisions", blocks: [{ id: "block-1", type: "bulleted_list", items: [
      { text: ja ? "初回は「ワークスペースを選ぶ」「ミーティングを開く」の2つに操作を絞る。" : "Focus the first visit on two actions: choose a Workspace and open a meeting." },
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
const meeting = (id: string) => ({ meetingId: id, workspaceId, projectId: projectId(0), name: id === primaryMeetingId ? meetingName : previewMode ? (ja ? "9月のリリース計画と優先順位" : "September release planning & priorities") : "Other meeting", description: previewMode ? (ja ? "プロダクト・デザインチームの週次レビュー" : "Weekly product and design team review") : "", duration: previewMode ? 2540 : undefined, status: "recording", revision: 1, summaryRevision: 1, createdAt: workspace.createdAt, summaryDocument: JSON.stringify(previewMode ? previewSummary : { sections: [{ heading: summary, blocks: [] }] }) });
const image = "data:image/svg+xml," + encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="600" height="400"><rect width="600" height="400" fill="#aaa"/></svg>');
const file = (index: number) => ({ id: fileId(index), capturedAt: workspace.createdAt, file: { id: fileId(index), workspaceId, name: `Screenshot ${index}.png`, contentType: "image/png", variants: { thumb_480: image, thumb_1568: image }, metadata: { source: navigationTest && (index === 2 || index === 3) ? "upload" : "screenshot", caption: index === 0 ? caption : `Screenshot ${index}` } } });
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
    meetings: [{ id: primaryMeetingId, kind: "meeting", title: meeting(primaryMeetingId).name, projectPath: "", date: meeting(primaryMeetingId).createdAt, snippet: "" }],
    projects: [{ id: projectId(0), kind: "project", title: projects[0]!.name, projectPath: projects[0]!.path, date: workspace.createdAt, snippet: "" }],
    screenshots: [], limited: { meetings: false, projects: false, screenshots: false },
  });
  if (url.pathname === "/api/v1/models") return Response.json({ data: [{ id: "gpt-5.4", display_name: "GPT-5.4" }], models: [{ slug: "gpt-5.4", supported_reasoning_levels: [{ effort: "medium" }], default_reasoning_level: "medium" }] });
  if (url.pathname === "/api/v1/capabilities") return Response.json(previewMode ? { meetingSummaryGeneration: { version: 1, sources: ["transcript"] } } : {});
  if (url.pathname === "/api/auth/mode") return Response.json({ provider: "header", mcp: { url: "https://dahlia.example/mcp", proxyUrl: "https://dahlia.aws.databricksapps.com/mcp", databricksProxy: true, available: true } });
  if (url.pathname === "/api/v1/session") return Response.json({ user: { id: "browser-fixture", name: previewMode ? "Yuki Tanaka" : "Tester", email: "yuki@example.com" },  capabilities: { sync: true, sharing: true, sessions: false, admin: false } });
  if (url.pathname === "/api/auth/organization/list") return Response.json([{ id: "o1", name: previewMode ? (ja ? "ダリア製品チーム" : "Dahlia Product Team") : "Test Organization", slug: "test-organization", kind: "team" }]);
  if (url.pathname === "/api/v1/organizations") return Response.json({ items: [{ id: "o1", name: "Test Organization" }], nextCursor: null });
  if (url.pathname === "/api/v1/workspaces") return Response.json({ items: workspaces });
  if (url.pathname === `/api/v1/workspaces/${otherWorkspaceId}/meetings`) return Response.json({ items: [] });
  if (url.pathname === "/api/v1/organizations/o1/teams") return Response.json({ items: [], nextCursor: null });
  if (url.pathname === `${base}/permission-targets`) return Response.json({ items: [{ principalType: "organization", principalId: "o1", name: "Example organization", detail: "example" }] });
  if (url.pathname === `${base}/permissions`) return Response.json({ items: sharingEnabled ? [{ principalType: "organization", principalId: "o1", role: "viewer", name: "Example organization", detail: "example" }] : [] });
  if (url.pathname === `${base}/permissions/organizations/o1`) {
    sharingEnabled = request.method === "PUT";
    return new Response(null, { status: 204 });
  }
  if (url.pathname === base) return Response.json(workspace);
  if (url.pathname.startsWith("/api/v1/projects/")) {
    const project = projects.find((p) => p.projectId === url.pathname.split("/").at(-1));
    return project ? Response.json(project) : Response.json({ error: "project_not_found" }, { status: 404 });
  }
  if (/^\/api\/v1\/meetings\/[^/]+$/.test(url.pathname)) {
    meetingDetailSignals.add(request.signal);
    if (performanceTest) {
      await new Promise(requestAnimationFrame);
      maxConcurrentMeetingDetailReads = Math.max(maxConcurrentMeetingDetailReads,
        [...meetingDetailSignals].filter((signal) => !signal.aborted).length);
    }
    meetingDetailSignals.delete(request.signal);
    return Response.json(meeting(url.pathname.split("/").at(-1)!));
  }
  if (url.pathname.startsWith("/api/v1/files/")) return Response.json(file(Array.from({ length: 100 }, (_, index) => fileId(index)).indexOf(url.pathname.split("/").at(-1)!)).file);
  if (url.pathname === `${base}/projects`) return Response.json({ items: projects });
  if (url.pathname.startsWith(`${base}/projects/`)) return Response.json(projects.find((p) => p.projectId === url.pathname.split("/").at(-1)));
  if (url.pathname === `${base}/meetings`) return Response.json({ items: (url.searchParams.get("projectId") === projectId(0) && projects.some((project) => project.projectId === projectId(0))) || (!url.searchParams.has("projectId") && !url.searchParams.has("projectScope")) ? [meeting(primaryMeetingId), meeting(secondaryMeetingId)] : [] });
  if (url.pathname.endsWith("/transcripts/latest")) return Response.json({ version: 1, syncRevision: 1, transcript: null, items: [{ segmentId: "s1", startedAt: workspace.createdAt, text: transcript }], nextCursor: null });
  if (url.pathname.endsWith("/transcripts")) return Response.json({ items: [] });
  if (url.pathname.endsWith("/summary-jobs/latest")) return Response.json({ job: null });
  if (url.pathname.endsWith("/summaries/latest")) return Response.json({ version: 1, revision: 1, present: true, record: { title: previewMode ? previewSummary.title : "Summary", document: meeting(primaryMeetingId).summaryDocument } });
  if (url.pathname.endsWith("/summaries")) return Response.json({ items: [] });
  if (url.pathname.endsWith("/files")) {
    const offset = Number(url.searchParams.get("cursor") ?? 0);
    const files = Array.from({ length: fileCount }, (_, index) => index).filter((index) => index !== omittedFile);
    const end = Math.min(offset + filePageSize, files.length);
    return Response.json({ items: files.slice(offset, end).map(file), nextCursor: end < files.length ? String(end) : null });
  }
  if (url.pathname.startsWith(`${base}/meetings/`)) return Response.json(meeting(url.pathname.split("/").at(-1)!));
  if (url.pathname === "/api/v1/transactions") {
    const body: { id: string; operations: { entity: string; action: string; entityId: string; baseRevision?: number; data: { name?: string; preservePermissions?: boolean; icon?: string; color?: string; parentProjectId?: string | null } }[] } = await request.json();
    for (const op of body.operations) {
      if (op.entity === "workspace" && op.action === "update") Object.assign(workspace, op.data);
      if (op.entity === "workspace" && op.action === "reset") {
        assert(op.baseRevision === workspace.revision && op.data.preservePermissions === false, "Workspace deletion must check revision and remove permissions");
        workspaces.splice(workspaces.findIndex((v) => v.workspaceId === op.entityId), 1);
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
function menuItem(text: string) {
  const item = [...document.querySelectorAll<HTMLElement>('[role="menuitem"]')].find((element) => element.textContent?.trim() === text);
  assert(item, `Missing menu item: ${text}`);
  return item;
}
function pointerClick(element: HTMLElement) {
  element.dispatchEvent(new PointerEvent("pointerdown", { bubbles: true, button: 0, pointerType: "mouse" }));
  element.dispatchEvent(new PointerEvent("pointerup", { bubbles: true, button: 0, pointerType: "mouse" }));
  element.click();
}
function selectTab(text: string) {
  const tab = [...document.querySelectorAll<HTMLButtonElement>('[role="tab"]')].find((item) => item.textContent?.trim() === text);
  assert(tab, `Missing tab: ${text}`);
  tab.dispatchEvent(new MouseEvent("mousedown", { bubbles: true, button: 0 }));
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
  const list = document.getElementById(control.getAttribute("aria-controls") ?? "");
  return [...(list?.querySelectorAll<HTMLElement>('[role="option"]') ?? [])];
}
async function choose(control: HTMLButtonElement, value: string) {
  if (control.getAttribute("aria-expanded") !== "true") control.click();
  await until(() => options(control).some((option) => option.dataset.value === value));
  const option = options(control).find((option) => option.dataset.value === value)!;
  option.dispatchEvent(new PointerEvent("pointerdown", { bubbles: true, button: 0, pointerType: "mouse" }));
  option.dispatchEvent(new PointerEvent("pointerup", { bubbles: true, button: 0, pointerType: "mouse" }));
}
function selectedTab() { return document.querySelector('[role="tab"][aria-selected="true"]')?.textContent; }

async function verifyMeetingImageNavigation(route: string) {
  const fileLink = document.querySelector<HTMLAnchorElement>(`a[href="/files/${fileId(1)}"]`)!;
  fileLink.click();
  await until(() => document.querySelector<HTMLImageElement>('[role="dialog"][aria-label="File preview"] img')?.complete);
  const dialog = document.querySelector<HTMLElement>('[role="dialog"][aria-label="File preview"]')!;
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
  return { dialog, fileLink: document.querySelector<HTMLAnchorElement>(`a[href="/files/${fileId(1)}"]`)!, preview: dialog.querySelector("img") };
}

async function verifyTabSelection() {
  const root = createRoot(document.getElementById("root")!);
  const tabs = ["Meetings", "Permissions", "Settings"].map((label) => ({ id: label, label, content: label }));
  root.render(<DetailTabs label="Test tabs" tabs={[tabs[0]!, tabs[2]!]} />);
  await until(() => selectedTab() === "Meetings");
  selectTab("Settings");
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
    createRoot(document.getElementById("root")!).render(<StrictMode><SyncedMeeting workspaceId={workspaceId} meetingId={primaryMeetingId} /></StrictMode>);
    await until(() => document.querySelector('[role="tab"]'));
    assert(!requests.some((url) => url === `/api/v1/meetings/${primaryMeetingId}/files`), "Screenshots loaded before opening the tab");
    selectTab("Screenshots");
    await until(() => document.querySelectorAll(".screenshot-grid figure").length === filePageSize);
    assert(requests.some((url) => url === `/api/v1/meetings/${primaryMeetingId}/files`), "Screenshots did not load after opening the tab");
    const { dialog, fileLink } = await verifyMeetingImageNavigation(location.pathname);
    dialog.querySelector<HTMLButtonElement>('[aria-label="Close"]')!.click();
    await until(() => !document.querySelector('[role="dialog"][aria-label="File preview"]'));
    assert(document.activeElement === fileLink, "Closing a navigated modal did not restore focus");
    document.body.dataset.testResult = "passed";
    console.log("PASS: meeting image navigation survives live list updates");
    return;
  }
  history.replaceState(null, "", route);
  createRoot(document.getElementById("root")!).render(<StrictMode><App /></StrictMode>);
  await until(() => document.querySelector('[role="tab"]') && document.querySelector(`aside a[href="/meetings/${secondaryMeetingId}"]`));
  if (performanceTest) {
    assert(maxConcurrentMeetingDetailReads === 1, "Initial route issued duplicate active meeting detail reads");
    assert(!requests.some((url) => url === `/api/v1/meetings/${primaryMeetingId}/files`), "Screenshots loaded before opening the tab");
    selectTab("Screenshots");
    await until(() => requests.some((url) => url === `/api/v1/meetings/${primaryMeetingId}/files`));
    document.body.dataset.testResult = "passed";
    console.log("PASS: meeting detail is shared and screenshots load on demand");
    return;
  }
  await document.fonts.ready;
  if (previewMode) {
    const { navigateDashboard } = await import("../../src/client/navigation");
    if (previewPage === "home") navigateDashboard("/dashboard");
    if (previewPage === "workspace") navigateDashboard(`/workspaces/${workspaceId}`);
    if (previewPage === "settings") navigateDashboard("/dashboard/settings");
    return;
  }
  assert(document.querySelector('#unassigned-heading')?.textContent === "Unassigned" && !document.querySelector('#unassigned-heading svg'), "Unassigned meetings must have a separate section without a folder icon");
  assert(document.querySelector('.primary-navigation a[href="/workspaces"]'), "Workspace navigation is missing from the sidebar");
  assert(!document.querySelector(".identity-copy small"), "Account identity must not repeat Organization or Workspace context");
  const accountMenuTrigger = document.querySelector<HTMLButtonElement>('aside button[aria-label^="Account menu:"]')!;
  pointerClick(accountMenuTrigger);
  await until(() => document.querySelector('[role="menu"]'));
  assert(!document.querySelector('[role="menu"] a[href^="/workspaces"]'), "Workspace navigation leaked into the account menu");
  menuItem("Connect with MCP").click();
  await until(() => document.querySelector('[role="dialog"] pre')?.textContent?.includes("uc-mcp-proxy"));
  assert(document.querySelector('[role="dialog"]')?.textContent?.includes("Databricks Apps authentication"), "Databricks Apps guidance is missing");
  assert(document.querySelector('[role="dialog"] [role="tab"][aria-selected="true"]')?.textContent === "mcp.json", "MCP client selection must use tab semantics");
  const profile = document.querySelector<HTMLInputElement>('[role="dialog"] input')!;
  Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(profile, "engineering");
  profile.dispatchEvent(new Event("input", { bubbles: true }));
  selectTab("Claude Code");
  await until(() => document.querySelector('[role="dialog"] pre')?.textContent?.includes("--profile 'engineering'"));
  Object.defineProperty(navigator, "clipboard", { value: { writeText: () => Promise.reject(new Error("denied")) }, configurable: true });
  button("Copy").click();
  await until(() => document.querySelector('[role="dialog"] [role=alert]')?.textContent?.includes("copy them manually"));
  assert(document.querySelector('[role="dialog"] pre'), "Clipboard failure must keep settings available for manual copy");
  Reflect.deleteProperty(navigator, "clipboard");
  button("Done").click();
  await until(() => !document.querySelector('[role="dialog"]'));
  await until(() => document.activeElement === accountMenuTrigger);
  const library = document.querySelector(".primary-navigation")!;
  assert(library.querySelector('a[aria-label="Home"] svg') && library.querySelector('a[aria-label="Workspaces"] svg') && library.querySelector('button[aria-label="Search"]'), "Library icons and search must remain accessible together");
  const homeLink = library.querySelector<HTMLAnchorElement>('a[aria-label="Home"]')!;
  homeLink.focus();
  await until(() => homeLink.getAttribute("aria-describedby"));
  const help = document.getElementById(homeLink.getAttribute("aria-describedby")!)!;
  assert(getComputedStyle(help).visibility === "visible", "Keyboard focus must show navigation help");
  homeLink.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  await until(() => !help.isConnected || getComputedStyle(help).visibility === "hidden");
  const workspaceTrigger = document.querySelector<HTMLButtonElement>('aside button[aria-label^="Current Workspace:"]')!;
  pointerClick(workspaceTrigger);
  await until(() => document.querySelector('[role="menu"] a[aria-current="true"]'));
  const documentBeforePortalNavigation = document.documentElement;
  document.querySelector<HTMLAnchorElement>(`[role="menu"] a[href="/workspaces/${workspaceId}"]`)!.click();
  await until(() => location.pathname === `/workspaces/${workspaceId}`);
  assert(document.documentElement === documentBeforePortalNavigation, "Workspace menu link reloaded the document");
  const { navigateDashboard } = await import("../../src/client/navigation");
  navigateDashboard("/dashboard");
  await until(() => document.querySelector(`.recent-meetings a[href="/meetings/${primaryMeetingId}"]`));
  const dateEdges = [...document.querySelectorAll<HTMLElement>(".recent-meetings .meeting-list-row .collection-date")].map((date) => Math.round(date.getBoundingClientRect().right));
  assert(dateEdges.length > 1 && new Set(dateEdges).size === 1, "Meeting dates moved with title length");
  const recentSelector = () => document.querySelector(".recent-meetings")!.querySelector<HTMLButtonElement>('[role="combobox"]')!;
  const recentRow = document.querySelector(`.recent-meetings a[href="/meetings/${primaryMeetingId}"]`);
  const otherWorkspace = { ...workspace, workspaceId: otherWorkspaceId, name: "Another Workspace" };
  workspaces.unshift(otherWorkspace); notify();
  recentSelector().click();
  await until(() => options(recentSelector()).length === 2);
  assert(recentSelector().dataset.value === workspaceId, "New Workspace changed the initial Home selection");
  assert(document.querySelector(`.recent-meetings a[href="/meetings/${primaryMeetingId}"]`) === recentRow, "Workspace reorder replaced recent meeting rows");
  await choose(recentSelector(), otherWorkspaceId);
  await until(() => document.querySelector(".recent-meetings .welcome-empty"));
  workspaces.reverse(); notify();
  recentSelector().click();
  await until(() => options(recentSelector())[0]?.dataset.value === workspaceId);
  assert(recentSelector().dataset.value === otherWorkspaceId, "Workspace reorder changed an explicit Home selection");
  workspaces.splice(workspaces.indexOf(otherWorkspace), 1); notify();
  await until(() => options(recentSelector()).length === 1 && recentSelector().dataset.value === workspaceId);
  workspaces.unshift(otherWorkspace); notify();
  await new Promise(requestAnimationFrame);
  assert(recentSelector().dataset.value === workspaceId, "Returning Workspace replaced the fallback Home selection");
  document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  const workspaceReads = requests.filter((url) => url === "/api/v1/workspaces").length;
  failures.set("/api/v1/workspaces", 503); notify();
  await until(() => requests.filter((url) => url === "/api/v1/workspaces").length > workspaceReads);
  assert(recentSelector().dataset.value === workspaceId, "Transient Workspace failure reset the Home selection");
  failures.clear(); workspaces.splice(0, workspaces.length, workspace); notify();
  await until(() => requests.filter((url) => url === "/api/v1/workspaces").length > workspaceReads + 1);
  navigateDashboard(route);
  await until(() => document.querySelector('[role="tab"]'));
  const navigation = document.querySelector<HTMLElement>("aside.sidebar")!;
  if (!window.matchMedia("(max-width: 767px)").matches) {
    navigateDashboard(location.pathname);
    assert(navigation.isConnected, "Same-page navigation removed the desktop sidebar");
  }
  for (const target of [route, `/projects/${projectId(0)}`]) {
    navigateDashboard(target);
    await until(() => document.querySelector("main article h1"));
    document.querySelector<HTMLButtonElement>('aside button[aria-label="Search"]')!.click();
    await until(() => document.querySelector('[role="dialog"] [role="option"]'));
    document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
    await until(() => !document.querySelector('[role="dialog"]'));
    assert(navigation.isConnected, "Canceling search dismissed navigation");
    document.querySelector<HTMLButtonElement>('aside button[aria-label="Search"]')!.click();
    await until(() => document.querySelectorAll('[role="dialog"] [role="option"]').length === 2);
    document.querySelectorAll<HTMLButtonElement>('[role="dialog"] [role="option"]')[target.startsWith("/meetings/") ? 0 : 1]!.click();
    await until(() => !document.querySelector('[role="dialog"]'));
    assert(location.pathname === target && navigation.isConnected, "Same-page search result removed navigation");
  }
  navigateDashboard(route);
  await until(() => [...document.querySelectorAll('[role="tab"]')].some((tab) => tab.textContent === "Screenshots"));
  selectTab("Screenshots");
  await until(() => document.querySelectorAll(".screenshot-grid figure").length === 3);
  const tab = button("Screenshots");
  const img = document.querySelector(".screenshot-grid img");
  const row = document.querySelector(`aside a[href="/meetings/${primaryMeetingId}"]`);
  const sidebar = document.querySelector<HTMLElement>(".sidebar-scroll")!;
  const main = document.querySelector<HTMLElement>("main")!;
  sidebar.scrollTop = 180;
  const sidebarScroll = sidebar.scrollTop;
  const documentNode = document.documentElement;
  const sessionReads = requests.filter((url) => url === "/api/v1/session").length;
  caption = "Updated caption"; summary = "Updated summary"; transcript = "Updated transcript"; fileCount = 4;
  for (let index = 0; index < 20; index++) notify();
  await until(() => document.querySelectorAll(".screenshot-grid figure").length === 4 && document.querySelector("figcaption")?.textContent === caption);
  assert(selectedTab() === "Screenshots", "Tab changed on invalidation");
  assert(tab === button("Screenshots") && img === document.querySelector(".screenshot-grid img"), "Existing tab/image DOM replaced");
  assert(row === document.querySelector(`aside a[href="/meetings/${primaryMeetingId}"]`), "Sidebar row remounted");
  assert(sidebar.scrollTop === sidebarScroll, `Sidebar scrolled from ${sidebarScroll} to ${sidebar.scrollTop}`);
  assert(documentNode === document.documentElement && main === document.querySelector("main"), "Document/main replaced");
  assert(requests.filter((url) => url === "/api/v1/session").length === sessionReads, "Sync notification refreshed session");
  assert(location.pathname === route, "Meeting route changed during live refresh");
  const { dialog, fileLink, preview } = await verifyMeetingImageNavigation(route);
  caption = "Modal updated caption";
  notify();
  await until(() => preview?.getAttribute("alt") === caption);
  assert(preview === dialog.querySelector("img") && dialog.isConnected, "Live refresh replaced or closed modal");
  failures.set(`/api/v1/files/${fileId(0)}`, 404); notify();
  await until(() => dialog.querySelector('[role="alert"]') && !dialog.querySelector("img"));
  assert(dialog.isConnected && selectedTab() === "Screenshots", "File failure changed its background page");
  failures.clear();
  dialog.querySelector<HTMLButtonElement>('[role="alert"] button')!.click();
  await until(() => dialog.querySelector<HTMLImageElement>("img")?.complete);
  dialog.querySelector<HTMLButtonElement>('[aria-label="Close"]')!.click();
  await until(() => !document.querySelector('[role="dialog"][aria-label="File preview"]'));
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
  await until(() => [...document.querySelectorAll("aside li")].some((node) => node.textContent === "No meetings"));
  const emptyRow = [...document.querySelectorAll("aside li")].find((node) => node.textContent === "No meetings")!;
  let releaseEmpty!: () => void;
  let emptyReadStarted = false;
  const emptyRead = new Promise<void>((resolve) => { releaseEmpty = resolve; });
  const fetchBeforeEmpty = window.fetch.bind(window);
  window.fetch = async (input, init) => {
    const response = await fetchBeforeEmpty(input, init);
    if (new URL(input instanceof Request ? input.url : input, location.origin).searchParams.get("projectId") === projectId(1)) {
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
  selectTab("Transcript");
  await until(() => document.querySelector('[role="tabpanel"][data-state="active"]')?.textContent?.includes(transcript));
  selectTab("Summary");
  await until(() => document.querySelector('[role="tabpanel"][data-state="active"]')?.textContent?.includes(summary));
  selectTab("Screenshots");
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
  failures.set("/api/v1/workspaces", 503);
  failures.set(`/api/v1/meetings/${primaryMeetingId}`, 503); notify();
  await until(() => document.querySelector('[role="alert"]')?.textContent?.includes("fixture_503"));
  assert(selectedTab() === "Screenshots", "Transient failure unmounted tabs");
  assert(row === document.querySelector(`aside a[href="/meetings/${primaryMeetingId}"]`), "Sidebar refresh failure replaced the tree");
  failures.clear();
  for (const retry of [...document.querySelectorAll<HTMLButtonElement>("button")].filter((b) => b.textContent === "Retry")) retry.click();
  await until(() => !document.querySelector('[role="alert"]'));
  failures.set("/api/v1/transactions", 409);
  pointerClick(document.querySelector<HTMLButtonElement>('[aria-label="Meeting actions"]')!);
  await until(() => [...document.querySelectorAll('[role="menuitem"]')].some((item) => item.textContent?.trim() === "Edit Meeting"));
  menuItem("Edit Meeting").click();
  await editDialog("Failed edit", "Description");
  await until(() => document.querySelector('.action-dialog [role="alert"]')?.textContent?.includes("fixture_409"));
  assert(document.querySelector<HTMLInputElement>('.action-dialog input')?.value === "Failed edit", "Failed save discarded the draft");
  failures.clear();
  await editDialog("Edited meeting", "Description");
  await until(() => document.querySelector("main article h1")?.textContent === "Edited meeting");
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
    if (new URL(request.url).pathname === `/api/v1/meetings/${primaryMeetingId}`) {
      heldSignals.push(request.signal);
      await held; // Deliberately ignore abort to exercise stale completion guards.
    }
    return response;
  };
  notify();
  await until(() => heldSignals.length === 1);
  document.querySelector<HTMLAnchorElement>(`a[href="/meetings/${secondaryMeetingId}"]`)!.click();
  await until(() => document.querySelector("main article h1")?.textContent === "Other meeting");
  assert(selectedTab() === "Summary", "Different meeting did not reset tab");
  assert(heldSignals.every((signal) => signal.aborted), "Obsolete detail/sidebar reads were not aborted");
  window.fetch = normalFetch;
  release();
  await new Promise(requestAnimationFrame);
  assert(document.querySelector("main article h1")?.textContent === "Other meeting", "Stale response overwrote current meeting");
  history.back();
  await until(() => document.querySelector("main article h1")?.textContent === "Edited meeting");
  history.forward();
  await until(() => document.querySelector("main article h1")?.textContent === "Other meeting");
  document.querySelector<HTMLAnchorElement>(`a[href="/workspaces/${workspaceId}"]`)!.click();
  await until(() => document.querySelector('input[aria-label="Search meetings"]'));
  selectTab("Permissions");
  await until(() => [...document.querySelectorAll("button")].some((button) => button.textContent === "Add access"));
  button("Add access").click();
  await until(() => document.querySelector<HTMLInputElement>('[role="dialog"] input[type="search"]'));
  const shareSearch = document.querySelector<HTMLInputElement>('[role="dialog"] input[type="search"]')!;
  Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(shareSearch, "Example");
  shareSearch.dispatchEvent(new Event("input", { bubbles: true }));
  await until(() => document.querySelector<HTMLButtonElement>('[role="dialog"] [role="combobox"][aria-label="Access for Example organization"]'));
  const sharePicker = document.querySelector<HTMLButtonElement>('[role="dialog"] [role="combobox"][aria-label="Access for Example organization"]')!;
  await choose(sharePicker, "viewer");
  await until(() => sharingEnabled && document.querySelector('[role="dialog"] [role="combobox"][aria-label="Access for Example organization"]')?.getAttribute("data-value") === "viewer");
  await new Promise(requestAnimationFrame);
  await choose(document.querySelector<HTMLButtonElement>('[role="dialog"] [role="combobox"][aria-label="Access for Example organization"]')!, "");
  await until(() => !sharingEnabled);
  button("Done").click();
  selectTab("Meetings");
  await until(() => document.querySelector('input[aria-label="Search meetings"]'));
  const search = document.querySelector<HTMLInputElement>('input[aria-label="Search meetings"]')!;
  Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(search, "recording");
  search.dispatchEvent(new Event("input", { bubbles: true }));
  await until(() => requestURLs.some((url) => url.includes("query=recording")));
  notify();
  await new Promise(requestAnimationFrame);
  assert(search.value === "recording", "Live refresh reset search input");
  const filter = document.querySelector<HTMLButtonElement>('[role="combobox"][aria-label="Filter by Project"]')!;
  await choose(filter, projectId(0));
  await until(() => requestURLs.some((url) => url.includes(`query=recording&projectId=${encodeURIComponent(projectId(0))}`)));
  failures.set(`${base}/projects`, 503); notify();
  await until(() => document.querySelector("main .error")?.textContent?.includes("fixture_503"));
  assert(filter.dataset.value === projectId(0), "Transient Project failure reset filter");
  failures.clear(); notify();
  await until(() => !document.querySelector("main .error"));
  assert(filter.dataset.value === projectId(0), "Refresh reset valid Project filter");
  const removedProjects = projects.splice(0);
  notify();
  await until(() => !document.querySelector('[aria-label="Filter by Project"]') && document.querySelector(`main a[href="/meetings/${primaryMeetingId}"]`));
  assert(search.value === "recording", "Deleted Project reset search text");
  projects.push(...removedProjects); notify();
  await until(() => document.querySelector('[aria-label="Filter by Project"]'));
  assert(document.querySelector<HTMLButtonElement>('[role="combobox"][aria-label="Filter by Project"]')!.dataset.value === "__dahlia_empty__", "Deleted Project filter was restored");
  selectTab("Projects");
  await until(() => [...document.querySelectorAll("button")].some((b) => b.textContent === "New Project"));
  button("New Project").click(); await editDialog("New project");
  await until(() => document.querySelector("h1")?.textContent === "New project");
  button("New Subproject").click(); await editDialog("New subproject");
  await until(() => document.querySelector("h1")?.textContent === "New subproject");
  const subproject = projects.find((project) => project.name === "New subproject");
  assert(subproject?.parentProjectId && projects.some((project) => project.projectId === subproject.parentProjectId), "Subproject was created without a parent");
  assert(![...document.querySelectorAll("button")].some((button) => button.textContent === "New Subproject"), "Nested Subproject creation should respect the one-level hierarchy");
  assert(!document.querySelector('[aria-label="Project actions"]'), "Project actions should be in Settings");
  assert(document.querySelector('[role="tab"][aria-selected="true"]')?.textContent === "Meetings", "Project should open Meetings first");
  failures.set("/api/v1/transactions", 409);
  selectTab("Settings");
  await until(() => [...document.querySelectorAll("button")].some((button) => button.textContent === "Edit Project"));
  button("Edit Project").click(); await editDialog("Failed project edit", "Description");
  await until(() => document.querySelector('.action-dialog [role="alert"]')?.textContent?.includes("fixture_409"));
  failures.clear();
  await editDialog("Edited project", "Description");
  await until(() => document.querySelector("h1")?.textContent === "Edited project");
  await until(() => !document.querySelector('.action-dialog'));
  button("Delete Project").click();
  await until(() => document.querySelector('.action-dialog [data-confirm]'));
  document.querySelector<HTMLButtonElement>('.action-dialog [data-confirm]')!.click();
  await until(() => location.pathname === `/workspaces/${workspaceId}`);
  pointerClick(document.querySelector<HTMLButtonElement>('aside button[aria-label^="Account menu:"]')!);
  await until(() => document.querySelector('[role="menu"] a[href="/orgs"]'));
  document.querySelector<HTMLAnchorElement>('[role="menu"] a[href="/orgs"]')!.click();
  await until(() => location.pathname === "/orgs");
  assert(documentNode === document.documentElement, "Account menu navigation reloaded document");
  document.querySelector<HTMLAnchorElement>(`a[href="/meetings/${primaryMeetingId}"]`)?.click();
  // Use the existing internal navigation helper when the newly scoped tree is still loading.
  navigateDashboard(`/files/${fileId(0)}`);
  await until(() => document.querySelector<HTMLImageElement>('main section[aria-label="File preview"] img')?.complete);
  assert(!document.querySelector('[role="dialog"][aria-label="File preview"]'), "Standalone file URL opened a modal");
  navigateDashboard(route);
  await until(() => document.querySelector('[role="tab"]'));
  failures.set(`/api/v1/meetings/${primaryMeetingId}`, 403); notify();
  await until(() => !document.querySelector('[role="tab"]'));
  assert(document.querySelector('[role="alert"]')?.textContent?.includes("fixture_403"), "Missing access-denied feedback");
  failures.clear();
  for (const retry of [...document.querySelectorAll<HTMLButtonElement>("button")].filter((b) => b.textContent === "Retry")) retry.click();
  await until(() => document.querySelector('[role="tab"]'));
  failures.set(`/api/v1/meetings/${primaryMeetingId}`, 404); notify();
  await until(() => !document.querySelector('[role="tab"]'));
  assert(document.querySelector('[role="alert"]')?.textContent?.includes("fixture_404"), "Deleted meeting remained visible");
  failures.clear();
  navigateDashboard(`/workspaces/${workspaceId}`);
  await until(() => [...document.querySelectorAll('[role="tab"]')].some((tab) => tab.textContent === "Settings"));
  selectTab("Projects");
  await until(() => document.querySelector('.collection-project-name'));
  const projectName = document.querySelector('.collection-project-name strong')!;
  const projectLabel = projectName.getBoundingClientRect();
  const projectIcon = projectName.previousElementSibling!.getBoundingClientRect();
  assert(projectLabel.left - projectIcon.right <= 12, "Project name separated from its icon");
  selectTab("Settings");
  await until(() => [...document.querySelectorAll("button")].some((b) => b.textContent === "Delete Workspace"));
  button("Edit Workspace").click();
  await until(() => document.querySelector('[role="dialog"] button[aria-label="Change icon and color"]'));
  const dialogTitle = document.querySelector<HTMLElement>('[role="dialog"] h2')!;
  const titleBounds = dialogTitle.getBoundingClientRect();
  const symbolBounds = dialogTitle.parentElement!.querySelector("span")!.getBoundingClientRect();
  assert(titleBounds.left > symbolBounds.right && Math.abs(titleBounds.top - symbolBounds.top) < 12, "Dialog title is not beside its icon");
  document.querySelector<HTMLButtonElement>('[role="dialog"] button[aria-label="Change icon and color"]')!.click();
  await until(() => document.querySelector('[data-slot="popover-content"][data-state="open"]'));
  const paletteBounds = document.querySelector('[data-slot="popover-content"][data-state="open"]')!.getBoundingClientRect();
  const nameBounds = document.querySelector<HTMLInputElement>('.action-dialog input[name="name"]')!.getBoundingClientRect();
  assert(paletteBounds.top >= nameBounds.bottom && paletteBounds.right <= window.innerWidth, "Appearance palette obscures the name or leaves the viewport");
  document.querySelector<HTMLButtonElement>('[data-slot="popover-content"] button[aria-label="Green"]')!.click();
  await until(() => document.querySelector('[data-slot="popover-content"] button[aria-label="Green"]')?.getAttribute("aria-pressed") === "true");
  document.querySelector<HTMLButtonElement>('[data-slot="popover-content"] button[aria-label="Book"]')!.click();
  await until(() => document.querySelector('[data-slot="popover-content"] button[aria-label="Book"]')?.getAttribute("aria-pressed") === "true");
  document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  await until(() => !document.querySelector('[data-slot="popover-content"][data-state="open"]'));
  document.querySelector<HTMLButtonElement>('.action-dialog [data-confirm]')!.click();
  await until(() => !document.querySelector('.action-dialog') && document.querySelector('h1 svg')?.parentElement?.getAttribute("style")?.includes("34, 197, 94"));
  const sidebarIcon = document.querySelector('aside button[aria-label^="Current Workspace:"] svg')!.parentElement!;
  assert(sidebarIcon.getBoundingClientRect().width === 18, "Workspace icon expanded into the label space");
  assert(getComputedStyle(document.querySelector('h1 svg')!).color === getComputedStyle(sidebarIcon).color, "Heading and sidebar icon colors differ");
  const child = { ...projects[1]!, parentProjectId: projects[0]!.projectId, icon: "heart", color: "red" };
  Object.assign(projects[0]!, { icon: "book.closed", color: "green" });
  Object.assign(projects[1]!, child);
  navigateDashboard(`/projects/${child.projectId}`);
  await until(() => document.querySelector("h1")?.textContent === child.name && document.querySelector('h1 svg')?.parentElement?.getAttribute("style")?.includes("34, 197, 94"));
  selectTab("Settings");
  await until(() => [...document.querySelectorAll("button")].some((button) => button.textContent === "Edit Project"));
  button("Edit Project").click();
  await until(() => document.querySelector('.action-dialog [title="Inherited from parent Project"]'));
  assert(!document.querySelector('.action-dialog button[aria-label="Change icon and color"]'), "Child Project exposed an editable appearance");
  await editDialog("Renamed child");
  await until(() => !document.querySelector('.action-dialog'));
  navigateDashboard(`/workspaces/${workspaceId}`);
  await until(() => document.querySelector("main h1")?.textContent === workspace.name
    && [...document.querySelectorAll('[role="tab"]')].some((tab) => tab.textContent === "Settings"));
  selectTab("Settings");
  await until(() => [...document.querySelectorAll("button")].some((b) => b.textContent === "Delete Workspace"));
  assert(button("Delete Workspace").disabled, "Nonempty Workspace allowed deletion");
  workspace.hasResources = false;
  notify();
  await until(() => !button("Delete Workspace").disabled);
  button("Delete Workspace").click();
  await until(() => document.querySelector('.action-dialog [data-confirm]'));
  assert(workspaces.some((v) => v.workspaceId === workspaceId), "Opening confirmation deleted the Workspace");
  failures.set("/api/v1/transactions", 409);
  document.querySelector<HTMLButtonElement>('.action-dialog [data-confirm]')!.click();
  await until(() => document.querySelector('.action-dialog [role="alert"]'));
  assert(String(location.pathname) === `/workspaces/${workspaceId}` && workspaces.some((v) => v.workspaceId === workspaceId), "Failed deletion left the Workspace page");
  failures.clear();
  document.querySelector<HTMLButtonElement>('.action-dialog [data-confirm]')!.click();
  await until(() => location.pathname === "/workspaces" && !workspaces.some((v) => v.workspaceId === workspaceId));
  document.body.dataset.testResult = "passed";
  console.log("PASS: live data, DOM identity, scroll, paging, retries, edits, canonical URLs, modal, standalone file, history, create/delete, organization, access revocation");
}
void run().catch((error: unknown) => {
  document.body.dataset.testResult = "failed";
  document.body.dataset.testError = error instanceof Error ? error.stack : String(error);
  console.error(error);
});
