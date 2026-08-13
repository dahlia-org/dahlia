import { mkdir, mkdtemp, readFile, readdir, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const packageJson = JSON.parse(await readFile(new URL("../package.json", import.meta.url), "utf8"));
const directory = await mkdtemp(join(tmpdir(), "dahlia-server-package-"));

try {
  const packed = spawnSync("pnpm", ["pack", "--pack-destination", directory], {
    cwd: new URL("..", import.meta.url),
    encoding: "utf8",
  });
  if (packed.status !== 0) throw new Error(packed.stderr || packed.stdout || "pnpm pack failed");
  const tarball = join(directory, `dahlia-ai-${packageJson.version}.tgz`);
  const installedPackage = join(directory, "node_modules", "dahlia-ai");
  await mkdir(installedPackage, { recursive: true });
  const extracted = spawnSync("tar", ["-xzf", tarball, "-C", installedPackage, "--strip-components=1"], {
    encoding: "utf8",
  });
  if (extracted.status !== 0) throw new Error(extracted.stderr || extracted.stdout || "tar extraction failed");
  const workspaceModules = fileURLToPath(new URL("../node_modules", import.meta.url));
  for (const dependency of [...Object.keys(packageJson.dependencies), "@types/node"]) {
    const destination = join(directory, "node_modules", dependency);
    await mkdir(dirname(destination), { recursive: true });
    await symlink(join(workspaceModules, dependency), destination);
  }
  await writeFile(join(directory, "package.json"), JSON.stringify({
    name: "dahlia-server-package-consumer",
    private: true,
    type: "module",
  }));
  await writeFile(join(directory, "verify.mjs"), `
    import { createApp, serverMigrationManifest } from "dahlia-ai";
    import { App } from "dahlia-ai/client";
    import { serverMigrationManifest as manifestFromSubpath } from "dahlia-ai/migrations";
    import { readFile } from "node:fs/promises";

    if (typeof createApp !== "function" || typeof App !== "function") throw new Error("Package API is incomplete");
    if (serverMigrationManifest !== manifestFromSubpath || serverMigrationManifest.sqlite.files.length !== 2) {
      throw new Error("Migration manifest is incomplete");
    }
    const style = await readFile(new URL(import.meta.resolve("dahlia-ai/client/styles.css")), "utf8");
    const migration = await readFile(
      new URL(import.meta.resolve("dahlia-ai/migrations/sqlite/0002_server.sql")),
      "utf8",
    );
    if (!style.includes(".app-shell") || !migration.includes("modelAlias")) {
      throw new Error("Package assets are incomplete");
    }
  `);
  await writeFile(join(directory, "verify.ts"), `
    import { createD1AuthStore, type D1DatabaseLike } from "dahlia-ai";
    import type { App } from "dahlia-ai/client";

    declare const database: D1DatabaseLike;
    const store = createD1AuthStore(database);
    const client: typeof App | undefined = undefined;
    void store;
    void client;
  `);
  await writeFile(join(directory, "tsconfig.json"), JSON.stringify({
    compilerOptions: {
      lib: ["ES2023", "DOM"],
      module: "NodeNext",
      moduleResolution: "NodeNext",
      noEmit: true,
      skipLibCheck: true,
      strict: true,
      types: ["node"],
    },
    include: ["verify.ts"],
  }));

  const verified = spawnSync(process.execPath, ["verify.mjs"], { cwd: directory, encoding: "utf8" });
  if (verified.status !== 0) throw new Error(verified.stderr || verified.stdout || "consumer verification failed");
  const typed = spawnSync(process.execPath, [join(workspaceModules, "typescript", "bin", "tsc")], {
    cwd: directory,
    encoding: "utf8",
  });
  if (typed.status !== 0) throw new Error(typed.stderr || typed.stdout || "consumer typecheck failed");
  for (const file of await readdir(join(installedPackage, "dist", "server"))) {
    if (!file.endsWith(".d.ts")) continue;
    const declaration = await readFile(join(installedPackage, "dist", "server", file), "utf8");
    if (/\bD1Database\b/.test(declaration)) {
      throw new Error(`Cloudflare global leaked into package declarations: ${file}`);
    }
  }
} finally {
  await rm(directory, { force: true, recursive: true });
}
