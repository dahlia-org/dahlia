CREATE UNIQUE INDEX "member_user_organization_idx" ON "auth"."member" ("user_id","organization_id");--> statement-breakpoint
CREATE UNIQUE INDEX "team_member_user_team_idx" ON "auth"."team_member" ("user_id","team_id");--> statement-breakpoint
ALTER TABLE "app"."account_settings" FORCE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "app"."meeting_events" FORCE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "app"."meeting_attachments" FORCE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "search"."documents" FORCE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "app"."summaries" FORCE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "jobs"."summary" FORCE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "app"."transaction_receipts" FORCE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "app"."files" FORCE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "app"."meetings" FORCE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "app"."projects" FORCE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "app"."recordings" FORCE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "app"."transcript_segments" FORCE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "app"."vaults" FORCE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "app"."transcripts" FORCE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "app"."transcript_patch_chunks" FORCE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "app"."vault_transfers" FORCE ROW LEVEL SECURITY;--> statement-breakpoint
-- Drizzle does not express DEFERRABLE foreign keys. Keep ordinary writes immediate;
-- the atomic transfer alone defers composite membership checks until commit.
DO $$
DECLARE membership record;
BEGIN
  FOR membership IN
    SELECT conrelid::regclass AS relation, conname
    FROM pg_constraint
    WHERE contype = 'f' AND cardinality(conkey) > 1
      AND connamespace IN ('app'::regnamespace, 'search'::regnamespace)
      AND conrelid IN ('app.projects'::regclass, 'app.meetings'::regclass,
        'app.transcript_patch_chunks'::regclass, 'app.recordings'::regclass,
        'app.meeting_attachments'::regclass, 'search.documents'::regclass)
  LOOP
    EXECUTE format('ALTER TABLE %s ALTER CONSTRAINT %I DEFERRABLE INITIALLY IMMEDIATE', membership.relation, membership.conname);
  END LOOP;
END $$;--> statement-breakpoint
ALTER TABLE "crypto"."vault_keys" FORCE ROW LEVEL SECURITY;--> statement-breakpoint
