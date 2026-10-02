import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { expect, it } from "vitest";
import { serverMigrationManifest } from "../src/migrations";

it("uses bounded document indexes for recovery pages, presence reads and expiry cleanup", () => {
  const db = new DatabaseSync(":memory:");
  try {
    for (const file of serverMigrationManifest.sqlite.files) db.exec(readFileSync(new URL(`../${file}`, import.meta.url), "utf8"));
    db.exec(`INSERT INTO user(id, name, email, updated_at) VALUES ('user', 'User', 'user@example.com', 1);
      INSERT INTO organization(id, name, slug, created_at) VALUES ('org', 'Org', 'org', 1);
      INSERT INTO workspaces(workspace_id, organization_id, created_by, name) VALUES ('workspace', 'org', '{}', 'Workspace');
      WITH RECURSIVE n(g) AS (VALUES(0) UNION ALL SELECT g+1 FROM n WHERE g < 1999)
      INSERT INTO documents(id, workspace_id, kind, generation, checkpoint, text, created_at, updated_at)
      SELECT CASE WHEN g = 0 THEN 'doc' ELSE 'doc-' || g END, 'workspace', 'general', 'generation', 'AAA=', '', 1, 1 FROM n;`);
    // Populate planner statistics: most sessions belong to other documents in the same Workspace.
    db.exec(`WITH RECURSIVE n(g) AS (VALUES(1) UNION ALL SELECT g+1 FROM n WHERE g < 10000)
      INSERT INTO document_presence(id, document_id, workspace_id, user_id, expires_at)
      SELECT 'session-' || g, CASE WHEN g % 2000 = 0 THEN 'doc' ELSE 'doc-' || (g % 2000) END,
        'workspace', 'user', CASE WHEN g <= 10 THEN 0 ELSE 2 END FROM n;
      ANALYZE document_presence;`);
    const cases = [
      ["SELECT id FROM document_recoveries WHERE document_id = 'doc' AND workspace_id = 'workspace' AND sequence > 0 AND sequence <= 100 ORDER BY sequence LIMIT 101", "document_recoveries_document_cursor"],
      ["SELECT user_id FROM document_presence WHERE document_id = 'doc' AND workspace_id = 'workspace' AND expires_at > 1", "document_presence_document_expiry"],
      ["DELETE FROM document_presence WHERE workspace_id = 'workspace' AND expires_at <= 1", "document_presence_workspace_expiry"],
      ["SELECT id FROM documents WHERE workspace_id = 'workspace' AND id > 'cursor' ORDER BY id LIMIT 101", "COVERING INDEX"],
    ];
    for (const [query, index] of cases) {
      const plan = db.prepare(`EXPLAIN QUERY PLAN ${query}`).all().map((row) => row.detail).join("\n");
      expect(plan).toContain(index);
      expect(plan).not.toContain("USE TEMP B-TREE");
    }
    expect(db.prepare("SELECT name FROM sqlite_master WHERE name = 'documents_workspace_id'").all()).toEqual([]);
  } finally { db.close(); }
});
