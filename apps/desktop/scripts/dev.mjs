// Development: Vite serves the shared renderer with HMR through app://dahlia; the Server runs separately.
import { spawn } from "node:child_process";
import { createRequire } from "node:module";
import { build } from "tsup";
import { createServer } from "vite";

await build({ silent: true });
const vite = await createServer({ configFile: new URL("../vite.config.ts", import.meta.url).pathname });
await vite.listen();
const renderer = `http://localhost:${vite.config.server.port}`;
const electron = createRequire(import.meta.url)("electron");
const child = spawn(electron, [".", ...process.argv.slice(2).filter((arg) => arg !== "--")], { stdio: "inherit", env: { ...process.env, DAHLIA_DESKTOP_RENDERER_URL: renderer } });
child.on("exit", async (code) => { await vite.close(); process.exit(code ?? 0); });
for (const signal of ["SIGINT", "SIGTERM"]) process.on(signal, () => child.kill(signal));
