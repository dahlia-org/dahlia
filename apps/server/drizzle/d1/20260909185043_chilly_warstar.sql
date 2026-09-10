PRAGMA foreign_keys=OFF;--> statement-breakpoint
CREATE TABLE `__new_account_settings` (
	`user_id` text PRIMARY KEY,
	`summary` text DEFAULT '{"mode":"local","remote":{"detail":"high","model":"gemini-3-8-flash","reasoningEffort":"medium","transcriptionModel":"gemini-3-8-flash"}}' NOT NULL,
	`revision` integer DEFAULT 1 NOT NULL,
	`output_language` text NOT NULL,
	`analysis_languages` text NOT NULL,
	CONSTRAINT `fk_account_settings_user_id_user_id_fk` FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON DELETE CASCADE
);
--> statement-breakpoint
INSERT INTO `__new_account_settings`(`user_id`, `summary`, `revision`, `output_language`, `analysis_languages`) SELECT `user_id`, `summary`, `revision`, `output_language`, `analysis_languages` FROM `account_settings`;--> statement-breakpoint
DROP TABLE `account_settings`;--> statement-breakpoint
ALTER TABLE `__new_account_settings` RENAME TO `account_settings`;--> statement-breakpoint
UPDATE `account_settings`
SET `summary` = CASE json_extract(`summary`, '$.method')
  WHEN 'cloudTranscription' THEN json_object(
    'mode', 'remote',
    'remote', json_object(
      'detail', CASE json_extract(`summary`, '$.detail')
        WHEN 'concise' THEN 'low' WHEN 'standard' THEN 'medium'
        WHEN 'detailed' THEN 'high' WHEN 'eventSession' THEN 'xhigh'
        ELSE coalesce(json_extract(`summary`, '$.detail'), 'high') END,
      'model', coalesce(json_extract(`summary`, '$.methodSettings.transcript.model'), 'gemini-3-8-flash'),
      'reasoningEffort', coalesce(json_extract(`summary`, '$.methodSettings.transcript.reasoningEffort'), 'medium'),
      'transcriptionModel', coalesce(json_extract(`summary`, '$.methodSettings.audio.model'), 'gemini-3-8-flash')
    )
  )
  WHEN 'audio' THEN json_object(
    'mode', 'remote',
    'remote', json_object(
      'detail', CASE json_extract(`summary`, '$.detail')
        WHEN 'concise' THEN 'low' WHEN 'standard' THEN 'medium'
        WHEN 'detailed' THEN 'high' WHEN 'eventSession' THEN 'xhigh'
        ELSE coalesce(json_extract(`summary`, '$.detail'), 'high') END,
      'model', coalesce(json_extract(`summary`, '$.methodSettings.audio.model'), 'gemini-3-8-flash'),
      'reasoningEffort', coalesce(json_extract(`summary`, '$.methodSettings.audio.reasoningEffort'), 'medium')
    )
  )
  ELSE json_object(
    'mode', 'local',
    'remote', json_object(
      'detail', CASE json_extract(`summary`, '$.detail')
        WHEN 'concise' THEN 'low' WHEN 'standard' THEN 'medium'
        WHEN 'detailed' THEN 'high' WHEN 'eventSession' THEN 'xhigh'
        ELSE coalesce(json_extract(`summary`, '$.detail'), 'high') END,
      'model', coalesce(json_extract(`summary`, '$.methodSettings.transcript.model'), 'gemini-3-8-flash'),
      'reasoningEffort', coalesce(json_extract(`summary`, '$.methodSettings.transcript.reasoningEffort'), 'medium'),
      'transcriptionModel', 'gemini-3-8-flash'
    )
  )
END
WHERE json_extract(`summary`, '$.method') IS NOT NULL;--> statement-breakpoint
PRAGMA foreign_keys=ON;
