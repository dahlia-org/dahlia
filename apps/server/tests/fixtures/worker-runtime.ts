import { createWorkerHandler, initializeWorkerApp, type WorkerEnv } from "../../src/worker";
import { createWorkerScreenshotTransformer } from "../../src/sync/worker-screenshot-transformer";
import { audioBase64 } from "../../src/summary/audio";
import { createHash } from "node:crypto";
import { connectPostgresUrl } from "../../src/db/postgres";
import { loadConfig } from "../../src/config";
import { createSearchEmbedder } from "../../src/search/embedding";
import { createImageCaptioner } from "../../src/image-analysis/captioner";
import { DEFAULT_ACCOUNT_SETTINGS } from "../../src/account-settings";
import { sql } from "drizzle-orm";

// Synthetic, local-only routes; this module is never a deployment entry point.
const handler = createWorkerHandler(async (env) => {
  const app = await initializeWorkerApp(env);
  const jobs = app.jobs!;
  app.jobs = { ...jobs, consume: async (body, signal) => {
    await jobs.consume(body, signal);
    await env.DAHLIA_STORAGE!.put("queue-completed", new TextEncoder().encode("ok"), { httpMetadata: { cacheControl: "no-store", contentType: "text/plain" } });
  } };
  return app;
});
export default {
  ...handler,
  async fetch(request: Request<unknown, IncomingRequestCfProperties>, env: WorkerEnv, context: ExecutionContext) {
    const path = new URL(request.url).pathname;
    if (path === "/runtime/provider") {
      const backend = new URL(request.url).searchParams.get("backend")!;
      const config = loadConfig({ DAHLIA_AUTH_TYPE: "header", DAHLIA_AI_BACKEND: backend,
        OPENAI_BASE_URL: "https://api.cloudflare.com/client/v4/accounts/synthetic/ai/v1", OPENAI_API_KEY: "synthetic",
        DATABRICKS_HOST: "https://synthetic.example", DATABRICKS_CLIENT_ID: "synthetic", DATABRICKS_CLIENT_SECRET: "synthetic", DATABRICKS_MODEL_SCHEMA: "test.ai",
        DAHLIA_CAPTIONING_MODEL: backend === "cloudflare" ? "gpt-4.1" : "test.ai.gpt-5-6-luna",
        DAHLIA_EMBEDDING_MODEL: backend === "cloudflare" ? "@cf/baai/bge-m3" : "test.ai.embedding", DAHLIA_SEARCH_EMBEDDING_DIMENSIONS: "1024" });
      const transport: typeof fetch = (url) => Promise.resolve(String(url).endsWith("/token")
        ? Response.json({ access_token: "synthetic", expires_in: 3600 })
        : String(url).endsWith("/responses")
          ? Response.json({ status: "completed", output: [{ type: "message", content: [{ type: "output_text", text: '{"ocr_text":"Test","caption":"A synthetic slide"}' }] }] })
          : Response.json(backend === "cloudflare" ? { success: true, result: { data: [Array(1024).fill(0.5)] } } : { data: [{ index: 0, embedding: Array(1024).fill(0.5) }] }));
      const caption = await createImageCaptioner(config, transport)!.analyze(new Uint8Array([1]), DEFAULT_ACCOUNT_SETTINGS, request.signal);
      const vector = await createSearchEmbedder(config, transport)!.embedQuery("synthetic", request.signal);
      return Response.json({ caption, dimensions: vector.length });
    }
    if (path === "/runtime/audio") {
      const bytes = new Uint8Array([1, 2, 3, 4, 5]);
      await env.DAHLIA_STORAGE!.put("audio", bytes, { httpMetadata: { cacheControl: "no-store", contentType: "audio/mp4" } });
      const object = await env.DAHLIA_STORAGE!.get("audio");
      const hash = `SHA-256:${createHash("sha256").update(bytes).digest("hex")}`;
      let encoded = "";
      for await (const chunk of audioBase64(new Response(object!.body), bytes.length, hash, request.signal)) encoded += chunk;
      return new Response(encoded);
    }
    if (path === "/runtime/image") {
      const object = await env.DAHLIA_STORAGE!.get("image");
      const output = await createWorkerScreenshotTransformer(env.IMAGES!)(object!.body!, 480);
      return new Response(output, { headers: { "content-type": "image/webp" } });
    }
    if (path === "/runtime/database") {
      const connection = connectPostgresUrl(env.DAHLIA_DATABASE_URL!, 1);
      try {
        const result = await connection.db.execute(sql`select pg_backend_pid() as pid`);
        return Response.json(result.rows[0]);
      } finally { await connection.close(); }
    }
    return handler.fetch!(request, env, context);
  },
};
