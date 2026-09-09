import { SummaryHistory } from "../src/client/SummaryHistory";
import { RecordingIndicator } from "../src/client/RecordingIndicator";
import { projectAncestors, selectedSidebarVault, Sidebar, SidebarProvider, vaultListURL } from "../src/client/Sidebar";
import { readFileSync } from "node:fs";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { MeetingTabs, parseSummary, SummaryContent, SummaryTags, TranscriptTime } from "../src/client/MeetingContent";

import { afterEach, describe, expect, it, vi } from "vitest";

import {
  ScreenshotFigure,
  SyncedMeeting,
  MeetingList,
  resolveDashboardExtensionRoute,
  type DashboardExtension,
} from "../src/client/App";
import { resolveDashboardRoute, shouldRedirectToSignIn } from "../src/client/routes";

import { FileViewer } from "../src/client/FileViewer";
import * as liveData from "../src/client/live-data";
import { dashboardNavigationPath } from "../src/client/navigation";
import { clientMutationEvent, json, type SyncedMeetingInfo } from "../src/client/api";

const ExtensionPage = () => null;
afterEach(() => vi.unstubAllGlobals());

describe("desktop-style meeting layout", () => {
  it("renders current and historical summaries with metadata conditions in both languages", () => {
    const query = vi.spyOn(liveData, "useLiveJSON");
    const page = vi.spyOn(liveData, "useLivePage");
    const old = JSON.stringify({ title: "Old", sections: [{ heading: "", blocks: [{ type: "paragraph", content: { text: "Previous result" } }] }],
      metadata: { generatedBy: "server", inputTypes: ["transcript"], detailLevel: "low", outputLanguage: "ja",
        request: { model: "first-model", reasoning: { effort: "low" } }, response: { usage: { input_tokens: 10 } } } });
    const latest = JSON.stringify({ title: "New", sections: [{ heading: "", blocks: [{ type: "paragraph", content: { text: "Current result" } }] }] });
    const ready = { error: undefined, loading: false, reload: vi.fn(), replace: vi.fn() };
    query.mockReturnValue({ ...ready, data: { version: 1, title: "Old", document: old } });
    page.mockReturnValue({ ...ready, data: { items: [{ version: 1, savedAt: "2026-09-08T00:00:00Z" }] }, loadingMore: false, loadMore: vi.fn() });
    try {
      for (const [language, label] of [["ja-JP", "過去版（閲覧のみ）"], ["en-US", "Read-only version"]]) {
        vi.stubGlobal("navigator", { language });
        const render = (selected: number | null) => renderToStaticMarkup(createElement(SummaryHistory, {
          base: "/api/v1/vaults/v/meetings/m", latest: { version: 7, revision: 2, present: true, record: { title: "New", document: latest, createdAt: null } },
          selected, onSelect: vi.fn(),
        }));
        expect(render(null)).toContain("Current result");
        expect(render(null)).toContain("v7");
        expect(render(null)).not.toContain("Previous result");
        const historical = render(1);
        expect(page).toHaveBeenCalledWith("/api/v1/vaults/v/meetings/m/summary");
        expect(query).toHaveBeenCalledWith("/api/v1/vaults/v/meetings/m/summary/1");
        expect(historical).toContain("Previous result");
        expect(historical).not.toContain("Current result");
        expect(historical).toContain(label);
        expect(historical).toContain("first-model");
        expect(historical).toContain("low");
        expect(historical).toContain("—");
      }
    } finally { query.mockRestore(); page.mockRestore(); }
  });

  it("waits for meeting and vault data without flashing a placeholder page, and keeps errors visible", () => {
    vi.stubGlobal("navigator", { language: "ja-JP" });
    const query = vi.spyOn(liveData, "useLiveJSON");
    const page = vi.spyOn(liveData, "useLivePage");
    const empty = { data: undefined, error: undefined, loading: true, reload: vi.fn(), replace: vi.fn() };
    const meeting = { meetingId: "m1", name: "Planning", createdAt: "2026-09-07T00:00:00Z" };
    const render = () => renderToStaticMarkup(createElement(SyncedMeeting, { vaultId: "v1", meetingId: "m1" }));
    page.mockReturnValue({ ...empty, loadingMore: false, loadMore: vi.fn() });
    try {
      for (const ready of ["neither", "meeting", "vault", "both"]) {
        query.mockImplementation((url) => {
          if (url === "/api/v1/vaults/v1/meetings/m1" && ["meeting", "both"].includes(ready)) {
            return { ...empty, data: meeting };
          }
          if (url === "/api/v1/vaults/v1" && ["vault", "both"].includes(ready)) {
            return { ...empty, data: { role: "member" } };
          }
          return empty;
        });
        const html = render();
        expect(query).toHaveBeenCalledWith("/api/v1/vaults/v1/meetings/m1");
        expect(query).toHaveBeenCalledWith("/api/v1/vaults/v1/meetings/m1/summary/latest");
        expect(html.includes("<h1>")).toBe(ready === "both");
        expect(html.includes("Planning")).toBe(ready === "both");
        expect(html).not.toContain("<h1>ミーティング</h1>");
        expect(html).not.toContain("ミーティングを読み込み中");
      }
      query.mockReturnValue({ ...empty, loading: false, error: new Error("meeting_not_found") });
      const html = render();
      expect(html).toContain('role="alert"');
      expect(html).not.toContain("<h1>");
    } finally { query.mockRestore(); page.mockRestore(); }
  });

  it("renders a text-labelled recording indicator only for active sessions in both languages", () => {
    for (const [language, label] of [["ja-JP", "録音中"], ["en-US", "Recording"]]) {
      vi.stubGlobal("navigator", { language });
      expect(renderToStaticMarkup(createElement(RecordingIndicator, { isRecording: true }))).toContain(label);
      expect(renderToStaticMarkup(createElement(RecordingIndicator, { isRecording: false }))).toBe("");
      expect(renderToStaticMarkup(createElement(RecordingIndicator, {}))).toBe("");
    }
  });

  it("renders elapsed transcript timestamps independently of locale, midnight and duration length", () => {
    for (const language of ["en-US", "ja-JP"]) {
      vi.stubGlobal("navigator", { language });
      for (const [startTime, timeBase, expected] of [
        ["2026-09-07T14:02:00+09:00", "2026-09-07T14:00:00+09:00", "00:02:00"],
        ["2026-09-08T00:01:02.999+09:00", "2026-09-07T23:00:00+09:00", "01:01:02"],
        ["2026-09-08T15:02:00Z", "2026-09-07T14:00:00Z", "25:02:00"],
        ["2026-09-07T14:00:00Z", "2026-09-07T14:00:01Z", "00:00:00"],
        ["invalid", "2026-09-07T14:00:00Z", "—"],
      ]) {
        const html = renderToStaticMarkup(createElement(TranscriptTime, { startTime: startTime!, timeBase: timeBase! }));
        expect(html).toBe(`<time dateTime="${startTime}">${expected}</time>`);
      }
    }
  });

  it("renders structured content and escapes untrusted summary text", () => {
    const document = parseSummary(JSON.stringify({
      description: "Meeting overview",
      sections: [{ heading: "Decisions", blocks: [
        { type: "bulleted_list", items: [{ text: "Keep the API", transcript_ref: "00:02:27" }] },
        { type: "numbered_list", items: [{ text: "First step" }] },
        { type: "checklist", items: [{ text: "Completed", checked: true }] },
        { type: "table", headers: [{ text: "Owner" }], rows: [[{ text: "Team" }]] },
        { type: "quote", content: { text: "First line\nSecond line" } },
        { type: "paragraph", content: { text: '<img src=x onerror="alert(1)">' } },
      ] }],
      tags: ["project", { text: "bad tag" }],
      actionItems: [{ title: "Follow up", assignee: "Team" }],
    }));
    const html = renderToStaticMarkup(createElement(SummaryContent, { document }));
    expect(html).toContain("<h2>Decisions</h2>");
    expect(html).toContain("<ul><li>Keep the API");
    expect(html).toContain("00:02:27");
    expect(html).toContain("<ol><li>First step</li></ol>");
    expect(html).toContain('checked=""');
    expect(html).toContain("<th>Owner</th>");
    expect(html).toContain("<blockquote>First line\nSecond line</blockquote>");
    expect(html).toContain("Follow up");
    expect(html).toContain("&lt;img");
    expect(html).not.toContain("<img");
    const tags = renderToStaticMarkup(createElement(SummaryTags, { document }));
    expect(tags).toContain("project");
    expect(tags).not.toContain("bad tag");
    expect(parseSummary("malformed")).toEqual({});
    expect(() => renderToStaticMarkup(createElement(SummaryContent, { document: { sections: [null, { blocks: [null, { type: "table", rows: [null] }] }] } }))).not.toThrow();
  });

  it("defaults to Summary with linked accessible tabs and defers hidden content", () => {
    vi.stubGlobal("navigator", { language: "ja-JP" });
    const html = renderToStaticMarkup(createElement(MeetingTabs, { summary: "Summary body", screenshots: "Hidden screenshots", transcript: "Hidden transcript" }));
    expect(html.match(/role="tab"/g)).toHaveLength(3);
    expect(html).toContain('aria-selected="true"');
    expect(html).toContain('aria-controls=');
    expect(html).toContain('role="tabpanel"');
    expect(html).toContain("要約");
    expect(html).toContain("文字起こし");
    expect(html).toContain("Summary body");
    expect(html).not.toContain("Hidden screenshots");
    expect(html).not.toContain("Hidden transcript");
  });

  it("groups account actions in the footer and keeps Vault navigation in the sidebar", () => {
    vi.stubGlobal("navigator", { language: "en" });
    const session = { user: { id: "user", name: "Example User" }, workspace: { id: "personal", type: "personal" as const }, capabilities: { sync: true, sharing: true, sessions: true, admin: false } };
    const html = renderToStaticMarkup(createElement(SidebarProvider, { session, children: createElement(Sidebar, {
      session, brand: "Dahlia", children: createElement("a", { href: "/dashboard/settings" }, "Settings"),
    }) }));
    const [navigation, footer] = html.split('<div class="sidebar-footer">');
    expect(navigation).toContain("Project navigation");
    expect(navigation).not.toContain("organization-switcher");
    expect(navigation).not.toContain("Account settings");
    expect(footer).toContain('popoverTarget="account-menu"');
    expect(footer).toContain("No organization selected");
    expect(footer).not.toContain('href="/vaults"');
    expect(navigation).toContain('href="/vaults"');
    expect(footer).toContain('<strong>Organizations</strong>');
    expect(footer).toContain('class="menu-account" href="/dashboard"');
    expect(footer).toContain('class="menu-icon"');
    expect(footer).toContain("Sign out");
    expect(footer).not.toContain("Workspace");
    expect(footer).not.toContain("Local account");
    expect(footer).toContain('href="/organizations"');
    expect(navigation).toContain('href="/organizations"');
    expect(footer).toContain("Settings");
    expect(footer).not.toContain("sidebar-settings");
    expect(footer).not.toContain("Artifacts");
  });

  it("omits unsupported sign-out and sharing sections for proxy accounts", () => {
    vi.stubGlobal("navigator", { language: "ja-JP" });
    const session = { user: { id: "user", name: "Example User" }, workspace: { id: "personal", type: "personal" as const }, capabilities: { sync: true, sharing: false, sessions: false, admin: false } };
    const html = renderToStaticMarkup(createElement(SidebarProvider, { session, children: createElement(Sidebar, {
      session, brand: "Dahlia", children: null,
    }) }));
    expect(html).toContain('aria-label="保管庫"');
    expect(html).not.toContain("保管庫を管理");
    expect(html).not.toContain("サインアウト");
    expect(html).not.toContain('<strong>組織</strong>');
    expect(html).not.toContain("組織を管理");
    expect(html).not.toContain('href="/admin/members"');
  });

  it.each([false, true])("keeps server administration outside the account menu with sharing=%s", (sharing) => {
    vi.stubGlobal("navigator", { language: "ja-JP" });
    const session = { user: { id: "user", name: "Example User" }, workspace: { id: "personal", type: "personal" as const }, capabilities: { sync: true, sharing, sessions: true, admin: true } };
    const html = renderToStaticMarkup(createElement(SidebarProvider, { session, children: createElement(Sidebar, {
      session, brand: "Dahlia", children: createElement("a", { href: "/dashboard/settings" }, "設定"),
    }) }));
    const [navigation, footer] = html.split('<div class="sidebar-footer">');
    for (const path of ["/admin/organizations", "/admin/users", "/admin/settings"]) {
      expect(navigation).toContain(`href="${path}"`);
      expect(footer).not.toContain(`href="${path}"`);
    }
    expect(navigation).toContain("サーバー設定");
    expect(footer?.includes('href="/organizations"')).toBe(sharing);
    if (sharing) expect(footer).toContain("所属組織一覧");
    expect(footer).toContain("設定");
  });
});

describe("dashboard navigation", () => {
  it("uses advertised thumbnails for browsing and preserves the original link", () => {
    const file = { id: "file", content_type: "image/png", metadata: { source: "screenshot" },
      variants: { thumb_480: "/small", thumb_1280: "/medium", thumb_1568: "/preview", thumb_1920: "/large" } };
    const capturedAt = "2026-09-07T00:00:00Z";
    const html = renderToStaticMarkup(createElement(ScreenshotFigure, { file, capturedAt }));
    expect(html).toContain('src="/small"');
    expect(html).toContain('href="/files/file"');
    expect(html).not.toContain('target="_blank"');
    expect(html).toContain('href="/api/v1/files/file"');
    expect(html).toContain("Download original");
    expect(html).toContain(`dateTime="${capturedAt}"`);
    const portable = renderToStaticMarkup(createElement(ScreenshotFigure, { file: { ...file, variants: {} } }));
    expect(portable).toContain('src="/api/v1/files/file"');
    expect(portable).not.toContain("/large");
  });
  it("previews images but never embeds active file content, and removes inaccessible previews", () => {
    vi.stubGlobal("navigator", { language: "en" });
    const query = vi.spyOn(liveData, "useLiveJSON");
    try {
      for (const contentType of ["image/png", "image/tiff", "text/html", "image/svg+xml"]) {
        query.mockReturnValue({ data: { id: "f1", revision: 2, name: "Example", content_type: contentType, metadata: { ocr_text: "Detected text", caption: "Image caption" }, variants: { thumb_1568: "/preview" } }, error: undefined, loading: false, reload: vi.fn(), replace: vi.fn() });
        const html = renderToStaticMarkup(createElement(FileViewer, { fileId: "f1", separateTab: true }));
        expect(query).toHaveBeenCalledWith("/api/v1/files/f1/metadata");
        expect(html).toContain('aria-label="Image information" aria-expanded="false"');
        expect(html).toContain('aria-label="Copy image"');
        expect(html).toContain('aria-label="Zoom out"');
        expect(html).toContain('aria-label="Zoom in"');
        expect(html).toContain('100%');
        expect(html).not.toContain('<aside');
        expect(html).toContain('download="Example"');
        expect(html.includes('<img')).toBe(contentType === "image/png" || contentType === "image/tiff");
        expect(html).not.toMatch(/<(iframe|object|embed)/);
      }
      query.mockReturnValue({ data: undefined, error: new Error("file_not_found"), loading: false, reload: vi.fn(), replace: vi.fn() });
      const inaccessible = renderToStaticMarkup(createElement(FileViewer, { fileId: "f1" }));
      expect(inaccessible).toContain('role="alert"');
      expect(inaccessible).not.toContain('<img');
      expect(inaccessible).not.toContain('download=');
    } finally { query.mockRestore(); }
  });

  it("invalidates shared projections only after successful write responses", async () => {
    const browser = new EventTarget();
    const changed = vi.fn();
    browser.addEventListener(clientMutationEvent, changed);
    vi.stubGlobal("window", browser);
    for (const method of [undefined, "GET", "HEAD", "OPTIONS", "POST", "PUT", "PATCH", "delete"]) {
      changed.mockClear();
      const result = { id: "updated" };
      vi.stubGlobal("fetch", vi.fn(async () => method === "delete" ? new Response(null, { status: 204 }) : Response.json(result)));
      await expect(json("/api/resource", { method })).resolves.toEqual(method === "delete" ? undefined : result);
      expect(changed).toHaveBeenCalledTimes(method && !["GET", "HEAD", "OPTIONS"].includes(method) ? 1 : 0);
    }
    changed.mockClear();
    for (const response of [Response.json({ error: "forbidden" }, { status: 403 }), Response.json({ error: "conflict" }, { status: 409 }), new Response("malformed JSON")]) {
      vi.stubGlobal("fetch", vi.fn(async () => response));
      await expect(json("/api/resource", { method: "POST" })).rejects.toThrow();
      expect(changed).not.toHaveBeenCalled();
    }
  });

  it("signals expired sessions without treating authorization or other failures as sign-out", async () => {
    const browser = new EventTarget();
    const sessionExpired = vi.fn();
    browser.addEventListener("dahlia:unauthorized", sessionExpired);
    vi.stubGlobal("window", browser);
    for (const status of [401, 403, 409, 503]) {
      vi.stubGlobal("fetch", vi.fn(async () => Response.json({ error: "request_failed" }, { status })));
      await expect(json("/api/protected")).rejects.toMatchObject({ status, message: "request_failed" });
      expect(sessionExpired).toHaveBeenCalledTimes(1);
    }
  });

  it("selects only the current Vault and restores the saved selection off Vault routes", () => {
    const vaults = [{ vaultId: "v1", name: "First" }, { vaultId: "v2", name: "Second" }] as NonNullable<Parameters<typeof selectedSidebarVault>[0]>;
    expect(selectedSidebarVault(vaults, "v2", "v1")).toBe(vaults[1]);
    expect(selectedSidebarVault(vaults, undefined, "v2")).toBe(vaults[1]);
    expect(selectedSidebarVault(vaults)).toBe(vaults[0]);
    expect(selectedSidebarVault(vaults, undefined, "removed")).toBe(vaults[0]);
    expect(selectedSidebarVault(vaults, "outside-scope", "v1")).toBeUndefined();
    expect(selectedSidebarVault([], undefined, "v2")).toBeUndefined();
    expect(selectedSidebarVault(undefined, "v2")).toBeUndefined();
  });

  it("navigates dashboard links in place and leaves other URLs to the browser", () => {
    const current = "https://dahlia.example/vaults/v1/meetings/m1";
    for (const path of ["/dashboard", "/vaults/v1", "/vaults/v1/meetings/m2", "/vaults/v1/projects/p1", "/dashboard/settings"]) {
      expect(dashboardNavigationPath(path, current)).toBe(path);
      expect(dashboardNavigationPath(`https://dahlia.example${path}`, current)).toBe(path);
    }
    for (const href of ["https://other.example/dashboard", "/api/v1/files/f1", "/sign-in", "/oauth/consent", "/dashboard/extension", "/dashboard?q=search", "#section", "mailto:user@example.com"]) {
      expect(dashboardNavigationPath(href, current)).toBeUndefined();
    }
  });

  it("builds exclusive scopes and expands the selected Project ancestry by ID", () => {
    expect(vaultListURL("")).toBe("/api/v1/vaults");
    expect(vaultListURL("org+1")).toBe("/api/v1/vaults?organizationId=org%2B1");
    const projects = [
      { projectId: "parent", name: "Same" },
      { projectId: "child", parentProjectId: "parent", name: "Same" },
      { projectId: "other", name: "Same" },
    ] as Parameters<typeof projectAncestors>[0];
    expect([...projectAncestors(projects, "child")]).toEqual(["child", "parent"]);
    expect([...projectAncestors(projects, "missing")]).toEqual([]);
  });

  it("redirects to sign-in only for an authentication failure", () => {
    expect(shouldRedirectToSignIn(401)).toBe(true);
    expect(shouldRedirectToSignIn(500)).toBe(false);
    expect(shouldRedirectToSignIn(undefined)).toBe(false);
  });

  it("routes the authenticated home to Overview", () => {
    expect(resolveDashboardRoute("/", { admin: false, sessions: false })).toEqual({ redirect: "/dashboard" });
    expect(resolveDashboardRoute("/dashboard", { admin: false, sessions: false })).toEqual({ page: "overview" });
  });

  it("resolves canonical detail URLs and preserves capability gates", () => {
    for (const [path, result] of [["/projects/p1", { page: "project", projectId: "p1" }], ["/meetings/m1", { page: "meeting", meetingId: "m1" }], ["/files/f1", { page: "file", fileId: "f1" }]] as const) {
      expect(resolveDashboardRoute(path, { admin: false, sessions: true, sync: true })).toEqual(result);
      expect(resolveDashboardRoute(path, { admin: false, sessions: true, sync: false })).toEqual({ redirect: "/dashboard" });
      expect(dashboardNavigationPath(path, "https://dahlia.example/vaults/v1")).toBe(path);
    }
  });

  it("renders localized collection rows without internal metadata", () => {
    const meeting = { meetingId: "m1", name: "Planning", createdAt: "2026-09-07T00:00:00Z", status: "TRANSCRIPT_NOT_FOUND" } as SyncedMeetingInfo;
    const html = renderToStaticMarkup(createElement(MeetingList, { meetings: [meeting], loading: false }));
    expect(html).toContain('href="/meetings/m1"');
    expect(html).toContain("Planning");
    expect(html).not.toContain("TRANSCRIPT_NOT_FOUND");
    vi.stubGlobal("navigator", { language: "ja-JP" });
    expect(renderToStaticMarkup(createElement(MeetingList, { meetings: [], loading: false }))).toContain("ミーティングはまだありません");
  });

  it("gates synchronized Vault routes with the sync capability", () => {
    const enabled = { admin: false, sessions: false, sync: true };
    expect(resolveDashboardRoute("/vaults", enabled)).toEqual({ page: "vaults" });
    expect(resolveDashboardRoute("/vaults/v1", enabled)).toEqual({ page: "vault", vaultId: "v1" });
    expect(resolveDashboardRoute("/vaults/v1/projects/p1", enabled))
      .toEqual({ redirect: "/projects/p1" });
    expect(resolveDashboardRoute("/vaults/v1/meetings/m1", enabled))
      .toEqual({ redirect: "/meetings/m1" });
    expect(resolveDashboardRoute("/vaults", { admin: false, sessions: false, sync: false }))
      .toEqual({ redirect: "/dashboard" });
  });

  it("gates organization and invitation routes with session capabilities", () => {
    const enabled = { admin: false, sessions: true, sharing: true };
    expect(resolveDashboardRoute("/organizations", enabled)).toEqual({ page: "organizations" });
    expect(resolveDashboardRoute("/organizations/alpha-team", enabled))
      .toEqual({ page: "organization", organizationSlug: "alpha-team" });
    expect(dashboardNavigationPath("/organizations/alpha-team", "https://example.com/organizations"))
      .toBe("/organizations/alpha-team");
    expect(resolveDashboardRoute("/organizations/alpha-team", { ...enabled, sharing: false }))
      .toEqual({ redirect: "/dashboard" });
    expect(resolveDashboardRoute("/organizations/external", { ...enabled, sessions: false }))
      .toEqual({ page: "organization", organizationSlug: "external" });
    expect(resolveDashboardRoute("/accept-invitation/invitation-1", enabled))
      .toEqual({ page: "invitation", invitationId: "invitation-1" });
    expect(resolveDashboardRoute("/organizations", { ...enabled, sharing: false }))
      .toEqual({ redirect: "/dashboard" });
    expect(resolveDashboardRoute("/organizations", { ...enabled, sessions: false }))
      .toEqual({ page: "organizations" });
  });

  it("opens account settings for both header and session authentication", () => {
    expect(resolveDashboardRoute("/dashboard/settings", { admin: false, sessions: false }))
      .toEqual({ page: "settings" });
    expect(resolveDashboardRoute("/dashboard/settings", { admin: false, sessions: true }))
      .toEqual({ page: "settings" });
  });

  it("gates administration routes", () => {
    const admin = { admin: true, sessions: false };
    const user = { admin: false, sessions: false };
    expect(resolveDashboardRoute("/admin", admin)).toEqual({ redirect: "/admin/settings" });
    expect(resolveDashboardRoute("/admin/models", admin)).toEqual({ redirect: "/dashboard" });
    expect(resolveDashboardRoute("/admin/members", admin)).toEqual({ redirect: "/admin/users" });
    for (const [path, page] of [["/admin/users", "admin-users"], ["/admin/organizations", "admin-organizations"], ["/admin/settings", "admin-settings"]]) {
      expect(resolveDashboardRoute(path!, admin)).toEqual({ page });
      expect(resolveDashboardRoute(path!, user)).toEqual({ redirect: "/dashboard" });
    }
    expect(resolveDashboardRoute("/admin/models", user)).toEqual({ redirect: "/dashboard" });
  });

  it("resolves extension routes through explicit capabilities", () => {
    const extensions: DashboardExtension[] = [{
      navigation: [{ path: "/dashboard/extension", label: "Extension", capability: "extension" }],
      routes: [{ path: "/dashboard/extension", component: ExtensionPage, capability: "extension" }],
    }];
    expect(resolveDashboardExtensionRoute(
      "/dashboard/extension",
      { admin: false, sessions: false, extension: true },
      extensions,
    )).toMatchObject({ allowed: true, route: { path: "/dashboard/extension" } });
    expect(resolveDashboardExtensionRoute(
      "/dashboard/extension",
      { admin: false, sessions: false, extension: false },
      extensions,
    )).toMatchObject({ allowed: false });
  });

  it("keeps core routes reserved from extensions", () => {
    const extensions: DashboardExtension[] = [{
      routes: [{ path: "/admin/models", component: ExtensionPage }],
    }];

    expect(resolveDashboardExtensionRoute(
      "/admin/models",
      { admin: false, sessions: false },
      extensions,
    )).toEqual({ allowed: true });
    expect(resolveDashboardRoute("/admin/models", { admin: false, sessions: false }))
      .toEqual({ redirect: "/dashboard" });
  });

  it("does not expose implementation names or the browser model API", () => {
    const source = readFileSync(new URL("../src/client/App.tsx", import.meta.url), "utf8");

    expect(source).not.toContain("Better Auth");
    expect(source).not.toContain("Trusted proxy");
    expect(source).not.toContain("/api/models");
    expect(source).not.toContain("On-Demand Usage");
    expect(source).not.toContain('className="nav-label"');
    expect(source).toContain('<svg className="brand-mark"');
    expect(source).not.toContain('href="/artifacts"');
    expect(source).not.toContain("/api/v1/artifacts");
    expect(source).not.toContain("Loading artifacts…");
    expect(source).toContain("/api/auth/organization/list-user-teams?");
    expect(source).not.toContain("/api/auth/organization/list-team-members?");
    expect(source).not.toContain("external-default");
    expect(source).not.toContain("window.prompt(");
    expect(source).not.toContain("window.confirm(");
    expect(source).not.toContain("<pre>{meeting.summaryDocument}</pre>");
  });

  it("removes the model management UI", () => {
    const source = readFileSync(new URL("../src/client/App.tsx", import.meta.url), "utf8");
    expect(source).not.toContain("/admin/models");
    expect(source).not.toContain("AdminModels");
  });
});
