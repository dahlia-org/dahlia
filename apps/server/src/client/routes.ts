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
  "/artifacts",
  "/vaults",
  "/organizations",
  "/admin",
  "/admin/models",
  "/admin/members",
]);

export function isCoreDashboardPath(path: string): boolean {
  return coreDashboardPaths.has(path)
    || /^\/vaults\/[^/]+(?:\/(?:meetings|projects)\/[^/]+)?$/.test(path)
    || /^\/accept-invitation\/[^/]+$/.test(path);
}

export type DashboardRoute = {
  page?: "overview" | "settings" | "artifacts" | "vaults" | "vault" | "meeting" | "project" | "organizations" | "invitation" | "admin-members";
  redirect?: string;
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
  if (path === "/artifacts") return { page: "artifacts" };
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
  const meeting = path.match(/^\/vaults\/([^/]+)\/meetings\/([^/]+)$/);
  if (meeting) {
    return capabilities.sync
      ? { page: "meeting", vaultId: meeting[1], meetingId: meeting[2] }
      : { redirect: "/dashboard" };
  }
  const project = path.match(/^\/vaults\/([^/]+)\/projects\/([^/]+)$/);
  if (project) {
    return capabilities.sync
      ? { page: "project", vaultId: project[1], projectId: project[2] }
      : { redirect: "/dashboard" };
  }
  const vault = path.match(/^\/vaults\/([^/]+)$/);
  if (vault) return capabilities.sync ? { page: "vault", vaultId: vault[1] } : { redirect: "/dashboard" };
  if (path === "/dashboard/settings") {
    return capabilities.sessions ? { page: "settings" } : { redirect: "/dashboard" };
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

export function artifactViewerId(path: string): string | undefined {
  return path.match(/^\/artifacts\/([^/]+)$/)?.[1];
}
