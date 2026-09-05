import { Hono } from "hono";
import { secureHeaders } from "hono/secure-headers";

import { createApp } from "./app";
import { R2ObjectStorage, type R2BucketLike } from "./artifacts/r2";
import { S3ObjectStorage } from "./artifacts/s3";
import { initializeDahliaAuth } from "./auth/better-auth";
import {
  createD1ApplicationStore,
  createPostgresApplicationStore,
  type ApplicationStore,
  type D1DatabaseLike,
} from "./auth/store";
import { loadConfig, type AppConfig } from "./config";
import { connectPostgresUrl } from "./db/postgres";
import { createIntlSearchTokenizer } from "./search/tokenizer";

export interface RuntimeSecrets {
  BETTER_AUTH_SECRET?: string;
  CODEX_AUTO_REVIEW_MODEL?: string;
  DAHLIA_AI_BACKEND?: string;
  DAHLIA_AUTH_HEADER?: string;
  DAHLIA_AUTH_TYPE?: string;
  DAHLIA_APP_URL?: string;
  DAHLIA_DATABASE_TYPE?: string;
  DAHLIA_DATABASE_URL?: string;
  DAHLIA_MAX_REQUEST_BYTES?: string;
  DAHLIA_SYNC_SHARING_ENABLED?: string;
  DAHLIA_STORAGE_BACKEND?: string;
  DAHLIA_ARTIFACT_BACKEND?: string;
  DAHLIA_STORAGE_LOCAL_PATH?: string;
  DAHLIA_STORAGE_S3_BUCKET?: string;
  DAHLIA_STORAGE_S3_ENDPOINT?: string;
  DAHLIA_ARTIFACT_MAX_BYTES?: string;
  AWS_ACCESS_KEY_ID?: string;
  AWS_REGION?: string;
  AWS_SECRET_ACCESS_KEY?: string;
  AWS_SESSION_TOKEN?: string;
  DAHLIA_OAUTH_REDIRECT_URIS?: string;
  GOOGLE_CLIENT_ID?: string;
  GOOGLE_CLIENT_SECRET?: string;
  DATABRICKS_APP_URL?: string;
  DATABRICKS_CLIENT_ID?: string;
  DATABRICKS_CLIENT_SECRET?: string;
  DATABRICKS_HOST?: string;
  DATABRICKS_MODEL_SCHEMA?: string;
  OPENAI_API_KEY?: string;
  OPENAI_BASE_URL?: string;
}

export interface WorkerEnv extends RuntimeSecrets {
  DAHLIA_STORAGE?: R2BucketLike;
  HYPERDRIVE?: { connectionString: string };
  dahlia_db_prod?: D1DatabaseLike;
}
export type WorkerApp = ReturnType<typeof createApp>;
export type WorkerAppInitializer = (env: WorkerEnv) => Promise<WorkerApp>;

const WORKER_DEFAULT_MAX_REQUEST_BYTES = 4 * 1024 * 1024;
const healthApp = new Hono();
healthApp.use("*", secureHeaders());
healthApp.get("/healthz", (context) => context.json({ status: "ok" }));

function createWorkerApplicationStore(config: AppConfig, env: WorkerEnv): ApplicationStore {
  if (config.databaseType === "d1") {
    if (!env.dahlia_db_prod) throw new Error("The dahlia_db_prod D1 binding is required");
    return createD1ApplicationStore(env.dahlia_db_prod, config.syncSharingEnabled);
  }
  if (config.databaseType === "hyperdrive") {
    if (!env.HYPERDRIVE) throw new Error("The HYPERDRIVE binding is required");
    const connection = connectPostgresUrl(env.HYPERDRIVE.connectionString, 5);
    return { ...createPostgresApplicationStore(connection.db, "postgres", undefined, config.syncSharingEnabled), close: connection.close };
  }
  if (config.databaseType === "postgres" && config.databaseUrl) {
    const connection = connectPostgresUrl(config.databaseUrl, 5);
    return { ...createPostgresApplicationStore(connection.db, "postgres", undefined, config.syncSharingEnabled), close: connection.close };
  }
  throw new Error("Worker storage supports DAHLIA_DATABASE_TYPE=d1, hyperdrive, or postgres");
}

export async function initializeWorkerApp(env: WorkerEnv): Promise<WorkerApp> {
  const config = loadConfig({
    BETTER_AUTH_SECRET: env.BETTER_AUTH_SECRET,
    CODEX_AUTO_REVIEW_MODEL: env.CODEX_AUTO_REVIEW_MODEL,
    DAHLIA_AI_BACKEND: env.DAHLIA_AI_BACKEND,
    DAHLIA_AUTH_HEADER: env.DAHLIA_AUTH_HEADER,
    DAHLIA_AUTH_TYPE: env.DAHLIA_AUTH_TYPE,
    DAHLIA_APP_URL: env.DAHLIA_APP_URL,
    DAHLIA_DATABASE_TYPE: env.DAHLIA_DATABASE_TYPE,
    DAHLIA_DATABASE_URL: env.DAHLIA_DATABASE_URL,
    DAHLIA_MAX_REQUEST_BYTES: String(Math.min(
      Number(env.DAHLIA_MAX_REQUEST_BYTES ?? WORKER_DEFAULT_MAX_REQUEST_BYTES),
      WORKER_DEFAULT_MAX_REQUEST_BYTES,
    )),
    DAHLIA_SYNC_SHARING_ENABLED: env.DAHLIA_SYNC_SHARING_ENABLED,
    DAHLIA_STORAGE_BACKEND: env.DAHLIA_STORAGE_BACKEND,
    DAHLIA_ARTIFACT_BACKEND: env.DAHLIA_ARTIFACT_BACKEND,
    DAHLIA_STORAGE_LOCAL_PATH: env.DAHLIA_STORAGE_LOCAL_PATH,
    DAHLIA_STORAGE_S3_BUCKET: env.DAHLIA_STORAGE_S3_BUCKET,
    DAHLIA_STORAGE_S3_ENDPOINT: env.DAHLIA_STORAGE_S3_ENDPOINT,
    DAHLIA_ARTIFACT_MAX_BYTES: env.DAHLIA_ARTIFACT_MAX_BYTES,
    AWS_ACCESS_KEY_ID: env.AWS_ACCESS_KEY_ID,
    AWS_REGION: env.AWS_REGION,
    AWS_SECRET_ACCESS_KEY: env.AWS_SECRET_ACCESS_KEY,
    AWS_SESSION_TOKEN: env.AWS_SESSION_TOKEN,
    DAHLIA_OAUTH_REDIRECT_URIS: env.DAHLIA_OAUTH_REDIRECT_URIS,
    GOOGLE_CLIENT_ID: env.GOOGLE_CLIENT_ID,
    GOOGLE_CLIENT_SECRET: env.GOOGLE_CLIENT_SECRET,
    DATABRICKS_APP_URL: env.DATABRICKS_APP_URL,
    DATABRICKS_CLIENT_ID: env.DATABRICKS_CLIENT_ID,
    DATABRICKS_CLIENT_SECRET: env.DATABRICKS_CLIENT_SECRET,
    DATABRICKS_HOST: env.DATABRICKS_HOST,
    DATABRICKS_MODEL_SCHEMA: env.DATABRICKS_MODEL_SCHEMA,
    OPENAI_API_KEY: env.OPENAI_API_KEY,
    OPENAI_BASE_URL: env.OPENAI_BASE_URL,
  });
  const applicationStore = createWorkerApplicationStore(config, env);
  try {
    const auth = config.authProvider === "accounts"
      ? await initializeDahliaAuth(config, applicationStore)
      : undefined;
    if (config.storageBackend === "local" || config.storageBackend === "databricks") {
      throw new Error(`Storage backend ${config.storageBackend} requires the Node runtime`);
    }
    const artifactStorage = config.storageBackend === "r2"
      ? new R2ObjectStorage(requiredR2Binding(env))
      : new S3ObjectStorage(config.storageS3!);
    return createApp({
      config,
      auth,
      authStore: applicationStore,
      artifactStorage,
      searchTokenizer: createIntlSearchTokenizer(),
    });
  } catch (error) {
    await applicationStore.close?.();
    throw error;
  }
}

function requiredR2Binding(env: WorkerEnv): R2BucketLike {
  if (!env.DAHLIA_STORAGE) throw new Error("The DAHLIA_STORAGE R2 binding is required");
  return env.DAHLIA_STORAGE;
}

export function createWorkerHandler(initialize: WorkerAppInitializer = initializeWorkerApp): ExportedHandler<WorkerEnv> {
  let appPromise: Promise<WorkerApp> | undefined;
  return {
    async fetch(request, env): Promise<Response> {
      if (new URL(request.url).pathname === "/healthz") return healthApp.fetch(request, env);
      appPromise ??= initialize(env).catch((error: unknown) => {
        appPromise = undefined;
        throw error;
      });
      return (await appPromise).fetch(request, env);
    },
  };
}

export default createWorkerHandler();
