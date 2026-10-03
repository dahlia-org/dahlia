import { apiOperations as api } from "./generated-operations";
import { useActionDialog } from "./ActionDialog";
import { useCallback, useEffect, useState } from "react";
import { uiText } from "./api";
import { MenuIcon } from "./Sidebar";
import { Button } from "./components/ui/button";
import { PageHeader } from "./layout/AppShell";
import { type DashboardExtension, isServerNavigation, type SessionInfo } from "./dashboard";

interface DeviceSession {
  id: string;
  createdAt: string;
  expiresAt: string;
  userAgent: string | null;
  current: boolean;
}
export function Settings({ session, extensions }: { session: SessionInfo; extensions: readonly DashboardExtension[] }) {
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
      <PageHeader title={uiText("Account settings", "アカウント設定")} description={uiText("Manage your account and connected sessions. Desktop AI settings are stored on each Mac and are not synced.", "アカウントと接続中のセッションを管理します。デスクトップのAI設定は各Macに保存され、同期されません。")}
        actions={session.capabilities.sync && !session.capabilities.ai && <Button asChild variant="outline"><a href="/memory">Dahlia Memory</a></Button>} />
      <section className="section-block">
        <h2 className="section-label text-[15px] font-semibold text-foreground">{uiText("Account", "アカウント")}</h2>
        <div className="panel account-card"><dl className="account-details">
          <div><dt>{uiText("Name", "名前")}</dt><dd>{session.user.name || "—"}</dd></div>
          <div><dt>{uiText("Email address", "メールアドレス")}</dt><dd>{session.user.email || "—"}</dd></div>
        </dl></div>
      </section>
      {extensions.flatMap((extension) => extension.navigation ?? []).filter((item) => !isServerNavigation(item)).map((item) =>
        (!item.capability || session.capabilities[item.capability]) && <a className="inline-flex items-center gap-2 py-3 text-[13px] font-medium text-primary hover:underline" key={item.path} href={item.path}><MenuIcon name="document" />{item.label}</a>)}
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
                {session.current && <span className="inline-block rounded-full bg-emerald-50 px-2 py-1 text-[11px] font-bold text-emerald-700">{uiText("Current", "現在")}</span>}
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
