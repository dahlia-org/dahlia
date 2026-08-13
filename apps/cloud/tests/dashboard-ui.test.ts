import { readFileSync } from "node:fs";

import { describe, expect, it } from "vitest";

import { resolveDashboardRoute, shouldRedirectToSignIn } from "../src/client/routes";

describe("dashboard navigation", () => {
  it("redirects to sign-in only for an authentication failure", () => {
    expect(shouldRedirectToSignIn(401)).toBe(true);
    expect(shouldRedirectToSignIn(500)).toBe(false);
    expect(shouldRedirectToSignIn(undefined)).toBe(false);
  });

  it("routes the authenticated home to Overview", () => {
    expect(resolveDashboardRoute("/", { admin: false, billing: false, sessions: false })).toEqual({ redirect: "/dashboard" });
    expect(resolveDashboardRoute("/dashboard", { admin: false, billing: false, sessions: false })).toEqual({ page: "overview" });
  });

  it("gates Billing and Settings with session capabilities", () => {
    expect(resolveDashboardRoute("/dashboard/billing", { admin: false, billing: false, sessions: true }))
      .toEqual({ redirect: "/dashboard" });
    expect(resolveDashboardRoute("/dashboard/billing", { admin: false, billing: true, sessions: false }))
      .toEqual({ page: "billing" });
    expect(resolveDashboardRoute("/dashboard/settings", { admin: false, billing: true, sessions: false }))
      .toEqual({ redirect: "/dashboard" });
    expect(resolveDashboardRoute("/dashboard/settings", { admin: false, billing: false, sessions: true }))
      .toEqual({ page: "settings" });
  });

  it("gates administration routes", () => {
    const admin = { admin: true, billing: false, sessions: false };
    const user = { admin: false, billing: false, sessions: false };
    expect(resolveDashboardRoute("/admin", admin)).toEqual({ redirect: "/admin/models" });
    expect(resolveDashboardRoute("/admin/models", admin)).toEqual({ page: "admin-models" });
    expect(resolveDashboardRoute("/admin/members", admin)).toEqual({ page: "admin-members" });
    expect(resolveDashboardRoute("/admin/models", user)).toEqual({ redirect: "/dashboard" });
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
