import { type ReactNode, useEffect, useState } from "react";
import { json, uiText } from "../api/api";
import { accountSignInRequired, beginSignIn } from "../api/auth";
import { type DashboardBrand } from "../app/dashboard";

export function Brand({ brand }: { brand: DashboardBrand }) {
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

export function AccountsOnly({ brand, children }: { brand: DashboardBrand; children: ReactNode }) {
  const [accountSignIn, setAccountSignIn] = useState<boolean>();
  const [authModeError, setAuthModeError] = useState<string>();
  const [authModeAttempt, setAuthModeAttempt] = useState(0);

  useEffect(() => {
    const controller = new AbortController();
    setAccountSignIn(undefined);
    setAuthModeError(undefined);
    void accountSignInRequired(controller.signal)
      .then((required) => {
        if (controller.signal.aborted) return;
        setAccountSignIn(required);
      })
      .catch((caught: unknown) => {
        if (!controller.signal.aborted) setAuthModeError(caught instanceof Error ? caught.message : "Could not load your account");
      });
    return () => controller.abort();
  }, [authModeAttempt]);

  if (accountSignIn) return children;
  if (accountSignIn === false) return <HeaderAuthenticationNotice brand={brand} />;
  return <main className="loading">
    <Brand brand={brand} />
    <span>{authModeError ?? uiText("Loading account…", "アカウントを読み込み中…")}</span>
    {authModeError && <button className="secondary" onClick={() => setAuthModeAttempt((attempt) => attempt + 1)}>{uiText("Try again", "再試行")}</button>}
  </main>;
}

export function HeaderAuthenticationNotice({ brand }: { brand: DashboardBrand }) {
  return <main className="loading">
    <Brand brand={brand} />
    <span>{uiText(
      "This deployment uses external authentication. Contact your administrator if you cannot sign in.",
      "この環境では外部認証を使用しています。サインインできない場合は管理者にお問い合わせください。",
    )}</span>
    <a className="secondary" href="/dashboard">{uiText("Return to dashboard", "ダッシュボードに戻る")}</a>
  </main>;
}

export function SignIn({ brand }: { brand: DashboardBrand }) {
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
          <p>{uiText("Find the decisions, details and next steps in your meetings. Sign in to access the Workspaces you sync with Dahlia for macOS.", "ミーティングで決まったこと、話した内容、次のアクションをすぐに確認。macOS 版 Dahlia と同期したワークスペースにアクセスできます。")}</p>
        </div>
        <button className="primary full" disabled={pending} onClick={() => void signIn()}>
          {pending ? uiText("Signing in…", "サインイン中…") : uiText("Continue with Google", "Google で続ける")}
        </button>
        {error && <p className="error">{error}</p>}
      </section>
    </main>
  );
}

export function OAuthConsentDetails({ query }: { query: string }) {
  const params = new URLSearchParams(query);
  const scopes = [...new Set(params.getAll("scope").flatMap((value) => value.split(/\s+/)).filter(Boolean))];
  const descriptions: Record<string, string> = {
    "mcp:memory:read": uiText("Read your personal memories and memories in Workspaces you can access.", "個人の記憶と、アクセスできる Workspace の記憶を読み取ります。"),
    "mcp:memory:write": uiText("Read, save, modify and delete your personal memories and memories in Workspaces you can edit. Shared saves and deletion require your explicit instruction.", "個人の記憶と、編集権限のある Workspace の記憶を読み取り・保存・変更・削除します。共有への保存と削除には明示的な依頼が必要です。"),
    mcp: uiText("Search and read meetings in your accessible Workspaces.", "アクセスできる Workspace の会議を検索・参照します。"),
    "mcp:read": uiText("Search and read meetings in your accessible Workspaces.", "アクセスできる Workspace の会議を検索・参照します。"),
    "all-apis": uiText("Use the Dahlia AI Gateway and authorized Dahlia APIs.", "Dahlia AI Gateway と認可された Dahlia API を利用します。"),
    openid: uiText("Identify your account.", "アカウントを識別します。"),
    profile: uiText("Read your profile.", "プロフィールを読み取ります。"),
    email: uiText("Read your email address.", "メールアドレスを読み取ります。"),
    offline_access: uiText("Keep access using refresh tokens until revoked.", "取り消されるまで更新トークンでアクセスを継続します。"),
  };
  return <div className="auth-copy">
    <h1>{uiText("Allow this client to access Dahlia?", "このクライアントに Dahlia へのアクセスを許可しますか？")}</h1>
    <dl>
      <dt>{uiText("Client ID", "クライアント ID")}</dt><dd className="break-all">{params.get("client_id") ?? uiText("Not specified", "未指定")}</dd>
      <dt>{uiText("Resources", "アクセス先")}</dt><dd>{params.getAll("resource").length ? params.getAll("resource").map((value) => <div className="break-all" key={value}>{value}</div>) : uiText("Dahlia default resource", "Dahlia の既定リソース")}</dd>
    </dl>
    <h2>{uiText("Requested permissions", "要求された権限")}</h2>
    <ul>{scopes.map((scope) => <li key={scope}><code>{scope}</code>: {descriptions[scope] ?? uiText("Additional requested permission", "追加の要求権限")}</li>)}</ul>
  </div>;
}

export function Consent({ brand }: { brand: DashboardBrand }) {
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
        <OAuthConsentDetails query={oauthQuery} />
        <div className="button-row">
          <button className="secondary" disabled={pending} onClick={() => void decide(false)}>{uiText("Cancel", "キャンセル")}</button>
          <button className="primary" disabled={pending} onClick={() => void decide(true)}>{uiText("Allow", "許可")}</button>
        </div>
        {error && <p className="error">{error}</p>}
      </section>
    </main>
  );
}
