import { initializeDahliaAuth } from "../auth/better-auth";
import { createNodeApplicationStore } from "../auth/node-store";
import { loadConfig } from "../config";

const config = loadConfig(process.env);

if (config.databaseType !== "d1") {
  const applicationStore = createNodeApplicationStore(config);
  try {
    await applicationStore.migrate();
    if (config.authProvider === "accounts") await initializeDahliaAuth(config, applicationStore);
  } finally {
    await applicationStore.close?.();
  }
  console.info("Dahlia Server application database is up to date");
} else {
  console.info("D1 application migrations are managed by Wrangler");
}
