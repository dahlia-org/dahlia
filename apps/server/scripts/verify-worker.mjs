import assert from 'node:assert/strict';
import { createRequire, builtinModules } from 'node:module';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
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
  const bundle = await build({ entryPoints: ['tests/fixtures/worker-runtime.ts'], bundle: true, format: 'esm', platform: 'node',
    target: 'es2022', external: ['node:*', 'cloudflare:*'], conditions: ['workerd', 'worker', 'browser'],
    alias: Object.fromEntries(builtinModules.filter((name) => !name.startsWith('node:')).map((name) => [name, `node:${name}`])),
    banner: { js: 'import { createRequire } from "node:module"; const require = createRequire("/worker.js");' },
    write: false, metafile: true, minify: true });
  assert(!Object.keys(bundle.metafile.inputs).some((file) => /sharp|storage\/local|node-worker|node-indexer/.test(file)), 'Node-only modules leaked into workerd');
  const script = bundle.outputFiles[0].text;
  const started = performance.now();
  mf = new Miniflare({ modules: true, script, compatibilityDate: '2026-08-08', compatibilityFlags: ['nodejs_compat'],
    port: 0, persist: directory, r2Buckets: ['DAHLIA_STORAGE'], images: { binding: 'IMAGES' },
    queueProducers: { DAHLIA_SUMMARY_QUEUE: 'summary' }, queueConsumers: { summary: { maxBatchSize: 1, maxRetries: 0 } },
    bindings: { DAHLIA_AUTH_TYPE: 'header', DAHLIA_DATABASE_TYPE: 'postgres', DAHLIA_DATABASE_URL: databaseUrl,
      DAHLIA_STORAGE_BACKEND: 'r2', DAHLIA_AI_BACKEND: 'cloudflare',
      OPENAI_BASE_URL: 'https://api.cloudflare.com/client/v4/accounts/synthetic/ai/v1', OPENAI_API_KEY: 'synthetic' } });
  await mf.ready;
  const startupMs = Math.round(performance.now() - started);
  const first = await (await mf.dispatchFetch('http://local/runtime/database')).json();
  const second = await (await mf.dispatchFetch('http://local/runtime/database')).json();
  assert(first.pid && second.pid && first.pid !== second.pid, 'events must create independent connections');
  for (let i = 0; i < 2; i++) {
    const response = await mf.dispatchFetch('http://local/api/not-defined');
    assert.equal(response.status, 404); await response.text();
  }
  assert.equal(await (await mf.dispatchFetch('http://local/runtime/audio')).text(), 'AQIDBAU=');
  for (const backend of ['cloudflare', 'databricks']) {
    const result = await (await mf.dispatchFetch(`http://local/runtime/provider?backend=${backend}`)).json();
    assert.deepEqual(result, { caption: { ocr_text: 'Test', caption: 'A synthetic slide' }, dimensions: 1024 });
  }
  const bindings = await mf.getBindings();
  await bindings.DAHLIA_STORAGE.put('image', await sharp({ create: { width: 640, height: 360, channels: 3, background: '#4488aa' } }).png().toBuffer());
  const transformed = await mf.dispatchFetch('http://local/runtime/image');
  assert.equal(transformed.status, 200, await transformed.clone().text());
  assert.equal(Buffer.from(await transformed.arrayBuffer()).subarray(8, 12).toString(), 'WEBP');
  await bindings.DAHLIA_SUMMARY_QUEUE.send({ action: 'run', kind: 'summary', reference: { id: '019a0000-0000-7000-8000-000000000001', ownerUserId: 'synthetic-nonexistent' } });
  let completed;
  const deadline = Date.now() + 10_000;
  while (!completed && Date.now() < deadline) {
    completed = await bindings.DAHLIA_STORAGE.get('queue-completed');
    if (!completed) await new Promise((resolve) => setTimeout(resolve, 50));
  }
  assert(completed, 'native Queue consumer did not complete');
  assert.equal(await completed.text(), 'ok');
  console.log(JSON.stringify({ runtime: 'workerd', checks: ['postgres-event-isolation', 'fetch-lifecycle', 'R2-audio-stream', 'Images-WebP', 'queue-handler', 'Cloudflare-and-Databricks-adapters'], bundleBytes: Buffer.byteLength(script), gzipBytes: gzipSync(script).length, startupMs }));
} finally { await mf?.dispose(); await rm(directory, { recursive: true, force: true }); }
