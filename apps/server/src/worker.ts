import { Hono } from "hono";
import { secureHeaders } from "hono/secure-headers";

import { createApp } from "./app";
import { R2ArtifactStorage, type R2BucketLike } from "./artifacts/r2";
import { initializeDahliaAuth } from "./auth/better-auth";
import {
  createD1ApplicationStore,
  createPostgresApplicationStore,
  type ApplicationStore,
  type D1DatabaseLike,
} from "./auth/store";
import { loadConfig, type AppConfig } from "./config";
import { connectPostgresUrl } from "./db/postgres";

export interface RuntimeSecrets {
  BETTER_AUTH_SECRET?: string;
  DAHLIA_ADMIN_EMAIL?: string;
  DAHLIA_AI_BACKEND?: string;
  DAHLIA_AUTH_HEADER?: string;
  DAHLIA_AUTH_TYPE?: string;
  DAHLIA_APP_URL?: string;
  DAHLIA_DATABASE_TYPE?: string;
  DAHLIA_DATABASE_URL?: string;
  DAHLIA_MAX_REQUEST_BYTES?: string;
  DAHLIA_ARTIFACT_BACKEND?: string;
  DAHLIA_ARTIFACT_MAX_BYTES?: string;
  DAHLIA_R2_ACCESS_KEY_ID?: string;
  DAHLIA_R2_ACCOUNT_ID?: string;
  DAHLIA_R2_BUCKET?: string;
  DAHLIA_R2_SECRET_ACCESS_KEY?: string;
  DAHLIA_OAUTH_REDIRECT_URIS?: string;
  GOOGLE_CLIENT_ID?: string;
  GOOGLE_CLIENT_SECRET?: string;
  DATABRICKS_APP_URL?: string;
  DATABRICKS_CLIENT_ID?: string;
  DATABRICKS_CLIENT_SECRET?: string;
  DATABRICKS_HOST?: string;
  OPENAI_API_KEY?: string;
  OPENAI_BASE_URL?: string;
}

export interface WorkerEnv extends RuntimeSecrets {
  DAHLIA_ARTIFACTS?: R2BucketLike;
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
    return createD1ApplicationStore(env.dahlia_db_prod);
  }
  if (config.databaseType === "hyperdrive") {
    if (!env.HYPERDRIVE) throw new Error("The HYPERDRIVE binding is required");
    const connection = connectPostgresUrl(env.HYPERDRIVE.connectionString, 5);
    return { ...createPostgresApplicationStore(connection.db), close: connection.close };
  }
  if (config.databaseType === "postgres" && config.databaseUrl) {
    const connection = connectPostgresUrl(config.databaseUrl, 5);
    return { ...createPostgresApplicationStore(connection.db), close: connection.close };
  }
  throw new Error("Worker storage supports DAHLIA_DATABASE_TYPE=d1, hyperdrive, or postgres");
}

export async function initializeWorkerApp(env: WorkerEnv): Promise<WorkerApp> {
  const config = loadConfig({
    BETTER_AUTH_SECRET: env.BETTER_AUTH_SECRET,
    DAHLIA_ADMIN_EMAIL: env.DAHLIA_ADMIN_EMAIL,
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
    DAHLIA_ARTIFACT_BACKEND: env.DAHLIA_ARTIFACT_BACKEND,
    DAHLIA_ARTIFACT_MAX_BYTES: env.DAHLIA_ARTIFACT_MAX_BYTES,
    DAHLIA_R2_ACCESS_KEY_ID: env.DAHLIA_R2_ACCESS_KEY_ID,
    DAHLIA_R2_ACCOUNT_ID: env.DAHLIA_R2_ACCOUNT_ID,
    DAHLIA_R2_BUCKET: env.DAHLIA_R2_BUCKET,
    DAHLIA_R2_SECRET_ACCESS_KEY: env.DAHLIA_R2_SECRET_ACCESS_KEY,
    DAHLIA_OAUTH_REDIRECT_URIS: env.DAHLIA_OAUTH_REDIRECT_URIS,
    GOOGLE_CLIENT_ID: env.GOOGLE_CLIENT_ID,
    GOOGLE_CLIENT_SECRET: env.GOOGLE_CLIENT_SECRET,
    DATABRICKS_APP_URL: env.DATABRICKS_APP_URL,
    DATABRICKS_CLIENT_ID: env.DATABRICKS_CLIENT_ID,
    DATABRICKS_CLIENT_SECRET: env.DATABRICKS_CLIENT_SECRET,
    DATABRICKS_HOST: env.DATABRICKS_HOST,
    OPENAI_API_KEY: env.OPENAI_API_KEY,
    OPENAI_BASE_URL: env.OPENAI_BASE_URL,
  });
  const applicationStore = createWorkerApplicationStore(config, env);
  try {
    const auth = config.authProvider === "accounts"
      ? await initializeDahliaAuth(config, applicationStore)
      : undefined;
    if (config.artifactBackend === "databricks-volume") {
      throw new Error("Databricks Volume artifact storage requires the Node runtime");
    }
    const artifactStorage = config.artifactBackend === "r2"
      ? new R2ArtifactStorage(requiredR2Binding(env), config.r2Artifact!)
      : undefined;
    return createApp({ config, auth, authStore: applicationStore, artifactStorage });
  } catch (error) {
    await applicationStore.close?.();
    throw error;
  }
}

function requiredR2Binding(env: WorkerEnv): R2BucketLike {
  if (!env.DAHLIA_ARTIFACTS) throw new Error("The DAHLIA_ARTIFACTS R2 binding is required");
  return env.DAHLIA_ARTIFACTS;
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
