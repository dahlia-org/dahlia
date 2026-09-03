import {
  createMcpHandler,
  McpServer,
  type AuthInfo,
  type CallToolResult,
} from "@modelcontextprotocol/server";
import { z } from "zod";

import { ArtifactRequestError, ArtifactService } from "./artifacts/service";
import type { ArtifactRecord } from "./auth/store";
import type { Identity } from "./auth/identity";
import { ARTIFACT_WRITE_SCOPE, SYNC_READ_SCOPE } from "./auth/scopes";
import type { AppConfig } from "./config";
import { MeetingSyncService } from "./sync/service";

export const MCP_MAX_REQUEST_BYTES = 12 * 1024 * 1024;
export const MCP_ARTIFACT_MAX_BYTES = 8 * 1024 * 1024;

const encodingSchema = z.enum(["utf8", "base64"]).default("utf8");
const contentTypeSchema = z.string().trim().min(1).max(255).refine(
  (value) => Array.from(value).every((character) => {
    const code = character.charCodeAt(0);
    return code >= 32 && code <= 255 && code !== 127;
  }),
  "invalid_content_type",
);
const artifactContentSchema = z.object({
  content: z.string(),
  content_type: contentTypeSchema,
  encoding: encodingSchema,
}).strict();
const artifactIdSchema = z.object({ artifact_id: z.string() }).strict();
const artifactOutputSchema = z.object({
  artifact_id: z.string(),
  url: z.string(),
  content_type: z.string(),
  visibility: z.enum(["private", "public"]),
});

export function createArtifactMcpHandler(
  config: AppConfig,
  artifacts: ArtifactService,
  sync?: MeetingSyncService,
) {
  return createMcpHandler(({ authInfo }) => {
    const identity = mcpIdentity(authInfo);
    const server = new McpServer({ name: "Dahlia Server", version: "0.1.0" });

    if (authInfo?.scopes.includes(ARTIFACT_WRITE_SCOPE)) {
    server.registerTool("create_artifact", {
      description: "Create a private artifact from UTF-8 text or canonical RFC 4648 base64 content.",
      inputSchema: artifactContentSchema,
      outputSchema: artifactOutputSchema,
      annotations: { destructiveHint: false, idempotentHint: false },
    }, async ({ content, content_type, encoding }) => toolResult(async () => {
      const bytes = decodeContent(content, encoding);
      const artifact = await artifacts.create(identity, uploadRequest(config, bytes, content_type));
      return artifactResult(config, artifact);
    }));

    server.registerTool("update_artifact_content", {
      description: "Replace the content of an owned artifact without changing its content type.",
      inputSchema: artifactContentSchema.extend({ artifact_id: z.string() }),
      outputSchema: artifactOutputSchema,
      annotations: { destructiveHint: true, idempotentHint: true },
    }, async ({ artifact_id, content, content_type, encoding }) => toolResult(async () => {
      const id = artifacts.parseId(artifact_id);
      const bytes = decodeContent(content, encoding);
      const artifact = await artifacts.put(id, identity, uploadRequest(config, bytes, content_type));
      return artifactResult(config, artifact);
    }));

    server.registerTool("update_artifact_visibility", {
      description: "Set an owned artifact to private or public visibility.",
      inputSchema: artifactIdSchema.extend({ visibility: z.enum(["private", "public"]) }),
      outputSchema: artifactOutputSchema,
      annotations: { destructiveHint: true, idempotentHint: true },
    }, async ({ artifact_id, visibility }) => toolResult(async () => {
      const id = artifacts.parseId(artifact_id);
      const artifact = await artifacts.setVisibility(id, identity, { visibility });
      return artifactResult(config, artifact);
    }));

    server.registerTool("delete_artifact", {
      description: "Permanently delete an owned artifact.",
      inputSchema: artifactIdSchema,
      outputSchema: artifactOutputSchema,
      annotations: { destructiveHint: true, idempotentHint: true },
    }, async ({ artifact_id }) => toolResult(async () => {
      const id = artifacts.parseId(artifact_id);
      return artifactResult(config, await artifacts.delete(id, identity));
    }));
    }

    if (sync && authInfo?.scopes.includes(SYNC_READ_SCOPE)) {
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
        if (!project) throw new ArtifactRequestError(404, "project_not_found");
        return project;
      }));
      server.registerTool("get_meeting", {
        description: "Get one synchronized meeting you can read and its summary.",
        inputSchema: meetingInput,
        annotations: { readOnlyHint: true },
      }, async ({ vault_id, meeting_id }) => jsonToolResult(async () => {
        const meeting = await sync.getMeeting(identity, sync.parseId(vault_id), sync.parseId(meeting_id));
        if (!meeting) throw new ArtifactRequestError(404, "meeting_not_found");
        return meeting;
      }));
      server.registerTool("get_meeting_transcript", {
        description: "Get the active transcript for a synchronized meeting you can read.",
        inputSchema: meetingInput,
        annotations: { readOnlyHint: true },
      }, async ({ vault_id, meeting_id }) => jsonToolResult(async () => sync.listTranscript(
        identity,
        sync.parseId(vault_id),
        sync.parseId(meeting_id),
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
    if (error instanceof ArtifactRequestError) {
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

function decodeContent(content: string, encoding: "utf8" | "base64"): Uint8Array {
  if (encoding === "utf8") {
    const bytes = new TextEncoder().encode(content);
    if (bytes.byteLength > MCP_ARTIFACT_MAX_BYTES) throw new ArtifactRequestError(413, "artifact_too_large");
    return bytes;
  }
  if (!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(content)) {
    throw new ArtifactRequestError(400, "invalid_base64");
  }
  const padding = content.endsWith("==") ? 2 : content.endsWith("=") ? 1 : 0;
  if ((content.length / 4) * 3 - padding > MCP_ARTIFACT_MAX_BYTES) {
    throw new ArtifactRequestError(413, "artifact_too_large");
  }
  const decoded = atob(content);
  if (btoa(decoded) !== content) throw new ArtifactRequestError(400, "invalid_base64");
  return Uint8Array.from(decoded, (character) => character.charCodeAt(0));
}

function uploadRequest(config: AppConfig, bytes: Uint8Array, contentType: string): Request {
  return new Request(`${config.baseUrl}/api/v1/artifacts`, {
    method: "POST",
    headers: {
      "content-length": String(bytes.byteLength),
      "content-type": contentType,
    },
    body: new Uint8Array(bytes).buffer,
  });
}

function artifactResult(config: AppConfig, artifact: ArtifactRecord) {
  const url = `${config.baseUrl}/artifacts/${artifact.id}`;
  return {
    artifact_id: artifact.id,
    url,
    content_type: artifact.contentType,
    visibility: artifact.visibility,
    resource: {
      type: "resource_link" as const,
      name: `Artifact ${artifact.id}`,
      uri: `${config.baseUrl}/api/v1/artifacts/${artifact.id}/content`,
      mimeType: artifact.contentType,
    },
  };
}

async function toolResult(operation: () => Promise<ReturnType<typeof artifactResult>>): Promise<CallToolResult> {
  try {
    const { resource, ...structuredContent } = await operation();
    return {
      content: [resource],
      structuredContent,
    };
  } catch (error) {
    if (error instanceof ArtifactRequestError) {
      return { isError: true, content: [{ type: "text", text: error.code }] };
    }
    throw error;
  }
}
