import { expect, it } from "vitest";
import { Client } from "pg";
import { createNodeApplicationStore } from "../src/auth/node-store";
import { MeetingSyncService } from "../src/sync/service";
import { DocumentCore } from "@dahlia-ai/ui/documents/core";
import { uuidV7 } from "@dahlia-ai/ui/model/id";
import { seedPostgresIdentity, testOrganizationID } from "./public-test-client";

it.runIf(process.env.TEST_DATABASE_URL)("enforces Documents RLS, composite tenant relationships, viewer permissions and shared presence", async () => {
  const databaseUrl = process.env.TEST_DATABASE_URL!;
  const config = { authProvider: "header" as const, authHeader: "X-Forwarded-Email", databaseType: "postgres" as const,
    databaseUrl, baseUrl: "http://localhost:5173", oauthRedirectUris: [], maxRequestBytes: 1_048_576 };
  const first = createNodeApplicationStore(config), second = createNodeApplicationStore(config);
  const client = new Client({ connectionString: databaseUrl });
  const owner = { userId: uuidV7(), source: "header" as const }, reader = { userId: uuidV7(), source: "header" as const };
  const workspaceId = uuidV7(), otherWorkspace = uuidV7(), meetingId = uuidV7();
  const core = new DocumentCore(); core.insertText("private PostgreSQL document", uuidV7);
  try {
    await client.connect();
    await seedPostgresIdentity(first, databaseUrl, owner); await seedPostgresIdentity(first, databaseUrl, reader);
    const sync = new MeetingSyncService(first.sync);
    for (const id of [workspaceId, otherWorkspace]) await sync.commitTransaction(owner, { id: uuidV7(), schemaVersion: 3, workspaceId: id,
      createdAt: new Date().toISOString(), operations: [
        { id: uuidV7(), entity: "workspace", action: "create", entityId: id, baseRevision: null,
          data: { organizationId: testOrganizationID, name: "Documents", encryption: "none", createdAt: new Date().toISOString() } },
        ...(id === workspaceId ? [{ id: uuidV7(), entity: "meeting" as const, action: "create" as const, entityId: meetingId, baseRevision: null,
          data: { name: "Meeting", projectId: null, description: "", status: "READY", duration: null, recordingStartedAt: null,
            createdAt: new Date().toISOString(), updatedAt: new Date().toISOString() } }] : []),
      ] });
    const documentId = uuidV7();
    const doc = await first.sync.withIdentity(owner, (s) => s.initializeMeetingNotes(workspaceId, meetingId, documentId, core.checkpoint()));
    expect((await client.query("SELECT * FROM app.documents WHERE id = $1", [documentId])).rows).toEqual([]);
    const generalId = uuidV7();
    await first.sync.withIdentity(owner, (s) => s.initializeDocument(workspaceId, generalId, { meetingId: null, kind: "general", title: "Independent" }));
    expect((await second.sync.withIdentity(owner, (s) => s.getDocument(workspaceId, generalId)))?.meetingId).toBeNull();
    await expect(second.sync.withIdentity(reader, (s) => s.getDocument(workspaceId, generalId))).rejects.toThrow("document_unavailable");
    expect(await second.sync.withIdentity(owner, (s) => s.notesHeads([{ workspaceId, meetingId }]))).toEqual([{ workspaceId, meetingId, id: documentId, generation: doc.generation, revision: doc.revision }]);
    expect(await second.sync.withIdentity(reader, (s) => s.notesHeads([{ workspaceId, meetingId }]))).toEqual([]);
    const concurrent = await Promise.all([first, second].map((store) => store.sync.withIdentity(owner, (s) => s.initializeMeetingNotes(workspaceId, meetingId, uuidV7()))));
    expect(concurrent.map((row) => row.id)).toEqual([documentId, documentId]);
    await expect(first.sync.withIdentity(reader, (s) => s.getDocument(workspaceId, documentId))).rejects.toThrow("document_unavailable");
    await client.query("BEGIN");
    await client.query("SELECT set_config('app.user_id', $1, true)", [owner.userId]);
    await client.query("INSERT INTO app.workspace_permissions(workspace_id, principal_type, principal_id, role, granted_by_user_id) VALUES ($1, 'user', $2, 'viewer', $3)", [workspaceId, reader.userId, owner.userId]);
    await client.query("COMMIT");
    expect((await second.sync.withIdentity(reader, (s) => s.getDocument(workspaceId, documentId)))?.text).toBe("private PostgreSQL document");
    const recovery = { id: uuidV7(), reason: "concurrent_delete" as const, blocks: [{ id: uuidV7(), type: "paragraph", text: "retained" }] };
    await first.sync.withIdentity(owner, (s) => s.saveDocumentRecovery(workspaceId, documentId, recovery));
    expect((await second.sync.withIdentity(reader, (s) => s.documentRecoveries(workspaceId, documentId))).items[0]).toMatchObject(recovery);
    await expect(first.sync.withIdentity(reader, (s) => s.exchangeDocument(workspaceId, documentId,
      { generation: doc.generation, vector: core.vector(), update: core.checkpoint() }))).rejects.toThrow("document_unavailable");
    const session = uuidV7();
    await first.sync.withIdentity(owner, (s) => s.documentPresence(workspaceId, documentId, session));
    expect(await second.sync.withIdentity(reader, (s) => s.documentPresence(workspaceId, documentId))).toHaveLength(1);
    await client.query("BEGIN");
    await client.query("SELECT set_config('app.user_id', $1, true)", [owner.userId]);
    await client.query("UPDATE app.document_presence SET expires_at = now() - interval '1 second' WHERE id = $1", [session]);
    await client.query("COMMIT");
    expect(await second.sync.withIdentity(reader, (s) => s.documentPresence(workspaceId, documentId))).toEqual([]);
    await client.query("BEGIN");
    await client.query("SELECT set_config('app.user_id', $1, true)", [owner.userId]);
    expect((await client.query("SELECT id FROM app.document_presence WHERE id = $1", [session])).rows).toEqual([{ id: session }]);
    await client.query("COMMIT");
    // A different editor reclaims a departed user's expired session; viewer reads above remain allowed.
    await client.query("BEGIN");
    await client.query("SELECT set_config('app.user_id', $1, true)", [owner.userId]);
    await client.query("UPDATE app.workspace_permissions SET role = 'editor' WHERE workspace_id = $1 AND principal_id = $2", [workspaceId, reader.userId]);
    await client.query("COMMIT");
    await second.sync.withIdentity(reader, (s) => s.documentPresence(workspaceId, documentId, uuidV7()));
    await client.query("BEGIN");
    await client.query("SELECT set_config('app.user_id', $1, true)", [owner.userId]);
    expect((await client.query("SELECT id FROM app.document_presence WHERE id = $1", [session])).rows).toEqual([]);
    await client.query("COMMIT");
    await client.query("BEGIN");
    await client.query("SELECT set_config('app.user_id', $1, true)", [owner.userId]);
    await expect(client.query("INSERT INTO app.document_updates(document_id, workspace_id, revision, update, created_at) VALUES ($1, $2, 2, 'AAA=', now())", [documentId, otherWorkspace])).rejects.toMatchObject({ code: "23503" });
    await client.query("ROLLBACK");
    await client.query("BEGIN");
    await client.query("SELECT set_config('app.user_id', $1, true)", [owner.userId]);
    await expect(client.query("UPDATE app.documents SET workspace_id = $1 WHERE id = $2", [otherWorkspace, documentId])).rejects.toMatchObject({ code: "23503" });
    await client.query("ROLLBACK");
    await client.query("BEGIN");
    await client.query("SELECT set_config('app.user_id', $1, true)", [owner.userId]);
    await expect(client.query("INSERT INTO app.documents(id, workspace_id, meeting_id, kind, title, generation, checkpoint, text, created_at, updated_at) SELECT $1, workspace_id, meeting_id, kind, title, generation, checkpoint, text, created_at, updated_at FROM app.documents WHERE id = $2", [uuidV7(), documentId])).rejects.toMatchObject({ code: "23505" });
    await client.query("ROLLBACK");
    await client.query("BEGIN");
    await client.query("SELECT set_config('app.user_id', $1, true)", [owner.userId]);
    await client.query("UPDATE app.workspaces SET deleting_at = now() WHERE workspace_id = $1", [workspaceId]);
    await client.query("COMMIT");
    await expect(second.sync.withIdentity(reader, (s) => s.listDocuments(workspaceId))).rejects.toThrow("document_unavailable");
  } finally {
    await client.query("ROLLBACK"); await client.end(); await first.close?.(); await second.close?.(); core.destroy();
  }
});
