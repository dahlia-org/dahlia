CREATE TABLE `account` (
	`id` text PRIMARY KEY,
	`issuer` text NOT NULL,
	`account_id` text NOT NULL,
	`provider_id` text NOT NULL,
	`user_id` text NOT NULL,
	`access_token` text,
	`refresh_token` text,
	`id_token` text,
	`access_token_expires_at` integer,
	`refresh_token_expires_at` integer,
	`scope` text,
	`password` text,
	`created_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	`updated_at` integer NOT NULL,
	CONSTRAINT `fk_account_user_id_user_id_fk` FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON DELETE CASCADE
);
--> statement-breakpoint
CREATE TABLE `invitation` (
	`id` text PRIMARY KEY,
	`organization_id` text NOT NULL,
	`email` text NOT NULL,
	`role` text,
	`team_id` text,
	`status` text DEFAULT 'pending' NOT NULL,
	`expires_at` integer NOT NULL,
	`created_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	`inviter_id` text NOT NULL,
	CONSTRAINT `fk_invitation_organization_id_organization_id_fk` FOREIGN KEY (`organization_id`) REFERENCES `organization`(`id`) ON DELETE CASCADE,
	CONSTRAINT `fk_invitation_inviter_id_user_id_fk` FOREIGN KEY (`inviter_id`) REFERENCES `user`(`id`) ON DELETE CASCADE
);
--> statement-breakpoint
CREATE TABLE `jwks` (
	`id` text PRIMARY KEY,
	`public_key` text NOT NULL,
	`private_key` text NOT NULL,
	`created_at` integer NOT NULL,
	`expires_at` integer,
	`alg` text,
	`crv` text
);
--> statement-breakpoint
CREATE TABLE `member` (
	`id` text PRIMARY KEY,
	`organization_id` text NOT NULL,
	`user_id` text NOT NULL,
	`role` text DEFAULT 'member' NOT NULL,
	`created_at` integer NOT NULL,
	CONSTRAINT `fk_member_organization_id_organization_id_fk` FOREIGN KEY (`organization_id`) REFERENCES `organization`(`id`) ON DELETE CASCADE,
	CONSTRAINT `fk_member_user_id_user_id_fk` FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON DELETE CASCADE
);
--> statement-breakpoint
CREATE TABLE `oauth_access_token` (
	`id` text PRIMARY KEY,
	`token` text UNIQUE,
	`client_id` text NOT NULL,
	`session_id` text,
	`user_id` text,
	`reference_id` text,
	`authorization_code_id` text,
	`resources` text,
	`requested_user_info_claims` text,
	`refresh_id` text,
	`expires_at` integer,
	`created_at` integer,
	`revoked` integer,
	`confirmation` text,
	`scopes` text NOT NULL,
	CONSTRAINT `fk_oauth_access_token_client_id_oauth_client_client_id_fk` FOREIGN KEY (`client_id`) REFERENCES `oauth_client`(`client_id`) ON DELETE CASCADE,
	CONSTRAINT `fk_oauth_access_token_session_id_session_id_fk` FOREIGN KEY (`session_id`) REFERENCES `session`(`id`) ON DELETE SET NULL,
	CONSTRAINT `fk_oauth_access_token_user_id_user_id_fk` FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON DELETE CASCADE,
	CONSTRAINT `fk_oauth_access_token_refresh_id_oauth_refresh_token_id_fk` FOREIGN KEY (`refresh_id`) REFERENCES `oauth_refresh_token`(`id`) ON DELETE CASCADE
);
--> statement-breakpoint
CREATE TABLE `oauth_client` (
	`id` text PRIMARY KEY,
	`client_id` text NOT NULL UNIQUE,
	`client_secret` text,
	`client_discovery_id` text,
	`disabled` integer DEFAULT false,
	`skip_consent` integer,
	`enable_end_session` integer,
	`subject_type` text,
	`scopes` text,
	`client_credentials_scopes` text DEFAULT '[]',
	`user_id` text,
	`created_at` integer,
	`updated_at` integer,
	`name` text,
	`uri` text,
	`icon` text,
	`contacts` text,
	`tos` text,
	`policy` text,
	`software_id` text,
	`software_version` text,
	`software_statement` text,
	`redirect_uris` text NOT NULL,
	`post_logout_redirect_uris` text,
	`backchannel_logout_uri` text,
	`backchannel_logout_session_required` integer,
	`token_endpoint_auth_method` text,
	`application_type` text,
	`jwks` text,
	`jwks_uri` text,
	`grant_types` text,
	`response_types` text,
	`require_pkce` integer,
	`dpop_bound_access_tokens` integer DEFAULT false,
	`reference_id` text,
	`metadata` text,
	CONSTRAINT `fk_oauth_client_user_id_user_id_fk` FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON DELETE CASCADE
);
--> statement-breakpoint
CREATE TABLE `oauth_client_assertion` (
	`id` text PRIMARY KEY,
	`expires_at` integer NOT NULL
);
--> statement-breakpoint
CREATE TABLE `oauth_client_resource` (
	`id` text PRIMARY KEY,
	`client_id` text NOT NULL,
	`resource_id` text NOT NULL,
	`metadata` text,
	`created_at` integer,
	CONSTRAINT `fk_oauth_client_resource_client_id_oauth_client_client_id_fk` FOREIGN KEY (`client_id`) REFERENCES `oauth_client`(`client_id`) ON DELETE CASCADE,
	CONSTRAINT `fk_oauth_client_resource_resource_id_oauth_resource_identifier_fk` FOREIGN KEY (`resource_id`) REFERENCES `oauth_resource`(`identifier`) ON DELETE CASCADE
);
--> statement-breakpoint
CREATE TABLE `oauth_consent` (
	`id` text PRIMARY KEY,
	`client_id` text NOT NULL,
	`user_id` text,
	`reference_id` text,
	`resources` text,
	`requested_user_info_claims` text,
	`scopes` text NOT NULL,
	`created_at` integer,
	`updated_at` integer,
	CONSTRAINT `fk_oauth_consent_client_id_oauth_client_client_id_fk` FOREIGN KEY (`client_id`) REFERENCES `oauth_client`(`client_id`) ON DELETE CASCADE,
	CONSTRAINT `fk_oauth_consent_user_id_user_id_fk` FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON DELETE CASCADE
);
--> statement-breakpoint
CREATE TABLE `oauth_refresh_token` (
	`id` text PRIMARY KEY,
	`token` text NOT NULL UNIQUE,
	`client_id` text NOT NULL,
	`session_id` text,
	`user_id` text NOT NULL,
	`reference_id` text,
	`authorization_code_id` text,
	`resources` text,
	`requested_user_info_claims` text,
	`expires_at` integer,
	`created_at` integer,
	`revoked` integer,
	`rotated_at` integer,
	`rotation_replay_response` text,
	`rotation_replay_expires_at` integer,
	`auth_time` integer,
	`confirmation` text,
	`scopes` text NOT NULL,
	CONSTRAINT `fk_oauth_refresh_token_client_id_oauth_client_client_id_fk` FOREIGN KEY (`client_id`) REFERENCES `oauth_client`(`client_id`) ON DELETE CASCADE,
	CONSTRAINT `fk_oauth_refresh_token_session_id_session_id_fk` FOREIGN KEY (`session_id`) REFERENCES `session`(`id`) ON DELETE SET NULL,
	CONSTRAINT `fk_oauth_refresh_token_user_id_user_id_fk` FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON DELETE CASCADE
);
--> statement-breakpoint
CREATE TABLE `oauth_resource` (
	`id` text PRIMARY KEY,
	`identifier` text NOT NULL UNIQUE,
	`name` text NOT NULL,
	`access_token_ttl` integer,
	`refresh_token_ttl` integer,
	`signing_algorithm` text,
	`signing_key_id` text,
	`allowed_scopes` text,
	`custom_claims` text,
	`dpop_bound_access_tokens_required` integer DEFAULT false,
	`disabled` integer DEFAULT false,
	`created_at` integer,
	`updated_at` integer,
	`policy_version` integer DEFAULT 1,
	`metadata` text
);
--> statement-breakpoint
CREATE TABLE `organization` (
	`id` text PRIMARY KEY,
	`name` text NOT NULL,
	`slug` text NOT NULL,
	`logo` text,
	`created_at` integer NOT NULL,
	`metadata` text
);
--> statement-breakpoint
CREATE TABLE `session` (
	`id` text PRIMARY KEY,
	`expires_at` integer NOT NULL,
	`token` text NOT NULL UNIQUE,
	`created_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	`updated_at` integer NOT NULL,
	`ip_address` text,
	`user_agent` text,
	`user_id` text NOT NULL,
	`impersonated_by` text,
	`active_organization_id` text,
	`active_team_id` text,
	CONSTRAINT `fk_session_user_id_user_id_fk` FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON DELETE CASCADE
);
--> statement-breakpoint
CREATE TABLE `team` (
	`id` text PRIMARY KEY,
	`name` text NOT NULL,
	`member_count` integer DEFAULT 0 NOT NULL,
	`organization_id` text NOT NULL,
	`created_at` integer NOT NULL,
	`updated_at` integer,
	CONSTRAINT `fk_team_organization_id_organization_id_fk` FOREIGN KEY (`organization_id`) REFERENCES `organization`(`id`) ON DELETE CASCADE
);
--> statement-breakpoint
CREATE TABLE `team_member` (
	`id` text PRIMARY KEY,
	`team_id` text NOT NULL,
	`user_id` text NOT NULL,
	`membership_key` text UNIQUE,
	`created_at` integer,
	CONSTRAINT `fk_team_member_team_id_team_id_fk` FOREIGN KEY (`team_id`) REFERENCES `team`(`id`) ON DELETE CASCADE,
	CONSTRAINT `fk_team_member_user_id_user_id_fk` FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON DELETE CASCADE
);
--> statement-breakpoint
CREATE TABLE `user` (
	`id` text PRIMARY KEY,
	`name` text NOT NULL,
	`email` text NOT NULL UNIQUE,
	`email_verified` integer DEFAULT false NOT NULL,
	`image` text,
	`created_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	`updated_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	`role` text,
	`banned` integer DEFAULT false,
	`ban_reason` text,
	`ban_expires` integer
);
--> statement-breakpoint
CREATE TABLE `verification` (
	`id` text PRIMARY KEY,
	`identifier` text NOT NULL,
	`value` text NOT NULL,
	`expires_at` integer NOT NULL,
	`created_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	`updated_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL
);
--> statement-breakpoint
CREATE TABLE `core_artifact` (
	`id` text PRIMARY KEY,
	`owner_workspace_id` text NOT NULL,
	`content_type` text NOT NULL,
	`storage_key` text,
	`visibility` text DEFAULT 'private' NOT NULL,
	`created_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	`updated_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	CONSTRAINT "artifact_visibility_check" CHECK("visibility" IN ('private', 'public'))
);
--> statement-breakpoint
CREATE TABLE `core_model_alias` (
	`alias` text PRIMARY KEY,
	`upstream_model` text NOT NULL,
	`display_name` text,
	`enabled` integer DEFAULT true NOT NULL,
	`created_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	`updated_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL
);
--> statement-breakpoint
CREATE TABLE `content_search_documents` (
	`document_id` text NOT NULL,
	`vault_id` text NOT NULL,
	`meeting_id` text NOT NULL,
	`kind` text NOT NULL,
	`search_text` text DEFAULT '' NOT NULL,
	`embedding_text` text,
	`embedding_content_hash` text,
	`updated_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	CONSTRAINT `content_search_documents_pk` PRIMARY KEY(`vault_id`, `document_id`),
	CONSTRAINT `fk_content_search_documents_vault_id_meeting_id_content_meetings_vault_id_meeting_id_fk` FOREIGN KEY (`vault_id`,`meeting_id`) REFERENCES `content_meetings`(`vault_id`,`meeting_id`) ON DELETE CASCADE,
	CONSTRAINT "search_document_kind_check" CHECK("kind" IN ('meeting', 'screenshot'))
);
--> statement-breakpoint
CREATE TABLE `content_search_embeddings` (
	`vault_id` text NOT NULL,
	`document_id` text NOT NULL,
	`model` text NOT NULL,
	`dimensions` integer NOT NULL,
	`content_hash` text NOT NULL,
	`embedding` blob NOT NULL,
	`updated_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	CONSTRAINT `content_search_embeddings_pk` PRIMARY KEY(`vault_id`, `document_id`),
	CONSTRAINT `fk_content_search_embeddings_vault_id_document_id_content_search_documents_vault_id_document_id_fk` FOREIGN KEY (`vault_id`,`document_id`) REFERENCES `content_search_documents`(`vault_id`,`document_id`) ON DELETE CASCADE,
	CONSTRAINT "search_embedding_dimensions_check" CHECK("dimensions" BETWEEN 32 AND 1024)
);
--> statement-breakpoint
CREATE TABLE `core_search_index_jobs` (
	`vault_id` text NOT NULL,
	`document_id` text NOT NULL,
	`owner_user_id` text NOT NULL,
	`model` text NOT NULL,
	`dimensions` integer NOT NULL,
	`generation` integer DEFAULT 1 NOT NULL,
	`status` text DEFAULT 'pending' NOT NULL,
	`attempts` integer DEFAULT 0 NOT NULL,
	`available_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	`claimed_at` integer,
	`lease_expires_at` integer,
	`last_error_code` text,
	`updated_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	CONSTRAINT `core_search_index_jobs_pk` PRIMARY KEY(`vault_id`, `document_id`),
	CONSTRAINT `fk_core_search_index_jobs_vault_id_core_vaults_vault_id_fk` FOREIGN KEY (`vault_id`) REFERENCES `core_vaults`(`vault_id`) ON DELETE CASCADE,
	CONSTRAINT `fk_core_search_index_jobs_owner_user_id_user_id_fk` FOREIGN KEY (`owner_user_id`) REFERENCES `user`(`id`) ON DELETE CASCADE,
	CONSTRAINT "search_index_job_status_check" CHECK("status" IN ('pending', 'processing', 'failed')),
	CONSTRAINT "search_index_job_dimensions_check" CHECK("dimensions" BETWEEN 32 AND 1024)
);
--> statement-breakpoint
CREATE TABLE `content_meetings` (
	`meeting_id` text PRIMARY KEY,
	`vault_id` text NOT NULL,
	`project_id` text,
	`name` text NOT NULL,
	`description` text DEFAULT '' NOT NULL,
	`status` text NOT NULL,
	`duration` real,
	`recording_started_at` integer,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	`summary_title` text,
	`summary_document` text,
	`summary_created_at` integer,
	`active_transcript_generation` text,
	`manifest_received_at` integer,
	`deleting_at` integer,
	CONSTRAINT `fk_content_meetings_vault_id_core_vaults_vault_id_fk` FOREIGN KEY (`vault_id`) REFERENCES `core_vaults`(`vault_id`) ON DELETE CASCADE,
	CONSTRAINT `fk_content_meetings_vault_id_project_id_core_projects_vault_id_project_id_fk` FOREIGN KEY (`vault_id`,`project_id`) REFERENCES `core_projects`(`vault_id`,`project_id`),
	CONSTRAINT `synced_meeting_vault_meeting_unique` UNIQUE(`vault_id`,`meeting_id`)
);
--> statement-breakpoint
CREATE TABLE `core_projects` (
	`project_id` text PRIMARY KEY,
	`vault_id` text NOT NULL,
	`parent_project_id` text,
	`name` text NOT NULL,
	`description` text DEFAULT '' NOT NULL,
	`project_type` text,
	`revision` integer NOT NULL,
	`created_at` integer NOT NULL,
	CONSTRAINT `fk_core_projects_vault_id_core_vaults_vault_id_fk` FOREIGN KEY (`vault_id`) REFERENCES `core_vaults`(`vault_id`) ON DELETE CASCADE,
	CONSTRAINT `fk_core_projects_vault_id_parent_project_id_core_projects_vault_id_project_id_fk` FOREIGN KEY (`vault_id`,`parent_project_id`) REFERENCES `core_projects`(`vault_id`,`project_id`) ON DELETE RESTRICT,
	CONSTRAINT `project_vault_project_unique` UNIQUE(`vault_id`,`project_id`),
	CONSTRAINT "project_type_check" CHECK((
    ("parent_project_id" IS NULL AND "project_type" IN ('customer', 'internal', 'personal', 'undefined'))
    OR ("parent_project_id" IS NOT NULL AND "project_type" IS NULL)
  )),
	CONSTRAINT "project_revision_check" CHECK("revision" >= 1),
	CONSTRAINT "project_parent_check" CHECK("parent_project_id" IS NULL OR "parent_project_id" <> "project_id")
);
--> statement-breakpoint
CREATE TABLE `content_screenshots` (
	`screenshot_id` text PRIMARY KEY,
	`vault_id` text NOT NULL,
	`meeting_id` text NOT NULL,
	`captured_at` integer NOT NULL,
	`content_type` text NOT NULL,
	`storage_key` text NOT NULL,
	`content_length` integer NOT NULL,
	`active` integer DEFAULT true NOT NULL,
	`ocr_text` text,
	`caption` text,
	`created_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	`updated_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	CONSTRAINT `fk_content_screenshots_vault_id_meeting_id_content_meetings_vault_id_meeting_id_fk` FOREIGN KEY (`vault_id`,`meeting_id`) REFERENCES `content_meetings`(`vault_id`,`meeting_id`) ON DELETE CASCADE
);
--> statement-breakpoint
CREATE TABLE `content_transcript_segments` (
	`vault_id` text NOT NULL,
	`meeting_id` text NOT NULL,
	`generation` text NOT NULL,
	`segment_id` text NOT NULL,
	`start_time` integer NOT NULL,
	`end_time` integer,
	`text` text NOT NULL,
	`is_confirmed` integer NOT NULL,
	`audio_source` text,
	`speaker_label` text,
	CONSTRAINT `content_transcript_segments_pk` PRIMARY KEY(`vault_id`, `meeting_id`, `generation`, `segment_id`),
	CONSTRAINT `fk_content_transcript_segments_vault_id_meeting_id_content_meetings_vault_id_meeting_id_fk` FOREIGN KEY (`vault_id`,`meeting_id`) REFERENCES `content_meetings`(`vault_id`,`meeting_id`) ON DELETE CASCADE
);
--> statement-breakpoint
CREATE TABLE `core_vaults` (
	`vault_id` text PRIMARY KEY,
	`name` text NOT NULL,
	`deleting_at` integer,
	`created_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	`updated_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL
);
--> statement-breakpoint
CREATE TABLE `core_vault_permissions` (
	`vault_id` text NOT NULL,
	`principal_type` text NOT NULL,
	`principal_id` text NOT NULL,
	`role` text NOT NULL,
	`granted_by_user_id` text NOT NULL,
	`created_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	CONSTRAINT `core_vault_permissions_pk` PRIMARY KEY(`vault_id`, `principal_type`, `principal_id`),
	CONSTRAINT `fk_core_vault_permissions_vault_id_core_vaults_vault_id_fk` FOREIGN KEY (`vault_id`) REFERENCES `core_vaults`(`vault_id`) ON DELETE CASCADE,
	CONSTRAINT `fk_core_vault_permissions_granted_by_user_id_user_id_fk` FOREIGN KEY (`granted_by_user_id`) REFERENCES `user`(`id`) ON DELETE RESTRICT,
	CONSTRAINT "vault_permission_principal_type_check" CHECK("principal_type" IN ('user', 'organization', 'team')),
	CONSTRAINT "vault_permission_role_check" CHECK("role" IN ('owner', 'member')),
	CONSTRAINT "vault_permission_owner_user_check" CHECK("role" <> 'owner' OR "principal_type" = 'user')
);
--> statement-breakpoint
CREATE UNIQUE INDEX `account_issuer_accountId_uidx` ON `account` (`issuer`,`account_id`);--> statement-breakpoint
CREATE INDEX `account_userId_idx` ON `account` (`user_id`);--> statement-breakpoint
CREATE INDEX `invitation_organizationId_idx` ON `invitation` (`organization_id`);--> statement-breakpoint
CREATE INDEX `invitation_email_idx` ON `invitation` (`email`);--> statement-breakpoint
CREATE INDEX `member_organizationId_idx` ON `member` (`organization_id`);--> statement-breakpoint
CREATE INDEX `member_userId_idx` ON `member` (`user_id`);--> statement-breakpoint
CREATE INDEX `oauthAccessToken_clientId_idx` ON `oauth_access_token` (`client_id`);--> statement-breakpoint
CREATE INDEX `oauthAccessToken_sessionId_idx` ON `oauth_access_token` (`session_id`);--> statement-breakpoint
CREATE INDEX `oauthAccessToken_userId_idx` ON `oauth_access_token` (`user_id`);--> statement-breakpoint
CREATE INDEX `oauthAccessToken_authorizationCodeId_idx` ON `oauth_access_token` (`authorization_code_id`);--> statement-breakpoint
CREATE INDEX `oauthAccessToken_refreshId_idx` ON `oauth_access_token` (`refresh_id`);--> statement-breakpoint
CREATE INDEX `oauthClient_userId_idx` ON `oauth_client` (`user_id`);--> statement-breakpoint
CREATE UNIQUE INDEX `oauthClientResource_clientId_resourceId_uidx` ON `oauth_client_resource` (`client_id`,`resource_id`);--> statement-breakpoint
CREATE INDEX `oauthClientResource_clientId_idx` ON `oauth_client_resource` (`client_id`);--> statement-breakpoint
CREATE INDEX `oauthClientResource_resourceId_idx` ON `oauth_client_resource` (`resource_id`);--> statement-breakpoint
CREATE INDEX `oauthConsent_clientId_idx` ON `oauth_consent` (`client_id`);--> statement-breakpoint
CREATE INDEX `oauthConsent_userId_idx` ON `oauth_consent` (`user_id`);--> statement-breakpoint
CREATE INDEX `oauthRefreshToken_clientId_idx` ON `oauth_refresh_token` (`client_id`);--> statement-breakpoint
CREATE INDEX `oauthRefreshToken_sessionId_idx` ON `oauth_refresh_token` (`session_id`);--> statement-breakpoint
CREATE INDEX `oauthRefreshToken_userId_idx` ON `oauth_refresh_token` (`user_id`);--> statement-breakpoint
CREATE INDEX `oauthRefreshToken_authorizationCodeId_idx` ON `oauth_refresh_token` (`authorization_code_id`);--> statement-breakpoint
CREATE UNIQUE INDEX `organization_slug_uidx` ON `organization` (`slug`);--> statement-breakpoint
CREATE INDEX `session_userId_idx` ON `session` (`user_id`);--> statement-breakpoint
CREATE INDEX `team_organizationId_idx` ON `team` (`organization_id`);--> statement-breakpoint
CREATE INDEX `teamMember_teamId_idx` ON `team_member` (`team_id`);--> statement-breakpoint
CREATE INDEX `teamMember_userId_idx` ON `team_member` (`user_id`);--> statement-breakpoint
CREATE INDEX `verification_identifier_idx` ON `verification` (`identifier`);--> statement-breakpoint
CREATE INDEX `search_document_vault_kind_meeting_document_idx` ON `content_search_documents` (`vault_id`,`kind`,`meeting_id`,`document_id`);--> statement-breakpoint
CREATE INDEX `search_index_job_claim_idx` ON `core_search_index_jobs` (`status`,`available_at`,`lease_expires_at`);--> statement-breakpoint
CREATE INDEX `synced_meeting_vault_created_id_idx` ON `content_meetings` (`vault_id`,`created_at`,`meeting_id`);--> statement-breakpoint
CREATE INDEX `project_vault_parent_name_idx` ON `core_projects` (`vault_id`,`parent_project_id`,`name`);--> statement-breakpoint
CREATE INDEX `synced_screenshot_vault_meeting_captured_id_idx` ON `content_screenshots` (`vault_id`,`meeting_id`,`captured_at`,`screenshot_id`);--> statement-breakpoint
CREATE INDEX `synced_transcript_vault_meeting_generation_start_id_idx` ON `content_transcript_segments` (`vault_id`,`meeting_id`,`generation`,`start_time`,`segment_id`);--> statement-breakpoint
CREATE UNIQUE INDEX `vault_permission_single_owner_idx` ON `core_vault_permissions` (`vault_id`) WHERE "core_vault_permissions"."role" = 'owner';--> statement-breakpoint
CREATE INDEX `vault_permission_principal_vault_idx` ON `core_vault_permissions` (`principal_type`,`principal_id`,`role`,`vault_id`);
--> statement-breakpoint
CREATE UNIQUE INDEX `project_sibling_name_unique`
ON `core_projects` (`vault_id`, coalesce(`parent_project_id`, '00000000-0000-0000-0000-000000000000'), lower(`name`));
--> statement-breakpoint
CREATE INDEX `member_user_organization_idx` ON `member` (`user_id`,`organization_id`);
--> statement-breakpoint
CREATE INDEX `team_member_user_team_idx` ON `team_member` (`user_id`,`team_id`);
--> statement-breakpoint
CREATE VIRTUAL TABLE `content_search_documents_fts` USING fts5(
  `search_text`, content=`content_search_documents`, content_rowid=`rowid`, tokenize='unicode61'
);
--> statement-breakpoint
CREATE TRIGGER `content_search_documents_fts_insert` AFTER INSERT ON `content_search_documents` BEGIN
  INSERT INTO `content_search_documents_fts` (`rowid`, `search_text`) VALUES (new.`rowid`, new.`search_text`);
END;
--> statement-breakpoint
CREATE TRIGGER `content_search_documents_fts_delete` AFTER DELETE ON `content_search_documents` BEGIN
  INSERT INTO `content_search_documents_fts` (`content_search_documents_fts`, `rowid`, `search_text`)
  VALUES ('delete', old.`rowid`, old.`search_text`);
END;
--> statement-breakpoint
CREATE TRIGGER `content_search_documents_fts_update` AFTER UPDATE OF `search_text` ON `content_search_documents` BEGIN
  INSERT INTO `content_search_documents_fts` (`content_search_documents_fts`, `rowid`, `search_text`)
  VALUES ('delete', old.`rowid`, old.`search_text`);
  INSERT INTO `content_search_documents_fts` (`rowid`, `search_text`) VALUES (new.`rowid`, new.`search_text`);
END;
