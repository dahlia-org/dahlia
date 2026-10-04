import { createAuthClient } from "better-auth/react";
import { finishBrowserDocuments } from "../screens/Documents";
import { json } from "./api";

export async function beginSignIn(callbackURL: string): Promise<string | undefined> {
  try {
    const authClient = createAuthClient({ baseURL: window.location.origin });
    const result = await authClient.signIn.social({ provider: "google", callbackURL });
    if (!result.error) return undefined;
    return result.error.message || "Sign in failed";
  } catch (caught) {
    return caught instanceof Error ? caught.message : "Sign in failed";
  }
}

export async function accountSignInRequired(signal?: AbortSignal): Promise<boolean> {
  const { provider } = await json<{ provider: "accounts" | "header" }>("/api/auth/mode", { signal });
  return provider === "accounts";
}

/** Sign-out waits for volatile Notes edits, then clears the Server session. */
export async function signOut() {
  await finishBrowserDocuments();
  await json("/api/auth/sign-out", { method: "POST", body: "{}" });
}
