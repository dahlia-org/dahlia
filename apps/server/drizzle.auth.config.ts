import { defineConfig } from "drizzle-kit";

export default defineConfig({
  dialect: "postgresql",
  schema: "./src/db/generated/postgres-auth-schema.ts",
  out: "./drizzle/postgres-auth",
  dbCredentials: {
    url: process.env.DAHLIA_DATABASE_URL ?? "",
  },
  migrations: {
    schema: "drizzle",
    table: "__dahlia_auth_migrations",
  },
});
