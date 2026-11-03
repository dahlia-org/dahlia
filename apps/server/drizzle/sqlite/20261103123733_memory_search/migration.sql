CREATE TABLE `personal_memory_chunks` (
	`memory_id` text NOT NULL,
	`chunk_no` integer NOT NULL,
	`user_id` text NOT NULL,
	`chunk_text` text NOT NULL,
	`search_text` text DEFAULT '' NOT NULL,
	`analyzer` text NOT NULL,
	`content_hash` text NOT NULL,
	`embedding` blob,
	`embedding_model` text,
	CONSTRAINT `personal_memory_chunks_pk` PRIMARY KEY(`memory_id`, `chunk_no`),
	CONSTRAINT `fk_personal_memory_chunks_memory_id_personal_memories_id_fk` FOREIGN KEY (`memory_id`) REFERENCES `personal_memories`(`id`) ON DELETE CASCADE
);
--> statement-breakpoint
CREATE TABLE `shared_memory_chunks` (
	`memory_id` text NOT NULL,
	`chunk_no` integer NOT NULL,
	`workspace_id` text NOT NULL,
	`chunk_text` text NOT NULL,
	`search_text` text DEFAULT '' NOT NULL,
	`analyzer` text NOT NULL,
	`content_hash` text NOT NULL,
	`embedding` blob,
	`embedding_model` text,
	CONSTRAINT `shared_memory_chunks_pk` PRIMARY KEY(`memory_id`, `chunk_no`),
	CONSTRAINT `fk_shared_memory_chunks_memory_id_shared_memories_id_fk` FOREIGN KEY (`memory_id`) REFERENCES `shared_memories`(`id`) ON DELETE CASCADE
);
--> statement-breakpoint
CREATE INDEX `personal_memory_chunks_user_idx` ON `personal_memory_chunks` (`user_id`);--> statement-breakpoint
CREATE INDEX `shared_memory_chunks_workspace_idx` ON `shared_memory_chunks` (`workspace_id`);