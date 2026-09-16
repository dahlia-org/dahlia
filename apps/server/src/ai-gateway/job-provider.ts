import type { AppConfig } from "../config";
import { DatabricksTokenProvider } from "../databricks/token";
import { CloudflareBackend, cloudflareHeaders, cloudflareModel } from "./cloudflare";
import { DatabricksBackend } from "./databricks";
import { CODEX_AUTO_REVIEW_ALIAS } from "./model-alias";

// Runtime-independent, server-credential execution. Request-scoped OBO belongs to the HTTP relay only.
export function createJobProvider(config: AppConfig, transport: typeof fetch = fetch) {
  const provider = config.provider;
  if (provider?.backend === "databricks" && config.databricksWorkspace) {
    const tokens = new DatabricksTokenProvider(config.databricksWorkspace, transport);
    return {
      provider,
      backend: new DatabricksBackend(provider, config.codexModels ?? [], transport),
      normalizeModel: (model: string) => model,
      resolveModel: (model: string) => model === CODEX_AUTO_REVIEW_ALIAS
        ? config.codexAutoReviewModel?.trim() ?? model
        : model,
      async headers(this: void, ownerUserId?: string): Promise<Record<string, string>> {
        return { authorization: `Bearer ${await tokens.getToken()}`,
          ...(ownerUserId ? { "Databricks-Ai-Gateway-Request-Tags": JSON.stringify({ user_id: ownerUserId }) } : {}) };
      },
    };
  }
  if (provider?.backend === "cloudflare") {
    return {
      provider,
      backend: new CloudflareBackend(provider, transport, config.codexModels ?? []),
      normalizeModel: (model: string) => model.replace(/^(openai|google)\//, ""),
      resolveModel: cloudflareModel,
      headers: (): Promise<Record<string, string>> => Promise.resolve({
        authorization: `Bearer ${provider.apiKey}`, ...cloudflareHeaders(provider),
      }),
    };
  }
  return undefined;
}
