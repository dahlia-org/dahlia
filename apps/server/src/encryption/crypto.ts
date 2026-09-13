export interface EncryptionConfig {
  masterKeys: ReadonlyMap<string, Uint8Array<ArrayBuffer>>;
  activeKeyId: string;
}

export class EncryptionError extends Error {
  constructor() {
    super("workspace_encryption_unavailable");
  }
}

export function encodeBase64(bytes: Uint8Array): string {
  let value = "";
  for (let i = 0; i < bytes.length; i += 8192) value += String.fromCharCode(...bytes.subarray(i, i + 8192));
  return btoa(value);
}

function decodeBase64(value: string): Uint8Array<ArrayBuffer> {
  const bytes = Uint8Array.from(atob(value), (character) => character.charCodeAt(0));
  if (encodeBase64(bytes) !== value) throw new EncryptionError();
  return bytes;
}

export function encryptionConfig(env: Record<string, string | undefined>): EncryptionConfig | undefined {
  const masterKeys = new Map<string, Uint8Array<ArrayBuffer>>();
  for (const [name, value] of Object.entries(env)) {
    if (!name.startsWith("DAHLIA_ENCRYPTION_MASTER_KEY_")) continue;
    const id = /^DAHLIA_ENCRYPTION_MASTER_KEY_([1-9][0-9]*)$/.exec(name)?.[1];
    if (!id) throw new Error("Invalid encryption master key variable name");
    try {
      const key = decodeBase64(value?.trim() ?? "");
      if (key.length !== 32) throw new EncryptionError();
      masterKeys.set(id, key);
    } catch {
      throw new Error("Encryption master keys must be Base64-encoded 32-byte keys");
    }
  }
  const activeKeyId = env.DAHLIA_ENCRYPTION_ACTIVE_KEY_ID?.trim();
  if (!masterKeys.size && !activeKeyId) return undefined;
  if (!activeKeyId || !masterKeys.has(activeKeyId)) throw new Error("DAHLIA_ENCRYPTION_ACTIVE_KEY_ID must identify a configured key");
  return { masterKeys, activeKeyId };
}

const encoder = new TextEncoder();
interface Envelope { v: 1; keyId: string; nonce: string; ciphertext: string }

async function seal(key: CryptoKey, keyId: string, context: readonly string[], bytes: Uint8Array<ArrayBuffer>): Promise<string> {
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const ciphertext = await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce,
    additionalData: encoder.encode(JSON.stringify([1, keyId, ...context])), tagLength: 128 }, key, bytes);
  return JSON.stringify({ v: 1, keyId, nonce: encodeBase64(nonce), ciphertext: encodeBase64(new Uint8Array(ciphertext)) } satisfies Envelope);
}

function envelope(value: string): Envelope {
  try {
    const parsed = JSON.parse(value) as Envelope;
    if (parsed.v !== 1 || typeof parsed.keyId !== "string" || typeof parsed.nonce !== "string" || typeof parsed.ciphertext !== "string") throw new EncryptionError();
    return parsed;
  } catch { throw new EncryptionError(); }
}

async function open(key: CryptoKey, keyId: string, context: readonly string[], value: string): Promise<Uint8Array<ArrayBuffer>> {
  try {
    const packet = envelope(value);
    const nonce = decodeBase64(packet.nonce);
    if (packet.keyId !== keyId || nonce.length !== 12) throw new EncryptionError();
    return new Uint8Array(await crypto.subtle.decrypt({ name: "AES-GCM", iv: nonce,
      additionalData: encoder.encode(JSON.stringify([1, keyId, ...context])), tagLength: 128 }, key, decodeBase64(packet.ciphertext)));
  } catch { throw new EncryptionError(); }
}

async function masterKey(config: EncryptionConfig | undefined, id: string): Promise<CryptoKey> {
  const key = config?.masterKeys.get(id);
  if (!key) throw new EncryptionError();
  return crypto.subtle.importKey("raw", key, "AES-GCM", false, ["encrypt", "decrypt"]);
}

export async function wrapDataKey(config: EncryptionConfig, workspaceId: string, raw: Uint8Array<ArrayBuffer>): Promise<string> {
  return seal(await masterKey(config, config.activeKeyId), config.activeKeyId, ["dahlia", workspaceId, "workspace_keys", "1"], raw);
}

export async function unwrapDataKey(config: EncryptionConfig | undefined, workspaceId: string, wrapped: string): Promise<Uint8Array<ArrayBuffer>> {
  const id = envelope(wrapped).keyId;
  const raw = await open(await masterKey(config, id), id, ["dahlia", workspaceId, "workspace_keys", "1"], wrapped);
  if (raw.length !== 32) throw new EncryptionError();
  return raw;
}

export async function createWorkspaceCipher(workspaceId: string, raw: Uint8Array<ArrayBuffer>) {
  const key = await crypto.subtle.importKey("raw", raw, "AES-GCM", false, ["encrypt", "decrypt"]);
  const source = await crypto.subtle.importKey("raw", raw, "HKDF", false, ["deriveKey"]);
  const hashKey = await crypto.subtle.deriveKey({ name: "HKDF", hash: "SHA-256", salt: encoder.encode(workspaceId),
    info: encoder.encode("dahlia-content-comparison-v1") }, source, { name: "HMAC", hash: "SHA-256", length: 256 }, false, ["sign"]);
  return {
    encrypt(table: string, id: string, field: string, value: unknown) {
      return seal(key, "1", ["dahlia", workspaceId, table, id, field], encoder.encode(JSON.stringify(value)));
    },
    async decrypt<T>(table: string, id: string, field: string, value: string): Promise<T> {
      const bytes = await open(key, "1", ["dahlia", workspaceId, table, id, field], value);
      try { return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes)) as T; }
      catch { throw new EncryptionError(); }
    },
    async hash(purpose: string, value: string): Promise<string> {
      const bytes = await crypto.subtle.sign("HMAC", hashKey, encoder.encode(JSON.stringify([purpose, value])));
      return encodeBase64(new Uint8Array(bytes));
    },
  };
}

export type WorkspaceCipher = Awaited<ReturnType<typeof createWorkspaceCipher>>;
