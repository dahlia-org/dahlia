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
ALTER TABLE `transaction_receipts` ADD `results_json` text DEFAULT '[]' NOT NULL;--> statement-breakpoint
PRAGMA foreign_keys=OFF;--> statement-breakpoint
CREATE TABLE `__new_transaction_receipts` (
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
INSERT INTO `__new_transaction_receipts`(`transaction_id`, `owner_user_id`, `vault_id`, `request_hash`, `response_json`, `cursor`, `created_at`) SELECT `transaction_id`, `owner_user_id`, `vault_id`, `request_hash`, `response_json`, `cursor`, `created_at` FROM `transaction_receipts`;--> statement-breakpoint
DROP TABLE `transaction_receipts`;--> statement-breakpoint
ALTER TABLE `__new_transaction_receipts` RENAME TO `transaction_receipts`;--> statement-breakpoint
PRAGMA foreign_keys=ON;--> statement-breakpoint
CREATE INDEX `transaction_receipt_owner_created_idx` ON `transaction_receipts` (`owner_user_id`,`created_at`);