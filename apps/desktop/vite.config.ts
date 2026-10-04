import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import { defineConfig } from "vite";

// Renderer built from the shared @dahlia-ai/ui source and served from app://dahlia by the main process.
export default defineConfig({
  root: "src/renderer",
  base: "/",
  plugins: [tailwindcss(), react()],
  build: { outDir: "../../dist/renderer", emptyOutDir: true },
  server: { port: 5174, strictPort: true, hmr: { protocol: "ws", host: "localhost", port: 5174 } },
});
