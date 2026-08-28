import { gatewayResource, type AppConfig } from "../config";
import { createAccessTokenVerifier, type DahliaAuth } from "./better-auth";
import type { GatewayScope } from "./scopes";
import { personalWorkspaceId } from "./workspace";

export interface Identity {
  userId: string;
  email?: string;
  name?: string;
  workspaceId: string;
  source: "accounts" | "header";
}

export class AuthenticationError extends Error {
  constructor(message: string, readonly oauthChallenge = false) {
    super(message);
  }
}

export class IdentityService {
  private readonly verifyAccessToken?: ReturnType<typeof createAccessTokenVerifier>;

  constructor(
    private readonly config: AppConfig,
    private readonly auth?: DahliaAuth,
  ) {
    this.verifyAccessToken = auth ? createAccessTokenVerifier(auth) : undefined;
  }

  async fromBrowser(request: Request): Promise<Identity> {
    if (this.config.authProvider === "accounts") {
      if (!this.auth) throw new AuthenticationError("Authentication is unavailable");
      const session = await this.auth.api.getSession({ headers: request.headers });
      if (!session) throw new AuthenticationError("Sign in required");
      return {
        userId: session.user.id,
        email: session.user.email,
        name: session.user.name,
        workspaceId: personalWorkspaceId(session.user.id),
        source: "accounts",
      };
    }
    return this.fromHeader(request);
  }

  async fromGateway(
    request: Request,
    requiredScope: GatewayScope,
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
    if (typeof claims.sub !== "string" || typeof claims.workspace_id !== "string") {
      throw new AuthenticationError("Access token is missing Dahlia identity claims", true);
    }
    const email = typeof claims.email === "string" ? claims.email : undefined;
    return {
      userId: claims.sub,
      email,
      workspaceId: claims.workspace_id,
      source: "accounts",
    };
  }

  private fromHeader(request: Request): Identity {
    const email = request.headers.get(this.config.authHeader)?.trim().toLowerCase();
    if (!email) throw new AuthenticationError(`${this.config.authHeader} is missing`);
    const userId = request.headers.get("X-Forwarded-User")?.trim() || email;
    const name = request.headers.get("X-Forwarded-Preferred-Username")?.trim() || undefined;
    return {
      userId,
      email,
      name,
      workspaceId: personalWorkspaceId(userId),
      source: "header",
    };
  }
}
