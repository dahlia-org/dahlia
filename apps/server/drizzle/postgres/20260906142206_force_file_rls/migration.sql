-- Table owners must obey the same policies as identity-scoped application queries.
ALTER TABLE "app"."files" FORCE ROW LEVEL SECURITY;
--> statement-breakpoint
ALTER TABLE "app"."meeting_files" FORCE ROW LEVEL SECURITY;
