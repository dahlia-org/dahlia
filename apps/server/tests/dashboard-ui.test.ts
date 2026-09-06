import { projectAncestors, vaultListURL } from "../src/client/Sidebar";
import { readFileSync } from "node:fs";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";

import { describe, expect, it } from "vitest";

import {
  canEmbedArtifact,
  ScreenshotFigure,
  resolveDashboardExtensionRoute,
  type DashboardExtension,
} from "../src/client/App";
import { artifactViewerId, resolveDashboardRoute, shouldRedirectToSignIn } from "../src/client/routes";

const ExtensionPage = () => null;

describe("dashboard navigation", () => {
  it("uses advertised thumbnails for browsing and preserves the original link", () => {
    const file = { id: "file", content_type: "image/png", metadata: { source: "screenshot" },
      variants: { thumb_360: "/small", thumb_1280: "/large" } };
    const html = renderToStaticMarkup(createElement(ScreenshotFigure, { file }));
    expect(html).toContain('src="/small"');
    expect(html).toContain('href="/large"');
    expect(html).toContain('href="/api/v1/files/file/content"');
    expect(html).toContain("Open original");
    const portable = renderToStaticMarkup(createElement(ScreenshotFigure, { file: { ...file, variants: {} } }));
    expect(portable).toContain('src="/api/v1/files/file/content"');
    expect(portable).not.toContain("/large");
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

  it("routes the artifact repository and recognizes only item viewer paths", () => {
    expect(resolveDashboardRoute("/artifacts", { admin: false, sessions: false })).toEqual({ page: "artifacts" });
    expect(artifactViewerId("/artifacts/019cc4dd-e5c5-7bd4-94e0-98df9cc40db9"))
      .toBe("019cc4dd-e5c5-7bd4-94e0-98df9cc40db9");
    expect(artifactViewerId("/artifacts")).toBeUndefined();
    expect(artifactViewerId("/artifacts/id/content")).toBeUndefined();
  });

  it("gates synchronized Vault routes with the sync capability", () => {
    const enabled = { admin: false, sessions: false, sync: true };
    expect(resolveDashboardRoute("/vaults", enabled)).toEqual({ page: "vaults" });
    expect(resolveDashboardRoute("/vaults/v1", enabled)).toEqual({ page: "vault", vaultId: "v1" });
    expect(resolveDashboardRoute("/vaults/v1/projects/p1", enabled))
      .toEqual({ page: "project", vaultId: "v1", projectId: "p1" });
    expect(resolveDashboardRoute("/vaults/v1/meetings/m1", enabled))
      .toEqual({ page: "meeting", vaultId: "v1", meetingId: "m1" });
    expect(resolveDashboardRoute("/vaults", { admin: false, sessions: false, sync: false }))
      .toEqual({ redirect: "/dashboard" });
  });

  it("gates organization and invitation routes with session capabilities", () => {
    const enabled = { admin: false, sessions: true, sharing: true };
    expect(resolveDashboardRoute("/organizations", enabled)).toEqual({ page: "organizations" });
    expect(resolveDashboardRoute("/accept-invitation/invitation-1", enabled))
      .toEqual({ page: "invitation", invitationId: "invitation-1" });
    expect(resolveDashboardRoute("/organizations", { ...enabled, sharing: false }))
      .toEqual({ redirect: "/dashboard" });
    expect(resolveDashboardRoute("/organizations", { ...enabled, sessions: false }))
      .toEqual({ page: "organizations" });
  });

  it("embeds browser-native artifact types and downloads other bytes", () => {
    expect(canEmbedArtifact("text/html; charset=utf-8")).toBe(true);
    expect(canEmbedArtifact("image/png")).toBe(true);
    expect(canEmbedArtifact("application/pdf")).toBe(true);
    expect(canEmbedArtifact("application/zip")).toBe(false);
  });

  it("gates Settings with the session capability", () => {
    expect(resolveDashboardRoute("/dashboard/settings", { admin: false, sessions: false }))
      .toEqual({ redirect: "/dashboard" });
    expect(resolveDashboardRoute("/dashboard/settings", { admin: false, sessions: true }))
      .toEqual({ page: "settings" });
  });

  it("gates administration routes", () => {
    const admin = { admin: true, sessions: false };
    const user = { admin: false, sessions: false };
    expect(resolveDashboardRoute("/admin", admin)).toEqual({ redirect: "/admin/members" });
    expect(resolveDashboardRoute("/admin/models", admin)).toEqual({ redirect: "/dashboard" });
    expect(resolveDashboardRoute("/admin/members", admin)).toEqual({ page: "admin-members" });
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
    expect(source).toContain('sandbox="allow-scripts"');
    expect(source).toContain("application/vnd.dahlia.artifact+json");
    expect(source).toContain("Loading artifacts…");
    expect(source).toContain("/api/auth/organization/list-user-teams?");
    expect(source).not.toContain("/api/auth/organization/list-team-members?");
    expect(source).toContain('team.id !== "external-default"');
    expect(source).toContain("summaryDisplayText(meeting?.summaryDocument ?? null)");
    expect(source).not.toContain("<pre>{meeting.summaryDocument}</pre>");
  });

  it("removes the model management UI", () => {
    const source = readFileSync(new URL("../src/client/App.tsx", import.meta.url), "utf8");
    expect(source).not.toContain("/admin/models");
    expect(source).not.toContain("AdminModels");
  });
});
