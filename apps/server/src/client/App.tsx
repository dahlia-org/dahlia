import { createAuthClient } from "better-auth/react";
import { useCallback, useEffect, useState, type ComponentType, type ReactNode } from "react";

import { resolveDashboardRoute, shouldRedirectToSignIn, type DashboardCapabilities } from "./routes";

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

interface ModelAliasInfo {
  alias: string;
  upstreamModel: string;
  displayName: string | null;
  enabled: boolean;
}

interface AdminMember {
  email: string;
  role: "admin";
  source: "database" | "environment";
  removable: boolean;
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
    const detail = (await response.json().catch(() => null)) as { message?: string; error?: string } | null;
    throw new RequestError(
      detail?.message || detail?.error || `Request failed (${response.status})`,
      response.status,
    );
  }
  return (response.status === 204 ? undefined : await response.json()) as T;
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
    try {
      const callbackURL = window.location.search
        ? `/api/auth/oauth2/authorize${window.location.search}`
        : "/dashboard";
      const authClient = createAuthClient({ baseURL: window.location.origin });
      const result = await authClient.signIn.social({ provider: "google", callbackURL });
      if (result.error) setError(result.error.message || "Sign in failed");
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Sign in failed");
    }
  }

  return (
    <main className="auth-page">
      <section className="auth-card">
        <Brand brand={brand} />
        <div className="auth-copy">
          <span className="eyebrow">Personal AI gateway</span>
          <h1>Use the model configured for your Dahlia deployment.</h1>
          <p>
            Audio, transcripts, and local recordings stay on your Mac. {brand.name} {brand.product} only brokers
            Codex requests.
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
      <label>Upstream model<input value={upstreamModel} required maxLength={255} onChange={(event) => setUpstreamModel(event.target.value)} /></label>
      <label>Display name<input value={displayName} maxLength={100} placeholder={model.alias} onChange={(event) => setDisplayName(event.target.value)} /></label>
      <div className="row-actions">
        <button className="secondary danger-button" type="button" disabled={pending} onClick={() => void remove()}>Delete</button>
        <button className="secondary" disabled={pending}>Save</button>
      </div>
      {error && <p className="error">{error}</p>}
    </form>
  );
}

function AdminModels() {
  const [models, setModels] = useState<ModelAliasInfo[]>();
  const [alias, setAlias] = useState("");
  const [upstreamModel, setUpstreamModel] = useState("");
  const [displayName, setDisplayName] = useState("");
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

  return (
    <>
      <PageHeader title="Models" />
      <section className="section-block">
        <h2 className="section-label">Model aliases</h2>
        <div className="panel admin-list">
          {!models && !error && <p className="muted">Loading models…</p>}
          {models?.length === 0 && <div className="empty-state"><strong>No models configured</strong><span>Add an alias below.</span></div>}
          {models?.map((model) => <ModelAliasRow key={model.alias} model={model} reload={load} />)}
        </div>
      </section>
      <section className="section-block">
        <h2 className="section-label">Add model</h2>
        <form className="panel admin-form" onSubmit={(event) => void create(event)}>
          <label>Alias<input value={alias} required pattern="[a-z0-9][a-z0-9._-]{0,63}" maxLength={64} placeholder="gpt-5.6-luna" onChange={(event) => setAlias(event.target.value)} /></label>
          <label>Upstream model<input value={upstreamModel} required maxLength={255} placeholder="openai/gpt-5.6-luna" onChange={(event) => setUpstreamModel(event.target.value)} /></label>
          <label>Display name<input value={displayName} maxLength={100} placeholder="Optional" onChange={(event) => setDisplayName(event.target.value)} /></label>
          <button className="primary">Add model</button>
        </form>
      </section>
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
            <div className="admin-row member-row" key={`${member.source}-${member.email}`}>
              <div><strong>{member.email}</strong><span>Admin · {member.source === "environment" ? "Environment" : "Managed"}</span></div>
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
  const [session, setSession] = useState<SessionInfo>();
  const [sessionError, setSessionError] = useState<string>();
  const [unauthorized, setUnauthorized] = useState(false);
  const [sessionAttempt, setSessionAttempt] = useState(0);

  useEffect(() => {
    if (path === "/sign-in" || path === "/oauth/consent") return;
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
  }, [path, sessionAttempt]);

  if (path === "/sign-in") return <SignIn brand={brand} />;
  if (path === "/oauth/consent") return <Consent brand={brand} />;
  if (unauthorized) {
    window.location.replace("/sign-in");
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
  } else if (route.page === "admin-models") page = <AdminModels />;
  else if (route.page === "admin-members") page = <AdminMembers />;
  else if (route.page === "settings") page = <Settings />;
  else page = <Overview session={session} />;
  return <Shell brand={brand} extensions={extensions} session={session}>{page}</Shell>;
}
