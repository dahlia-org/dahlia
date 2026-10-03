import { parseObjectPath } from "../object-url";
import { PendingDocumentNotice } from "./Documents";
import { DahliaMemoryPage } from "./DahliaMemory";
import { apiQuery, useLiveJSON } from "./live-data";
import { type ReactNode, useEffect, useState } from "react";
import { navigateDashboard } from "./navigation";
import { type SyncedMeetingInfo, type SyncedProjectInfo, uiText } from "./api";
import { FileViewer } from "./FileViewer";
import { MenuIcon } from "./Sidebar";
import { AppShell } from "./layout/AppShell";
import { AiChat } from "./AiChat";
import { resolveDashboardRoute } from "./routes";
import { type DashboardBrand, type DashboardExtension, isServerNavigation, resolveDashboardExtensionRoute, useDashboardSession } from "./dashboard";
import { AccountsOnly, Brand, Consent, SignIn } from "./SignIn";
import { Settings } from "./Settings";
import { Overview, WorkspaceMeetings } from "./Workspaces";
import { SyncedProject } from "./Project";
import { SyncedMeeting } from "./Meeting";
import { Invitation, Organization, Organizations } from "./Organizations";
import { AdminDirectory, AdminMembers, AdminOrganization, AdminSearchSettings } from "./Admin";
import { DataError } from "./DataError";

export interface AppProps {
  brand?: DashboardBrand;
  extensions?: readonly DashboardExtension[];
}

const defaultBrand: DashboardBrand = { name: "Dahlia", product: "Server" };

function DashboardRedirect({ path }: { path: string }) {
  useEffect(() => navigateDashboard(parseObjectPath(path) ? `${path}${window.location.search}${window.location.hash}` : path, true), [path]);
  return null;
}

export function App({ brand = defaultBrand, extensions = [] }: AppProps) {
  const [path, setPath] = useState(window.location.pathname);
  useEffect(() => {
    const followHistory = () => setPath(window.location.pathname);
    window.addEventListener("popstate", followHistory);
    return () => window.removeEventListener("popstate", followHistory);
  }, []);

  const { session, sessionError, unauthorized, retrySession } = useDashboardSession(path);

  const detail = parseObjectPath(path);
  const detailQuery = useLiveJSON<{ workspaceId: string }>(!session?.capabilities.sync || !detail || detail.kind === "workspace" ? undefined
    : detail.kind === "meeting" ? apiQuery("getMeeting", { params: { path: { meetingId: detail.id } } })
      : detail.kind === "project" ? apiQuery("getProject", { params: { path: { projectId: detail.id } } })
        : apiQuery("getFile", { params: { path: { fileId: detail.id } } }));
  const detailWorkspaceId = detailQuery.data?.workspaceId;
  const detailMeeting = detail?.kind === "meeting" ? detailQuery.data as SyncedMeetingInfo | undefined : undefined;
  const detailProject = detail?.kind === "project" ? detailQuery.data as SyncedProjectInfo | undefined : undefined;

  if (path === "/sign-in") return <AccountsOnly brand={brand}><SignIn brand={brand} /></AccountsOnly>;
  if (path === "/oauth/consent") return <AccountsOnly brand={brand}><Consent brand={brand} /></AccountsOnly>;
  if (unauthorized) return null;
  if (sessionError && !session) {
    return (
      <main className="loading">
        <Brand brand={brand} />
        <span>{sessionError}</span>
        <button className="secondary" onClick={retrySession}>Try again</button>
      </main>
    );
  }
  if (!session) return <main className="loading"><Brand brand={brand} /><span>Loading account…</span></main>;
  const extension = resolveDashboardExtensionRoute(path, session.capabilities, extensions);
  const extensionRoute = extension.route;
  const route = extensionRoute ? {} : resolveDashboardRoute(path, session.capabilities);
  let page: ReactNode;
  if (!extension.allowed || route.redirect) page = <DashboardRedirect path={route.redirect ?? "/dashboard"} />;
  else if (extensionRoute) {
    const ExtensionPage = extensionRoute.component;
    page = <ExtensionPage session={session} />;
  }
  else if (route.page === "admin-users") page = <><AdminDirectory kind="users" /><AdminMembers /></>;
  else if (route.page === "admin-organization") page = <AdminOrganization key={route.organizationId} organizationId={route.organizationId!} session={session} />;
  else if (route.page === "admin-organizations") page = <AdminDirectory kind="organizations" />;
  else if (route.page === "admin-settings") page = <AdminSearchSettings />;
  else if (route.page === "workspace") page = <WorkspaceMeetings session={session} workspaceId={route.workspaceId!} />;
  else if (route.page === "meeting") page = detailWorkspaceId ? <SyncedMeeting workspaceId={detailWorkspaceId} meetingId={route.meetingId!} resolvedMeeting={detailMeeting} /> : null;
  else if (route.page === "project") page = detailWorkspaceId ? <SyncedProject workspaceId={detailWorkspaceId} projectId={route.projectId!} resolvedProject={detailProject} /> : null;
  else if (route.page === "file") page = <FileViewer fileId={route.fileId!} />;
  else if (route.page === "organizations") page = <Organizations />;
  else if (route.page === "organization") page = <Organization session={session} organizationId={route.organizationId!} />;
  else if (route.page === "invitation") page = <Invitation invitationId={route.invitationId!} />;
  else if (route.page === "settings") page = <Settings session={session} extensions={extensions} />;
  else if (route.page === "memory") page = <DahliaMemoryPage />;
  else if (route.page === "ai") page = <AiChat requestedThreadId={route.threadId} />;
  else page = <Overview session={session} />;
  return <AppShell brand={<Brand brand={brand} />} extensionPaths={extensions.flatMap((extension) => extension.routes?.map((item) => item.path) ?? [])}
    serverLinks={extensions.flatMap((extension) => extension.navigation ?? []).filter(isServerNavigation).map((item) =>
      (!item.capability || session.capabilities[item.capability]) && <a className="flex items-center gap-2 rounded-md px-2 py-1.5 text-xs text-muted-foreground hover:bg-accent hover:text-foreground" key={item.path} href={item.path}><MenuIcon name="settings" />{item.label}</a>)}
    headerStatus={<PendingDocumentNotice userId={session.user.id} />}
    session={session} path={path} navigate={navigateDashboard} routeWorkspaceId={detailWorkspaceId ?? route.workspaceId}
    routeMeeting={detailMeeting} routeMeetingOwned={detail?.kind === "meeting"}>
    <DataError error={sessionError ? new Error(sessionError) : undefined} retry={retrySession} />
    {detail && detail.kind !== "workspace" && !detailWorkspaceId && route.page !== "file" && <>
      <DataError error={detailQuery.error} retry={detailQuery.reload} />
      {!detailQuery.error && <p className="content-empty">{uiText("Loading…", "読み込み中…")}</p>}
    </>}
    {page}
  </AppShell>;
}
