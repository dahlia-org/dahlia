import { defineConfig } from "tsup";

export default defineConfig({
  entry: {
    "document-core": "src/documents/native-core.ts",
    "document-editor": "src/documents/native-editor.ts",
    "transcript-surface": "src/content-surface/transcript.ts",
  },
  globalName: "DahliaDocuments", format: "iife", platform: "browser", target: "es2022",
  outDir: "dist/documents", noExternal: [/.*/], minify: true, metafile: true, sourcemap: false, clean: true,
});
