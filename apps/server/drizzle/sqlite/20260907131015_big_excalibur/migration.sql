CREATE TABLE `recordings` (
	`session_id` text PRIMARY KEY,
	`vault_id` text NOT NULL,
	`meeting_id` text NOT NULL,
	`number` integer NOT NULL,
	`started_at` integer NOT NULL,
	`ended_at` integer NOT NULL,
	`audio` text NOT NULL,
	`revision` integer DEFAULT 0 NOT NULL,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	CONSTRAINT `fk_recordings_vault_id_meeting_id_meetings_vault_id_meeting_id_fk` FOREIGN KEY (`vault_id`,`meeting_id`) REFERENCES `meetings`(`vault_id`,`meeting_id`) ON DELETE CASCADE,
	CONSTRAINT `recordings_meeting_number_unique` UNIQUE(`meeting_id`,`number`),
	CONSTRAINT "recordings_number_check" CHECK("number" > 0)
);
--> statement-breakpoint
CREATE INDEX `recordings_vault_session_idx` ON `recordings` (`vault_id`,`session_id`);