import { refreshData, subscribeLiveUpdates, useLiveJSON, useLivePage, useLiveQuery } from "./live-data";
import { createAuthClient } from "better-auth/react";
import { useCallback, useEffect, useMemo, useRef, useState, type ComponentType, type MouseEvent, type ReactNode } from "react";

import {
  isCoreDashboardPath,
  resolveDashboardRoute,
  shouldRedirectToSignIn,
  type DashboardCapabilities,
} from "./routes";
import { dashboardNavigationPath, navigateDashboard } from "./navigation";
import { summaryDisplayText } from "../search/summary";
import { clientMutationEvent, json, RequestError, syncMessage, uiText, type SyncedVaultInfo, type OrganizationInfo, type SyncedMeetingInfo, type SyncedProjectInfo } from "./api";
import { MeetingTabs, parseSummary, SummaryContent, SummaryTags, TranscriptTime } from "./MeetingContent";
import { MenuIcon, Sidebar, SidebarProvider, useSidebar } from "./Sidebar";

export interface SessionInfo {
  capabilities: DashboardCapabilities;
  user: { id: string; email?: string; name?: string };
  workspace: { id: string; type: "personal" };
}

export interface DashboardBrand {
  name: string;
  product: string;
}

export interface DashboardNavigationItem {
  capability?: string;
  label: string;
  path: string;
}

export interface DashboardExtensionRoute {
  capability?: string;
  component: ComponentType<{ session: SessionInfo }>;
  path: string;
}

export interface DashboardExtension {
  navigation?: readonly DashboardNavigationItem[];
  routes?: readonly DashboardExtensionRoute[];
}

export interface AppProps {
  brand?: DashboardBrand;
  extensions?: readonly DashboardExtension[];
}

const defaultBrand: DashboardBrand = { name: "Dahlia", product: "Server" };

export function resolveDashboardExtensionRoute(
  path: string,
  capabilities: DashboardCapabilities,
  extensions: readonly DashboardExtension[],
): { allowed: boolean; route?: DashboardExtensionRoute } {
  if (isCoreDashboardPath(path)) return { allowed: true };
  const route = extensions
    .flatMap((extension) => extension.routes ?? [])
    .find((candidate) => candidate.path === path);
  return {
    allowed: !route?.capability || capabilities[route.capability] === true,
    route,
  };
}

interface DeviceSession {
  id: string;
  createdAt: string;
  expiresAt: string;
  userAgent?: string;
  current: boolean;
}

interface AdminMember {
  id: string;
  name: string;
  email: string;
  role: "admin";
  removable: boolean;
}

interface OrganizationMember {
  id: string;
  userId: string;
  role: string;
  user: { name: string; email: string };
}

interface OrganizationInvitation {
  id: string;
  organizationId: string;
  organizationName?: string;
  email: string;
  role: string;
  status: string;
  expiresAt: string;
}

interface TeamInfo {
  id: string;
  name: string;
  organizationId: string;
}

interface TeamMember {
  id: string;
  userId: string;
  teamId: string;
}

interface VaultPermissionInfo {
  principalType: "user" | "organization" | "team";
  principalId: string;
  role: "owner" | "member";
}

interface SyncedTranscriptSegmentInfo {
  segmentId: string;
  startTime: string;
  endTime?: string;
  text: string;
  isConfirmed: boolean;
  audioSource?: string;
  speakerLabel?: string;
}

interface SyncedScreenshotInfo {
  id: string;
  capturedAt: string | null;
  file: { id: string; content_type: string; variants: Partial<Record<"thumb_360" | "thumb_1280", string>>; metadata: { source: string; ocr_text?: string; caption?: string } };
}

type SyncOperation = {
  entity: "vault" | "project" | "meeting" | "summary";
  action: "create" | "update" | "delete" | "upsert";
  entityId: string;
  baseRevision: number | null;
  data: Record<string, unknown>;
};

export async function commitSyncTransaction(vaultId: string, operations: SyncOperation[], onRecovery: (active: boolean) => void = () => {}) {
  const transactionId = uuidV7();
  const request = {
    method: "POST",
    body: JSON.stringify({
      schemaVersion: 2,
      id: transactionId,
      vaultId,
      createdAt: new Date().toISOString(),
      operations: operations.map((operation) => ({ ...operation, id: uuidV7() })),
    }),
  };
  type Receipt = { id: string; status: "committed" | "unknown"; receipt?: "full" | "compact" };
  try {
    let result: Receipt;
    try {
      result = await json<Receipt>("/api/v1/transactions", request, { notifyMutation: false });
    } catch (error) {
      if (error instanceof RequestError && error.status && error.status < 500 && ![408, 410, 425, 429].includes(error.status)) throw error;
      onRecovery(true);
      let resolved: Receipt;
      try {
        resolved = await json<Receipt>("/api/v1/transactions/resolve", request, { notifyMutation: false });
      } catch (resolveError) {
        if (resolveError instanceof RequestError && resolveError.status === 404) {
          throw new RequestError(syncMessage("sync_upgrade_required")!, 426, { cause: resolveError });
        }
        throw resolveError;
      }
      if (resolved.id !== transactionId) throw new Error("Invalid transaction receipt", { cause: error });
      result = resolved.status === "unknown"
        ? await json<Receipt>("/api/v1/transactions", request, { notifyMutation: false })
        : resolved;
    }
    if (result.id !== transactionId || result.status !== "committed"
      || (result.receipt !== undefined && !["full", "compact"].includes(result.receipt))) {
      throw new Error("Invalid transaction receipt");
    }
    // Both receipt forms acknowledge the write. Callers reload canonical data rather than applying old content.
    if (typeof window !== "undefined") refreshData();
    return result;
  } finally {
    onRecovery(false);
  }
}

function uuidV7(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  let timestamp = Date.now();
  for (let index = 5; index >= 0; index -= 1) {
    bytes[index] = timestamp & 0xff;
    timestamp = Math.floor(timestamp / 256);
  }
  bytes[6] = (bytes[6]! & 0x0f) | 0x70;
  bytes[8] = (bytes[8]! & 0x3f) | 0x80;
  const value = [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
  return `${value.slice(0, 8)}-${value.slice(8, 12)}-${value.slice(12, 16)}-${value.slice(16, 20)}-${value.slice(20)}`;
}

function summaryDocument(title: string, text: string): string {
  return JSON.stringify({
    schemaVersion: 3,
    title,
    description: "",
    sections: [{
      id: uuidV7(),
      heading: "",
      blocks: [{ id: uuidV7(), type: "paragraph", content: { text } }],
    }],
    tags: [],
    actionItems: [],
  });
}

async function beginSignIn(callbackURL: string): Promise<string | undefined> {
  try {
    const authClient = createAuthClient({ baseURL: window.location.origin });
    const result = await authClient.signIn.social({ provider: "google", callbackURL });
    if (!result.error) return undefined;
    return result.error.message || "Sign in failed";
  } catch (caught) {
    return caught instanceof Error ? caught.message : "Sign in failed";
  }
}

function Brand({ brand }: { brand: DashboardBrand }) {
  return (
    <a className="brand" href="/dashboard" aria-label={`${brand.name} ${brand.product} home`}>
      <svg className="brand-mark" viewBox="0 0 32 32" aria-hidden="true" focusable="false">
        <path d="M16 15C12 13 10.5 10 11.3 6.8C12 3.8 14.2 1.8 16 1c1.8.8 4 2.8 4.7 5.8.8 3.2-.7 6.2-4.7 8.2Z" />
        <path d="M17 16c2-4 5-5.5 8.2-4.7 3 .7 5 2.9 5.8 4.7-.8 1.8-2.8 4-5.8 4.7-3.2.8-6.2-.7-8.2-4.7Z" />
        <path d="M16 17c4 2 5.5 5 4.7 8.2-.7 3-2.9 5-4.7 5.8-1.8-.8-4-2.8-4.7-5.8-.8-3.2.7-6.2 4.7-8.2Z" />
        <path d="M15 16c-2 4-5 5.5-8.2 4.7-3-.7-5-2.9-5.8-4.7.8-1.8 2.8-4 5.8-4.7 3.2-.8 6.2.7 8.2 4.7Z" />
        <circle cx="16" cy="16" r="3.2" />
      </svg>
      <span>{brand.name}</span>
      <small>{brand.product}</small>
    </a>
  );
}

function SignIn({ brand }: { brand: DashboardBrand }) {
  const [error, setError] = useState<string>();

  async function signIn() {
    setError(undefined);
    const params = new URLSearchParams(window.location.search);
    const next = params.get("next");
    const safeNext = next?.startsWith("/") && !next.startsWith("//") ? next : undefined;
    setError(await beginSignIn(safeNext
      ?? (params.has("client_id") ? `/api/auth/oauth2/authorize${window.location.search}` : "/dashboard")));
  }

  return (
    <main className="auth-page">
      <section className="auth-card">
        <Brand brand={brand} />
        <div className="auth-copy">
          <span className="eyebrow">Personal AI gateway</span>
          <h1>Use the model configured for your Dahlia deployment.</h1>
          <p>
            Audio and local recordings stay on your Mac. When you enable Vault sync, meeting summaries,
            transcripts, screenshots, OCR text, and captions are stored privately on this server.
          </p>
        </div>
        <button className="primary full" onClick={() => void signIn()}>
          Continue with Google
        </button>
        {error && <p className="error">{error}</p>}
      </section>
    </main>
  );
}

function Consent({ brand }: { brand: DashboardBrand }) {
  const [error, setError] = useState<string>();
  const oauthQuery = window.location.search.slice(1);

  async function decide(accept: boolean) {
    try {
      const result = await json<{ redirect_uri: string }>("/api/auth/oauth2/consent", {
        method: "POST",
        body: JSON.stringify({ accept, oauth_query: oauthQuery }),
      });
      window.location.assign(result.redirect_uri);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Consent failed");
    }
  }

  return (
    <main className="auth-page">
      <section className="auth-card compact">
        <Brand brand={brand} />
        <div className="auth-copy">
          <span className="eyebrow">Dahlia for macOS</span>
          <h1>Allow this Mac to use the Dahlia AI Gateway?</h1>
          <p>This grants the app a short-lived access token. Provider credentials are never sent to your Mac.</p>
        </div>
        <div className="button-row">
          <button className="secondary" onClick={() => void decide(false)}>Cancel</button>
          <button className="primary" onClick={() => void decide(true)}>Allow</button>
        </div>
        {error && <p className="error">{error}</p>}
      </section>
    </main>
  );
}

function Shell({
  brand,
  children,
  extensions,
  session,
  path,
  navigate,
}: {
  brand: DashboardBrand;
  children: ReactNode;
  extensions: readonly DashboardExtension[];
  session: SessionInfo;
  path: string;
  navigate: (path: string) => void;
}) {
  const main = useRef<HTMLElement>(null);
  useEffect(() => {
    main.current?.focus({ preventScroll: true });
    window.scrollTo(0, 0);
  }, [path]);
  const followLink = (event: MouseEvent<HTMLDivElement>) => {
    if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    const link = event.target instanceof Element ? event.target.closest("a") : null;
    if (!link || !link.hasAttribute("href") || link.hasAttribute("download") || (link.target && link.target !== "_self")) return;
    const next = dashboardNavigationPath(link.href, window.location.href, extensions.flatMap((extension) => extension.routes?.map((route) => route.path) ?? []));
    if (!next) return;
    event.preventDefault();
    link.closest<HTMLElement>("[popover]")?.hidePopover();
    navigate(next);
  };
  return (
    <SidebarProvider key={session.user.id} session={session}>
      <div className="app-shell" onClick={followLink}>
        <Sidebar brand={<Brand brand={brand} />} session={session}>
          <nav aria-label="Account navigation">
            {extensions.flatMap((extension) => extension.navigation ?? []).map((item) => (
              (!item.capability || session.capabilities[item.capability])
                ? <a className={path === item.path ? "active" : ""} href={item.path} key={item.path}><MenuIcon name="artifact" />{item.label}</a>
                : null
            ))}
            {session.capabilities.sessions && (
              <a className={path === "/dashboard/settings" ? "active" : ""} href="/dashboard/settings">
                <MenuIcon name="settings" />{uiText("Settings", "設定")}
              </a>
            )}
          </nav>
        </Sidebar>
        <main className="workspace" key={path} ref={main} tabIndex={-1}>{children}</main>
      </div>
    </SidebarProvider>
  );
}

function PageHeader({ title }: { title: string }) {
  return <header className="page-header"><h1>{title}</h1></header>;
}

function Overview({ session }: { session: SessionInfo }) {
  return (
    <>
      <PageHeader title="Overview" />
      <section className="section-block">
        <h2 className="section-label">Account</h2>
        <div className="panel account-card">
          <dl className="account-details">
            <div><dt>Name</dt><dd>{session.user.name || "—"}</dd></div>
            <div><dt>Email address</dt><dd>{session.user.email || "—"}</dd></div>
            <div><dt>Account</dt><dd>Personal account</dd></div>
          </dl>
        </div>
      </section>
    </>
  );
}

function Settings() {
  const [sessions, setSessions] = useState<DeviceSession[]>();
  const [error, setError] = useState<string>();
  const load = useCallback(() => {
    setError(undefined);
    void json<DeviceSession[]>("/api/sessions").then(setSessions).catch((caught: Error) => setError(caught.message));
  }, []);
  useEffect(load, [load]);

  async function revoke(id: string) {
    try {
      await json(`/api/sessions/${id}`, { method: "DELETE" });
      load();
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Could not revoke session");
    }
  }

  return (
    <>
      <PageHeader title="Settings" />
      <section className="section-block">
        <h2 className="section-label">Active Sessions</h2>
        <div className="panel sessions-panel">
          {error && <p className="error">{error}</p>}
          {!sessions && !error && <p className="muted">Loading sessions…</p>}
          {sessions?.length === 0 && (
            <div className="empty-state"><strong>No active sessions</strong><span>Connect Dahlia for macOS to see it here.</span></div>
          )}
          {sessions?.map((session) => (
            <div className="row" key={session.id}>
              <div>
                <strong>{session.current ? "This browser" : session.userAgent || "Dahlia session"}</strong>
                <span>Created {new Date(session.createdAt).toLocaleString()}</span>
              </div>
              <div className="row-actions">
                {session.current && <span className="status good">Current</span>}
                <button className="secondary" onClick={() => void revoke(session.id)}>Revoke</button>
              </div>
            </div>
          ))}
        </div>
        <p className="section-note">Revoked access can remain valid for up to 15 minutes.</p>
      </section>
    </>
  );
}

function Vaults() {
  const { vaults, error: loadError, reload, organizationId } = useSidebar();
  const [error, setError] = useState<string>();
  const [recovering, setRecovering] = useState(false);

  const createVault = async () => {
    const name = window.prompt("Vault name")?.trim();
    if (!name) return;
    const id = uuidV7();
    setError(undefined);
    try {
      await commitSyncTransaction(id, [{
        entity: "vault",
        action: "create",
        entityId: id,
        baseRevision: null,
        data: { name, createdAt: new Date().toISOString() },
      }], setRecovering);
      navigateDashboard(`/vaults/${id}`);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Could not create Vault");
    }
  };
  return (
    <>
      <PageHeader title="Vaults" />
      {recovering && <p role="status">{syncMessage("sync_recovering")}</p>}
      <section className="section-block">
        <h2 className="section-label">Synchronized Vaults</h2>
        {!organizationId && <button className="secondary" onClick={() => void createVault()}>New Vault</button>}
        <div className="panel artifact-list">
          {!vaults && !loadError && <p className="muted">Loading Vaults…</p>}
          {loadError && <p role="alert">{loadError} <button onClick={reload}>Retry</button></p>}
          {vaults?.length === 0 && <div className="empty-state"><strong>No synchronized Vaults</strong></div>}
          {vaults?.map((vault) => (
            <a className="artifact-row" href={`/vaults/${vault.vaultId}`} key={vault.vaultId}>
              <span className="artifact-copy">
                <strong>{vault.name}</strong>
                <span>{vault.role === "owner" ? "Owned by you" : "Shared with you"} · Updated {new Date(vault.updatedAt).toLocaleString()}</span>
              </span>
            </a>
          ))}
        </div>
        {error && <p className="error artifact-error">{error}</p>}
      </section>
    </>
  );
}

function VaultSharing({ session, vault }: { session: SessionInfo; vault: SyncedVaultInfo }) {
  const [error, setError] = useState<string>();
  const sharingQuery = useLiveQuery(`sharing:${vault.vaultId}:${session.capabilities.sessions}`, async (signal) => {
    const [{ items }, organizationItems] = await Promise.all([
      json<{ items: VaultPermissionInfo[] }>(`/api/v1/vaults/${vault.vaultId}/permissions`, { signal }),
      session.capabilities.sessions
        ? json<OrganizationInfo[]>("/api/auth/organization/list", { signal })
        : json<OrganizationInfo[]>("/api/v1/organizations", { signal }),
    ]);
    const teamItems = (await Promise.all(organizationItems.map((organization) =>
      session.capabilities.sessions
        ? json<TeamInfo[]>(`/api/auth/organization/list-teams?organizationId=${encodeURIComponent(organization.id)}`, { signal })
        : json<TeamInfo[]>(`/api/v1/organizations/${encodeURIComponent(organization.id)}/teams`, { signal })
    ))).flat();
    return { permissions: items, organizations: organizationItems, teams: teamItems };
  });
  const permissions = sharingQuery.data?.permissions;
  const organizations = sharingQuery.data?.organizations ?? [];
  const teams = sharingQuery.data?.teams ?? [];

  async function toggle(principalType: "organization" | "team", principalId: string, enabled: boolean) {
    setError(undefined);
    try {
      const target = `${principalType === "organization" ? "organizations" : "teams"}/${encodeURIComponent(principalId)}`;
      await json(`/api/v1/vaults/${vault.vaultId}/permissions/${target}`, {
        method: enabled ? "PUT" : "DELETE",
      });
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Could not update sharing");
    }
  }

  const shared = (principalType: VaultPermissionInfo["principalType"], principalId: string) =>
    permissions?.some((permission) => permission.role === "member"
      && permission.principalType === principalType
      && permission.principalId === principalId) === true;
  const permissionLabel = (permission: VaultPermissionInfo) => {
    if (permission.principalType === "organization") {
      return organizations.find(({ id }) => id === permission.principalId)?.name ?? "Organization";
    }
    if (permission.principalType === "team") {
      return teams.find(({ id }) => id === permission.principalId)?.name ?? "Team";
    }
    return "Shared directly with you";
  };
  return (
    <section className="section-block">
      <h2 className="section-label">Sharing</h2>
      <div className="panel share-list">
        {!permissions && !error && !sharingQuery.error && <p className="muted">Loading sharing settings…</p>}
        {vault.role === "member" && permissions && (
          <>
            <p className="muted">This Vault was shared with you. Only its owner can change access.</p>
            {permissions.map((permission) => (
              <div className="share-row" key={`${permission.principalType}-${permission.principalId}`}>
                <span>
                  <strong>{permissionLabel(permission)}</strong>
                  <small>Read-only access</small>
                </span>
              </div>
            ))}
          </>
        )}
        {vault.role === "owner" && organizations.length === 0 && permissions && (
          <div className="empty-state"><strong>No organizations</strong><span>Create one from Organizations first.</span></div>
        )}
        {vault.role === "owner" && organizations.map((organization) => (
          <label className="share-row" key={organization.id}>
            <span><strong>{organization.name}</strong><small>{organization.slug}</small></span>
            <input
              type="checkbox"
              checked={shared("organization", organization.id)}
              onChange={(event) => void toggle("organization", organization.id, event.target.checked)}
            />
          </label>
        ))}
        {vault.role === "owner" && teams.map((team) => (
          <label className="share-row" key={team.id}>
            <span><strong>{team.name}</strong><small>Team · read-only access</small></span>
            <input
              type="checkbox"
              checked={shared("team", team.id)}
              onChange={(event) => void toggle("team", team.id, event.target.checked)}
            />
          </label>
        ))}
      </div>
      <DataError error={sharingQuery.error} retry={sharingQuery.reload} />
      {error && <p className="error artifact-error">{error}</p>}
    </section>
  );
}

function VaultMeetings({ session, vaultId }: { session: SessionInfo; vaultId: string }) {
  const vaultQuery = useLiveJSON<SyncedVaultInfo>(`/api/v1/vaults/${vaultId}`);
  const vault = vaultQuery.data;
  const [error, setError] = useState<string>();
  const [recovering, setRecovering] = useState(false);
  const projectsQuery = useLiveJSON<{ items: SyncedProjectInfo[] }>(`/api/v1/vaults/${vaultId}/projects`);
  const projects = vault ? projectsQuery.data?.items ?? [] : [];
  const [query, setQuery] = useState("");
  const [projectId, setProjectId] = useState("");
  useEffect(() => {
    if (projectsQuery.data && !projectsQuery.data.items.some((project) => project.projectId === projectId)) setProjectId("");
  }, [projectId, projectsQuery.data]);
  const [search, setSearch] = useState("");
  useEffect(() => {
    const timer = setTimeout(() => setSearch(query), 250);
    return () => clearTimeout(timer);
  }, [query]);
  const params = new URLSearchParams();
  if (search) params.set("q", search);
  if (projectId) params.set("projectId", projectId);
  const meetingsQuery = useLivePage<SyncedMeetingInfo>(`/api/v1/vaults/${vaultId}/meetings?${params}`);
  const meetings = vault ? meetingsQuery.data?.items : undefined;
  const nextCursor = meetingsQuery.data?.nextCursor;
  const loadingMore = meetingsQuery.loadingMore;
  const renameVault = async () => {
    if (!vault) return;
    const name = window.prompt("Vault name", vault.name)?.trim();
    if (!name || name === vault.name) return;
    setError(undefined);
    try {
      await commitSyncTransaction(vaultId, [{
        entity: "vault", action: "update", entityId: vaultId,
        baseRevision: vault.revision, data: { name },
      }], setRecovering);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Could not rename Vault");
    }
  };
  const createProject = async () => {
    const name = window.prompt("Project name")?.trim();
    if (!name) return;
    const id = uuidV7();
    setError(undefined);
    try {
      await commitSyncTransaction(vaultId, [{
        entity: "project", action: "create", entityId: id, baseRevision: null,
        data: {
          parentProjectId: null,
          name,
          description: "",
          projectType: "undefined",
          createdAt: new Date().toISOString(),
        },
      }], setRecovering);
      navigateDashboard(`/vaults/${vaultId}/projects/${id}`);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Could not create Project");
    }
  };
  return (
    <>
      <PageHeader title={vault?.name ?? "Vault"} />
      {recovering && <p role="status">{syncMessage("sync_recovering")}</p>}
      <DataError error={vaultQuery.error} retry={vaultQuery.reload} />
      <DataError error={meetingsQuery.error} retry={meetingsQuery.reload} />
      <DataError error={projectsQuery.error} retry={projectsQuery.reload} />
      <section className="section-block">
        <a className="secondary viewer-back" href="/vaults">All Vaults</a>
        {vault?.role === "owner" && <>
          <button className="secondary" onClick={() => void renameVault()}>Rename Vault</button>
          <button className="secondary" onClick={() => void createProject()}>New Project</button>
        </>}
        {projects.length > 0 && (
          <select aria-label="Filter by Project" value={projectId} onChange={(event) => setProjectId(event.target.value)}>
            <option value="">All Projects</option>
            {projects.map((project) => <option key={project.projectId} value={project.projectId}>{project.path}</option>)}
          </select>
        )}
        <input
          className="model-search"
          aria-label="Search meetings"
          placeholder="Search meetings"
          value={query}
          onChange={(event) => setQuery(event.target.value)}
        />
        <div className="panel artifact-list">
          {!meetings && !error && <p className="muted">Loading meetings…</p>}
          {meetings?.length === 0 && <div className="empty-state"><strong>No meetings found</strong></div>}
          {meetings?.map((meeting) => (
            <a
              className="artifact-row"
              href={`/vaults/${vaultId}/meetings/${meeting.meetingId}`}
              key={meeting.meetingId}
            >
              <span className="artifact-copy">
                <strong>{meeting.name}</strong>
                <span>{new Date(meeting.createdAt).toLocaleString()} · {meeting.status}</span>
              </span>
            </a>
          ))}
        </div>
        {error && <p className="error artifact-error">{error}</p>}
        {nextCursor && (
          <button className="secondary load-more" disabled={loadingMore} onClick={meetingsQuery.loadMore}>
            {loadingMore ? "Loading…" : "Load more"}
          </button>
        )}
      </section>
      {projects.length > 0 && (
        <section className="section-block">
          <h2 className="section-label">Projects</h2>
          <div className="panel artifact-list">
            {projects.map((project) => (
              <a className="artifact-row" href={`/vaults/${vaultId}/projects/${project.projectId}`} key={project.projectId}>
                <span className="artifact-copy"><strong>{project.path}</strong><span>{project.subtreeMeetingCount} meetings</span></span>
              </a>
            ))}
          </div>
        </section>
      )}
      {session.capabilities.sharing && vault && <VaultSharing session={session} vault={vault} />}
    </>
  );
}

function SyncedProject({ vaultId, projectId }: { vaultId: string; projectId: string }) {
  const vaultQuery = useLiveJSON<SyncedVaultInfo>(`/api/v1/vaults/${vaultId}`);
  const vault = vaultQuery.data;
  const [error, setError] = useState<string>();
  const [recovering, setRecovering] = useState(false);
  const projectQuery = useLiveJSON<SyncedProjectInfo>(`/api/v1/vaults/${vaultId}/projects/${projectId}`);
  const project = vault ? projectQuery.data : undefined;
  const params = new URLSearchParams({ projectId });
  const meetingsQuery = useLivePage<SyncedMeetingInfo>(`/api/v1/vaults/${vaultId}/meetings?${params}`);
  const meetings = project ? meetingsQuery.data?.items : undefined;
  const nextCursor = meetingsQuery.data?.nextCursor;
  const loadingMore = meetingsQuery.loadingMore;
  const editProject = async () => {
    if (!project) return;
    const name = window.prompt("Project name", project.name)?.trim();
    if (!name) return;
    const description = window.prompt("Project description", project.description) ?? project.description;
    setError(undefined);
    try {
      await commitSyncTransaction(vaultId, [{
        entity: "project", action: "update", entityId: projectId, baseRevision: project.revision,
        data: {
          parentProjectId: project.parentProjectId ?? null,
          name,
          description,
          projectType: project.parentProjectId ? null : project.projectType ?? "undefined",
        },
      }], setRecovering);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Could not update Project");
    }
  };
  const deleteProject = async () => {
    if (!project || !window.confirm(`Delete empty Project ${project.path}?`)) return;
    setError(undefined);
    try {
      await commitSyncTransaction(vaultId, [{
        entity: "project", action: "delete", entityId: projectId,
        baseRevision: project.revision, data: {},
      }], setRecovering);
      navigateDashboard(`/vaults/${vaultId}`);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Could not delete Project");
    }
  };
  return <>
    <PageHeader title={project?.path ?? "Project"} />
      {recovering && <p role="status">{syncMessage("sync_recovering")}</p>}
      <DataError error={vaultQuery.error} retry={vaultQuery.reload} />
      <DataError error={meetingsQuery.error} retry={meetingsQuery.reload} />
      <DataError error={projectQuery.error} retry={projectQuery.reload} />
    <a className="secondary viewer-back" href={`/vaults/${vaultId}`}>Back to Vault</a>
    {project && vault?.role === "owner" && <>
      <button className="secondary" onClick={() => void editProject()}>Edit Project</button>
      <button className="secondary" onClick={() => void deleteProject()}>Delete Project</button>
    </>}
    {error && <p className="error">{error}</p>}
    {project && <section className="section-block"><div className="panel meeting-content">
      {project.description && <p>{project.description}</p>}
      <p className="muted">{project.effectiveType} · revision {project.revision} · {project.subtreeMeetingCount} meetings</p>
    </div></section>}
    <section className="section-block"><h2 className="section-label">Meetings</h2><div className="panel artifact-list">
      {meetings?.length === 0 && <div className="empty-state"><strong>No meetings</strong></div>}
      {meetings?.map((meeting) => <a className="artifact-row" href={`/vaults/${vaultId}/meetings/${meeting.meetingId}`} key={meeting.meetingId}>
        <span className="artifact-copy"><strong>{meeting.name}</strong><span>{new Date(meeting.createdAt).toLocaleString()}</span></span>
      </a>)}
    </div></section>
    {nextCursor && (
      <button className="secondary load-more" disabled={loadingMore} onClick={meetingsQuery.loadMore}>
        {loadingMore ? "Loading…" : "Load more"}
      </button>
    )}
  </>;
}

function SyncedMeeting({ vaultId, meetingId }: { vaultId: string; meetingId: string }) {
  const base = `/api/v1/vaults/${vaultId}/meetings/${meetingId}`;
  const meetingQuery = useLiveJSON<SyncedMeetingInfo>(base);
  const vaultQuery = useLiveJSON<SyncedVaultInfo>(`/api/v1/vaults/${vaultId}`);
  const projectsQuery = useLiveJSON<{ items: SyncedProjectInfo[] }>(`/api/v1/vaults/${vaultId}/projects`);
  const transcriptQuery = useLiveJSON<{ items: SyncedTranscriptSegmentInfo[] }>(`${base}/transcript`);
  const screenshotsQuery = useLivePage<SyncedScreenshotInfo>(`${base}/files`);
  const meeting = vaultQuery.data ? meetingQuery.data : undefined;
  const vault = vaultQuery.data;
  const transcript = transcriptQuery.data?.items;
  const screenshots = screenshotsQuery.data?.items;
  const screenshotCursor = screenshotsQuery.data?.nextCursor;
  const loadingScreenshots = screenshotsQuery.loadingMore;
  const [error, setError] = useState<string>();
  const [recovering, setRecovering] = useState(false);
  const summaryText = summaryDisplayText(meeting?.summaryDocument ?? null);
  const document = useMemo(() => parseSummary(meeting?.summaryDocument), [meeting?.summaryDocument]);
  const project = projectsQuery.data?.items.find((item) => item.projectId === meeting?.projectId);
  const editMeeting = async () => {
    if (!meeting) return;
    const name = window.prompt("Meeting name", meeting.name)?.trim();
    if (!name) return;
    const description = window.prompt("Meeting description", meeting.description) ?? meeting.description;
    setError(undefined);
    try {
      await commitSyncTransaction(vaultId, [{
        entity: "meeting", action: "update", entityId: meetingId, baseRevision: meeting.revision,
        data: {
          projectId: meeting.projectId ?? null,
          name,
          description,
          status: meeting.status,
          duration: meeting.duration ?? null,
          recordingStartedAt: meeting.recordingStartedAt ?? null,
          updatedAt: new Date().toISOString(),
        },
      }], setRecovering);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Could not update Meeting");
    }
  };
  const editSummary = async () => {
    if (!meeting) return;
    const title = window.prompt("Summary title", meeting.summaryTitle ?? meeting.name)?.trim();
    if (!title) return;
    const text = window.prompt("Summary", summaryText) ?? summaryText;
    setError(undefined);
    try {
      await commitSyncTransaction(vaultId, [{
        entity: "summary", action: "upsert", entityId: meetingId,
        baseRevision: meeting.summaryRevision,
        data: { title, document: summaryDocument(title, text), createdAt: new Date().toISOString() },
      }], setRecovering);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Could not update Summary");
    }
  };
  const deleteSummary = async () => {
    if (!meeting?.summaryDocument || !window.confirm("Delete this Summary?")) return;
    setError(undefined);
    try {
      await commitSyncTransaction(vaultId, [{
        entity: "summary", action: "delete", entityId: meetingId,
        baseRevision: meeting.summaryRevision, data: {},
      }], setRecovering);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Could not delete Summary");
    }
  };
  const visibleScreenshots = screenshots?.filter((screenshot) => screenshot.file.metadata.source === "screenshot");
  return (
    <article className="meeting-detail">
      <header className="meeting-header">
        <h1>{meeting?.name || uiText("Meeting", "ミーティング")}</h1>
        {meeting && <div className="meeting-metadata">
          <span className="metadata-chip"><time dateTime={meeting.recordingStartedAt ?? meeting.createdAt}>
            {new Date(meeting.recordingStartedAt ?? meeting.createdAt).toLocaleString(undefined, { year: "numeric", month: "long", day: "numeric", hour: "2-digit", minute: "2-digit" })}
          </time>{meeting.duration != null && <> · {Math.floor(meeting.duration / 60)}:{String(Math.floor(meeting.duration % 60)).padStart(2, "0")}</>}</span>
          {meeting.projectId ? <a className="metadata-chip" href={`/vaults/${vaultId}/projects/${meeting.projectId}`}>
            <span aria-hidden="true">▱</span>{project?.path ?? uiText("Project", "プロジェクト")}
          </a> : <span className="metadata-chip">{uiText("Unassigned", "未分類")}</span>}
          <SummaryTags document={document} />
        </div>}
      </header>
      {recovering && <p role="status">{syncMessage("sync_recovering")}</p>}
      {error && <p className="error" role="alert">{error}</p>}
      <DataError error={meetingQuery.error} retry={meetingQuery.reload} />
      <DataError error={vaultQuery.error} retry={vaultQuery.reload} />
      <DataError error={projectsQuery.error} retry={projectsQuery.reload} />
      {!meeting && !error && !meetingQuery.error && !vaultQuery.error && <p className="muted">{uiText("Loading meeting…", "ミーティングを読み込み中…")}</p>}
      {meeting && <MeetingTabs
        actions={vault?.role === "owner" && <div className="meeting-actions">
          <button className="action-trigger" popoverTarget="meeting-actions">{uiText("⋯ Actions", "⋯ 操作")} <span aria-hidden="true">⌄</span></button>
          <div id="meeting-actions" popover="auto" className="action-menu">
            <button onClick={() => void editMeeting()}>{uiText("Edit Meeting", "ミーティングを編集")}</button>
            <button onClick={() => void editSummary()}>{meeting.summaryDocument ? uiText("Edit Summary", "要約を編集") : uiText("New Summary", "要約を追加")}</button>
            {meeting.summaryDocument && <button className="danger-button" onClick={() => void deleteSummary()}>{uiText("Delete Summary", "要約を削除")}</button>}
          </div>
        </div>}
        summary={meeting.summaryDocument
          ? <>{meeting.summaryTitle && meeting.summaryTitle !== meeting.name && <h2 className="summary-title">{meeting.summaryTitle}</h2>}<SummaryContent document={document} /></>
          : <p className="content-empty">{uiText("No summary yet", "要約はまだありません")}</p>}
        screenshots={<>
          <DataError error={screenshotsQuery.error} retry={screenshotsQuery.reload} />
          {visibleScreenshots?.length === 0 && <p className="content-empty">{uiText("No screenshots", "スクリーンショットはありません")}</p>}
          <div className="screenshot-grid">
            {visibleScreenshots?.map((screenshot) => (
              <ScreenshotFigure key={screenshot.id} file={screenshot.file} capturedAt={screenshot.capturedAt} />
            ))}
          </div>
          {screenshotCursor && <button className="secondary load-more" disabled={loadingScreenshots} onClick={screenshotsQuery.loadMore}>
            {loadingScreenshots ? uiText("Loading…", "読み込み中…") : uiText("Load more", "さらに表示")}
          </button>}
        </>}
        transcript={<div className="transcript-document">
          <DataError error={transcriptQuery.error} retry={transcriptQuery.reload} />
          {transcript?.length === 0 && <p className="content-empty">{uiText("No transcript", "文字起こしはありません")}</p>}
          {transcript?.slice(0, 500).map((segment) => <div className="transcript-segment" key={segment.segmentId}>
            <TranscriptTime startTime={segment.startTime} timeBase={meeting.recordingStartedAt ?? transcript?.[0]?.startTime ?? meeting.createdAt} />
            <p>{segment.speakerLabel && <strong>{segment.speakerLabel}: </strong>}{segment.text}</p>
          </div>)}
          {transcript && transcript.length > 500 && <p className="muted">{uiText("Showing the first 500 transcript segments.", "文字起こしの最初の500件を表示しています。")}</p>}
        </div>}
      />}
    </article>
  );
}

export function ScreenshotFigure({ file, capturedAt }: { file: SyncedScreenshotInfo["file"]; capturedAt?: string | null }) {
  const [failed, setFailed] = useState(false);
  const original = `/api/v1/files/${file.id}/content`;
  return <figure className="panel">
    <a href={file.variants.thumb_1280 ?? original} target="_blank" rel="noreferrer" aria-label={uiText("Open screenshot", "スクリーンショットを開く")}>
      {failed ? <span role="alert">{uiText("Unable to load screenshot.", "スクリーンショットを読み込めませんでした。")}</span> : <img
        src={file.variants.thumb_360 ?? original}
        alt={file.metadata.caption || uiText("Screenshot", "スクリーンショット")}
        loading="lazy"
        onError={() => setFailed(true)}
      />}
    </a>
    {capturedAt && <time className="screenshot-time" dateTime={capturedAt}>{new Date(capturedAt).toLocaleTimeString()}</time>}
    {(file.metadata.caption || file.metadata.ocr_text) && <figcaption>{file.metadata.caption || file.metadata.ocr_text}</figcaption>}
    <a href={original} target="_blank" rel="noreferrer">{uiText("Open original", "原本を開く")}</a>
  </figure>;
}

function OrganizationCard({
  organization,
  session,
  reloadOrganizations,
}: {
  organization: OrganizationInfo;
  session: SessionInfo;
  reloadOrganizations: () => void;
}) {
  const [members, setMembers] = useState<OrganizationMember[]>();
  const [teams, setTeams] = useState<TeamInfo[]>([]);
  const [teamMembers, setTeamMembers] = useState<Record<string, TeamMember[]>>({});
  const [invitations, setInvitations] = useState<OrganizationInvitation[]>();
  const [email, setEmail] = useState("");
  const [teamName, setTeamName] = useState("");
  const [invitationLink, setInvitationLink] = useState<string>();
  const [error, setError] = useState<string>();
  const organizationId = encodeURIComponent(organization.id);
  const load = useCallback(async () => {
    setError(undefined);
    try {
      const accounts = session.capabilities.sessions;
      const [memberPage, teamItems] = await Promise.all([
        json<{ members: OrganizationMember[] }>(accounts
          ? `/api/auth/organization/list-members?organizationId=${organizationId}`
          : `/api/v1/organizations/${organizationId}/members`),
        json<TeamInfo[]>(accounts
          ? `/api/auth/organization/list-teams?organizationId=${organizationId}`
          : `/api/v1/organizations/${organizationId}/teams`),
      ]);
      setMembers(memberPage.members);
      const role = memberPage.members.find((member) => member.userId === session.user.id)?.role;
      const canManageTeams = ["owner", "admin"].includes(role ?? "");
      const [invitationItems, teamMemberEntries] = await Promise.all([
        accounts && canManageTeams
          ? json<OrganizationInvitation[]>(
              `/api/auth/organization/list-invitations?organizationId=${organizationId}`,
            )
          : Promise.resolve([]),
        accounts && canManageTeams
          ? Promise.all(memberPage.members.map(async (member) => ({
              member,
              teams: await json<TeamInfo[]>(
                `/api/auth/organization/list-user-teams?userId=${encodeURIComponent(member.userId)}&organizationId=${organizationId}`,
              ),
            }))).then((memberships) => teamItems.map((team): [string, TeamMember[]] => [
              team.id,
              memberships.filter(({ teams }) => teams.some(({ id }) => id === team.id)).map(({ member }) => ({
                id: `${team.id}:${member.userId}`,
                userId: member.userId,
                teamId: team.id,
              })),
            ]))
          : accounts
            ? Promise.resolve([] as [string, TeamMember[]][])
            : Promise.all(teamItems.map(async (team): Promise<[string, TeamMember[]]> => [
                team.id,
                await json<TeamMember[]>(
                  `/api/v1/organizations/${organizationId}/teams/${encodeURIComponent(team.id)}/members`,
                ),
              ])),
      ]);
      setInvitations(invitationItems.filter((invitation) => invitation.status === "pending"));
      setTeams(teamItems);
      setTeamMembers(Object.fromEntries(teamMemberEntries));
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Could not load organization");
    }
  }, [organizationId, session.capabilities.sessions, session.user.id]);
  useEffect(() => { void load(); }, [load]);

  async function invite(event: React.FormEvent) {
    event.preventDefault();
    setError(undefined);
    setInvitationLink(undefined);
    try {
      const invitation = await json<OrganizationInvitation>("/api/auth/organization/invite-member", {
        method: "POST",
        body: JSON.stringify({ email, role: "member", organizationId: organization.id }),
      });
      const link = `${window.location.origin}/accept-invitation/${invitation.id}`;
      setInvitationLink(link);
      setEmail("");
      await navigator.clipboard.writeText(link).catch(() => undefined);
      await load();
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Could not create invitation");
    }
  }

  async function removeMember(member: OrganizationMember) {
    if (!window.confirm(`Remove ${member.user.email} from ${organization.name}?`)) return;
    try {
      await json("/api/auth/organization/remove-member", {
        method: "POST",
        body: JSON.stringify({ memberIdOrEmail: member.id, organizationId: organization.id }),
      });
      await load();
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Could not remove member");
    }
  }

  async function cancelInvitation(invitation: OrganizationInvitation) {
    try {
      await json("/api/auth/organization/cancel-invitation", {
        method: "POST",
        body: JSON.stringify({ invitationId: invitation.id }),
      });
      await load();
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Could not cancel invitation");
    }
  }

  async function deleteOrganization() {
    if (!window.confirm(`Delete ${organization.name}? Shared Vault access will be revoked.`)) return;
    try {
      await json("/api/auth/organization/delete", {
        method: "POST",
        body: JSON.stringify({ organizationId: organization.id }),
      });
      reloadOrganizations();
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Could not delete organization");
    }
  }

  async function createTeam(event: React.FormEvent) {
    event.preventDefault();
    try {
      const team = await json<TeamInfo>(session.capabilities.sessions
        ? "/api/auth/organization/create-team"
        : `/api/v1/organizations/${organizationId}/teams`, {
        method: "POST",
        body: JSON.stringify(session.capabilities.sessions
          ? { name: teamName, organizationId: organization.id }
          : { name: teamName }),
      });
      if (session.capabilities.sessions) {
        await json("/api/auth/organization/add-team-member", {
          method: "POST",
          body: JSON.stringify({ teamId: team.id, userId: session.user.id, organizationId: organization.id }),
        });
      }
      setTeamName("");
      await load();
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Could not create team");
    }
  }

  async function renameTeam(team: TeamInfo) {
    const name = window.prompt("Team name", team.name)?.trim();
    if (!name || name === team.name) return;
    try {
      await json(session.capabilities.sessions
        ? "/api/auth/organization/update-team"
        : `/api/v1/organizations/${organizationId}/teams/${encodeURIComponent(team.id)}`, {
        method: session.capabilities.sessions ? "POST" : "PATCH",
        body: JSON.stringify(session.capabilities.sessions
          ? { teamId: team.id, data: { name, organizationId: organization.id } }
          : { name }),
      });
      await load();
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Could not rename team");
    }
  }

  async function deleteTeam(team: TeamInfo) {
    if (!window.confirm(`Delete ${team.name}? Shared Vault access will be revoked.`)) return;
    try {
      await json(session.capabilities.sessions
        ? "/api/auth/organization/remove-team"
        : `/api/v1/organizations/${organizationId}/teams/${encodeURIComponent(team.id)}`, {
        method: session.capabilities.sessions ? "POST" : "DELETE",
        body: session.capabilities.sessions ? JSON.stringify({ teamId: team.id, organizationId: organization.id }) : undefined,
      });
      await load();
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Could not delete team");
    }
  }

  async function setTeamMember(team: TeamInfo, userId: string, enabled: boolean) {
    try {
      await json(session.capabilities.sessions
        ? `/api/auth/organization/${enabled ? "add" : "remove"}-team-member`
        : `/api/v1/organizations/${organizationId}/teams/${encodeURIComponent(team.id)}/members/${encodeURIComponent(userId)}`, {
        method: session.capabilities.sessions ? "POST" : enabled ? "PUT" : "DELETE",
        body: session.capabilities.sessions
          ? JSON.stringify({ teamId: team.id, userId, organizationId: organization.id })
          : undefined,
      });
      await load();
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Could not update team membership");
    }
  }

  const currentRole = members?.find((member) => member.userId === session.user.id)?.role;
  const canManage = ["owner", "admin"].includes(currentRole ?? "");
  const teamMemberIds = useMemo(() => Object.fromEntries(
    Object.entries(teamMembers).map(([teamId, entries]) => [teamId, new Set(entries.map(({ userId }) => userId))]),
  ), [teamMembers]);
  return (
    <section className="panel organization-card">
      <div className="organization-heading">
        <div><h2>{organization.name}</h2><span>{organization.slug}</span></div>
        {session.capabilities.sessions && currentRole === "owner" && (
          <button className="secondary danger-button" onClick={() => void deleteOrganization()}>Delete</button>
        )}
      </div>
      <h3>Members</h3>
      {!members && !error && <p className="muted">Loading members…</p>}
      {members?.map((member) => (
        <div className="member-row organization-row" key={member.id}>
          <div><strong>{member.user.name || member.user.email}</strong><span>{member.user.email} · {member.role}</span></div>
          {session.capabilities.sessions && canManage && member.userId !== session.user.id && (
            <button className="secondary danger-button" onClick={() => void removeMember(member)}>Remove</button>
          )}
        </div>
      ))}
      <h3>Teams</h3>
      {teams.map((team) => (
        <div className="team-block" key={team.id}>
          <div className="member-row organization-row">
            <div><strong>{team.name}</strong><span>{teamMembers[team.id]?.length ?? 0} members</span></div>
            {canManage && (
              <div className="row-actions">
                <button className="secondary" onClick={() => void renameTeam(team)}>Rename</button>
                {teams.length > 1 && (session.capabilities.sessions || team.id !== "external-default") && (
                  <button className="secondary danger-button" onClick={() => void deleteTeam(team)}>Delete</button>
                )}
              </div>
            )}
          </div>
          {(!session.capabilities.sessions || canManage) && members?.map((member) => (
            <label className="share-row" key={`${team.id}-${member.userId}`}>
              <span><strong>{member.user.name || member.user.email}</strong><small>{member.user.email}</small></span>
              <input
                type="checkbox"
                disabled={!canManage || (!session.capabilities.sessions
                  && team.id === "external-default" && member.userId === session.user.id)}
                checked={teamMemberIds[team.id]?.has(member.userId) === true}
                onChange={(event) => void setTeamMember(team, member.userId, event.target.checked)}
              />
            </label>
          ))}
        </div>
      ))}
      {canManage && (
        <form className="organization-invite" onSubmit={(event) => void createTeam(event)}>
          <label>Team name<input required value={teamName} onChange={(event) => setTeamName(event.target.value)} /></label>
          <button className="secondary">Create team</button>
        </form>
      )}
      {session.capabilities.sessions && canManage && (
        <>
          <h3>Pending invitations</h3>
          {invitations?.length === 0 && <p className="muted">No pending invitations.</p>}
          {invitations?.map((invitation) => (
            <div className="member-row organization-row" key={invitation.id}>
              <div><strong>{invitation.email}</strong><span>Expires {new Date(invitation.expiresAt).toLocaleString()}</span></div>
              <button className="secondary danger-button" onClick={() => void cancelInvitation(invitation)}>Cancel</button>
            </div>
          ))}
          <form className="organization-invite" onSubmit={(event) => void invite(event)}>
            <label>Email<input type="email" required value={email} onChange={(event) => setEmail(event.target.value)} /></label>
            <button className="secondary">Create invitation link</button>
          </form>
          {invitationLink && (
            <label className="invitation-link">Invitation link<input readOnly value={invitationLink} onFocus={(event) => event.target.select()} /></label>
          )}
        </>
      )}
      {error && <p className="error">{error}</p>}
    </section>
  );
}

function Organizations({ session }: { session: SessionInfo }) {
  const [organizations, setOrganizations] = useState<OrganizationInfo[]>();
  const [invitations, setInvitations] = useState<OrganizationInvitation[]>();
  const [name, setName] = useState("");
  const [slug, setSlug] = useState("");
  const [error, setError] = useState<string>();
  const load = useCallback(async () => {
    setError(undefined);
    try {
      const accounts = session.capabilities.sessions;
      const [organizationItems, invitationItems] = await Promise.all([
        json<OrganizationInfo[]>(accounts ? "/api/auth/organization/list" : "/api/v1/organizations"),
        accounts ? json<OrganizationInvitation[]>("/api/auth/organization/list-user-invitations") : Promise.resolve([]),
      ]);
      setOrganizations(organizationItems);
      setInvitations(invitationItems.filter((invitation) => invitation.status === "pending"));
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Could not load organizations");
    }
  }, [session.capabilities.sessions]);
  useEffect(() => { void load(); }, [load]);

  async function create(event: React.FormEvent) {
    event.preventDefault();
    setError(undefined);
    try {
      await json("/api/auth/organization/create", {
        method: "POST",
        body: JSON.stringify({ name, slug }),
      });
      setName("");
      setSlug("");
      await load();
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Could not create organization");
    }
  }

  async function decide(invitationId: string, accept: boolean) {
    try {
      await json(`/api/auth/organization/${accept ? "accept" : "reject"}-invitation`, {
        method: "POST",
        body: JSON.stringify({ invitationId }),
      });
      await load();
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Could not update invitation");
    }
  }

  return (
    <>
      <PageHeader title="Organizations" />
      {invitations && invitations.length > 0 && (
        <section className="section-block">
          <h2 className="section-label">Invitations</h2>
          <div className="panel admin-list">
            {invitations.map((invitation) => (
              <div className="member-row organization-row" key={invitation.id}>
                <div><strong>{invitation.organizationName}</strong><span>{invitation.role} · expires {new Date(invitation.expiresAt).toLocaleString()}</span></div>
                <div className="row-actions">
                  <button className="secondary" onClick={() => void decide(invitation.id, false)}>Decline</button>
                  <button className="primary" onClick={() => void decide(invitation.id, true)}>Accept</button>
                </div>
              </div>
            ))}
          </div>
        </section>
      )}
      <section className="section-block organization-list">
        <h2 className="section-label">Your organizations</h2>
        {!organizations && !error && <p className="muted">Loading organizations…</p>}
        {organizations?.length === 0 && <div className="panel empty-state"><strong>No organizations</strong></div>}
        {organizations?.map((organization) => (
          <OrganizationCard
            organization={organization}
            session={session}
            reloadOrganizations={() => void load()}
            key={organization.id}
          />
        ))}
      </section>
      {session.capabilities.sessions && <section className="section-block">
        <h2 className="section-label">Create organization</h2>
        <form className="panel admin-form organization-form" onSubmit={(event) => void create(event)}>
          <label>Name<input required value={name} onChange={(event) => setName(event.target.value)} /></label>
          <label>Slug<input required pattern="[a-z0-9-]+" value={slug} onChange={(event) => setSlug(event.target.value)} /></label>
          <button className="primary">Create</button>
        </form>
      </section>}
      {error && <p className="error page-error">{error}</p>}
    </>
  );
}

function Invitation({ invitationId }: { invitationId: string }) {
  const [invitation, setInvitation] = useState<OrganizationInvitation>();
  const [error, setError] = useState<string>();
  useEffect(() => {
    void json<OrganizationInvitation>(`/api/auth/organization/get-invitation?id=${encodeURIComponent(invitationId)}`)
      .then(setInvitation)
      .catch((caught: Error) => setError(caught.message));
  }, [invitationId]);

  async function decide(accept: boolean) {
    try {
      await json(`/api/auth/organization/${accept ? "accept" : "reject"}-invitation`, {
        method: "POST",
        body: JSON.stringify({ invitationId }),
      });
      navigateDashboard("/organizations");
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Could not update invitation");
    }
  }

  return (
    <>
      <PageHeader title="Organization invitation" />
      <section className="panel invitation-card">
        {!invitation && !error && <p className="muted">Loading invitation…</p>}
        {invitation && (
          <>
            <h2>Join {invitation.organizationName}</h2>
            <p>You were invited as {invitation.role}. This link expires {new Date(invitation.expiresAt).toLocaleString()}.</p>
            <div className="button-row">
              <button className="secondary" onClick={() => void decide(false)}>Decline</button>
              <button className="primary" onClick={() => void decide(true)}>Accept invitation</button>
            </div>
          </>
        )}
        {error && <p className="error">{error}</p>}
      </section>
    </>
  );
}

export function canEmbedArtifact(contentType: string): boolean {
  const type = contentType.split(";", 1)[0]!.trim().toLowerCase();
  return type.startsWith("text/")
    || type.startsWith("image/")
    || type.startsWith("audio/")
    || type.startsWith("video/")
    || ["application/json", "application/pdf", "application/xml", "application/xhtml+xml"].includes(type);
}

function AdminMembers() {
  const [members, setMembers] = useState<AdminMember[]>();
  const [email, setEmail] = useState("");
  const [error, setError] = useState<string>();
  const load = useCallback(() => {
    setError(undefined);
    void json<AdminMember[]>("/api/admin/members").then(setMembers).catch((caught: Error) => setError(caught.message));
  }, []);
  useEffect(load, [load]);

  async function add(event: React.FormEvent) {
    event.preventDefault();
    setError(undefined);
    try {
      await json("/api/admin/members", { method: "POST", body: JSON.stringify({ email }) });
      setEmail("");
      load();
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Could not add administrator");
    }
  }

  async function remove(member: AdminMember) {
    if (!window.confirm(`Remove administrator access for ${member.email}?`)) return;
    try {
      await json(`/api/admin/members/${encodeURIComponent(member.email)}`, { method: "DELETE" });
      load();
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Could not remove administrator");
    }
  }

  return (
    <>
      <PageHeader title="Members" />
      <section className="section-block">
        <h2 className="section-label">Administrators</h2>
        <div className="panel admin-list">
          {!members && !error && <p className="muted">Loading administrators…</p>}
          {members?.length === 0 && <div className="empty-state"><strong>No administrators</strong><span>Add an email below.</span></div>}
          {members?.map((member) => (
            <div className="admin-row member-row" key={member.id}>
              <div><strong>{member.email}</strong><span>{member.name} · Admin</span></div>
              <button className="secondary danger-button" disabled={!member.removable} onClick={() => void remove(member)}>Remove</button>
            </div>
          ))}
        </div>
      </section>
      <section className="section-block">
        <h2 className="section-label">Add administrator</h2>
        <form className="panel admin-form member-form" onSubmit={(event) => void add(event)}>
          <label>Email<input type="email" value={email} required placeholder="admin@example.com" onChange={(event) => setEmail(event.target.value)} /></label>
          <button className="primary">Add administrator</button>
        </form>
      </section>
      {error && <p className="error page-error admin-error">{error}</p>}
    </>
  );
}

function DashboardRedirect({ path }: { path: string }) {
  useEffect(() => navigateDashboard(path, true), [path]);
  return null;
}

function DataError({ error, retry }: { error?: Error; retry: () => void }) {
  return error ? <p className="error" role="alert">{error.message} <button onClick={retry}>{uiText("Retry", "再試行")}</button></p> : null;
}

export function App({ brand = defaultBrand, extensions = [] }: AppProps) {
  const [path, setPath] = useState(window.location.pathname);
  const needsSession = path !== "/sign-in" && path !== "/oauth/consent";
  const [session, setSession] = useState<SessionInfo>();
  const [sessionError, setSessionError] = useState<string>();
  const [unauthorized, setUnauthorized] = useState(false);
  const [sessionAttempt, setSessionAttempt] = useState(0);

  useEffect(() => {
    if (!needsSession) return;
    const sessionExpired = () => setUnauthorized(true);
    const refreshSession = () => setSessionAttempt((attempt) => attempt + 1);
    window.addEventListener("dahlia:unauthorized", sessionExpired);
    window.addEventListener(clientMutationEvent, refreshSession);
    return () => {
      window.removeEventListener("dahlia:unauthorized", sessionExpired);
      window.removeEventListener(clientMutationEvent, refreshSession);
    };
  }, [needsSession]);

  useEffect(() => {
    if (unauthorized) window.location.replace(`/sign-in?next=${encodeURIComponent(path)}`);
  }, [unauthorized, path]);

  useEffect(() => {
    const followHistory = () => setPath(window.location.pathname);
    window.addEventListener("popstate", followHistory);
    return () => window.removeEventListener("popstate", followHistory);
  }, []);

  useEffect(() => {
    if (!needsSession) return;
    const controller = new AbortController();
    setSessionError(undefined);
    void json<SessionInfo>("/api/session", { signal: controller.signal })
      .then((value) => { if (!controller.signal.aborted) setSession(value); })
      .catch((caught: unknown) => {
        if (controller.signal.aborted) return;
        if (shouldRedirectToSignIn(caught instanceof RequestError ? caught.status : undefined)) {
          setUnauthorized(true);
          return;
        }
        setSessionError(caught instanceof Error ? caught.message : "Could not load your account");
      });
    return () => controller.abort();
  }, [needsSession, sessionAttempt]);

  const syncEnabled = session?.capabilities.sync;
  const userId = session?.user.id;
  useEffect(() => {
    if (!needsSession || unauthorized || !userId || !syncEnabled) return;
    return subscribeLiveUpdates();
  }, [needsSession, unauthorized, userId, syncEnabled]);

  if (path === "/sign-in") return <SignIn brand={brand} />;
  if (path === "/oauth/consent") return <Consent brand={brand} />;
  if (unauthorized) return null;
  if (sessionError && !session) {
    return (
      <main className="loading">
        <Brand brand={brand} />
        <span>{sessionError}</span>
        <button className="secondary" onClick={() => setSessionAttempt((attempt) => attempt + 1)}>Try again</button>
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
  else if (route.page === "admin-members") page = <AdminMembers />;
  else if (route.page === "vaults") page = <Vaults />;
  else if (route.page === "vault") page = <VaultMeetings session={session} vaultId={route.vaultId!} />;
  else if (route.page === "meeting") page = <SyncedMeeting vaultId={route.vaultId!} meetingId={route.meetingId!} />;
  else if (route.page === "project") page = <SyncedProject vaultId={route.vaultId!} projectId={route.projectId!} />;
  else if (route.page === "organizations") page = <Organizations session={session} />;
  else if (route.page === "invitation") page = <Invitation invitationId={route.invitationId!} />;
  else if (route.page === "settings") page = <Settings />;
  else page = <Overview session={session} />;
  return <Shell brand={brand} extensions={extensions} session={session} path={path} navigate={navigateDashboard}>
    <DataError error={sessionError ? new Error(sessionError) : undefined} retry={() => setSessionAttempt((attempt) => attempt + 1)} />
    {page}
  </Shell>;
}
