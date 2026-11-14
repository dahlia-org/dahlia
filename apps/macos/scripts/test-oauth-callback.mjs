import assert from "node:assert/strict";
import { test } from "node:test";
import { readFileSync } from "node:fs";
import { oauthCallbackPage } from "../Sources/Dahlia/PiExtension/oauth-callback.ts";

for (const language of ["en-US,en;q=0.9", "ja-JP,ja;q=0.9"]) {
  for (const succeeded of [true, false]) {
    test(`callback page: ${language}, ${succeeded ? "success" : "failure"}`, () => {
      const html = oauthCallbackPage(succeeded, language);
      const locale = language.startsWith("ja") ? "ja" : "en";
      const strings = readFileSync(new URL(`../Sources/Dahlia/Resources/${locale}.lproj/Localizable.strings`, import.meta.url), "utf8");
      // Both runtimes must use the same translated messages and the same self-contained template.
      for (const key of succeeded ? ["received", "continue"] : ["failed", "retry"]) {
        const value = strings.match(new RegExp(`"oauth.callback.${key}" = "([^"]+)";`))?.[1];
        assert.ok(value);
        assert.ok(html.includes(value));
      }
      assert.ok(html.includes(`<html lang="${locale}">`));
      assert.ok(html.includes(`data-state="${succeeded ? "success" : "failure"}"`));
      assert.ok(html.includes("data:image/png;base64,"));
      assert.ok(!html.includes("{{"));
      assert.ok(!html.includes("<script"));
      assert.ok(!html.includes("https://"));
    });
  }
}
