import { defineConfig } from "tsup";

export default defineConfig({
  clean: true,
  dts: true,
  entry: { index: "src/client/index.ts" },
  external: ["better-auth", "react", "react-dom"],
  format: "esm",
  outDir: "dist/client-library",
  platform: "browser",
  sourcemap: true,
  target: "es2023",
});
