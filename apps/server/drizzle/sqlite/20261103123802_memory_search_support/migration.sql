CREATE VIRTUAL TABLE `personal_memory_chunks_fts` USING fts5(
  `search_text`, content=`personal_memory_chunks`, content_rowid=`rowid`, tokenize='unicode61'
);
--> statement-breakpoint
CREATE TRIGGER `personal_memory_chunks_fts_insert` AFTER INSERT ON `personal_memory_chunks` BEGIN
  INSERT INTO `personal_memory_chunks_fts` (`rowid`, `search_text`) VALUES (new.`rowid`, new.`search_text`);
END;
--> statement-breakpoint
CREATE TRIGGER `personal_memory_chunks_fts_delete` AFTER DELETE ON `personal_memory_chunks` BEGIN
  INSERT INTO `personal_memory_chunks_fts` (`personal_memory_chunks_fts`, `rowid`, `search_text`) VALUES ('delete', old.`rowid`, old.`search_text`);
END;
--> statement-breakpoint
CREATE TRIGGER `personal_memory_chunks_fts_update` AFTER UPDATE OF `search_text` ON `personal_memory_chunks` BEGIN
  INSERT INTO `personal_memory_chunks_fts` (`personal_memory_chunks_fts`, `rowid`, `search_text`) VALUES ('delete', old.`rowid`, old.`search_text`);
  INSERT INTO `personal_memory_chunks_fts` (`rowid`, `search_text`) VALUES (new.`rowid`, new.`search_text`);
END;
--> statement-breakpoint
CREATE VIRTUAL TABLE `shared_memory_chunks_fts` USING fts5(
  `search_text`, content=`shared_memory_chunks`, content_rowid=`rowid`, tokenize='unicode61'
);
--> statement-breakpoint
CREATE TRIGGER `shared_memory_chunks_fts_insert` AFTER INSERT ON `shared_memory_chunks` BEGIN
  INSERT INTO `shared_memory_chunks_fts` (`rowid`, `search_text`) VALUES (new.`rowid`, new.`search_text`);
END;
--> statement-breakpoint
CREATE TRIGGER `shared_memory_chunks_fts_delete` AFTER DELETE ON `shared_memory_chunks` BEGIN
  INSERT INTO `shared_memory_chunks_fts` (`shared_memory_chunks_fts`, `rowid`, `search_text`) VALUES ('delete', old.`rowid`, old.`search_text`);
END;
--> statement-breakpoint
CREATE TRIGGER `shared_memory_chunks_fts_update` AFTER UPDATE OF `search_text` ON `shared_memory_chunks` BEGIN
  INSERT INTO `shared_memory_chunks_fts` (`shared_memory_chunks_fts`, `rowid`, `search_text`) VALUES ('delete', old.`rowid`, old.`search_text`);
  INSERT INTO `shared_memory_chunks_fts` (`rowid`, `search_text`) VALUES (new.`rowid`, new.`search_text`);
END;
