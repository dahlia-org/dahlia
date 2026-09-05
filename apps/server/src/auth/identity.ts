import type { AuthInfo } from "@modelcontextprotocol/server";

import { gatewayResource, mcpResource, type AppConfig } from "../config";
import { createAccessTokenVerifier, type DahliaAuth } from "./better-auth";
import { hasApiScope, type ApiScope } from "./scopes";
import { personalWorkspaceId } from "./workspace";

export interface Identity {
  userId: string;
  email?: string;
  name?: string;
  workspaceId: string;
  source: "accounts" | "header";
  impersonated?: boolean;
}

export class AuthenticationError extends Error {
  constructor(message: string, readonly oauthChallenge = false) {
    super(message);
  }
}

export class IdentityProjectionError extends Error {
  constructor() {
    super("identity_projection_failed");
  }
}

export type IdentityUserProjector = (identity: Identity) => Promise<boolean>;

export class IdentityService {
  private readonly verifyAccessToken?: ReturnType<typeof createAccessTokenVerifier>;

  constructor(
    private readonly config: AppConfig,
    private readonly auth?: DahliaAuth,
    private readonly projectUser?: IdentityUserProjector,
  ) {
    this.verifyAccessToken = auth ? createAccessTokenVerifier(auth) : undefined;
  }

  async fromBrowser(request: Request): Promise<Identity> {
    if (this.config.authProvider === "accounts") {
      if (!this.auth) throw new AuthenticationError("Authentication is unavailable");
      const session = await this.auth.api.getSession({ headers: request.headers });
      if (!session) throw new AuthenticationError("Sign in required");
      return this.project({
        userId: session.user.id,
        email: session.user.email,
        name: session.user.name,
        workspaceId: personalWorkspaceId(session.user.id),
        source: "accounts",
        impersonated: Boolean(session.session.impersonatedBy),
      });
    }
    return this.fromHeader(request);
  }

  async fromGateway(
    request: Request,
    requiredScope: ApiScope,
  ): Promise<Identity> {
    if (this.config.authProvider !== "accounts") {
      return this.fromHeader(request);
    }
    if (!this.verifyAccessToken) throw new AuthenticationError("Authentication is unavailable");
    let claims: Awaited<ReturnType<NonNullable<typeof this.verifyAccessToken>>>;
    try {
      claims = await this.verifyAccessToken(request, {
        requiredScopes: [requiredScope],
        verifyOptions: {
          audience: gatewayResource(this.config),
          issuer: this.config.baseUrl,
        },
      });
    } catch {
      throw new AuthenticationError("Invalid or expired Dahlia access token", true);
    }
    if (claims.impersonated === true) {
      throw new AuthenticationError("Impersonated sessions are read-only", true);
    }
    if (typeof claims.sub !== "string" || typeof claims.workspace_id !== "string") {
      throw new AuthenticationError("Access token is missing Dahlia identity claims", true);
    }
    const email = typeof claims.email === "string" ? claims.email : undefined;
    return this.project({
      userId: claims.sub,
      email,
      workspaceId: claims.workspace_id,
      source: "accounts",
    });
  }

  async fromBrowserOrGateway(
    request: Request,
    requiredScope: ApiScope,
  ): Promise<Identity> {
    return request.headers.has("authorization")
      ? this.fromGateway(request, requiredScope)
      : this.fromBrowser(request);
  }

  async fromMcpHeader(request: Request): Promise<Identity> {
    return this.fromHeader(request);
  }

  async fromMcpResource(request: Request, requiredScope: ApiScope): Promise<Identity> {
    if (this.config.authProvider !== "accounts") return this.fromHeader(request);
    const authInfo = await this.verifyMcpAccessToken(request, new URL(request.url).pathname);
    if (!hasApiScope(authInfo.scopes, requiredScope)) {
      throw new AuthenticationError("Insufficient scope", true);
    }
    const identity = authInfo.extra?.identity;
    if (!isIdentity(identity)) throw new AuthenticationError("Access token is missing Dahlia identity claims", true);
    return identity;
  }

  async verifyMcpAccessToken(request: Request, canonicalPath = "/mcp"): Promise<AuthInfo> {
    if (!this.verifyAccessToken) throw new AuthenticationError("Authentication is unavailable", true);
    const resource = mcpResource(this.config);
    let claims: Record<string, unknown>;
    try {
      claims = await this.verifyAccessToken(new Request(new URL(canonicalPath, this.config.baseUrl), {
        method: request.method,
        headers: request.headers,
      }), {
        requiredScopes: [],
        verifyOptions: {
          audience: resource,
          issuer: this.config.baseUrl,
        },
      });
    } catch {
      throw new AuthenticationError("Invalid or expired Dahlia access token", true);
    }
    const clientId = typeof claims.client_id === "string"
      ? claims.client_id
      : typeof claims.azp === "string" ? claims.azp : undefined;
    if (
      typeof claims.sub !== "string"
      || typeof claims.workspace_id !== "string"
      || !clientId
      || typeof claims.exp !== "number"
    ) {
      throw new AuthenticationError("Access token is missing Dahlia MCP claims", true);
    }
    if (claims.impersonated === true) {
      throw new AuthenticationError("Impersonated sessions are read-only", true);
    }
    const token = request.headers.get("authorization")?.trim().split(/\s+/, 2)[1];
    if (!token) throw new AuthenticationError("Access token is missing", true);
    const scopes = typeof claims.scope === "string" ? claims.scope.split(" ").filter(Boolean) : [];
    const identity = await this.project({
      userId: claims.sub,
      email: typeof claims.email === "string" ? claims.email : undefined,
      workspaceId: claims.workspace_id,
      source: "accounts",
    });
    return {
      token,
      clientId,
      scopes,
      expiresAt: claims.exp,
      resource: new URL(resource),
      extra: {
        identity,
      },
    };
  }

  private async fromHeader(request: Request): Promise<Identity> {
    const email = request.headers.get(this.config.authHeader)?.trim().toLowerCase();
    if (!email) throw new AuthenticationError(`${this.config.authHeader} is missing`);
    const userId = request.headers.get("X-Forwarded-User")?.trim() || email;
    const name = request.headers.get("X-Forwarded-Preferred-Username")?.trim() || undefined;
    const identity: Identity = {
      userId,
      email,
      name,
      workspaceId: personalWorkspaceId(userId),
      source: "header",
    };
    return this.project(identity);
  }

  private async project(identity: Identity): Promise<Identity> {
    if (this.projectUser && !await this.projectUser(identity)) throw new IdentityProjectionError();
    return identity;
  }
}

function isIdentity(value: unknown): value is Identity {
  if (!value || typeof value !== "object") return false;
  const candidate = value as Partial<Identity>;
  return typeof candidate.userId === "string"
    && typeof candidate.workspaceId === "string"
    && (candidate.source === "accounts" || candidate.source === "header");
}
