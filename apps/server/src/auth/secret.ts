export function validateAuthSecret(secret: string): string {
  const value = secret.trim();
  if (value.length < 32 || value === "replace-with-at-least-32-random-characters") {
    throw new Error("Authentication secret must be a unique random value of at least 32 characters");
  }
  return secret;
}

export async function resolveAuthSecret(configured?: string): Promise<string> {
  if (configured) return validateAuthSecret(configured);
  const { readFileSync, writeFileSync } = await import("node:fs");
  const path = `${process.cwd()}/dahlia-auth-secret`;
  try {
    return validateAuthSecret(readFileSync(path, "utf8"));
  } catch (error) {
    if ((error as { code?: string }).code !== "ENOENT") throw error;
  }
  const secret = Array.from(crypto.getRandomValues(new Uint8Array(32)), (byte) => byte.toString(16).padStart(2, "0")).join("");
  try {
    writeFileSync(path, secret, { flag: "wx", mode: 0o600 });
  } catch (error) {
    if ((error as { code?: string }).code !== "EEXIST") throw error;
    return validateAuthSecret(readFileSync(path, "utf8"));
  }
  return secret;
}
