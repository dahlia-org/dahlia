import { readFileSync } from "node:fs";

const template = readFileSync(new URL("./oauth-callback.html", import.meta.url), "utf8");

export function oauthCallbackPage(succeeded: boolean, acceptLanguage = "en"): string {
  const japanese = acceptLanguage.split(",")[0].trim().toLowerCase().startsWith("ja");
  const title = japanese
    ? (succeeded ? "認証情報を受け取りました" : "認証できませんでした")
    : (succeeded ? "Authorization received" : "Authorization unsuccessful");
  const message = japanese
    ? (succeeded
      ? "Dahlia に戻って続けてください。このタブは閉じてもかまいません。"
      : "Dahlia で詳細を確認し、もう一度お試しください。このタブは閉じてもかまいません。")
    : (succeeded
      ? "Return to Dahlia to continue. You can close this tab."
      : "Return to Dahlia for details and try again. You can close this tab.");
  return template.replaceAll("{{language}}", japanese ? "ja" : "en")
    .replaceAll("{{state}}", succeeded ? "success" : "failure")
    .replaceAll("{{title}}", title)
    .replaceAll("{{message}}", message);
}
