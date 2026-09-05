CREATE TABLE "app"."sync_vault_state" (
	"owner_user_id" text,
	"vault_id" uuid,
	"latest_sequence" bigint DEFAULT 0 NOT NULL,
	"pruned_through" bigint DEFAULT 0 NOT NULL,
	CONSTRAINT "sync_vault_state_pkey" PRIMARY KEY("owner_user_id","vault_id"),
	CONSTRAINT "sync_vault_state_boundary_check" CHECK ("pruned_through" >= 0 AND "latest_sequence" >= "pruned_through")
);
--> statement-breakpoint
ALTER TABLE "app"."transaction_receipts" ADD COLUMN "results_json" jsonb DEFAULT '[]' NOT NULL;--> statement-breakpoint
ALTER TABLE "app"."transaction_receipts" ALTER COLUMN "response_json" DROP NOT NULL;--> statement-breakpoint
ALTER TABLE "app"."sync_vault_state" ADD CONSTRAINT "sync_vault_state_owner_user_id_user_id_fkey" FOREIGN KEY ("owner_user_id") REFERENCES "auth"."user"("id") ON DELETE CASCADE;