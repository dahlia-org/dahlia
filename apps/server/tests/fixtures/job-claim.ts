import { fileURLToPath } from "node:url";
import { DatabaseSync } from "node:sqlite";
import { drizzle } from "drizzle-orm/sqlite-proxy";
import { createJobStore } from "../../src/jobs/store";
import { defaultJobLimits } from "../../src/jobs/model";

// Load only the claim boundary in each child, without unrelated application/AI startup.
const database = new DatabaseSync(fileURLToPath(process.argv[2]!));
database.exec("PRAGMA busy_timeout = 5000");
const db = drizzle(async (sql, params, method) => {
  const statement = database.prepare(sql);
  statement.setReturnArrays(true);
  if (method === "run") { statement.run(...params as []); return { rows: [] }; }
  if (method === "get") return { rows: statement.get(...params as []) as unknown as unknown[] };
  return { rows: statement.all(...params as []) as unknown[] };
});
try {
  const claim = await createJobStore(db, false, defaultJobLimits).claim(["image", "search"]);
  process.send?.(claim?.id ?? null);
} finally { database.close(); process.disconnect?.(); }
