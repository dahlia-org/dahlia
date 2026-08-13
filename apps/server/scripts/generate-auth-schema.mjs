import { oauthProvider } from "@better-auth/oauth-provider";
import { jwt } from "better-auth/plugins";
import { realpathSync } from "node:fs";
import { mkdir, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const betterAuthEntry = realpathSync(fileURLToPath(import.meta.resolve("better-auth")));
const generatorUrl = pathToFileURL(resolve(
  dirname(betterAuthEntry),
  "../../@better-auth/drizzle-adapter/dist/generate-drizzle-schema-D5cxh_0D.mjs",
));
const { generateDrizzleSchema } = await import(generatorUrl);

const result = await generateDrizzleSchema({
  adapterConfig: { provider: "pg" },
  camelCase: false,
  file: "src/db/auth-schema.ts",
  options: {
    plugins: [
      jwt(),
      oauthProvider({
        resources: ["https://dahlia.invalid/api/v1"],
        scopes: ["openid", "profile", "email", "offline_access", "api.model.read", "api.model.request"],
      }),
    ],
  },
  provider: "pg",
});

await mkdir("src/db", { recursive: true });
const schemaOnly = result.code
  .replace('import { defineRelationsPart } from "drizzle-orm";\n', "")
  .replace(/\n\nexport const authRelations[\s\S]*$/, "\n")
  .concat(`
export const modelAlias = pgTable("model_alias", {
  alias: text("alias").primaryKey(),
  upstreamModel: text("upstream_model").notNull(),
  displayName: text("display_name"),
  enabled: boolean("enabled").default(true).notNull(),
  createdAt: timestamp("created_at").defaultNow().notNull(),
  updatedAt: timestamp("updated_at").defaultNow().notNull(),
});

export const platformAdmin = pgTable("platform_admin", {
  email: text("email").primaryKey(),
  createdAt: timestamp("created_at").defaultNow().notNull(),
});
`);
await writeFile(result.path, schemaOnly);
