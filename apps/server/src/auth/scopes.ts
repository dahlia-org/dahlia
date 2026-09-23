export const ALL_APIS_SCOPE = "all-apis";
export const MCP_SCOPE = "mcp";
export const MEMORY_READ_SCOPE = "mcp:memory:read";
export const MEMORY_WRITE_SCOPE = "mcp:memory:write";
export const MCP_READ_SCOPE = "mcp:read";
const IDENTITY_SCOPES = ["openid", "profile", "email", "offline_access"] as const;

export const GATEWAY_SCOPES = [ALL_APIS_SCOPE] as const;
export const MCP_CAPABILITY_SCOPES = [MCP_SCOPE, MCP_READ_SCOPE, MEMORY_READ_SCOPE, MEMORY_WRITE_SCOPE] as const;
export type ApiScope = typeof ALL_APIS_SCOPE | typeof MCP_CAPABILITY_SCOPES[number];

export const OAUTH_SCOPES = [...IDENTITY_SCOPES, ALL_APIS_SCOPE];
export const MCP_OAUTH_SCOPES = [...IDENTITY_SCOPES, ...MCP_CAPABILITY_SCOPES];
export const AUTHORIZATION_SERVER_SCOPES = [...OAUTH_SCOPES, ...MCP_CAPABILITY_SCOPES];

export function hasApiScope(grantedScopes: readonly string[], requiredScope: ApiScope): boolean {
  return grantedScopes.includes(requiredScope)
    || (requiredScope === MEMORY_READ_SCOPE && grantedScopes.includes(MEMORY_WRITE_SCOPE))
    || (requiredScope === MCP_READ_SCOPE && grantedScopes.includes(MCP_SCOPE));
}
