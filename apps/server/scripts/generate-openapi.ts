import { readFile, writeFile } from "node:fs/promises";
import { z } from "zod";
import openapiTS, { astToString } from "openapi-typescript";
import { contracts, openapiDocument } from "../src/api/contracts";

const audit = z.object({
  owned: z.array(z.object({ operationId: z.string(), method: z.string(), path: z.string(), classification: z.enum(["maintained", "modified"]), previous: z.string(), reason: z.string(), consumers: z.array(z.string()).min(1) })),
  delegated: z.array(z.object({ operation: z.string(), method: z.string(), path: z.string(), protocol: z.string(), availability: z.string() })),
  mcp: z.object({ methods: z.array(z.string()), tools: z.array(z.string()), authorization: z.string() }),
  fallbacks: z.array(z.string()),
}).parse(JSON.parse(await readFile(new URL("../api-audit.json", import.meta.url), "utf8")));
const registered = Object.values(contracts).map(({ operationId, method, path }) => `${operationId} ${method.toUpperCase()} ${path}`).sort();
const audited = audit.owned.map(({ operationId, method, path }) => `${operationId} ${method} ${path}`).sort();
if (new Set(registered.map((value) => value.split(" ")[0])).size !== registered.length || JSON.stringify(registered) !== JSON.stringify(audited)) {
  throw new Error("API audit and registered operations differ; review api-audit.json before regeneration");
}
const auditMarkdown = `# Server API audit

Generated from apps/server/api-audit.json by pnpm openapi:generate. The independently reviewed inventory must match the registered OpenAPI operations. Extensions own their additional routes.

## Dahlia-owned operations

All listed operations use the generated Web and Desktop clients where a bundled consumer exists. Database and sync queue representations are separate from these wire DTOs. Null clears an explicitly nullable property; omitted PATCH properties remain unchanged. IDs are UUID/UUIDv7 except identity-provider IDs, integer history versions, recording numbers and opaque cursors. See openapi.json for per-field bounds and ordering.

| Operation | Classification | Method / path | Previous | Reason | Consumers |
| --- | --- | --- | --- | --- | --- |
${audit.owned.map((entry) => `| ${entry.operationId} | ${entry.classification} | ${entry.method} \`${entry.path}\` | \`${entry.previous}\` | ${entry.reason} | ${entry.consumers.join("<br>")} |`).join("\n")}

## Delegated protocols

These concrete endpoints preserve Better Auth/OAuth/OIDC, OpenAI and MCP formats. Dahlia Problem/DTO conventions do not apply. OAuth client and resource management are registered by the provider but denied by denyOAuthManagement; dynamic client registration is disabled. Email/password sign-in is not enabled. Plugin/session/organization/admin checks remain authoritative. The installed provider inventory is tested; it is not represented by a wildcard claim of OpenAPI coverage.

| Operation | Method / path | Protocol | Availability |
| --- | --- | --- | --- |
${audit.delegated.map((entry) => `| ${entry.operation} | ${entry.method} \`${entry.path}\` | ${entry.protocol} | ${entry.availability} |`).join("\n")}

MCP methods: ${audit.mcp.methods.join(", ")}. Tools: ${audit.mcp.tools.join(", ")}. ${audit.mcp.authorization}

## Dispatch and fallbacks

${audit.fallbacks.map((entry) => `- ${entry}`).join("\n")}
`;

const document = JSON.stringify(openapiDocument(), null, 2) + "\n";
const types = astToString(await openapiTS(document));
const calls = `// Generated from OpenAPI. Run pnpm openapi:generate.
import { createFinalURL, createQuerySerializer, defaultPathSerializer, type FetchOptions } from "openapi-fetch";
import type { operations } from "./generated-api";
import { serverClient, unwrap } from "./api";

export const apiOperations = {
${Object.values(contracts).map(({ operationId, method, path }) => `  ${operationId}: (init: FetchOptions<operations["${operationId}"]>, notifyMutation = ${!["get", "head"].includes(method) && !["search", "textSearch", "resolveTransaction"].includes(operationId)}) => unwrap(serverClient.${method.toUpperCase()}("${path}", init), notifyMutation),`).join("\n")}
};
export type GetOperation = ${Object.values(contracts).filter((v) => v.method === "get").map((v) => JSON.stringify(v.operationId)).join(" | ")};
export const apiUrls = {
${Object.values(contracts).filter((v) => v.method === "get").map(({ operationId, path }) => `  ${operationId}: (init: FetchOptions<operations["${operationId}"]>) => createFinalURL("${path}", { baseUrl: "", params: init.params ?? {}, querySerializer: createQuerySerializer(), pathSerializer: defaultPathSerializer }),`).join("\n")}
};
`;
const outputs = new Map([
  [new URL("../../../docs/architecture/server-api-audit.md", import.meta.url), auditMarkdown],
  [new URL("../openapi.json", import.meta.url), document],
  [new URL("../src/client/generated-api.ts", import.meta.url), types],
  [new URL("../src/client/generated-operations.ts", import.meta.url), calls],
]);
for (const [url, content] of outputs) {
  if (process.argv.includes("--check")) {
    if (await readFile(url, "utf8").catch(() => "") !== content) throw new Error(`Regenerate OpenAPI: ${url.pathname}`);
  } else await writeFile(url, content);
}
console.log(`${process.argv.includes("--check") ? "Verified" : "Generated"} OpenAPI and TypeScript client types`);
