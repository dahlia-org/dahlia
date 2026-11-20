// Databricks workspace OAuth: the authorization code flow with PKCE and a loopback callback, as Dahlia for macOS signs in
// (docs/spec/desktop/accounts.md#chatgpt-と-databricks-workspace-oauth). Tokens, codes and callback queries never reach logs
// or error messages.
import { createHash, randomBytes } from "node:crypto";
import { createServer, type Server } from "node:http";

export const clientId = "databricks-cli";
export const scope = "offline_access all-apis";
const callbackPorts = Array.from({ length: 21 }, (_, index) => 8020 + index);
const signInTimeoutMs = 300_000;

export type Credential = {
  workspace: string;
  email: string;
  accessToken: string;
  refreshToken: string;
  expiresAt: number;
  tokenEndpoint: string;
};

type Endpoints = { authorization: string; token: string };
type Fetch = typeof fetch;

export class SignInError extends Error {}

/** The workspace origin from what the user typed: https only, with or without the scheme. */
export function workspaceOrigin(input: string): string {
  const trimmed = input.trim();
  let url: URL;
  try {
    url = new URL(/^[a-z][a-z0-9+.-]*:\/\//i.test(trimmed) ? trimmed : `https://${trimmed}`);
  } catch {
    throw new SignInError("invalidWorkspace");
  }
  if (url.protocol !== "https:" || !url.hostname.includes(".") || url.username || url.password) throw new SignInError("invalidWorkspace");
  return url.origin;
}

/** The workspace's OIDC endpoints; only https endpoints on the workspace itself are trusted. */
export async function discoverEndpoints(origin: string, fetcher: Fetch = fetch, signal?: AbortSignal): Promise<Endpoints> {
  const fallback = { authorization: `${origin}/oidc/v1/authorize`, token: `${origin}/oidc/v1/token` };
  try {
    const response = await fetcher(`${origin}/oidc/.well-known/oauth-authorization-server`, { redirect: "error", signal: AbortSignal.any([...(signal ? [signal] : []), AbortSignal.timeout(15_000)]) });
    if (!response.ok) return fallback;
    const body = (await response.json()) as { authorization_endpoint?: unknown; token_endpoint?: unknown };
    const trusted = (value: unknown) => {
      if (typeof value !== "string") return false;
      try {
        const url = new URL(value);
        return url.protocol === "https:" && url.origin === origin;
      } catch {
        return false;
      }
    };
    return trusted(body.authorization_endpoint) && trusted(body.token_endpoint)
      ? { authorization: body.authorization_endpoint as string, token: body.token_endpoint as string }
      : fallback;
  } catch {
    return fallback;
  }
}

export function pkce() {
  const verifier = randomBytes(64).toString("base64url");
  return { verifier, challenge: createHash("sha256").update(verifier).digest("base64url"), state: randomBytes(32).toString("base64url") };
}

/** Signs in through the system browser. `open` shows the authorization page; aborting `signal` cancels. */
export async function signIn(input: string, open: (url: string) => Promise<void>, signal: AbortSignal, fetcher: Fetch = fetch): Promise<Credential> {
  const workspace = workspaceOrigin(input);
  const timeout = AbortSignal.any([signal, AbortSignal.timeout(signInTimeoutMs)]);
  const checkCancellation = () => {
    if (timeout.aborted) throw new SignInError(signal.aborted ? "cancelled" : "timedOut");
  };
  checkCancellation();
  const endpoints = await discoverEndpoints(workspace, fetcher, timeout);
  checkCancellation();
  const { verifier, challenge, state } = pkce();
  const callback = Promise.withResolvers<string>();
  // A cancel can land while the browser opens, before anything awaits the callback.
  callback.promise.catch(() => {});
  const abort = () => callback.reject(new SignInError(signal.aborted ? "cancelled" : "timedOut"));
  timeout.addEventListener("abort", abort, { once: true });
  const server = createServer((request, response) => {
    const url = new URL(request.url ?? "/", "http://localhost");
    if (url.pathname !== "/") return void response.writeHead(404).end();
    const code = url.searchParams.get("state") === state ? url.searchParams.get("code") : null;
    response.writeHead(code ? 200 : 400, { "content-type": "text/html; charset=utf-8", "cache-control": "no-store", "referrer-policy": "no-referrer" })
      .end(callbackPage(Boolean(code)));
    if (code) callback.resolve(code);
    else callback.reject(new SignInError("denied"));
  });
  try {
    const redirectUri = `http://localhost:${await listen(server)}`;
    checkCancellation();
    const url = new URL(endpoints.authorization);
    url.search = new URLSearchParams({
      response_type: "code",
      client_id: clientId,
      redirect_uri: redirectUri,
      scope,
      state,
      code_challenge: challenge,
      code_challenge_method: "S256",
    }).toString();
    await open(url.href);
    const code = await callback.promise;
    checkCancellation();
    const tokens = await requestToken(endpoints.token, { grant_type: "authorization_code", code, redirect_uri: redirectUri, code_verifier: verifier }, undefined, fetcher, timeout);
    checkCancellation();
    const email = await fetchEmail(workspace, tokens.accessToken, fetcher, timeout);
    checkCancellation();
    return { workspace, email, tokenEndpoint: endpoints.token, ...tokens };
  } catch (error) {
    checkCancellation();
    throw error;
  } finally {
    timeout.removeEventListener("abort", abort);
    server.close();
  }
}

export async function refresh(credential: Credential, fetcher: Fetch = fetch): Promise<Credential> {
  const tokens = await requestToken(credential.tokenEndpoint, { grant_type: "refresh_token", refresh_token: credential.refreshToken }, credential.refreshToken, fetcher);
  return { ...credential, ...tokens };
}

async function requestToken(endpoint: string, parameters: Record<string, string>, previousRefresh: string | undefined, fetcher: Fetch, signal?: AbortSignal) {
  const response = await fetcher(endpoint, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    // The scope is sent again on exchange and refresh, as the workspace expects.
    body: new URLSearchParams({ client_id: clientId, scope, ...parameters }),
    redirect: "error",
    signal: AbortSignal.any([...(signal ? [signal] : []), AbortSignal.timeout(30_000)]),
  });
  if (!response.ok) throw new SignInError(response.status === 400 || response.status === 401 ? "expired" : "tokenFailed");
  const body = (await response.json()) as { access_token?: unknown; refresh_token?: unknown; expires_in?: unknown; token_type?: unknown };
  // Databricks may keep the refresh token instead of rotating it.
  const refreshToken = typeof body.refresh_token === "string" ? body.refresh_token : previousRefresh;
  if (typeof body.access_token !== "string" || typeof body.expires_in !== "number" || !(body.expires_in > 0) || !refreshToken
    || (typeof body.token_type === "string" && body.token_type.toLowerCase() !== "bearer")) {
    throw new SignInError("tokenFailed");
  }
  return { accessToken: body.access_token, refreshToken, expiresAt: Date.now() + body.expires_in * 1000 };
}

/** The signed-in user's email: SCIM `Me`'s userName. */
export async function fetchEmail(workspace: string, token: string, fetcher: Fetch = fetch, signal?: AbortSignal): Promise<string> {
  const response = await fetcher(`${workspace}/api/2.0/preview/scim/v2/Me`, {
    headers: { authorization: `Bearer ${token}` },
    redirect: "error",
    signal: AbortSignal.any([...(signal ? [signal] : []), AbortSignal.timeout(30_000)]),
  });
  if (!response.ok) throw new SignInError("identityFailed");
  const body = (await response.json()) as { userName?: unknown };
  if (typeof body.userName !== "string" || !body.userName) throw new SignInError("identityFailed");
  return body.userName;
}

// Listens on the first free port. `localhost` is served on 127.0.0.1; browsers fall back to it when ::1 refuses.
async function listen(server: Server): Promise<number> {
  for (const port of callbackPorts) {
    const listening = await new Promise<boolean>((resolve) => {
      const failed = () => {
        server.removeListener("listening", ready);
        resolve(false);
      };
      const ready = () => {
        server.removeListener("error", failed);
        resolve(true);
      };
      server.once("error", failed);
      server.once("listening", ready);
      server.listen(port, "127.0.0.1");
    });
    if (listening) return port;
  }
  throw new SignInError("noFreePort");
}

function callbackPage(succeeded: boolean) {
  const message = succeeded
    ? "Dahlia v2 にサインインしました。このタブを閉じてアプリに戻ってください。<br>Signed in to Dahlia v2. You can close this tab."
    : "サインインできませんでした。アプリに戻ってやり直してください。<br>Sign-in failed. Return to the app and try again.";
  return `<!doctype html><meta charset="utf-8"><title>Dahlia v2</title><body style="font:15px -apple-system,sans-serif;margin:4rem auto;max-width:32rem;color:#1A1C1F"><p>${message}</p></body>`;
}

/** Hands out a fresh access token, refreshing once for concurrent callers and saving before anyone uses the result. */
export class TokenSource {
  private refreshing?: Promise<Credential>;

  constructor(
    private credential: Credential | undefined,
    private readonly save: (credential: Credential | undefined) => void,
    private readonly fetcher: Fetch = fetch,
  ) {}

  get current() {
    return this.credential;
  }

  set(credential: Credential | undefined) {
    this.refreshing = undefined;
    this.save(credential);
    this.credential = credential;
  }

  async token(): Promise<{ workspace: string; token: string }> {
    const credential = this.credential;
    if (!credential) throw new SignInError("signedOut");
    if (credential.expiresAt - Date.now() > 60_000) return { workspace: credential.workspace, token: credential.accessToken };
    this.refreshing ??= refresh(credential, this.fetcher).then((next) => {
      // A sign-out or a new sign-in during the refresh wins over its result.
      if (this.credential !== credential) throw new SignInError("signedOut");
      this.save(next);
      this.credential = next;
      return next;
    }).finally(() => {
      this.refreshing = undefined;
    });
    const next = await this.refreshing;
    return { workspace: next.workspace, token: next.accessToken };
  }
}
