import assert from 'node:assert/strict';
import { Client } from 'pg';
import { createRequire, builtinModules } from 'node:module';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { gzipSync } from 'node:zlib';

// Use Wrangler's installed runtime/build dependencies; no additional package or remote resources.
const require = createRequire(import.meta.resolve('wrangler'));
const { Miniflare } = require('miniflare');
const sharp = createRequire(require.resolve('miniflare'))('sharp');
const { build } = require('esbuild');
const databaseUrl = process.env.TEST_DATABASE_URL;
assert(databaseUrl, 'TEST_DATABASE_URL must point to a migrated, disposable PostgreSQL database');
const directory = await mkdtemp(join(tmpdir(), 'dahlia-workerd-'));
let mf;
try {
  const wasmModules = [];
  const bundle = await build({ entryPoints: ['tests/fixtures/worker-runtime.ts'], bundle: true, format: 'esm', platform: 'node',
    target: 'es2022', external: ['node:*', 'cloudflare:*'], conditions: ['workerd', 'worker', 'browser'],
    alias: Object.fromEntries(builtinModules.filter((name) => !name.startsWith('node:')).map((name) => [name, `node:${name}`])),
    banner: { js: 'import { createRequire } from "node:module"; const require = createRequire("/worker.js");' },
    plugins: [{ name: 'workerd-wasm', setup(build) {
      build.onResolve({ filter: /\.wasm$/ }, async (args) => {
        const path = `./wasm-${wasmModules.length}.wasm`;
        wasmModules.push({ type: 'CompiledWasm', path: join(directory, path), contents: await readFile(resolve(args.resolveDir, args.path)) });
        return { path, external: true };
      });
    } }],
    write: false, metafile: true, minify: true });
  assert(!Object.keys(bundle.metafile.inputs).some((file) => /sharp|storage\/local|node-worker|node-indexer/.test(file)), 'Node-only modules leaked into workerd');
  const script = bundle.outputFiles[0].text;
  const started = performance.now();
  mf = new Miniflare({ modules: [{ type: 'ESModule', path: join(directory, 'worker.js'), contents: script }, ...wasmModules], modulesRoot: directory, compatibilityDate: '2026-08-08', compatibilityFlags: ['nodejs_compat'],
    port: 0, persist: directory, r2Buckets: ['DAHLIA_STORAGE'], images: { binding: 'IMAGES' },
    queueProducers: { DAHLIA_SUMMARY_QUEUE: 'summary' }, queueConsumers: { summary: { maxBatchSize: 1, maxRetries: 0 } },
    bindings: { DAHLIA_APP_URL: 'http://localhost:5173', DAHLIA_AUTH_HEADER: 'Cf-Access-Authenticated-User-Email', DAHLIA_AUTH_TYPE: 'header', DAHLIA_AUTH_SECRET: 'test-worker-secret-at-least-32-characters', DAHLIA_DATABASE_TYPE: 'postgres', DAHLIA_DATABASE_URL: databaseUrl,
      DAHLIA_STORAGE_BACKEND: 'r2', DAHLIA_AI_BACKEND: 'cloudflare',
      OPENAI_BASE_URL: 'https://api.cloudflare.com/client/v4/accounts/synthetic/ai/v1', OPENAI_API_KEY: 'synthetic' } });
  await mf.ready;
  const startupMs = Math.round(performance.now() - started);
  const first = await (await mf.dispatchFetch('http://localhost:5173/runtime/database')).json();
  const second = await (await mf.dispatchFetch('http://localhost:5173/runtime/database')).json();
  assert(first.pid && second.pid && first.pid !== second.pid, 'events must create independent connections');
  for (let i = 0; i < 2; i++) {
    const response = await mf.dispatchFetch('http://localhost:5173/api/not-defined');
    assert.equal(response.status, 404, await response.clone().text()); await response.text();
  }
  const email = `worker@initial-${crypto.randomUUID()}.example.com`;
  const identityHeaders = { 'Cf-Access-Authenticated-User-Email': ` ${email.toUpperCase()} `, 'X-Forwarded-User': 'ignored', origin: 'http://localhost:5173' };
  const identityResponse = await mf.dispatchFetch('http://localhost:5173/api/v1/session', { headers: identityHeaders });
  assert.equal(identityResponse.status, 200, await identityResponse.clone().text());
  const identity = await identityResponse.json();
  for (const knownLength of [true, false]) {
    const body = JSON.stringify({ name: 'x'.repeat(64 * 1024), slug: 'oversized' });
    const response = await mf.dispatchFetch('http://localhost:5173/api/v1/organizations', {
      method: 'POST', headers: { ...identityHeaders, 'content-type': 'application/json',
        ...(knownLength ? { 'content-length': String(body.length) } : {}) }, body,
    });
    assert.equal(response.status, 413, await response.clone().text());
    assert.equal((await response.json()).code, 'request_too_large');
  }
  const signIn = await mf.dispatchFetch('http://localhost:5173/api/auth/header/sign-in', { method: 'POST', headers: { ...identityHeaders, 'X-Forwarded-User': 'different', 'content-type': 'application/json' }, body: '{}' });
  assert.equal(signIn.status, 200, await signIn.clone().text());
  const session = await signIn.json();
  assert.equal(session.user.email, identity.user.email);
  const cookie = signIn.headers.getSetCookie().map((value) => value.split(';')[0]).join('; ');
  const resumed = await mf.dispatchFetch('http://localhost:5173/api/v1/session', { headers: { ...identityHeaders, cookie } });
  assert.equal(resumed.status, 200, await resumed.clone().text());
  assert.equal((await resumed.json()).user.id, identity.user.id);
  const rejected = await mf.dispatchFetch('http://localhost:5173/api/v1/session', { headers: { 'X-Forwarded-Email': email } });
  assert.equal(rejected.status, 401);
  await rejected.text();
  const database = new Client({ connectionString: databaseUrl });
  await database.connect();
  try {
    const accounts = await database.query('SELECT account_id, user_id FROM auth.account WHERE account_id = $1', [email]);
    assert.deepEqual(accounts.rows, [{ account_id: email, user_id: session.user.id }]);
    const membership = await database.query(`SELECT organization_id FROM auth.member WHERE user_id = $1`, [session.user.id]);
    assert.deepEqual(membership.rows, [], 'default signup must not create an Organization');
    await database.query("UPDATE auth.user SET role = 'admin' WHERE id = $1", [session.user.id]);
    const organizationResponse = await mf.dispatchFetch('http://localhost:5173/api/v1/organizations', {
      method: 'POST', headers: { ...identityHeaders, cookie, 'content-type': 'application/json' },
      body: JSON.stringify({ name: 'Worker team', slug: `worker-${crypto.randomUUID()}`, initialOwnerUserId: identity.user.id }),
    });
    assert.equal(organizationResponse.status, 201, await organizationResponse.clone().text());
    const organization = await organizationResponse.json();
    const workspaceResponse = await mf.dispatchFetch(`http://localhost:5173/api/v1/workspaces?organizationId=${organization.id}`, { headers: { ...identityHeaders, cookie } });
    assert.equal(workspaceResponse.status, 200, await workspaceResponse.clone().text());
    const privateWorkspaces = (await workspaceResponse.json()).items;
    assert.equal(privateWorkspaces.length, 1, 'initial membership must provision a private Workspace');
    assert.equal(privateWorkspaces[0].personalUserId, identity.user.id);
    const settingsUrl = `http://localhost:5173/api/v1/organizations/${organization.id}/domains`;
    const save = (domains) => mf.dispatchFetch(settingsUrl, { method: 'PUT',
      headers: { ...identityHeaders, cookie, 'content-type': 'application/json' }, body: JSON.stringify({ domains: domains.map((domain) => ({ domain, joinPolicy: 'auto_join' })) }) });
    for (const [domain, code] of [['gmail.com', 'shared_email_domain'], ['https://example.com', 'invalid_organization_domain']]) {
      const deniedDomain = await save([domain]);
      assert.equal(deniedDomain.status, 400, await deniedDomain.clone().text());
      assert.equal((await deniedDomain.json()).code, code);
    }
    const domain = `${crypto.randomUUID()}.example.com`;
    const saved = await save([domain]);
    assert.equal(saved.status, 200, await saved.clone().text());
    assert.deepEqual(await saved.json(), { domains: [{ domain, joinPolicy: 'auto_join' }] });
    const settings = await mf.dispatchFetch(settingsUrl, { headers: { ...identityHeaders, cookie } });
    assert.equal(settings.status, 200, await settings.clone().text());
    assert.deepEqual(await settings.json(), { domains: [{ domain, joinPolicy: 'auto_join' }] });
    await database.query("UPDATE auth.user SET role = 'admin' WHERE id = $1", [session.user.id]);
    const createdEmail = `provisioned-${crypto.randomUUID()}@${domain}`;
    const createdResponse = await mf.dispatchFetch('http://localhost:5173/api/auth/admin/create-user', {
      method: 'POST', headers: { ...identityHeaders, cookie, 'content-type': 'application/json' },
      body: JSON.stringify({ email: createdEmail, name: 'Provisioned' }),
    });
    assert.equal(createdResponse.status, 200, await createdResponse.clone().text());
    const created = await createdResponse.json();
    const emailEdit = await mf.dispatchFetch('http://localhost:5173/api/auth/admin/update-user', {
      method: 'POST', headers: { ...identityHeaders, cookie, 'content-type': 'application/json' },
      body: JSON.stringify({ userId: created.user.id, data: { email: `changed-${createdEmail}` } }),
    });
    assert.equal(emailEdit.status, 403, await emailEdit.clone().text());
    await emailEdit.text();
    const provisioned = await mf.dispatchFetch('http://localhost:5173/api/v1/session', {
      headers: { 'Cf-Access-Authenticated-User-Email': createdEmail },
    });
    assert.equal(provisioned.status, 200, await provisioned.clone().text());
    assert.equal((await provisioned.json()).user.id, created.user.id);
    const enrolled = await database.query(`SELECT m.role FROM auth.member m JOIN app.organization_domains d ON d.organization_id = m.organization_id
      JOIN auth.account a ON a.user_id = m.user_id WHERE a.account_id = $1 AND d.domain = $2`, [createdEmail, domain]);
    assert.deepEqual(enrolled.rows, [{ role: 'member' }]);
  } finally { await database.end(); }
  const participation = await mf.dispatchFetch('http://localhost:5173/runtime/organization-participation');
  assert.equal(participation.status, 200, await participation.clone().text());
  assert.deepEqual(await participation.json(), { passed: true });
  assert.equal(await (await mf.dispatchFetch('http://localhost:5173/runtime/audio')).text(), 'AQIDBAU=');
  for (const backend of ['cloudflare', 'databricks']) {
    const result = await (await mf.dispatchFetch(`http://localhost:5173/runtime/provider?backend=${backend}`)).json();
    assert.deepEqual(result, { caption: { ocr_text: 'Test', caption: 'A synthetic slide' }, dimensions: 1024 });
  }
  const bindings = await mf.getBindings();
  await bindings.DAHLIA_STORAGE.put('image', await sharp({ create: { width: 640, height: 360, channels: 3, background: '#4488aa' } }).png().toBuffer());
  const transformed = await mf.dispatchFetch('http://localhost:5173/runtime/image');
  assert.equal(transformed.status, 200, await transformed.clone().text());
  assert.equal(Buffer.from(await transformed.arrayBuffer()).subarray(8, 12).toString(), 'WEBP');
  await bindings.DAHLIA_SUMMARY_QUEUE.send({ action: 'run', kind: 'summary', reference: { id: '019a0000-0000-7000-8000-000000000001', ownerUserId: '019a0000-0000-7000-8000-000000000002' } });
  let completed;
  const deadline = Date.now() + 10_000;
  while (!completed && Date.now() < deadline) {
    completed = await bindings.DAHLIA_STORAGE.get('queue-completed');
    if (!completed) await new Promise((resolve) => setTimeout(resolve, 50));
  }
  assert(completed, 'native Queue consumer did not complete');
  assert.equal(await completed.text(), 'ok');
  console.log(JSON.stringify({ runtime: 'workerd', checks: ['configured-email-identity-and-domain-enrollment', 'native-header-user-provisioning', 'verified-google-organization-policies', 'organization-request-and-lifecycle-authorization', 'postgres-event-isolation', 'fetch-lifecycle', 'R2-audio-stream', 'Images-WebP', 'queue-handler', 'Cloudflare-and-Databricks-adapters'], bundleBytes: Buffer.byteLength(script), gzipBytes: gzipSync(script).length, startupMs }));
} finally { await mf?.dispose(); await rm(directory, { recursive: true, force: true }); }
