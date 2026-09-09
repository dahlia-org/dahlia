import { z } from "zod";
import type { MiddlewareHandler } from "hono";

export function problemResponse(status: number, code: string, extras: Record<string, unknown> = {}, headers?: HeadersInit) {
  const responseHeaders = new Headers(headers);
  responseHeaders.delete("Content-Length");
  responseHeaders.set("Content-Type", "application/problem+json");
  return new Response(JSON.stringify({ type: "about:blank", title: code.replaceAll("_", " "), status, code, ...extras }), {
    status, headers: responseHeaders,
  });
}

/** Native OAuth, OpenAI and MCP error contracts are deliberately outside this boundary. */
export const problemMiddleware: MiddlewareHandler = async (context, next) => {
  await next();
  if (["/api/v1/models", "/api/v1/responses"].includes(context.req.path)
    || context.res.status < 400 || !context.res.headers.get("content-type")?.includes("application/json")) return;
  const parsed = z.object({ error: z.string(), message: z.string().optional(), conflicts: z.array(z.unknown()).optional(), operationId: z.string().optional() }).safeParse(await context.res.clone().json());
  if (!parsed.success) return;
  const value = parsed.data;
  const extras: Record<string, unknown> = {};
  if (typeof value.message === "string") extras.detail = value.message;
  if (Array.isArray(value.conflicts)) extras.conflicts = value.conflicts;
  if (typeof value.operationId === "string") extras.operationId = value.operationId;
  context.res = problemResponse(context.res.status, value.error, extras, context.res.headers);
};
