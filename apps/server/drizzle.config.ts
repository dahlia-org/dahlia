import { defineConfig } from "drizzle-kit";

export default defineConfig({
  dialect: "postgresql",
  schema: "./src/db/postgres-app-schema.ts",
  out: "./drizzle/postgres",
  dbCredentials: {
    url: process.env.DAHLIA_DATABASE_URL ?? "",
  },
  migrations: {
    schema: "drizzle",
    table: "__dahlia_server_migrations",
  },
});
