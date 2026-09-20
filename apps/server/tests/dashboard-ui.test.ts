import * as sidebar from "../src/client/Sidebar";
import { MeetingHoverDetails } from "../src/client/MeetingHoverCard";
import { encodeId } from "../src/typeid";
import { apiUrls } from "../src/client/generated-operations";
import { SummaryHistory } from "../src/client/SummaryHistory";
import { RecordingIndicator } from "../src/client/RecordingIndicator";
import { projectAncestors, selectedSidebarWorkspace, Sidebar, SidebarProvider } from "../src/client/Sidebar";
import { readFileSync } from "node:fs";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { MeetingTabs, parseSummary, SummaryContent, SummaryTags, TranscriptTime } from "../src/client/MeetingContent";

import { afterEach, describe, expect, it, vi } from "vitest";

import {
  App,
  HeaderAuthenticationNotice,
  Organization,
  ScreenshotFigure,
  SyncedMeeting,
  WorkspaceMeetings,
  Workspaces,
  MeetingList,
  accountSignInRequired,
  projectBreadcrumbOptions,
  resolveDashboardExtensionRoute,
  type DashboardExtension,
} from "../src/client/App";
import { isCoreDashboardPath, resolveDashboardRoute, shouldRedirectToSignIn } from "../src/client/routes";

import { FileViewer } from "../src/client/FileViewer";
import * as liveData from "../src/client/live-data";
import { dashboardNavigationPath } from "../src/client/navigation";
import { clientMutationEvent, json, type SyncedMeetingInfo, type SyncedProjectInfo, type SyncedWorkspaceInfo } from "../src/client/api";
import { mcpConnectionOutput, parseMCPConnectionInfo } from "../src/client/MCPConnectionDialog";

const ExtensionPage = () => null;
afterEach(() => vi.unstubAllGlobals());

describe("desktop-style meeting layout", () => {
  it("renders the full meeting breadcrumb and top-right actions", () => {
    vi.stubGlobal("navigator", { language: "en-US" });
    const scope = vi.spyOn(sidebar, "useSidebar").mockReturnValue({ userId: "user", reload: vi.fn(), workspaces: [
      { workspaceId: "w1", name: "Workspace" } as SyncedWorkspaceInfo,
      { workspaceId: "w2", name: "Team Workspace" } as SyncedWorkspaceInfo,
    ] });
    const ready = { error: undefined, loading: false, reload: vi.fn(), replace: vi.fn() };
    const query = vi.spyOn(liveData, "useLiveJSON").mockImplementation((input) => {
      const key = typeof input === "object" ? input.key : "";
      if (key.startsWith('["getMeeting"')) return { ...ready, data: {
        meetingId: "m1", workspaceId: "w1", projectId: "child", name: "Weekly Meeting", description: "", status: "READY",
        duration: null, revision: 1, createdAt: "2026-09-18T00:00:00Z", updatedAt: "2026-09-18T00:00:00Z",
      } };
      if (key.startsWith('["getWorkspace"')) return { ...ready, data: { workspaceId: "w1", name: "Workspace", role: "admin" } };
      if (key.startsWith('["listProjects"')) return { ...ready, data: { items: [
        { projectId: "root", parentProjectId: null, name: "Project" },
        { projectId: "child", parentProjectId: "root", name: "Sub Project" },
      ] } };
      if (key.startsWith('["getLatestSummary"')) return { ...ready, data: { record: { document: "{}" } } };
      return { ...ready, data: undefined };
    });
    const page = vi.spyOn(liveData, "useLivePage").mockImplementation((input) => ({ ...ready,
      data: typeof input === "object" && input.key.startsWith('["listMeetings"') ? { items: [
        { meetingId: "m1", name: "Weekly Meeting" }, { meetingId: "m2", name: "Design Review" },
      ] } : undefined, loadingMore: false, loadMore: vi.fn() }));
    try {
      const html = renderToStaticMarkup(createElement(SyncedMeeting, { workspaceId: "w1", meetingId: "m1" }));
      expect(html).toContain('aria-label="Breadcrumbs"');
      expect(html).toContain('href="/projects/root"');
      expect(html).toContain('href="/projects/child"');
      expect(html).toContain(">Project</span>");
      expect(html).toContain(">Sub Project</span>");
      expect(html).toContain('aria-current="page"');
      expect(html).toContain('aria-label="Copy meeting link"');
      expect(html).toContain('aria-label="Meeting actions"');
      expect(html).toContain('aria-haspopup="menu"');
      expect(html).toMatch(/<h1[^>]*>Weekly Meeting<\/h1>/);
      expect(html.indexOf('aria-label="Breadcrumbs"')).toBeLessThan(html.indexOf("Weekly Meeting</h1>"));
    } finally { query.mockRestore(); page.mockRestore(); scope.mockRestore(); }
  });

  it("builds the header hierarchy from projects through meetings", () => {
    const options = projectBreadcrumbOptions([
      { projectId: "root", parentProjectId: null, name: "Project" },
      { projectId: "child", parentProjectId: "root", name: "Sub Project" },
    ] as SyncedProjectInfo[], undefined, { projectId: "child", meetingId: "m1", meetings: [
      { meetingId: "m1", name: "Weekly Meeting" }, { meetingId: "m2", name: "Design Review" },
    ] as SyncedMeetingInfo[] });
    expect(options).toMatchObject([{ href: "/projects/root", children: [{ href: "/projects/child", current: true, children: [
      { href: "/meetings/m1", current: true }, { href: "/meetings/m2", current: false },
    ] }] }]);
  });

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
          meetingId: "m", latest: { formatVersion: 1, entity: "summary", entityId: "m", count: 1, byteCount: 0, sha256: "", version: 7, revision: 2, present: true, record: { title: "New", document: latest, createdAt: null } },
          selected, onSelect: vi.fn(),
        }));
        expect(render(null)).toContain("Current result");
        expect(render(null)).not.toContain("Previous result");
        const historical = render(1);
        expect(page).toHaveBeenCalledWith(expect.objectContaining({ key: "[\"listSummaries\",{\"params\":{\"path\":{\"meetingId\":\"m\"}}}]" }));
        expect(query).toHaveBeenCalledWith(expect.objectContaining({ key: "[\"getSummary\",{\"params\":{\"path\":{\"meetingId\":\"m\",\"version\":\"1\"}}}]" }));
        expect(historical).toContain("Previous result");
        expect(historical).not.toContain("Current result");
        expect(historical).toContain(label);
        expect(historical).toContain("first-model");
        expect(historical).toContain("low");
        expect(historical).toContain("—");
      }
    } finally { query.mockRestore(); page.mockRestore(); }
  });

  it("waits for meeting and workspace data without flashing a placeholder page, and keeps errors visible", () => {
    vi.stubGlobal("navigator", { language: "ja-JP" });
    const scope = vi.spyOn(sidebar, "useSidebar").mockReturnValue({ userId: "user", reload: vi.fn() });
    const query = vi.spyOn(liveData, "useLiveJSON");
    const page = vi.spyOn(liveData, "useLivePage");
    const empty = { data: undefined, error: undefined, loading: true, reload: vi.fn(), replace: vi.fn() };
    const meeting = { meetingId: "m1", name: "Planning", description: "Description available to read-only members", createdAt: "2026-09-07T00:00:00Z" };
    const render = () => renderToStaticMarkup(createElement(SyncedMeeting, { workspaceId: "v1", meetingId: "m1" }));
    page.mockReturnValue({ ...empty, loadingMore: false, loadMore: vi.fn() });
    try {
      for (const ready of ["neither", "meeting", "workspace", "both"]) {
        query.mockImplementation((url) => {
          if (typeof url === "object" && url.key.startsWith('["getMeeting"') && ["meeting", "both"].includes(ready)) {
            return { ...empty, data: meeting };
          }
          if (typeof url === "object" && url.key.startsWith('["getWorkspace"') && ["workspace", "both"].includes(ready)) {
            return { ...empty, data: { role: "member" } };
          }
          return empty;
        });
        const html = render();
        expect(query).toHaveBeenCalledWith(expect.objectContaining({ key: "[\"getMeeting\",{\"params\":{\"path\":{\"meetingId\":\"m1\"}}}]" }));
        expect(query).toHaveBeenCalledWith(expect.objectContaining({ key: "[\"getLatestSummary\",{\"params\":{\"path\":{\"meetingId\":\"m1\"}}}]" }));
        expect(html.includes("Description available to read-only members")).toBe(ready === "both");
        if (ready === "both") expect(html).toContain('<details class="meeting-description"><summary>説明</summary><p>Description available to read-only members</p></details>');
        expect(/<h1[^>]*>Planning<\/h1>/.test(html)).toBe(ready === "both");
        expect(html.includes("Planning")).toBe(ready === "both");
        expect(html).not.toContain("<h1>ミーティング</h1>");
        expect(html).not.toContain("ミーティングを読み込み中");
        expect(page.mock.calls.some(([input]) => typeof input === "object" && input.key.includes("listMeetingFiles"))).toBe(false);
      }
      query.mockReturnValue({ ...empty, loading: false, error: new Error("meeting_not_found") });
      const html = render();
      expect(html).toContain('role="alert"');
      expect(html).not.toContain("<h1>");
    } finally { query.mockRestore(); page.mockRestore(); scope.mockRestore(); }
  });

  it("reuses a resolved meeting without issuing another detail query", () => {
    const scope = vi.spyOn(sidebar, "useSidebar").mockReturnValue({ userId: "user", reload: vi.fn() });
    const query = vi.spyOn(liveData, "useLiveJSON").mockImplementation((input) => ({
      data: typeof input === "object" && input.key.startsWith('["getWorkspace"') ? { role: "member" } : undefined,
      error: undefined, loading: false, reload: vi.fn(), replace: vi.fn(),
    }));
    const page = vi.spyOn(liveData, "useLivePage").mockReturnValue({ data: undefined, error: undefined, loading: false,
      reload: vi.fn(), replace: vi.fn(), loadingMore: false, loadMore: vi.fn() });
    try {
      renderToStaticMarkup(createElement(SyncedMeeting, { workspaceId: "v1", meetingId: "m1",
        resolvedMeeting: { meetingId: "m1", workspaceId: "v1", name: "Planning", description: "", status: "READY",
          projectId: null, duration: null, createdAt: "2026-09-07T00:00:00Z", updatedAt: "2026-09-07T00:00:00Z" } as SyncedMeetingInfo }));
      expect(query.mock.calls.some(([input]) => typeof input === "object" && input.key.includes('"getMeeting"'))).toBe(false);
    } finally { query.mockRestore(); page.mockRestore(); scope.mockRestore(); }
  });

  it("leaves a pending route meeting query owned by App", () => {
    vi.stubGlobal("window", { location: { pathname: "/meetings/m1" } });
    vi.stubGlobal("sessionStorage", { getItem: vi.fn(), setItem: vi.fn() });
    const workspace = { workspaceId: "v1", name: "Workspace" } as SyncedWorkspaceInfo;
    const query = vi.spyOn(liveData, "useLiveJSON").mockImplementation((input) => ({
      data: typeof input === "object" && input.key.startsWith('["listWorkspaces"') ? { items: [workspace] }
        : typeof input === "object" && input.key.startsWith('["listProjects"') ? { items: [] }
          : undefined,
      error: undefined, loading: false, reload: vi.fn(), replace: vi.fn(),
    }));
    const page = vi.spyOn(liveData, "useLivePage").mockReturnValue({ data: undefined, error: undefined, loading: false,
      reload: vi.fn(), replace: vi.fn(), loadingMore: false, loadMore: vi.fn() });
    const session = { user: { id: "user" }, capabilities: { sync: true, sharing: false, sessions: false, admin: false } };
    try {
      renderToStaticMarkup(createElement(SidebarProvider, { session, children: createElement(Sidebar, {
        session, brand: "Dahlia", children: null, routeMeetingOwned: true,
      }) }));
      expect(query.mock.calls.some(([input]) => typeof input === "object" && input.key.includes('"getMeeting"'))).toBe(false);
    } finally { query.mockRestore(); page.mockRestore(); }
  });

  it("waits for Workspace and Organization names without flashing generic detail headings", () => {
    vi.stubGlobal("navigator", { language: "ja-JP" });
    const empty = { data: undefined, error: undefined, loading: true, reload: vi.fn(), replace: vi.fn() };
    const query = vi.spyOn(liveData, "useLiveJSON").mockReturnValue(empty);
    const page = vi.spyOn(liveData, "useLivePage").mockReturnValue({ ...empty, loadingMore: false, loadMore: vi.fn() });
    const scope = vi.spyOn(sidebar, "useSidebar").mockReturnValue({ userId: "user", reload: vi.fn() });
    const session = { user: { id: "user" }, capabilities: { sync: true, sharing: true, sessions: true, admin: false } };
    try {
      const workspace = renderToStaticMarkup(createElement(WorkspaceMeetings, { session, workspaceId: "workspace" }));
      const organization = renderToStaticMarkup(createElement(Organization, { session, organizationId: "organization" }));
      expect(workspace).toContain('aria-busy="true"');
      expect(workspace).toContain("ワークスペースを読み込み中…");
      expect(workspace).not.toContain("<h1>");
      expect(workspace).not.toContain('role="tab"');
      expect(organization).toContain("組織を読み込み中…");
      expect(organization).not.toContain("<h1>");
    } finally { query.mockRestore(); page.mockRestore(); scope.mockRestore(); }
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
        expect(html).toBe(`<time class="pt-0.5 text-xs tabular-nums text-muted-foreground" dateTime="${startTime}">${expected}</time>`);
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
    expect(html).toMatch(/<h2[^>]*>Decisions<\/h2>/);
    expect(html).toMatch(/<ul[^>]*><li>Keep the API/);
    expect(html).toContain("00:02:27");
    expect(html).toMatch(/<ol[^>]*><li>First step<\/li><\/ol>/);
    expect(html).toContain('checked=""');
    expect(html).toContain("<th>Owner</th>");
    expect(html).toMatch(/<blockquote[^>]*>First line\nSecond line<\/blockquote>/);
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

  it("groups account actions in the footer and keeps Workspace navigation in the sidebar", () => {
    vi.stubGlobal("navigator", { language: "en" });
    const session = { user: { id: "user", name: "Example User" },  capabilities: { sync: true, sharing: true, sessions: true, admin: false } };
    const html = renderToStaticMarkup(createElement(SidebarProvider, { session, children: createElement(Sidebar, {
      session, brand: "Dahlia", children: createElement("a", { href: "/dashboard/settings" }, "Settings"),
    }) }));
    const [navigation, footer] = html.split('<div class="sidebar-footer');
    expect(navigation).toContain("Project navigation");
    expect(navigation).not.toContain("organization-switcher");
    expect(navigation).not.toContain("Account settings");
    expect(footer).toContain('aria-haspopup="menu"');
    expect(footer).toContain('aria-label="Account menu: Example User"');
    expect(footer).not.toContain("All accessible Workspaces");
    expect(footer).not.toContain("<small>");
    expect(footer).not.toContain('href="/workspaces"');
    expect(navigation).toContain('href="/workspaces"');
    expect(footer).not.toContain('<strong>Organizations</strong>');
    expect(footer).not.toContain("aria-pressed");
    expect(readFileSync(new URL("../src/client/Sidebar.tsx", import.meta.url), "utf8"))
      .toContain('window.location.replace("/sign-out")');
    expect(footer).not.toContain("personal:");
    expect(footer).not.toContain("Local account");
    expect(navigation).toContain('href="/orgs"');
    expect(footer).not.toContain("sidebar-settings");
    expect(footer).not.toContain("Artifacts");
  });

  it("labels the AI navigation as chat", () => {
    vi.stubGlobal("navigator", { language: "ja-JP" });
    const session = { user: { id: "user" }, capabilities: { sync: false, sharing: false, sessions: false, admin: false, ai: true } };
    const html = renderToStaticMarkup(createElement(SidebarProvider, { session, children: createElement(Sidebar, {
      session, brand: "Dahlia", children: null,
    }) }));
    expect(html).toContain('href="/chat"');
    expect(html).toContain('aria-label="Dahlia AI とチャット"');
    expect(html).toContain(">チャット</span>");
  });

  it("generates direct and Databricks proxy MCP client settings", () => {
    const url = "https://dahlia.aws.databricksapps.com/mcp";
    const direct = { url, databricksProxy: false, available: true } as const;
    const proxy = { url: "https://dahlia.example/mcp", proxyUrl: url, databricksProxy: true, available: true } as const;
    expect(mcpConnectionOutput("codex", direct)).toBe(`codex mcp add dahlia --url '${url}'`);
    expect(mcpConnectionOutput("claude", direct)).toBe(`claude mcp add --scope user --transport http dahlia '${url}'`);
    expect(JSON.parse(mcpConnectionOutput("mcpJSON", direct))).toEqual({ mcpServers: { dahlia: { type: "http", url } } });
    expect(mcpConnectionOutput("codex", proxy, "team profile"))
      .toContain(`uvx uc-mcp-proxy --url '${url}' --profile 'team profile'`);
    expect(JSON.parse(mcpConnectionOutput("mcpJSON", proxy, "team"))).toEqual({
      mcpServers: { dahlia: { type: "stdio", command: "uvx", args: ["uc-mcp-proxy", "--url", url, "--profile", "team"] } },
    });
  });

  it("validates MCP settings before rendering client commands", () => {
    const settings = { mcp: { url: "https://dahlia.example/mcp", databricksProxy: false, available: true } };
    expect(parseMCPConnectionInfo(settings)).toEqual(settings);
    expect(parseMCPConnectionInfo({ mcp: { ...settings.mcp, databricksProxy: true, proxyUrl: "https://dahlia.aws.databricksapps.com/mcp" } }))
      .toMatchObject({ mcp: { url: settings.mcp.url, proxyUrl: "https://dahlia.aws.databricksapps.com/mcp" } });
    expect(() => parseMCPConnectionInfo({ provider: "header" })).toThrow("invalid MCP settings");
    expect(() => parseMCPConnectionInfo({ mcp: { ...settings.mcp, url: "javascript:alert(1)" } })).toThrow("invalid MCP settings");
    expect(() => parseMCPConnectionInfo({ mcp: { ...settings.mcp, databricksProxy: true } })).toThrow("invalid MCP settings");
    expect(() => parseMCPConnectionInfo({ mcp: { ...settings.mcp, databricksProxy: true, proxyUrl: "javascript:alert(1)" } })).toThrow("invalid MCP settings");
  });

  it("omits unsupported sign-out and sharing sections for proxy accounts", () => {
    vi.stubGlobal("navigator", { language: "ja-JP" });
    const session = { user: { id: "user", name: "Example User" },  capabilities: { sync: true, sharing: false, sessions: false, admin: false } };
    const html = renderToStaticMarkup(createElement(SidebarProvider, { session, children: createElement(Sidebar, {
      session, brand: "Dahlia", children: null,
    }) }));
    expect(html).toContain('aria-label="ワークスペース"');
    expect(html).not.toContain("ワークスペースを管理");
    expect(html).not.toContain("サインアウト");
    expect(html).not.toContain('<strong>組織</strong>');
    expect(html).not.toContain("組織を管理");
    expect(html).not.toContain('href="/admin/members"');
  });

  it("requests every accessible Workspace without an Organization filter", () => {
    const query = vi.spyOn(liveData, "useLiveJSON").mockReturnValue({ data: undefined, loading: true, error: undefined, reload: vi.fn(), replace: vi.fn() });
    const session = { user: { id: "user" }, capabilities: { sync: true, sharing: false, sessions: false, admin: false } };
    try {
      renderToStaticMarkup(createElement(SidebarProvider, { session, children: createElement("div") }));
      expect(query).toHaveBeenCalledWith(expect.objectContaining({ key: '["listWorkspaces",{}]' }));
    } finally { query.mockRestore(); }
  });

  it.each([false, true])("keeps server administration outside the account menu with sharing=%s", (sharing) => {
    vi.stubGlobal("navigator", { language: "ja-JP" });
    const session = { user: { id: "user", name: "Example User" },  capabilities: { sync: true, sharing, sessions: true, admin: true } };
    const html = renderToStaticMarkup(createElement(SidebarProvider, { session, children: createElement(Sidebar, {
      session, brand: "Dahlia", children: createElement("a", { href: "/dashboard/settings" }, "設定"),
    }) }));
    const [navigation, footer] = html.split('<div class="sidebar-footer');
    for (const path of ["/admin/orgs", "/admin/users", "/admin/settings"]) {
      expect(navigation).toContain(`href="${path}"`);
      expect(footer).not.toContain(`href="${path}"`);
    }
    expect(navigation).toContain("サーバー設定");
    expect(footer).toContain('aria-haspopup="menu"');
  });
});

describe("dashboard navigation", () => {
  it("keeps every accounts-only screen hidden until accounts authentication is confirmed", () => {
    vi.stubGlobal("navigator", { language: "en-US" });
    for (const pathname of ["/sign-in", "/oauth/consent"]) {
      vi.stubGlobal("window", { location: { pathname } });
      const html = renderToStaticMarkup(createElement(App));
      expect(html).toContain("Loading account…");
      expect(html).not.toContain("Continue with Google");
      expect(html).not.toContain("Allow this Mac to use the Dahlia AI Gateway?");
    }
  });

  it("shows account sign-in only when the deployment explicitly uses accounts authentication", async () => {
    for (const [provider, required] of [["accounts", true], ["header", false]] as const) {
      vi.stubGlobal("fetch", vi.fn(async () => Response.json({ provider })));
      await expect(accountSignInRequired()).resolves.toBe(required);
    }
    vi.stubGlobal("fetch", vi.fn(async () => Response.json({ error: "unavailable" }, { status: 503 })));
    await expect(accountSignInRequired()).rejects.toMatchObject({ status: 503 });
  });

  it("shows a stable notice with an explicit escape when Header authentication handles sign-in", () => {
    vi.stubGlobal("navigator", { language: "en-US" });
    const html = renderToStaticMarkup(createElement(HeaderAuthenticationNotice, {
      brand: { name: "Dahlia", product: "Server" },
    }));
    expect(html).toContain("This deployment uses external authentication.");
    expect(html).toContain('<a class="secondary" href="/dashboard">Return to dashboard</a>');
    expect(html).not.toContain("Continue with Google");
  });

  it("uses advertised thumbnails for browsing and preserves the original link", () => {
    const file = { id: "file", workspaceId: "workspace", name: "image.png", size: 1, checksum: "hash", revision: 1, createdAt: "2026-09-07T00:00:00Z", updatedAt: "2026-09-07T00:00:00Z", contentType: "image/png", metadata: { source: "screenshot" as const },
      variants: { thumb_480: "/small", thumb_1280: "/medium", thumb_1568: "/preview", thumb_1920: "/large" } };
    const capturedAt = "2026-09-07T00:00:00Z";
    const html = renderToStaticMarkup(createElement(ScreenshotFigure, { file, capturedAt }));
    expect(html).toContain('src="/small"');
    expect(html).toContain('href="/files/file"');
    expect(html).not.toContain('target="_blank"');
    expect(html).toContain('href="/api/v1/files/file/content"');
    expect(html).toContain("Download original");
    expect(html).toContain(`dateTime="${capturedAt}"`);
    const portable = renderToStaticMarkup(createElement(ScreenshotFigure, { file: { ...file, variants: {} } }));
    expect(portable).toContain('src="/api/v1/files/file/content"');
    expect(portable).not.toContain("/large");
  });
  it("previews images but never embeds active file content, and removes inaccessible previews", () => {
    vi.stubGlobal("navigator", { language: "en" });
    const query = vi.spyOn(liveData, "useLiveJSON");
    try {
      for (const contentType of ["image/png", "image/tiff", "text/html", "image/svg+xml"]) {
        query.mockReturnValue({ data: { id: "f1", revision: 2, name: "Example", contentType, metadata: { ocrText: "Detected text", caption: "Image caption" }, variants: { thumb_1568: "/preview" } }, error: undefined, loading: false, reload: vi.fn(), replace: vi.fn() });
        const html = renderToStaticMarkup(createElement(FileViewer, { fileId: "f1", separateTab: true, onPrevious: vi.fn(), onNext: vi.fn() }));
        expect(query).toHaveBeenCalledWith(expect.objectContaining({ key: "[\"getFile\",{\"params\":{\"path\":{\"fileId\":\"f1\"}}}]" }));
        expect(html).toContain('aria-label="Image information" aria-expanded="false"');
        expect(html).toContain('aria-label="Copy image"');
        expect(html).toContain('aria-label="Zoom out"');
        expect(html).toContain('aria-label="Zoom in"');
        expect(html).toContain('aria-label="Previous image"');
        expect(html).toContain('aria-label="Next image"');
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

  it("selects only the current Workspace and restores the saved selection off Workspace routes", () => {
    const workspaces = [{ workspaceId: "v1", name: "First" }, { workspaceId: "v2", name: "Second" }] as NonNullable<Parameters<typeof selectedSidebarWorkspace>[0]>;
    expect(selectedSidebarWorkspace(workspaces, "v2", "v1")).toBe(workspaces[1]);
    expect(selectedSidebarWorkspace(workspaces, undefined, "v2")).toBe(workspaces[1]);
    expect(selectedSidebarWorkspace(workspaces)).toBe(workspaces[0]);
    expect(selectedSidebarWorkspace(workspaces, undefined, "removed")).toBe(workspaces[0]);
    expect(selectedSidebarWorkspace(workspaces, "outside-scope", "v1")).toBeUndefined();
    expect(selectedSidebarWorkspace([], undefined, "v2")).toBeUndefined();
    expect(selectedSidebarWorkspace(undefined, "v2")).toBeUndefined();
  });

  it("navigates dashboard links in place and leaves other URLs to the browser", () => {
    const current = "https://dahlia.example/workspaces/v1/meetings/m1";
    for (const path of ["/dashboard", "/workspaces/v1", "/workspaces/v1/meetings/m2", "/workspaces/v1/projects/p1", "/dashboard/settings"]) {
      expect(dashboardNavigationPath(path, current)).toBe(path);
      expect(dashboardNavigationPath(`https://dahlia.example${path}`, current)).toBe(path);
    }
    for (const href of ["https://other.example/dashboard", "/api/v1/files/f1/content", "/sign-in", "/oauth/consent", "/dashboard/extension", "/dashboard?q=search", "#section", "mailto:user@example.com"]) {
      expect(dashboardNavigationPath(href, current)).toBeUndefined();
    }
  });

  it("builds exclusive scopes and expands the selected Project ancestry by ID", () => {
    expect(apiUrls.listWorkspaces({})).toBe("/api/v1/workspaces");
    expect(apiUrls.listWorkspaces({ params: { query: { organizationId: "org+1" } } })).toBe("/api/v1/workspaces?organizationId=org%2B1");
    expect(apiUrls.listWorkspaces({ params: { query: { organizationId: "org+1" } } })).toBe("/api/v1/workspaces?organizationId=org%2B1");
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
    expect(resolveDashboardRoute("/chat", { admin: false, sessions: false, ai: true })).toEqual({ page: "ai" });
    expect(resolveDashboardRoute("/chat", { admin: false, sessions: false, ai: false })).toEqual({ redirect: "/dashboard" });
  });

  it("routes chat deep links independently of their validity and retires the AI page", () => {
    const capabilities = { admin: false, sessions: true, ai: true };
    for (const id of [encodeId("aiThread", "01990ab0-0000-7000-8000-000000000001"), "invalid"]) {
      const path = `/chat/${id}`;
      expect(resolveDashboardRoute(path, capabilities)).toEqual({ page: "ai", threadId: id });
      expect(dashboardNavigationPath(path, "https://dahlia.example/chat")).toBe(path);
      expect(resolveDashboardRoute(path, { ...capabilities, ai: false })).toEqual({ redirect: "/dashboard" });
    }
    expect(isCoreDashboardPath("/ai")).toBe(false);
    expect(resolveDashboardRoute("/ai", capabilities)).toEqual({ redirect: "/dashboard" });
    expect(isCoreDashboardPath("/chat/id/messages")).toBe(false);
  });

  it("resolves canonical detail URLs and preserves capability gates", () => {
    for (const [path, result] of [[`/projects/${encodeId("project", "01990ab0-0000-7000-8000-000000000001")}`, { page: "project", projectId: encodeId("project", "01990ab0-0000-7000-8000-000000000001") }], [`/meetings/${encodeId("meeting", "01990ab0-0000-7000-8000-000000000001")}`, { page: "meeting", meetingId: encodeId("meeting", "01990ab0-0000-7000-8000-000000000001") }], [`/files/${encodeId("file", "01990ab0-0000-7000-8000-000000000001")}`, { page: "file", fileId: encodeId("file", "01990ab0-0000-7000-8000-000000000001") }]] as const) {
      expect(resolveDashboardRoute(path, { admin: false, sessions: true, sync: true })).toEqual(result);
      expect(resolveDashboardRoute(path, { admin: false, sessions: true, sync: false })).toEqual({ redirect: "/dashboard" });
      expect(dashboardNavigationPath(path, "https://dahlia.example/workspaces/v1")).toBe(path);
    }
  });

  it("renders localized collection rows without internal metadata", () => {
    const meeting = { meetingId: "m1", name: "Planning", description: "Preview omitted from compact rows", createdAt: "2026-09-07T00:00:00Z", status: "TRANSCRIPT_NOT_FOUND" } as SyncedMeetingInfo;
    const html = renderToStaticMarkup(createElement(MeetingList, { meetings: [meeting], loading: false }));
    expect(html).toContain('href="/meetings/m1"');
    expect(html).toContain("Planning");
    expect(html).not.toContain("TRANSCRIPT_NOT_FOUND");
    expect(html).not.toContain("Preview omitted from compact rows");
    vi.stubGlobal("navigator", { language: "ja-JP" });
    expect(renderToStaticMarkup(createElement(MeetingList, { meetings: [], loading: false }))).toContain("ミーティングはまだありません");
  });

  it("gates synchronized Workspace routes with the sync capability", () => {
    const enabled = { admin: false, sessions: false, sync: true };
    expect(resolveDashboardRoute("/workspaces", enabled)).toEqual({ page: "workspaces" });
    const workspace = encodeId("workspace", "01990ab0-0000-7000-8000-000000000001");
    expect(resolveDashboardRoute(`/workspaces/${workspace}`, enabled)).toEqual({ page: "workspace", workspaceId: workspace });
    expect(resolveDashboardRoute("/workspaces/v1/projects/p1", enabled))
      .toEqual({ redirect: "/dashboard" });
    expect(resolveDashboardRoute("/workspaces/v1/meetings/m1", enabled))
      .toEqual({ redirect: "/dashboard" });
    expect(resolveDashboardRoute("/workspaces", { admin: false, sessions: false, sync: false }))
      .toEqual({ redirect: "/dashboard" });
  });

  it("gates organization and invitation routes with session capabilities", () => {
    const enabled = { admin: false, sessions: true, sharing: true };
    const organization = encodeId("organization", "01990ab0-0000-7000-8000-000000000001");
    expect(resolveDashboardRoute("/orgs", enabled)).toEqual({ page: "organizations" });
    expect(resolveDashboardRoute(`/orgs/${organization}`, enabled))
      .toEqual({ page: "organization", organizationId: organization });
    expect(dashboardNavigationPath(`/orgs/${organization}`, "https://example.com/orgs"))
      .toBe(`/orgs/${organization}`);
    expect(resolveDashboardRoute(`/orgs/${organization}`, { ...enabled, sharing: false }))
      .toEqual({ redirect: "/dashboard" });
    expect(resolveDashboardRoute(`/orgs/${organization}`, { ...enabled, sessions: false }))
      .toEqual({ page: "organization", organizationId: organization });
    for (const path of ["/organizations", "/organizations/alpha-team", "/orgs/alpha-team", "/orgs/org_invalid", `/orgs/${encodeId("team", "01990ab0-0000-7000-8000-000000000001")}`]) {
      expect(resolveDashboardRoute(path, enabled)).toEqual({ redirect: "/dashboard" });
    }
    expect(dashboardNavigationPath("/organizations", "https://example.com/orgs")).toBeUndefined();
    expect(dashboardNavigationPath("/organizations/alpha-team", "https://example.com/orgs")).toBeUndefined();
    const invitation = encodeId("invitation", "01990ab0-0000-7000-8000-000000000001");
    expect(resolveDashboardRoute(`/accept-invitation/${invitation}`, enabled))
      .toEqual({ page: "invitation", invitationId: invitation });
    expect(resolveDashboardRoute("/orgs", { ...enabled, sharing: false }))
      .toEqual({ redirect: "/dashboard" });
    expect(resolveDashboardRoute("/orgs", { ...enabled, sessions: false }))
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
    for (const [path, page] of [["/admin/users", "admin-users"], ["/admin/orgs", "admin-organizations"], ["/admin/settings", "admin-settings"]]) {
      expect(resolveDashboardRoute(path!, admin)).toEqual({ page });
      expect(resolveDashboardRoute(path!, user)).toEqual({ redirect: "/dashboard" });
    }
    expect(resolveDashboardRoute("/admin/organizations", admin)).toEqual({ redirect: "/dashboard" });
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


describe("meeting hover details", () => {
  it("shows existing metadata, localized recording status and missing-value fallbacks", () => {
    const meeting = { name: "Planning", description: "Discuss the next release", duration: 3360,
      createdAt: "2026-09-10T06:00:00Z", recordingStartedAt: "2026-09-10T07:00:00Z" } as SyncedMeetingInfo;
    for (const [language, duration, recording] of [["ja-JP", "56分", "録音中"], ["en-US", "56 min", "Recording"]]) {
      vi.stubGlobal("navigator", { language });
      const html = renderToStaticMarkup(createElement(MeetingHoverDetails, { meeting, projectName: "GMO/Nikko" }));
      for (const text of ["Planning", "Discuss the next release", "GMO/Nikko", duration, 'dateTime="2026-09-10T07:00:00Z"']) expect(html).toContain(text);
      expect(renderToStaticMarkup(createElement(MeetingHoverDetails, { meeting: { ...meeting, isRecording: true } }))).toContain(recording);
    }
    const empty = renderToStaticMarkup(createElement(MeetingHoverDetails, { meeting: { ...meeting, name: "", description: " ", duration: null, recordingStartedAt: null } }));
    expect(empty).toContain("Untitled meeting");
    expect(empty).toContain('dateTime="2026-09-10T06:00:00Z"');
    expect(empty).toContain("—");
    expect(empty).not.toContain("meeting-preview-project");
  });
});


it("routes administrator organization details independently of sharing membership", () => {
  const id = encodeId("organization", "019d4a01-2000-7000-8000-000000000001");
  expect(resolveDashboardRoute(`/admin/orgs/${id}`, { admin: true, sessions: false, sharing: false })).toEqual({ page: "admin-organization", organizationId: id });
  expect(resolveDashboardRoute(`/admin/orgs/${id}`, { admin: false, sessions: true, sharing: true })).toEqual({ redirect: "/dashboard" });
});


it("keeps Workspace creation available while showing every accessible Workspace", () => {
  vi.stubGlobal("navigator", { language: "en-US" });
  const scope = vi.spyOn(sidebar, "useSidebar").mockReturnValue({ userId: "user", organizations: [{ id: "team", name: "Team", slug: "team", kind: "team" }], workspaces: [], reload: vi.fn() });
  const query = vi.spyOn(liveData, "useLiveJSON").mockReturnValue({ data: undefined, loading: false, error: undefined, reload: vi.fn(), replace: vi.fn() });
  try {
    const html = renderToStaticMarkup(createElement(Workspaces));
    expect(html).toContain("New Workspace</button>");
    expect(html).not.toContain("Accessible Workspaces owned by this organization");
  } finally { scope.mockRestore(); query.mockRestore(); }
});

it("labels each Workspace with its owning Organization", () => {
  vi.stubGlobal("navigator", { language: "ja-JP" });
  const workspace = { workspaceId: "workspace", organizationId: "alpha", organizationName: "Alpha", name: "企画", role: "admin", revision: 1,
    createdAt: "2026-09-16T00:00:00Z" } as SyncedWorkspaceInfo;
  const scope = vi.spyOn(sidebar, "useSidebar").mockReturnValue({ userId: "user",
    organizations: [{ id: "alpha", name: "Alpha", slug: "alpha", kind: "team" }], workspaces: [workspace], reload: vi.fn() });
  const query = vi.spyOn(liveData, "useLiveJSON").mockReturnValue({ data: undefined, loading: false, error: undefined, reload: vi.fn(), replace: vi.fn() });
  try {
    const html = renderToStaticMarkup(createElement(Workspaces));
    expect(html).toContain('class="workspace-organization-badge" role="img" aria-label="組織: Alpha"');
    expect(html).toContain("<span>Alpha</span>");
  } finally { scope.mockRestore(); query.mockRestore(); }
});

it("rejects retired Web paths and workspace ID prefixes", () => {
  const capabilities = { admin: false, sessions: true, sync: true };
  const id = encodeId("workspace", "01950000-0000-7000-8000-000000000001");
  expect(isCoreDashboardPath("/vaults")).toBe(false);
  expect(isCoreDashboardPath(`/vaults/${id.replace("ws_", "vlt_")}`)).toBe(false);
  expect(resolveDashboardRoute("/vaults", capabilities)).toEqual({ redirect: "/dashboard" });
  expect(resolveDashboardRoute(`/vaults/${id.replace("ws_", "vlt_")}`, capabilities)).toEqual({ redirect: "/dashboard" });
  expect(resolveDashboardRoute(`/workspaces/${id.replace("ws_", "vlt_")}`, capabilities)).toEqual({ redirect: "/dashboard" });
  expect(resolveDashboardRoute("/vaults/vlt_invalid", capabilities)).toEqual({ redirect: "/dashboard" });
  expect(resolveDashboardRoute(`/vaults/${id.replace("ws_", "vlt_")}`, { ...capabilities, sync: false })).toEqual({ redirect: "/dashboard" });
});
