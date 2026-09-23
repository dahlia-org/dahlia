import { ChatMemoryStore } from "./agent/context-store";
import { ChatMemoryService, createMemoryGenerator } from "./agent/context-service";
import { WorkspaceMemoryService } from "./memory/service";
import * as authSchema from "./db/auth-schema";
import { workspacePermissions } from "./auth/workspace-permissions";
import { and, asc, gt, inArray } from "drizzle-orm";
import { syncedWorkspacePermission } from "./db/auth-schema";
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
import { createAiHistoryService, type AiHistoryService } from "./agent/history";
import { R2ObjectStorage, type R2BucketLike } from "./storage/r2";
import { S3ObjectStorage } from "./storage/s3";
import { initializeDahliaAuth } from "./auth/better-auth";
import {
  createPostgresApplicationStore,
  type ApplicationStore,
} from "./auth/store";
import { loadConfig, type AppConfig } from "./config";
import { connectPostgresUrl } from "./db/postgres";
import { createIntlSearchTokenizer } from "./search/tokenizer";

export interface RuntimeSecrets {
  DAHLIA_CHAT_MEMORY_MODEL?: string;
  DAHLIA_MEMORY_MCP_ACCESS?: string;
  DAHLIA_HINDSIGHT_URL?: string;
  DAHLIA_HINDSIGHT_AUTH?: string;
  DAHLIA_HINDSIGHT_API_KEY?: string;
  DAHLIA_HINDSIGHT_BANK_PREFIX?: string;
  [key: `DAHLIA_ENCRYPTION_MASTER_KEY_${string}`]: string | undefined;
  DAHLIA_ENCRYPTION_ACTIVE_KEY_ID?: string;
  DAHLIA_AUTH_SECRET?: string;
  DAHLIA_CODEX_AUTO_REVIEW_MODEL?: string;
  DAHLIA_FOUNDATION_MODELS?: string;
  DAHLIA_AI_BACKEND?: string;
  DAHLIA_SEARCH_EMBEDDING_MODEL?: string;
  DAHLIA_SEARCH_EMBEDDING_DIMENSIONS?: string;
  DAHLIA_IMAGE_ANALYSIS_MODEL?: string;
  DAHLIA_AUTH_HEADER?: string;
  DAHLIA_AUTH_PROVIDER_ID?: string;
  DAHLIA_AUTH_TYPE?: string;
  DAHLIA_LOCAL_SINGLE_USER?: string;
  DAHLIA_AUTO_CREATE_ORG_ON_SIGNUP?: string;
  DAHLIA_APP_URL?: string;
  DAHLIA_SIGNOUT_URL?: string;
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
  CLOUDFLARE_AI_GATEWAY_ID?: string;
  OPENAI_API_KEY?: string;
  OPENAI_BASE_URL?: string;
}

export interface WorkerEnv extends RuntimeSecrets, WorkerJobBindings {
  IMAGES?: Pick<ImagesBinding, "input">;
  DAHLIA_STORAGE?: R2BucketLike;
  HYPERDRIVE?: { connectionString: string };
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

function createWorkerApplicationStore(config: AppConfig, env: WorkerEnv): ApplicationStore & { jobs?: WorkerJobStores; aiHistory: AiHistoryService; chatMemoryStore?: ChatMemoryStore } {
  if (config.databaseType === "hyperdrive" && !env.HYPERDRIVE) throw new Error("The HYPERDRIVE binding is required");
  const url = config.databaseType === "hyperdrive" ? env.HYPERDRIVE!.connectionString
    : config.databaseType === "postgres" ? config.databaseUrl : undefined;
  if (!url) throw new Error("Worker storage supports DAHLIA_DATABASE_TYPE=hyperdrive or postgres");
  const connection = connectPostgresUrl(url, 5);
  const permissions = syncedWorkspacePermission;
  return { ...createPostgresApplicationStore(connection.db, "postgres", config.searchEmbedding, config.encryption, config.authProviderId, config.localSingleUser, config.autoCreateOrgOnSignup), close: connection.close,
    aiHistory: createAiHistoryService(connection.pool),
    chatMemoryStore: config.chatMemoryModel ? new ChatMemoryStore(connection.pool) : undefined,
    jobs: {
      summaryJobs: createSummaryJobStore(connection.db, true, config.encryption),
      imageAnalysis: createImageAnalysisStore(connection.db, true, config.encryption),
      searchIndex: createPostgresSearchIndexStore(connection.db),
      async listJobScopes(kind, after, userId) {
        if (kind !== "search") {
          return (await connection.db.select({ id: authSchema.user.id }).from(authSchema.user)
            .where(after ? gt(authSchema.user.id, after) : undefined).orderBy(asc(authSchema.user.id)).limit(100)).map((row) => row.id);
        }
        const rows = await connection.db.selectDistinct({ id: permissions.workspaceId }).from(permissions)
          .where(and(after ? gt(permissions.workspaceId, after) : undefined,
            userId ? and(workspacePermissions(connection.db, authSchema, userId).matchingPrincipal(), inArray(permissions.role, ["admin", "editor"])) : undefined))
          .orderBy(asc(permissions.workspaceId)).limit(100);
        return rows.map((row) => row.id);
      },
    },
  };
}

export async function initializeWorkerApp(env: WorkerEnv): Promise<WorkerApp> {
  const config = loadConfig({
    DAHLIA_HINDSIGHT_URL: env.DAHLIA_HINDSIGHT_URL,
    DAHLIA_HINDSIGHT_AUTH: env.DAHLIA_HINDSIGHT_AUTH,
    DAHLIA_HINDSIGHT_API_KEY: env.DAHLIA_HINDSIGHT_API_KEY,
    DAHLIA_HINDSIGHT_BANK_PREFIX: env.DAHLIA_HINDSIGHT_BANK_PREFIX,
    ...Object.fromEntries(Object.entries(env).filter(([name]) => name.startsWith("DAHLIA_ENCRYPTION_MASTER_KEY_"))) as Record<string, string | undefined>,
    DAHLIA_ENCRYPTION_ACTIVE_KEY_ID: env.DAHLIA_ENCRYPTION_ACTIVE_KEY_ID,
    DAHLIA_AUTH_SECRET: env.DAHLIA_AUTH_SECRET,
    DAHLIA_CODEX_AUTO_REVIEW_MODEL: env.DAHLIA_CODEX_AUTO_REVIEW_MODEL,
    DAHLIA_FOUNDATION_MODELS: env.DAHLIA_FOUNDATION_MODELS,
    DAHLIA_AI_BACKEND: env.DAHLIA_AI_BACKEND,
    DAHLIA_SEARCH_EMBEDDING_MODEL: env.DAHLIA_SEARCH_EMBEDDING_MODEL,
    DAHLIA_SEARCH_EMBEDDING_DIMENSIONS: env.DAHLIA_SEARCH_EMBEDDING_DIMENSIONS,
    DAHLIA_CHAT_MEMORY_MODEL: env.DAHLIA_CHAT_MEMORY_MODEL,
    DAHLIA_MEMORY_MCP_ACCESS: env.DAHLIA_MEMORY_MCP_ACCESS,
    DAHLIA_IMAGE_ANALYSIS_MODEL: env.DAHLIA_IMAGE_ANALYSIS_MODEL,
    DAHLIA_AUTH_HEADER: env.DAHLIA_AUTH_HEADER,
    DAHLIA_AUTH_PROVIDER_ID: env.DAHLIA_AUTH_PROVIDER_ID,
    DAHLIA_AUTH_TYPE: env.DAHLIA_AUTH_TYPE,
    DAHLIA_AUTO_CREATE_ORG_ON_SIGNUP: env.DAHLIA_AUTO_CREATE_ORG_ON_SIGNUP,
    DAHLIA_APP_URL: env.DAHLIA_APP_URL,
    DAHLIA_SIGNOUT_URL: env.DAHLIA_SIGNOUT_URL,
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
    CLOUDFLARE_AI_GATEWAY_ID: env.CLOUDFLARE_AI_GATEWAY_ID,
    OPENAI_API_KEY: env.OPENAI_API_KEY,
    OPENAI_BASE_URL: env.OPENAI_BASE_URL,
  });
  const applicationStore = createWorkerApplicationStore(config, env);
  try {
    if (config.storageBackend === "local" || config.storageBackend === "databricks") {
      throw new Error(`Storage backend ${config.storageBackend} requires the Node runtime`);
    }
    const auth = await initializeDahliaAuth(config, applicationStore);
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
    const captioner = createImageCaptioner(config);
    const screenshotTransformer = env.IMAGES ? createWorkerScreenshotTransformer(env.IMAGES) : undefined;
    const syncService = new MeetingSyncService(applicationStore.sync, objectStorage, searchTokenizer, searchEmbedder,
      screenshotTransformer, undefined, false, captioner?.model);
    const summaryMethods = applicationStore.jobs && env.DAHLIA_SUMMARY_QUEUE ? [
      createTranscriptSummaryMethod(config, applicationStore.sync, syncService),
      createAudioSummaryMethod(config, applicationStore.sync, syncService),
    ].filter((method) => method !== undefined) : [];
    if (config.hindsight && !env.DAHLIA_MEMORY_QUEUE) throw new Error("DAHLIA_MEMORY_QUEUE is required for Hindsight");
    const personalMemory = config.hindsight && applicationStore.personalMemory ? new WorkspaceMemoryService(config, applicationStore.personalMemory, syncService, applicationStore.sync) : undefined;
    const workspaceMemory = config.hindsight && applicationStore.memory ? new WorkspaceMemoryService(config, applicationStore.memory, syncService, applicationStore.sync) : undefined;
    if (config.chatMemoryModel && !env.DAHLIA_MEMORY_QUEUE) throw new Error("DAHLIA_MEMORY_QUEUE is required for chat memory");
    const chatMemory = applicationStore.chatMemoryStore ? new ChatMemoryService(applicationStore.chatMemoryStore, syncService, createMemoryGenerator(config)) : undefined;
    const jobs = applicationStore.jobs ? createQueueJobs(env, applicationStore.jobs, applicationStore.sync,
      syncService, summaryMethods, captioner, searchEmbedder, workspaceMemory, chatMemory, personalMemory) : undefined;
    const app = createApp({
      workspaceMemory, personalMemory, chatMemory, config, auth, authStore: applicationStore, aiHistory: applicationStore.aiHistory, objectStorage, searchTokenizer, searchEmbedder, screenshotTransformer, syncService,
      mcpSupportsCimd: false,
      summaryService: summaryMethods.length ? new SummaryService(applicationStore.sync, summaryMethods) : undefined,
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
