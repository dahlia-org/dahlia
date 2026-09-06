CREATE TABLE `meeting_files` (
	`id` text PRIMARY KEY,
	`vault_id` text NOT NULL,
	`meeting_id` text NOT NULL,
	`file_id` text NOT NULL,
	`captured_at` integer,
	`session_id` text,
	`created_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	`revision` integer DEFAULT 1 NOT NULL,
	CONSTRAINT `fk_meeting_files_vault_id_meeting_id_meetings_vault_id_meeting_id_fk` FOREIGN KEY (`vault_id`,`meeting_id`) REFERENCES `meetings`(`vault_id`,`meeting_id`) ON DELETE CASCADE,
	CONSTRAINT `fk_meeting_files_vault_id_file_id_files_vault_id_file_id_fk` FOREIGN KEY (`vault_id`,`file_id`) REFERENCES `files`(`vault_id`,`file_id`),
	CONSTRAINT `meeting_files_meeting_file_unique` UNIQUE(`meeting_id`,`file_id`)
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
PRAGMA foreign_keys=OFF;--> statement-breakpoint
CREATE TABLE `__new_sync_changes` (
	`sequence` integer PRIMARY KEY AUTOINCREMENT,
	`owner_user_id` text NOT NULL,
	`vault_id` text NOT NULL,
	`entity` text NOT NULL,
	`entity_id` text NOT NULL,
	`action` text NOT NULL,
	`revision` integer,
	`transaction_id` text NOT NULL,
	`created_at` integer DEFAULT (cast(unixepoch('subsecond') * 1000 as integer)) NOT NULL,
	CONSTRAINT "sync_change_entity_check" CHECK("entity" IN ('vault', 'project', 'meeting', 'summary', 'transcript', 'file', 'meeting_file')),
	CONSTRAINT "sync_change_action_check" CHECK("action" IN ('upsert', 'delete', 'reset'))
);
--> statement-breakpoint
INSERT INTO `__new_sync_changes`(`sequence`, `owner_user_id`, `vault_id`, `entity`, `entity_id`, `action`, `revision`, `transaction_id`, `created_at`) SELECT `sequence`, `owner_user_id`, `vault_id`, `entity`, `entity_id`, `action`, `revision`, `transaction_id`, `created_at` FROM `sync_changes`;--> statement-breakpoint
DROP TABLE `sync_changes`;--> statement-breakpoint
ALTER TABLE `__new_sync_changes` RENAME TO `sync_changes`;--> statement-breakpoint
PRAGMA foreign_keys=ON;--> statement-breakpoint
DROP INDEX IF EXISTS `synced_screenshot_vault_meeting_captured_id_idx`;--> statement-breakpoint
CREATE INDEX `sync_change_owner_vault_sequence_idx` ON `sync_changes` (`owner_user_id`,`vault_id`,`sequence`);--> statement-breakpoint
CREATE INDEX `sync_change_owner_sequence_idx` ON `sync_changes` (`owner_user_id`,`sequence`);--> statement-breakpoint
CREATE INDEX `meeting_files_vault_meeting_id_idx` ON `meeting_files` (`vault_id`,`meeting_id`,`id`);--> statement-breakpoint
CREATE INDEX `files_vault_file_idx` ON `files` (`vault_id`,`file_id`);--> statement-breakpoint
DROP TABLE `screenshots`;--> statement-breakpoint
CREATE VIEW `meeting_images` AS
  SELECT m.id AS screenshot_id, f.file_id, m.vault_id, m.meeting_id,
    coalesce(m.captured_at, m.created_at) AS captured_at, f.content_type,
    'files/' || f.file_id || '/original' AS storage_key,
    f.size AS content_length, substr(f.checksum, 9) AS content_hash, f.active,
    json_extract(f.metadata, '$.ocr_text') AS ocr_text,
    json_extract(f.metadata, '$.caption') AS caption,
    m.revision
  FROM meeting_files m JOIN files f ON f.file_id = m.file_id AND f.vault_id = m.vault_id
  WHERE json_extract(f.metadata, '$.source') = 'screenshot'
;
