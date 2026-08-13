export interface DashboardCapabilities {
  admin: boolean;
  sessions: boolean;
  [name: string]: boolean;
}

export function shouldRedirectToSignIn(status: number | undefined): boolean {
  return status === 401;
}

const coreDashboardPaths = new Set([
  "/",
  "/sessions",
  "/dashboard",
  "/dashboard/settings",
  "/admin",
  "/admin/models",
  "/admin/members",
]);

export function isCoreDashboardPath(path: string): boolean {
  return coreDashboardPaths.has(path);
}

export function resolveDashboardRoute(
  path: string,
  capabilities: DashboardCapabilities,
): { page?: "overview" | "settings" | "admin-models" | "admin-members"; redirect?: string } {
  if (path === "/") return { redirect: "/dashboard" };
  if (path === "/sessions") return { redirect: "/dashboard/settings" };
  if (path === "/dashboard") return { page: "overview" };
  if (path === "/dashboard/settings") {
    return capabilities.sessions ? { page: "settings" } : { redirect: "/dashboard" };
  }
  if (path === "/admin") return { redirect: capabilities.admin ? "/admin/models" : "/dashboard" };
  if (path === "/admin/models") {
    return capabilities.admin ? { page: "admin-models" } : { redirect: "/dashboard" };
  }
  if (path === "/admin/members") {
    return capabilities.admin ? { page: "admin-members" } : { redirect: "/dashboard" };
  }
  return { redirect: "/dashboard" };
}
