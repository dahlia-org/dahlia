import type { MemoryTools } from "./memory/tools";
import { decodeId, encodeId } from "./typeid";
import { wireValue, wireURL, wireCursor } from "./public-wire";
import {
  createMcpHandler,
  McpServer,
  type AuthInfo,
  type CallToolResult,
} from "@modelcontextprotocol/server";
import { z } from "zod";

import { RequestError } from "./storage/upload";
import type { Identity } from "./auth/identity";
import { hasApiScope, MCP_READ_SCOPE } from "./auth/scopes";
import type { AppConfig } from "./config";
import { searchRequestSchema } from "./search/model";
import { MeetingSyncService } from "./sync/service";
import { createMeetingTools, meetingInputSchema, meetingRequestContext, publicIdSchema, type MeetingTools } from "./agent/tools";

export const MCP_MAX_REQUEST_BYTES = 12 * 1024 * 1024;
export function createServerMcpHandler(
  config: AppConfig,
  sync?: MeetingSyncService,
  authorize?: (request: Request) => Promise<void>,
  meetingTools?: MeetingTools,
  memoryTools?: MemoryTools,
) {
  return createMcpHandler(({ authInfo, requestInfo }) => {
    const identity = mcpIdentity(authInfo);
    const server = new McpServer({ name: "Dahlia Server", version: "0.1.0" });

    if (sync && hasApiScope(authInfo?.scopes ?? [], MCP_READ_SCOPE)) {
      const sharedMeetingTools = meetingTools ?? createMeetingTools(sync);
      server.registerTool("search", {
        description: "Search meetings, screenshots and projects in a readable Workspace. Returns up to 100 ranked results per kind.",
        inputSchema: searchRequestSchema.safeExtend({ workspaceId: publicIdSchema("workspace"), projectId: publicIdSchema("project").optional() }),
        annotations: { readOnlyHint: true },
      }, async (request) => jsonToolResult("search", () => sync.searchAll(identity, {
        ...request, workspaceId: decodeId("workspace", request.workspaceId), projectId: request.projectId ? decodeId("project", request.projectId) : undefined, from: request.from?.toISOString(), to: request.to?.toISOString(),
      })));
      registerMastraTool(server, sharedMeetingTools.query_meetings, identity);
      for (const tool of Object.values(memoryTools ?? {})) registerMastraTool(server, tool, identity, requestInfo?.signal, async () => {
        if (requestInfo) await authorize?.(requestInfo);
        if (authInfo?.expiresAt !== undefined && authInfo.expiresAt <= Date.now() / 1000) throw new RequestError(401, "token_expired");
      });
      server.registerTool("query_projects", {
        description: "List the complete synchronized Project hierarchy in a Workspace you can read.",
        inputSchema: z.object({ workspace_id: publicIdSchema("workspace"), type: z.enum([
          "customer", "internal", "personal", "undefined",
        ]).optional() }).strict(),
        annotations: { readOnlyHint: true },
      }, async ({ workspace_id, type }) => jsonToolResult("array:project", async () => {
        const projects = await sync.listProjects(identity, decodeId("workspace", workspace_id));
        return type ? projects.filter((project) => project.effectiveType === type) : projects;
      }));
      server.registerTool("get_project", {
        description: "Get one synchronized Project by stable proj_ TypeID.",
        inputSchema: z.object({ workspace_id: publicIdSchema("workspace"), project_id: publicIdSchema("project") }).strict(),
        annotations: { readOnlyHint: true },
      }, async ({ workspace_id, project_id }) => jsonToolResult("project", async () => {
        const project = await sync.getProject(identity, decodeId("workspace", workspace_id), decodeId("project", project_id));
        if (!project) throw new RequestError(404, "project_not_found");
        return project;
      }));
      registerMastraTool(server, sharedMeetingTools.get_meeting, identity);
      registerMastraTool(server, sharedMeetingTools.get_meeting_transcript, identity, requestInfo?.signal, async () => {
        if (requestInfo) await authorize?.(requestInfo);
        if (authInfo?.expiresAt !== undefined && authInfo.expiresAt <= Date.now() / 1000) throw new RequestError(401, "token_expired");
      });
      server.registerTool("query_screenshots", {
        description: "Search screenshot OCR and captions in a synchronized meeting you can read.",
        inputSchema: meetingInputSchema.extend({ query: z.string() }),
        annotations: { readOnlyHint: true },
      }, async ({ workspace_id, meeting_id, query }) => screenshotToolResult(
        config,
        sync,
        identity,
        workspace_id,
        meeting_id,
        query,
      ));
      server.registerTool("get_meeting_screenshots", {
        description: "List authenticated screenshot resource links for a synchronized meeting you can read.",
        inputSchema: meetingInputSchema.extend({ cursor: z.string().optional() }),
        annotations: { readOnlyHint: true },
      }, async ({ workspace_id, meeting_id, cursor }) => screenshotToolResult(
        config,
        sync,
        identity,
        workspace_id,
        meeting_id,
        undefined,
        cursor,
      ));
    }

    return server;
  }, { legacy: "reject" });
}

export function registerMastraTool(
  server: McpServer,
  tool: MeetingTools[keyof MeetingTools] | MemoryTools[keyof MemoryTools],
  identity: Identity,
  requestSignal?: AbortSignal,
  authorize?: () => Promise<void>,
) {
  server.registerTool(tool.id, {
    description: tool.description,
    inputSchema: tool.mcpInputSchema,
    annotations: tool.mcp?.annotations,
  }, async (request: z.infer<typeof tool.mcpInputSchema>, context: { mcpReq: { signal: AbortSignal } }) => mastraToolResult(async () => {
    const signal = requestSignal ? AbortSignal.any([context.mcpReq.signal, requestSignal]) : context.mcpReq.signal;
    return tool.execute!(tool.toAgentInput(request as never) as never,
      { requestContext: meetingRequestContext(identity, undefined, authorize), abortSignal: signal } as never);
  }));
}

async function mastraToolResult(operation: () => Promise<unknown>): Promise<CallToolResult> {
  try {
    return { content: [{ type: "text", text: JSON.stringify(await operation()) }] };
  } catch (error) {
    if (error instanceof RequestError) return { isError: true, content: [{ type: "text", text: error.code }] };
    throw error;
  }
}

async function jsonToolResult(shape: string, operation: () => Promise<unknown>): Promise<CallToolResult> {
  try {
    return { content: [{ type: "text", text: JSON.stringify(wireValue(await operation(), shape, "encode")) }] };
  } catch (error) {
    if (error instanceof RequestError) {
      return { isError: true, content: [{ type: "text", text: error.code }] };
    }
    throw error;
  }
}

async function screenshotToolResult(
  config: AppConfig,
  sync: MeetingSyncService,
  identity: Identity,
  workspaceIdValue: string,
  meetingIdValue: string,
  query?: string,
  cursor?: string,
): Promise<CallToolResult> {
  const workspaceId = decodeId("workspace", workspaceIdValue);
  const meetingId = decodeId("meeting", meetingIdValue);
  const page = await sync.listScreenshots(identity, workspaceId, meetingId, query, undefined, wireCursor(cursor, "screenshot", "decode") as string | undefined);
  return {
    content: [
      ...(page.nextCursor
        ? [{ type: "text" as const, text: JSON.stringify({ nextCursor: wireCursor(page.nextCursor, "screenshot", "encode") }) }]
        : []),
      ...page.items.map((screenshot) => ({
      type: "resource_link" as const,
      name: `Screenshot ${encodeId("attachment", screenshot.screenshotId)}`,
      uri: wireURL(`${config.baseUrl}/mcp/resources/workspaces/${workspaceId}/meetings/${meetingId}`
        + `/screenshots/${screenshot.screenshotId}/content`, "encode"),
      mimeType: screenshot.contentType,
      })),
    ],
  };
}

function mcpIdentity(authInfo: AuthInfo | undefined): Identity {
  const identity = authInfo?.extra?.identity;
  if (
    !identity
    || typeof identity !== "object"
    || !("userId" in identity)
    || typeof identity.userId !== "string"
    || !("source" in identity)
    || (identity.source !== "accounts" && identity.source !== "header")
  ) throw new Error("MCP identity is unavailable");
  return identity as Identity;
}
