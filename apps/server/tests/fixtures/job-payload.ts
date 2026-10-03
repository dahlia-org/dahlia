import { uuidV7 } from "../../src/id";
import type { JobKind, JobPayload } from "../../src/jobs/model";
export function testJobPayload(kind: JobKind): JobPayload {
  switch (kind) {
    case "summary": case "audio-summary": return { id: uuidV7(), workspaceId: uuidV7(), ownerUserId: uuidV7() };
    case "image": return { fileId: uuidV7(), workspaceId: uuidV7(), ownerUserId: uuidV7(), model: "test", mode: "fill_missing" };
    case "search": return { workspaceId: uuidV7(), documentId: uuidV7(), model: "test", dimensions: 32 };
    case "workspace-memory": case "personal-memory": return { scopeId: uuidV7() };
    case "storage-delete": return { storageKey: uuidV7() };
    case "chat-memory": return { threadId: uuidV7(), ownerUserId: uuidV7(), memoryKind: "live", revision: 0 };
    case "reconcile": return { kind: "image", phase: "scopes" };
    case "maintenance": return {};
  }
}
