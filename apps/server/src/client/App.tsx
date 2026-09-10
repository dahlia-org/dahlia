import { apiUrls } from "./generated-operations";
import { encodeId } from "../typeid";
import { apiOperations as api } from "./generated-operations";
import type { components } from "./generated-api";
import { apiQuery, mapQuery } from "./live-data";
import type { operations } from "./generated-api";
type ServerUserRecord = operations["listServerUsers"]["responses"][200]["content"]["application/json"]["items"][number];
type ServerOrganizationRecord = operations["listServerOrganizations"]["responses"][200]["content"]["application/json"]["items"][number];
import { Select } from "./Select";
import type { Appearance } from "../appearance-model";
import { collectionAppearance, AppearanceIcon, projectAppearance } from "./AppearancePicker";
import { useActionDialog } from "./ActionDialog";
import { TranscriptHistory } from "./TranscriptHistory";
import { SummaryHistory, type LatestSummary } from "./SummaryHistory";
import { ServerSummaryGeneration, ServerSummarySettings } from "./SummaryGeneration";
import { RecordingIndicator } from "./RecordingIndicator";
import { liveDataEvent, refreshData, subscribeLiveUpdates, useLiveJSON, useLivePage, useLiveQuery } from "./live-data";
import { createAuthClient } from "better-auth/react";
import { useCallback, useEffect, useMemo, useRef, useState, type ComponentType, type MouseEvent, type ReactNode } from "react";

import {
  isCoreDashboardPath,
  resolveDashboardRoute,
  shouldRedirectToSignIn,
  type DashboardCapabilities,
} from "./routes";
import { dashboardNavigationEvent, dashboardNavigationPath, navigateDashboard } from "./navigation";
import { summaryEditor } from "./summary-editor";
import { clientMutationEvent, json, RequestError, syncMessage, uiText, type SyncedVaultInfo, type OrganizationInfo, type SyncedMeetingInfo, type SyncedProjectInfo } from "./api";
import { DetailTabs, MeetingTabs, parseSummary, SummaryTags } from "./MeetingContent";
import { FileLink, FileViewer } from "./FileViewer";
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

function isServerNavigation(item: DashboardNavigationItem): boolean {
  return item.capability === "admin" || item.path.startsWith("/admin/");
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
  userAgent: string | null;
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



type SyncedScreenshotInfo = operations["listMeetingFiles"]["responses"][200]["content"]["application/json"]["items"][number];

type WithoutOperationId<T> = T extends unknown ? Omit<T, "id"> : never;
type SyncOperation = WithoutOperationId<components["schemas"]["Transaction"]["operations"][number]>;

export async function commitSyncTransaction(vaultId: string, operations: SyncOperation[], onRecovery: (active: boolean) => void = () => {}) {
  const transactionId = encodeId("transaction", uuidV7());
  const request = {
    body: {
      schemaVersion: 2 as const,
      id: transactionId,
      vaultId,
      createdAt: new Date().toISOString(),
      operations: operations.map((operation) => ({ ...operation, id: encodeId("operation", uuidV7()) })),
    },
  };
  type Receipt = { id: string; status: "committed" | "unknown"; receipt?: "full" | "compact" };
  try {
    let result: Receipt;
    try {
      result = await api.commitTransaction(request, false);
    } catch (error) {
      if (error instanceof RequestError && error.status && error.status < 500 && ![408, 410, 425, 429].includes(error.status)) throw error;
      onRecovery(true);
      let resolved: Receipt;
      try {
        resolved = await api.resolveTransaction(request, false);
      } catch (resolveError) {
        if (resolveError instanceof RequestError && resolveError.status === 404) {
          throw new RequestError(syncMessage("sync_upgrade_required")!, 426, { cause: resolveError });
        }
        throw resolveError;
      }
      if (resolved.id !== transactionId) throw new Error("Invalid transaction receipt", { cause: error });
      result = resolved.status === "unknown"
        ? await api.commitTransaction(request, false)
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
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string>();

  async function signIn() {
    if (pending) return;
    setPending(true);
    setError(undefined);
    const params = new URLSearchParams(window.location.search);
    const next = params.get("next");
    const safeNext = next?.startsWith("/") && !next.startsWith("//") ? next : undefined;
    const failure = await beginSignIn(safeNext ?? (params.has("client_id") ? `/api/auth/oauth2/authorize${window.location.search}` : "/dashboard"));
    if (failure) { setError(failure); setPending(false); }
  }

  return (
    <main className="auth-page">
      <section className="auth-card">
        <Brand brand={brand} />
        <div className="auth-copy">
          <span className="eyebrow">{uiText("Your meeting library", "ミーティングライブラリ")}</span>
          <h1>{uiText("Every conversation,\nwithin reach.", "会話の記録を、\nいつでも手元に。")}</h1>
          <p>{uiText("Find the decisions, details and next steps in your meetings. Sign in to access the Vaults you sync with Dahlia for macOS.", "ミーティングで決まったこと、話した内容、次のアクションをすぐに確認。macOS 版 Dahlia と同期した保管庫にアクセスできます。")}</p>
        </div>
        <button className="primary full" disabled={pending} onClick={() => void signIn()}>
          {pending ? uiText("Signing in…", "サインイン中…") : uiText("Continue with Google", "Google で続ける")}
        </button>
        {error && <p className="error">{error}</p>}
      </section>
    </main>
  );
}

function Consent({ brand }: { brand: DashboardBrand }) {
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string>();
  const oauthQuery = window.location.search.slice(1);

  async function decide(accept: boolean) {
    if (pending) return;
    setPending(true);
    setError(undefined);
    try {
      const result = await json<{ redirect_uri: string }>("/api/auth/oauth2/consent", {
        method: "POST",
        body: JSON.stringify({ accept, oauth_query: oauthQuery }),
      });
      window.location.assign(result.redirect_uri);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Consent failed");
    } finally {
      setPending(false);
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
          <button className="secondary" disabled={pending} onClick={() => void decide(false)}>{uiText("Cancel", "キャンセル")}</button>
          <button className="primary" disabled={pending} onClick={() => void decide(true)}>Allow</button>
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
  routeVaultId,
}: {
  brand: DashboardBrand;
  children: ReactNode;
  extensions: readonly DashboardExtension[];
  session: SessionInfo;
  path: string;
  navigate: (path: string) => void;
  routeVaultId?: string;
}) {
  const main = useRef<HTMLElement>(null);
  const navigation = useRef<HTMLDialogElement>(null);
  const attachNavigation = useCallback((element: HTMLDialogElement | null) => {
    navigation.current = element;
    if (element && !window.matchMedia("(max-width: 820px)").matches) element.show();
  }, []);
  const [compact, setCompact] = useState(() => window.matchMedia("(max-width: 820px)").matches);
  useEffect(() => {
    const media = window.matchMedia("(max-width: 820px)");
    const update = () => {
      navigation.current?.close();
      setCompact(media.matches);
      if (!media.matches) navigation.current?.show();
    };
    update();
    media.addEventListener("change", update);
    return () => media.removeEventListener("change", update);
  }, []);
  useEffect(() => {
    if (navigation.current?.matches(":modal")) navigation.current.close();
    main.current?.focus({ preventScroll: true });
    window.scrollTo(0, 0);
  }, [path]);
  useEffect(() => {
    const closeNavigation = () => {
      if (navigation.current?.matches(":modal")) navigation.current.close();
    };
    window.addEventListener(dashboardNavigationEvent, closeNavigation);
    return () => window.removeEventListener(dashboardNavigationEvent, closeNavigation);
  }, []);
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
        <a className="skip-link" href="#main-content">{uiText("Skip to content", "本文へ移動")}</a>
        <header className="mobile-header">
          <button className="icon-button" aria-label={uiText("Open navigation", "ナビゲーションを開く")} aria-controls="primary-navigation" onClick={() => navigation.current?.showModal()}><MenuIcon name="menu" /></button>
          <Brand brand={brand} />
        </header>
        <dialog ref={attachNavigation} id="primary-navigation" className="sidebar-container" aria-label={compact ? uiText("Navigation", "ナビゲーション") : undefined} role={compact ? "dialog" : "presentation"}
          onClick={(event) => { if (event.target === event.currentTarget && compact) event.currentTarget.close(); }}>
        <button className="icon-button navigation-close" aria-label={uiText("Close navigation", "ナビゲーションを閉じる")} onClick={() => navigation.current?.close()}>×</button>
        <Sidebar brand={<Brand brand={brand} />} session={session} routeVaultId={routeVaultId}
          serverLinks={extensions.flatMap((extension) => extension.navigation ?? []).filter(isServerNavigation).map((item) =>
            (!item.capability || session.capabilities[item.capability]) && <a key={item.path} href={item.path}><MenuIcon name="settings" />{item.label}</a>)}>
          <nav aria-label={uiText("Account navigation", "アカウント")}>
            <a className={path === "/dashboard/settings" ? "active" : ""} href="/dashboard/settings">
              <MenuIcon name="settings" />{uiText("Account settings", "アカウント設定")}
            </a>
          </nav>
        </Sidebar>
        </dialog>
        <main id="main-content" className="workspace" key={path} ref={main} tabIndex={-1}>{children}</main>
      </div>
    </SidebarProvider>
  );
}

function PageHeader({ title, description, actions }: { title: string; description?: string; actions?: ReactNode }) {
  return <header className="page-header"><div><h1>{title}</h1>{description && <p>{description}</p>}</div>{actions}</header>;
}

function Overview({ session }: { session: SessionInfo }) {
  if (session.capabilities.sync) return <Vaults home />;
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

function Settings({ session, extensions }: { session: SessionInfo; extensions: readonly DashboardExtension[] }) {
  const sessionsEnabled = session.capabilities.sessions;
  const { dialog, openDialog } = useActionDialog();
  const [sessions, setSessions] = useState<DeviceSession[]>();
  const [error, setError] = useState<string>();
  const load = useCallback(() => {
    setError(undefined);
    void api.listSessions({}).then(({ items }) => setSessions(items)).catch((caught: Error) => setError(caught.message));
  }, []);
  useEffect(() => { if (sessionsEnabled) load(); }, [load, sessionsEnabled]);

  function revoke(device: DeviceSession) {
    openDialog({
      title: uiText("Revoke this session?", "このセッションを解除しますか？"),
      description: device.current
        ? uiText("You will be signed out of this browser. Your meetings will remain available when you sign in again.", "このブラウザからサインアウトします。再度サインインすれば、ミーティングを引き続き閲覧できます。")
        : uiText("This device will need to sign in again. Existing access tokens may remain valid for up to 15 minutes.", "このデバイスでは再度サインインが必要になります。発行済みのアクセストークンは最大15分間有効な場合があります。"),
      confirmLabel: uiText("Revoke session", "セッションを解除"), destructive: true,
      onSubmit: async () => { await api.revokeSession({ params: { path: { id: device.id } } }); load(); },
    });
  }

  return (
    <>
      {dialog}
      <PageHeader title={uiText("Account settings", "アカウント設定")} description={uiText("Applies to every vault in this account and syncs across your devices.", "このアカウントのすべての保管庫に適用され、ほかの端末にも同期されます。")} />
      <section className="section-block settings-section">
        <h2 className="section-label">{uiText("Account", "アカウント")}</h2>
        <div className="panel account-card"><dl className="account-details">
          <div><dt>{uiText("Name", "名前")}</dt><dd>{session.user.name || "—"}</dd></div>
          <div><dt>{uiText("Email address", "メールアドレス")}</dt><dd>{session.user.email || "—"}</dd></div>
        </dl></div>
      </section>
      <ServerSummarySettings />
      {extensions.flatMap((extension) => extension.navigation ?? []).filter((item) => !isServerNavigation(item)).map((item) =>
        (!item.capability || session.capabilities[item.capability]) && <a className="text-link" key={item.path} href={item.path}><MenuIcon name="document" />{item.label}</a>)}
      {sessionsEnabled && <section className="section-block">
        <h2 className="section-label">{uiText("Active sessions", "接続中のセッション")}</h2>
        <div className="panel sessions-panel">
          {error && <p className="error">{error}</p>}
          {!sessions && !error && <p className="muted">{uiText("Loading sessions…", "セッションを読み込み中…")}</p>}
          {sessions?.length === 0 && (
            <div className="empty-state"><strong>{uiText("No active sessions", "接続中のセッションはありません")}</strong><span>{uiText("Connected devices will appear here.", "接続したデバイスがここに表示されます。")}</span></div>
          )}
          {sessions?.map((session) => (
            <div className="row" key={session.id}>
              <div>
                <strong>{session.current ? uiText("This browser", "このブラウザ") : session.userAgent || uiText("Dahlia session", "Dahlia セッション")}</strong>
                <span>{uiText("Connected", "接続日時")} {new Date(session.createdAt).toLocaleString()}</span>
              </div>
              <div className="row-actions">
                {session.current && <span className="status good">{uiText("Current", "現在")}</span>}
                <button className="secondary danger-button" onClick={() => revoke(session)}>{uiText("Revoke", "解除")}</button>
              </div>
            </div>
          ))}
        </div>
        <p className="section-note">{uiText("Revoked access can remain valid for up to 15 minutes.", "解除後も、発行済みのアクセストークンは最大15分間有効な場合があります。")}</p>
      </section>}
    </>
  );
}

function Vaults({ home = false }: { home?: boolean }) {
  const { dialog, openDialog } = useActionDialog();
  const { vaults, error: loadError, reload, organizationId } = useSidebar();
  const [recentVaultId, setRecentVaultId] = useState("");
  const recentVault = vaults?.find((vault) => vault.vaultId === recentVaultId) ?? vaults?.[0];
  useEffect(() => {
    if (recentVault) setRecentVaultId(recentVault.vaultId);
  }, [recentVault]);
  const recent = useLiveJSON<{ items: SyncedMeetingInfo[] }>(home && recentVault ? apiQuery("listMeetings", { params: { path: { vaultId: recentVault.vaultId } } }) : undefined);
  const [recovering, setRecovering] = useState(false);

  const createVault = () => openDialog({
    title: uiText("New Vault", "保管庫を作成"),
    description: uiText("Keep related meetings together. Only you can access a new Vault until you share it.", "関連するミーティングをまとめる場所です。共有するまでは、あなたのみが閲覧できます。"),
    confirmLabel: uiText("Create Vault", "保管庫を作成"),
    fields: [{ name: "name", label: uiText("Vault name", "保管庫名"), required: true }],
    onSubmit: async ({ name }) => {
      const id = encodeId("vault", uuidV7());
      await commitSyncTransaction(id, [{ entity: "vault", action: "create", entityId: id, baseRevision: null,
        data: { name: name!.trim(), createdAt: new Date().toISOString() } }], setRecovering);
      navigateDashboard(`/vaults/${id}`);
    },
  });
  return <>
    {dialog}
    <PageHeader title={home ? uiText("Home", "ホーム") : uiText("Vaults", "保管庫")}
      description={home ? uiText("Pick up where your last conversation left off.", "前回の会話の続きから、始めましょう。") : uiText("Your meetings, organized in one place.", "ミーティングとその記録を、保管庫ごとに整理します。")}
      actions={!organizationId && <button className="primary" onClick={createVault}><MenuIcon name="plus" />{uiText("New Vault", "保管庫を作成")}</button>} />
    {recovering && <p role="status">{syncMessage("sync_recovering")}</p>}
    <section className="section-block">
      <div className="collection-heading"><h2>{uiText("Your Vaults", "保管庫一覧")}</h2>{vaults && <span className="muted">{vaults.length}</span>}</div>
      {!vaults && !loadError && <p className="content-empty" role="status">{uiText("Loading Vaults…", "保管庫を読み込み中…")}</p>}
      {loadError && <p className="error" role="alert">{loadError} <button className="secondary" onClick={reload}>{uiText("Retry", "再試行")}</button></p>}
      {vaults?.length === 0 && <div className="welcome-empty">
        <span className="empty-symbol"><MenuIcon name="vault" /></span>
        <h2>{uiText("A home for your meetings", "ミーティングの記録を、ひとつの場所に")}</h2>
        <p>{organizationId ? uiText("Vaults shared with this organization will appear here.", "この組織に共有された保管庫がここに表示されます。") : uiText("Create a Vault, then connect it in Dahlia for macOS to bring your meeting notes, transcripts and screenshots here.", "保管庫を作成して macOS 版 Dahlia で接続すると、ミーティングの要約・文字起こし・スクリーンショットをここで閲覧できます。")}</p>
      </div>}
      <div className="vault-grid">{vaults?.map((vault) => <a className="vault-card" href={`/vaults/${vault.vaultId}`} key={vault.vaultId}>
        <div className="vault-card-top"><span className="vault-symbol"><AppearanceIcon appearance={collectionAppearance(vault, "vault")} size={22} /></span><span className={`status${vault.role === "owner" ? "" : " shared"}`}>{vault.role === "owner" ? uiText("Personal", "個人") : uiText("Shared · read-only", "共有・閲覧のみ")}</span></div>
        <h3>{vault.name}</h3>
        <div className="vault-card-bottom"><span>{uiText("Updated", "更新日")} {new Date(vault.updatedAt ?? vault.createdAt).toLocaleDateString()}</span><MenuIcon name="arrow" /></div>
      </a>)}</div>
    </section>
    {home && recentVault && <section className="section-block recent-meetings">
      <div className="collection-heading"><h2>{uiText("Recent meetings", "最近のミーティング")}</h2>
        <Select aria-label={uiText("Vault for recent meetings", "最近のミーティングの保管庫")} value={recentVault.vaultId} onValueChange={(value) => setRecentVaultId(value)}>
          {vaults?.map((vault) => <option value={vault.vaultId} key={vault.vaultId}><AppearanceIcon appearance={collectionAppearance(vault, "vault")} /><span>{vault.name}</span></option>)}
        </Select>
      </div>
      <DataError error={recent.error} retry={recent.reload} />
      <MeetingList meetings={recent.data?.items.slice(0, 10)} loading={recent.loading} />
      <a className="text-link" href={`/vaults/${recentVault.vaultId}`}>{uiText("View all meetings", "すべてのミーティングを見る")} <MenuIcon name="arrow" /></a>
    </section>}
  </>;
}

function VaultSharing({ session, vault }: { session: SessionInfo; vault: SyncedVaultInfo }) {
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string>();
  const sharingQuery = useLiveQuery(`sharing:${vault.vaultId}:${session.capabilities.sessions}`, async (signal) => {
    const [{ items }, organizationItems] = await Promise.all([
      api.listPermissions({ params: { path: { vaultId: vault.vaultId } }, signal }),
      session.capabilities.sessions
        ? json<OrganizationInfo[]>("/api/auth/organization/list", { signal })
        : api.listOrganizations({ signal }).then(({ items }) => items),
    ]);
    const teamItems = (await Promise.all(organizationItems.map((organization) =>
      session.capabilities.sessions
        ? json<TeamInfo[]>(`/api/auth/organization/list-teams?organizationId=${encodeURIComponent(organization.id)}`, { signal })
        : api.listTeams({ params: { path: { organizationId: organization.id } }, signal }).then(({ items }) => items)
    ))).flat();
    return { permissions: items, organizations: organizationItems, teams: teamItems };
  });
  const permissions = sharingQuery.data?.permissions;
  const organizations = sharingQuery.data?.organizations ?? [];
  const teams = sharingQuery.data?.teams ?? [];

  async function toggle(principalType: "organization" | "team", principalId: string, enabled: boolean) {
    if (saving) return;
    setSaving(true);
    setError(undefined);
    try {
      if (principalType === "organization") {
        const params = { path: { vaultId: vault.vaultId, organizationId: principalId } };
        await (enabled ? api.putOrganizationPermission({ params }) : api.deleteOrganizationPermission({ params }));
      } else {
        const params = { path: { vaultId: vault.vaultId, teamId: principalId } };
        await (enabled ? api.putTeamPermission({ params }) : api.deleteTeamPermission({ params }));
      }
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : uiText("Could not update sharing", "共有設定を更新できませんでした"));
    } finally {
      setSaving(false);
    }
  }

  const shared = (principalType: VaultPermissionInfo["principalType"], principalId: string) =>
    permissions?.some((permission) => permission.role === "member"
      && permission.principalType === principalType
      && permission.principalId === principalId) === true;
  const permissionLabel = (permission: VaultPermissionInfo) => {
    if (permission.principalType === "organization") {
      return organizations.find(({ id }) => id === permission.principalId)?.name ?? uiText("Organization", "組織");
    }
    if (permission.principalType === "team") {
      return teams.find(({ id }) => id === permission.principalId)?.name ?? uiText("Team", "チーム");
    }
    return uiText("Shared directly with you", "あなたに直接共有");
  };
  return (
    <section className="section-block">
      <h2 className="section-label">{uiText("Sharing", "共有")}</h2>
      <div className="panel share-list">
        {!permissions && !error && !sharingQuery.error && <p className="muted">{uiText("Loading sharing settings…", "共有設定を読み込み中…")}</p>}
        {vault.role === "member" && permissions && (
          <>
            <p className="muted">{uiText("This Vault was shared with you. Only its owner can change access.", "共有された保管庫です。アクセス権は所有者のみ変更できます。")}</p>
            {permissions.map((permission) => (
              <div className="share-row" key={`${permission.principalType}-${permission.principalId}`}>
                <span>
                  <strong>{permissionLabel(permission)}</strong>
                  <small>{uiText("Read-only access", "閲覧のみ")}</small>
                </span>
              </div>
            ))}
          </>
        )}
        {vault.role === "owner" && organizations.length === 0 && permissions && (
          <div className="empty-state"><strong>{uiText("No organizations", "組織がありません")}</strong><span>{uiText("Create one from Organizations first.", "アカウントメニューから組織を作成してください。")}</span></div>
        )}
        {vault.role === "owner" && organizations.map((organization) => (
          <label className="share-row" key={organization.id}>
            <span><strong>{organization.name}</strong><small>{organization.slug}</small></span>
            <input
              type="checkbox"
              disabled={saving || sharingQuery.loading || !permissions}
              checked={shared("organization", organization.id)}
              onChange={(event) => void toggle("organization", organization.id, event.target.checked)}
            />
          </label>
        ))}
        {vault.role === "owner" && teams.map((team) => (
          <label className="share-row" key={team.id}>
            <span><strong>{team.name}</strong><small>{uiText("Team · read-only access", "チーム・閲覧のみ")}</small></span>
            <input
              type="checkbox"
              disabled={saving || sharingQuery.loading || !permissions}
              checked={shared("team", team.id)}
              onChange={(event) => void toggle("team", team.id, event.target.checked)}
            />
          </label>
        ))}
      </div>
      {saving && <p className="muted" role="status">{uiText("Updating access…", "アクセス権を更新中…")}</p>}
      <DataError error={sharingQuery.error} retry={sharingQuery.reload} />
      {error && <p className="error resource-error">{error}</p>}
    </section>
  );
}

function VaultTransfer({ vault }: { vault: SyncedVaultInfo }) {
  const { dialog, openDialog } = useActionDialog();
  const targets = useLiveJSON<{ items: SyncedVaultInfo[] }>(apiQuery("listVaults", {}));
  const [destinationId, setDestinationId] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string>();
  const available = targets.data?.items.filter((item) => item.role === "owner" && item.vaultId !== vault.vaultId) ?? [];
  const destination = available.find((item) => item.vaultId === destinationId);
  async function confirm() {
    if (!destination || loading) return;
    setLoading(true);
    setError(undefined);
    try {
      const [source, target, audience] = await Promise.all([
        api.getVault({ params: { path: { vaultId: vault.vaultId } } }),
        api.getVault({ params: { path: { vaultId: destination.vaultId } } }),
        api.getTransferAudience({ params: { path: { vaultId: vault.vaultId }, query: { destinationVaultId: destination.vaultId } } }),
      ]);
      const people = (items: { name: string; email: string }[]) => items.map((person) => `${person.name} (${person.email})`).join(", ");
      const description = [
        uiText(`Move all Server-saved content from “${source.name}” to “${target.name}”. The source Vault will remain empty.`,
          `「${source.name}」のServer保存済みの全内容を「${target.name}」へ移管します。元の保管庫は空で残ります。`),
        audience.removed.length ? uiText(`Will lose access: ${people(audience.removed)}.`, `閲覧できなくなる人：${people(audience.removed)}。`) : "",
        audience.added.length ? uiText(`Will gain access: ${people(audience.added)}.`, `新しく閲覧できる人：${people(audience.added)}。`) : "",
        !audience.removed.length && !audience.added.length ? uiText("No change to the current readers.", "現在の閲覧者に変更はありません。") : "",
        uiText("Devices without access will pause sync and keep local data. Unsynced data is not transferred.",
          "移管先を閲覧できない端末はローカルデータを保持して同期を停止します。未同期データは移管されません。"),
      ].filter(Boolean).join("\n\n");
      const key = encodeId("transaction", uuidV7());
      const body = { destinationVaultId: target.vaultId, sourceRevision: source.revision, destinationRevision: target.revision, audienceHash: audience.audienceHash };
      openDialog({ title: uiText("Transfer content", "内容を移管"), description,
        confirmLabel: uiText("Transfer", "移管する"), destructive: true,
        onSubmit: async () => {
          await api.transferVault({ params: { path: { vaultId: source.vaultId }, header: { "idempotency-key": key } }, body });
          window.location.assign(`/vaults/${target.vaultId}`);
        },
      });
    } catch (caught) { setError(caught instanceof Error ? caught.message : String(caught)); }
    finally { setLoading(false); }
  }
  return <section className="vault-settings"><h2>{uiText("Transfer content", "内容を移管")}</h2>
    <p>{uiText("Move all saved content to another Vault you own.", "保存済みの全内容を、自分が所有する別の保管庫へ移します。")}</p>
    <div className="collection-heading"><Select aria-label={uiText("Destination Vault", "移管先の保管庫")} placeholder={uiText("Choose a Vault", "保管庫を選択")} menuLabel={uiText("Vaults", "保管庫")} value={destinationId} disabled={loading}
      onValueChange={(value) => setDestinationId(value)}>
      {available.map((item) => <option key={item.vaultId} value={item.vaultId}><AppearanceIcon appearance={collectionAppearance(item, "vault")} /><span>{item.name}</span></option>)}
    </Select><button className="secondary" disabled={!destination || loading || vault.hasResources !== true} onClick={() => void confirm()}>
      {loading ? uiText("Checking…", "確認中…") : uiText("Transfer content", "内容を移管")}</button></div>
    {targets.data && !available.length && <p className="muted">{uiText("Create another Vault to transfer content.", "移管先となる別の保管庫を作成してください。")}</p>}
    <DataError error={targets.error} retry={targets.reload} />{error && <p className="error" role="alert">{error}</p>}{dialog}
  </section>;
}

function meetingCount(count: number) { return uiText(`${count} meeting${count === 1 ? "" : "s"}`, `${count}件のミーティング`); }

export function MeetingList({ meetings, loading, filtered = false, onClear }: { meetings?: SyncedMeetingInfo[]; loading: boolean; filtered?: boolean; onClear?: () => void }) {
  return <div className="collection-list" aria-busy={loading}>
    {!meetings && loading && <p className="content-empty" role="status">{uiText("Loading meetings…", "ミーティングを読み込み中…")}</p>}
    {meetings?.length === 0 && <div className="welcome-empty compact-empty">
      <span className="empty-symbol"><MenuIcon name={filtered ? "search" : "document"} /></span>
      <h2>{filtered ? uiText("No matching meetings", "条件に一致するミーティングがありません") : uiText("No meetings yet", "ミーティングはまだありません")}</h2>
      <p>{filtered ? uiText("Try a different title or clear your filters.", "別のタイトルで検索するか、絞り込みを解除してください。") : uiText("Meetings synced from Dahlia for macOS will appear here.", "macOS 版 Dahlia から同期されたミーティングがここに表示されます。")}</p>
      {filtered && onClear && <button className="secondary" onClick={onClear}>{uiText("Clear filters", "絞り込みを解除")}</button>}
    </div>}
    {meetings?.map((meeting) => {
      const date = meeting.recordingStartedAt ?? meeting.createdAt;
      return <a className="collection-row meeting-list-row" href={`/meetings/${meeting.meetingId}`} key={meeting.meetingId}>
        <span className="collection-icon"><MenuIcon name="document" /></span>
        <span className="collection-copy"><strong>{meeting.name || uiText("Untitled meeting", "無題のミーティング")} <RecordingIndicator isRecording={meeting.isRecording} /></strong>
          {meeting.description && <small>{meeting.description}</small>}
          <span className="collection-date"><time dateTime={date}>{new Date(date).toLocaleString(undefined, { year: "numeric", month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" })}</time>
          {meeting.duration != null && <span> · {Math.floor(meeting.duration / 60)}:{String(Math.floor(meeting.duration % 60)).padStart(2, "0")}</span>}</span>
        </span>
        <MenuIcon name="arrow" />
      </a>;
    })}
  </div>;
}

function VaultMeetings({ session, vaultId }: { session: SessionInfo; vaultId: string }) {
  const { dialog, openDialog } = useActionDialog();
  const vaultQuery = useLiveJSON<SyncedVaultInfo>(apiQuery("getVault", { params: { path: { vaultId: vaultId } } }));
  const vault = vaultQuery.data;
  const [recovering, setRecovering] = useState(false);
  const projectsQuery = useLiveJSON<{ items: SyncedProjectInfo[] }>(apiQuery("listProjects", { params: { path: { vaultId: vaultId } } }));
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
  const meetingFilters = { query: search || undefined, projectId: projectId || undefined };
  const meetingsQuery = useLivePage<SyncedMeetingInfo>(apiQuery("listMeetings", { params: { path: { vaultId }, query: meetingFilters } }));
  const meetings = vault ? meetingsQuery.data?.items : undefined;
  const nextCursor = meetingsQuery.data?.nextCursor;
  const loadingMore = meetingsQuery.loadingMore;
  const renameVault = () => {
    if (!vault) return;
    openDialog({
      title: uiText("Edit Vault", "保管庫を編集"), confirmLabel: uiText("Save changes", "変更を保存"),
      fields: [{ name: "name", label: uiText("Vault name", "保管庫名"), value: vault.name, required: true },
        { name: "appearance", label: uiText("Appearance", "見た目"), appearance: "editable", value: JSON.stringify(collectionAppearance(vault, "vault")) }],
      onSubmit: async ({ name, appearance }) => {
        await commitSyncTransaction(vaultId, [{ entity: "vault", action: "update", entityId: vaultId,
          baseRevision: vault.revision, data: { name: name!.trim(), ...(JSON.parse(appearance!) as Appearance) } }], setRecovering);
      },
    });
  };
  const deleteVault = () => {
    if (!vault || vault.role !== "owner") return;
    openDialog({
      title: uiText("Delete Vault?", "保管庫を削除しますか？"),
      description: uiText(`Delete the empty Vault “${vault.name}”? This cannot be undone.`, `空の保管庫「${vault.name}」を削除します。この操作は取り消せません。`),
      confirmLabel: uiText("Delete Vault", "保管庫を削除"), destructive: true,
      onSubmit: async () => {
        await commitSyncTransaction(vaultId, [{ entity: "vault", action: "reset", entityId: vaultId,
          baseRevision: vault.revision, data: { preservePermissions: false } }], setRecovering);
        navigateDashboard("/vaults");
      },
    });
  };
  const createProject = () => openDialog({
    title: uiText("New Project", "プロジェクトを作成"),
    description: uiText(`Organize meetings in ${vault?.name ?? "this Vault"}.`, `「${vault?.name ?? "この保管庫"}」のミーティングを整理します。`),
    confirmLabel: uiText("Create Project", "プロジェクトを作成"),
    fields: [
      { name: "name", label: uiText("Project name", "プロジェクト名"), required: true },
      { name: "description", label: uiText("Description", "説明"), multiline: true },
    ],
    onSubmit: async ({ name, description }) => {
      const id = encodeId("project", uuidV7());
      await commitSyncTransaction(vaultId, [{ entity: "project", action: "create", entityId: id, baseRevision: null,
        data: { parentProjectId: null, name: name!.trim(), description: description ?? "", projectType: "undefined", createdAt: new Date().toISOString() } }], setRecovering);
      navigateDashboard(`/projects/${id}`);
    },
  });
  return <article className="meeting-detail collection-detail">
    <header className="meeting-header">
      <nav className="detail-breadcrumbs" aria-label={uiText("Breadcrumbs", "パンくず")}><a href="/vaults">{uiText("All Vaults", "保管庫一覧")}</a></nav>
      <h1><AppearanceIcon appearance={collectionAppearance(vault, "vault")} size={28} />{vault?.name ?? uiText("Vault", "保管庫")}</h1>
      {vault && <div className="meeting-metadata"><span className="metadata-chip">{vault.role === "owner" ? uiText("Owner", "所有者") : uiText("Read-only", "閲覧のみ")}</span></div>}
    </header>
    {dialog}
    {recovering && <p role="status">{syncMessage("sync_recovering")}</p>}
    <DataError error={vaultQuery.error} retry={vaultQuery.reload} />
    <DetailTabs label={uiText("Vault content", "保管庫の内容")} tabs={[
      { id: "meetings", label: uiText("Meetings", "ミーティング"), content: <>
        <div className="collection-filters">
          <input type="search" className="model-search" aria-label={uiText("Search meetings", "ミーティングを検索")} placeholder={uiText("Search meetings", "ミーティングを検索")} value={query} onChange={(event) => setQuery(event.target.value)} />
          {projects.length > 0 && <Select aria-label={uiText("Filter by Project", "プロジェクトで絞り込み")} value={projectId} onValueChange={(value) => setProjectId(value)}>
            <option value="">{uiText("All Projects", "すべてのプロジェクト")}</option>
            {projects.map((project) => <option key={project.projectId} value={project.projectId}>{project.path}</option>)}
          </Select>}
        </div>
        <DataError error={projectsQuery.error} retry={projectsQuery.reload} />
        <DataError error={meetingsQuery.error} retry={meetingsQuery.reload} />
        <MeetingList meetings={meetings} loading={meetingsQuery.loading} filtered={Boolean(query || projectId)} onClear={() => { setQuery(""); setSearch(""); setProjectId(""); }} />
        {nextCursor && <button className="secondary load-more" disabled={loadingMore} onClick={meetingsQuery.loadMore}>{loadingMore ? uiText("Loading…", "読み込み中…") : uiText("Load more", "さらに表示")}</button>}
      </> },
      { id: "projects", label: uiText("Projects", "プロジェクト"), content: <>
        <div className="collection-heading"><h2>{uiText("Projects", "プロジェクト")}</h2>{vault?.role === "owner" && <button className="secondary" onClick={createProject}>{uiText("New Project", "プロジェクトを作成")}</button>}</div>
        <DataError error={projectsQuery.error} retry={projectsQuery.reload} />
        {projectsQuery.loading && !projectsQuery.data && <p className="content-empty">{uiText("Loading…", "読み込み中…")}</p>}
        {projectsQuery.data && projects.length === 0 && <p className="content-empty">{uiText("No projects yet", "プロジェクトはまだありません")}</p>}
        <div className="collection-list">{projects.map((project) => <a className="collection-row" href={`/projects/${project.projectId}`} key={project.projectId}>
          <span className="collection-project-name"><AppearanceIcon appearance={projectAppearance(project, projects.find((parent) => parent.projectId === project.parentProjectId))} /><span><strong>{project.path}</strong>{project.description && <small>{project.description}</small>}</span></span><span className="muted">{meetingCount(project.subtreeMeetingCount ?? 0)}</span>
        </a>)}</div>
      </> },
      ...(session.capabilities.sharing && vault ? [{ id: "permissions", label: uiText("Permissions", "権限"), content: <VaultSharing session={session} vault={vault} /> }] : []),
      { id: "settings", label: uiText("Settings", "設定"), content: <>
        <section className="vault-settings"><h2>{uiText("Vault details", "保管庫の詳細")}</h2><div className="collection-heading"><span>{vault?.name}</span>{vault?.role === "owner" && <button className="secondary" onClick={renameVault}>{uiText("Edit Vault", "保管庫を編集")}</button>}</div></section>
        {vault?.role === "owner" && <VaultTransfer vault={vault} />}
        {vault?.role === "owner" && <section className="vault-settings"><h2>{uiText("Delete Vault", "保管庫を削除")}</h2>
          <div className="collection-heading"><p>{uiText("Only empty Vaults can be deleted. Transfer or delete all resources first.", "空の保管庫のみ削除できます。リソースが残っている場合は、先に移管または削除してください。")}</p>
          <button className="secondary danger-button" disabled={vault.hasResources !== false} onClick={deleteVault}>{uiText("Delete Vault", "保管庫を削除")}</button></div>
        </section>}
      </> },
    ]} />
  </article>;
}

function SyncedProject({ vaultId, projectId }: { vaultId: string; projectId: string }) {
  const { dialog, openDialog } = useActionDialog();
  const vaultQuery = useLiveJSON<SyncedVaultInfo>(apiQuery("getVault", { params: { path: { vaultId: vaultId } } }));
  const vault = vaultQuery.data;
  const [recovering, setRecovering] = useState(false);
  const projectQuery = useLiveJSON<SyncedProjectInfo>(apiQuery("getProject", { params: { path: { projectId: projectId } } }));
  const project = vault ? projectQuery.data : undefined;
  const parentQuery = useLiveJSON<SyncedProjectInfo>(project?.parentProjectId ? apiQuery("getProject", { params: { path: { projectId: project.parentProjectId } } }) : undefined);
  const meetingFilters = { projectId };
  const meetingsQuery = useLivePage<SyncedMeetingInfo>(apiQuery("listMeetings", { params: { path: { vaultId }, query: meetingFilters } }));
  const meetings = project ? meetingsQuery.data?.items : undefined;
  const nextCursor = meetingsQuery.data?.nextCursor;
  const loadingMore = meetingsQuery.loadingMore;
  const editProject = () => {
    if (!project) return;
    openDialog({
      title: uiText("Edit Project", "プロジェクトを編集"), confirmLabel: uiText("Save changes", "変更を保存"),
      fields: [
        { name: "name", label: uiText("Project name", "プロジェクト名"), value: project.name, required: true },
        { name: "description", label: uiText("Description", "説明"), value: project.description, multiline: true },
        { name: "appearance", label: uiText("Appearance", "見た目"), appearance: project.parentProjectId ? "inherited" : "editable", value: JSON.stringify(projectAppearance(project, parentQuery.data)) },
      ],
      onSubmit: async ({ name, description, appearance }) => {
        await commitSyncTransaction(vaultId, [{ entity: "project", action: "update", entityId: projectId, baseRevision: project.revision,
          data: { ...(!project.parentProjectId ? JSON.parse(appearance!) as Appearance : {}), parentProjectId: project.parentProjectId ?? null, name: name!.trim(), description: description ?? "",
            projectType: project.parentProjectId ? null : project.projectType ?? "undefined" } }], setRecovering);
      },
    });
  };
  const deleteProject = () => {
    if (!project) return;
    openDialog({
      title: uiText("Delete Project?", "プロジェクトを削除しますか？"),
      description: uiText(`“${project.path}” will be permanently deleted. Only empty projects can be deleted.`, `「${project.path}」を完全に削除します。削除できるのは空のプロジェクトのみです。`),
      confirmLabel: uiText("Delete Project", "プロジェクトを削除"), destructive: true,
      onSubmit: async () => {
        await commitSyncTransaction(vaultId, [{ entity: "project", action: "delete", entityId: projectId,
          baseRevision: project.revision, data: {} }], setRecovering);
        navigateDashboard(`/vaults/${vaultId}`);
      },
    });
  };
  return <article className="meeting-detail collection-detail">
    <header className="meeting-header">
      <nav className="detail-breadcrumbs" aria-label={uiText("Breadcrumbs", "パンくず")}>
        <a href={`/vaults/${vaultId}`}>{vault?.name ?? uiText("Vault", "保管庫")}</a>
        {project?.parentProjectId && <><span aria-hidden="true">/</span><a href={`/projects/${project.parentProjectId}`}>{parentQuery.data?.name ?? uiText("Parent Project", "親プロジェクト")}</a></>}
      </nav>
      <h1><AppearanceIcon appearance={projectAppearance(project, parentQuery.data)} size={28} />{project?.name ?? uiText("Project", "プロジェクト")}</h1>
      {project?.description && <p className="project-description">{project.description}</p>}
      {project && <div className="meeting-metadata"><span className="metadata-chip">{meetingCount(project.subtreeMeetingCount ?? 0)}</span></div>}
    </header>
    {dialog}
    {recovering && <p role="status">{syncMessage("sync_recovering")}</p>}
    <DataError error={vaultQuery.error} retry={vaultQuery.reload} />
    <DataError error={projectQuery.error} retry={projectQuery.reload} />
    <DetailTabs label={uiText("Project content", "プロジェクトの内容")} tabs={[
      { id: "meetings", label: uiText("Meetings", "ミーティング"), content: <>
        <DataError error={meetingsQuery.error} retry={meetingsQuery.reload} />
        <MeetingList meetings={meetings} loading={meetingsQuery.loading} />
        {nextCursor && <button className="secondary load-more" disabled={loadingMore} onClick={meetingsQuery.loadMore}>{loadingMore ? uiText("Loading…", "読み込み中…") : uiText("Load more", "さらに表示")}</button>}
      </> },
      { id: "settings", label: uiText("Settings", "設定"), content: <>
        <section className="vault-settings">
          <h2>{uiText("Project details", "プロジェクトの詳細")}</h2>
          <div className="collection-heading"><span>{project?.name}</span>
            {project && vault?.role === "owner" && <button className="secondary" onClick={editProject}>{uiText("Edit Project", "プロジェクトを編集")}</button>}
          </div>
        </section>
        {project && vault?.role === "owner" && <section className="vault-settings">
          <h2>{uiText("Delete Project", "プロジェクトを削除")}</h2>
          <div className="collection-heading">
            <p>{uiText("Only empty projects can be deleted.", "削除できるのは空のプロジェクトのみです。")}</p>
            <button className="secondary danger-button" onClick={deleteProject}>{uiText("Delete Project", "プロジェクトを削除")}</button>
          </div>
        </section>}
      </> },
    ]} />
  </article>;
}

export function SyncedMeeting({ vaultId, meetingId }: { vaultId: string; meetingId: string }) {
  const { dialog, openDialog } = useActionDialog();
  const meetingQuery = useLiveJSON(apiQuery("getMeeting", { params: { path: { meetingId } } }));
  const vaultQuery = useLiveJSON<SyncedVaultInfo>(apiQuery("getVault", { params: { path: { vaultId: vaultId } } }));
  const projectsQuery = useLiveJSON<{ items: SyncedProjectInfo[] }>(apiQuery("listProjects", { params: { path: { vaultId: vaultId } } }));
  const screenshotsQuery = useLivePage<SyncedScreenshotInfo>(apiQuery("listMeetingFiles", { params: { path: { meetingId } } }));
  const meeting = vaultQuery.data ? meetingQuery.data : undefined;
  const vault = vaultQuery.data;
  const screenshots = screenshotsQuery.data?.items;
  const screenshotCursor = screenshotsQuery.data?.nextCursor;
  const loadingScreenshots = screenshotsQuery.loadingMore;
  const [recovering, setRecovering] = useState(false);
  const latestSummary = useLiveJSON<LatestSummary>(apiQuery("getLatestSummary", { params: { path: { meetingId } } }));
  const [selectedSummary, setSelectedSummary] = useState<number | null>(null);
  useEffect(() => { setSelectedSummary(null); }, [meetingId]);
  const currentSummary = latestSummary.data?.record;
  const document = useMemo(() => parseSummary(currentSummary?.document ?? undefined), [currentSummary?.document]);
  const project = projectsQuery.data?.items.find((item) => item.projectId === meeting?.projectId);
  const editMeeting = () => {
    if (!meeting) return;
    openDialog({
      title: uiText("Edit Meeting", "ミーティングを編集"), confirmLabel: uiText("Save changes", "変更を保存"),
      fields: [
        { name: "name", label: uiText("Meeting name", "ミーティング名"), value: meeting.name, required: true },
        { name: "description", label: uiText("Description", "説明"), value: meeting.description, multiline: true },
      ],
      onSubmit: async ({ name, description }) => {
        await commitSyncTransaction(vaultId, [{ entity: "meeting", action: "update", entityId: meetingId, baseRevision: meeting.revision,
          data: { projectId: meeting.projectId ?? null, name: name!.trim(), description: description ?? "", status: meeting.status,
            duration: meeting.duration ?? null, recordingStartedAt: meeting.recordingStartedAt ?? null, updatedAt: new Date().toISOString() } }], setRecovering);
      },
    });
  };
  const editSummary = () => {
    if (!meeting || !latestSummary.data || selectedSummary !== null) return;
    const editor = summaryEditor(currentSummary?.document, currentSummary?.title ?? meeting.name);
    openDialog({
      title: currentSummary?.document ? uiText("Edit Summary", "要約を編集") : uiText("New Summary", "要約を追加"),
      description: uiText("Your changes are saved as a new version. Previous versions remain available.", "変更は新しいバージョンとして保存され、過去のバージョンも引き続き閲覧できます。"),
      confirmLabel: uiText("Save summary", "要約を保存"), fields: editor.fields,
      onSubmit: async (values) => {
        await commitSyncTransaction(vaultId, [{ entity: "summary", action: "upsert", entityId: meetingId,
          baseRevision: latestSummary.data!.revision,
          data: { title: values.title!.trim(), document: editor.document(values), createdAt: new Date().toISOString() } }], setRecovering);
      },
    });
  };
  const deleteSummary = () => {
    if (!meeting || !currentSummary?.document) return;
    openDialog({
      title: uiText("Delete summary and history?", "要約と履歴を削除しますか？"),
      description: uiText(`The summary for “${meeting.name}” and all its versions will be permanently deleted. The meeting, transcript and screenshots will remain.`, `「${meeting.name}」の要約とすべての過去バージョンを完全に削除します。ミーティング、文字起こし、スクリーンショットは残ります。`),
      confirmLabel: uiText("Delete summary", "要約を削除"), destructive: true,
      onSubmit: async () => {
        await commitSyncTransaction(vaultId, [{ entity: "summary", action: "delete", entityId: meetingId,
          baseRevision: latestSummary.data!.revision, data: {} }], setRecovering);
      },
    });
  };
  const visibleScreenshots = screenshots?.filter((screenshot) => screenshot.file.metadata.source === "screenshot");
  return (
    <article className="meeting-detail" aria-busy={!meeting && (meetingQuery.loading || vaultQuery.loading)}>
      {meeting && <header className="meeting-header">
        <nav className="detail-breadcrumbs" aria-label={uiText("Breadcrumbs", "パンくず")}>
          <a href={`/vaults/${vaultId}`}><AppearanceIcon appearance={collectionAppearance(vault, "vault")} />{vault?.name ?? uiText("Vault", "保管庫")}</a>
          {project && <><span aria-hidden="true">/</span><a href={`/projects/${project.projectId}`}>{project.path}</a></>}
        </nav>
        <h1>{meeting.name || uiText("Untitled meeting", "無題のミーティング")}</h1>
        {meeting.description && <p className="project-description">{meeting.description}</p>}
        <div className="meeting-metadata">
          <RecordingIndicator isRecording={meeting.isRecording} />
          <span className="metadata-chip"><time dateTime={meeting.recordingStartedAt ?? meeting.createdAt}>
            {new Date(meeting.recordingStartedAt ?? meeting.createdAt).toLocaleString(undefined, { year: "numeric", month: "long", day: "numeric", hour: "2-digit", minute: "2-digit" })}
          </time>{meeting.duration != null && <> · {Math.floor(meeting.duration / 60)}:{String(Math.floor(meeting.duration % 60)).padStart(2, "0")}</>}</span>
          {meeting.projectId ? <a className="metadata-chip" href={`/projects/${meeting.projectId}`}>
            <span aria-hidden="true">▱</span>{project?.path ?? uiText("Project", "プロジェクト")}
          </a> : <span className="metadata-chip">{uiText("Unassigned", "未分類")}</span>}
          <SummaryTags document={document} />
        </div>
      </header>}
      {dialog}
      {recovering && <p role="status">{syncMessage("sync_recovering")}</p>}
      <DataError error={meetingQuery.error} retry={meetingQuery.reload} />
      <DataError error={vaultQuery.error} retry={vaultQuery.reload} />
      <DataError error={projectsQuery.error} retry={projectsQuery.reload} />
      {meeting && vault?.role === "owner" && <ServerSummaryGeneration key={meetingId} meetingId={meetingId} />}
      {meeting && <MeetingTabs
        actions={vault?.role === "owner" && <div className="meeting-actions">
          <button className="action-trigger" aria-label={uiText("Meeting actions", "ミーティングの操作")} popoverTarget="meeting-actions"><span aria-hidden="true">⋯</span>{" "}<span className="action-label">{uiText("Actions", "操作")}</span></button>
          <div id="meeting-actions" popover="auto" className="action-menu">
            <button onClick={editMeeting}>{uiText("Edit Meeting", "ミーティングを編集")}</button>
            <button disabled={selectedSummary !== null || !latestSummary.data || Boolean(currentSummary?.document && !Array.isArray(document.sections))} onClick={editSummary}>{currentSummary?.document ? uiText("Edit Summary", "要約を編集") : uiText("New Summary", "要約を追加")}</button>
            {currentSummary?.document && <button className="danger-button" onClick={deleteSummary}>{uiText("Delete Summary", "要約を削除")}</button>}
          </div>
        </div>}
        summary={<>
          <DataError error={latestSummary.error} retry={latestSummary.reload} />
          <SummaryHistory key={meetingId} meetingId={meetingId} latest={latestSummary.data} selected={selectedSummary} onSelect={setSelectedSummary} />
        </>}
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
        transcript={<TranscriptHistory key={meetingId} meetingId={meetingId} timeBase={meeting.recordingStartedAt ?? meeting.createdAt} />}
      />}
    </article>
  );
}

export function ScreenshotFigure({ file, capturedAt }: { file: SyncedScreenshotInfo["file"]; capturedAt?: string | null }) {
  const [failed, setFailed] = useState(false);
  useEffect(() => {
    const retry = () => setFailed(false);
    const events = [liveDataEvent, clientMutationEvent, "online"];
    for (const event of events) window.addEventListener(event, retry);
    return () => { for (const event of events) window.removeEventListener(event, retry); };
  }, []);
  const original = apiUrls.getFileContent({ params: { path: { fileId: file.id } } });
  return <figure className="panel">
    <FileLink fileId={file.id} capturedAt={capturedAt} label={uiText("Open screenshot", "スクリーンショットを開く")}>
      {failed ? <span role="alert">{uiText("Unable to load screenshot.", "スクリーンショットを読み込めませんでした。")}</span> : <img
        src={file.variants?.thumb_480 ?? original}
        alt={file.metadata.caption || uiText("Screenshot", "スクリーンショット")}
        loading="lazy"
        onError={() => setFailed(true)}
      />}
    </FileLink>
    {failed && <button className="secondary" onClick={() => setFailed(false)}>{uiText("Retry", "再試行")}</button>}
    {capturedAt && <time className="screenshot-time" dateTime={capturedAt}>{new Date(capturedAt).toLocaleTimeString()}</time>}
    {(file.metadata.caption || file.metadata.ocrText) && <figcaption>{file.metadata.caption || file.metadata.ocrText}</figcaption>}
    <a href={original} download>{uiText("Download original", "原本をダウンロード")}</a>
  </figure>;
}

function OrganizationDetails({ organization, session }: { organization: OrganizationInfo; session: SessionInfo }) {
  const { dialog, openDialog } = useActionDialog();
  const [members, setMembers] = useState<OrganizationMember[]>();
  const [teams, setTeams] = useState<TeamInfo[]>([]);
  const [teamMembers, setTeamMembers] = useState<Record<string, TeamMember[]>>({});
  const [invitations, setInvitations] = useState<OrganizationInvitation[]>();
  const [memberSearch, setMemberSearch] = useState("");
  const [copied, setCopied] = useState(false);
  const [invitationLink, setInvitationLink] = useState<string>();
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string>();
  const organizationId = encodeURIComponent(organization.id);
  const load = useCallback(async () => {
    setError(undefined);
    try {
      const accounts = session.capabilities.sessions;
      const [memberPage, teamItems] = await Promise.all([
        accounts ? json<{ members: OrganizationMember[] }>(`/api/auth/organization/list-members?organizationId=${organizationId}`)
          : api.listOrganizationMembers({ params: { path: { organizationId: organization.id } } }).then(({ items }) => ({ members: items })),
        accounts ? json<TeamInfo[]>(`/api/auth/organization/list-teams?organizationId=${organizationId}`)
          : api.listTeams({ params: { path: { organizationId: organization.id } } }).then(({ items }) => items),
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
                await api.listTeamMembers({ params: { path: { organizationId: organization.id, teamId: team.id } } }).then(({ items }) => items),
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

  function invite() {
    openDialog({
      title: uiText("Invite member", "メンバーを招待"),
      description: uiText("Create a link and share it with this person. An email is not sent automatically.", "招待リンクを作成して相手に共有します。メールは自動送信されません。"),
      confirmLabel: uiText("Create invitation link", "招待リンクを作成"),
      fields: [{ name: "email", label: uiText("Email address", "メールアドレス"), type: "email", required: true }],
      onSubmit: async ({ email }) => {
        const invitation = await json<OrganizationInvitation>("/api/auth/organization/invite-member", {
          method: "POST", body: JSON.stringify({ email: email!.trim(), role: "member", organizationId: organization.id }),
        });
        setInvitationLink(`${window.location.origin}/accept-invitation/${invitation.id}`);
        setCopied(false);
        await load();
      },
    });
  }

  async function copyInvitation() {
    try {
      await navigator.clipboard.writeText(invitationLink!);
      setCopied(true);
    } catch {
      setError(uiText("Could not copy. Select the link and copy it manually.", "コピーできませんでした。リンクを選択してコピーしてください。"));
    }
  }

  function removeMember(member: OrganizationMember) {
    openDialog({
      title: uiText("Remove member?", "メンバーを削除しますか？"),
      description: uiText(`${member.user.email} will lose access through ${organization.name}.`, `${member.user.email} は「${organization.name}」を通じたアクセスを失います。`),
      confirmLabel: uiText("Remove member", "メンバーを削除"), destructive: true,
      onSubmit: async () => {
        await json("/api/auth/organization/remove-member", { method: "POST", body: JSON.stringify({ memberIdOrEmail: member.id, organizationId: organization.id }) });
        await load();
      },
    });
  }

  async function cancelInvitation(invitation: OrganizationInvitation) {
    if (pending) return;
    setPending(true);
    setError(undefined);
    try {
      await json("/api/auth/organization/cancel-invitation", {
        method: "POST",
        body: JSON.stringify({ invitationId: invitation.id }),
      });
      await load();
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Could not cancel invitation");
    } finally {
      setPending(false);
    }
  }

  function deleteOrganization() {
    openDialog({
      title: uiText("Delete organization?", "組織を削除しますか？"),
      description: uiText(`“${organization.name}” and its teams will be deleted. Members will lose access to Vaults shared through this organization. The Vaults themselves will remain.`, `「${organization.name}」とそのチームを削除します。この組織を通じて共有している保管庫へのアクセスは失われますが、保管庫そのものは残ります。`),
      confirmLabel: uiText("Delete organization", "組織を削除"), destructive: true,
      onSubmit: async () => {
        await json("/api/auth/organization/delete", { method: "POST", body: JSON.stringify({ organizationId: organization.id }) });
        navigateDashboard("/organizations");
      },
    });
  }

  function createTeam() {
    openDialog({
      title: uiText("Create team", "チームを作成"),
      description: uiText("Group members to share Vaults with a team. You can manage members after creating it.", "保管庫の共有先となるチームを作成します。作成後にメンバーを設定できます。"),
      confirmLabel: uiText("Create team", "チームを作成"),
      fields: [{ name: "name", label: uiText("Team name", "チーム名"), required: true }],
      onSubmit: async ({ name }) => {
        const team = session.capabilities.sessions ? await json<TeamInfo>("/api/auth/organization/create-team", {
          method: "POST", body: JSON.stringify({ name: name!.trim(), organizationId: organization.id }),
        }) : await api.createTeam({ params: { path: { organizationId: organization.id } }, body: { name: name!.trim() } });
        // Creation succeeded: a membership failure must not invite a duplicate team retry.
        if (session.capabilities.sessions) {
          try {
            await json("/api/auth/organization/add-team-member", {
              method: "POST", body: JSON.stringify({ teamId: team.id, userId: session.user.id, organizationId: organization.id }),
            });
          } catch {
            await load();
            setError(uiText("Team created. Add yourself from the team's member list.", "チームを作成しました。チームのメンバー一覧から自分を追加してください。"));
            return;
          }
        }
        await load();
      },
    });
  }

  function renameTeam(team: TeamInfo) {
    openDialog({
      title: uiText("Rename team", "チーム名を変更"), confirmLabel: uiText("Save changes", "変更を保存"),
      fields: [{ name: "name", label: uiText("Team name", "チーム名"), hideLabel: true, value: team.name, required: true }],
      onSubmit: async ({ name }) => {
        if (name!.trim() === team.name) return;
        if (session.capabilities.sessions) await json("/api/auth/organization/update-team", {
          method: "POST", body: JSON.stringify({ teamId: team.id, data: { name: name!.trim(), organizationId: organization.id } }),
        }); else await api.updateTeam({ params: { path: { organizationId: organization.id, teamId: team.id } }, body: { name: name!.trim() } });
        await load();
      },
    });
  }

  function deleteTeam(team: TeamInfo) {
    openDialog({
      title: uiText("Delete team?", "チームを削除しますか？"),
      description: uiText(`“${team.name}” will be deleted. Members will lose access to Vaults shared through this team.`, `「${team.name}」を削除し、このチームを通じた保管庫へのアクセスを解除します。`),
      confirmLabel: uiText("Delete team", "チームを削除"), destructive: true,
      onSubmit: async () => {
        if (session.capabilities.sessions) await json("/api/auth/organization/remove-team", {
          method: "POST", body: JSON.stringify({ teamId: team.id, organizationId: organization.id }),
        }); else await api.deleteTeam({ params: { path: { organizationId: organization.id, teamId: team.id } } });
        await load();
      },
    });
  }

  async function setTeamMember(team: TeamInfo, userId: string, enabled: boolean) {
    if (pending) return;
    setPending(true);
    setError(undefined);
    try {
      if (session.capabilities.sessions) await json(`/api/auth/organization/${enabled ? "add" : "remove"}-team-member`, {
        method: "POST", body: JSON.stringify({ teamId: team.id, userId, organizationId: organization.id }),
      }); else {
        const params = { path: { organizationId: organization.id, teamId: team.id, userId } };
        await (enabled ? api.putTeamMember({ params }) : api.deleteTeamMember({ params }));
      }
      await load();
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Could not update team membership");
    } finally {
      setPending(false);
    }
  }

  const currentRole = members?.find((member) => member.userId === session.user.id)?.role;
  const canManage = ["owner", "admin"].includes(currentRole ?? "");
  const teamMemberIds = useMemo(() => Object.fromEntries(
    Object.entries(teamMembers).map(([teamId, entries]) => [teamId, new Set(entries.map(({ userId }) => userId))]),
  ), [teamMembers]);
  const visibleMembers = members?.filter((member) => `${member.user.name} ${member.user.email}`.toLocaleLowerCase().includes(memberSearch.trim().toLocaleLowerCase()));
  return (
    <section className="organization-card">
      {dialog}
      <fieldset className="organization-controls" disabled={pending}>
      <DetailTabs label={uiText("Organization content", "組織の内容")} tabs={[
        { id: "members", label: <>{uiText("Members", "メンバー")}{members && <> <span className="org-count">{members.length}</span></>}</>, content: <>
          <div className="org-section-header org-member-toolbar">
            {members && members.length > 0 && <input className="org-search" type="search" aria-label={uiText("Find members", "メンバーを検索")} placeholder={uiText("Search by name or email", "名前・メールアドレスで検索")} value={memberSearch} onChange={(event) => setMemberSearch(event.target.value)} />}
            {session.capabilities.sessions && canManage && <button className="primary" onClick={invite}><MenuIcon name="plus" />{uiText("Invite member", "メンバーを招待")}</button>}
          </div>
          {visibleMembers?.length === 0 && <p className="empty-state">{uiText("No matching members.", "該当するメンバーはいません。")}</p>}
          {!members && !error && <p className="muted">{uiText("Loading members…", "メンバーを読み込み中…")}</p>}
          {visibleMembers?.map((member) => (
            <div className="member-row organization-row" key={member.id}>
              <div className="org-person"><span className="org-avatar" aria-hidden="true">{(member.user.name || member.user.email).slice(0, 1).toLocaleUpperCase()}</span><div><strong>{member.user.name || member.user.email}{member.userId === session.user.id && <small className="org-you">{uiText("You", "あなた")}</small>}</strong><span>{member.user.email}</span></div></div>
              <span className="org-role">{member.role === "owner" ? uiText("Owner", "所有者") : member.role === "admin" ? uiText("Administrator", "管理者") : uiText("Member", "メンバー")}</span>
              {session.capabilities.sessions && canManage && member.userId !== session.user.id && (
                <button className="secondary danger-button" onClick={() => removeMember(member)}>{uiText("Remove", "解除")}</button>
              )}
            </div>
          ))}
          {session.capabilities.sessions && canManage && (
            <>
              <h3>{uiText("Pending invitations", "承認待ちの招待")}</h3>
              {invitations?.length === 0 && <p className="muted">{uiText("No pending invitations.", "承認待ちの招待はありません。")}</p>}
              {invitations?.map((invitation) => (
                <div className="member-row organization-row" key={invitation.id}>
                  <div><strong>{invitation.email}</strong><span>{uiText("Expires", "有効期限")} {new Date(invitation.expiresAt).toLocaleString()}</span></div>
                  <button className="secondary danger-button" onClick={() => void cancelInvitation(invitation)}>{uiText("Cancel", "キャンセル")}</button>
                </div>
              ))}
              {invitationLink && <div className="org-invitation-result" role="status">
                <strong>{uiText("Invitation link ready", "招待リンクを作成しました")}</strong>
                <p>{uiText("Share this link with the invited person.", "招待した相手にこのリンクを共有してください。")}</p>
                <div className="org-copy-row"><input aria-label={uiText("Invitation link", "招待リンク")} readOnly value={invitationLink} onFocus={(event) => event.target.select()} />
                  <button className="secondary" onClick={() => void copyInvitation()}>{copied ? uiText("Copied", "コピーしました") : uiText("Copy link", "リンクをコピー")}</button></div>
              </div>}
            </>
          )}
        </> },
        { id: "teams", label: <>{uiText("Teams", "チーム")}{invitations && <> <span className="org-count">{teams.length}</span></>}</>, content: <>
          <div className="org-section-header"><div><p>{uiText("Share Vaults with a smaller group. Open a team to see its members.", "チーム単位で保管庫を共有できます。チームを開いてメンバーを確認します。")}</p></div>
            {canManage && <button className="primary" onClick={createTeam}><MenuIcon name="plus" />{uiText("Create team", "チームを作成")}</button>}</div>
          {invitations && teams.length === 0 && <div className="empty-state"><strong>{uiText("No teams yet", "チームはまだありません")}</strong><span>{uiText("Create a team for the people you share with regularly.", "よく共有するメンバーをチームにまとめられます。")}</span></div>}
          {teams.map((team) => (
            <details className="team-block" key={team.id}>
              <summary className="org-team-summary"><MenuIcon name="organization" /><strong>{team.name}</strong><span>{teamMembers[team.id] ? uiText(`${teamMembers[team.id]!.length} members`, `${teamMembers[team.id]!.length}名のメンバー`) : uiText("Team", "チーム")}</span></summary>
              <div className="org-team-content"><div className="org-team-toolbar"><p>{canManage ? uiText("Select members. Changes are saved immediately.", "メンバーを選択すると、変更がすぐに保存されます。") : uiText("Team members", "チームのメンバー")}</p>
                {canManage && (
                  <div className="row-actions">
                    <button className="secondary" onClick={() => renameTeam(team)}>{uiText("Rename", "名前を変更")}</button>
                    <button className="secondary danger-button" onClick={() => deleteTeam(team)}>{uiText("Delete", "削除")}</button>
                  </div>
                )}
              </div>
              {(!session.capabilities.sessions || canManage) && members?.map((member) => (
                <label className="share-row" key={`${team.id}-${member.userId}`}>
                  <span><strong>{member.user.name || member.user.email}</strong><small>{member.user.email}</small></span>
                  <input
                    type="checkbox"
                    disabled={!canManage}
                    checked={teamMemberIds[team.id]?.has(member.userId) === true}
                    onChange={(event) => void setTeamMember(team, member.userId, event.target.checked)}
                  />
                </label>
              ))}
              {session.capabilities.sessions && !canManage && <p className="muted">{uiText("Ask an organization administrator to manage this team's members.", "メンバーの管理は組織の管理者にお問い合わせください。")}</p>}
              </div>
            </details>
          ))}
        </> },
        { id: "settings", label: uiText("Settings", "設定"), content: <>
          <section className="org-settings-info">
            <h3>{uiText("General", "基本情報")}</h3>
            <dl className="org-settings-fields">
              <div><dt>{uiText("Organization name", "組織名")}</dt><dd>{organization.name}</dd></div>
              <div><dt>slug</dt><dd><code>{organization.slug}</code></dd></div>
            </dl>
          </section>
          {session.capabilities.sessions && currentRole === "owner" && <section className="org-danger-zone">
            <div><h3>{uiText("Delete organization", "組織を削除")}</h3><p>{uiText("Permanently delete this organization and its teams. Shared access will be removed; Vaults will remain.", "組織とチームを削除し、共有アクセスを解除します。保管庫そのものは残ります。この操作は取り消せません。")}</p></div>
            <button className="secondary danger-button" onClick={deleteOrganization}>{uiText("Delete organization", "組織を削除")}</button>
          </section>}
        </> },
      ]} />
      </fieldset>
      {pending && <p className="muted" role="status">{uiText("Saving changes…", "変更を保存中…")}</p>}
      {error && <div className="org-error" role="alert"><p className="error">{error}</p><button className="secondary" disabled={pending} onClick={() => void load()}>{uiText("Reload", "再読み込み")}</button></div>}
    </section>
  );
}

function Organization({ session, slug }: { session: SessionInfo; slug: string }) {
  const query = useLiveJSON<OrganizationInfo[]>(session.capabilities.sessions ? "/api/auth/organization/list" : mapQuery(apiQuery("listOrganizations", {}), ({ items }) => items));
  const organization = query.data?.find((item) => encodeURIComponent(item.slug) === slug);
  return <>
    <nav className="detail-breadcrumbs" aria-label={uiText("Breadcrumbs", "パンくず")}>
      <a className="text-link" href="/organizations">{uiText("Your organizations", "所属組織")}</a>
    </nav>
    <PageHeader title={organization?.name ?? uiText("Organization", "組織")} />
    <DataError error={query.error} retry={query.reload} />
    {!query.data && query.loading && <p role="status">{uiText("Loading organization…", "組織を読み込み中…")}</p>}
    {query.data && !organization && <p role="alert">{uiText("Organization not found or you no longer have access.", "組織が見つからないか、アクセス権がありません。")}</p>}
    {organization && <OrganizationDetails key={organization.id} organization={organization} session={session} />}
  </>;
}

function Organizations({ session }: { session: SessionInfo }) {
  const [organizations, setOrganizations] = useState<OrganizationInfo[]>();
  const [invitations, setInvitations] = useState<OrganizationInvitation[]>();
  const { dialog, openDialog } = useActionDialog();
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string>();
  const load = useCallback(async () => {
    setError(undefined);
    try {
      const accounts = session.capabilities.sessions;
      const [organizationItems, invitationItems] = await Promise.all([
        accounts ? json<OrganizationInfo[]>("/api/auth/organization/list") : api.listOrganizations({}).then(({ items }) => items),
        accounts ? json<OrganizationInvitation[]>("/api/auth/organization/list-user-invitations") : Promise.resolve([]),
      ]);
      setOrganizations(organizationItems);
      setInvitations(invitationItems.filter((invitation) => invitation.status === "pending"));
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Could not load organizations");
    }
  }, [session.capabilities.sessions]);
  useEffect(() => { void load(); }, [load]);

  function create() {
    openDialog({
      title: uiText("Create organization", "組織を作成"),
      description: uiText("Use lowercase letters, numbers and hyphens for the slug.", "slugには半角英小文字・数字・ハイフンを使用してください。"),
      confirmLabel: uiText("Create organization", "組織を作成"),
      fields: [{ name: "name", label: uiText("Name", "名前"), required: true },
        { name: "slug", label: "slug", required: true, pattern: "(?:[a-z0-9]|-)+" }],
      onSubmit: async ({ name, slug }) => {
        const organization = await json<OrganizationInfo>("/api/auth/organization/create", {
          method: "POST", body: JSON.stringify({ name: name!.trim(), slug: slug!.trim() }),
        });
        navigateDashboard(`/organizations/${encodeURIComponent(organization.slug)}`);
      },
    });
  }

  async function decide(invitationId: string, accept: boolean) {
    if (pending) return;
    setPending(true);
    setError(undefined);
    try {
      await json(`/api/auth/organization/${accept ? "accept" : "reject"}-invitation`, {
        method: "POST",
        body: JSON.stringify({ invitationId }),
      });
      await load();
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Could not update invitation");
    } finally {
      setPending(false);
    }
  }

  return (
    <>
      {dialog}
      <PageHeader title={uiText("Your organizations", "所属組織")} description={uiText("Choose an organization to manage its members and teams.", "組織を選んで、メンバーやチームを管理します。")}
        actions={session.capabilities.sessions && <button className="primary" onClick={create}><MenuIcon name="plus" />{uiText("Create organization", "組織を作成")}</button>} />
      {invitations && invitations.length > 0 && (
        <section className="section-block">
          <h2 className="section-label">{uiText("Invitations", "招待")}</h2>
          <div className="panel admin-list">
            {invitations.map((invitation) => (
              <div className="member-row organization-row" key={invitation.id}>
                <div><strong>{invitation.organizationName}</strong><span>{uiText("Expires", "有効期限")} {new Date(invitation.expiresAt).toLocaleString()}</span></div>
                <div className="row-actions">
                  <button className="secondary" disabled={pending} onClick={() => void decide(invitation.id, false)}>{uiText("Decline", "辞退")}</button>
                  <button className="primary" disabled={pending} onClick={() => void decide(invitation.id, true)}>{uiText("Accept", "参加")}</button>
                </div>
              </div>
            ))}
          </div>
        </section>
      )}
      <section className="section-block organization-list">
        <h2 className="section-label">{uiText("Your organizations", "参加している組織")}</h2>
        {!organizations && !error && <p className="muted">{uiText("Loading organizations…", "組織を読み込み中…")}</p>}
        {organizations?.length === 0 && <div className="panel empty-state"><strong>{uiText("No organizations", "参加している組織はありません")}</strong><span>{uiText("Create an organization or ask its administrator for an invitation link.", "組織を作成するか、管理者から招待リンクを受け取って参加してください。")}</span></div>}
        <div className="collection-list">{organizations?.map((organization) => (
          <a className="collection-row" href={`/organizations/${encodeURIComponent(organization.slug)}`} key={organization.id}>
            <span className="collection-icon"><MenuIcon name="organization" /></span>
            <span className="collection-copy"><strong>{organization.name}</strong><small>{organization.slug}</small></span>
            <MenuIcon name="arrow" />
          </a>
        ))}</div>
      </section>
      {error && <div className="org-error" role="alert"><p className="error">{error}</p><button className="secondary" onClick={() => void load()}>{uiText("Reload", "再読み込み")}</button></div>}
    </>
  );
}

function Invitation({ invitationId }: { invitationId: string }) {
  const [invitation, setInvitation] = useState<OrganizationInvitation>();
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string>();
  useEffect(() => {
    void json<OrganizationInvitation>(`/api/auth/organization/get-invitation?id=${encodeURIComponent(invitationId)}`)
      .then(setInvitation)
      .catch((caught: Error) => setError(caught.message));
  }, [invitationId]);

  async function decide(accept: boolean) {
    if (pending) return;
    setPending(true);
    setError(undefined);
    try {
      await json(`/api/auth/organization/${accept ? "accept" : "reject"}-invitation`, {
        method: "POST",
        body: JSON.stringify({ invitationId }),
      });
      navigateDashboard("/organizations");
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Could not update invitation");
    } finally {
      setPending(false);
    }
  }

  return (
    <>
      <PageHeader title={uiText("Organization invitation", "組織への招待")} />
      <section className="panel invitation-card">
        {!invitation && !error && <p className="muted" role="status">{uiText("Loading invitation…", "招待を読み込み中…")}</p>}
        {invitation && (
          <>
            <h2>{uiText(`Join ${invitation.organizationName}`, `「${invitation.organizationName}」に参加`)}</h2>
            <p>{uiText("Accept to join this organization.", "招待を承認すると、この組織のメンバーになります。")}</p><p className="muted">{uiText("Expires", "有効期限")} {new Date(invitation.expiresAt).toLocaleString()}</p>
            <div className="button-row">
              <button className="secondary" disabled={pending} onClick={() => void decide(false)}>{uiText("Decline", "辞退")}</button>
              <button className="primary" disabled={pending} onClick={() => void decide(true)}>{uiText("Accept invitation", "招待を承認")}</button>
            </div>
          </>
        )}
        {error && <p className="error">{error}</p>}
      </section>
    </>
  );
}

function AdminDirectory({ kind }: { kind: "users" | "organizations" }) {
  const [offset, setOffset] = useState(0);
  const query = useLiveJSON<{ items: (ServerUserRecord | ServerOrganizationRecord)[]; hasMore: boolean }>(kind === "users" ? apiQuery("listServerUsers", { params: { query: { offset: String(offset) } } }) : apiQuery("listServerOrganizations", { params: { query: { offset: String(offset) } } }));
  const organizations = kind === "organizations";
  return <>
    <PageHeader title={organizations ? uiText("Organization management", "組織管理") : uiText("User management", "ユーザー管理")}
      description={organizations ? uiText("All organizations on this server, including those you have not joined.", "所属していない組織を含む、サーバー内のすべての組織です。") : uiText("All users registered on this server.", "このサーバーに登録されているすべてのユーザーです。")}
      actions={organizations && <a className="secondary" href="/organizations">{uiText("Manage your organizations", "所属組織を管理")}</a>} />
    <section className="section-block">
      <DataError error={query.error} retry={query.reload} />
      {query.loading && <p role="status">{uiText("Loading…", "読み込み中…")}</p>}
      {query.data && <><div className="admin-directory-scroll"><table className={`admin-directory${organizations ? " org-directory" : ""}`}>
        <thead><tr><th>{uiText("Name", "名前")}</th><th>{organizations ? "slug" : uiText("Email address", "メールアドレス")}</th><th>{organizations ? uiText("Members", "メンバー") : uiText("Role", "権限")}</th>{organizations && <th>{uiText("Teams", "チーム")}</th>}</tr></thead>
        <tbody>{query.data.items.map((item) => <tr key={item.id}>
          <td>{organizations ? <span className="org-directory-identity"><MenuIcon name="organization" /><strong>{item.name}</strong></span> : item.name}</td>{"email" in item ? <><td>{item.email}</td><td>{item.role?.split(",").includes("admin") ? uiText("Administrator", "管理者") : uiText("User", "ユーザー")}</td></>
            : <><td><code>{item.slug}</code></td><td>{item.memberCount}</td><td>{item.teamCount}</td></>}
        </tr>)}</tbody>
      </table></div>
      {!query.data.items.length && <p className="muted">{uiText("No results", "該当する項目はありません")}</p>}
      {(offset > 0 || query.data.hasMore) && <div className="admin-pagination">
        <button className="secondary" disabled={query.loading || offset === 0} onClick={() => setOffset(offset - 100)}>{uiText("Previous", "前へ")}</button>
        <button className="secondary" disabled={query.loading || !query.data.hasMore} onClick={() => setOffset(offset + 100)}>{uiText("Next", "次へ")}</button>
      </div>}</>}
    </section>
  </>;
}

function AdminMembers() {
  const { dialog, openDialog } = useActionDialog();
  const [members, setMembers] = useState<AdminMember[]>();
  const [email, setEmail] = useState("");
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string>();
  const load = useCallback(() => {
    setError(undefined);
    void api.listAdministrators({}).then(({ items }) => setMembers(items)).catch((caught: Error) => setError(caught.message));
  }, []);
  useEffect(load, [load]);

  async function add(event: React.FormEvent) {
    event.preventDefault();
    if (pending) return;
    setPending(true);
    setError(undefined);
    try {
      await api.addAdministrator({ body: { email } });
      setEmail("");
      load();
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Could not add administrator");
    } finally {
      setPending(false);
    }
  }

  function remove(member: AdminMember) {
    openDialog({
      title: uiText("Remove administrator?", "管理者権限を解除しますか？"),
      description: uiText(`${member.email} will lose administrator access. Their personal account and meetings will remain.`, `${member.email} の管理者権限を解除します。個人アカウントとミーティングは残ります。`),
      confirmLabel: uiText("Remove access", "権限を解除"), destructive: true,
      onSubmit: async () => { await api.removeAdministrator({ params: { path: { userId: member.id } } }); load(); },
    });
  }

  return (
    <>
      {dialog}
      <section className="section-block">
        <h2 className="section-label">{uiText("Administrators", "管理者")}</h2>
        <div className="panel admin-list">
          {!members && !error && <p className="muted">{uiText("Loading administrators…", "管理者を読み込み中…")}</p>}
          {members?.length === 0 && <div className="empty-state"><strong>{uiText("No administrators", "管理者はいません")}</strong><span>{uiText("Add an email below.", "メールアドレスを入力して追加してください。")}</span></div>}
          {members?.map((member) => (
            <div className="admin-row member-row" key={member.id}>
              <div><strong>{member.email}</strong><span>{member.name} · Admin</span></div>
              <button className="secondary danger-button" disabled={!member.removable} onClick={() => remove(member)}>{uiText("Remove", "解除")}</button>
            </div>
          ))}
        </div>
      </section>
      <section className="section-block">
        <h2 className="section-label">{uiText("Add administrator", "管理者を追加")}</h2>
        <form className="panel admin-form member-form" onSubmit={(event) => void add(event)}>
          <label>{uiText("Email", "メールアドレス")}<input type="email" value={email} required placeholder="admin@example.com" onChange={(event) => setEmail(event.target.value)} /></label>
          <button className="primary" disabled={pending}>{pending ? uiText("Adding…", "追加中…") : uiText("Add administrator", "管理者を追加")}</button>
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
  return error ? <p className="error" role="alert">{error.message} <button className="secondary" onClick={retry}>{uiText("Retry", "再試行")}</button></p> : null;
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
    void api.getSession({ signal: controller.signal })
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

  const detailPath = path.match(/^\/(meetings|projects|files)\/([^/]+)$/);
  const detailQuery = useLiveJSON<{ vaultId: string }>(!session?.capabilities.sync || !detailPath ? undefined
    : detailPath[1] === "meetings" ? apiQuery("getMeeting", { params: { path: { meetingId: decodeURIComponent(detailPath[2]!) } } })
      : detailPath[1] === "projects" ? apiQuery("getProject", { params: { path: { projectId: decodeURIComponent(detailPath[2]!) } } })
        : apiQuery("getFile", { params: { path: { fileId: decodeURIComponent(detailPath[2]!) } } }));
  const detailVaultId = detailQuery.data?.vaultId;

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
  else if (route.page === "admin-users") page = <><AdminDirectory kind="users" /><AdminMembers /></>;
  else if (route.page === "admin-organizations") page = <AdminDirectory kind="organizations" />;
  else if (route.page === "admin-settings") page = <><PageHeader title={uiText("Server settings", "サーバー全体の設定")} /><p className="muted">{uiText("No settings are available yet.", "設定項目はまだありません。")}</p></>;
  else if (route.page === "vaults") page = <Vaults />;
  else if (route.page === "vault") page = <VaultMeetings session={session} vaultId={route.vaultId!} />;
  else if (route.page === "meeting") page = detailVaultId ? <SyncedMeeting vaultId={detailVaultId} meetingId={route.meetingId!} /> : null;
  else if (route.page === "project") page = detailVaultId ? <SyncedProject vaultId={detailVaultId} projectId={route.projectId!} /> : null;
  else if (route.page === "file") page = <FileViewer fileId={route.fileId!} />;
  else if (route.page === "organizations") page = <Organizations session={session} />;
  else if (route.page === "organization") page = <Organization session={session} slug={route.organizationSlug!} />;
  else if (route.page === "invitation") page = <Invitation invitationId={route.invitationId!} />;
  else if (route.page === "settings") page = <Settings session={session} extensions={extensions} />;
  else page = <Overview session={session} />;
  return <Shell brand={brand} extensions={extensions} session={session} path={path} navigate={navigateDashboard} routeVaultId={detailVaultId ?? route.vaultId}>
    <DataError error={sessionError ? new Error(sessionError) : undefined} retry={() => setSessionAttempt((attempt) => attempt + 1)} />
    {detailPath && !detailVaultId && route.page !== "file" && <>
      <DataError error={detailQuery.error} retry={detailQuery.reload} />
      {!detailQuery.error && <p className="content-empty">{uiText("Loading…", "読み込み中…")}</p>}
    </>}
    {page}
  </Shell>;
}
