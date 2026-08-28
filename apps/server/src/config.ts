import { z } from "zod";

export type AuthProvider = "accounts" | "header";
export type DatabaseType = "sqlite" | "postgres" | "lakebase" | "hyperdrive" | "d1";
/** @deprecated Use DatabaseType. */
export type AuthDatabaseBackend = DatabaseType;

export interface ProviderConfig {
  apiKey: string;
  baseUrl: string;
}

export interface LakebaseDatabaseConfig {
  database: string;
  endpoint: string;
  host: string;
  port: number;
  sslMode: "disable" | "prefer" | "require";
  username: string;
}

export interface AppConfig {
  authProvider: AuthProvider;
  authHeader: string;
  databaseType: DatabaseType;
  databaseUrl?: string;
  lakebaseDatabase?: LakebaseDatabaseConfig;
  baseUrl: string;
  adminEmail?: string;
  provider?: ProviderConfig;
  googleClientId?: string;
  googleClientSecret?: string;
  betterAuthSecret?: string;
  oauthRedirectUris: string[];
  maxRequestBytes: number;
}

const authProviderSchema = z.enum(["accounts", "header"]);
const databaseTypeSchema = z.enum(["sqlite", "postgres", "lakebase", "hyperdrive", "d1"]);
const LOCAL_BASE_URL = "http://localhost:5173";
const LOCAL_DATABASE_URL = "file:.data/dahlia-auth.sqlite";

function csv(value: string | undefined): string[] {
  return value
    ?.split(",")
    .map((item) => item.trim())
    .filter(Boolean) ?? [];
}

function required(env: Record<string, string | undefined>, name: string): string {
  const value = env[name]?.trim();
  if (!value) throw new Error(`${name} is required`);
  return value;
}

function isLocalUrl(url: URL): boolean {
  const { hostname } = url;
  return hostname === "localhost" || hostname === "127.0.0.1" || hostname === "[::1]";
}

function validateBaseUrl(value: string, name: string): string {
  const url = new URL(value);
  if (url.protocol !== "https:" && !(url.protocol === "http:" && isLocalUrl(url))) {
    throw new Error(`${name} must use HTTPS except on localhost`);
  }
  url.search = "";
  url.hash = "";
  return url.toString().replace(/\/$/, "");
}

function loadDatabaseUrl(env: Record<string, string | undefined>, type: DatabaseType): string | undefined {
  if (type === "sqlite") {
    const value = env.DAHLIA_DATABASE_URL?.trim() || LOCAL_DATABASE_URL;
    if (!value.startsWith("file:")) throw new Error("DAHLIA_DATABASE_URL must use file: for SQLite storage");
    return value;
  }
  if (type !== "postgres") return undefined;
  const value = required(env, "DAHLIA_DATABASE_URL");
  let protocol: string;
  try {
    protocol = new URL(value).protocol;
  } catch {
    throw new Error("DAHLIA_DATABASE_URL must use postgres: or postgresql: for PostgreSQL storage");
  }
  if (protocol !== "postgres:" && protocol !== "postgresql:") {
    throw new Error("DAHLIA_DATABASE_URL must use postgres: or postgresql: for PostgreSQL storage");
  }
  return value;
}

function loadLakebaseDatabase(
  env: Record<string, string | undefined>,
  type: DatabaseType,
): LakebaseDatabaseConfig | undefined {
  if (type !== "lakebase") return undefined;
  return {
    database: required(env, "PGDATABASE"),
    endpoint: required(env, "LAKEBASE_ENDPOINT"),
    host: required(env, "PGHOST"),
    port: z.coerce.number().int().positive().parse(env.PGPORT ?? "5432"),
    sslMode: z.enum(["disable", "prefer", "require"]).parse(env.PGSSLMODE?.trim() || "require"),
    username: env.PGUSER?.trim() || required(env, "DATABRICKS_CLIENT_ID"),
  };
}

function providerConfig(env: Record<string, string | undefined>): ProviderConfig | undefined {
  const apiKey = env.OPENAI_API_KEY?.trim();
  if (!apiKey) return undefined;
  return {
    apiKey,
    baseUrl: validateBaseUrl(env.OPENAI_BASE_URL?.trim() || "https://api.openai.com/v1", "OPENAI_BASE_URL"),
  };
}

export function loadConfig(env: Record<string, string | undefined>): AppConfig {
  const authProvider = authProviderSchema.parse(env.DAHLIA_AUTH_PROVIDER?.trim() || "accounts");
  const databaseType = databaseTypeSchema.parse(env.DAHLIA_DATABASE_TYPE?.trim() || "sqlite");
  const baseUrl = validateBaseUrl(env.DAHLIA_BASE_URL?.trim() || LOCAL_BASE_URL, "DAHLIA_BASE_URL");
  const maxRequestBytes = z.coerce
    .number()
    .int()
    .positive()
    .max(64 * 1024 * 1024)
    .parse(env.DAHLIA_MAX_REQUEST_BYTES ?? String(16 * 1024 * 1024));

  const config: AppConfig = {
    authProvider,
    authHeader: env.DAHLIA_AUTH_HEADER?.trim() || "X-Forwarded-Email",
    databaseType,
    databaseUrl: loadDatabaseUrl(env, databaseType),
    lakebaseDatabase: loadLakebaseDatabase(env, databaseType),
    baseUrl,
    adminEmail: env.DAHLIA_ADMIN_EMAIL?.trim()
      ? z.email().parse(env.DAHLIA_ADMIN_EMAIL.trim().toLowerCase())
      : undefined,
    provider: providerConfig(env),
    oauthRedirectUris: csv(env.DAHLIA_OAUTH_REDIRECT_URIS),
    maxRequestBytes,
  };

  if (authProvider === "accounts") {
    config.betterAuthSecret = required(env, "BETTER_AUTH_SECRET");
    if (
      config.betterAuthSecret.length < 32
      || config.betterAuthSecret === "replace-with-at-least-32-random-characters"
    ) {
      throw new Error("BETTER_AUTH_SECRET must be a unique random value of at least 32 characters");
    }
    config.googleClientId = required(env, "GOOGLE_CLIENT_ID");
    config.googleClientSecret = required(env, "GOOGLE_CLIENT_SECRET");
    if (config.oauthRedirectUris.length === 0) {
      config.oauthRedirectUris = ["http://127.0.0.1:1455/oauth/callback"];
    }
  }

  return config;
}

export function gatewayResource(config: Pick<AppConfig, "baseUrl">): string {
  return `${config.baseUrl}/api/v1`;
}
