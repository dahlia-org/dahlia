import { copyFile, mkdir, readdir, rm } from "node:fs/promises";

const source = new URL("../drizzle/sqlite/", import.meta.url);
const destination = new URL("../drizzle/d1/", import.meta.url);
const migrations = (await readdir(source, { withFileTypes: true }))
  .filter((entry) => entry.isDirectory())
  .map((entry) => entry.name)
  .sort();

await mkdir(destination, { recursive: true });
for (const entry of await readdir(destination, { withFileTypes: true })) {
  if (entry.isFile() && entry.name.endsWith(".sql")) await rm(new URL(entry.name, destination));
}
for (const migration of migrations) {
  await copyFile(new URL(`${migration}/migration.sql`, source), new URL(`${migration}.sql`, destination));
}
