import { z } from "zod";

export type AuthProvider = "accounts" | "header";
export type DatabaseType = "sqlite" | "postgres" | "lakebase" | "hyperdrive" | "d1";
export type AIBackend = "databricks" | "cloudflare" | "openai";
export type StorageBackend = "databricks" | "local" | "r2" | "s3";
/** @deprecated Use DatabaseType. */
export type AuthDatabaseBackend = DatabaseType;

export type ProviderConfig = {
  backend: "cloudflare" | "openai";
  apiKey: string;
  baseUrl: string;
} | {
  backend: "databricks";
  baseUrl: string;
};

export interface LakebaseDatabaseConfig {
  database: string;
  endpoint: string;
  host: string;
  port: number;
  sslMode: "disable" | "prefer" | "require";
  username: string;
}

export interface DatabricksWorkspaceConfig {
  host: string;
  clientId: string;
  clientSecret: string;
  tokenUrl: string;
}

export interface S3StorageConfig {
  accessKeyId: string;
  bucket: string;
  endpoint?: string;
  region: string;
  secretAccessKey: string;
  sessionToken?: string;
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
  storageBackend?: StorageBackend;
  storageLocalPath?: string;
  storageS3?: S3StorageConfig;
  storageDatabricksVolumePath?: string;
  artifactMaxBytes?: number;
  databricksWorkspace?: DatabricksWorkspaceConfig;
}

const authProviderSchema = z.enum(["accounts", "header"]);
const databaseTypeSchema = z.enum(["sqlite", "postgres", "lakebase", "hyperdrive", "d1"]);
const aiBackendSchema = z.enum(["databricks", "cloudflare", "openai"]);
const storageBackendSchema = z.enum(["databricks", "local", "r2", "s3"]);
const LOCAL_BASE_URL = "http://localhost:5173";
const LOCAL_DATABASE_URL = "file:.data/dahlia-auth.sqlite";
export const DEFAULT_ARTIFACT_MAX_BYTES = 64 * 1024 * 1024;

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

function databricksWorkspaceConfig(
  env: Record<string, string | undefined>,
  requiredForStorage: boolean,
): DatabricksWorkspaceConfig | undefined {
  if (!requiredForStorage) return undefined;
  const hostValue = required(env, "DATABRICKS_HOST");
  const host = validateBaseUrl(hostValue.includes("://") ? hostValue : `https://${hostValue}`, "DATABRICKS_HOST");
  if (new URL(host).pathname !== "/") throw new Error("DATABRICKS_HOST must be a workspace origin without a path");
  return {
    host,
    clientId: required(env, "DATABRICKS_CLIENT_ID"),
    clientSecret: required(env, "DATABRICKS_CLIENT_SECRET"),
    tokenUrl: `${host}/oidc/v1/token`,
  };
}

function providerConfig(
  env: Record<string, string | undefined>,
  databricks: DatabricksWorkspaceConfig | undefined,
): ProviderConfig | undefined {
  const backend = aiBackendSchema.parse(env.DAHLIA_AI_BACKEND?.trim() || "openai");
  if (backend === "databricks") {
    const hostValue = required(env, "DATABRICKS_HOST");
    const host = databricks?.host
      ?? validateBaseUrl(hostValue.includes("://") ? hostValue : `https://${hostValue}`, "DATABRICKS_HOST");
    if (new URL(host).pathname !== "/") throw new Error("DATABRICKS_HOST must be a workspace origin without a path");
    return {
      backend,
      baseUrl: `${host}/ai-gateway/mlflow/v1`,
    };
  }
  const apiKey = env.OPENAI_API_KEY?.trim();
  if (!apiKey) return undefined;
  return {
    backend,
    apiKey,
    baseUrl: validateBaseUrl(
      backend === "cloudflare"
        ? required(env, "OPENAI_BASE_URL")
        : env.OPENAI_BASE_URL?.trim() || "https://api.openai.com/v1",
      "OPENAI_BASE_URL",
    ),
  };
}

export function loadConfig(env: Record<string, string | undefined>): AppConfig {
  if (env.DAHLIA_ARTIFACT_BACKEND?.trim()) {
    throw new Error("DAHLIA_ARTIFACT_BACKEND was replaced by DAHLIA_STORAGE_BACKEND");
  }
  const authProvider = authProviderSchema.parse(env.DAHLIA_AUTH_TYPE?.trim() || "accounts");
  const databaseType = databaseTypeSchema.parse(env.DAHLIA_DATABASE_TYPE?.trim() || "sqlite");
  const configuredAppUrl = env.DAHLIA_APP_URL?.trim();
  const databricksAppUrl = env.DATABRICKS_APP_URL?.trim();
  const baseUrl = validateBaseUrl(
    configuredAppUrl || databricksAppUrl || LOCAL_BASE_URL,
    configuredAppUrl ? "DAHLIA_APP_URL" : databricksAppUrl ? "DATABRICKS_APP_URL" : "DAHLIA_APP_URL",
  );
  const maxRequestBytes = z.coerce
    .number()
    .int()
    .positive()
    .max(64 * 1024 * 1024)
    .parse(env.DAHLIA_MAX_REQUEST_BYTES ?? String(16 * 1024 * 1024));
  const storageBackend = storageBackendSchema.parse(env.DAHLIA_STORAGE_BACKEND?.trim() || "local");
  const databricksWorkspace = databricksWorkspaceConfig(env, storageBackend === "databricks");
  const artifactMaxBytes = z.coerce.number().int().positive().max(DEFAULT_ARTIFACT_MAX_BYTES)
    .parse(env.DAHLIA_ARTIFACT_MAX_BYTES ?? String(DEFAULT_ARTIFACT_MAX_BYTES));
  const storageDatabricksVolumePath = storageBackend === "databricks"
    ? required(env, "DAHLIA_STORAGE_DATABRICKS_VOLUME_PATH").replace(/\/$/, "")
    : undefined;
  if (storageDatabricksVolumePath && !/^\/Volumes\/[^/]+\/[^/]+\/[^/]+$/.test(storageDatabricksVolumePath)) {
    throw new Error("DAHLIA_STORAGE_DATABRICKS_VOLUME_PATH must identify a Unity Catalog Volume");
  }
  const storageS3 = storageBackend === "s3" ? {
    accessKeyId: required(env, "AWS_ACCESS_KEY_ID"),
    bucket: required(env, "DAHLIA_STORAGE_S3_BUCKET"),
    endpoint: env.DAHLIA_STORAGE_S3_ENDPOINT?.trim()
      ? validateBaseUrl(env.DAHLIA_STORAGE_S3_ENDPOINT.trim(), "DAHLIA_STORAGE_S3_ENDPOINT")
      : undefined,
    region: required(env, "AWS_REGION"),
    secretAccessKey: required(env, "AWS_SECRET_ACCESS_KEY"),
    sessionToken: env.AWS_SESSION_TOKEN?.trim() || undefined,
  } : undefined;
  if (storageS3?.endpoint && new URL(storageS3.endpoint).pathname !== "/") {
    throw new Error("DAHLIA_STORAGE_S3_ENDPOINT must be an origin without a path");
  }

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
    provider: providerConfig(env, databricksWorkspace),
    oauthRedirectUris: csv(env.DAHLIA_OAUTH_REDIRECT_URIS),
    maxRequestBytes,
    storageBackend,
    storageLocalPath: env.DAHLIA_STORAGE_LOCAL_PATH?.trim() || ".data/storage",
    storageS3,
    storageDatabricksVolumePath,
    artifactMaxBytes,
    databricksWorkspace,
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
