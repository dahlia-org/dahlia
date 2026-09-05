import { defineRelationsPart } from "drizzle-orm";
import {
  pgSchema,
  text,
  timestamp,
  boolean,
  integer,
  jsonb,
  index,
  uniqueIndex,
} from "drizzle-orm/pg-core";

export const authSchema = pgSchema("auth");

export const user = authSchema.table("user", {
  id: text("id").primaryKey(),
  name: text("name").notNull(),
  email: text("email").notNull().unique(),
  emailVerified: boolean("email_verified").default(false).notNull(),
  image: text("image"),
  createdAt: timestamp("created_at").defaultNow().notNull(),
  updatedAt: timestamp("updated_at")
    .defaultNow()
    .$onUpdate(() => /* @__PURE__ */ new Date())
    .notNull(),
  role: text("role"),
  banned: boolean("banned").default(false),
  banReason: text("ban_reason"),
  banExpires: timestamp("ban_expires"),
});

export const session = authSchema.table(
  "session",
  {
    id: text("id").primaryKey(),
    expiresAt: timestamp("expires_at").notNull(),
    token: text("token").notNull().unique(),
    createdAt: timestamp("created_at").defaultNow().notNull(),
    updatedAt: timestamp("updated_at")
      .$onUpdate(() => /* @__PURE__ */ new Date())
      .notNull(),
    ipAddress: text("ip_address"),
    userAgent: text("user_agent"),
    userId: text("user_id")
      .notNull()
      .references(() => user.id, { onDelete: "cascade" }),
    impersonatedBy: text("impersonated_by"),
    activeOrganizationId: text("active_organization_id"),
    activeTeamId: text("active_team_id"),
  },
  (table) => [index("session_userId_idx").on(table.userId)],
);

export const account = authSchema.table(
  "account",
  {
    id: text("id").primaryKey(),
    issuer: text("issuer").notNull(),
    accountId: text("account_id").notNull(),
    providerId: text("provider_id").notNull(),
    userId: text("user_id")
      .notNull()
      .references(() => user.id, { onDelete: "cascade" }),
    accessToken: text("access_token"),
    refreshToken: text("refresh_token"),
    idToken: text("id_token"),
    accessTokenExpiresAt: timestamp("access_token_expires_at"),
    refreshTokenExpiresAt: timestamp("refresh_token_expires_at"),
    scope: text("scope"),
    password: text("password"),
    createdAt: timestamp("created_at").defaultNow().notNull(),
    updatedAt: timestamp("updated_at")
      .$onUpdate(() => /* @__PURE__ */ new Date())
      .notNull(),
  },
  (table) => [
    uniqueIndex("account_issuer_accountId_uidx").on(
      table.issuer,
      table.accountId,
    ),
    index("account_userId_idx").on(table.userId),
  ],
);

export const verification = authSchema.table(
  "verification",
  {
    id: text("id").primaryKey(),
    identifier: text("identifier").notNull(),
    value: text("value").notNull(),
    expiresAt: timestamp("expires_at").notNull(),
    createdAt: timestamp("created_at").defaultNow().notNull(),
    updatedAt: timestamp("updated_at")
      .defaultNow()
      .$onUpdate(() => /* @__PURE__ */ new Date())
      .notNull(),
  },
  (table) => [index("verification_identifier_idx").on(table.identifier)],
);

export const jwks = authSchema.table("jwks", {
  id: text("id").primaryKey(),
  publicKey: text("public_key").notNull(),
  privateKey: text("private_key").notNull(),
  createdAt: timestamp("created_at").notNull(),
  expiresAt: timestamp("expires_at"),
  alg: text("alg"),
  crv: text("crv"),
});

export const oauthClient = authSchema.table(
  "oauth_client",
  {
    id: text("id").primaryKey(),
    clientId: text("client_id").notNull().unique(),
    clientSecret: text("client_secret"),
    clientDiscoveryId: text("client_discovery_id"),
    disabled: boolean("disabled").default(false),
    skipConsent: boolean("skip_consent"),
    enableEndSession: boolean("enable_end_session"),
    subjectType: text("subject_type"),
    scopes: text("scopes").array(),
    clientCredentialsScopes: text("client_credentials_scopes")
      .array()
      .default([]),
    userId: text("user_id").references(() => user.id, { onDelete: "cascade" }),
    createdAt: timestamp("created_at"),
    updatedAt: timestamp("updated_at"),
    name: text("name"),
    uri: text("uri"),
    icon: text("icon"),
    contacts: text("contacts").array(),
    tos: text("tos"),
    policy: text("policy"),
    softwareId: text("software_id"),
    softwareVersion: text("software_version"),
    softwareStatement: text("software_statement"),
    redirectUris: text("redirect_uris").array().notNull(),
    postLogoutRedirectUris: text("post_logout_redirect_uris").array(),
    backchannelLogoutUri: text("backchannel_logout_uri"),
    backchannelLogoutSessionRequired: boolean(
      "backchannel_logout_session_required",
    ),
    tokenEndpointAuthMethod: text("token_endpoint_auth_method"),
    applicationType: text("application_type"),
    jwks: text("jwks"),
    jwksUri: text("jwks_uri"),
    grantTypes: text("grant_types").array(),
    responseTypes: text("response_types").array(),
    requirePKCE: boolean("require_pkce"),
    dpopBoundAccessTokens: boolean("dpop_bound_access_tokens").default(false),
    referenceId: text("reference_id"),
    metadata: jsonb("metadata"),
  },
  (table) => [index("oauthClient_userId_idx").on(table.userId)],
);

export const oauthResource = authSchema.table("oauth_resource", {
  id: text("id").primaryKey(),
  identifier: text("identifier").notNull().unique(),
  name: text("name").notNull(),
  accessTokenTtl: integer("access_token_ttl"),
  refreshTokenTtl: integer("refresh_token_ttl"),
  signingAlgorithm: text("signing_algorithm"),
  signingKeyId: text("signing_key_id"),
  allowedScopes: text("allowed_scopes").array(),
  customClaims: jsonb("custom_claims"),
  dpopBoundAccessTokensRequired: boolean(
    "dpop_bound_access_tokens_required",
  ).default(false),
  disabled: boolean("disabled").default(false),
  createdAt: timestamp("created_at"),
  updatedAt: timestamp("updated_at"),
  policyVersion: integer("policy_version").default(1),
  metadata: jsonb("metadata"),
});

export const oauthClientResource = authSchema.table(
  "oauth_client_resource",
  {
    id: text("id").primaryKey(),
    clientId: text("client_id")
      .notNull()
      .references(() => oauthClient.clientId, { onDelete: "cascade" }),
    resourceId: text("resource_id")
      .notNull()
      .references(() => oauthResource.identifier, { onDelete: "cascade" }),
    metadata: jsonb("metadata"),
    createdAt: timestamp("created_at"),
  },
  (table) => [
    uniqueIndex("oauthClientResource_clientId_resourceId_uidx").on(
      table.clientId,
      table.resourceId,
    ),
    index("oauthClientResource_clientId_idx").on(table.clientId),
    index("oauthClientResource_resourceId_idx").on(table.resourceId),
  ],
);

export const oauthRefreshToken = authSchema.table(
  "oauth_refresh_token",
  {
    id: text("id").primaryKey(),
    token: text("token").notNull().unique(),
    clientId: text("client_id")
      .notNull()
      .references(() => oauthClient.clientId, { onDelete: "cascade" }),
    sessionId: text("session_id").references(() => session.id, {
      onDelete: "set null",
    }),
    userId: text("user_id")
      .notNull()
      .references(() => user.id, { onDelete: "cascade" }),
    referenceId: text("reference_id"),
    authorizationCodeId: text("authorization_code_id"),
    resources: text("resources").array(),
    requestedUserInfoClaims: text("requested_user_info_claims").array(),
    expiresAt: timestamp("expires_at"),
    createdAt: timestamp("created_at"),
    revoked: timestamp("revoked"),
    rotatedAt: timestamp("rotated_at"),
    rotationReplayResponse: text("rotation_replay_response"),
    rotationReplayExpiresAt: timestamp("rotation_replay_expires_at"),
    authTime: timestamp("auth_time"),
    confirmation: jsonb("confirmation"),
    scopes: text("scopes").array().notNull(),
  },
  (table) => [
    index("oauthRefreshToken_clientId_idx").on(table.clientId),
    index("oauthRefreshToken_sessionId_idx").on(table.sessionId),
    index("oauthRefreshToken_userId_idx").on(table.userId),
    index("oauthRefreshToken_authorizationCodeId_idx").on(
      table.authorizationCodeId,
    ),
  ],
);

export const oauthAccessToken = authSchema.table(
  "oauth_access_token",
  {
    id: text("id").primaryKey(),
    token: text("token").unique(),
    clientId: text("client_id")
      .notNull()
      .references(() => oauthClient.clientId, { onDelete: "cascade" }),
    sessionId: text("session_id").references(() => session.id, {
      onDelete: "set null",
    }),
    userId: text("user_id").references(() => user.id, { onDelete: "cascade" }),
    referenceId: text("reference_id"),
    authorizationCodeId: text("authorization_code_id"),
    resources: text("resources").array(),
    requestedUserInfoClaims: text("requested_user_info_claims").array(),
    refreshId: text("refresh_id").references(() => oauthRefreshToken.id, {
      onDelete: "cascade",
    }),
    expiresAt: timestamp("expires_at"),
    createdAt: timestamp("created_at"),
    revoked: timestamp("revoked"),
    confirmation: jsonb("confirmation"),
    scopes: text("scopes").array().notNull(),
  },
  (table) => [
    index("oauthAccessToken_clientId_idx").on(table.clientId),
    index("oauthAccessToken_sessionId_idx").on(table.sessionId),
    index("oauthAccessToken_userId_idx").on(table.userId),
    index("oauthAccessToken_authorizationCodeId_idx").on(
      table.authorizationCodeId,
    ),
    index("oauthAccessToken_refreshId_idx").on(table.refreshId),
  ],
);

export const oauthConsent = authSchema.table(
  "oauth_consent",
  {
    id: text("id").primaryKey(),
    clientId: text("client_id")
      .notNull()
      .references(() => oauthClient.clientId, { onDelete: "cascade" }),
    userId: text("user_id").references(() => user.id, { onDelete: "cascade" }),
    referenceId: text("reference_id"),
    resources: text("resources").array(),
    requestedUserInfoClaims: text("requested_user_info_claims").array(),
    scopes: text("scopes").array().notNull(),
    createdAt: timestamp("created_at"),
    updatedAt: timestamp("updated_at"),
  },
  (table) => [
    index("oauthConsent_clientId_idx").on(table.clientId),
    index("oauthConsent_userId_idx").on(table.userId),
  ],
);

export const oauthClientAssertion = authSchema.table("oauth_client_assertion", {
  id: text("id").primaryKey(),
  expiresAt: timestamp("expires_at").notNull(),
});

export const organization = authSchema.table(
  "organization",
  {
    id: text("id").primaryKey(),
    name: text("name").notNull(),
    slug: text("slug").notNull().unique(),
    logo: text("logo"),
    createdAt: timestamp("created_at").notNull(),
    metadata: text("metadata"),
  },
  (table) => [uniqueIndex("organization_slug_uidx").on(table.slug)],
);

export const team = authSchema.table(
  "team",
  {
    id: text("id").primaryKey(),
    name: text("name").notNull(),
    memberCount: integer("member_count").default(0).notNull(),
    organizationId: text("organization_id")
      .notNull()
      .references(() => organization.id, { onDelete: "cascade" }),
    createdAt: timestamp("created_at").notNull(),
    updatedAt: timestamp("updated_at").$onUpdate(
      () => /* @__PURE__ */ new Date(),
    ),
  },
  (table) => [index("team_organizationId_idx").on(table.organizationId)],
);

export const teamMember = authSchema.table(
  "team_member",
  {
    id: text("id").primaryKey(),
    teamId: text("team_id")
      .notNull()
      .references(() => team.id, { onDelete: "cascade" }),
    userId: text("user_id")
      .notNull()
      .references(() => user.id, { onDelete: "cascade" }),
    membershipKey: text("membership_key").unique(),
    createdAt: timestamp("created_at"),
  },
  (table) => [
    index("teamMember_teamId_idx").on(table.teamId),
    index("teamMember_userId_idx").on(table.userId),
  ],
);

export const member = authSchema.table(
  "member",
  {
    id: text("id").primaryKey(),
    organizationId: text("organization_id")
      .notNull()
      .references(() => organization.id, { onDelete: "cascade" }),
    userId: text("user_id")
      .notNull()
      .references(() => user.id, { onDelete: "cascade" }),
    role: text("role").default("member").notNull(),
    createdAt: timestamp("created_at").notNull(),
  },
  (table) => [
    index("member_organizationId_idx").on(table.organizationId),
    index("member_userId_idx").on(table.userId),
  ],
);

export const invitation = authSchema.table(
  "invitation",
  {
    id: text("id").primaryKey(),
    organizationId: text("organization_id")
      .notNull()
      .references(() => organization.id, { onDelete: "cascade" }),
    email: text("email").notNull(),
    role: text("role"),
    teamId: text("team_id"),
    status: text("status").default("pending").notNull(),
    expiresAt: timestamp("expires_at").notNull(),
    createdAt: timestamp("created_at").defaultNow().notNull(),
    inviterId: text("inviter_id")
      .notNull()
      .references(() => user.id, { onDelete: "cascade" }),
  },
  (table) => [
    index("invitation_organizationId_idx").on(table.organizationId),
    index("invitation_email_idx").on(table.email),
  ],
);

export const authRelations = defineRelationsPart(
  {
    user,
    session,
    account,
    verification,
    jwks,
    oauthClient,
    oauthResource,
    oauthClientResource,
    oauthRefreshToken,
    oauthAccessToken,
    oauthConsent,
    oauthClientAssertion,
    organization,
    team,
    teamMember,
    member,
    invitation,
  },
  (r) => ({
    user: {
      sessions: r.many.session({
        from: r.user.id,
        to: r.session.userId,
      }),
      accounts: r.many.account({
        from: r.user.id,
        to: r.account.userId,
      }),
      oauthClients: r.many.oauthClient({
        from: r.user.id,
        to: r.oauthClient.userId,
      }),
      oauthRefreshTokens: r.many.oauthRefreshToken({
        from: r.user.id,
        to: r.oauthRefreshToken.userId,
      }),
      oauthAccessTokens: r.many.oauthAccessToken({
        from: r.user.id,
        to: r.oauthAccessToken.userId,
      }),
      oauthConsents: r.many.oauthConsent({
        from: r.user.id,
        to: r.oauthConsent.userId,
      }),
      teamMembers: r.many.teamMember({
        from: r.user.id,
        to: r.teamMember.userId,
      }),
      members: r.many.member({
        from: r.user.id,
        to: r.member.userId,
      }),
      invitations: r.many.invitation({
        from: r.user.id,
        to: r.invitation.inviterId,
      }),
    },
    session: {
      user: r.one.user({
        from: r.session.userId,
        to: r.user.id,
      }),
      oauthRefreshTokens: r.many.oauthRefreshToken({
        from: r.session.id,
        to: r.oauthRefreshToken.sessionId,
      }),
      oauthAccessTokens: r.many.oauthAccessToken({
        from: r.session.id,
        to: r.oauthAccessToken.sessionId,
      }),
    },
    account: {
      user: r.one.user({
        from: r.account.userId,
        to: r.user.id,
      }),
    },
    oauthClient: {
      user: r.one.user({
        from: r.oauthClient.userId,
        to: r.user.id,
      }),
      oauthClientResources: r.many.oauthClientResource({
        from: r.oauthClient.clientId,
        to: r.oauthClientResource.clientId,
      }),
      oauthRefreshTokens: r.many.oauthRefreshToken({
        from: r.oauthClient.clientId,
        to: r.oauthRefreshToken.clientId,
      }),
      oauthAccessTokens: r.many.oauthAccessToken({
        from: r.oauthClient.clientId,
        to: r.oauthAccessToken.clientId,
      }),
      oauthConsents: r.many.oauthConsent({
        from: r.oauthClient.clientId,
        to: r.oauthConsent.clientId,
      }),
    },
    oauthResource: {
      oauthClientResources: r.many.oauthClientResource({
        from: r.oauthResource.identifier,
        to: r.oauthClientResource.resourceId,
      }),
    },
    oauthClientResource: {
      oauthClient: r.one.oauthClient({
        from: r.oauthClientResource.clientId,
        to: r.oauthClient.clientId,
      }),
      oauthResource: r.one.oauthResource({
        from: r.oauthClientResource.resourceId,
        to: r.oauthResource.identifier,
      }),
    },
    oauthRefreshToken: {
      oauthClient: r.one.oauthClient({
        from: r.oauthRefreshToken.clientId,
        to: r.oauthClient.clientId,
      }),
      session: r.one.session({
        from: r.oauthRefreshToken.sessionId,
        to: r.session.id,
      }),
      user: r.one.user({
        from: r.oauthRefreshToken.userId,
        to: r.user.id,
      }),
      oauthAccessTokens: r.many.oauthAccessToken({
        from: r.oauthRefreshToken.id,
        to: r.oauthAccessToken.refreshId,
      }),
    },
    oauthAccessToken: {
      oauthClient: r.one.oauthClient({
        from: r.oauthAccessToken.clientId,
        to: r.oauthClient.clientId,
      }),
      session: r.one.session({
        from: r.oauthAccessToken.sessionId,
        to: r.session.id,
      }),
      user: r.one.user({
        from: r.oauthAccessToken.userId,
        to: r.user.id,
      }),
      oauthRefreshToken: r.one.oauthRefreshToken({
        from: r.oauthAccessToken.refreshId,
        to: r.oauthRefreshToken.id,
      }),
    },
    oauthConsent: {
      oauthClient: r.one.oauthClient({
        from: r.oauthConsent.clientId,
        to: r.oauthClient.clientId,
      }),
      user: r.one.user({
        from: r.oauthConsent.userId,
        to: r.user.id,
      }),
    },
    organization: {
      teams: r.many.team({
        from: r.organization.id,
        to: r.team.organizationId,
      }),
      members: r.many.member({
        from: r.organization.id,
        to: r.member.organizationId,
      }),
      invitations: r.many.invitation({
        from: r.organization.id,
        to: r.invitation.organizationId,
      }),
    },
    team: {
      organization: r.one.organization({
        from: r.team.organizationId,
        to: r.organization.id,
      }),
      teamMembers: r.many.teamMember({
        from: r.team.id,
        to: r.teamMember.teamId,
      }),
    },
    teamMember: {
      team: r.one.team({
        from: r.teamMember.teamId,
        to: r.team.id,
      }),
      user: r.one.user({
        from: r.teamMember.userId,
        to: r.user.id,
      }),
    },
    member: {
      organization: r.one.organization({
        from: r.member.organizationId,
        to: r.organization.id,
      }),
      user: r.one.user({
        from: r.member.userId,
        to: r.user.id,
      }),
    },
    invitation: {
      organization: r.one.organization({
        from: r.invitation.organizationId,
        to: r.organization.id,
      }),
      user: r.one.user({
        from: r.invitation.inviterId,
        to: r.user.id,
      }),
    },
  }),
);
