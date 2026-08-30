import { defineConfig } from "drizzle-kit";

export default defineConfig({
  dialect: "sqlite",
  schema: ["./src/db/generated/sqlite-auth-schema.ts", "./src/db/sqlite-app-schema.ts"],
  out: "./drizzle/sqlite",
});
