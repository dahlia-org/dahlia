import { createContext, useContext, useEffect, useState, type ReactNode } from "react";
import type { SessionInfo } from "./App";
import type { OrganizationInfo, SyncedMeetingInfo, SyncedMeetingPage, SyncedProjectInfo, SyncedVaultInfo } from "./api";
import { json, RequestError } from "./api";

export function vaultListURL(userId: string, organizationId: string) {
  return `/api/v1/vaults?${new URLSearchParams(organizationId ? { organizationId } : { userId })}`;
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

function readSelection(userId: string): string {
  try { return sessionStorage.getItem(`dahlia:sidebar:${userId}:organization`) ?? ""; }
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
  const [organizationId, setOrganizationId] = useState(() => session.capabilities.sharing ? readSelection(session.user.id) : "");
  const [organizations, setOrganizations] = useState<OrganizationInfo[]>();
  const [organizationError, setOrganizationError] = useState<string>();
  const [vaults, setVaults] = useState<SyncedVaultInfo[]>();
  const [error, setError] = useState<string>();
  const [attempt, setAttempt] = useState(0);
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
    void json<{ items: SyncedVaultInfo[] }>(vaultListURL(session.user.id, organizationId), { signal: controller.signal })
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
  return <div className="sidebar-status" role="alert">{message} <button className="sidebar-action" onClick={retry}>Retry</button></div>;
}

export function Sidebar({ brand, session, children }: { brand: ReactNode; session: SessionInfo; children: ReactNode }) {
  const state = useSidebar();
  const identity = session.user.name || session.user.email || session.user.id;
  const current = state.organizationId
    ? state.organizations?.find(({ id }) => id === state.organizationId)?.name ?? "Organization"
    : "Personal";
  return <aside className="sidebar">
    <div className="sidebar-brand">{brand}</div>
    <button className="organization-switcher" popoverTarget="organization-picker" aria-label={`Switch organization: ${current}`}>
      <span className="avatar">{current.slice(0, 1).toUpperCase()}</span><strong>{current}</strong><Chevron expanded />
    </button>
    <div id="organization-picker" popover="auto" className="organization-picker">
      <strong>Workspace</strong>
      <button onClick={() => state.select("")}>Personal <span>{!state.organizationId ? "✓" : ""}</span></button>
      {state.organizations?.map((organization) => <button key={organization.id} onClick={() => state.select(organization.id)}>
        {organization.name}<span>{state.organizationId === organization.id ? "✓" : ""}</span>
      </button>)}
      {!state.organizations && !state.organizationError && <p className="sidebar-status">Loading organizations…</p>}
      {state.organizationError && <Failure message={state.organizationError} retry={state.reload} />}
      {session.capabilities.sharing && <a href="/organizations">Manage organizations</a>}
    </div>
    <div className="sidebar-scroll">
      {children}
      {session.capabilities.sync && <nav className="vault-navigation" aria-label="Vault navigation">
        <a className="vault-heading" href="/vaults">Vaults</a>
        {state.error && <Failure message={state.error} retry={state.reload} />}
        {!state.vaults && !state.error && <p className="sidebar-status">{state.organizationError ? "Choose Personal or retry loading organizations." : "Loading Vaults…"}</p>}
        {state.vaults?.length === 0 && <p className="sidebar-status">No Vaults</p>}
        <ul className="sidebar-tree" key={state.organizationId}>
          {state.vaults?.map((vault) => <VaultNode key={vault.vaultId} vault={vault} />)}
        </ul>
      </nav>}
    </div>
    <div className="sidebar-footer"><span className="avatar">{identity.slice(0, 1).toUpperCase()}</span>
      <span className="identity-copy"><strong>{identity}</strong><small>Personal account</small></span>
    </div>
  </aside>;
}

function TreeNode({ id, name, href, initialOpen, children }: { id: string; name: string; href: string; initialOpen: boolean; children: ReactNode }) {
  const { userId, organizationId } = useSidebar();
  const key = `dahlia:sidebar:${userId}:${organizationId || "personal"}:${id}`;
  const [open, setOpen] = useState(() => {
    if (initialOpen) return true;
    try { return sessionStorage.getItem(key) === "true"; } catch { return false; }
  });
  const active = window.location.pathname === href;
  return <li>
    <div className={`tree-row${active ? " active" : ""}`}>
      <button className="tree-toggle" aria-label={`${open ? "Collapse" : "Expand"} ${name}`} aria-expanded={open} onClick={() => {
        setOpen(!open);
        save(key, String(!open));
      }}><Chevron expanded={open} /></button>
      <a href={href} title={name} aria-current={active ? "page" : undefined}>{name}</a>
    </div>
    {open && children}
  </li>;
}

function VaultNode({ vault }: { vault: SyncedVaultInfo }) {
  const href = `/vaults/${vault.vaultId}`;
  return <TreeNode id={vault.vaultId} name={vault.name} href={href} initialOpen={window.location.pathname === href || window.location.pathname.startsWith(`${href}/`)}>
    <VaultChildren vaultId={vault.vaultId} />
  </TreeNode>;
}

function VaultChildren({ vaultId }: { vaultId: string }) {
  const [data, setData] = useState<{ projects: SyncedProjectInfo[]; selectedMeeting?: SyncedMeetingInfo }>();
  const [error, setError] = useState<string>();
  const [attempt, setAttempt] = useState(0);
  const base = `/vaults/${vaultId}`;
  const route = window.location.pathname;
  const meetingId = route.startsWith(`${base}/meetings/`) ? route.split("/")[4] : undefined;
  const projectId = route.startsWith(`${base}/projects/`) ? route.split("/")[4] : undefined;
  useEffect(() => {
    const controller = new AbortController();
    setError(undefined);
    void Promise.all([
      json<{ items: SyncedProjectInfo[] }>(`/api/v1/vaults/${vaultId}/projects`, { signal: controller.signal }),
      meetingId ? json<SyncedMeetingInfo>(`/api/v1/vaults/${vaultId}/meetings/${meetingId}`, { signal: controller.signal }) : Promise.resolve(undefined),
    ]).then(([projects, selectedMeeting]) => {
      if (!controller.signal.aborted) setData({ projects: projects.items, selectedMeeting });
    }).catch((caught: unknown) => {
      if (!controller.signal.aborted) setError(caught instanceof Error ? caught.message : "Could not load Projects");
    });
    return () => controller.abort();
  }, [vaultId, meetingId, attempt]);
  if (error) return <Failure message={error} retry={() => setAttempt((value) => value + 1)} />;
  if (!data) return <p className="sidebar-status">Loading Projects…</p>;
  const ancestors = projectAncestors(data.projects, projectId ?? data.selectedMeeting?.projectId);
  const childrenByParent = new Map<string | undefined, SyncedProjectInfo[]>();
  for (const project of data.projects) {
    const parent = project.parentProjectId ?? undefined;
    const siblings = childrenByParent.get(parent) ?? [];
    siblings.push(project);
    childrenByParent.set(parent, siblings);
  }
  const projectsUnder = (parentId?: string): ReactNode => (childrenByParent.get(parentId) ?? []).map((project) =>
    <TreeNode key={project.projectId} id={project.projectId} name={project.name} href={`${base}/projects/${project.projectId}`} initialOpen={ancestors.has(project.projectId)}>
      <ul className="sidebar-tree">
        {projectsUnder(project.projectId)}
        <Meetings vaultId={vaultId} projectId={project.projectId} selectedMeeting={data.selectedMeeting} />
      </ul>
    </TreeNode>);
  return <ul className="sidebar-tree">
    {projectsUnder()}
    <Meetings vaultId={vaultId} selectedMeeting={data.selectedMeeting} />
  </ul>;
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
      return <li key={meeting.meetingId} className={`tree-row meeting-row${active ? " active" : ""}`}>
        <span aria-hidden="true">▤</span><a href={href} title={meeting.name} aria-current={active ? "page" : undefined}>{meeting.name || "Untitled meeting"}</a>
      </li>;
    })}
    {loading && <li className="sidebar-status">Loading meetings…</li>}
    {error && <li><Failure message={error} retry={() => setAttempt((value) => value + 1)} /></li>}
    {!loading && !error && visibleMeetings.length === 0 && <li className="sidebar-status">No meetings</li>}
    {!loading && !error && nextCursor && <li><button className="sidebar-action" onClick={() => setCursor(nextCursor)}>Show more</button></li>}
  </>;
}
