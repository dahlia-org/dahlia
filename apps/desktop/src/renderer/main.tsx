import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "@dahlia-ai/ui";
import "@dahlia-ai/ui/styles.css";

declare global {
  interface Window {
    dahliaDesktop: { config(): Promise<{ serverOrigin: string }>; signIn(next: string): Promise<boolean> };
  }
}

const ja = navigator.language.startsWith("ja");
document.documentElement.lang = ja ? "ja" : "en";
const { serverOrigin } = await window.dahliaDesktop.config();

// API requests stay same-origin (app://dahlia/api) and the main process relays them to the Server.
// Desktop AI runs on the device; the alpha does not substitute Server AI jobs for it.
async function signIn(next: string) {
  if (await window.dahliaDesktop.signIn(next)) {
    window.location.replace(next);
    return undefined;
  }
  return ja ? "サインインは完了しませんでした。" : "Sign-in was not completed.";
}

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App brand={{ name: "Dahlia", product: "Alpha" }} publicOrigin={serverOrigin} signIn={signIn} signOutPath="/sign-in" serverAI={false} />
  </StrictMode>,
);
