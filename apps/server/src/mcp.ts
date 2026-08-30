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
import type { AppConfig } from "./config";

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

export function createArtifactMcpHandler(config: AppConfig, artifacts: ArtifactService) {
  return createMcpHandler(({ authInfo }) => {
    const identity = mcpIdentity(authInfo);
    const server = new McpServer({ name: "Dahlia Server", version: "0.1.0" });

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

    return server;
  }, { legacy: "reject" });
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
  const url = `${config.baseUrl}/api/v1/artifacts/${artifact.id}`;
  return {
    artifact_id: artifact.id,
    url,
    content_type: artifact.contentType,
    visibility: artifact.visibility,
    resource: {
      type: "resource_link" as const,
      name: `Artifact ${artifact.id}`,
      uri: url,
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
