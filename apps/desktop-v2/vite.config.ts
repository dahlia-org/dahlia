import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import { defineConfig } from "vite";

// The renderer, served from app://dahlia by the main process (or by this server in development).
export default defineConfig({
  root: "src/renderer",
  base: "/",
  plugins: [tailwindcss(), react()],
  build: { outDir: "../../dist/renderer", emptyOutDir: true },
  server: { port: 5175, strictPort: true },
});
