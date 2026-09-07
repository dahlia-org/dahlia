-- Preserve the global cursor even if all prior change rows have been pruned.
CREATE TABLE __recording_sync_sequence AS SELECT seq FROM sqlite_sequence WHERE name = 'sync_changes';
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
	CONSTRAINT "sync_change_entity_check" CHECK("entity" IN ('vault', 'project', 'meeting', 'summary', 'transcript', 'file', 'meeting_file', 'recording')),
	CONSTRAINT "sync_change_action_check" CHECK("action" IN ('upsert', 'delete', 'reset'))
);
--> statement-breakpoint
INSERT INTO `__new_sync_changes`(`sequence`, `owner_user_id`, `vault_id`, `entity`, `entity_id`, `action`, `revision`, `transaction_id`, `created_at`) SELECT `sequence`, `owner_user_id`, `vault_id`, `entity`, `entity_id`, `action`, `revision`, `transaction_id`, `created_at` FROM `sync_changes`;--> statement-breakpoint
DROP TABLE `sync_changes`;--> statement-breakpoint
ALTER TABLE `__new_sync_changes` RENAME TO `sync_changes`;--> statement-breakpoint
PRAGMA foreign_keys=ON;--> statement-breakpoint
CREATE INDEX `sync_change_owner_vault_sequence_idx` ON `sync_changes` (`owner_user_id`,`vault_id`,`sequence`);--> statement-breakpoint
CREATE INDEX `sync_change_owner_sequence_idx` ON `sync_changes` (`owner_user_id`,`sequence`);
--> statement-breakpoint
UPDATE sqlite_sequence SET seq = MAX(seq, COALESCE((SELECT MAX(seq) FROM __recording_sync_sequence), 0)) WHERE name = 'sync_changes';
--> statement-breakpoint
DROP TABLE __recording_sync_sequence;
