CREATE TABLE "app"."vault_transfers" (
	"sequence" bigserial PRIMARY KEY,
	"id" uuid NOT NULL UNIQUE,
	"owner_user_id" text NOT NULL,
	"idempotency_key" uuid NOT NULL,
	"request_hash" text NOT NULL,
	"source_vault_id" uuid NOT NULL,
	"destination_vault_id" uuid NOT NULL,
	"manifest" jsonb NOT NULL,
	CONSTRAINT "vault_transfer_owner_key_unique" UNIQUE("owner_user_id","idempotency_key")
);
--> statement-breakpoint
ALTER TABLE "app"."vault_transfers" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
CREATE INDEX "vault_transfer_owner_sequence_idx" ON "app"."vault_transfers" ("owner_user_id","sequence");--> statement-breakpoint
ALTER TABLE "app"."vault_transfers" ADD CONSTRAINT "vault_transfers_owner_user_id_user_id_fkey" FOREIGN KEY ("owner_user_id") REFERENCES "auth"."user"("id") ON DELETE CASCADE;--> statement-breakpoint
CREATE POLICY "vault_transfer_owner" ON "app"."vault_transfers" AS PERMISSIVE FOR ALL TO public USING ("app"."vault_transfers"."owner_user_id" = nullif(current_setting('app.user_id', true), '')) WITH CHECK ("app"."vault_transfers"."owner_user_id" = nullif(current_setting('app.user_id', true), ''));