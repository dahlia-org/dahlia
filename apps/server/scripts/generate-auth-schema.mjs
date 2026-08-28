import { oauthProvider } from "@better-auth/oauth-provider";
import { jwt } from "better-auth/plugins";
import { readdirSync, realpathSync } from "node:fs";
import { mkdir, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const betterAuthEntry = realpathSync(fileURLToPath(import.meta.resolve("better-auth")));
const generatorDirectory = resolve(dirname(betterAuthEntry), "../../@better-auth/drizzle-adapter/dist");
const generatorFile = readdirSync(generatorDirectory)
  .find((file) => file.startsWith("generate-drizzle-schema-") && file.endsWith(".mjs"));
if (!generatorFile) throw new Error("Better Auth Drizzle schema generator was not found");
const generatorUrl = pathToFileURL(resolve(generatorDirectory, generatorFile));
const { generateDrizzleSchema } = await import(generatorUrl);

const plugins = [
  jwt(),
  oauthProvider({
    resources: ["https://dahlia.invalid/api/v1"],
    scopes: ["openid", "profile", "email", "offline_access", "api.model.read", "api.model.request"],
  }),
];

await mkdir("src/db", { recursive: true });
const postgres = await generateDrizzleSchema({
  adapterConfig: { provider: "pg" },
  camelCase: false,
  file: "src/db/auth-schema.ts",
  options: { plugins },
  provider: "pg",
});
const postgresSchema = postgres.code
  .replace('import { defineRelationsPart } from "drizzle-orm";\n', "")
  .replace(/\n\nexport const authRelations[\s\S]*$/, "\n")
  .replace("accountId: text('account_id')", "accountId: text('provider_account_id')")
  .replace("account_issuer_accountId_uidx", "account_issuer_providerAccountId_uidx")
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
await writeFile(postgres.path, postgresSchema);

const sqlite = await generateDrizzleSchema({
  adapterConfig: { provider: "sqlite" },
  camelCase: true,
  file: "src/db/sqlite-schema.ts",
  options: { plugins },
  provider: "sqlite",
});
const sqliteSchema = sqlite.code
  .replace('import { defineRelationsPart, sql } from "drizzle-orm";', 'import { sql } from "drizzle-orm";')
  .replace(
    'import { sqliteTable, text, integer, index, uniqueIndex } from "drizzle-orm/sqlite-core";',
    'import { customType, sqliteTable, text, integer, index, uniqueIndex } from "drizzle-orm/sqlite-core";',
  )
  .replace(/\n\nexport const authRelations[\s\S]*$/, "\n")
  .replaceAll(/integer\(([^,]+), \{ mode: 'timestamp_ms' \}\)/g, "sqliteDate($1)")
  .replaceAll(".default(sql`(cast(unixepoch('subsecond') * 1000 as integer))`)", ".default(sql`CURRENT_TIMESTAMP`)")
  .replace("accountId: text('accountId')", "accountId: text('providerAccountId')")
  .replace("account_issuer_accountId_uidx", "account_issuer_providerAccountId_uidx")
  .replace(
    "export const user = sqliteTable",
    `const sqliteDate = customType<{ data: Date; driverData: string }>({
  dataType: () => "text",
  fromDriver: (value) => new Date(value),
  toDriver: (value) => value.toISOString(),
});

export const user = sqliteTable`,
  )
  .concat(`
export const modelAlias = sqliteTable("modelAlias", {
  alias: text("alias").primaryKey(),
  upstreamModel: text("upstreamModel").notNull(),
  displayName: text("displayName"),
  enabled: integer("enabled", { mode: "boolean" }).default(true).notNull(),
  createdAt: sqliteDate("createdAt").default(sql\`CURRENT_TIMESTAMP\`).notNull(),
  updatedAt: sqliteDate("updatedAt").default(sql\`CURRENT_TIMESTAMP\`).notNull(),
});

export const platformAdmin = sqliteTable("platformAdmin", {
  email: text("email").primaryKey(),
  createdAt: sqliteDate("createdAt").default(sql\`CURRENT_TIMESTAMP\`).notNull(),
});
`);
await writeFile(sqlite.path, sqliteSchema);
