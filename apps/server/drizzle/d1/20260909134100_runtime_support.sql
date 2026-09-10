CREATE UNIQUE INDEX `member_user_organization_idx` ON `member` (`user_id`,`organization_id`);
--> statement-breakpoint
CREATE UNIQUE INDEX `team_member_user_team_idx` ON `team_member` (`user_id`,`team_id`);
--> statement-breakpoint
CREATE VIRTUAL TABLE `search_documents_fts` USING fts5(
  `title_text`, `tags_text`, `description_text`, `summary_text`, `ocr_text`, `caption_text`,
  content=`search_documents`, content_rowid=`rowid`, tokenize='unicode61'
);
--> statement-breakpoint
CREATE TRIGGER `search_documents_fts_insert` AFTER INSERT ON `search_documents` BEGIN
  INSERT INTO `search_documents_fts` (`rowid`, `title_text`, `tags_text`, `description_text`, `summary_text`, `ocr_text`, `caption_text`)
  VALUES (new.`rowid`, new.`title_text`, new.`tags_text`, new.`description_text`, new.`summary_text`, new.`ocr_text`, new.`caption_text`);
END;
--> statement-breakpoint
CREATE TRIGGER `search_documents_fts_delete` AFTER DELETE ON `search_documents` BEGIN
  INSERT INTO `search_documents_fts` (`search_documents_fts`, `rowid`, `title_text`, `tags_text`, `description_text`, `summary_text`, `ocr_text`, `caption_text`)
  VALUES ('delete', old.`rowid`, old.`title_text`, old.`tags_text`, old.`description_text`, old.`summary_text`, old.`ocr_text`, old.`caption_text`);
END;
--> statement-breakpoint
CREATE TRIGGER `search_documents_fts_update` AFTER UPDATE OF `title_text`, `tags_text`, `description_text`, `summary_text`, `ocr_text`, `caption_text` ON `search_documents` BEGIN
  INSERT INTO `search_documents_fts` (`search_documents_fts`, `rowid`, `title_text`, `tags_text`, `description_text`, `summary_text`, `ocr_text`, `caption_text`)
  VALUES ('delete', old.`rowid`, old.`title_text`, old.`tags_text`, old.`description_text`, old.`summary_text`, old.`ocr_text`, old.`caption_text`);
  INSERT INTO `search_documents_fts` (`rowid`, `title_text`, `tags_text`, `description_text`, `summary_text`, `ocr_text`, `caption_text`)
  VALUES (new.`rowid`, new.`title_text`, new.`tags_text`, new.`description_text`, new.`summary_text`, new.`ocr_text`, new.`caption_text`);
END;
