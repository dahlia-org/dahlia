import { createNodeApplicationStore } from "../auth/node-store";
import { loadConfig } from "../config";
import { pruneSyncHistory } from "../sync/retention";

async function main() {
  const args = process.argv.slice(2);
  if (args.length === 0) {
    console.info(JSON.stringify({ event: "sync_retention_disabled" }));
    return;
  }
  if (args.length !== 1 || args[0] !== "--apply") throw new Error("invalid_arguments");
  const store = createNodeApplicationStore(loadConfig(process.env));
  try {
    const counts = await pruneSyncHistory(store.sync);
    console.info(JSON.stringify({ event: "sync_retention_completed", ...counts }));
  } finally {
    await store.close?.();
  }
}

void main().catch(() => {
  console.error(JSON.stringify({ event: "sync_retention_failed" }));
  process.exitCode = 1;
});
