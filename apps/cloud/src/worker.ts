import { Hono } from "hono";
import { secureHeaders } from "hono/secure-headers";

import { createApp } from "./app";
import { initializeDahliaAuth } from "./auth/better-auth";
import { createD1AuthStore } from "./auth/store";
import { loadConfig } from "./config";

interface RuntimeSecrets {
  BETTER_AUTH_SECRET: string;
  DAHLIA_ADMIN_EMAIL?: string;
  DAHLIA_BASE_URL?: string;
  DAHLIA_MAX_REQUEST_BYTES?: string;
  DAHLIA_OAUTH_REDIRECT_URIS?: string;
  GOOGLE_CLIENT_ID: string;
  GOOGLE_CLIENT_SECRET: string;
  OPENAI_API_KEY?: string;
  OPENAI_BASE_URL?: string;
  STRIPE_PRO_MONTHLY_PRICE_ID?: string;
  STRIPE_SECRET_KEY?: string;
  STRIPE_WEBHOOK_SECRET?: string;
}

type WorkerEnv = Cloudflare.Env & RuntimeSecrets;
type WorkerApp = ReturnType<typeof createApp>;
type WorkerAppInitializer = (env: WorkerEnv) => Promise<WorkerApp>;

const WORKER_DEFAULT_MAX_REQUEST_BYTES = 4 * 1024 * 1024;
const healthApp = new Hono();
healthApp.use("*", secureHeaders());
healthApp.get("/healthz", (context) => context.json({ status: "ok" }));

async function initializeWorkerApp(env: WorkerEnv): Promise<WorkerApp> {
  const config = loadConfig({
      BETTER_AUTH_SECRET: env.BETTER_AUTH_SECRET,
      DAHLIA_ADMIN_EMAIL: env.DAHLIA_ADMIN_EMAIL,
      DAHLIA_BASE_URL: env.DAHLIA_BASE_URL,
      DAHLIA_MAX_REQUEST_BYTES: String(Math.min(
        Number(env.DAHLIA_MAX_REQUEST_BYTES ?? WORKER_DEFAULT_MAX_REQUEST_BYTES),
        WORKER_DEFAULT_MAX_REQUEST_BYTES,
      )),
      DAHLIA_OAUTH_REDIRECT_URIS: env.DAHLIA_OAUTH_REDIRECT_URIS,
      DAHLIA_RUNTIME: env.DAHLIA_RUNTIME,
      GOOGLE_CLIENT_ID: env.GOOGLE_CLIENT_ID,
      GOOGLE_CLIENT_SECRET: env.GOOGLE_CLIENT_SECRET,
      OPENAI_API_KEY: env.OPENAI_API_KEY,
      OPENAI_BASE_URL: env.OPENAI_BASE_URL,
      STRIPE_PRO_MONTHLY_PRICE_ID: env.STRIPE_PRO_MONTHLY_PRICE_ID,
      STRIPE_SECRET_KEY: env.STRIPE_SECRET_KEY,
      STRIPE_WEBHOOK_SECRET: env.STRIPE_WEBHOOK_SECRET,
  });
  if (config.runtime !== "cloudflare" || config.authDatabase !== "d1") {
    throw new Error("The Worker entry point requires DAHLIA_RUNTIME=cloudflare");
  }
  const authStore = createD1AuthStore(env.AUTH_DB);
  const auth = await initializeDahliaAuth(config, authStore);
  return createApp({ config, auth, authStore });
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
