CREATE TABLE `summary_versions` (
	`vault_id` text NOT NULL,
	`meeting_id` text NOT NULL,
	`revision` integer NOT NULL,
	`title` text NOT NULL,
	`document` text NOT NULL,
	`created_at` integer,
	`saved_at` integer NOT NULL,
	`metadata` text,
	CONSTRAINT `summary_versions_pk` PRIMARY KEY(`meeting_id`, `revision`),
	CONSTRAINT `fk_summary_versions_vault_id_meeting_id_meetings_vault_id_meeting_id_fk` FOREIGN KEY (`vault_id`,`meeting_id`) REFERENCES `meetings`(`vault_id`,`meeting_id`) ON DELETE CASCADE
);
