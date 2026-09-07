import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { expect, it } from "vitest";

it("preserves a pruned global cursor while extending the recording change constraint", () => {
  const db = new DatabaseSync(":memory:");
  try {
    db.exec(`CREATE TABLE sync_changes (
      sequence INTEGER PRIMARY KEY AUTOINCREMENT, owner_user_id TEXT NOT NULL, vault_id TEXT NOT NULL,
      entity TEXT NOT NULL, entity_id TEXT NOT NULL, action TEXT NOT NULL, revision INTEGER,
      transaction_id TEXT NOT NULL, created_at INTEGER NOT NULL
    );
    INSERT INTO sync_changes VALUES (900, 'owner', 'vault', 'meeting', 'meeting', 'upsert', 1, 'tx', 1);
    DELETE FROM sync_changes;`);
    db.exec(readFileSync(new URL("../drizzle/sqlite/20260907132433_stiff_slyde/migration.sql", import.meta.url), "utf8"));
    db.exec(`INSERT INTO sync_changes(owner_user_id, vault_id, entity, entity_id, action, revision, transaction_id, created_at)
      VALUES ('owner', 'vault', 'recording', 'session', 'upsert', 1, 'tx2', 2);`);
    expect(db.prepare("SELECT sequence FROM sync_changes").get()).toEqual({ sequence: 901 });
  } finally { db.close(); }
});
