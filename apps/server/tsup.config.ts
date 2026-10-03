import { fileURLToPath } from "node:url";
import { defineConfig } from "tsup";

// Declarations inline the private workspace UI package, so consumers never resolve @dahlia-ai/ui.
const ui = fileURLToPath(new URL("../../packages/ui/src/", import.meta.url));
const uiPaths = { "@dahlia-ai/ui": [`${ui}index.ts`], "@dahlia-ai/ui/*": [`${ui}*`] };

export default defineConfig({
  clean: true,
  dts: {
    compilerOptions: { paths: uiPaths },
    entry: {
      index: "src/index.ts",
      migrations: "src/migration-api.ts",
      "node-api": "src/node-api.ts",
    },
  },
  entry: {
    "db/rotate-encryption-keys": "src/db/rotate-encryption-keys.ts",
    "db/migrate": "src/db/migrate.ts",
    "db/prune-sync-history": "src/db/prune-sync-history.ts",
    index: "src/index.ts",
    migrations: "src/migration-api.ts",
    node: "src/node.ts",
    "job-worker": "src/job-worker.ts",
    "node-api": "src/node-api.ts",
    worker: "src/worker.ts",
  },
  format: "esm",
  outDir: "dist/server",
  platform: "node",
  removeNodeProtocol: false,
  sourcemap: true,
  target: "node22",
});
