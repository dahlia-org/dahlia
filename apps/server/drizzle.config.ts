import { defineConfig } from "drizzle-kit";

export default defineConfig({
  dialect: "postgresql",
  schema: ["./src/db/generated/postgres-auth-schema.ts", "./src/db/postgres-app-schema.ts"],
  out: "./drizzle/postgres",
  dbCredentials: {
    url: process.env.DAHLIA_DATABASE_URL ?? "",
  },
});
