import { defineConfig } from "tsup";

export default defineConfig({
  clean: true,
  dts: true,
  entry: {
    "db/migrate": "src/db/migrate.ts",
    "db/prune-sync-history": "src/db/prune-sync-history.ts",
    index: "src/index.ts",
    migrations: "src/migration-api.ts",
    node: "src/node.ts",
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
