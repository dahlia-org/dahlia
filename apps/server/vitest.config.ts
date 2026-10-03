import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    // Readiness scenarios alter FORCE RLS on the shared PostgreSQL database.
    fileParallelism: !process.env.TEST_DATABASE_URL,
    coverage: {
      reporter: ["text", "json", "html"],
    },
    environment: "node",
    include: ["tests/**/*.test.ts"],
  },
});
