import { z } from "zod";

export type AuthProvider = "accounts" | "header";
export type AuthDatabaseBackend = "sqlite" | "postgres" | "d1";
export type DahliaRuntime = "cloudflare" | "databricks" | "custom";

export interface ProviderConfig {
  apiKey: string;
  baseUrl: string;
}

export interface DatabricksDatabaseConfig {
  clientId: string;
  clientSecret: string;
  workspaceUrl: string;
  database: string;
  endpoint: string;
  host: string;
  port: number;
  sslMode: "allow" | "prefer" | "require" | "verify-full";
  username: string;
}

export interface AppConfig {
  runtime: DahliaRuntime;
  authProvider: AuthProvider;
  authHeader: string;
  authDatabase: AuthDatabaseBackend;
  authDatabaseUrl?: string;
  databricksDatabase?: DatabricksDatabaseConfig;
  authSqlitePath?: string;
  baseUrl: string;
  adminEmail?: string;
  provider?: ProviderConfig;
  googleClientId?: string;
  googleClientSecret?: string;
  betterAuthSecret?: string;
  oauthRedirectUris: string[];
  trustedProxyCidrs: string[];
  maxRequestBytes: number;
}

const authProviderSchema = z.enum(["accounts", "header"]);
const authDatabaseSchema = z.enum(["sqlite", "postgres", "d1"]);
const customAuthDatabaseSchema = z.enum(["sqlite", "postgres"]);
const runtimeSchema = z.enum(["cloudflare", "databricks", "custom"]);
const LOCAL_BASE_URL = "http://localhost:5173";
const LOCAL_AUTH_SQLITE_PATH = ".data/dahlia-auth.sqlite";

const runtimeDefaults = {
  cloudflare: { authProvider: "accounts", authDatabase: "d1" },
  databricks: { authProvider: "header", authDatabase: "postgres" },
  custom: { authProvider: "accounts", authDatabase: "sqlite" },
} as const satisfies Record<DahliaRuntime, {
  authProvider: AuthProvider;
  authDatabase: AuthDatabaseBackend;
}>;

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

function fixedRuntimeValue(
  configured: string | undefined,
  expected: string,
  name: string,
  runtime: Exclude<DahliaRuntime, "custom">,
): string {
  if (configured && configured !== expected) {
    throw new Error(`${name} must be ${expected} when DAHLIA_RUNTIME=${runtime}`);
  }
  return expected;
}

function proxyCidrs(
  env: Record<string, string | undefined>,
  runtime: DahliaRuntime,
  authProvider: AuthProvider,
  baseUrl: string,
): string[] {
  const configured = csv(env.DAHLIA_TRUSTED_PROXY_CIDRS);
  if (configured.length > 0 || runtime !== "custom" || authProvider !== "header") return configured;
  if (isLocalUrl(new URL(baseUrl))) return ["127.0.0.0/8", "::1/128"];
  throw new Error("DAHLIA_TRUSTED_PROXY_CIDRS is required for custom header authentication");
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
  const runtime = runtimeSchema.parse(env.DAHLIA_RUNTIME?.trim() || "custom");
  const defaults = runtimeDefaults[runtime];
  const authProvider = runtime === "custom"
    ? authProviderSchema.parse(env.DAHLIA_AUTH_PROVIDER?.trim() || defaults.authProvider)
    : authProviderSchema.parse(fixedRuntimeValue(
        env.DAHLIA_AUTH_PROVIDER?.trim(),
        defaults.authProvider,
        "DAHLIA_AUTH_PROVIDER",
        runtime,
      ));
  const authDatabase = runtime === "custom"
    ? customAuthDatabaseSchema.parse(env.DAHLIA_AUTH_DATABASE?.trim() || defaults.authDatabase)
    : authDatabaseSchema.parse(fixedRuntimeValue(
        env.DAHLIA_AUTH_DATABASE?.trim(),
        defaults.authDatabase,
        "DAHLIA_AUTH_DATABASE",
        runtime,
      ));
  const baseUrl = validateBaseUrl(env.DAHLIA_BASE_URL?.trim() || LOCAL_BASE_URL, "DAHLIA_BASE_URL");
  const maxRequestBytes = z.coerce
    .number()
    .int()
    .positive()
    .max(64 * 1024 * 1024)
    .parse(env.DAHLIA_MAX_REQUEST_BYTES ?? String(16 * 1024 * 1024));

  const config: AppConfig = {
    runtime,
    authProvider,
    authDatabase,
    authHeader: env.DAHLIA_AUTH_HEADER?.trim() || "X-Forwarded-Email",
    baseUrl,
    adminEmail: env.DAHLIA_ADMIN_EMAIL?.trim()
      ? z.email().parse(env.DAHLIA_ADMIN_EMAIL.trim().toLowerCase())
      : undefined,
    provider: providerConfig(env),
    oauthRedirectUris: csv(env.DAHLIA_OAUTH_REDIRECT_URIS),
    trustedProxyCidrs: proxyCidrs(env, runtime, authProvider, baseUrl),
    maxRequestBytes,
  };

  if (authDatabase === "sqlite") {
    config.authSqlitePath = env.DAHLIA_AUTH_SQLITE_PATH?.trim() || LOCAL_AUTH_SQLITE_PATH;
  } else if (authDatabase === "postgres" && runtime === "databricks") {
    config.databricksDatabase = {
      workspaceUrl: validateBaseUrl(required(env, "DATABRICKS_HOST"), "DATABRICKS_HOST"),
      clientId: required(env, "DATABRICKS_CLIENT_ID"),
      clientSecret: required(env, "DATABRICKS_CLIENT_SECRET"),
      database: required(env, "PGDATABASE"),
      endpoint: required(env, "ENDPOINT_NAME"),
      host: required(env, "PGHOST"),
      port: z.coerce.number().int().positive().parse(env.PGPORT ?? "5432"),
      sslMode: z.enum(["allow", "prefer", "require", "verify-full"]).parse(env.PGSSLMODE?.trim() || "require"),
      username: required(env, "PGUSER"),
    };
  } else if (authDatabase === "postgres") {
    config.authDatabaseUrl = required(env, "DATABASE_URL");
  }

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
