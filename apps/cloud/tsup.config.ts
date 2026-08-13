import { defineConfig } from "tsup";

export default defineConfig({
  clean: true,
  entry: ["src/node.ts", "src/db/migrate.ts"],
  format: "esm",
  outDir: "dist/server",
  platform: "node",
  removeNodeProtocol: false,
  sourcemap: true,
  target: "node22",
});
