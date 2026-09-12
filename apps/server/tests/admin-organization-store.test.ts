import { DatabaseSync } from "node:sqlite";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, it } from "vitest";
import { createNodeApplicationStore } from "../src/auth/node-store";

it("reads only the requested organization's members and teams with independent paging", async () => {
  const directory = mkdtempSync(join(tmpdir(), "dahlia-admin-org-"));
  const path = join(directory, "test.sqlite");
  const store = createNodeApplicationStore({ authProvider: "header", authHeader: "X-Forwarded-Email", databaseType: "sqlite", databaseUrl: `file:${path}`,
    baseUrl: "http://localhost:5173", oauthRedirectUris: [], maxRequestBytes: 1024 });
  try {
    await store.migrate();
    const db = new DatabaseSync(path);
    try {
      for (const id of ["one", "two"]) {
        db.prepare('INSERT INTO user (id,name,email,email_verified,created_at,updated_at) VALUES (?,?,?,1,0,0)').run(id, id, `${id}@example.com`);
        db.prepare('INSERT INTO organization (id,name,slug,created_at) VALUES (?,?,?,0)').run(id, id, id);
        db.prepare('INSERT INTO member (id,organization_id,user_id,role,created_at) VALUES (?,?,?,\'member\',0)').run(id, id, id);
        db.prepare('INSERT INTO team (id,organization_id,name,created_at) VALUES (?,?,?,0)').run(id, id, id);
      }
    } finally { db.close(); }
    expect(await store.getServerOrganization("one", 100, 0, 0)).toEqual({ id: "one", name: "one", slug: "one", kind: "team",
      members: [{ id: "one", userId: "one", role: "member", name: "one", email: "one@example.com" }], teams: [{ id: "one", name: "one" }] });
    expect(await store.getServerOrganization("one", 100, 1, 0)).toMatchObject({ members: [], teams: [{ id: "one" }] });
    expect(await store.getServerOrganization("one", 100, 0, 1)).toMatchObject({ members: [{ id: "one" }], teams: [] });
    expect(await store.getServerOrganization("missing", 100, 0, 0)).toBeNull();
  } finally { await store.close?.(); rmSync(directory, { recursive: true, force: true }); }
});
