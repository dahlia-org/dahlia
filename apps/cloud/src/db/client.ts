import { drizzle, type PostgresJsDatabase } from "drizzle-orm/postgres-js";
import { migrate } from "drizzle-orm/postgres-js/migrator";
import postgres from "postgres";

import type { AppConfig, DatabricksDatabaseConfig } from "../config";
import * as authSchema from "./auth-schema";

export type Database = PostgresJsDatabase<typeof authSchema>;

function databaseClient(config: AppConfig, max: number) {
  if (config.runtime === "databricks") {
    if (!config.databricksDatabase) {
      throw new Error("Databricks Lakebase configuration is incomplete");
    }
    const database = config.databricksDatabase;
    return postgres({
      host: database.host,
      port: database.port,
      database: database.database,
      username: database.username,
      password: databricksDatabasePassword(database, database.endpoint),
      ssl: database.sslMode,
      max,
    });
  }
  if (!config.authDatabaseUrl) throw new Error("DATABASE_URL is required for PostgreSQL storage");
  return postgres(config.authDatabaseUrl, { max });
}

export function connectAuthDatabase(config: AppConfig) {
  const client = databaseClient(config, 5);
  return {
    db: drizzle(client, { schema: authSchema }),
    close: async () => client.end(),
  };
}

export async function migrateAuthDatabase(config: AppConfig): Promise<void> {
  const client = databaseClient(config, 1);
  const database = drizzle(client, { schema: authSchema });
  const lockId = 0x4441484c4941;
  let locked = false;
  try {
    await client`SELECT pg_advisory_lock(${lockId})`;
    locked = true;
    await migrate(database, { migrationsFolder: "./drizzle" });
  } finally {
    if (locked) await client`SELECT pg_advisory_unlock(${lockId})`;
    await client.end();
  }
}

export function databricksDatabasePassword(
  credentials: Pick<DatabricksDatabaseConfig, "workspaceUrl" | "clientId" | "clientSecret">,
  endpointName: string,
  transport: typeof fetch = fetch,
): () => Promise<string> {
  let cached: { token: string; expiresAt: number } | undefined;
  let pending: Promise<{ token: string; expiresAt: number }> | undefined;
  return async () => {
    if (cached && cached.expiresAt > Date.now() + 60_000) return cached.token;
    pending ??= fetchDatabricksDatabaseCredential(credentials, endpointName, transport).finally(() => {
      pending = undefined;
    });
    cached = await pending;
    return cached.token;
  };
}

async function fetchDatabricksDatabaseCredential(
  credentials: Pick<DatabricksDatabaseConfig, "workspaceUrl" | "clientId" | "clientSecret">,
  endpointName: string,
  transport: typeof fetch,
): Promise<{ token: string; expiresAt: number }> {
  const oauth = await transport(new URL("oidc/v1/token", `${credentials.workspaceUrl}/`), {
    method: "POST",
    headers: {
      authorization: `Basic ${btoa(`${credentials.clientId}:${credentials.clientSecret}`)}`,
      "content-type": "application/x-www-form-urlencoded",
    },
    body: new URLSearchParams({ grant_type: "client_credentials", scope: "all-apis" }),
  });
  if (!oauth.ok) throw new Error("Databricks service-principal authentication failed");
  const oauthBody: { access_token?: string } = await oauth.json();
  if (!oauthBody.access_token) throw new Error("Databricks service-principal response is invalid");

  const credential = await transport(new URL("api/2.0/postgres/credentials", `${credentials.workspaceUrl}/`), {
    method: "POST",
    headers: {
      authorization: `Bearer ${oauthBody.access_token}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({ endpoint: endpointName }),
  });
  if (!credential.ok) throw new Error("Databricks Lakebase credential generation failed");
  const body: { token?: string; expire_time?: string } = await credential.json();
  const expiresAt = Date.parse(body.expire_time ?? "");
  if (!body.token || !Number.isFinite(expiresAt)) throw new Error("Databricks Lakebase credential response is invalid");
  return { token: body.token, expiresAt };
}
