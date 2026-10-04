import { fileURLToPath } from "node:url";
import { defineConfig } from "tsup";

// Declarations inline the private workspace UI package, so consumers never resolve @dahlia-ai/ui.
const ui = fileURLToPath(new URL("../../packages/ui/src/", import.meta.url));
const uiPaths = { "@dahlia-ai/ui": [`${ui}index.ts`], "@dahlia-ai/ui/*": [`${ui}*`] };

export default defineConfig({
  clean: true,
  dts: { compilerOptions: { paths: uiPaths } },
  entry: { index: "src/client/index.ts" },
  external: ["better-auth", "react", "react-dom"],
  format: "esm",
  outDir: "dist/client-library",
  platform: "browser",
  sourcemap: true,
  target: "es2023",
});
