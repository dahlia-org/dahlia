import { createNodeApplicationStore } from "../auth/node-store";
import { loadConfig } from "../config";

async function main() {
  const args = process.argv.slice(2);
  if (args.length > 1 || (args.length === 1 && args[0] !== "--apply")) throw new Error("invalid_arguments");
  const store = createNodeApplicationStore(loadConfig(process.env));
  try {
    const apply = args[0] === "--apply";
    const counts = await store.rotateEncryptionKeys(apply);
    console.info(JSON.stringify({ event: "vault_key_rotation_completed", apply, ...counts }));
  } finally { await store.close?.(); }
}

void main().catch(() => {
  console.error(JSON.stringify({ event: "vault_key_rotation_failed" }));
  process.exitCode = 1;
});
