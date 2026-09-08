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
  "/vaults",
  "/organizations",
  "/admin",
  "/admin/models",
  "/admin/members",
]);

export function isCoreDashboardPath(path: string): boolean {
  return coreDashboardPaths.has(path)
    || /^\/(?:meetings|projects|files)\/[^/]+$/.test(path)
    || /^\/vaults\/[^/]+(?:\/(?:meetings|projects)\/[^/]+)?$/.test(path)
    || /^\/accept-invitation\/[^/]+$/.test(path);
}

export type DashboardRoute = {
  page?: "file" | "overview" | "settings" | "vaults" | "vault" | "meeting" | "project" | "organizations" | "invitation" | "admin-members";
  redirect?: string;
  fileId?: string;
  vaultId?: string;
  meetingId?: string;
  projectId?: string;
  invitationId?: string;
};

export function resolveDashboardRoute(
  path: string,
  capabilities: DashboardCapabilities,
): DashboardRoute {
  if (path === "/") return { redirect: "/dashboard" };
  if (path === "/sessions") return { redirect: "/dashboard/settings" };
  if (path === "/dashboard") return { page: "overview" };
  if (path === "/organizations") {
    return capabilities.sharing
      ? { page: "organizations" }
      : { redirect: "/dashboard" };
  }
  const invitation = path.match(/^\/accept-invitation\/([^/]+)$/);
  if (invitation) {
    return capabilities.sharing && capabilities.sessions
      ? { page: "invitation", invitationId: invitation[1] }
      : { redirect: "/dashboard" };
  }
  if (path === "/vaults") return capabilities.sync ? { page: "vaults" } : { redirect: "/dashboard" };
  const detail = path.match(/^\/(meetings|projects|files)\/([^/]+)$/);
  if (detail) {
    if (!capabilities.sync) return { redirect: "/dashboard" };
    if (detail[1] === "meetings") return { page: "meeting", meetingId: detail[2] };
    if (detail[1] === "projects") return { page: "project", projectId: detail[2] };
    return { page: "file", fileId: detail[2] };
  }
  const legacy = path.match(/^\/vaults\/[^/]+\/(meetings|projects)\/([^/]+)$/);
  if (legacy) return { redirect: capabilities.sync ? `/${legacy[1]}/${legacy[2]}` : "/dashboard" };
  const vault = path.match(/^\/vaults\/([^/]+)$/);
  if (vault) return capabilities.sync ? { page: "vault", vaultId: vault[1] } : { redirect: "/dashboard" };
  if (path === "/dashboard/settings") {
    return { page: "settings" };
  }
  if (path === "/admin") return { redirect: capabilities.admin ? "/admin/members" : "/dashboard" };
  if (path === "/admin/models") {
    return { redirect: "/dashboard" };
  }
  if (path === "/admin/members") {
    return capabilities.admin ? { page: "admin-members" } : { redirect: "/dashboard" };
  }
  return { redirect: "/dashboard" };
}
