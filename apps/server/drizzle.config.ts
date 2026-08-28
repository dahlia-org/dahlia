import { defineConfig } from "drizzle-kit";

export default defineConfig({
  dialect: "postgresql",
  schema: "./src/db/auth-schema.ts",
  out: "./drizzle",
  dbCredentials: {
    url: process.env.DAHLIA_DATABASE_URL ?? "",
  },
});
