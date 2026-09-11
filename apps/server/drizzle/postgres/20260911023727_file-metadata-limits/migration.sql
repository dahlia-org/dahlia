CREATE TEMP TABLE IF NOT EXISTS dahlia_file_metadata_limit_values (
	target text NOT NULL,
	record_id uuid NOT NULL,
	field_name text NOT NULL,
	owner_id uuid NOT NULL,
	original text NOT NULL,
	replacement text NOT NULL,
	PRIMARY KEY (target, record_id, field_name)
);--> statement-breakpoint
LOCK TABLE "app"."files", "search"."documents" IN ACCESS EXCLUSIVE MODE;--> statement-breakpoint
DO $$
DECLARE
	owner record;
	previous_user_id text := current_setting('app.user_id', true);
BEGIN
	FOR owner IN
		SELECT principal_id AS user_id
		FROM "app"."vault_permissions"
		WHERE principal_type = 'user' AND role = 'owner'
	LOOP
		PERFORM set_config('app.user_id', owner.user_id::text, true);
		IF EXISTS (
			SELECT 1 FROM "app"."files" file
			WHERE (char_length(file.metadata->>'ocr_text') > 65536
				AND NOT EXISTS (SELECT 1 FROM dahlia_file_metadata_limit_values staged
					WHERE staged.target = 'files' AND staged.record_id = file.file_id
						AND staged.field_name = 'ocr_text' AND staged.owner_id = owner.user_id
						AND staged.original = file.metadata->>'ocr_text'))
			OR (char_length(file.metadata->>'caption') > 2048
				AND NOT EXISTS (SELECT 1 FROM dahlia_file_metadata_limit_values staged
					WHERE staged.target = 'files' AND staged.record_id = file.file_id
						AND staged.field_name = 'caption' AND staged.owner_id = owner.user_id
						AND staged.original = file.metadata->>'caption'))
			UNION ALL
			SELECT 1 FROM "search"."documents" document
			WHERE (char_length(document.ocr_text) > 65536
				AND NOT EXISTS (SELECT 1 FROM dahlia_file_metadata_limit_values staged
					WHERE staged.target = 'search_documents' AND staged.record_id = document.document_id
						AND staged.field_name = 'ocr_text' AND staged.owner_id = owner.user_id
						AND staged.original = document.ocr_text))
			OR (char_length(document.caption_text) > 2048
				AND NOT EXISTS (SELECT 1 FROM dahlia_file_metadata_limit_values staged
					WHERE staged.target = 'search_documents' AND staged.record_id = document.document_id
						AND staged.field_name = 'caption_text' AND staged.owner_id = owner.user_id
						AND staged.original = document.caption_text))
		) THEN
			RAISE EXCEPTION 'file metadata changed while preparing migration; retry through the Dahlia Server migration runner';
		END IF;

		UPDATE "app"."files" file
		SET metadata = jsonb_set(file.metadata, '{ocr_text}', to_jsonb(staged.replacement), false)
		FROM dahlia_file_metadata_limit_values staged
		WHERE staged.target = 'files' AND staged.field_name = 'ocr_text' AND staged.owner_id = owner.user_id
			AND staged.record_id = file.file_id AND file.metadata->>'ocr_text' = staged.original;
		UPDATE "app"."files" file
		SET metadata = jsonb_set(file.metadata, '{caption}', to_jsonb(staged.replacement), false)
		FROM dahlia_file_metadata_limit_values staged
		WHERE staged.target = 'files' AND staged.field_name = 'caption' AND staged.owner_id = owner.user_id
			AND staged.record_id = file.file_id AND file.metadata->>'caption' = staged.original;
		UPDATE "search"."documents" document
		SET ocr_text = staged.replacement
		FROM dahlia_file_metadata_limit_values staged
		WHERE staged.target = 'search_documents' AND staged.field_name = 'ocr_text'
			AND staged.owner_id = owner.user_id AND staged.record_id = document.document_id
			AND document.ocr_text = staged.original;
		UPDATE "search"."documents" document
		SET caption_text = staged.replacement
		FROM dahlia_file_metadata_limit_values staged
		WHERE staged.target = 'search_documents' AND staged.field_name = 'caption_text'
			AND staged.owner_id = owner.user_id AND staged.record_id = document.document_id
			AND document.caption_text = staged.original;
	END LOOP;
	PERFORM set_config('app.user_id', coalesce(previous_user_id, ''), true);
END;
$$;--> statement-breakpoint
DROP TABLE dahlia_file_metadata_limit_values;--> statement-breakpoint
ALTER TABLE "search"."documents" ADD CONSTRAINT "search_documents_ocr_text_migration_check" CHECK (char_length("ocr_text") <= 65536);--> statement-breakpoint
ALTER TABLE "search"."documents" ADD CONSTRAINT "search_documents_caption_text_migration_check" CHECK (char_length("caption_text") <= 2048);--> statement-breakpoint
ALTER TABLE "search"."documents" DROP COLUMN "ocr_vector";--> statement-breakpoint
ALTER TABLE "search"."documents" DROP COLUMN "caption_vector";--> statement-breakpoint
ALTER TABLE "search"."documents" ALTER COLUMN "ocr_text" SET DATA TYPE varchar(65536) USING "ocr_text"::varchar(65536);--> statement-breakpoint
ALTER TABLE "search"."documents" ALTER COLUMN "caption_text" SET DATA TYPE varchar(2048) USING "caption_text"::varchar(2048);--> statement-breakpoint
ALTER TABLE "search"."documents" ADD COLUMN "ocr_vector" tsvector GENERATED ALWAYS AS (to_tsvector('simple', ocr_text)) STORED;--> statement-breakpoint
ALTER TABLE "search"."documents" ADD COLUMN "caption_vector" tsvector GENERATED ALWAYS AS (to_tsvector('simple', caption_text)) STORED;--> statement-breakpoint
ALTER TABLE "search"."documents" DROP CONSTRAINT "search_documents_ocr_text_migration_check";--> statement-breakpoint
ALTER TABLE "search"."documents" DROP CONSTRAINT "search_documents_caption_text_migration_check";--> statement-breakpoint
ALTER TABLE "app"."files" ADD CONSTRAINT "files_metadata_ocr_text_length_check" CHECK (char_length("metadata"->>'ocr_text') <= 65536);--> statement-breakpoint
ALTER TABLE "app"."files" ADD CONSTRAINT "files_metadata_caption_length_check" CHECK (char_length("metadata"->>'caption') <= 2048);
