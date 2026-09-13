import type { DatabricksWorkspaceConfig } from "../config";
import { validateAuthSecret } from "../auth/secret";
import { DatabricksTokenProvider } from "./token";

export async function readDatabricksAuthSecret(
  workspace: DatabricksWorkspaceConfig,
  fullName: string,
  transport: typeof fetch = fetch,
): Promise<string> {
  const token = await new DatabricksTokenProvider(workspace, transport).getToken();
  let response: Response;
  try {
    response = await transport(`${workspace.host}/api/2.1/unity-catalog/secrets/${encodeURIComponent(fullName)}?include_value=true`, {
      headers: { authorization: `Bearer ${token}` },
      redirect: "error",
      signal: AbortSignal.timeout(30_000),
    });
  } catch {
    throw new Error("Databricks authentication secret retrieval failed");
  }
  if (!response.ok) throw new Error(`Databricks authentication secret retrieval failed (${response.status})`);
  const body: unknown = await response.json().catch(() => undefined);
  if (!body || typeof body !== "object" || !("effective_value" in body) || typeof body.effective_value !== "string") {
    throw new Error("Databricks authentication secret response is invalid");
  }
  return validateAuthSecret(body.effective_value);
}
