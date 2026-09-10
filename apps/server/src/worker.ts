import { and, asc, eq, gt } from "drizzle-orm";
import { syncedVaultPermission } from "./db/auth-schema";
import { createSummaryJobStore } from "./summary/store";
import { createImageAnalysisStore } from "./image-analysis/store";
import { createPostgresSearchIndexStore } from "./search/index-store";
import { createAudioSummaryMethod } from "./summary/audio";
import { createTranscriptSummaryMethod } from "./summary/transcript";
import { SummaryService } from "./summary/service";
import { createImageCaptioner } from "./image-analysis/captioner";
import { createSearchEmbedder } from "./search/embedding";
import { MeetingSyncService } from "./sync/service";
import { createWorkerScreenshotTransformer } from "./sync/worker-screenshot-transformer";
import { createQueueJobs, type WorkerJobBindings, type WorkerJobStores } from "./jobs/queues";
import { Hono } from "hono";
import { secureHeaders } from "hono/secure-headers";

import { createApp } from "./app";
import { R2ObjectStorage, type R2BucketLike } from "./storage/r2";
import { S3ObjectStorage } from "./storage/s3";
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
  [key: `DAHLIA_ENCRYPTION_MASTER_KEY_${string}`]: string | undefined;
  DAHLIA_ENCRYPTION_ACTIVE_KEY_ID?: string;
  BETTER_AUTH_SECRET?: string;
  CODEX_AUTO_REVIEW_MODEL?: string;
  DAHLIA_AI_BACKEND?: string;
  DAHLIA_EMBEDDING_MODEL?: string;
  DAHLIA_SEARCH_EMBEDDING_DIMENSIONS?: string;
  DAHLIA_CAPTIONING_MODEL?: string;
  DAHLIA_AUTH_HEADER?: string;
  DAHLIA_AUTH_TYPE?: string;
  DAHLIA_APP_URL?: string;
  DAHLIA_DATABASE_TYPE?: string;
  DAHLIA_DATABASE_URL?: string;
  DAHLIA_MAX_REQUEST_BYTES?: string;
  DAHLIA_STORAGE_BACKEND?: string;
  DAHLIA_STORAGE_LOCAL_PATH?: string;
  DAHLIA_STORAGE_S3_BUCKET?: string;
  DAHLIA_STORAGE_S3_ENDPOINT?: string;
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
  CLOUDFLARE_AI_GATEWAY_ID?: string;
  OPENAI_API_KEY?: string;
  OPENAI_BASE_URL?: string;
}

export interface WorkerEnv extends RuntimeSecrets, WorkerJobBindings {
  IMAGES?: Pick<ImagesBinding, "input">;
  DAHLIA_STORAGE?: R2BucketLike;
  HYPERDRIVE?: { connectionString: string };
  dahlia_db_prod?: D1DatabaseLike;
}
export type WorkerApp = ReturnType<typeof createApp> & {
  jobs?: ReturnType<typeof createQueueJobs>;
  close?: () => Promise<void>;
};
export type WorkerAppInitializer = (env: WorkerEnv) => Promise<WorkerApp>;

const WORKER_DEFAULT_MAX_REQUEST_BYTES = 4 * 1024 * 1024;
const healthApp = new Hono();
healthApp.use("*", secureHeaders());
healthApp.get("/healthz", (context) => context.json({ status: "ok" }));

function createWorkerApplicationStore(config: AppConfig, env: WorkerEnv): ApplicationStore & { jobs?: WorkerJobStores } {
  if (config.databaseType === "d1") {
    if (!env.dahlia_db_prod) throw new Error("The dahlia_db_prod D1 binding is required");
    return createD1ApplicationStore(env.dahlia_db_prod);
  }
  if (config.databaseType === "hyperdrive" && !env.HYPERDRIVE) throw new Error("The HYPERDRIVE binding is required");
  const url = config.databaseType === "hyperdrive" ? env.HYPERDRIVE!.connectionString
    : config.databaseType === "postgres" ? config.databaseUrl : undefined;
  if (!url) throw new Error("Worker storage supports DAHLIA_DATABASE_TYPE=d1, hyperdrive, or postgres");
  const connection = connectPostgresUrl(url, 5);
  const permissions = syncedVaultPermission;
  return { ...createPostgresApplicationStore(connection.db, "postgres", config.searchEmbedding, config.encryption), close: connection.close,
    jobs: {
      summaryJobs: createSummaryJobStore(connection.db, true, config.encryption),
      imageAnalysis: createImageAnalysisStore(connection.db, true, config.encryption),
      searchIndex: createPostgresSearchIndexStore(connection.db),
      async listJobOwners(after) {
        const rows = await connection.db.selectDistinct({ id: permissions.principalId }).from(permissions)
          .where(and(eq(permissions.principalType, "user"), eq(permissions.role, "owner"), after ? gt(permissions.principalId, after) : undefined))
          .orderBy(asc(permissions.principalId)).limit(100);
        return rows.map((row) => row.id);
      },
    },
  };
}

export async function initializeWorkerApp(env: WorkerEnv): Promise<WorkerApp> {
  const config = loadConfig({
    ...Object.fromEntries(Object.entries(env).filter(([name]) => name.startsWith("DAHLIA_ENCRYPTION_MASTER_KEY_"))) as Record<string, string | undefined>,
    DAHLIA_ENCRYPTION_ACTIVE_KEY_ID: env.DAHLIA_ENCRYPTION_ACTIVE_KEY_ID,
    BETTER_AUTH_SECRET: env.BETTER_AUTH_SECRET,
    CODEX_AUTO_REVIEW_MODEL: env.CODEX_AUTO_REVIEW_MODEL,
    DAHLIA_AI_BACKEND: env.DAHLIA_AI_BACKEND,
    DAHLIA_EMBEDDING_MODEL: env.DAHLIA_EMBEDDING_MODEL,
    DAHLIA_SEARCH_EMBEDDING_DIMENSIONS: env.DAHLIA_SEARCH_EMBEDDING_DIMENSIONS,
    DAHLIA_CAPTIONING_MODEL: env.DAHLIA_CAPTIONING_MODEL,
    DAHLIA_AUTH_HEADER: env.DAHLIA_AUTH_HEADER,
    DAHLIA_AUTH_TYPE: env.DAHLIA_AUTH_TYPE,
    DAHLIA_APP_URL: env.DAHLIA_APP_URL,
    DAHLIA_DATABASE_TYPE: env.DAHLIA_DATABASE_TYPE,
    DAHLIA_DATABASE_URL: env.DAHLIA_DATABASE_URL,
    DAHLIA_MAX_REQUEST_BYTES: String(Math.min(
      Number(env.DAHLIA_MAX_REQUEST_BYTES ?? WORKER_DEFAULT_MAX_REQUEST_BYTES),
      WORKER_DEFAULT_MAX_REQUEST_BYTES,
    )),
    DAHLIA_STORAGE_BACKEND: env.DAHLIA_STORAGE_BACKEND,
    DAHLIA_STORAGE_LOCAL_PATH: env.DAHLIA_STORAGE_LOCAL_PATH,
    DAHLIA_STORAGE_S3_BUCKET: env.DAHLIA_STORAGE_S3_BUCKET,
    DAHLIA_STORAGE_S3_ENDPOINT: env.DAHLIA_STORAGE_S3_ENDPOINT,
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
    CLOUDFLARE_AI_GATEWAY_ID: env.CLOUDFLARE_AI_GATEWAY_ID,
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
    const objectStorage = config.storageBackend === "r2"
      ? new R2ObjectStorage(requiredR2Binding(env))
      : new S3ObjectStorage(config.storageS3!);
    const hasQueues = env.DAHLIA_SUMMARY_QUEUE || env.DAHLIA_IMAGE_QUEUE || env.DAHLIA_SEARCH_QUEUE;
    if (!applicationStore.jobs && (hasQueues || config.searchEmbedding || config.captioningModel)) {
      throw new Error("Worker AI jobs require PostgreSQL or Hyperdrive");
    }
    if (env.DAHLIA_SUMMARY_QUEUE && !env.IMAGES) throw new Error("Summary jobs require the IMAGES binding");
    if (config.captioningModel && (!env.DAHLIA_IMAGE_QUEUE || !env.IMAGES)) {
      throw new Error("Image analysis requires DAHLIA_IMAGE_QUEUE and IMAGES bindings");
    }
    if (config.searchEmbedding && !env.DAHLIA_SEARCH_QUEUE) throw new Error("Embedding jobs require DAHLIA_SEARCH_QUEUE");
    const searchTokenizer = createIntlSearchTokenizer();
    const searchEmbedder = createSearchEmbedder(config);
    const screenshotTransformer = env.IMAGES ? createWorkerScreenshotTransformer(env.IMAGES) : undefined;
    const syncService = new MeetingSyncService(applicationStore.sync, objectStorage, searchTokenizer, searchEmbedder,
      screenshotTransformer, undefined, false);
    const summaryMethods = applicationStore.jobs && env.DAHLIA_SUMMARY_QUEUE ? [
      createTranscriptSummaryMethod(config, applicationStore.sync, syncService),
      createAudioSummaryMethod(config, applicationStore.sync, syncService),
    ].filter((method) => method !== undefined) : [];
    const captioner = createImageCaptioner(config);
    const jobs = applicationStore.jobs ? createQueueJobs(env, applicationStore.jobs, applicationStore.sync,
      syncService, applicationStore.accountSettings, summaryMethods, captioner, searchEmbedder) : undefined;
    const app = createApp({
      config, auth, authStore: applicationStore, objectStorage, searchTokenizer, searchEmbedder, screenshotTransformer, syncService,
      summaryService: summaryMethods.length ? new SummaryService(applicationStore.sync, applicationStore.accountSettings, summaryMethods) : undefined,
      imageAnalysisEnabled: captioner !== undefined,
      onSyncMutation: jobs ? (owner, context) => context.waitUntil(jobs.notify(owner)) : undefined,
    });
    return Object.assign(app, { jobs, close: () => applicationStore.close?.() ?? Promise.resolve() });
  } catch (error) {
    await applicationStore.close?.();
    throw error;
  }
}

function requiredR2Binding(env: WorkerEnv): R2BucketLike {
  if (!env.DAHLIA_STORAGE) throw new Error("The DAHLIA_STORAGE R2 binding is required");
  return env.DAHLIA_STORAGE;
}

// A Worker socket belongs to its event. Keep it alive through streamed reads, including SSE,
// and close it on completion, cancellation, and errors rather than caching it on the isolate.
export async function closeAfterResponse(response: Response, close?: () => Promise<void>): Promise<Response> {
  if (!close) return response;
  if (!response.body) { await close(); return response; }
  const reader = response.body.getReader();
  let closing: Promise<void> | undefined;
  const finish = () => closing ??= close();
  const body = new ReadableStream<Uint8Array>({
    async pull(controller) {
      try {
        const next = await reader.read();
        if (next.done) { await finish(); controller.close(); }
        else controller.enqueue(next.value);
      } catch (error) { await finish(); controller.error(error); }
    },
    async cancel(reason) { try { await reader.cancel(reason); } finally { await finish(); } },
  });
  return new Response(body, response);
}

export function createWorkerHandler(initialize: WorkerAppInitializer = initializeWorkerApp): ExportedHandler<WorkerEnv> {
  return {
    async fetch(request, env, context): Promise<Response> {
      if (new URL(request.url).pathname === "/healthz") return healthApp.fetch(request, env);
      const app = await initialize(env);
      try { return await closeAfterResponse(await app.fetch(request, env, context), app.close); }
      catch (error) { await app.close?.(); throw error; }
    },
    async scheduled(_controller, env): Promise<void> {
      const app = await initialize(env);
      try {
        await app.jobs?.schedule();
      } finally {
        try { await app.runStorageMaintenance(); }
        finally { await app.close?.(); }
      }
    },
    async queue(batch, env): Promise<void> {
      const app = await initialize(env);
      try {
        if (!app.jobs) throw new Error("job_queue_unavailable");
        for (const message of batch.messages) {
          try {
            await app.jobs.consume(message.body, AbortSignal.timeout(240_000));
            message.ack();
          } catch {
            console.warn(JSON.stringify({ level: "warn", event: "queue_job_failed" }));
            message.retry();
          }
        }
      } finally { await app.close?.(); }
    },
  };
}

export default createWorkerHandler();
