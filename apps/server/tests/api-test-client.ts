import { expect } from "vitest";
import { type RouteConfig, z } from "@hono/zod-openapi";
import { createApp, type AppDependencies } from "../src/app";
import { contracts } from "../src/api/contracts";

export function validate(request: Request, response: Response) {
  const path = new URL(request.url).pathname;
  const route: RouteConfig | undefined = Object.values(contracts).sort((a, b) => (a.path.match(/\{/g)?.length ?? 0) - (b.path.match(/\{/g)?.length ?? 0)).find((route) => route.method.toUpperCase() === request.method
    && new RegExp(`^${route.path.replace(/\{[^}]+\}/g, "[^/]+")}$`).test(path));
  expect(route, `${request.method} ${path}`).toBeDefined();
  const declared = route!.responses[response.status];
  expect(declared, `${route!.operationId}: HTTP ${response.status}`).toBeDefined();
  const contentType = response.headers.get("content-type")?.split(";")[0];
  if (!contentType?.includes("json")) return Promise.resolve();
  const content = declared as { content?: Record<string, { schema: z.ZodType }> };
  const schema = content.content?.[contentType]?.schema;
  expect(schema, `${route!.operationId}: ${contentType}`).toBeDefined();
  return response.clone().json().then((value: unknown) => {
    const result = schema!.safeParse(value);
    expect(result.success, `${route!.operationId}: ${JSON.stringify(result.error?.issues)}`).toBe(true);
  });
}

export function createContractApp(dependencies: AppDependencies) {
  const app = createApp(dependencies);
  const fetch = app.fetch.bind(app);
  app.fetch = async (request, ...args) => {
    const response = await fetch(request, ...args);
    const path = new URL(request.url).pathname;
    if (request.method !== "HEAD" && Object.values(contracts).some((route) => route.method.toUpperCase() === request.method
      && new RegExp(`^${route.path.replace(/\{[^}]+\}/g, "[^/]+")}$`).test(path))) await validate(request, response);
    return response;
  };
  return app;
}
