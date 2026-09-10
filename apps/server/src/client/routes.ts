import { decodeId, type IDKind } from "../typeid";

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
  "/admin/users",
  "/admin/organizations",
  "/admin/settings",
]);

export function isCoreDashboardPath(path: string): boolean {
  return coreDashboardPaths.has(path)
    || /^\/(?:meetings|projects|files|organizations)\/[^/]+$/.test(path)
    || /^\/vaults\/[^/]+(?:\/(?:meetings|projects)\/[^/]+)?$/.test(path)
    || /^\/accept-invitation\/[^/]+$/.test(path);
}

export type DashboardRoute = {
  page?: "file" | "overview" | "settings" | "vaults" | "vault" | "meeting" | "project" | "organizations" | "organization" | "invitation" | "admin-users" | "admin-organizations" | "admin-settings";
  redirect?: string;
  fileId?: string;
  vaultId?: string;
  meetingId?: string;
  projectId?: string;
  invitationId?: string;
  organizationSlug?: string;
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
  const organization = path.match(/^\/organizations\/([^/]+)$/);
  if (organization) return capabilities.sharing
    ? { page: "organization", organizationSlug: organization[1] }
    : { redirect: "/dashboard" };
  const invitation = path.match(/^\/accept-invitation\/([^/]+)$/);
  if (invitation && validID("invitation", invitation[1])) {
    return capabilities.sharing && capabilities.sessions
      ? { page: "invitation", invitationId: invitation[1] }
      : { redirect: "/dashboard" };
  }
  if (path === "/vaults") return capabilities.sync ? { page: "vaults" } : { redirect: "/dashboard" };
  const detail = path.match(/^\/(meetings|projects|files)\/([^/]+)$/);
  if (detail && validID(({ meetings: "meeting", projects: "project", files: "file" } as const)[detail[1] as "meetings" | "projects" | "files"], detail[2])) {
    if (!capabilities.sync) return { redirect: "/dashboard" };
    if (detail[1] === "meetings") return { page: "meeting", meetingId: detail[2] };
    if (detail[1] === "projects") return { page: "project", projectId: detail[2] };
    return { page: "file", fileId: detail[2] };
  }
  const vault = path.match(/^\/vaults\/([^/]+)$/);
  if (vault && validID("vault", vault[1])) return capabilities.sync ? { page: "vault", vaultId: vault[1] } : { redirect: "/dashboard" };
  if (path === "/dashboard/settings") {
    return { page: "settings" };
  }
  if (path === "/admin") return { redirect: capabilities.admin ? "/admin/settings" : "/dashboard" };
  if (path === "/admin/models") {
    return { redirect: "/dashboard" };
  }
  if (path === "/admin/members") return { redirect: capabilities.admin ? "/admin/users" : "/dashboard" };
  if (path === "/admin/users") return capabilities.admin ? { page: "admin-users" } : { redirect: "/dashboard" };
  if (path === "/admin/organizations") return capabilities.admin ? { page: "admin-organizations" } : { redirect: "/dashboard" };
  if (path === "/admin/settings") return capabilities.admin ? { page: "admin-settings" } : { redirect: "/dashboard" };
  return { redirect: "/dashboard" };
}

function validID(kind: IDKind, value: string | undefined): boolean {
  try { decodeId(kind, value ?? ""); return true; } catch { return false; }
}
