import { readFileSync } from "node:fs";

import { describe, expect, it } from "vitest";

import {
  canEmbedArtifact,
  resolveDashboardExtensionRoute,
  type DashboardExtension,
} from "../src/client/App";
import { filterAndSortModels, type ModelAliasInfo } from "../src/client/model-list";
import { artifactViewerId, resolveDashboardRoute, shouldRedirectToSignIn } from "../src/client/routes";

const ExtensionPage = () => null;

describe("dashboard navigation", () => {
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
    expect(resolveDashboardRoute("/admin", admin)).toEqual({ redirect: "/admin/models" });
    expect(resolveDashboardRoute("/admin/models", admin)).toEqual({ page: "admin-models" });
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
  });

  it("uses immediate accessible switches for Databricks models", () => {
    const source = readFileSync(new URL("../src/client/App.tsx", import.meta.url), "utf8");
    const styles = readFileSync(new URL("../src/client/styles.css", import.meta.url), "utf8");

    expect(source).toContain('className="switch-field"');
    expect(source).toContain('role="switch"');
    expect(source).toContain('aria-label={`Enable ${model.upstreamModel}`}');
    expect(source).toContain('typeof detail?.error === "string"');
    expect(source).toContain('method: configured ? "PATCH" : "POST"');
    expect(source).toContain("setEnabled(previousEnabled)");
    expect(source).toContain("!databricksModels && (");
    expect(styles).toContain(".switch-field input:focus-visible + .switch-control");
    expect(styles).toContain(".provider-model-row { grid-template-columns: 1fr; }");
  });

  it("filters models by name and applies the default sort order", () => {
    const model = (alias: string, displayName: string, enabled: boolean, updateTime: string): ModelAliasInfo => ({
      alias,
      upstreamModel: `system.ai.${alias}`,
      displayName,
      enabled,
      updateTime,
    });
    const models = [
      model("alpha-old", "Alpha", false, "2026-08-01T00:00:00Z"),
      model("zulu", "Zulu", true, "2026-08-01T00:00:00Z"),
      model("alpha-new", "Alpha", false, "2026-08-02T00:00:00Z"),
    ];

    expect(filterAndSortModels(models, "").map(({ alias }) => alias))
      .toEqual(["zulu", "alpha-new", "alpha-old"]);
    expect(filterAndSortModels(models, "SYSTEM.AI.ALPHA").map(({ alias }) => alias))
      .toEqual(["alpha-new", "alpha-old"]);
  });
});
