import { createContext, useContext, useEffect, useState, type ReactNode } from "react";
import type { SessionInfo } from "./App";
import type { OrganizationInfo, SyncedMeetingInfo, SyncedMeetingPage, SyncedProjectInfo, SyncedVaultInfo } from "./api";
import { clientMutationEvent, json, RequestError, uiText } from "./api";

export function vaultListURL(organizationId: string) {
  return organizationId ? `/api/v1/vaults?${new URLSearchParams({ organizationId })}` : "/api/v1/vaults";
}

export function projectAncestors(projects: SyncedProjectInfo[], projectId?: string): Set<string> {
  const parents = new Map(projects.map((project) => [project.projectId, project.parentProjectId]));
  const result = new Set<string>();
  while (projectId && parents.has(projectId) && !result.has(projectId)) {
    result.add(projectId);
    projectId = parents.get(projectId);
  }
  return result;
}

export function selectedSidebarVault(vaults: SyncedVaultInfo[] | undefined, routeVaultId?: string, savedVaultId?: string): SyncedVaultInfo | undefined {
  const selected = vaults?.find(({ vaultId }) => vaultId === (routeVaultId ?? savedVaultId));
  return selected ?? (routeVaultId ? undefined : vaults?.[0]);
}

function readSelection(key: string): string {
  try { return sessionStorage.getItem(key) ?? ""; }
  catch { return ""; }
}

function save(key: string, value: string) {
  try { sessionStorage.setItem(key, value); } catch { /* Browsing still works without storage. */ }
}

interface SidebarState {
  userId: string;
  organizationId: string;
  organizations?: OrganizationInfo[];
  organizationError?: string;
  vaults?: SyncedVaultInfo[];
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
  const [organizationId, setOrganizationId] = useState(() => session.capabilities.sharing ? readSelection(`dahlia:sidebar:${session.user.id}:organization`) : "");
  const [organizations, setOrganizations] = useState<OrganizationInfo[]>();
  const [organizationError, setOrganizationError] = useState<string>();
  const [vaults, setVaults] = useState<SyncedVaultInfo[]>();
  const [error, setError] = useState<string>();
  const [attempt, setAttempt] = useState(0);
  useEffect(() => {
    const refresh = () => setAttempt((value) => value + 1);
    window.addEventListener(clientMutationEvent, refresh);
    return () => window.removeEventListener(clientMutationEvent, refresh);
  }, []);
  const select = (id: string) => {
    save(`dahlia:sidebar:${session.user.id}:organization`, id);
    setVaults(undefined);
    setOrganizationId(id);
    window.location.assign("/vaults");
  };
  useEffect(() => {
    const controller = new AbortController();
    setOrganizationError(undefined);
    void (async () => {
      try {
        let items: OrganizationInfo[] = [];
        if (session.capabilities.sharing) {
          const url = session.capabilities.sessions ? "/api/auth/organization/list" : "/api/v1/organizations";
          items = await json<OrganizationInfo[]>(url, { signal: controller.signal });
        }
        if (controller.signal.aborted) return;
        setOrganizations(items);
        if (organizationId && !items.some(({ id }) => id === organizationId)) {
          save(`dahlia:sidebar:${session.user.id}:organization`, "");
          setOrganizationId("");
          setVaults(undefined);
        }
      } catch (caught) {
        if (!controller.signal.aborted) setOrganizationError(caught instanceof Error ? caught.message : "Could not load organizations");
      }
    })();
    return () => controller.abort();
  }, [session.user.id, session.capabilities.sharing, session.capabilities.sessions, organizationId, attempt]);
  useEffect(() => {
    const controller = new AbortController();
    setVaults(undefined);
    setError(undefined);
    if (!session.capabilities.sync) return;
    if (organizationId && !organizations?.some(({ id }) => id === organizationId)) return;
    void json<{ items: SyncedVaultInfo[] }>(vaultListURL(organizationId), { signal: controller.signal })
      .then(({ items }) => { if (!controller.signal.aborted) setVaults(items); })
      .catch((caught: unknown) => {
        if (controller.signal.aborted) return;
        if (organizationId && caught instanceof RequestError && caught.status === 403) {
          save(`dahlia:sidebar:${session.user.id}:organization`, "");
          setOrganizationId("");
        } else setError(caught instanceof Error ? caught.message : "Could not load Vaults");
      });
    return () => controller.abort();
  }, [session.user.id, session.capabilities.sync, organizationId, organizations, attempt]);
  const vaultError = error ?? (organizationId && !organizations ? organizationError : undefined);
  return <SidebarContext.Provider value={{ userId: session.user.id, organizationId, organizations, organizationError, vaults, error: vaultError, select, reload: () => setAttempt((value) => value + 1) }}>
    {children}
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
  account: "M16 7a4 4 0 1 1-8 0 4 4 0 0 1 8 0ZM4 21v-2a6 6 0 0 1 6-6h4a6 6 0 0 1 6 6v2Z",
  vault: "M5 5h14l3 10v4H2v-4L5 5ZM2 15h20M10 17h4",
  organization: "M4 21V3h12v18M16 9h4v12M2 21h20M8 7h4M8 11h4M8 15h4M9 21v-3h2v3",
  settings: "m10 2 4 0 1 3 3 1 3-1 2 4-2 2v3l2 2-2 4-3-1-3 1-1 3h-4l-1-3-3-1-3 1-2-4 2-2v-3L1 9l2-4 3 1 3-1 1-3ZM16 12a4 4 0 1 1-8 0 4 4 0 0 1 8 0Z",
  artifact: "M5 3h9l5 5v13H5V3ZM14 3v6h5M8 13h8M8 17h6",
  members: "M14 7a3 3 0 1 1-6 0 3 3 0 0 1 6 0ZM3 20v-3a5 5 0 0 1 5-5h6a5 5 0 0 1 5 5v3ZM18 4a3 3 0 0 1 0 6M20 13a4 4 0 0 1 3 4v3",
  signOut: "M9 4H3v16h6M8 12h14m-5-5 5 5-5 5",
  check: "m5 12 4 4L19 6",
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

export function Sidebar({ brand, session, children }: { brand: ReactNode; session: SessionInfo; children: ReactNode }) {
  const state = useSidebar();
  const identity = session.user.name || session.user.email || session.user.id;
  const current = state.organizationId
    ? state.organizations?.find(({ id }) => id === state.organizationId)?.name ?? "Organization"
    : uiText("Personal", "個人");
  const routeVaultId = typeof window === "undefined" ? undefined : window.location.pathname.match(/^\/vaults\/([^/]+)/)?.[1];
  const selectionKey = `dahlia:sidebar:${session.user.id}:${state.organizationId || "personal"}:vault`;
  const selectedVault = selectedSidebarVault(state.vaults, routeVaultId, readSelection(selectionKey));
  const selectedVaultId = selectedVault?.vaultId;
  useEffect(() => {
    if (selectedVaultId) save(selectionKey, selectedVaultId);
  }, [selectionKey, selectedVaultId]);
  return <aside className="sidebar">
    <div className="sidebar-brand">{brand}</div>
    <div className="sidebar-scroll">
      {session.capabilities.sync && <nav className="vault-navigation" aria-label={uiText("Project navigation", "プロジェクト")}>
        <h2 className="vault-heading">{uiText("Projects", "プロジェクト")}</h2>
        {state.error && <Failure message={state.error} retry={state.reload} />}
        {!state.vaults && !state.error && <p className="sidebar-status">{state.organizationError ? "Choose Personal or retry loading organizations." : "Loading Vaults…"}</p>}
        {state.vaults?.length === 0 && <p className="sidebar-status">{uiText("No Vaults", "保管庫がありません")}</p>}
        {selectedVault && <VaultChildren key={`${state.organizationId}:${selectedVault.vaultId}`} vaultId={selectedVault.vaultId} />}
        {Boolean(state.vaults?.length) && !selectedVault && <p className="sidebar-status">{uiText("Choose a Vault from the account menu", "アカウントメニューから保管庫を選択してください")}</p>}
      </nav>}
    </div>
    <div className="sidebar-footer">
      <button className="organization-switcher" popoverTarget="account-menu" aria-label={uiText(`Account menu: ${identity}`, `アカウントメニュー: ${identity}`)}>
        <MenuIcon name="account" />
        <span className="identity-copy"><strong>{identity}</strong><small>{selectedVault?.name ?? current}</small></span>
        <Chevron expanded />
      </button>
      <div id="account-menu" popover="auto" className="organization-picker">
        <a className="menu-account" href="/dashboard"><MenuIcon name="account" /><span>{identity}</span></a>
        {session.capabilities.sync && <>
          <span className="nav-divider" />
          <strong>{uiText("Vaults", "保管庫")}</strong>
          {state.error && <Failure message={state.error} retry={state.reload} />}
          {!state.vaults && !state.error && <p className="sidebar-status">{uiText("Loading Vaults…", "保管庫を読み込み中…")}</p>}
          {state.vaults?.length === 0 && <p className="sidebar-status">{uiText("No Vaults", "保管庫がありません")}</p>}
          {state.vaults?.map((vault) => <a key={vault.vaultId} href={`/vaults/${vault.vaultId}`} aria-current={selectedVaultId === vault.vaultId ? "true" : undefined}>
            <MenuIcon name="vault" /><span>{vault.name}</span>{selectedVaultId === vault.vaultId && <MenuIcon name="check" />}
          </a>)}
          <a href="/vaults"><MenuIcon name="settings" />{uiText("Manage Vaults", "保管庫を管理")}</a>
        </>}
        {(session.capabilities.sharing || session.capabilities.admin) && <>
          <span className="nav-divider" />
          <strong>{uiText("Organizations", "組織")}</strong>
          {session.capabilities.sharing && <>
            <button onClick={() => state.select("")} aria-pressed={!state.organizationId}><MenuIcon name="account" /><span>{uiText("Personal", "個人")}</span>{!state.organizationId && <MenuIcon name="check" />}</button>
            {state.organizations?.map((organization) => <button key={organization.id} onClick={() => state.select(organization.id)} aria-pressed={state.organizationId === organization.id}>
              <MenuIcon name="organization" /><span>{organization.name}</span>{state.organizationId === organization.id && <MenuIcon name="check" />}
            </button>)}
            {!state.organizations && !state.organizationError && <p className="sidebar-status">{uiText("Loading organizations…", "組織を読み込み中…")}</p>}
            {state.organizationError && <Failure message={state.organizationError} retry={state.reload} />}
            <a href="/organizations"><MenuIcon name="settings" />{uiText("Manage organizations", "組織を管理")}</a>
          </>}
          {session.capabilities.admin && <a href="/admin/members" aria-current={typeof window !== "undefined" && window.location.pathname === "/admin/members" ? "page" : undefined}><MenuIcon name="members" />{uiText("Members", "メンバー")}</a>}
        </>}
        <span className="nav-divider" />
        {children}
        {session.capabilities.sessions && <SignOutButton />}
      </div>
    </div>
  </aside>;
}

function TreeNode({ id, name, href, initialOpen, children }: { id: string; name: string; href?: string; initialOpen: boolean; children: ReactNode }) {
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
  return <li>
    <div className={`tree-row${active ? " active" : ""}`}>
      <button className="tree-toggle" aria-label={`${open ? uiText("Collapse", "閉じる") : uiText("Expand", "展開")} ${name}`} aria-expanded={open} onClick={toggle}><Chevron expanded={open} /></button>
      <svg className="folder-icon" width="18" height="18" viewBox="0 0 24 24" aria-hidden="true"><path d="M3 7V5a1 1 0 0 1 1-1h5l2 2h9a1 1 0 0 1 1 1v12a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V7Zm0 2h18" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinejoin="round" /></svg>
      {href ? <a href={href} title={name} aria-current={active ? "page" : undefined}>{name}</a>
        : <button className="tree-group" aria-expanded={open} onClick={toggle}>{name}</button>}
    </div>
    {open && children}
  </li>;
}

function VaultChildren({ vaultId }: { vaultId: string }) {
  const [projects, setProjects] = useState<SyncedProjectInfo[]>();
  const [meeting, setMeeting] = useState<SyncedMeetingInfo>();
  const [error, setError] = useState<string>();
  const [selectionError, setSelectionError] = useState<string>();
  const [attempt, setAttempt] = useState(0);
  const base = `/vaults/${vaultId}`;
  const route = window.location.pathname;
  const meetingId = route.startsWith(`${base}/meetings/`) ? route.split("/")[4] : undefined;
  const projectId = route.startsWith(`${base}/projects/`) ? route.split("/")[4] : undefined;
  const selectedMeeting = meeting?.meetingId === meetingId ? meeting : undefined;
  useEffect(() => {
    const controller = new AbortController();
    setError(undefined);
    void json<{ items: SyncedProjectInfo[] }>(`/api/v1/vaults/${vaultId}/projects`, { signal: controller.signal }).then(({ items }) => {
      if (!controller.signal.aborted) setProjects(items);
    }).catch((caught: unknown) => {
      if (!controller.signal.aborted) setError(caught instanceof Error ? caught.message : "Could not load Projects");
    });
    return () => controller.abort();
  }, [vaultId, attempt]);
  useEffect(() => {
    const controller = new AbortController();
    setSelectionError(undefined);
    if (meetingId) {
      void json<SyncedMeetingInfo>(`/api/v1/vaults/${vaultId}/meetings/${meetingId}`, { signal: controller.signal }).then((value) => {
        if (!controller.signal.aborted) setMeeting(value);
      }).catch((caught: unknown) => {
        if (!controller.signal.aborted) setSelectionError(caught instanceof Error ? caught.message : "Could not load meeting");
      });
    }
    return () => controller.abort();
  }, [vaultId, meetingId, attempt]);
  if (error) return <Failure message={error} retry={() => setAttempt((value) => value + 1)} />;
  if (!projects) return <p className="sidebar-status">{uiText("Loading Projects…", "プロジェクトを読み込み中…")}</p>;
  const ancestors = projectAncestors(projects, projectId ?? selectedMeeting?.projectId);
  const childrenByParent = new Map<string | undefined, SyncedProjectInfo[]>();
  for (const project of projects) {
    const parent = project.parentProjectId ?? undefined;
    const siblings = childrenByParent.get(parent) ?? [];
    siblings.push(project);
    childrenByParent.set(parent, siblings);
  }
  const projectsUnder = (parentId?: string): ReactNode => (childrenByParent.get(parentId) ?? []).map((project) =>
    <TreeNode key={project.projectId} id={`${vaultId}:${project.projectId}`} name={project.name} href={`${base}/projects/${project.projectId}`} initialOpen={ancestors.has(project.projectId)}>
      <ul className="sidebar-tree">
        {projectsUnder(project.projectId)}
        <Meetings vaultId={vaultId} projectId={project.projectId} selectedMeeting={selectedMeeting} />
      </ul>
    </TreeNode>);
  return <>
    {selectionError && <Failure message={selectionError} retry={() => setAttempt((value) => value + 1)} />}
    <ul className="sidebar-tree">
      {projectsUnder()}
      <TreeNode id={`${vaultId}:unassigned`} name={uiText("Unassigned", "未分類")}
        initialOpen={route === base || Boolean(selectedMeeting && !selectedMeeting.projectId)}>
        <ul className="sidebar-tree"><Meetings vaultId={vaultId} selectedMeeting={selectedMeeting} /></ul>
      </TreeNode>
    </ul>
  </>;
}

function Meetings({ vaultId, projectId, selectedMeeting }: { vaultId: string; projectId?: string; selectedMeeting?: SyncedMeetingInfo }) {
  const [items, setItems] = useState<SyncedMeetingInfo[]>([]);
  const [nextCursor, setNextCursor] = useState<string>();
  const [cursor, setCursor] = useState<string>();
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string>();
  const [attempt, setAttempt] = useState(0);
  useEffect(() => {
    const controller = new AbortController();
    setLoading(true);
    setError(undefined);
    const params = new URLSearchParams(projectId ? { projectId, projectScope: "direct" } : { projectScope: "unassigned" });
    if (cursor) params.set("cursor", cursor);
    void json<SyncedMeetingPage>(`/api/v1/vaults/${vaultId}/meetings?${params}`, { signal: controller.signal }).then((page) => {
      if (controller.signal.aborted) return;
      setItems((previous) => {
        if (!cursor) return page.items;
        const previousIds = new Set(previous.map(({ meetingId }) => meetingId));
        const newItems = page.items.filter(({ meetingId }) => !previousIds.has(meetingId));
        return [...previous, ...newItems];
      });
      setNextCursor(page.nextCursor);
    }).catch((caught: unknown) => {
      if (!controller.signal.aborted) setError(caught instanceof Error ? caught.message : "Could not load meetings");
    }).finally(() => { if (!controller.signal.aborted) setLoading(false); });
    return () => controller.abort();
  }, [vaultId, projectId, cursor, attempt]);
  let visibleMeetings = items;
  if (selectedMeeting
    && (selectedMeeting.projectId ?? undefined) === projectId
    && !items.some(({ meetingId }) => meetingId === selectedMeeting.meetingId)) {
    visibleMeetings = [selectedMeeting, ...items];
  }
  return <>
    {visibleMeetings.map((meeting) => {
      const href = `/vaults/${vaultId}/meetings/${meeting.meetingId}`;
      const active = window.location.pathname === href;
      const meetingDate = meeting.recordingStartedAt ?? meeting.createdAt;
      return <li key={meeting.meetingId} className={`tree-row meeting-row${active ? " active" : ""}`}>
        <a href={href} title={meeting.name} aria-current={active ? "page" : undefined}>
          <span>{meeting.name || uiText("Untitled meeting", "無題のミーティング")}</span>
          <time dateTime={meetingDate}>{new Date(meetingDate).toLocaleString(undefined, { year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit" })}</time>
        </a>
      </li>;
    })}
    {loading && <li className="sidebar-status">{uiText("Loading meetings…", "ミーティングを読み込み中…")}</li>}
    {error && <li><Failure message={error} retry={() => setAttempt((value) => value + 1)} /></li>}
    {!loading && !error && visibleMeetings.length === 0 && <li className="sidebar-status">{uiText("No meetings", "ミーティングがありません")}</li>}
    {!loading && !error && nextCursor && <li><button className="sidebar-action" onClick={() => setCursor(nextCursor)}>{uiText("Show more", "さらに表示")}</button></li>}
  </>;
}
