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
CREATE INDEX `vault_transfer_owner_sequence_idx` ON `vault_transfers` (`owner_user_id`,`sequence`);