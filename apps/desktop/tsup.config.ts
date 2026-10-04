import { defineConfig } from "tsup";

// Main is an ES module; the sandboxed preload must be a single CommonJS file.
export default defineConfig([
  { entry: { main: "src/main/main.ts" }, format: "esm", platform: "node", target: "node22", external: ["electron"], outDir: "dist", clean: false },
  { entry: { preload: "src/preload/preload.ts" }, format: "cjs", platform: "node", target: "node22", external: ["electron"], outDir: "dist", clean: false, outExtension: () => ({ js: ".cjs" }) },
]);
