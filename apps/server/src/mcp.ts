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

export const MCP_MAX_REQUEST_BYTES = 12 * 1024 * 1024;
export function createServerMcpHandler(
  config: AppConfig,
  sync?: MeetingSyncService,
) {
  return createMcpHandler(({ authInfo }) => {
    const identity = mcpIdentity(authInfo);
    const server = new McpServer({ name: "Dahlia Server", version: "0.1.0" });

    if (sync && hasApiScope(authInfo?.scopes ?? [], MCP_READ_SCOPE)) {
      server.registerTool("search", {
        description: "Search meetings, screenshots and projects in a readable Vault. Returns up to 100 ranked results per kind.",
        inputSchema: searchRequestSchema,
        annotations: { readOnlyHint: true },
      }, async (request) => jsonToolResult(() => sync.searchAll(identity, {
        ...request, from: request.from?.toISOString(), to: request.to?.toISOString(),
      })));
      const meetingInput = z.object({ vault_id: z.string(), meeting_id: z.string() }).strict();
      server.registerTool("query_meetings", {
        description: "List meetings in a synchronized Vault you can read.",
        inputSchema: z.object({
          vault_id: z.string(),
          query: z.string().optional(),
          project_id: z.string().optional(),
          cursor: z.string().optional(),
        }).strict(),
        annotations: { readOnlyHint: true },
      }, async ({ vault_id, query, project_id, cursor }) => jsonToolResult(async () => sync.listMeetings(
        identity,
        sync.parseId(vault_id),
        query,
        undefined,
        project_id ? sync.parseId(project_id) : undefined,
        cursor,
      )));
      server.registerTool("query_projects", {
        description: "List the complete synchronized Project hierarchy in a Vault you can read.",
        inputSchema: z.object({ vault_id: z.string(), type: z.enum([
          "customer", "internal", "personal", "undefined",
        ]).optional() }).strict(),
        annotations: { readOnlyHint: true },
      }, async ({ vault_id, type }) => jsonToolResult(async () => {
        const projects = await sync.listProjects(identity, sync.parseId(vault_id));
        return type ? projects.filter((project) => project.effectiveType === type) : projects;
      }));
      server.registerTool("get_project", {
        description: "Get one synchronized Project by stable UUID.",
        inputSchema: z.object({ vault_id: z.string(), project_id: z.string() }).strict(),
        annotations: { readOnlyHint: true },
      }, async ({ vault_id, project_id }) => jsonToolResult(async () => {
        const project = await sync.getProject(identity, sync.parseId(vault_id), sync.parseId(project_id));
        if (!project) throw new RequestError(404, "project_not_found");
        return project;
      }));
      server.registerTool("get_meeting", {
        description: "Get one synchronized meeting you can read and its summary.",
        inputSchema: meetingInput,
        annotations: { readOnlyHint: true },
      }, async ({ vault_id, meeting_id }) => jsonToolResult(async () => {
        const meeting = await sync.getMeeting(identity, sync.parseId(vault_id), sync.parseId(meeting_id));
        if (!meeting) throw new RequestError(404, "meeting_not_found");
        return meeting;
      }));
      server.registerTool("get_meeting_transcript", {
        description: "Get the active transcript for a synchronized meeting you can read.",
        inputSchema: meetingInput.extend({ cursor: z.string().optional() }),
        annotations: { readOnlyHint: true },
      }, async ({ vault_id, meeting_id, cursor }) => jsonToolResult(async () => sync.listTranscript(
        identity,
        sync.parseId(vault_id),
        sync.parseId(meeting_id),
        cursor,
      )));
      server.registerTool("query_screenshots", {
        description: "Search screenshot OCR and captions in a synchronized meeting you can read.",
        inputSchema: meetingInput.extend({ query: z.string() }),
        annotations: { readOnlyHint: true },
      }, async ({ vault_id, meeting_id, query }) => screenshotToolResult(
        config,
        sync,
        identity,
        vault_id,
        meeting_id,
        query,
      ));
      server.registerTool("get_meeting_screenshots", {
        description: "List authenticated screenshot resource links for a synchronized meeting you can read.",
        inputSchema: meetingInput.extend({ cursor: z.string().optional() }),
        annotations: { readOnlyHint: true },
      }, async ({ vault_id, meeting_id, cursor }) => screenshotToolResult(
        config,
        sync,
        identity,
        vault_id,
        meeting_id,
        undefined,
        cursor,
      ));
    }

    return server;
  }, { legacy: "reject" });
}

async function jsonToolResult(operation: () => Promise<unknown>): Promise<CallToolResult> {
  try {
    return { content: [{ type: "text", text: JSON.stringify(await operation()) }] };
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
  vaultIdValue: string,
  meetingIdValue: string,
  query?: string,
  cursor?: string,
): Promise<CallToolResult> {
  const vaultId = sync.parseId(vaultIdValue);
  const meetingId = sync.parseId(meetingIdValue);
  const page = await sync.listScreenshots(identity, vaultId, meetingId, query, undefined, cursor);
  return {
    content: [
      ...(page.nextCursor
        ? [{ type: "text" as const, text: JSON.stringify({ nextCursor: page.nextCursor }) }]
        : []),
      ...page.items.map((screenshot) => ({
      type: "resource_link" as const,
      name: `Screenshot ${screenshot.screenshotId}`,
      uri: `${config.baseUrl}/mcp/resources/vaults/${vaultId}/meetings/${meetingId}`
        + `/screenshots/${screenshot.screenshotId}/content`,
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
    || !("workspaceId" in identity)
    || typeof identity.workspaceId !== "string"
    || !("source" in identity)
    || (identity.source !== "accounts" && identity.source !== "header")
  ) throw new Error("MCP identity is unavailable");
  return identity as Identity;
}
