import { defineConfig } from "drizzle-kit";

export default defineConfig({
  dialect: "postgresql",
  schema: "./src/db/postgres-agent-schema.ts",
  out: "./drizzle/postgres-agent",
  dbCredentials: { url: process.env.DAHLIA_DATABASE_URL ?? "" },
  migrations: { schema: "drizzle", table: "__dahlia_agent_migrations" },
});
