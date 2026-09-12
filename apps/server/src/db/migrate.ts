import { initializeDahliaAuth } from "../auth/better-auth";
import { createNodeApplicationStore } from "../auth/node-store";
import { loadConfig } from "../config";

const config = loadConfig(process.env);

const applicationStore = createNodeApplicationStore(config);
try {
  await applicationStore.migrate();
  await initializeDahliaAuth(config, applicationStore);
} finally {
  await applicationStore.close?.();
}
console.info("Dahlia Server application database is up to date");
