import { oauthProvider } from "@better-auth/oauth-provider";
import { stripe } from "@better-auth/stripe";
import { jwt, organization } from "better-auth/plugins";
import { realpathSync } from "node:fs";
import { mkdir, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import Stripe from "stripe";

const betterAuthEntry = realpathSync(fileURLToPath(import.meta.resolve("better-auth")));
const generatorUrl = pathToFileURL(resolve(
  dirname(betterAuthEntry),
  "../../@better-auth/drizzle-adapter/dist/generate-drizzle-schema-D5cxh_0D.mjs",
));
const { generateDrizzleSchema } = await import(generatorUrl);
const stripeClient = new Stripe("sk_test_schema_generation");

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
      stripe({
        stripeClient,
        stripeWebhookSecret: "whsec_schema_generation",
        createCustomerOnSignUp: true,
        subscription: {
          enabled: true,
          plans: [{ name: "pro", priceId: "price_schema_generation" }],
        },
        organization: { enabled: true },
      }),
      organization({ teams: { enabled: false } }),
    ],
  },
  provider: "pg",
});

await mkdir("src/db", { recursive: true });
const schemaOnly = result.code
  .replace('import { defineRelationsPart } from "drizzle-orm";\n', "")
  .replace('index("member_userId_idx")', 'uniqueIndex("member_userId_uidx")')
  .replace(
    " stripeScheduleId: text('stripe_schedule_id')\n\t\t\t\t\t});",
    " stripeScheduleId: text('stripe_schedule_id')\n\t\t\t\t\t}, (table) => [\n  index(\"subscription_referenceId_idx\").on(table.referenceId),\n]);",
  )
  .replace(/\n\nexport const authRelations[\s\S]*$/, "\n");
await writeFile(result.path, schemaOnly);
