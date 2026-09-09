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
CREATE TABLE `account_settings` (
	`user_id` text PRIMARY KEY,
	`summary` text DEFAULT '{"method":"transcript","detail":"high","methodSettings":{"transcript":{"model":"gpt-5.4","reasoningEffort":"medium"},"audio":{"model":"gemini-3-8-flash","reasoningEffort":"medium"}}}' NOT NULL,
	`revision` integer DEFAULT 1 NOT NULL,
	`output_language` text NOT NULL,
	`analysis_languages` text NOT NULL,
	CONSTRAINT `fk_account_settings_user_id_user_id_fk` FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON DELETE CASCADE
);
--> statement-breakpoint
CREATE TABLE `jobs_image_analysis` (
	`file_id` text PRIMARY KEY,
	`vault_id` text NOT NULL,
	`owner_user_id` text NOT NULL,
	`model` text NOT NULL,
	`status` text DEFAULT 'pending' NOT NULL,
	`attempts` integer DEFAULT 0 NOT NULL,
	`available_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	`claimed_at` integer,
	`lease_expires_at` integer,
	`last_error_code` text,
	CONSTRAINT `fk_jobs_image_analysis_file_id_files_file_id_fk` FOREIGN KEY (`file_id`) REFERENCES `files`(`file_id`) ON DELETE CASCADE,
	CONSTRAINT `fk_jobs_image_analysis_vault_id_vaults_vault_id_fk` FOREIGN KEY (`vault_id`) REFERENCES `vaults`(`vault_id`) ON DELETE CASCADE,
	CONSTRAINT `fk_jobs_image_analysis_owner_user_id_user_id_fk` FOREIGN KEY (`owner_user_id`) REFERENCES `user`(`id`) ON DELETE CASCADE,
	CONSTRAINT "image_analysis_job_status_check" CHECK("status" IN ('pending', 'processing', 'failed'))
);
--> statement-breakpoint
CREATE TABLE `meeting_events` (
	`id` text PRIMARY KEY,
	`vault_id` text NOT NULL,
	`owner_user_id` text NOT NULL,
	`meeting_id` text NOT NULL,
	`kind` text NOT NULL,
	`occurred_at` integer NOT NULL,
	`received_at` integer NOT NULL,
	`session_id` text,
	`related_id` text,
	`audio_source` text,
	`segment_index` integer,
	`changed_fields` text,
	CONSTRAINT `fk_meeting_events_vault_id_vaults_vault_id_fk` FOREIGN KEY (`vault_id`) REFERENCES `vaults`(`vault_id`) ON DELETE CASCADE,
	CONSTRAINT `fk_meeting_events_owner_user_id_user_id_fk` FOREIGN KEY (`owner_user_id`) REFERENCES `user`(`id`) ON DELETE CASCADE,
	CONSTRAINT "meeting_events_kind_check" CHECK("kind" IN ('meeting_created', 'meeting_updated', 'meeting_deleted', 'tag_added', 'tag_removed', 'recording_started', 'recording_ended', 'segment_rotated')),
	CONSTRAINT "meeting_events_source_check" CHECK("audio_source" IN ('mic', 'system'))
);
--> statement-breakpoint
CREATE TABLE `meeting_attachments` (
	`id` text PRIMARY KEY,
	`vault_id` text NOT NULL,
	`meeting_id` text NOT NULL,
	`file_id` text NOT NULL,
	`captured_at` integer,
	`session_id` text,
	`created_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	`revision` integer DEFAULT 1 NOT NULL,
	CONSTRAINT `fk_meeting_attachments_vault_id_meeting_id_meetings_vault_id_meeting_id_fk` FOREIGN KEY (`vault_id`,`meeting_id`) REFERENCES `meetings`(`vault_id`,`meeting_id`) ON DELETE CASCADE,
	CONSTRAINT `fk_meeting_attachments_vault_id_file_id_files_vault_id_file_id_fk` FOREIGN KEY (`vault_id`,`file_id`) REFERENCES `files`(`vault_id`,`file_id`),
	CONSTRAINT `meeting_attachments_meeting_attachment_unique` UNIQUE(`meeting_id`,`file_id`)
);
--> statement-breakpoint
CREATE TABLE `search_documents` (
	`document_id` text NOT NULL,
	`vault_id` text NOT NULL,
	`meeting_id` text NOT NULL,
	`kind` text NOT NULL,
	`search_text` text DEFAULT '' NOT NULL,
	`embedding_text` text,
	`embedding_content_hash` text,
	`updated_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	CONSTRAINT `search_documents_pk` PRIMARY KEY(`vault_id`, `document_id`),
	CONSTRAINT `fk_search_documents_vault_id_meeting_id_meetings_vault_id_meeting_id_fk` FOREIGN KEY (`vault_id`,`meeting_id`) REFERENCES `meetings`(`vault_id`,`meeting_id`) ON DELETE CASCADE,
	CONSTRAINT "search_document_kind_check" CHECK("kind" IN ('meeting', 'screenshot'))
);
--> statement-breakpoint
CREATE TABLE `search_embeddings` (
	`vault_id` text NOT NULL,
	`document_id` text NOT NULL,
	`model` text NOT NULL,
	`dimensions` integer NOT NULL,
	`content_hash` text NOT NULL,
	`embedding` blob NOT NULL,
	`updated_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	CONSTRAINT `search_embeddings_pk` PRIMARY KEY(`vault_id`, `document_id`),
	CONSTRAINT `fk_search_embeddings_vault_id_document_id_search_documents_vault_id_document_id_fk` FOREIGN KEY (`vault_id`,`document_id`) REFERENCES `search_documents`(`vault_id`,`document_id`) ON DELETE CASCADE,
	CONSTRAINT "search_embedding_dimensions_check" CHECK("dimensions" BETWEEN 32 AND 1024)
);
--> statement-breakpoint
CREATE TABLE `jobs_search_index` (
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
	CONSTRAINT `jobs_search_index_pk` PRIMARY KEY(`vault_id`, `document_id`),
	CONSTRAINT `fk_jobs_search_index_vault_id_vaults_vault_id_fk` FOREIGN KEY (`vault_id`) REFERENCES `vaults`(`vault_id`) ON DELETE CASCADE,
	CONSTRAINT `fk_jobs_search_index_owner_user_id_user_id_fk` FOREIGN KEY (`owner_user_id`) REFERENCES `user`(`id`) ON DELETE CASCADE,
	CONSTRAINT "search_index_job_status_check" CHECK("status" IN ('pending', 'processing', 'failed')),
	CONSTRAINT "search_index_job_dimensions_check" CHECK("dimensions" BETWEEN 32 AND 1024)
);
--> statement-breakpoint
CREATE TABLE `jobs_storage_delete` (
	`storage_key` text PRIMARY KEY,
	`attempts` integer DEFAULT 0 NOT NULL,
	`status` text DEFAULT 'pending' NOT NULL,
	`available_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	`claimed_at` integer,
	`lease_expires_at` integer,
	`last_error_code` text,
	`created_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	CONSTRAINT "storage_delete_job_status_check" CHECK("status" IN ('pending', 'processing', 'failed'))
);
--> statement-breakpoint
CREATE TABLE `summaries` (
	`id` text PRIMARY KEY,
	`meeting_id` text NOT NULL,
	`version` integer NOT NULL,
	`title` text NOT NULL,
	`document` text NOT NULL,
	`created_at` integer,
	`saved_at` integer NOT NULL,
	`metadata` text,
	CONSTRAINT `fk_summaries_meeting_id_meetings_meeting_id_fk` FOREIGN KEY (`meeting_id`) REFERENCES `meetings`(`meeting_id`) ON DELETE CASCADE,
	CONSTRAINT `summary_meeting_version_unique` UNIQUE(`meeting_id`,`version`)
);
--> statement-breakpoint
CREATE TABLE `jobs_summary` (
	`id` text PRIMARY KEY,
	`vault_id` text NOT NULL,
	`meeting_id` text NOT NULL,
	`owner_user_id` text NOT NULL,
	`method` text NOT NULL,
	`settings` text NOT NULL,
	`input` text,
	`stage` text,
	`transcript_revision` integer,
	`transcript_result` text,
	`output_language` text NOT NULL,
	`status` text DEFAULT 'pending' NOT NULL,
	`attempts` integer DEFAULT 0 NOT NULL,
	`created_at` integer NOT NULL,
	`available_at` integer NOT NULL,
	`claimed_at` integer,
	`lease_expires_at` integer,
	`last_error_code` text,
	`summary_revision` integer NOT NULL,
	`input_version` text NOT NULL,
	`request_hash` text NOT NULL,
	CONSTRAINT `fk_jobs_summary_vault_id_vaults_vault_id_fk` FOREIGN KEY (`vault_id`) REFERENCES `vaults`(`vault_id`) ON DELETE CASCADE,
	CONSTRAINT `fk_jobs_summary_meeting_id_meetings_meeting_id_fk` FOREIGN KEY (`meeting_id`) REFERENCES `meetings`(`meeting_id`) ON DELETE CASCADE,
	CONSTRAINT `fk_jobs_summary_owner_user_id_user_id_fk` FOREIGN KEY (`owner_user_id`) REFERENCES `user`(`id`) ON DELETE CASCADE,
	CONSTRAINT "summary_job_status_check" CHECK("status" IN ('pending', 'processing', 'succeeded', 'failed', 'cancelled'))
);
--> statement-breakpoint
CREATE TABLE `sync_changes` (
	`sequence` integer PRIMARY KEY AUTOINCREMENT,
	`owner_user_id` text NOT NULL,
	`vault_id` text NOT NULL,
	`entity` text NOT NULL,
	`entity_id` text NOT NULL,
	`action` text NOT NULL,
	`revision` integer,
	`transaction_id` text NOT NULL,
	`created_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	CONSTRAINT "sync_change_entity_check" CHECK("entity" IN ('vault', 'project', 'meeting', 'summary', 'transcript', 'file', 'meeting_attachment', 'recording')),
	CONSTRAINT "sync_change_action_check" CHECK("action" IN ('upsert', 'delete', 'reset'))
);
--> statement-breakpoint
CREATE TABLE `transaction_receipts` (
	`transaction_id` text PRIMARY KEY,
	`owner_user_id` text NOT NULL,
	`vault_id` text NOT NULL,
	`request_hash` text NOT NULL,
	`response_json` text,
	`results_json` text DEFAULT '[]' NOT NULL,
	`cursor` integer NOT NULL,
	`created_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	CONSTRAINT `fk_transaction_receipts_owner_user_id_user_id_fk` FOREIGN KEY (`owner_user_id`) REFERENCES `user`(`id`) ON DELETE CASCADE
);
--> statement-breakpoint
CREATE TABLE `sync_vault_state` (
	`owner_user_id` text NOT NULL,
	`vault_id` text NOT NULL,
	`latest_sequence` integer DEFAULT 0 NOT NULL,
	`pruned_through` integer DEFAULT 0 NOT NULL,
	CONSTRAINT `sync_vault_state_pk` PRIMARY KEY(`owner_user_id`, `vault_id`),
	CONSTRAINT `fk_sync_vault_state_owner_user_id_user_id_fk` FOREIGN KEY (`owner_user_id`) REFERENCES `user`(`id`) ON DELETE CASCADE,
	CONSTRAINT "sync_vault_state_boundary_check" CHECK("pruned_through" >= 0 AND "latest_sequence" >= "pruned_through")
);
--> statement-breakpoint
CREATE TABLE `files` (
	`file_id` text PRIMARY KEY,
	`vault_id` text NOT NULL,
	`uri` text NOT NULL,
	`offset` integer DEFAULT 0 NOT NULL,
	`size` integer NOT NULL,
	`content_type` text NOT NULL,
	`checksum` text NOT NULL,
	`name` text NOT NULL,
	`metadata` text NOT NULL,
	`active` integer DEFAULT false NOT NULL,
	`uploaded_at` integer,
	`revision` integer DEFAULT 0 NOT NULL,
	`created_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	`updated_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	CONSTRAINT `fk_files_vault_id_vaults_vault_id_fk` FOREIGN KEY (`vault_id`) REFERENCES `vaults`(`vault_id`) ON DELETE CASCADE,
	CONSTRAINT `files_vault_file_unique` UNIQUE(`vault_id`,`file_id`),
	CONSTRAINT "files_offset_check" CHECK("offset" = 0),
	CONSTRAINT "files_size_check" CHECK("size" >= 0)
);
--> statement-breakpoint
CREATE TABLE `meetings` (
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
	`revision` integer DEFAULT 1 NOT NULL,
	`summary_revision` integer DEFAULT 0 NOT NULL,
	`transcript_revision` integer DEFAULT 0 NOT NULL,
	`active` integer DEFAULT false NOT NULL,
	`deleting_at` integer,
	CONSTRAINT `fk_meetings_vault_id_vaults_vault_id_fk` FOREIGN KEY (`vault_id`) REFERENCES `vaults`(`vault_id`) ON DELETE CASCADE,
	CONSTRAINT `fk_meetings_vault_id_project_id_projects_vault_id_project_id_fk` FOREIGN KEY (`vault_id`,`project_id`) REFERENCES `projects`(`vault_id`,`project_id`),
	CONSTRAINT `synced_meeting_vault_meeting_unique` UNIQUE(`vault_id`,`meeting_id`)
);
--> statement-breakpoint
CREATE TABLE `projects` (
	`project_id` text PRIMARY KEY,
	`vault_id` text NOT NULL,
	`parent_project_id` text,
	`name` text NOT NULL,
	`icon` text,
	`color` text,
	`description` text DEFAULT '' NOT NULL,
	`project_type` text,
	`revision` integer NOT NULL,
	`created_at` integer NOT NULL,
	`updated_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	CONSTRAINT `fk_projects_vault_id_vaults_vault_id_fk` FOREIGN KEY (`vault_id`) REFERENCES `vaults`(`vault_id`) ON DELETE CASCADE,
	CONSTRAINT `fk_projects_vault_id_parent_project_id_projects_vault_id_project_id_fk` FOREIGN KEY (`vault_id`,`parent_project_id`) REFERENCES `projects`(`vault_id`,`project_id`) ON DELETE RESTRICT,
	CONSTRAINT `project_vault_project_unique` UNIQUE(`vault_id`,`project_id`),
	CONSTRAINT "project_type_check" CHECK((
    ("parent_project_id" IS NULL AND "project_type" IN ('customer', 'internal', 'personal', 'undefined'))
    OR ("parent_project_id" IS NOT NULL AND "project_type" IS NULL)
  )),
	CONSTRAINT "project_revision_check" CHECK("revision" >= 1),
	CONSTRAINT "project_parent_check" CHECK("parent_project_id" IS NULL OR "parent_project_id" <> "project_id")
);
--> statement-breakpoint
CREATE TABLE `recordings` (
	`session_id` text PRIMARY KEY,
	`meeting_id` text NOT NULL,
	`number` integer NOT NULL,
	`started_at` integer NOT NULL,
	`ended_at` integer NOT NULL,
	`audio` text NOT NULL,
	`revision` integer DEFAULT 0 NOT NULL,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	CONSTRAINT `fk_recordings_meeting_id_meetings_meeting_id_fk` FOREIGN KEY (`meeting_id`) REFERENCES `meetings`(`meeting_id`) ON DELETE CASCADE,
	CONSTRAINT `recordings_meeting_number_unique` UNIQUE(`meeting_id`,`number`),
	CONSTRAINT "recordings_number_check" CHECK("number" > 0)
);
--> statement-breakpoint
CREATE TABLE `transcript_segments` (
	`transcript_id` text NOT NULL,
	`segment_id` text NOT NULL,
	`started_at` integer NOT NULL,
	`ended_at` integer,
	`text` text NOT NULL,
	`created_at` integer,
	`audio_source` text,
	`speaker_label` text,
	CONSTRAINT `transcript_segments_pk` PRIMARY KEY(`transcript_id`, `segment_id`),
	CONSTRAINT `fk_transcript_segments_transcript_id_transcripts_id_fk` FOREIGN KEY (`transcript_id`) REFERENCES `transcripts`(`id`) ON DELETE CASCADE
);
--> statement-breakpoint
CREATE TABLE `vaults` (
	`vault_id` text PRIMARY KEY,
	`name` text NOT NULL,
	`icon` text,
	`color` text,
	`revision` integer DEFAULT 1 NOT NULL,
	`deleting_at` integer,
	`created_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	`updated_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL
);
--> statement-breakpoint
CREATE TABLE `vault_permissions` (
	`vault_id` text NOT NULL,
	`principal_type` text NOT NULL,
	`principal_id` text NOT NULL,
	`role` text NOT NULL,
	`granted_by_user_id` text NOT NULL,
	`created_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	CONSTRAINT `vault_permissions_pk` PRIMARY KEY(`vault_id`, `principal_type`, `principal_id`),
	CONSTRAINT `fk_vault_permissions_vault_id_vaults_vault_id_fk` FOREIGN KEY (`vault_id`) REFERENCES `vaults`(`vault_id`) ON DELETE CASCADE,
	CONSTRAINT `fk_vault_permissions_granted_by_user_id_user_id_fk` FOREIGN KEY (`granted_by_user_id`) REFERENCES `user`(`id`) ON DELETE RESTRICT,
	CONSTRAINT "vault_permission_principal_type_check" CHECK("principal_type" IN ('user', 'organization', 'team')),
	CONSTRAINT "vault_permission_role_check" CHECK("role" IN ('owner', 'member')),
	CONSTRAINT "vault_permission_owner_user_check" CHECK("role" <> 'owner' OR "principal_type" = 'user')
);
--> statement-breakpoint
CREATE TABLE `transcripts` (
	`id` text PRIMARY KEY,
	`meeting_id` text NOT NULL,
	`version` integer NOT NULL,
	`sync_revision` integer NOT NULL,
	`started_at` integer,
	`ended_at` integer,
	`created_at` integer NOT NULL,
	`metadata` text,
	CONSTRAINT `fk_transcripts_meeting_id_meetings_meeting_id_fk` FOREIGN KEY (`meeting_id`) REFERENCES `meetings`(`meeting_id`) ON DELETE CASCADE,
	CONSTRAINT `transcript_meeting_version_unique` UNIQUE(`meeting_id`,`version`),
	CONSTRAINT "transcript_version_check" CHECK("version" >= 1)
);
--> statement-breakpoint
CREATE TABLE `transcript_patch_chunks` (
	`vault_id` text NOT NULL,
	`meeting_id` text NOT NULL,
	`patch_id` text NOT NULL,
	`chunk_index` integer NOT NULL,
	`content_hash` text NOT NULL,
	`payload` text NOT NULL,
	`created_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	CONSTRAINT `transcript_patch_chunks_pk` PRIMARY KEY(`vault_id`, `meeting_id`, `patch_id`, `chunk_index`),
	CONSTRAINT `fk_transcript_patch_chunks_vault_id_meeting_id_meetings_vault_id_meeting_id_fk` FOREIGN KEY (`vault_id`,`meeting_id`) REFERENCES `meetings`(`vault_id`,`meeting_id`) ON DELETE CASCADE
);
--> statement-breakpoint
CREATE TABLE `vault_transfers` (
	`sequence` integer PRIMARY KEY AUTOINCREMENT,
	`id` text NOT NULL UNIQUE,
	`owner_user_id` text NOT NULL,
	`idempotency_key` text NOT NULL,
	`request_hash` text NOT NULL,
	`source_vault_id` text NOT NULL,
	`destination_vault_id` text NOT NULL,
	`manifest` text NOT NULL,
	CONSTRAINT `fk_vault_transfers_owner_user_id_user_id_fk` FOREIGN KEY (`owner_user_id`) REFERENCES `user`(`id`) ON DELETE CASCADE,
	CONSTRAINT `vault_transfer_owner_key_unique` UNIQUE(`owner_user_id`,`idempotency_key`)
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
CREATE INDEX `image_analysis_job_claim_idx` ON `jobs_image_analysis` (`status`,`available_at`,`lease_expires_at`);--> statement-breakpoint
CREATE INDEX `meeting_events_meeting_time_idx` ON `meeting_events` (`vault_id`,`meeting_id`,`occurred_at`,`id`);--> statement-breakpoint
CREATE INDEX `meeting_events_session_idx` ON `meeting_events` (`vault_id`,`session_id`);--> statement-breakpoint
CREATE INDEX `meeting_attachments_vault_meeting_id_idx` ON `meeting_attachments` (`vault_id`,`meeting_id`,`id`);--> statement-breakpoint
CREATE INDEX `search_document_vault_kind_meeting_document_idx` ON `search_documents` (`vault_id`,`kind`,`meeting_id`,`document_id`);--> statement-breakpoint
CREATE INDEX `search_index_job_claim_idx` ON `jobs_search_index` (`status`,`available_at`,`lease_expires_at`);--> statement-breakpoint
CREATE INDEX `storage_delete_job_claim_idx` ON `jobs_storage_delete` (`status`,`available_at`,`lease_expires_at`);--> statement-breakpoint
CREATE UNIQUE INDEX `summary_job_active_meeting_idx` ON `jobs_summary` (`meeting_id`) WHERE "jobs_summary"."status" IN ('pending', 'processing');--> statement-breakpoint
CREATE INDEX `summary_job_owner_created_idx` ON `jobs_summary` (`owner_user_id`,`created_at`);--> statement-breakpoint
CREATE INDEX `sync_change_owner_vault_sequence_idx` ON `sync_changes` (`owner_user_id`,`vault_id`,`sequence`);--> statement-breakpoint
CREATE INDEX `sync_change_owner_sequence_idx` ON `sync_changes` (`owner_user_id`,`sequence`);--> statement-breakpoint
CREATE INDEX `transaction_receipt_owner_created_idx` ON `transaction_receipts` (`owner_user_id`,`created_at`);--> statement-breakpoint
CREATE INDEX `files_vault_file_idx` ON `files` (`vault_id`,`file_id`);--> statement-breakpoint
CREATE INDEX `synced_meeting_vault_created_id_idx` ON `meetings` (`vault_id`,`created_at`,`meeting_id`);--> statement-breakpoint
CREATE INDEX `project_vault_parent_name_idx` ON `projects` (`vault_id`,`parent_project_id`,`name`);--> statement-breakpoint
CREATE INDEX `recordings_meeting_session_idx` ON `recordings` (`meeting_id`,`session_id`);--> statement-breakpoint
CREATE INDEX `transcript_segment_created_idx` ON `transcript_segments` (`transcript_id`,`created_at`);--> statement-breakpoint
CREATE INDEX `transcript_segment_start_id_idx` ON `transcript_segments` (`transcript_id`,`started_at`,`segment_id`);--> statement-breakpoint
CREATE UNIQUE INDEX `vault_permission_single_owner_idx` ON `vault_permissions` (`vault_id`) WHERE "vault_permissions"."role" = 'owner';--> statement-breakpoint
CREATE INDEX `vault_permission_principal_vault_idx` ON `vault_permissions` (`principal_type`,`principal_id`,`role`,`vault_id`);--> statement-breakpoint
CREATE INDEX `vault_transfer_owner_sequence_idx` ON `vault_transfers` (`owner_user_id`,`sequence`);--> statement-breakpoint
CREATE VIEW `recording_sessions` AS
  SELECT vault_id, meeting_id, session_id,
    min(CASE WHEN kind = 'recording_started' THEN occurred_at END) AS started_at,
    max(CASE WHEN kind = 'recording_ended' THEN occurred_at END) AS ended_at
  FROM meeting_events
  WHERE session_id IS NOT NULL AND kind IN ('recording_started', 'recording_ended')
  GROUP BY vault_id, meeting_id, session_id
;--> statement-breakpoint
CREATE VIEW `meeting_images` AS
  SELECT m.id AS screenshot_id, f.file_id, m.vault_id, m.meeting_id,
    coalesce(m.captured_at, m.created_at) AS captured_at, f.content_type,
    'files/' || f.file_id || '/original' AS storage_key,
    f.size AS content_length, substr(f.checksum, 9) AS content_hash, f.active,
    json_extract(f.metadata, '$.ocr_text') AS ocr_text,
    json_extract(f.metadata, '$.caption') AS caption,
    m.revision
  FROM meeting_attachments m JOIN files f ON f.file_id = m.file_id AND f.vault_id = m.vault_id
  WHERE json_extract(f.metadata, '$.source') = 'screenshot'
;
