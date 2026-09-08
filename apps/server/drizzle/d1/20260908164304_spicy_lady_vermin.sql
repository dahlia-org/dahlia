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
DROP TABLE `summary_versions`;--> statement-breakpoint
ALTER TABLE `meetings` DROP COLUMN `summary_title`;--> statement-breakpoint
ALTER TABLE `meetings` DROP COLUMN `summary_document`;--> statement-breakpoint
ALTER TABLE `meetings` DROP COLUMN `summary_created_at`;