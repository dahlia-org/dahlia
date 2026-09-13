import { apiQuery } from "./live-data";
import { collectionAppearance, AppearanceIcon, projectAppearance, type Appearance } from "./AppearancePicker";
import { MeetingHoverCard, HoverPreview } from "./MeetingHoverCard";
import { Tooltip } from "./Tooltip";
import { Search } from "./Search";
import { RecordingIndicator } from "./RecordingIndicator";
import { useLiveJSON, useLivePage } from "./live-data";
import { navigateDashboard } from "./navigation";
import { createContext, Fragment, useContext, useEffect, useState, type ReactNode } from "react";
import type { SessionInfo } from "./App";
import type { OrganizationInfo, SyncedMeetingInfo, SyncedProjectInfo, SyncedWorkspaceInfo } from "./api";
import { json, RequestError, uiText } from "./api";


export function projectAncestors(projects: SyncedProjectInfo[], projectId?: string): Set<string> {
  const parents = new Map(projects.map((project) => [project.projectId, project.parentProjectId]));
  const result = new Set<string>();
  while (projectId && parents.has(projectId) && !result.has(projectId)) {
    result.add(projectId);
    projectId = parents.get(projectId) ?? undefined;
  }
  return result;
}

export function selectedSidebarWorkspace(workspaces: SyncedWorkspaceInfo[] | undefined, routeWorkspaceId?: string, savedWorkspaceId?: string): SyncedWorkspaceInfo | undefined {
  const selected = workspaces?.find(({ workspaceId }) => workspaceId === (routeWorkspaceId ?? savedWorkspaceId));
  return selected ?? (routeWorkspaceId ? undefined : workspaces?.[0]);
}

function readSelection(key: string, fallback = ""): string {
  try { return sessionStorage.getItem(key) ?? fallback; }
  catch { return fallback; }
}

function save(key: string, value: string) {
  try { sessionStorage.setItem(key, value); } catch { /* Browsing still works without storage. */ }
}

interface SidebarState {
  userId: string;
  organizationId: string;
  organizations?: OrganizationInfo[];
  organizationError?: string;
  workspaces?: SyncedWorkspaceInfo[];
  error?: string;
  select: (id: string) => void;
  reload: () => void;
}
const SidebarContext = createContext<SidebarState | null>(null);

export function useSidebar() {
  const value = useContext(SidebarContext);
  if (!value) throw new Error("SidebarProvider is required");
  return value;
}

export function SidebarProvider({ session, children }: { session: SessionInfo; children: ReactNode }) {
  const [selectedOrganizationId, setOrganizationId] = useState(() => session.capabilities.sharing ? readSelection(`dahlia:sidebar:${session.user.id}:organization`, "personal") : "personal");
  const organizationsQuery = useLiveJSON<OrganizationInfo[]>(!session.capabilities.sharing ? undefined
    : "/api/auth/organization/list");
  const organizations = organizationsQuery.data;
  const organizationId = selectedOrganizationId === "personal"
    ? organizations?.find((organization) => organization.kind === "personal")?.id ?? "personal"
    : selectedOrganizationId;
  const organizationAllowed = !organizationId || organizations?.some(({ id }) => id === organizationId);
  const workspacesQuery = useLiveJSON<{ items: SyncedWorkspaceInfo[] }>(session.capabilities.sync && organizationAllowed
    ? apiQuery("listWorkspaces", { params: { query: organizationId ? { organizationId } : {} } }) : undefined);
  const select = (id: string) => {
    save(`dahlia:sidebar:${session.user.id}:organization`, id);
    setOrganizationId(id);
    document.getElementById("account-menu")?.hidePopover();
    navigateDashboard("/workspaces");
  };
  useEffect(() => {
    if (!organizationId || organizationId === "personal") return;
    const membershipRemoved = organizations && !organizationAllowed;
    const accessDenied = workspacesQuery.error instanceof RequestError && workspacesQuery.error.status === 403;
    if (!membershipRemoved && !accessDenied) return;
    save(`dahlia:sidebar:${session.user.id}:organization`, "personal");
    setOrganizationId("personal");
    navigateDashboard("/workspaces", true);
  }, [organizationId, organizations, organizationAllowed, workspacesQuery.error, session.user.id]);
  const reload = () => { organizationsQuery.reload(); workspacesQuery.reload(); };
  const organizationError = organizationsQuery.error?.message;
  const workspaceError = workspacesQuery.error?.message ?? (organizationId && !organizations ? organizationError : undefined);
  return <SidebarContext.Provider value={{ userId: session.user.id, organizationId, organizations,
    organizationError, workspaces: workspacesQuery.data?.items, error: workspaceError, select, reload }}>
    <Fragment key={selectedOrganizationId}>{children}</Fragment>
  </SidebarContext.Provider>;
}

function Chevron({ expanded }: { expanded: boolean }) {
  return <svg className="sidebar-chevron" data-expanded={expanded} width="16" height="16" viewBox="0 0 16 16" aria-hidden="true">
    <path d="m6 4 4 4-4 4" fill="none" stroke="currentColor" strokeWidth="1.75" strokeLinecap="round" strokeLinejoin="round" />
  </svg>;
}

function Failure({ message, retry }: { message: string; retry: () => void }) {
  return <div className="sidebar-status" role="alert">{message} <button className="sidebar-action" onClick={retry}>{uiText("Retry", "再試行")}</button></div>;
}

const menuIconPaths = {
  folder: "M3 5h7l2 3h9v12H3V5Z",
  account: "M16 7a4 4 0 1 1-8 0 4 4 0 0 1 8 0ZM4 21v-2a6 6 0 0 1 6-6h4a6 6 0 0 1 6 6v2Z",
  workspace: "M5 5h14l3 10v4H2v-4L5 5ZM2 15h20M10 17h4",
  organization: "M4 21V3h12v18M16 9h4v12M2 21h20M8 7h4M8 11h4M8 15h4M9 21v-3h2v3",
  settings: "m10 2 4 0 1 3 3 1 3-1 2 4-2 2v3l2 2-2 4-3-1-3 1-1 3h-4l-1-3-3-1-3 1-2-4 2-2v-3L1 9l2-4 3 1 3-1 1-3ZM16 12a4 4 0 1 1-8 0 4 4 0 0 1 8 0Z",
  document: "M5 3h9l5 5v13H5V3ZM14 3v6h5M8 13h8M8 17h6",
  members: "M14 7a3 3 0 1 1-6 0 3 3 0 0 1 6 0ZM3 20v-3a5 5 0 0 1 5-5h6a5 5 0 0 1 5 5v3ZM18 4a3 3 0 0 1 0 6M20 13a4 4 0 0 1 3 4v3",
  signOut: "M9 4H3v16h6M8 12h14m-5-5 5 5-5 5",
  check: "m5 12 4 4L19 6",
  home: "m3 10 9-7 9 7v11h-6v-7H9v7H3V10Z",
  search: "M17 10a7 7 0 1 1-14 0 7 7 0 0 1 14 0Zm-2 5 6 6",
  edit: "m15 4 5 5M4 20l4-1L21 6l-5-5L3 14l-1 8 6-3",
  trash: "M3 6h18M9 6V3h6v3M5 6l1 15h12l1-15M10 10v7M14 10v7",
  plus: "M12 5v14M5 12h14",
  arrow: "M5 12h14m-5-5 5 5-5 5",
  menu: "M4 6h16M4 12h16M4 18h16",
  sparkles: "m12 3 2.5 6.5L21 12l-6.5 2.5L12 21l-2.5-6.5L3 12l6.5-2.5L12 3Z",
};

export function MenuIcon({ name }: { name: keyof typeof menuIconPaths }) {
  return <svg className={`menu-icon${name === "check" ? " menu-check" : ""}`} width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
    <path d={menuIconPaths[name]} />
  </svg>;
}

function SignOutButton() {
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string>();
  async function signOut() {
    setPending(true);
    setError(undefined);
    try {
      await json("/api/auth/sign-out", { method: "POST", body: "{}" });
      window.location.replace("/sign-in");
    } catch {
      setError(uiText("Could not sign out. Please try again.", "サインアウトできませんでした。再試行してください。"));
      setPending(false);
    }
  }
  return <>
    <span className="nav-divider" />
    <button disabled={pending} onClick={() => void signOut()}><MenuIcon name="signOut" />{pending ? uiText("Signing out…", "サインアウト中…") : uiText("Sign out", "サインアウト")}</button>
    {error && <p className="sidebar-status" role="alert">{error}</p>}
  </>;
}

export function Sidebar({ brand, session, children, serverLinks, routeWorkspaceId: resolvedWorkspaceId }: { brand: ReactNode; session: SessionInfo; children: ReactNode; serverLinks?: ReactNode; routeWorkspaceId?: string }) {
  const state = useSidebar();
  const identity = session.user.name || session.user.email || session.user.id;
  const current = state.organizationId
    ? state.organizations?.find(({ id }) => id === state.organizationId)?.name ?? "Organization"
    : uiText("All accessible Workspaces", "アクセス可能なすべてのワークスペース");
  const routeWorkspaceId = resolvedWorkspaceId ?? (typeof window === "undefined" ? undefined : window.location.pathname.match(/^\/workspaces\/([^/]+)/)?.[1]);
  const selectionKey = `dahlia:sidebar:${session.user.id}:${state.organizationId || "personal"}:workspace`;
  const routedWorkspace = useLiveJSON<SyncedWorkspaceInfo>(resolvedWorkspaceId ? apiQuery("getWorkspace", { params: { path: { workspaceId: resolvedWorkspaceId } } }) : undefined);
  const selectedWorkspace = selectedSidebarWorkspace(state.workspaces, routeWorkspaceId, readSelection(selectionKey)) ?? routedWorkspace.data;
  const selectedWorkspaceId = selectedWorkspace?.workspaceId;
  const selectableWorkspaces = selectedWorkspace && !state.workspaces?.some((workspace) => workspace.workspaceId === selectedWorkspaceId)
    ? [selectedWorkspace, ...(state.workspaces ?? [])] : state.workspaces ?? [];
  useEffect(() => {
    if (selectedWorkspaceId) save(selectionKey, selectedWorkspaceId);
  }, [selectionKey, selectedWorkspaceId]);
  return <aside className="sidebar">
    <div className="sidebar-brand">{brand}</div>
    <nav className="primary-navigation" aria-label={uiText("Library navigation", "ライブラリ")}>
      <Tooltip label={uiText("Home", "ホーム")}><a href="/dashboard" aria-label={uiText("Home", "ホーム")} aria-current={typeof window !== "undefined" && window.location.pathname === "/dashboard" ? "page" : undefined}><MenuIcon name="home" /><span className="navigation-label">{uiText("Home", "ホーム")}</span></a></Tooltip>
      {session.capabilities.sync && <Tooltip label={uiText("Workspaces", "ワークスペース")}><a href="/workspaces" aria-label={uiText("Workspaces", "ワークスペース")} aria-current={typeof window !== "undefined" && window.location.pathname === "/workspaces" ? "page" : undefined}><MenuIcon name="workspace" /><span className="navigation-label">{uiText("Workspaces", "ワークスペース")}</span></a></Tooltip>}
      {session.capabilities.sync && selectedWorkspaceId && <Search key={`${selectionKey}:${selectedWorkspaceId}`} workspaceId={selectedWorkspaceId} />}
    </nav>
    {session.capabilities.sync && selectedWorkspace && <div className="workspace-switcher">
      <span>{uiText("Current Workspace", "現在のワークスペース")}</span>
      <button className="dropdown-trigger workspace-switcher-trigger" popoverTarget="workspace-menu" aria-label={uiText(`Current Workspace: ${selectedWorkspace.name}`, `現在のワークスペース: ${selectedWorkspace.name}`)}>
        <AppearanceIcon appearance={collectionAppearance(selectedWorkspace, "workspace")} /><span>{selectedWorkspace.name}</span><Chevron expanded />
      </button>
      <nav id="workspace-menu" popover="auto" className="dropdown-menu workspace-picker" aria-label={uiText("Choose a Workspace", "ワークスペースを選択")}>
        <strong>{uiText("Workspaces", "ワークスペース")}</strong>
        {selectableWorkspaces.map((workspace) => <a className="dropdown-option" key={workspace.workspaceId} href={`/workspaces/${workspace.workspaceId}`} aria-current={selectedWorkspaceId === workspace.workspaceId ? "true" : undefined}>
          <AppearanceIcon appearance={collectionAppearance(workspace, "workspace")} /><span>{workspace.name}</span>{selectedWorkspaceId === workspace.workspaceId && <MenuIcon name="check" />}
        </a>)}
      </nav>
    </div>}
    <div className="sidebar-scroll">
      {session.capabilities.sync && <nav className="workspace-navigation" aria-label={uiText("Project navigation", "プロジェクト")}>
        <h2 className="workspace-heading">{uiText("Projects", "プロジェクト")}</h2>
        {state.error && <Failure message={state.error} retry={state.reload} />}
        {!state.workspaces && !state.error && <p className="sidebar-status">{state.organizationError ? uiText("Clear the organization selection or retry loading organizations.", "組織の選択を解除するか、組織の読み込みを再試行してください。") : "Loading Workspaces…"}</p>}
        {state.workspaces?.length === 0 && <p className="sidebar-status">{uiText("No Workspaces", "ワークスペースがありません")}</p>}
        {selectedWorkspace && <WorkspaceChildren key={`${state.organizationId}:${selectedWorkspace.workspaceId}`} workspaceId={selectedWorkspace.workspaceId} />}
        {Boolean(state.workspaces?.length) && !selectedWorkspace && <p className="sidebar-status">{uiText("Choose a Workspace from Workspaces", "ワークスペースから表示するワークスペースを選択してください")}</p>}
      </nav>}
      {session.capabilities.admin ? <nav className="server-navigation" aria-label={uiText("Server settings", "サーバー設定")}>
        <h2 className="section-label">{uiText("Server settings", "サーバー設定")}</h2>
        {([["/admin/organizations", "organization", uiText("Organizations", "組織管理")],
          ["/admin/users", "members", uiText("Users", "ユーザー管理")],
          ["/admin/settings", "settings", uiText("General settings", "全体設定")]] as const).map(([href, icon, label]) =>
          <a key={href} href={href} aria-current={typeof window !== "undefined" && window.location.pathname === href ? "page" : undefined}><MenuIcon name={icon} /><span>{label}</span></a>)}
        {serverLinks}
      </nav> : session.capabilities.sharing && <nav className="server-navigation" aria-label={uiText("Organization settings", "組織設定")}>
        <a href="/organizations" aria-current={typeof window !== "undefined" && (window.location.pathname === "/organizations" || window.location.pathname.startsWith("/organizations/")) ? "page" : undefined}><MenuIcon name="organization" /><span>{uiText("Organization settings", "組織設定")}</span></a>
      </nav>}
    </div>
    <div className="sidebar-footer">
      <button className="organization-switcher" popoverTarget="account-menu" aria-label={uiText(`Account menu: ${identity}`, `アカウントメニュー: ${identity}`)}>
        <MenuIcon name="account" />
        <span className="identity-copy"><strong>{identity}</strong><small>{current}</small></span>
        <svg className="account-menu-chevron" width="16" height="20" viewBox="0 0 16 20" aria-hidden="true">
          <path d="m5 6 3-3 3 3M5 14l3 3 3-3" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
      </button>
      <div id="account-menu" popover="auto" className="organization-picker">
        <a className="menu-account" href="/dashboard"><MenuIcon name="account" /><span>{identity}</span></a>
        {session.capabilities.sharing && <>
          <span className="nav-divider" />
          <strong>{uiText("Organizations", "組織")}</strong>
          <button onClick={() => state.select("")} aria-pressed={!state.organizationId}><MenuIcon name="account" /><span>{uiText("All accessible Workspaces", "アクセス可能なすべてのワークスペース")}</span>{!state.organizationId && <MenuIcon name="check" />}</button>
          {state.organizations?.map((organization) => <button key={organization.id} onClick={() => state.select(organization.id)} aria-pressed={state.organizationId === organization.id}>
            <MenuIcon name="organization" /><span>{organization.name}</span>{state.organizationId === organization.id && <MenuIcon name="check" />}
          </button>)}
          {!state.organizations && !state.organizationError && <p className="sidebar-status">{uiText("Loading organizations…", "組織を読み込み中…")}</p>}
          {state.organizationError && <Failure message={state.organizationError} retry={state.reload} />}
          <a href="/organizations" aria-current={typeof window !== "undefined" && (window.location.pathname === "/organizations" || window.location.pathname.startsWith("/organizations/")) ? "page" : undefined}><MenuIcon name="organization" /><span>{uiText("Your organizations", "所属組織一覧")}</span><MenuIcon name="arrow" /></a>
        </>}
        <span className="nav-divider" />
        {children}
        {session.capabilities.sessions && <SignOutButton />}
      </div>
    </div>
  </aside>;
}

function TreeNode({ id, name, href, initialOpen, children, appearance, project }: { project?: SyncedProjectInfo; id: string; name: string; href?: string; initialOpen: boolean; children: ReactNode; appearance?: Appearance | null }) {
  const { userId, organizationId } = useSidebar();
  const key = `dahlia:sidebar:${userId}:${organizationId || "personal"}:${id}`;
  const [open, setOpen] = useState(() => initialOpen || readSelection(key) === "true");
  const route = window.location.pathname;
  const active = route === href;
  useEffect(() => {
    if (initialOpen) setOpen(true);
  }, [initialOpen, route]);
  const toggle = () => {
    setOpen(!open);
    save(key, String(!open));
  };
  const row = (describedBy?: string) => <div className={`tree-row${active ? " active" : ""}`}>
      <button className="tree-toggle" aria-label={`${open ? uiText("Collapse", "閉じる") : uiText("Expand", "展開")} ${name}`} aria-expanded={open} onClick={toggle}><Chevron expanded={open} /></button>
      <AppearanceIcon appearance={appearance ?? { icon: "folder", color: "neutral" }} />
      {href ? <a href={href} aria-describedby={describedBy} aria-current={active ? "page" : undefined}>{name}</a>
        : <button className="tree-group" aria-expanded={open} onClick={toggle}>{name}</button>}
    </div>;
  return <li>
    {project ? <HoverPreview details={<>
      <div className="meeting-preview-project"><AppearanceIcon appearance={appearance ?? { icon: "folder", color: "neutral" }} /><strong>{project.name}</strong></div>
      <p>{uiText(`${project.subtreeMeetingCount ?? project.directMeetingCount ?? 0} meetings`, `${project.subtreeMeetingCount ?? project.directMeetingCount ?? 0}件のミーティング`)}</p>
      {project.description && <p>{project.description}</p>}
    </>}>{row}</HoverPreview> : row()}
    {open && children}
  </li>;
}

function WorkspaceChildren({ workspaceId }: { workspaceId: string }) {
  const route = window.location.pathname;
  const meetingId = route.match(/^\/meetings\/([^/]+)$/)?.[1];
  const projectId = route.match(/^\/projects\/([^/]+)$/)?.[1];
  const projectsQuery = useLiveJSON<{ items: SyncedProjectInfo[] }>(apiQuery("listProjects", { params: { path: { workspaceId: workspaceId } } }));
  const meetingQuery = useLiveJSON<SyncedMeetingInfo>(meetingId ? apiQuery("getMeeting", { params: { path: { meetingId: meetingId } } }) : undefined);
  const projects = projectsQuery.data?.items;
  const selectedMeeting = meetingQuery.data;
  if (!projects) return projectsQuery.error
    ? <Failure message={projectsQuery.error.message} retry={projectsQuery.reload} />
    : <p className="sidebar-status">{uiText("Loading Projects…", "プロジェクトを読み込み中…")}</p>;
  const ancestors = projectAncestors(projects, projectId ?? selectedMeeting?.projectId ?? undefined);
  const childrenByParent = new Map<string | undefined, SyncedProjectInfo[]>();
  for (const project of projects) {
    const parent = project.parentProjectId ?? undefined;
    const siblings = childrenByParent.get(parent) ?? [];
    siblings.push(project);
    childrenByParent.set(parent, siblings);
  }
  const projectsUnder = (parentId?: string): ReactNode => (childrenByParent.get(parentId) ?? []).map((project) => {
    const appearance = projectAppearance(project, projects.find((parent) => parent.projectId === project.parentProjectId));
    return <TreeNode project={project} key={project.projectId} id={`${workspaceId}:${project.projectId}`} name={project.name} appearance={appearance} href={`/projects/${project.projectId}`} initialOpen={ancestors.has(project.projectId)}>
      <ul className="sidebar-tree">
        {projectsUnder(project.projectId)}
        <Meetings workspaceId={workspaceId} projectId={project.projectId} projectName={project.name} appearance={appearance} selectedMeeting={selectedMeeting} />
      </ul>
    </TreeNode>;
  });
  return <>
    {projectsQuery.error && <Failure message={projectsQuery.error.message} retry={projectsQuery.reload} />}
    {meetingQuery.error && <Failure message={meetingQuery.error.message} retry={meetingQuery.reload} />}
    <ul className="sidebar-tree">
      {projectsUnder()}
    </ul>
    <section className="unassigned-meetings" aria-labelledby="unassigned-heading">
      <h2 id="unassigned-heading" className="workspace-heading">{uiText("Unassigned", "未分類")}</h2>
      <ul className="sidebar-tree"><Meetings workspaceId={workspaceId} selectedMeeting={selectedMeeting} /></ul>
    </section>
  </>;
}

function Meetings({ workspaceId, projectId, projectName, appearance, selectedMeeting }: { workspaceId: string; projectId?: string; projectName?: string; appearance?: Appearance; selectedMeeting?: SyncedMeetingInfo }) {
  const filters = projectId ? { projectId, projectScope: "direct" as const } : { projectScope: "unassigned" as const };
  const query = useLivePage<SyncedMeetingInfo>(apiQuery("listMeetings", { params: { path: { workspaceId }, query: filters } }));
  const items = query.data?.items ?? [];
  const nextCursor = query.data?.nextCursor;
  const loading = query.loading;
  const error = query.error?.message;
  let visibleMeetings = items;
  if (selectedMeeting
    && (selectedMeeting.projectId ?? undefined) === projectId
    && !items.some(({ meetingId }) => meetingId === selectedMeeting.meetingId)) {
    visibleMeetings = [selectedMeeting, ...items];
  }
  return <>
    {visibleMeetings.map((meeting) => {
      const href = `/meetings/${meeting.meetingId}`;
      const active = window.location.pathname === href;
      const meetingDate = meeting.recordingStartedAt ?? meeting.createdAt;
      return <MeetingHoverCard key={meeting.meetingId} meeting={meeting} projectName={projectName} appearance={appearance} active={active}>
          <span>{meeting.name || uiText("Untitled meeting", "無題のミーティング")}</span>
          <RecordingIndicator isRecording={meeting.isRecording} />
          <time dateTime={meetingDate}>{new Date(meetingDate).toLocaleString(undefined, { year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit" })}</time>
      </MeetingHoverCard>;
    })}
    {loading && !query.data && <li className="sidebar-status">{uiText("Loading meetings…", "ミーティングを読み込み中…")}</li>}
    {error && <li><Failure message={error} retry={query.reload} /></li>}
    {query.data && !error && visibleMeetings.length === 0 && <li className="sidebar-status">{uiText("No meetings", "ミーティングがありません")}</li>}
    {nextCursor && <li><button className="sidebar-action" disabled={query.loadingMore} onClick={query.loadMore}>{uiText("Show more", "さらに表示")}</button></li>}
  </>;
}
