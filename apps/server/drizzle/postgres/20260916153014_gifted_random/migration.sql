UPDATE "app"."workspaces"
SET "generation_settings" = "generation_settings" #- '{processing,remote,transcriptionModel}'
    #- '{transcription}'
WHERE "generation_settings" #> '{processing,remote,transcriptionModel}' IS NOT NULL
   OR "generation_settings" #> '{transcription}' IS NOT NULL;--> statement-breakpoint
ALTER TABLE "app"."workspaces" ALTER COLUMN "generation_settings" SET DEFAULT '{"outputLanguage":"ja","processing":{"location":"local","remote":{"workflow":"combined"}},"summary":{"style":"detailed"},"local":{"model":"gpt-5.6-luna","reasoningEffort":"high"},"automaticProcessing":true}';
