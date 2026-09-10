CREATE TABLE `live_transcripts` (
	`meeting_id` text PRIMARY KEY,
	`vault_id` text NOT NULL,
	`session_id` text NOT NULL,
	`started_at` integer NOT NULL,
	`sequence` integer NOT NULL,
	`status` text NOT NULL,
	`updated_at` integer NOT NULL,
	`previews` text NOT NULL,
	CONSTRAINT `fk_live_transcripts_vault_id_meeting_id_meetings_vault_id_meeting_id_fk` FOREIGN KEY (`vault_id`,`meeting_id`) REFERENCES `meetings`(`vault_id`,`meeting_id`) ON DELETE CASCADE
);
--> statement-breakpoint
CREATE INDEX `live_transcripts_vault_idx` ON `live_transcripts` (`vault_id`,`updated_at`);