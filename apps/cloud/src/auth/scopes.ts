export const MODEL_READ_SCOPE = "api.model.read";
export const MODEL_REQUEST_SCOPE = "api.model.request";
export const GATEWAY_SCOPES = [MODEL_READ_SCOPE, MODEL_REQUEST_SCOPE] as const;
export type GatewayScope = typeof GATEWAY_SCOPES[number];

export const OAUTH_SCOPES = ["openid", "profile", "email", "offline_access", ...GATEWAY_SCOPES];
