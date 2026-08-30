export const MODEL_READ_SCOPE = "api.model.read";
export const MODEL_REQUEST_SCOPE = "api.model.request";
export const ARTIFACT_READ_SCOPE = "api.artifact.read";
export const ARTIFACT_WRITE_SCOPE = "api.artifact.write";
export const GATEWAY_SCOPES = [
  MODEL_READ_SCOPE,
  MODEL_REQUEST_SCOPE,
  ARTIFACT_READ_SCOPE,
  ARTIFACT_WRITE_SCOPE,
] as const;
export type GatewayScope = typeof GATEWAY_SCOPES[number];

export const OAUTH_SCOPES = ["openid", "profile", "email", "offline_access", ...GATEWAY_SCOPES];
export const MCP_OAUTH_SCOPES = ["openid", "profile", "email", "offline_access", ARTIFACT_WRITE_SCOPE];
