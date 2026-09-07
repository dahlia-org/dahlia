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
CREATE INDEX `meeting_events_meeting_time_idx` ON `meeting_events` (`vault_id`,`meeting_id`,`occurred_at`,`id`);--> statement-breakpoint
CREATE INDEX `meeting_events_session_idx` ON `meeting_events` (`vault_id`,`session_id`);--> statement-breakpoint
CREATE VIEW `recording_sessions` AS
  SELECT vault_id, meeting_id, session_id,
    min(CASE WHEN kind = 'recording_started' THEN occurred_at END) AS started_at,
    max(CASE WHEN kind = 'recording_ended' THEN occurred_at END) AS ended_at
  FROM meeting_events
  WHERE session_id IS NOT NULL AND kind IN ('recording_started', 'recording_ended')
  GROUP BY vault_id, meeting_id, session_id
;
