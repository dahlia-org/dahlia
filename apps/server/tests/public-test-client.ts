import { Client } from "pg";
import { createHash } from "node:crypto";
import { DatabaseSync } from "node:sqlite";
import { createApp as createPublicApp } from "../src/app";
import { publicRoute, wireURL, wireValue } from "../src/public-wire";
import { uuidV7 } from "../src/id";
import type { Identity } from "../src/auth/identity";
import type { AuthStore } from "../src/auth/store";

export const testOrganizationID = "01990ab0-0000-7000-8000-000000000001";

export function testUserID(subject: string): string {
  return /^[0-9a-f-]{36}$/i.test(subject) ? subject : `01990ab0-0000-7000-8000-${createHash("sha256").update(subject).digest("hex").slice(0, 12)}`;
}

/** Seed the same external-account link as header auth, with stable IDs for domain fixtures. */
export async function seedHeaderIdentity(store: AuthStore, path: string, identity: Identity): Promise<void> {
  const database = new DatabaseSync(path);
  database.prepare("INSERT OR IGNORE INTO user (id, name, email, email_verified, registration_state, created_at, updated_at) VALUES (?, ?, ?, 1, 'personal', ?, ?)")
    .run(identity.userId, identity.name ?? identity.email ?? identity.userId, identity.email ?? `${identity.userId}@example.com`, Date.now(), Date.now());
  await store.ensureIdentityUser(identity);
  database.prepare("INSERT OR IGNORE INTO organization (id, name, slug, kind, created_at) VALUES (?, 'Test organization', 'test-organization', 'team', ?)").run(testOrganizationID, Date.now());
  database.prepare("INSERT OR IGNORE INTO member (id, organization_id, user_id, role, created_at) VALUES (?, ?, ?, CASE WHEN EXISTS (SELECT 1 FROM member WHERE organization_id = ?) THEN 'member' ELSE 'owner' END, ?)").run(uuidV7(), testOrganizationID, identity.userId, testOrganizationID, Date.now());
  database.prepare("INSERT OR IGNORE INTO account (id, account_id, provider_id, issuer, user_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)")
    .run(uuidV7(), identity.email ?? `${identity.userId}@example.com`, "external", "urn:dahlia:header", identity.userId, Date.now(), Date.now());
  database.close();
}

/** Existing PostgreSQL domain scenarios retain stable user IDs through the real initializer. */
export async function seedPostgresIdentity(store: AuthStore, databaseUrl: string, identity: Identity): Promise<void> {
  const client = new Client({ connectionString: databaseUrl });
  await client.connect();
  try {
    await client.query(`INSERT INTO auth."user" (id, name, email, email_verified, registration_state, created_at, updated_at)
      VALUES ($1, $2, $3, true, 'personal', now(), now()) ON CONFLICT DO NOTHING`,
    [identity.userId, identity.name ?? identity.userId, identity.email ?? `${identity.userId}@example.com`]);
    await store.ensureIdentityUser(identity);
    await client.query("INSERT INTO auth.organization (id, name, slug, kind, created_at) VALUES ($1, 'Test organization', 'test-organization', 'team', now()) ON CONFLICT DO NOTHING", [testOrganizationID]);
    await client.query("INSERT INTO auth.member (id, organization_id, user_id, role, created_at) VALUES ($1, $2, $3, CASE WHEN EXISTS (SELECT 1 FROM auth.member WHERE organization_id = $2) THEN 'member' ELSE 'owner' END, now()) ON CONFLICT DO NOTHING", [uuidV7(), testOrganizationID, identity.userId]);
  } finally { await client.end(); }
}

/** Existing domain scenarios use UUID fixtures; every request still crosses the real public adapter. */
export function createApp(...parameters: Parameters<typeof createPublicApp>): ReturnType<typeof createPublicApp> {
  const app = createPublicApp(...parameters);
  const dispatch = app.fetch;
  app.fetch = async (request, env, context) => {
    const route = publicRoute(new URL(request.url).pathname, request.method);
    let url = request.url;
    try { url = wireURL(url, "encode", request.method); } catch { /* Invalid-input scenarios go to the public validator. */ }
    const headers = new Headers(request.headers);
    for (const [key, shape] of Object.entries(route?.headers ?? {})) {
      const value = headers.get(key);
      if (value !== null) { try { headers.set(key, String(wireValue(value, shape, "encode"))); } catch { /* Invalid input. */ } }
    }
    let responseShape = route?.response;
    let body: BodyInit | null = request.body;
    if (body && route?.request) {
      body = await request.text();
      try {
        const value: unknown = JSON.parse(body);
        body = JSON.stringify(wireValue(value, route.request, "encode"));
        if (responseShape === "textSearch" && typeof value === "object" && value !== null && "kind" in value && value.kind === "screenshot") {
          responseShape = "textScreenshotSearch";
        }
      } catch { /* Invalid JSON/ID scenarios. */ }
    }
    const response = await dispatch(new Request(url, { method: request.method, headers, body,
      ...(body instanceof ReadableStream ? { duplex: "half" } : {}) }), env, context);
    const responseHeaders = new Headers(response.headers);
    const location = responseHeaders.get("location");
    if (location) responseHeaders.set("location", wireURL(location, "decode"));
    const shape = response.ok ? responseShape : route ? "error" : undefined;
    if (request.method === "HEAD" || !shape || !response.headers.get("content-type")?.includes("json")) return new Response(response.body, { status: response.status, headers: responseHeaders });
    const value: unknown = await response.json();
    const output = wireValue(value, shape, "decode");
    return new Response(JSON.stringify(output), { status: response.status, headers: responseHeaders });
  };
  return app;
}
