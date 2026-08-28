import { Hono } from "hono";
import { secureHeaders } from "hono/secure-headers";

import { createApp } from "./app";
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
  DAHLIA_AUTH_HEADER?: string;
  DAHLIA_AUTH_PROVIDER?: string;
  DAHLIA_BASE_URL?: string;
  DAHLIA_DATABASE_TYPE?: string;
  DAHLIA_DATABASE_URL?: string;
  DAHLIA_MAX_REQUEST_BYTES?: string;
  DAHLIA_OAUTH_REDIRECT_URIS?: string;
  GOOGLE_CLIENT_ID?: string;
  GOOGLE_CLIENT_SECRET?: string;
  OPENAI_API_KEY?: string;
  OPENAI_BASE_URL?: string;
}

export interface WorkerEnv extends RuntimeSecrets {
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
    DAHLIA_AUTH_HEADER: env.DAHLIA_AUTH_HEADER,
    DAHLIA_AUTH_PROVIDER: env.DAHLIA_AUTH_PROVIDER,
    DAHLIA_BASE_URL: env.DAHLIA_BASE_URL,
    DAHLIA_DATABASE_TYPE: env.DAHLIA_DATABASE_TYPE,
    DAHLIA_DATABASE_URL: env.DAHLIA_DATABASE_URL,
    DAHLIA_MAX_REQUEST_BYTES: String(Math.min(
      Number(env.DAHLIA_MAX_REQUEST_BYTES ?? WORKER_DEFAULT_MAX_REQUEST_BYTES),
      WORKER_DEFAULT_MAX_REQUEST_BYTES,
    )),
    DAHLIA_OAUTH_REDIRECT_URIS: env.DAHLIA_OAUTH_REDIRECT_URIS,
    GOOGLE_CLIENT_ID: env.GOOGLE_CLIENT_ID,
    GOOGLE_CLIENT_SECRET: env.GOOGLE_CLIENT_SECRET,
    OPENAI_API_KEY: env.OPENAI_API_KEY,
    OPENAI_BASE_URL: env.OPENAI_BASE_URL,
  });
  const applicationStore = createWorkerApplicationStore(config, env);
  try {
    const auth = config.authProvider === "accounts"
      ? await initializeDahliaAuth(config, applicationStore)
      : undefined;
    return createApp({ config, auth, authStore: applicationStore });
  } catch (error) {
    await applicationStore.close?.();
    throw error;
  }
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
