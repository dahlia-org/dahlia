import { readFileSync } from "node:fs";

import { describe, expect, it } from "vitest";

import { resolveDashboardExtensionRoute, type DashboardExtension } from "../src/client/App";
import { resolveDashboardRoute, shouldRedirectToSignIn } from "../src/client/routes";

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

  it("does not expose implementation names or the browser model API", () => {
    const source = readFileSync(new URL("../src/client/App.tsx", import.meta.url), "utf8");

    expect(source).not.toContain("Better Auth");
    expect(source).not.toContain("Trusted proxy");
    expect(source).not.toContain("/api/models");
    expect(source).not.toContain("On-Demand Usage");
    expect(source).not.toContain('className="nav-label"');
    expect(source).toContain('<svg className="brand-mark"');
  });
});
