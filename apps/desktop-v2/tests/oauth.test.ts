import { describe, expect, it, vi } from "vitest";
import { discoverEndpoints, signIn, SignInError, TokenSource, workspaceOrigin, type Credential } from "../src/main/oauth.js";

const workspace = "https://dbc-1.cloud.databricks.com";
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

/** A workspace: discovery, the token endpoint and SCIM, recording each request. */
function fakeWorkspace(discovery: unknown = { authorization_endpoint: `${workspace}/oidc/v1/authorize`, token_endpoint: `${workspace}/oidc/v1/token` }) {
  const requests: { url: string; body?: URLSearchParams; authorization?: string }[] = [];
  const fetcher = vi.fn(async (input: string | URL | Request, init?: RequestInit) => {
    const url = String(input);
    const headers = new Headers(init?.headers);
    requests.push({ url, body: init?.body instanceof URLSearchParams ? init.body : undefined, authorization: headers.get("authorization") ?? undefined });
    if (url.endsWith("/oidc/.well-known/oauth-authorization-server")) return json(discovery);
    if (url.endsWith("/oidc/v1/token")) return json({ access_token: "access-1", refresh_token: "refresh-1", expires_in: 3600, token_type: "Bearer" });
    if (url.endsWith("/api/2.0/preview/scim/v2/Me")) return json({ userName: "user@example.com" });
    return json({}, 404);
  });
  return { fetcher: fetcher as unknown as typeof fetch, requests };
}

describe("workspaceOrigin", () => {
  it("takes the origin of an https workspace URL, adding the scheme when missing", () => {
    expect(workspaceOrigin("dbc-1.cloud.databricks.com/?o=1")).toBe(workspace);
    expect(workspaceOrigin(` ${workspace}/browse `)).toBe(workspace);
    for (const input of ["http://dbc-1.cloud.databricks.com", "localhost", "https://user:pw@dbc-1.cloud.databricks.com", ""]) {
      expect(() => workspaceOrigin(input)).toThrow(SignInError);
    }
  });
});

describe("discoverEndpoints", () => {
  it("uses discovered endpoints only when they are https on the workspace", async () => {
    expect(await discoverEndpoints(workspace, fakeWorkspace({ authorization_endpoint: `${workspace}/a`, token_endpoint: `${workspace}/t` }).fetcher))
      .toEqual({ authorization: `${workspace}/a`, token: `${workspace}/t` });
    expect(await discoverEndpoints(workspace, fakeWorkspace({ authorization_endpoint: "https://evil.example/a", token_endpoint: `${workspace}/t` }).fetcher))
      .toEqual({ authorization: `${workspace}/oidc/v1/authorize`, token: `${workspace}/oidc/v1/token` });
  });
});

describe("signIn", () => {
  it("runs the PKCE flow through the loopback callback and reads the user's email", async () => {
    const { fetcher, requests } = fakeWorkspace();
    let authorizeURL: URL | undefined;
    const credential = await signIn(workspace, async (url) => {
      authorizeURL = new URL(url);
      const redirect = new URL(authorizeURL.searchParams.get("redirect_uri")!);
      redirect.search = new URLSearchParams({ code: "the-code", state: authorizeURL.searchParams.get("state")! }).toString();
      void fetch(redirect);
    }, new AbortController().signal, fetcher);

    expect(authorizeURL?.origin + authorizeURL!.pathname).toBe(`${workspace}/oidc/v1/authorize`);
    expect(Object.fromEntries(authorizeURL!.searchParams)).toMatchObject({
      client_id: "databricks-cli", scope: "offline_access all-apis", response_type: "code", code_challenge_method: "S256",
    });
    expect(authorizeURL!.searchParams.get("redirect_uri")).toMatch(/^http:\/\/localhost:80[2-4]\d$/);
    const exchange = requests.find((request) => request.url.endsWith("/oidc/v1/token"))!.body!;
    expect(exchange.get("code")).toBe("the-code");
    expect(exchange.get("code_verifier")).toMatch(/^[A-Za-z0-9_-]{86}$/);
    expect(requests.find((request) => request.url.endsWith("/Me"))?.authorization).toBe("Bearer access-1");
    expect(credential).toMatchObject({ workspace, email: "user@example.com", accessToken: "access-1", refreshToken: "refresh-1" });
  });

  it("rejects a callback whose state does not match", async () => {
    const { fetcher } = fakeWorkspace();
    await expect(signIn(workspace, async (url) => {
      const redirect = new URL(new URL(url).searchParams.get("redirect_uri")!);
      redirect.search = "code=x&state=wrong";
      void fetch(redirect);
    }, new AbortController().signal, fetcher)).rejects.toThrow("denied");
  });

  it.each(["discovery", "token", "identity"])("rejects cancellation during %s even if the request returns successfully", async (phase) => {
    const controller = new AbortController();
    const { fetcher } = fakeWorkspace();
    const cancellingFetch: typeof fetch = async (url, init) => {
      const response = await fetcher(url, init);
      if ((phase === "discovery" && String(url).includes(".well-known"))
        || (phase === "token" && String(url).endsWith("/token"))
        || (phase === "identity" && String(url).endsWith("/Me"))) controller.abort();
      return response;
    };
    const open = vi.fn(async (url: string) => {
      const auth = new URL(url);
      const callback = new URL(auth.searchParams.get("redirect_uri")!);
      callback.search = new URLSearchParams({ code: "code", state: auth.searchParams.get("state")! }).toString();
      await fetch(callback);
    });
    await expect(signIn(workspace, open, controller.signal, cancellingFetch)).rejects.toThrow("cancelled");
    if (phase === "discovery") expect(open).not.toHaveBeenCalled();
  });

  it("does not open the browser when already cancelled", async () => {
    const controller = new AbortController();
    controller.abort();
    const open = vi.fn();
    await expect(signIn(workspace, open, controller.signal, fakeWorkspace().fetcher)).rejects.toThrow("cancelled");
    expect(open).not.toHaveBeenCalled();
  });

  it("stops waiting when cancelled", async () => {
    const controller = new AbortController();
    await expect(signIn(workspace, async () => controller.abort(), controller.signal, fakeWorkspace().fetcher)).rejects.toThrow("cancelled");
  });
});

describe("TokenSource", () => {
  const expired: Credential = { workspace, email: "u", accessToken: "old", refreshToken: "refresh-0", expiresAt: Date.now() - 1, tokenEndpoint: `${workspace}/oidc/v1/token` };

  it("refreshes once for concurrent callers and saves before handing the token out", async () => {
    const saved: (Credential | undefined)[] = [];
    let calls = 0;
    const fetcher = (async () => {
      calls++;
      // Not rotated: the previous refresh token stays.
      return json({ access_token: "new", expires_in: 3600 });
    }) as unknown as typeof fetch;
    const source = new TokenSource(expired, (credential) => saved.push(credential), fetcher);
    const tokens = await Promise.all([source.token(), source.token()]);
    expect(tokens.map((token) => token.token)).toEqual(["new", "new"]);
    expect(calls).toBe(1);
    expect(saved).toEqual([expect.objectContaining({ accessToken: "new", refreshToken: "refresh-0" })]);
    expect((await source.token()).token).toBe("new");
    expect(calls).toBe(1);
  });

  it("drops a refresh that finishes after sign-out", async () => {
    const { promise, resolve } = Promise.withResolvers<Response>();
    const saved: (Credential | undefined)[] = [];
    const source = new TokenSource(expired, (credential) => saved.push(credential), () => promise);
    const pending = source.token();
    source.set(undefined);
    resolve(json({ access_token: "late", expires_in: 3600 }));
    await expect(pending).rejects.toThrow("signedOut");
    expect(source.current).toBeUndefined();
    expect(saved).toEqual([undefined]);
  });

  it("reports an expired refresh token", async () => {
    const source = new TokenSource(expired, () => {}, async () => json({ error: "invalid_grant" }, 400));
    await expect(source.token()).rejects.toThrow("expired");
  });
});
