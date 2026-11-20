import { defineConfig, type Options } from "tsup";

// Main is an ES module; the sandboxed preload must be a single CommonJS file. `node:sqlite` exists only with its prefix.
const common: Options = { platform: "node", target: "node24", external: ["electron"], outDir: "dist", clean: false, removeNodeProtocol: false };
export default defineConfig([
  { ...common, entry: { main: "src/main/main.ts" }, format: "esm" },
  { ...common, entry: { preload: "src/preload/preload.ts" }, format: "cjs", outExtension: () => ({ js: ".cjs" }) },
]);
