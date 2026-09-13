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
  "/workspaces",
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
    || /^\/workspaces\/[^/]+(?:\/(?:meetings|projects)\/[^/]+)?$/.test(path)
    || /^\/admin\/organizations\/[^/]+$/.test(path)
    || /^\/accept-invitation\/[^/]+$/.test(path);
}

export type DashboardRoute = {
  page?: "file" | "overview" | "settings" | "workspaces" | "workspace" | "meeting" | "project" | "organizations" | "organization" | "invitation" | "admin-users" | "admin-organizations" | "admin-organization" | "admin-settings";
  redirect?: string;
  fileId?: string;
  workspaceId?: string;
  meetingId?: string;
  projectId?: string;
  invitationId?: string;
  organizationSlug?: string;
  organizationId?: string;
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
  if (path === "/workspaces") return capabilities.sync ? { page: "workspaces" } : { redirect: "/dashboard" };
  const detail = path.match(/^\/(meetings|projects|files)\/([^/]+)$/);
  if (detail && validID(({ meetings: "meeting", projects: "project", files: "file" } as const)[detail[1] as "meetings" | "projects" | "files"], detail[2])) {
    if (!capabilities.sync) return { redirect: "/dashboard" };
    if (detail[1] === "meetings") return { page: "meeting", meetingId: detail[2] };
    if (detail[1] === "projects") return { page: "project", projectId: detail[2] };
    return { page: "file", fileId: detail[2] };
  }
  const workspace = path.match(/^\/workspaces\/([^/]+)$/);
  if (workspace && validID("workspace", workspace[1])) return capabilities.sync ? { page: "workspace", workspaceId: workspace[1] } : { redirect: "/dashboard" };
  if (path === "/dashboard/settings") {
    return { page: "settings" };
  }
  if (path === "/admin") return { redirect: capabilities.admin ? "/admin/settings" : "/dashboard" };
  if (path === "/admin/models") {
    return { redirect: "/dashboard" };
  }
  if (path === "/admin/members") return { redirect: capabilities.admin ? "/admin/users" : "/dashboard" };
  if (path === "/admin/users") return capabilities.admin ? { page: "admin-users" } : { redirect: "/dashboard" };
  const adminOrganization = path.match(/^\/admin\/organizations\/([^/]+)$/);
  if (adminOrganization && validID("organization", adminOrganization[1])) return capabilities.admin
    ? { page: "admin-organization", organizationId: adminOrganization[1] } : { redirect: "/dashboard" };
  if (path === "/admin/organizations") return capabilities.admin ? { page: "admin-organizations" } : { redirect: "/dashboard" };
  if (path === "/admin/settings") return capabilities.admin ? { page: "admin-settings" } : { redirect: "/dashboard" };
  return { redirect: "/dashboard" };
}

function validID(kind: IDKind, value: string | undefined): boolean {
  try { decodeId(kind, value ?? ""); return true; } catch { return false; }
}
