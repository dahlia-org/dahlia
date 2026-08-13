import { defineConfig } from "tsup";

export default defineConfig({
  clean: true,
  dts: true,
  entry: {
    "db/migrate": "src/db/migrate.ts",
    index: "src/index.ts",
    node: "src/node.ts",
    worker: "src/worker.ts",
  },
  format: "esm",
  outDir: "dist/server",
  platform: "node",
  removeNodeProtocol: false,
  sourcemap: true,
  target: "node22",
});
