ALTER TABLE `account_settings` ADD `processing` text DEFAULT '{"location":"local","remote":{"workflow":"transcribeThenSummarize"}}' NOT NULL;--> statement-breakpoint
PRAGMA foreign_keys=OFF;--> statement-breakpoint
CREATE TABLE `__new_account_settings` (
	`user_id` text PRIMARY KEY,
	`summary` text DEFAULT '{"style":"detailed"}' NOT NULL,
	`processing` text DEFAULT '{"location":"local","remote":{"workflow":"transcribeThenSummarize"}}' NOT NULL,
	`revision` integer DEFAULT 1 NOT NULL,
	`output_language` text NOT NULL,
	`analysis_languages` text NOT NULL,
	CONSTRAINT `fk_account_settings_user_id_user_id_fk` FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON DELETE CASCADE
);
--> statement-breakpoint
INSERT INTO `__new_account_settings`(`user_id`, `summary`, `revision`, `output_language`, `analysis_languages`) SELECT `user_id`, `summary`, `revision`, `output_language`, `analysis_languages` FROM `account_settings`;--> statement-breakpoint
DROP TABLE `account_settings`;--> statement-breakpoint
ALTER TABLE `__new_account_settings` RENAME TO `account_settings`;--> statement-breakpoint
UPDATE `account_settings` SET
  `processing` = json_object(
    'location', json_extract(`summary`, '$.mode'),
    'remote', json_patch(json_object(
      'workflow', CASE WHEN json_extract(`summary`, '$.remote.transcriptionModel') IS NULL THEN 'combined' ELSE 'transcribeThenSummarize' END
    ), json_object(
      'summaryModel', json_extract(`summary`, '$.remote.model'),
      'reasoningEffort', json_extract(`summary`, '$.remote.reasoningEffort'),
      'transcriptionModel', json_extract(`summary`, '$.remote.transcriptionModel')
    ))
  ),
  `summary` = json_object('style', CASE json_extract(`summary`, '$.remote.detail')
    WHEN 'low' THEN 'concise' WHEN 'medium' THEN 'standard' WHEN 'high' THEN 'detailed'
    WHEN 'xhigh' THEN 'eventSummary' WHEN 'max' THEN 'eventTimeline'
    WHEN 'concise' THEN 'concise' WHEN 'standard' THEN 'standard' WHEN 'eventSession' THEN 'eventSummary'
    ELSE 'detailed' END),
  `revision` = `revision` + 1
WHERE json_extract(`summary`, '$.mode') IS NOT NULL;--> statement-breakpoint
PRAGMA foreign_keys=ON;
