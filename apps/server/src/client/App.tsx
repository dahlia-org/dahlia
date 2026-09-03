import { createAuthClient } from "better-auth/react";
import { useCallback, useEffect, useMemo, useState, type ComponentType, type ReactNode } from "react";

import {
  artifactViewerId,
  isCoreDashboardPath,
  resolveDashboardRoute,
  shouldRedirectToSignIn,
  type DashboardCapabilities,
} from "./routes";
import { filterAndSortModels, type ModelAliasInfo } from "./model-list";
import { UPSTREAM_MODEL_MAX_LENGTH } from "../ai-gateway/model-alias";

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
const artifactMetadataMediaType = "application/vnd.dahlia.artifact+json";

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

interface ArtifactInfo {
  id: string;
  visibility: "private" | "public";
  contentType: string;
  createdAt: string;
  updatedAt: string;
}

interface ArtifactPage {
  items: ArtifactInfo[];
  nextCursor?: string;
}

interface SyncedVaultInfo {
  vaultId: string;
  name: string;
  role: "owner" | "member";
  createdAt: string;
  updatedAt: string;
}

interface OrganizationInfo {
  id: string;
  name: string;
  slug: string;
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

interface SyncedMeetingInfo {
  meetingId: string;
  vaultId: string;
  projectId?: string;
  name: string;
  description: string;
  status: string;
  duration?: number;
  recordingStartedAt?: string;
  createdAt: string;
  updatedAt: string;
  summaryTitle?: string;
  summaryDocument?: string;
}

interface SyncedMeetingPage {
  items: SyncedMeetingInfo[];
  nextCursor?: string;
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

interface SyncedProjectInfo {
  projectId: string;
  vaultId: string;
  parentProjectId?: string;
  name: string;
  description: string;
  projectType?: "customer" | "internal" | "personal" | "undefined";
  effectiveType: "customer" | "internal" | "personal" | "undefined";
  revision: number;
  path: string;
  directMeetingCount: number;
  subtreeMeetingCount: number;
}

interface SyncedScreenshotInfo {
  screenshotId: string;
  capturedAt: string;
  contentType: string;
  ocrText?: string;
  caption?: string;
}

class RequestError extends Error {
  constructor(message: string, readonly status?: number) {
    super(message);
  }
}

async function json<T>(url: string, init?: RequestInit): Promise<T> {
  const response = await fetch(url, {
    ...init,
    headers: init?.body ? { "content-type": "application/json", ...init.headers } : init?.headers,
  });
  if (!response.ok) {
    const detail = (await response.json().catch(() => null)) as {
      message?: string;
      error?: string | { message?: string };
    } | null;
    const error = typeof detail?.error === "string" ? detail.error : detail?.error?.message;
    throw new RequestError(
      detail?.message || error || `Request failed (${response.status})`,
      response.status,
    );
  }
  return (response.status === 204 ? undefined : await response.json()) as T;
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
}: {
  brand: DashboardBrand;
  children: ReactNode;
  extensions: readonly DashboardExtension[];
  session: SessionInfo;
}) {
  const route = window.location.pathname;
  return (
    <div className="app-shell">
      <aside className="sidebar">
        <Brand brand={brand} />
        <nav aria-label="Account navigation">
          <a className={route === "/dashboard" ? "active" : ""} href="/dashboard">Overview</a>
          <a className={route === "/artifacts" ? "active" : ""} href="/artifacts">Artifacts</a>
          {session.capabilities.sync && (
            <a className={route.startsWith("/vaults") ? "active" : ""} href="/vaults">Vaults</a>
          )}
          {session.capabilities.sharing && (
            <a className={route === "/organizations" ? "active" : ""} href="/organizations">Organizations</a>
          )}
          {extensions.flatMap((extension) => extension.navigation ?? []).map((item) => (
            (!item.capability || session.capabilities[item.capability])
              ? <a className={route === item.path ? "active" : ""} href={item.path} key={item.path}>{item.label}</a>
              : null
          ))}
          {session.capabilities.sessions && (
            <a className={route === "/dashboard/settings" ? "active" : ""} href="/dashboard/settings">
              Settings
            </a>
          )}
          {session.capabilities.admin && (
            <>
              <span className="nav-divider" />
              <a className={route === "/admin/models" ? "active" : ""} href="/admin/models">Models</a>
              <a className={route === "/admin/members" ? "active" : ""} href="/admin/members">Members</a>
            </>
          )}
        </nav>
        <div className="sidebar-footer">
          <span className="avatar">
            {(session.user.name || session.user.email || session.user.id).slice(0, 1).toUpperCase()}
          </span>
          <span className="identity-copy">
            <strong>{session.user.name || session.user.email || session.user.id}</strong>
            <small>Personal account</small>
          </span>
        </div>
      </aside>
      <main className="workspace">{children}</main>
    </div>
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

function Artifacts() {
  const [artifacts, setArtifacts] = useState<ArtifactInfo[]>();
  const [nextCursor, setNextCursor] = useState<string>();
  const [error, setError] = useState<string>();
  const [loadingMore, setLoadingMore] = useState(false);

  const load = useCallback(async (cursor?: string) => {
    setError(undefined);
    if (cursor) setLoadingMore(true);
    try {
      const page = await json<ArtifactPage>(`/api/v1/artifacts${cursor ? `?cursor=${encodeURIComponent(cursor)}` : ""}`);
      setArtifacts((current) => cursor ? [...(current ?? []), ...page.items] : page.items);
      setNextCursor(page.nextCursor);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Could not load artifacts");
    } finally {
      setLoadingMore(false);
    }
  }, []);
  useEffect(() => { void load(); }, [load]);

  return (
    <>
      <PageHeader title="Artifacts" />
      <section className="section-block">
        <h2 className="section-label">Exported artifacts</h2>
        <div className="panel artifact-list">
          {!artifacts && !error && <p className="muted">Loading artifacts…</p>}
          {artifacts?.length === 0 && (
            <div className="empty-state">
              <strong>No artifacts yet</strong><span>Artifacts exported by your AI will appear here.</span>
            </div>
          )}
          {artifacts?.map((artifact) => (
            <a className="artifact-row" href={`/artifacts/${artifact.id}`} key={artifact.id}>
              <span className="artifact-copy">
                <strong>{artifact.id}</strong>
                <span>{artifact.contentType} · Updated {new Date(artifact.updatedAt).toLocaleString()}</span>
              </span>
              <span className={`status ${artifact.visibility === "public" ? "good" : ""}`}>
                {artifact.visibility}
              </span>
            </a>
          ))}
        </div>
        {error && <p className="error artifact-error">{error}</p>}
        {nextCursor && (
          <button className="secondary load-more" disabled={loadingMore} onClick={() => void load(nextCursor)}>
            {loadingMore ? "Loading…" : "Load more"}
          </button>
        )}
      </section>
    </>
  );
}

function Vaults() {
  const [vaults, setVaults] = useState<SyncedVaultInfo[]>();
  const [error, setError] = useState<string>();
  useEffect(() => {
    void json<{ items: SyncedVaultInfo[] }>("/api/v1/vaults")
      .then(({ items }) => setVaults(items))
      .catch((caught: Error) => setError(caught.message));
  }, []);
  return (
    <>
      <PageHeader title="Vaults" />
      <section className="section-block">
        <h2 className="section-label">Synchronized Vaults</h2>
        <div className="panel artifact-list">
          {!vaults && !error && <p className="muted">Loading Vaults…</p>}
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
  const [permissions, setPermissions] = useState<VaultPermissionInfo[]>();
  const [organizations, setOrganizations] = useState<OrganizationInfo[]>([]);
  const [teams, setTeams] = useState<TeamInfo[]>([]);
  const [error, setError] = useState<string>();
  const load = useCallback(async () => {
    setError(undefined);
    try {
      const [{ items }, organizationItems] = await Promise.all([
        json<{ items: VaultPermissionInfo[] }>(`/api/v1/vaults/${vault.vaultId}/permissions`),
        session.capabilities.sessions
          ? json<OrganizationInfo[]>("/api/auth/organization/list")
          : json<OrganizationInfo[]>("/api/v1/organizations"),
      ]);
      const teamItems = (await Promise.all(organizationItems.map((organization) =>
        session.capabilities.sessions
          ? json<TeamInfo[]>(`/api/auth/organization/list-teams?organizationId=${encodeURIComponent(organization.id)}`)
          : json<TeamInfo[]>(`/api/v1/organizations/${encodeURIComponent(organization.id)}/teams`)
      ))).flat();
      setPermissions(items);
      setOrganizations(organizationItems);
      setTeams(teamItems);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Could not load sharing settings");
    }
  }, [session.capabilities.sessions, vault.vaultId]);
  useEffect(() => { void load(); }, [load]);

  async function toggle(principalType: "organization" | "team", principalId: string, enabled: boolean) {
    setError(undefined);
    try {
      const target = `${principalType === "organization" ? "organizations" : "teams"}/${encodeURIComponent(principalId)}`;
      await json(`/api/v1/vaults/${vault.vaultId}/permissions/${target}`, {
        method: enabled ? "PUT" : "DELETE",
      });
      await load();
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
        {!permissions && !error && <p className="muted">Loading sharing settings…</p>}
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
      {error && <p className="error artifact-error">{error}</p>}
    </section>
  );
}

function VaultMeetings({ session, vaultId }: { session: SessionInfo; vaultId: string }) {
  const [vault, setVault] = useState<SyncedVaultInfo>();
  const [projects, setProjects] = useState<SyncedProjectInfo[]>([]);
  const [meetings, setMeetings] = useState<SyncedMeetingInfo[]>();
  const [query, setQuery] = useState("");
  const [projectId, setProjectId] = useState("");
  const [nextCursor, setNextCursor] = useState<string>();
  const [loadingMore, setLoadingMore] = useState(false);
  const [error, setError] = useState<string>();
  const loadMeetings = useCallback(async (cursor?: string, signal?: AbortSignal) => {
    const params = new URLSearchParams();
    if (query) params.set("q", query);
    if (projectId) params.set("projectId", projectId);
    if (cursor) params.set("cursor", cursor);
    if (cursor) setLoadingMore(true);
    try {
      const page = await json<SyncedMeetingPage>(
        `/api/v1/vaults/${vaultId}/meetings${params.size ? `?${params}` : ""}`,
        { signal },
      );
      setError(undefined);
      setMeetings((current) => cursor ? [...(current ?? []), ...page.items] : page.items);
      setNextCursor(page.nextCursor);
    } catch (caught) {
      if (caught instanceof Error && caught.name !== "AbortError") setError(caught.message);
    } finally {
      setLoadingMore(false);
    }
  }, [projectId, query, vaultId]);
  useEffect(() => {
    const controller = new AbortController();
    const timer = setTimeout(() => void loadMeetings(undefined, controller.signal), 250);
    return () => {
      clearTimeout(timer);
      controller.abort();
    };
  }, [loadMeetings]);
  useEffect(() => {
    void Promise.all([
      json<SyncedVaultInfo>(`/api/v1/vaults/${vaultId}`),
      json<{ items: SyncedProjectInfo[] }>(`/api/v1/vaults/${vaultId}/projects`),
    ]).then(([vaultValue, projectPage]) => {
      setVault(vaultValue);
      setProjects(projectPage.items);
    })
      .catch((caught: Error) => setError(caught.message));
  }, [vaultId]);
  return (
    <>
      <PageHeader title={vault?.name ?? "Vault"} />
      <section className="section-block">
        <a className="secondary viewer-back" href="/vaults">All Vaults</a>
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
          <button className="secondary load-more" disabled={loadingMore} onClick={() => void loadMeetings(nextCursor)}>
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
  const [project, setProject] = useState<SyncedProjectInfo>();
  const [meetings, setMeetings] = useState<SyncedMeetingInfo[]>([]);
  const [nextCursor, setNextCursor] = useState<string>();
  const [loadingMore, setLoadingMore] = useState(false);
  const [error, setError] = useState<string>();
  const loadMeetings = useCallback(async (cursor?: string, signal?: AbortSignal) => {
    const params = new URLSearchParams({ projectId });
    if (cursor) params.set("cursor", cursor);
    if (cursor) setLoadingMore(true);
    try {
      const page = await json<SyncedMeetingPage>(`/api/v1/vaults/${vaultId}/meetings?${params}`, { signal });
      setMeetings((current) => cursor ? [...current, ...page.items] : page.items);
      setNextCursor(page.nextCursor);
    } catch (caught) {
      if (caught instanceof Error && caught.name !== "AbortError") setError(caught.message);
    } finally {
      setLoadingMore(false);
    }
  }, [projectId, vaultId]);
  useEffect(() => {
    const controller = new AbortController();
    void json<SyncedProjectInfo>(`/api/v1/vaults/${vaultId}/projects/${projectId}`, { signal: controller.signal })
      .then(setProject).catch((caught: Error) => {
      if (caught.name !== "AbortError") setError(caught.message);
    });
    void loadMeetings(undefined, controller.signal);
    return () => controller.abort();
  }, [loadMeetings, projectId, vaultId]);
  return <>
    <PageHeader title={project?.path ?? "Project"} />
    <a className="secondary viewer-back" href={`/vaults/${vaultId}`}>Back to Vault</a>
    {error && <p className="error">{error}</p>}
    {project && <section className="section-block"><div className="panel meeting-content">
      {project.description && <p>{project.description}</p>}
      <p className="muted">{project.effectiveType} · revision {project.revision} · {project.subtreeMeetingCount} meetings</p>
    </div></section>}
    <section className="section-block"><h2 className="section-label">Meetings</h2><div className="panel artifact-list">
      {meetings.length === 0 && <div className="empty-state"><strong>No meetings</strong></div>}
      {meetings.map((meeting) => <a className="artifact-row" href={`/vaults/${vaultId}/meetings/${meeting.meetingId}`} key={meeting.meetingId}>
        <span className="artifact-copy"><strong>{meeting.name}</strong><span>{new Date(meeting.createdAt).toLocaleString()}</span></span>
      </a>)}
    </div></section>
    {nextCursor && (
      <button className="secondary load-more" disabled={loadingMore} onClick={() => void loadMeetings(nextCursor)}>
        {loadingMore ? "Loading…" : "Load more"}
      </button>
    )}
  </>;
}

function SyncedMeeting({ vaultId, meetingId }: { vaultId: string; meetingId: string }) {
  const base = `/api/v1/vaults/${vaultId}/meetings/${meetingId}`;
  const [meeting, setMeeting] = useState<SyncedMeetingInfo>();
  const [transcript, setTranscript] = useState<SyncedTranscriptSegmentInfo[]>();
  const [screenshots, setScreenshots] = useState<SyncedScreenshotInfo[]>();
  const [error, setError] = useState<string>();
  useEffect(() => {
    const controller = new AbortController();
    void Promise.all([
      json<SyncedMeetingInfo>(base, { signal: controller.signal }),
      json<{ items: SyncedTranscriptSegmentInfo[] }>(`${base}/transcript`, { signal: controller.signal }),
      json<{ items: SyncedScreenshotInfo[] }>(`${base}/screenshots`, { signal: controller.signal }),
    ]).then(([meetingValue, transcriptPage, screenshotPage]) => {
      setMeeting(meetingValue);
      setTranscript(transcriptPage.items);
      setScreenshots(screenshotPage.items);
    }).catch((caught: Error) => {
      if (caught.name !== "AbortError") setError(caught.message);
    });
    return () => controller.abort();
  }, [base]);
  return (
    <>
      <PageHeader title={meeting?.name ?? "Meeting"} />
      <a className="secondary viewer-back" href={`/vaults/${vaultId}`}>All meetings</a>
      {error && <p className="error">{error}</p>}
      {!meeting && !error && <p className="muted">Loading meeting…</p>}
      {meeting?.summaryDocument && (
        <section className="section-block">
          <h2 className="section-label">{meeting.summaryTitle || "Summary"}</h2>
          <div className="panel meeting-content"><pre>{meeting.summaryDocument}</pre></div>
        </section>
      )}
      {transcript && (
        <section className="section-block">
          <h2 className="section-label">Transcript</h2>
          <div className="panel meeting-content">
            {transcript.slice(0, 500).map((segment) => (
              <p key={segment.segmentId}>
                {segment.speakerLabel && <strong>{segment.speakerLabel}: </strong>}{segment.text}
              </p>
            ))}
            {transcript.length > 500 && <p className="muted">Showing the first 500 transcript segments.</p>}
          </div>
        </section>
      )}
      {screenshots && screenshots.length > 0 && (
        <section className="section-block">
          <h2 className="section-label">Screenshots</h2>
          <div className="screenshot-grid">
            {screenshots.map((screenshot) => (
              <figure className="panel" key={screenshot.screenshotId}>
                <img
                  src={`${base}/screenshots/${screenshot.screenshotId}/content`}
                  alt={screenshot.caption || ""}
                  loading="lazy"
                />
                {(screenshot.caption || screenshot.ocrText) && <figcaption>{screenshot.caption || screenshot.ocrText}</figcaption>}
              </figure>
            ))}
          </div>
        </section>
      )}
    </>
  );
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
      window.location.assign("/organizations");
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

function ArtifactViewer({ brand, id }: { brand: DashboardBrand; id: string }) {
  const [artifact, setArtifact] = useState<ArtifactInfo>();
  const [loadError, setLoadError] = useState<Error>();
  const [signInError, setSignInError] = useState<string>();
  const load = useCallback(async () => {
    setLoadError(undefined);
    try {
      setArtifact(await json<ArtifactInfo>(`/api/v1/artifacts/${encodeURIComponent(id)}`, {
        headers: { accept: artifactMetadataMediaType },
      }));
    } catch (caught) {
      setLoadError(caught instanceof Error ? caught : new Error("Could not load artifact"));
    }
  }, [id]);
  useEffect(() => { void load(); }, [load]);

  const contentURL = `/api/v1/artifacts/${encodeURIComponent(id)}/content`;
  const requiresSignIn = loadError instanceof RequestError && loadError.status === 401;
  return (
    <main className="artifact-viewer">
      <header className="viewer-header">
        <Brand brand={brand} />
        <a className="secondary viewer-back" href="/artifacts">All artifacts</a>
      </header>
      {!artifact && !loadError && <div className="viewer-state muted">Loading artifact…</div>}
      {requiresSignIn && (
        <div className="viewer-state panel">
          <strong>Sign in to view this artifact</strong>
          <span>This artifact is private.</span>
          <button className="primary" onClick={() => void beginSignIn(window.location.pathname).then(setSignInError)}>
            Continue with Google
          </button>
          {signInError && <span className="error">{signInError}</span>}
        </div>
      )}
      {loadError && !requiresSignIn && (
        <div className="viewer-state panel">
          <strong>Artifact unavailable</strong><span>{loadError.message}</span>
          <button className="secondary" onClick={() => void load()}>Try again</button>
        </div>
      )}
      {artifact && (
        <>
          <section className="viewer-title">
            <div>
              <span className="eyebrow">{artifact.visibility} artifact</span>
              <h1>{artifact.id}</h1>
              <p>{artifact.contentType} · Updated {new Date(artifact.updatedAt).toLocaleString()}</p>
            </div>
            <a className="secondary" href={contentURL} download={artifact.id}>Download</a>
          </section>
          {canEmbedArtifact(artifact.contentType)
            ? <iframe className="artifact-frame" src={contentURL} sandbox="allow-scripts" title={`Artifact ${artifact.id}`} />
            : (
                <div className="viewer-state panel">
                  <strong>Preview unavailable</strong>
                  <span>Download this artifact to open it in a compatible application.</span>
                </div>
              )}
        </>
      )}
    </main>
  );
}

function ModelAliasRow({ model, reload }: { model: ModelAliasInfo; reload: () => void }) {
  const [upstreamModel, setUpstreamModel] = useState(model.upstreamModel);
  const [displayName, setDisplayName] = useState(model.displayName || "");
  const [enabled, setEnabled] = useState(model.enabled);
  const [error, setError] = useState<string>();
  const [pending, setPending] = useState(false);

  async function save(event: React.FormEvent) {
    event.preventDefault();
    setPending(true);
    setError(undefined);
    try {
      await json(`/api/admin/models/${model.alias}`, {
        method: "PATCH",
        body: JSON.stringify({ upstreamModel, displayName: displayName.trim() || null, enabled }),
      });
      reload();
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Could not update model");
    } finally {
      setPending(false);
    }
  }

  async function remove() {
    if (!window.confirm(`Delete model alias '${model.alias}'?`)) return;
    setPending(true);
    setError(undefined);
    try {
      await json(`/api/admin/models/${model.alias}`, { method: "DELETE" });
      reload();
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Could not delete model");
      setPending(false);
    }
  }

  return (
    <form className="admin-row model-row" onSubmit={(event) => void save(event)}>
      <div className="admin-row-heading">
        <strong>{model.alias}</strong>
        <label className="toggle-field">
          <input type="checkbox" checked={enabled} onChange={(event) => setEnabled(event.target.checked)} />
          Enabled
        </label>
      </div>
      <label>Upstream model<input value={upstreamModel} required maxLength={UPSTREAM_MODEL_MAX_LENGTH} onChange={(event) => setUpstreamModel(event.target.value)} /></label>
      <label>Display name<input value={displayName} maxLength={100} placeholder={model.alias} onChange={(event) => setDisplayName(event.target.value)} /></label>
      <div className="row-actions">
        <button className="secondary danger-button" type="button" disabled={pending} onClick={() => void remove()}>Delete</button>
        <button className="secondary" disabled={pending}>Save</button>
      </div>
      {error && <p className="error">{error}</p>}
    </form>
  );
}

function DatabricksModelRow({
  model,
  onUpdated,
}: {
  model: ModelAliasInfo;
  onUpdated: (enabled: boolean) => void;
}) {
  const [configured, setConfigured] = useState(model.configured ?? true);
  const [enabled, setEnabled] = useState(model.enabled);
  const [error, setError] = useState<string>();
  const [pending, setPending] = useState(false);

  async function toggle(nextEnabled: boolean) {
    const previousEnabled = enabled;
    setEnabled(nextEnabled);
    setPending(true);
    setError(undefined);
    try {
      await json(configured ? `/api/admin/models/${model.alias}` : "/api/admin/models", {
        method: configured ? "PATCH" : "POST",
        body: JSON.stringify({
          ...(configured ? {} : { alias: model.alias }),
          upstreamModel: model.upstreamModel,
          displayName: model.displayName,
          enabled: nextEnabled,
        }),
      });
      setConfigured(true);
      onUpdated(nextEnabled);
    } catch (caught) {
      setEnabled(previousEnabled);
      setError(caught instanceof Error ? caught.message : "Could not update model");
    } finally {
      setPending(false);
    }
  }

  return (
    <div className="admin-row provider-model-row">
      <div className="provider-model-copy">
        <strong>{model.displayName || model.alias}</strong>
        <span>{model.upstreamModel}</span>
      </div>
      <label className="switch-field">
        <input
          type="checkbox"
          role="switch"
          aria-label={`Enable ${model.upstreamModel}`}
          checked={enabled}
          disabled={pending}
          onChange={(event) => void toggle(event.target.checked)}
        />
        <span className="switch-control" aria-hidden="true" />
        <span>{enabled ? "Enabled" : "Disabled"}</span>
      </label>
      {error && <p className="error">{error}</p>}
    </div>
  );
}

function AdminModels({ databricksModels }: { databricksModels: boolean }) {
  const [models, setModels] = useState<ModelAliasInfo[]>();
  const [alias, setAlias] = useState("");
  const [upstreamModel, setUpstreamModel] = useState("");
  const [displayName, setDisplayName] = useState("");
  const [query, setQuery] = useState("");
  const [error, setError] = useState<string>();
  const load = useCallback(() => {
    setError(undefined);
    void json<ModelAliasInfo[]>("/api/admin/models").then(setModels).catch((caught: Error) => setError(caught.message));
  }, []);
  useEffect(load, [load]);

  async function create(event: React.FormEvent) {
    event.preventDefault();
    setError(undefined);
    try {
      await json("/api/admin/models", {
        method: "POST",
        body: JSON.stringify({ alias, upstreamModel, displayName: displayName.trim() || null, enabled: true }),
      });
      setAlias("");
      setUpstreamModel("");
      setDisplayName("");
      load();
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Could not add model");
    }
  }

  function updateModel(upstreamModel: string, enabled: boolean) {
    setModels((current) => current?.map((model) => model.upstreamModel === upstreamModel
      ? { ...model, configured: true, enabled }
      : model));
  }

  const displayedModels = models && filterAndSortModels(models, query);

  return (
    <>
      <PageHeader title="Models" />
      <section className="section-block">
        <h2 className="section-label">{databricksModels ? "Available models" : "Model aliases"}</h2>
        {models && models.length > 0 && (
          <input
            className="model-search"
            type="search"
            aria-label="Search models"
            placeholder="Search models"
            value={query}
            onChange={(event) => setQuery(event.target.value)}
          />
        )}
        <div className="panel admin-list">
          {!models && !error && <p className="muted">Loading models…</p>}
          {models?.length === 0 && (
            <div className="empty-state">
              <strong>{databricksModels ? "No models available" : "No models configured"}</strong>
              {!databricksModels && <span>Add an alias below.</span>}
            </div>
          )}
          {models && models.length > 0 && displayedModels?.length === 0 && (
            <div className="empty-state"><strong>No models match your search</strong></div>
          )}
          {displayedModels?.map((model) => databricksModels
            ? <DatabricksModelRow
                key={model.upstreamModel}
                model={model}
                onUpdated={(enabled) => updateModel(model.upstreamModel, enabled)}
              />
            : <ModelAliasRow key={model.alias} model={model} reload={load} />)}
        </div>
      </section>
      {!databricksModels && (
        <section className="section-block">
          <h2 className="section-label">Add model</h2>
          <form className="panel admin-form" onSubmit={(event) => void create(event)}>
            <label>Alias<input value={alias} required pattern="[a-z0-9][a-z0-9._-]{0,254}" maxLength={255} placeholder="gpt-5.6-luna" onChange={(event) => setAlias(event.target.value)} /></label>
            <label>Upstream model<input value={upstreamModel} required maxLength={UPSTREAM_MODEL_MAX_LENGTH} placeholder="openai/gpt-5.6-luna" onChange={(event) => setUpstreamModel(event.target.value)} /></label>
            <label>Display name<input value={displayName} maxLength={100} placeholder="Optional" onChange={(event) => setDisplayName(event.target.value)} /></label>
            <button className="primary">Add model</button>
          </form>
        </section>
      )}
      {error && <p className="error page-error admin-error">{error}</p>}
    </>
  );
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

export function App({ brand = defaultBrand, extensions = [] }: AppProps) {
  const path = window.location.pathname;
  const viewerId = artifactViewerId(path);
  const [session, setSession] = useState<SessionInfo>();
  const [sessionError, setSessionError] = useState<string>();
  const [unauthorized, setUnauthorized] = useState(false);
  const [sessionAttempt, setSessionAttempt] = useState(0);

  useEffect(() => {
    if (path === "/sign-in" || path === "/oauth/consent" || viewerId) return;
    setSessionError(undefined);
    void json<SessionInfo>("/api/session")
      .then(setSession)
      .catch((caught: unknown) => {
        if (shouldRedirectToSignIn(caught instanceof RequestError ? caught.status : undefined)) {
          setUnauthorized(true);
          return;
        }
        setSessionError(caught instanceof Error ? caught.message : "Could not load your account");
      });
  }, [path, sessionAttempt, viewerId]);

  if (path === "/sign-in") return <SignIn brand={brand} />;
  if (path === "/oauth/consent") return <Consent brand={brand} />;
  if (viewerId) return <ArtifactViewer brand={brand} id={viewerId} />;
  if (unauthorized) {
    window.location.replace(`/sign-in?next=${encodeURIComponent(path)}`);
    return null;
  }
  if (sessionError) {
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
  if (!extension.allowed) {
    window.location.replace("/dashboard");
    return null;
  }
  const extensionRoute = extension.route;
  const route = extensionRoute ? {} : resolveDashboardRoute(path, session.capabilities);
  if (route.redirect) {
    window.location.replace(route.redirect);
    return null;
  }

  let page: ReactNode;
  if (extensionRoute) {
    const ExtensionPage = extensionRoute.component;
    page = <ExtensionPage session={session} />;
  } else if (route.page === "admin-models") {
    page = <AdminModels databricksModels={session.capabilities.databricksModels === true} />;
  }
  else if (route.page === "admin-members") page = <AdminMembers />;
  else if (route.page === "artifacts") page = <Artifacts />;
  else if (route.page === "vaults") page = <Vaults />;
  else if (route.page === "vault") page = <VaultMeetings session={session} vaultId={route.vaultId!} />;
  else if (route.page === "meeting") page = <SyncedMeeting vaultId={route.vaultId!} meetingId={route.meetingId!} />;
  else if (route.page === "project") page = <SyncedProject vaultId={route.vaultId!} projectId={route.projectId!} />;
  else if (route.page === "organizations") page = <Organizations session={session} />;
  else if (route.page === "invitation") page = <Invitation invitationId={route.invitationId!} />;
  else if (route.page === "settings") page = <Settings />;
  else page = <Overview session={session} />;
  return <Shell brand={brand} extensions={extensions} session={session}>{page}</Shell>;
}
