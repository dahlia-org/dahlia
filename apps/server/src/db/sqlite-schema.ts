import { sql } from "drizzle-orm";
import { customType, sqliteTable, text, integer, index, uniqueIndex } from "drizzle-orm/sqlite-core";

const sqliteDate = customType<{ data: Date; driverData: string }>({
  dataType: () => "text",
  fromDriver: (value) => new Date(value),
  toDriver: (value) => value.toISOString(),
});

export const user = sqliteTable("user", {
					id: text('id').primaryKey(),
					name: text('name').notNull(),
 email: text('email').notNull().unique(),
 emailVerified: integer('emailVerified', { mode: 'boolean' }).default(false).notNull(),
 image: text('image'),
 createdAt: sqliteDate('createdAt').default(sql`CURRENT_TIMESTAMP`).notNull(),
 updatedAt: sqliteDate('updatedAt').default(sql`CURRENT_TIMESTAMP`).$onUpdate(() => /* @__PURE__ */ new Date()).notNull()
					});

export const session = sqliteTable("session", {
					id: text('id').primaryKey(),
					expiresAt: sqliteDate('expiresAt').notNull(),
 token: text('token').notNull().unique(),
 createdAt: sqliteDate('createdAt').default(sql`CURRENT_TIMESTAMP`).notNull(),
 updatedAt: sqliteDate('updatedAt').$onUpdate(() => /* @__PURE__ */ new Date()).notNull(),
 ipAddress: text('ipAddress'),
 userAgent: text('userAgent'),
 userId: text('userId').notNull().references(()=> user.id, { onDelete: 'cascade' })
					}, (table) => [
  index("session_userId_idx").on(table.userId),
]);

export const account = sqliteTable("account", {
					id: text('id').primaryKey(),
					issuer: text('issuer').notNull(),
 accountId: text('providerAccountId').notNull(),
 providerId: text('providerId').notNull(),
 userId: text('userId').notNull().references(()=> user.id, { onDelete: 'cascade' }),
 accessToken: text('accessToken'),
 refreshToken: text('refreshToken'),
 idToken: text('idToken'),
 accessTokenExpiresAt: sqliteDate('accessTokenExpiresAt'),
 refreshTokenExpiresAt: sqliteDate('refreshTokenExpiresAt'),
 scope: text('scope'),
 password: text('password'),
 createdAt: sqliteDate('createdAt').default(sql`CURRENT_TIMESTAMP`).notNull(),
 updatedAt: sqliteDate('updatedAt').$onUpdate(() => /* @__PURE__ */ new Date()).notNull()
					}, (table) => [
  uniqueIndex("account_issuer_providerAccountId_uidx").on(table.issuer, table.accountId),
  index("account_userId_idx").on(table.userId),
]);

export const verification = sqliteTable("verification", {
					id: text('id').primaryKey(),
					identifier: text('identifier').notNull(),
 value: text('value').notNull(),
 expiresAt: sqliteDate('expiresAt').notNull(),
 createdAt: sqliteDate('createdAt').default(sql`CURRENT_TIMESTAMP`).notNull(),
 updatedAt: sqliteDate('updatedAt').default(sql`CURRENT_TIMESTAMP`).$onUpdate(() => /* @__PURE__ */ new Date()).notNull()
					}, (table) => [
  index("verification_identifier_idx").on(table.identifier),
]);

export const jwks = sqliteTable("jwks", {
					id: text('id').primaryKey(),
					publicKey: text('publicKey').notNull(),
 privateKey: text('privateKey').notNull(),
 createdAt: sqliteDate('createdAt').notNull(),
 expiresAt: sqliteDate('expiresAt'),
 alg: text('alg'),
 crv: text('crv')
					});

export const oauthClient = sqliteTable("oauthClient", {
					id: text('id').primaryKey(),
					clientId: text('clientId').notNull().unique(),
 clientSecret: text('clientSecret'),
 clientDiscoveryId: text('clientDiscoveryId'),
 disabled: integer('disabled', { mode: 'boolean' }).default(false),
 skipConsent: integer('skipConsent', { mode: 'boolean' }),
 enableEndSession: integer('enableEndSession', { mode: 'boolean' }),
 subjectType: text('subjectType'),
 scopes: text('scopes', { mode: "json" }),
 clientCredentialsScopes: text('clientCredentialsScopes', { mode: "json" }).default([]),
 userId: text('userId').references(()=> user.id, { onDelete: 'cascade' }),
 createdAt: sqliteDate('createdAt'),
 updatedAt: sqliteDate('updatedAt'),
 name: text('name'),
 uri: text('uri'),
 icon: text('icon'),
 contacts: text('contacts', { mode: "json" }),
 tos: text('tos'),
 policy: text('policy'),
 softwareId: text('softwareId'),
 softwareVersion: text('softwareVersion'),
 softwareStatement: text('softwareStatement'),
 redirectUris: text('redirectUris', { mode: "json" }).notNull(),
 postLogoutRedirectUris: text('postLogoutRedirectUris', { mode: "json" }),
 backchannelLogoutUri: text('backchannelLogoutUri'),
 backchannelLogoutSessionRequired: integer('backchannelLogoutSessionRequired', { mode: 'boolean' }),
 tokenEndpointAuthMethod: text('tokenEndpointAuthMethod'),
 applicationType: text('applicationType'),
 jwks: text('jwks'),
 jwksUri: text('jwksUri'),
 grantTypes: text('grantTypes', { mode: "json" }),
 responseTypes: text('responseTypes', { mode: "json" }),
 requirePKCE: integer('requirePKCE', { mode: 'boolean' }),
 dpopBoundAccessTokens: integer('dpopBoundAccessTokens', { mode: 'boolean' }).default(false),
 referenceId: text('referenceId'),
 metadata: text('metadata', { mode: "json" })
					}, (table) => [
  index("oauthClient_userId_idx").on(table.userId),
]);

export const oauthResource = sqliteTable("oauthResource", {
					id: text('id').primaryKey(),
					identifier: text('identifier').notNull().unique(),
 name: text('name').notNull(),
 accessTokenTtl: integer('accessTokenTtl'),
 refreshTokenTtl: integer('refreshTokenTtl'),
 signingAlgorithm: text('signingAlgorithm'),
 signingKeyId: text('signingKeyId'),
 allowedScopes: text('allowedScopes', { mode: "json" }),
 customClaims: text('customClaims', { mode: "json" }),
 dpopBoundAccessTokensRequired: integer('dpopBoundAccessTokensRequired', { mode: 'boolean' }).default(false),
 disabled: integer('disabled', { mode: 'boolean' }).default(false),
 createdAt: sqliteDate('createdAt'),
 updatedAt: sqliteDate('updatedAt'),
 policyVersion: integer('policyVersion').default(1),
 metadata: text('metadata', { mode: "json" })
					});

export const oauthClientResource = sqliteTable("oauthClientResource", {
					id: text('id').primaryKey(),
					clientId: text('clientId').notNull().references(()=> oauthClient.clientId, { onDelete: 'cascade' }),
 resourceId: text('resourceId').notNull().references(()=> oauthResource.identifier, { onDelete: 'cascade' }),
 metadata: text('metadata', { mode: "json" }),
 createdAt: sqliteDate('createdAt')
					}, (table) => [
  uniqueIndex("oauthClientResource_clientId_resourceId_uidx").on(table.clientId, table.resourceId),
  index("oauthClientResource_clientId_idx").on(table.clientId),
  index("oauthClientResource_resourceId_idx").on(table.resourceId),
]);

export const oauthRefreshToken = sqliteTable("oauthRefreshToken", {
					id: text('id').primaryKey(),
					token: text('token').notNull().unique(),
 clientId: text('clientId').notNull().references(()=> oauthClient.clientId, { onDelete: 'cascade' }),
 sessionId: text('sessionId').references(()=> session.id, { onDelete: 'set null' }),
 userId: text('userId').notNull().references(()=> user.id, { onDelete: 'cascade' }),
 referenceId: text('referenceId'),
 authorizationCodeId: text('authorizationCodeId'),
 resources: text('resources', { mode: "json" }),
 requestedUserInfoClaims: text('requestedUserInfoClaims', { mode: "json" }),
 expiresAt: sqliteDate('expiresAt'),
 createdAt: sqliteDate('createdAt'),
 revoked: sqliteDate('revoked'),
 rotatedAt: sqliteDate('rotatedAt'),
 rotationReplayResponse: text('rotationReplayResponse'),
 rotationReplayExpiresAt: sqliteDate('rotationReplayExpiresAt'),
 authTime: sqliteDate('authTime'),
 confirmation: text('confirmation', { mode: "json" }),
 scopes: text('scopes', { mode: "json" }).notNull()
					}, (table) => [
  index("oauthRefreshToken_clientId_idx").on(table.clientId),
  index("oauthRefreshToken_sessionId_idx").on(table.sessionId),
  index("oauthRefreshToken_userId_idx").on(table.userId),
  index("oauthRefreshToken_authorizationCodeId_idx").on(table.authorizationCodeId),
]);

export const oauthAccessToken = sqliteTable("oauthAccessToken", {
					id: text('id').primaryKey(),
					token: text('token').unique(),
 clientId: text('clientId').notNull().references(()=> oauthClient.clientId, { onDelete: 'cascade' }),
 sessionId: text('sessionId').references(()=> session.id, { onDelete: 'set null' }),
 userId: text('userId').references(()=> user.id, { onDelete: 'cascade' }),
 referenceId: text('referenceId'),
 authorizationCodeId: text('authorizationCodeId'),
 resources: text('resources', { mode: "json" }),
 requestedUserInfoClaims: text('requestedUserInfoClaims', { mode: "json" }),
 refreshId: text('refreshId').references(()=> oauthRefreshToken.id, { onDelete: 'cascade' }),
 expiresAt: sqliteDate('expiresAt'),
 createdAt: sqliteDate('createdAt'),
 revoked: sqliteDate('revoked'),
 confirmation: text('confirmation', { mode: "json" }),
 scopes: text('scopes', { mode: "json" }).notNull()
					}, (table) => [
  index("oauthAccessToken_clientId_idx").on(table.clientId),
  index("oauthAccessToken_sessionId_idx").on(table.sessionId),
  index("oauthAccessToken_userId_idx").on(table.userId),
  index("oauthAccessToken_authorizationCodeId_idx").on(table.authorizationCodeId),
  index("oauthAccessToken_refreshId_idx").on(table.refreshId),
]);

export const oauthConsent = sqliteTable("oauthConsent", {
					id: text('id').primaryKey(),
					clientId: text('clientId').notNull().references(()=> oauthClient.clientId, { onDelete: 'cascade' }),
 userId: text('userId').references(()=> user.id, { onDelete: 'cascade' }),
 referenceId: text('referenceId'),
 resources: text('resources', { mode: "json" }),
 requestedUserInfoClaims: text('requestedUserInfoClaims', { mode: "json" }),
 scopes: text('scopes', { mode: "json" }).notNull(),
 createdAt: sqliteDate('createdAt'),
 updatedAt: sqliteDate('updatedAt')
					}, (table) => [
  index("oauthConsent_clientId_idx").on(table.clientId),
  index("oauthConsent_userId_idx").on(table.userId),
]);

export const oauthClientAssertion = sqliteTable("oauthClientAssertion", {
					id: text('id').primaryKey(),
					expiresAt: sqliteDate('expiresAt').notNull()
					});


export const modelAlias = sqliteTable("modelAlias", {
  alias: text("alias").primaryKey(),
  upstreamModel: text("upstreamModel").notNull(),
  displayName: text("displayName"),
  enabled: integer("enabled", { mode: "boolean" }).default(true).notNull(),
  createdAt: sqliteDate("createdAt").default(sql`CURRENT_TIMESTAMP`).notNull(),
  updatedAt: sqliteDate("updatedAt").default(sql`CURRENT_TIMESTAMP`).notNull(),
});

export const platformAdmin = sqliteTable("platformAdmin", {
  email: text("email").primaryKey(),
  createdAt: sqliteDate("createdAt").default(sql`CURRENT_TIMESTAMP`).notNull(),
});
