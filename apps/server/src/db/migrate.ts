import { initializeDahliaAuth } from "../auth/better-auth";
import { createNodeAuthStore } from "../auth/node-store";
import { loadConfig } from "../config";

const config = loadConfig(process.env);

if (config.authDatabase !== "d1") {
  const authStore = createNodeAuthStore(config);
  try {
    await authStore.migrate();
    if (config.authProvider === "accounts") await initializeDahliaAuth(config, authStore);
  } finally {
    await authStore.close?.();
  }
  console.info("Dahlia Server application database is up to date");
} else {
  console.info("D1 application migrations are managed by Wrangler");
}
