import { mkdir, mkdtemp, readFile, readdir, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const packageJson = JSON.parse(await readFile(new URL("../package.json", import.meta.url), "utf8"));
const directory = await mkdtemp(join(tmpdir(), "dahlia-server-package-"));

async function readEntryGraph(entry) {
  const files = new Map();
  async function visit(file) {
    if (files.has(file)) return;
    const source = await readFile(file, "utf8");
    files.set(file, source);
    for (const match of source.matchAll(/(?:from\s+|import\s+)["']\.\/([^"']+\.js)["']/g)) {
      await visit(join(dirname(file), match[1]));
    }
  }
  await visit(entry);
  return files;
}

try {
  const packed = spawnSync("pnpm", ["pack", "--pack-destination", directory], {
    cwd: new URL("..", import.meta.url),
    encoding: "utf8",
  });
  if (packed.status !== 0) throw new Error(packed.stderr || packed.stdout || "pnpm pack failed");
  const tarball = join(directory, `dahlia-ai-server-${packageJson.version}.tgz`);
  const installedPackage = join(directory, "node_modules", "@dahlia-ai", "server");
  await mkdir(installedPackage, { recursive: true });
  const extracted = spawnSync("tar", ["-xzf", tarball, "-C", installedPackage, "--strip-components=1"], {
    encoding: "utf8",
  });
  if (extracted.status !== 0) throw new Error(extracted.stderr || extracted.stdout || "tar extraction failed");
  const workspaceModules = fileURLToPath(new URL("../node_modules", import.meta.url));
  for (const dependency of [
    ...Object.keys(packageJson.dependencies),
    ...Object.keys(packageJson.peerDependencies),
    "@types/node",
  ]) {
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
    import { createApp } from "@dahlia-ai/server";
    import { createNodeAuthStore } from "@dahlia-ai/server/node";
    import { App } from "@dahlia-ai/server/client";
    import { serverMigrationManifest } from "@dahlia-ai/server/migrations";
    import { readFile } from "node:fs/promises";
    import { DatabaseSync } from "node:sqlite";
    import { fileURLToPath } from "node:url";

    if (typeof createApp !== "function" || typeof App !== "function") throw new Error("Package API is incomplete");
    if (serverMigrationManifest.sqlite.files.length !== 4) {
      throw new Error("Migration manifest is incomplete");
    }
    const style = await readFile(new URL(import.meta.resolve("@dahlia-ai/server/client/styles.css")), "utf8");
    const migration = await readFile(
      new URL(import.meta.resolve("@dahlia-ai/server/migrations/sqlite/0002_server.sql")),
      "utf8",
    );
    const artifactMigration = await readFile(
      new URL(import.meta.resolve("@dahlia-ai/server/migrations/sqlite/0003_artifact.sql")),
      "utf8",
    );
    const reservationMigration = await readFile(
      new URL(import.meta.resolve("@dahlia-ai/server/migrations/sqlite/0004_artifact_reservation.sql")),
      "utf8",
    );
    if (
      !style.includes(".app-shell")
      || !migration.includes("modelAlias")
      || !artifactMigration.includes("artifact")
      || !reservationMigration.includes("artifactReservation")
    ) {
      throw new Error("Package assets are incomplete");
    }

    const databasePath = fileURLToPath(new URL("./auth.sqlite", import.meta.url));
    const store = createNodeAuthStore({
      authProvider: "header",
      authHeader: "X-Forwarded-Email",
      databaseType: "sqlite",
      databaseUrl: "file:" + databasePath,
      baseUrl: "http://localhost:5173",
      oauthRedirectUris: [],
      maxRequestBytes: 1024,
    });
    await store.migrate();
    const database = new DatabaseSync(databasePath);
    const applied = database.prepare('SELECT "name" FROM "_dahlia_auth_migrations" ORDER BY "name"').all();
    database.close();
    await store.close?.();
    if (applied.length !== 4 || applied[3]?.name !== "server/0004_artifact_reservation.sql") {
      throw new Error("Installed package migrations did not run from the package directory");
    }
  `);
  await writeFile(join(directory, "verify.ts"), `
    import { createD1AuthStore, type D1DatabaseLike } from "@dahlia-ai/server";
    import { createNodeAuthStore } from "@dahlia-ai/server/node";
    import type { App } from "@dahlia-ai/server/client";

    declare const database: D1DatabaseLike;
    const store = createD1AuthStore(database);
    const client: typeof App | undefined = undefined;
    void store;
    void client;
    void createNodeAuthStore;
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
  for (const [file, source] of await readEntryGraph(join(installedPackage, "dist", "server", "index.js"))) {
    if (/node:(?:fs|http2|net|path|sqlite|url)/.test(source) || source.includes("node-store")) {
      throw new Error(`Node-only module leaked into the package root entry: ${file}`);
    }
  }
} finally {
  await rm(directory, { force: true, recursive: true });
}
