import ipaddr from "ipaddr.js";

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

export function trustedRemoteAddress(remoteAddress: string | undefined, cidrs: string[]): boolean {
  if (!remoteAddress) return false;
  let address: ipaddr.IPv4 | ipaddr.IPv6;
  try {
    address = ipaddr.process(remoteAddress);
  } catch {
    return false;
  }
  return cidrs.some((cidr) => {
    try {
      const [range, prefix] = ipaddr.parseCIDR(cidr);
      return address.kind() === range.kind() && address.match(range, prefix);
    } catch {
      return false;
    }
  });
}

export class IdentityService {
  private readonly verifyAccessToken?: ReturnType<typeof createAccessTokenVerifier>;

  constructor(
    private readonly config: AppConfig,
    private readonly auth?: DahliaAuth,
  ) {
    this.verifyAccessToken = auth ? createAccessTokenVerifier(auth) : undefined;
  }

  async fromBrowser(request: Request, remoteAddress?: string): Promise<Identity> {
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
    return this.fromHeader(request, remoteAddress);
  }

  async fromGateway(
    request: Request,
    requiredScope: GatewayScope,
    remoteAddress?: string,
  ): Promise<Identity> {
    if (this.config.authProvider !== "accounts") {
      return this.fromHeader(request, remoteAddress);
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

  private fromHeader(request: Request, remoteAddress?: string): Identity {
    if (
      this.config.trustedProxyCidrs.length > 0
      && !trustedRemoteAddress(remoteAddress, this.config.trustedProxyCidrs)
    ) {
      throw new AuthenticationError("Direct access is not allowed for header authentication");
    }
    const email = request.headers.get(this.config.authHeader)?.trim().toLowerCase();
    if (!email) throw new AuthenticationError(`${this.config.authHeader} is missing`);
    return {
      userId: email,
      email,
      workspaceId: personalWorkspaceId(email),
      source: "header",
    };
  }
}
