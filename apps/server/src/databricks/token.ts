import type { DatabricksWorkspaceConfig } from "../config";

type DatabricksTokenConfig = Pick<DatabricksWorkspaceConfig, "clientId" | "clientSecret" | "tokenUrl">;

interface CachedToken {
  expiresAt: number;
  value: string;
}

const TOKEN_TIMEOUT_MS = 30_000;

export class DatabricksTokenError extends Error {
  constructor(message: string, readonly retryable = false) {
    super(message);
  }
}

export class DatabricksTokenProvider {
  private cached?: CachedToken;
  private pending?: Promise<CachedToken>;

  constructor(
    private readonly config: DatabricksTokenConfig,
    private readonly transport: typeof fetch = fetch,
  ) {}

  async getToken(): Promise<string> {
    if (this.cached && this.cached.expiresAt > Date.now() + 60_000) return this.cached.value;
    this.pending ??= this.requestToken();
    try {
      this.cached = await this.pending;
      return this.cached.value;
    } finally {
      this.pending = undefined;
    }
  }

  private async requestToken(): Promise<CachedToken> {
    let response: Response;
    try {
      response = await this.transport(this.config.tokenUrl, {
        method: "POST",
        headers: {
          authorization: `Basic ${btoa(`${this.config.clientId}:${this.config.clientSecret}`)}`,
          "content-type": "application/x-www-form-urlencoded",
        },
        body: new URLSearchParams({ grant_type: "client_credentials", scope: "all-apis" }),
        signal: AbortSignal.timeout(TOKEN_TIMEOUT_MS),
      });
    } catch {
      throw new DatabricksTokenError("Databricks authentication failed", true);
    }
    const body: unknown = await response.json().catch(() => undefined);
    if (!response.ok) {
      throw new DatabricksTokenError(
        "Databricks authentication failed",
        response.status === 429 || response.status >= 500,
      );
    }
    if (
      !body
      || typeof body !== "object"
      || !("access_token" in body)
      || typeof body.access_token !== "string"
      || !("expires_in" in body)
      || typeof body.expires_in !== "number"
    ) throw new DatabricksTokenError("Databricks authentication failed");
    return { value: body.access_token, expiresAt: Date.now() + body.expires_in * 1000 };
  }
}
