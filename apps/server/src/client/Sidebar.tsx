import { apiQuery } from "./live-data";
import { isChatPath } from "./routes";
import { collectionAppearance, AppearanceIcon, projectAppearance, type Appearance } from "./AppearancePicker";
import { MeetingHoverCard, HoverPreview, HoverPreviewProvider } from "./MeetingHoverCard";
import { Tooltip } from "./Tooltip";
import { Search } from "./Search";
import { RecordingIndicator } from "./RecordingIndicator";
import { MCPConnectionDialog } from "./MCPConnectionDialog";
import { useLiveJSON, useLivePage } from "./live-data";
import { createContext, useContext, useEffect, useRef, useState, type ReactNode } from "react";
import type { SessionInfo } from "./App";
import type { OrganizationInfo, SyncedMeetingInfo, SyncedProjectInfo, SyncedWorkspaceInfo } from "./api";
import { json, uiText } from "./api";
import { ArrowRight, Blocks, Building2, Check, ChevronRight, FileText, Folder, Home, Link, LogOut, Menu, MessageCircle, Pencil, Plus, Search as SearchIcon, Settings2, Sparkles, Trash2, User, Users, type LucideIcon } from "lucide-react";
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuSeparator, DropdownMenuTrigger } from "./components/ui/dropdown-menu";


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

function preferredOrganizationWorkspace(workspaces: SyncedWorkspaceInfo[], savedWorkspaceId: string, userId: string): SyncedWorkspaceInfo | undefined {
  return workspaces.find((workspace) => workspace.workspaceId === savedWorkspaceId)
    ?? workspaces.find((workspace) => workspace.personalUserId === userId)
    ?? workspaces[0];
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
  organizations?: OrganizationInfo[];
  workspaces?: SyncedWorkspaceInfo[];
  error?: string;
  reload: () => void;
  chatHistoryTarget?: HTMLElement | null;
  setChatHistoryTarget?: (target: HTMLElement | null) => void;
}
const SidebarContext = createContext<SidebarState | null>(null);

export function useSidebar() {
  const value = useContext(SidebarContext);
  if (!value) throw new Error("SidebarProvider is required");
  return value;
}

export function SidebarProvider({ session, children }: { session: SessionInfo; children: ReactNode }) {
  const [chatHistoryTarget, setChatHistoryTarget] = useState<HTMLElement | null>(null);
  const organizationsQuery = useLiveJSON<OrganizationInfo[]>(!session.capabilities.sharing ? undefined
    : "/api/auth/organization/list");
  const workspacesQuery = useLiveJSON<{ items: SyncedWorkspaceInfo[] }>(session.capabilities.sync
    ? apiQuery("listWorkspaces", {}) : undefined);
  const reload = () => { organizationsQuery.reload(); workspacesQuery.reload(); };
  return <SidebarContext.Provider value={{ userId: session.user.id, organizations: organizationsQuery.data,
    workspaces: workspacesQuery.data?.items, error: workspacesQuery.error?.message, reload,
    chatHistoryTarget, setChatHistoryTarget }}>
    {children}
  </SidebarContext.Provider>;
}

function Chevron({ expanded }: { expanded: boolean }) {
  return <ChevronRight className={`size-4 transition-transform motion-reduce:transition-none${expanded ? " rotate-90" : ""}`} strokeWidth={1.75} aria-hidden="true" />;
}

function Failure({ message, retry }: { message: string; retry: () => void }) {
  return <div className="px-2 py-1 text-xs text-muted-foreground" role="alert">{message} <button className="text-primary hover:underline" onClick={retry}>{uiText("Retry", "再試行")}</button></div>;
}

const menuIcons = { folder: Folder, account: User, workspace: Blocks, organization: Building2, settings: Settings2,
  document: FileText, members: Users, signOut: LogOut, check: Check, home: Home, search: SearchIcon, edit: Pencil,
  trash: Trash2, plus: Plus, arrow: ArrowRight, menu: Menu, chat: MessageCircle, sparkles: Sparkles, link: Link } satisfies Record<string, LucideIcon>;

export function MenuIcon({ name }: { name: keyof typeof menuIcons }) {
  const Icon = menuIcons[name];
  return <Icon className={name === "check" ? "ml-auto size-4 text-primary" : "size-4 shrink-0"} strokeWidth={1.6} aria-hidden="true" />;
}

function SignOutButton() {
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string>();
  async function signOut() {
    setPending(true);
    setError(undefined);
    try {
      await json("/api/auth/sign-out", { method: "POST", body: "{}" });
      window.location.replace("/sign-out");
    } catch {
      setError(uiText("Could not sign out. Please try again.", "サインアウトできませんでした。再試行してください。"));
      setPending(false);
    }
  }
  return <>
    <DropdownMenuSeparator />
    <DropdownMenuItem disabled={pending} onSelect={() => void signOut()}><MenuIcon name="signOut" />{pending ? uiText("Signing out…", "サインアウト中…") : uiText("Sign out", "サインアウト")}</DropdownMenuItem>
    {error && <p className="px-2 py-1 text-xs text-destructive" role="alert">{error}</p>}
  </>;
}

export function Sidebar({ brand, session, children, serverLinks, routeWorkspaceId: resolvedWorkspaceId, routeMeeting, routeMeetingOwned }: { brand: ReactNode; session: SessionInfo; children: ReactNode; serverLinks?: ReactNode; routeWorkspaceId?: string; routeMeeting?: SyncedMeetingInfo; routeMeetingOwned?: boolean }) {
  const state = useSidebar();
  const accountMenuTrigger = useRef<HTMLButtonElement>(null);
  const [mcpDialogOpen, setMcpDialogOpen] = useState(false);
  const identity = session.user.name || session.user.email || session.user.id;
  const routeWorkspaceId = resolvedWorkspaceId ?? (typeof window === "undefined" ? undefined : window.location.pathname.match(/^\/workspaces\/([^/]+)/)?.[1]);
  const selectionKey = `dahlia:sidebar:${session.user.id}:workspace`;
  const routedWorkspace = useLiveJSON<SyncedWorkspaceInfo>(resolvedWorkspaceId ? apiQuery("getWorkspace", { params: { path: { workspaceId: resolvedWorkspaceId } } }) : undefined);
  const selectionOrgKey = `dahlia:sidebar:${session.user.id}:organization`;
  const routeWorkspace = state.workspaces?.find((workspace) => workspace.workspaceId === routeWorkspaceId) ?? routedWorkspace.data;
  const routeOrganizationId = typeof window === "undefined" ? undefined : window.location.pathname.match(/^\/orgs\/([^/]+)/)?.[1];
  const savedOrganizationId = readSelection(selectionOrgKey);
  const selectedOrganizationId = routeWorkspace?.organizationId ?? routeOrganizationId
    ?? state.organizations?.find(({ id }) => id === savedOrganizationId)?.id ?? state.organizations?.[0]?.id;
  const selectedOrganization = state.organizations?.find(({ id }) => id === selectedOrganizationId);
  const organizationWorkspaces = selectedOrganization
    ? (state.workspaces ?? []).filter((workspace) => workspace.organizationId === selectedOrganizationId)
    : [];
  const savedWorkspaceId = readSelection(`${selectionKey}:${selectedOrganizationId}`);
  const selectedWorkspace = routeWorkspace ?? (routeWorkspaceId ? undefined :
    preferredOrganizationWorkspace(organizationWorkspaces, savedWorkspaceId, state.userId));
  const selectedWorkspaceId = selectedWorkspace?.workspaceId;
  const externalWorkspaces = (state.workspaces ?? []).filter((workspace) => !state.organizations?.some(({ id }) => id === workspace.organizationId));
  function organizationHref(organizationId: string) {
    const workspaces = (state.workspaces ?? []).filter((workspace) => workspace.organizationId === organizationId);
    const savedId = readSelection(`${selectionKey}:${organizationId}`);
    const workspace = preferredOrganizationWorkspace(workspaces, savedId, state.userId);
    return workspace ? `/workspaces/${workspace.workspaceId}` : `/orgs/${organizationId}`;
  }
  const currentPath = typeof window === "undefined" ? "" : window.location.pathname;
  const homeActive = currentPath === "/dashboard";
  const aiActive = isChatPath(currentPath);
  const workspacesActive = currentPath === "/workspaces";
  useEffect(() => {
    if (selectedOrganizationId) save(selectionOrgKey, selectedOrganizationId);
    if (selectedWorkspaceId && selectedOrganizationId) save(`${selectionKey}:${selectedOrganizationId}`, selectedWorkspaceId);
  }, [selectionKey, selectionOrgKey, selectedOrganizationId, selectedWorkspaceId]);
  return <aside className="sidebar flex h-dvh min-w-0 flex-col gap-2 border-r bg-secondary p-3">
    <div className="sidebar-brand flex h-9 items-center px-2">{brand}</div>
    {session.capabilities.sharing && <DropdownMenu>
      <DropdownMenuTrigger asChild><button className="flex h-9 w-full items-center gap-2 rounded-md px-2 text-sm font-medium hover:bg-accent focus-visible:ring-2 focus-visible:ring-ring" aria-label={uiText("Switch organization", "組織を切り替え")}>
        <MenuIcon name="organization" /><span className="min-w-0 flex-1 truncate text-left">{selectedOrganization?.name ?? routeWorkspace?.organizationName ?? uiText("Choose an organization", "組織を選択")}</span><Chevron expanded={false} />
      </button></DropdownMenuTrigger>
      <DropdownMenuContent align="start" className="w-58">
        {state.organizations?.map((organization) => <DropdownMenuItem asChild key={organization.id}><a href={organizationHref(organization.id)}>
          <MenuIcon name="organization" /><span className="min-w-0 flex-1 truncate">{organization.name}</span>{organization.id === selectedOrganizationId && <MenuIcon name="check" />}
        </a></DropdownMenuItem>)}
        <DropdownMenuSeparator /><DropdownMenuItem asChild><a href="/orgs">{uiText("Join or manage organizations", "組織への参加・管理")}</a></DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>}
    <nav className="primary-navigation flex items-center gap-1 px-1" aria-label={uiText("Library navigation", "ライブラリ")}>
      <Tooltip label={uiText("Home", "ホーム")}><a className={`flex h-8 min-w-0 items-center gap-1.5 whitespace-nowrap rounded-full px-2.5 text-muted-foreground hover:bg-accent hover:text-foreground${homeActive ? " bg-accent pr-3 text-foreground" : " w-8 shrink-0 justify-center"}`} href="/dashboard" aria-label={uiText("Home", "ホーム")} aria-current={homeActive ? "page" : undefined}><MenuIcon name="home" /><span className={homeActive ? "truncate text-xs font-medium" : "sr-only"}>{uiText("Home", "ホーム")}</span></a></Tooltip>
      <a href="/memory" className="text-xs text-muted-foreground hover:text-foreground">Dahlia Memory</a>
      {session.capabilities.ai && <Tooltip label={uiText("Chat with Dahlia AI", "Dahlia AI とチャット")}><a className={`flex h-8 min-w-0 items-center gap-1.5 whitespace-nowrap rounded-full px-2.5 text-muted-foreground hover:bg-accent hover:text-foreground${aiActive ? " bg-accent pr-3 text-foreground" : " w-8 shrink-0 justify-center"}`} href="/chat" aria-label={uiText("Chat with Dahlia AI", "Dahlia AI とチャット")} aria-current={aiActive ? "page" : undefined}><MenuIcon name="chat" /><span className={aiActive ? "truncate text-xs font-medium" : "sr-only"}>{uiText("Chat", "チャット")}</span></a></Tooltip>}
      {session.capabilities.sync && <Tooltip label={uiText("Workspaces", "ワークスペース")}><a className={`flex h-8 min-w-0 items-center gap-1.5 whitespace-nowrap rounded-full px-2.5 text-muted-foreground hover:bg-accent hover:text-foreground${workspacesActive ? " bg-accent pr-3 text-foreground" : " w-8 shrink-0 justify-center"}`} href="/workspaces" aria-label={uiText("Workspaces", "ワークスペース")} aria-current={workspacesActive ? "page" : undefined}><MenuIcon name="workspace" /><span className={workspacesActive ? "truncate text-xs font-medium" : "sr-only"}>{uiText("Workspaces", "ワークスペース")}</span></a></Tooltip>}
      {!aiActive && session.capabilities.sync && selectedWorkspaceId && <Search key={`${selectionKey}:${selectedWorkspaceId}`} workspaceId={selectedWorkspaceId} />}
    </nav>
    <div className="sidebar-scroll flex min-h-0 flex-1 flex-col overflow-y-auto">
      {aiActive && <div className="flex min-h-0 flex-1 flex-col pt-2" ref={state.setChatHistoryTarget} />}
      {session.capabilities.sync && <nav className="workspace-navigation mt-2" aria-label={uiText("Project navigation", "プロジェクト")}>
        {state.error && <Failure message={state.error} retry={state.reload} />}
        {!state.workspaces && !state.error && <p className="px-2 py-1 text-xs text-muted-foreground">{uiText("Loading Workspaces…", "読み込み中…")}</p>}
        {state.organizations?.length === 0 && <p className="px-2 py-2 text-xs text-muted-foreground">{uiText("Join an organization or wait for an invitation.", "組織に参加するか、招待をお待ちください。")} <a className="text-primary underline" href={session.capabilities.admin ? "/admin/orgs" : "/orgs"}>{uiText("Organizations", "組織")}</a></p>}
        <HoverPreviewProvider>
          {organizationWorkspaces.filter((workspace) => workspace.personalUserId === state.userId).map((workspace) => <SidebarWorkspace key={workspace.workspaceId} workspace={workspace} personal selected={workspace.workspaceId === selectedWorkspaceId} routeMeeting={routeMeeting} routeMeetingOwned={routeMeetingOwned} />)}
          <h2 className="px-2 py-1 text-[11px] font-semibold text-muted-foreground">{uiText("Workspaces", "ワークスペース")}</h2>
          {organizationWorkspaces.filter((workspace) => workspace.personalUserId == null).map((workspace) => <SidebarWorkspace key={workspace.workspaceId} workspace={workspace} selected={workspace.workspaceId === selectedWorkspaceId} routeMeeting={routeMeeting} routeMeetingOwned={routeMeetingOwned} />)}
          {externalWorkspaces.length > 0 && <>
            <h2 className="px-2 pt-4 pb-1 text-[11px] font-semibold text-muted-foreground">{uiText("Shared from other organizations", "他の組織からの共有")}</h2>
            {externalWorkspaces.map((workspace) => <SidebarWorkspace key={workspace.workspaceId} workspace={workspace} selected={workspace.workspaceId === selectedWorkspaceId} routeMeeting={routeMeeting} routeMeetingOwned={routeMeetingOwned} />)}
          </>}
        </HoverPreviewProvider>
      </nav>}
      {session.capabilities.admin ? <nav className="server-navigation mt-auto grid gap-0.5 pt-6" aria-label={uiText("Server settings", "サーバー設定")}>
        <h2 className="px-2 py-1 text-[11px] font-semibold text-muted-foreground">{uiText("Server settings", "サーバー設定")}</h2>
        {([["/admin/orgs", "organization", uiText("Organizations", "組織管理")],
          ["/admin/users", "members", uiText("Users", "ユーザー管理")],
          ["/admin/settings", "settings", uiText("General settings", "全体設定")]] as const).map(([href, icon, label]) =>
          <a className="flex items-center gap-2 rounded-md px-2 py-1.5 text-xs text-muted-foreground hover:bg-accent hover:text-foreground aria-[current=page]:bg-accent aria-[current=page]:text-foreground" key={href} href={href} aria-current={typeof window !== "undefined" && window.location.pathname === href ? "page" : undefined}><MenuIcon name={icon} /><span>{label}</span></a>)}
        {serverLinks}
      </nav> : session.capabilities.sharing && <nav className="server-navigation mt-auto grid gap-0.5 pt-6" aria-label={uiText("Organization settings", "組織設定")}>
        <a className="flex items-center gap-2 rounded-md px-2 py-1.5 text-xs text-muted-foreground hover:bg-accent hover:text-foreground aria-[current=page]:bg-accent" href="/orgs" aria-current={typeof window !== "undefined" && (window.location.pathname === "/orgs" || window.location.pathname.startsWith("/orgs/")) ? "page" : undefined}><MenuIcon name="organization" /><span>{uiText("Organization settings", "組織設定")}</span></a>
      </nav>}
    </div>
    <div className="sidebar-footer mt-auto border-t pt-2">
      <DropdownMenu>
      <DropdownMenuTrigger asChild><button ref={accountMenuTrigger} className="flex h-9 w-full items-center gap-2 rounded-md px-2 text-sm outline-none hover:bg-accent focus-visible:ring-2 focus-visible:ring-ring" aria-label={uiText(`Account menu: ${identity}`, `アカウントメニュー: ${identity}`)}>
        <MenuIcon name="account" />
        <span className="min-w-0 flex-1 truncate text-left font-medium">{identity}</span>
        <svg className="account-menu-chevron" width="16" height="20" viewBox="0 0 16 20" aria-hidden="true">
          <path d="m5 6 3-3 3 3M5 14l3 3 3-3" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
      </button></DropdownMenuTrigger>
      <DropdownMenuContent side="top" align="start" className="w-60">
        <DropdownMenuItem asChild><a href="/dashboard"><MenuIcon name="account" /><span>{identity}</span></a></DropdownMenuItem>
        {session.capabilities.sharing && <>
          <DropdownMenuSeparator />
          <DropdownMenuItem asChild><a href="/orgs" aria-current={typeof window !== "undefined" && (window.location.pathname === "/orgs" || window.location.pathname.startsWith("/orgs/")) ? "page" : undefined}><MenuIcon name="organization" /><span>{uiText("Organizations you belong to", "参加している組織")}</span></a></DropdownMenuItem>
        </>}
        <DropdownMenuSeparator />
        {children}
        <DropdownMenuItem onSelect={() => { accountMenuTrigger.current?.focus(); setMcpDialogOpen(true); }}>
          <MenuIcon name="document" />{uiText("Connect with MCP", "MCP による接続")}
        </DropdownMenuItem>
        {session.capabilities.sessions && <SignOutButton />}
      </DropdownMenuContent>
      </DropdownMenu>
      {mcpDialogOpen && <MCPConnectionDialog onClose={() => {
        setMcpDialogOpen(false);
        requestAnimationFrame(() => accountMenuTrigger.current?.focus());
      }} />}
    </div>
  </aside>;
}

function TreeNode({ id, name, href, initialOpen, children, appearance, project }: { project?: SyncedProjectInfo; id: string; name: string; href?: string; initialOpen: boolean; children: ReactNode; appearance?: Appearance | null }) {
  const { userId } = useSidebar();
  const key = `dahlia:sidebar:${userId}:${id}`;
  const [open, setOpen] = useState(() => initialOpen || readSelection(key) === "true");
  const route = typeof window === "undefined" ? "" : window.location.pathname;
  const active = route === href;
  useEffect(() => {
    if (initialOpen) setOpen(true);
  }, [initialOpen, route]);
  const toggle = () => {
    setOpen(!open);
    save(key, String(!open));
  };
  const row = (describedBy?: string) => <div className={`flex min-w-0 items-center rounded-md hover:bg-accent/70${active ? " bg-accent text-accent-foreground" : ""}`}>
      <button className="grid size-7 shrink-0 place-items-center rounded-md text-muted-foreground outline-none hover:bg-accent focus-visible:ring-2 focus-visible:ring-ring" aria-label={`${open ? uiText("Collapse", "閉じる") : uiText("Expand", "展開")} ${name}`} aria-expanded={open} onClick={toggle}><Chevron expanded={open} /></button>
      <AppearanceIcon appearance={appearance ?? { icon: "folder", color: "neutral" }} />
      {href ? <a className="min-w-0 flex-1 truncate px-2 py-1.5 text-xs" href={href} aria-describedby={describedBy} aria-current={active ? "page" : undefined}>{name}</a>
        : <button className="min-w-0 flex-1 truncate px-2 py-1.5 text-left text-xs" aria-expanded={open} onClick={toggle}>{name}</button>}
    </div>;
  return <li>
    {project ? <HoverPreview details={<>
      <div className="flex items-center gap-2"><AppearanceIcon appearance={appearance ?? { icon: "folder", color: "neutral" }} /><strong>{project.name}</strong></div>
      <p className="mt-2 text-sm text-muted-foreground">{uiText(`${project.subtreeMeetingCount ?? project.directMeetingCount ?? 0} meetings`, `${project.subtreeMeetingCount ?? project.directMeetingCount ?? 0}件のミーティング`)}</p>
      {project.description && <p className="mt-2 text-sm text-muted-foreground">{project.description}</p>}
    </>}>{row}</HoverPreview> : row()}
    {open && children}
  </li>;
}

function WorkspaceChildren({ workspaceId, resolvedMeeting, routeMeetingOwned }: { workspaceId: string; resolvedMeeting?: SyncedMeetingInfo; routeMeetingOwned?: boolean }) {
  const route = typeof window === "undefined" ? "" : window.location.pathname;
  const meetingId = route.match(/^\/meetings\/([^/]+)$/)?.[1];
  const projectId = route.match(/^\/projects\/([^/]+)$/)?.[1];
  const projectsQuery = useLiveJSON<{ items: SyncedProjectInfo[] }>(apiQuery("listProjects", { params: { path: { workspaceId: workspaceId } } }));
  const meetingQuery = useLiveJSON<SyncedMeetingInfo>(meetingId && !routeMeetingOwned && !resolvedMeeting ? apiQuery("getMeeting", { params: { path: { meetingId: meetingId } } }) : undefined);
  const projects = projectsQuery.data?.items;
  const candidateMeeting = resolvedMeeting ?? meetingQuery.data;
  const selectedMeeting = candidateMeeting?.workspaceId === workspaceId ? candidateMeeting : undefined;
  if (!projects) return projectsQuery.error
    ? <Failure message={projectsQuery.error.message} retry={projectsQuery.reload} />
    : <p className="px-2 py-1 text-xs text-muted-foreground">{uiText("Loading Projects…", "プロジェクトを読み込み中…")}</p>;
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
      <ul className="ml-3 grid list-none gap-0.5 p-0">
        {projectsUnder(project.projectId)}
        <Meetings workspaceId={workspaceId} projectId={project.projectId} projectName={project.name} appearance={appearance} selectedMeeting={selectedMeeting} />
      </ul>
    </TreeNode>;
  });
  return <>
    {projectsQuery.error && <Failure message={projectsQuery.error.message} retry={projectsQuery.reload} />}
    {meetingQuery.error && <Failure message={meetingQuery.error.message} retry={meetingQuery.reload} />}
    <ul className="grid list-none gap-0.5 p-0">
      {projectsUnder()}
    </ul>
    <section className="mt-3" aria-labelledby={`unassigned-heading-${workspaceId}`}>
      <h2 id={`unassigned-heading-${workspaceId}`} className="px-2 py-1 text-[11px] font-semibold text-muted-foreground">{uiText("Unassigned", "未分類")}</h2>
      <ul className="grid list-none gap-0.5 p-0"><Meetings workspaceId={workspaceId} selectedMeeting={selectedMeeting} /></ul>
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
          <span className="block truncate text-xs">{meeting.name || uiText("Untitled meeting", "無題のミーティング")}</span>
          <RecordingIndicator isRecording={meeting.isRecording} />
          <time className="mt-1 block text-[10px] text-muted-foreground" dateTime={meetingDate}>{new Date(meetingDate).toLocaleString(undefined, { year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit" })}</time>
      </MeetingHoverCard>;
    })}
    {loading && !query.data && <li className="px-2 py-1 text-xs text-muted-foreground">{uiText("Loading meetings…", "ミーティングを読み込み中…")}</li>}
    {error && <li><Failure message={error} retry={query.reload} /></li>}
    {query.data && !error && visibleMeetings.length === 0 && <li className="px-2 py-1 text-xs text-muted-foreground">{uiText("No meetings", "ミーティングがありません")}</li>}
    {nextCursor && <li><button className="px-2 py-1 text-xs text-primary hover:underline" disabled={query.loadingMore} onClick={query.loadMore}>{uiText("Show more", "さらに表示")}</button></li>}
  </>;
}

function SidebarWorkspace({ workspace, personal = false, selected, routeMeeting, routeMeetingOwned }: { workspace: SyncedWorkspaceInfo; personal?: boolean; selected: boolean; routeMeeting?: SyncedMeetingInfo; routeMeetingOwned?: boolean }) {
  const [expanded, setExpanded] = useState(selected);
  useEffect(() => { if (selected) setExpanded(true); }, [selected]);
  const label = personal ? uiText("Private", "自分専用") : workspace.name;
  return <div>
    <div className="flex items-center rounded-md hover:bg-accent">
      <button className="rounded p-1 focus-visible:ring-2 focus-visible:ring-ring" onClick={() => setExpanded(!expanded)} aria-expanded={expanded} aria-label={uiText(`Expand ${label}`, `${label}を展開`)}><Chevron expanded={expanded} /></button>
      <a className="flex min-w-0 flex-1 items-center gap-2 rounded px-1 py-1.5 text-sm aria-[current=page]:bg-accent" href={`/workspaces/${workspace.workspaceId}`} aria-current={selected ? "page" : undefined}>
        <AppearanceIcon appearance={collectionAppearance(workspace, "workspace")} /><span className="truncate">{label}</span>{personal && <span aria-label={uiText("Only you", "本人のみ")}>🔒</span>}
      </a>
    </div>
    {expanded && <div className="pl-3"><WorkspaceChildren workspaceId={workspace.workspaceId} resolvedMeeting={routeMeeting} routeMeetingOwned={routeMeetingOwned} /></div>}
  </div>;
}
