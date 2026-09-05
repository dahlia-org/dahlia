-- The migration owner backfills existing receipts, then restores FORCE RLS in the same transaction.
ALTER TABLE "app"."transaction_receipts" NO FORCE ROW LEVEL SECURITY;
--> statement-breakpoint
UPDATE "app"."transaction_receipts"
SET results_json = (
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'entity', value->'entity', 'id', value->'id', 'revision', value->'revision'
  ) ORDER BY ordinal), '[]'::jsonb)
  FROM jsonb_array_elements(response_json->'records') WITH ORDINALITY AS records(value, ordinal)
);
--> statement-breakpoint
INSERT INTO "app"."sync_vault_state" (owner_user_id, vault_id, latest_sequence)
SELECT history.owner_user_id, history.vault_id, max(history.sequence)
FROM (
  SELECT owner_user_id, vault_id, sequence FROM "app"."sync_changes"
  UNION ALL
  SELECT owner_user_id, vault_id, cursor AS sequence FROM "app"."transaction_receipts"
) AS history
JOIN "auth"."user" AS users ON users.id = history.owner_user_id
GROUP BY history.owner_user_id, history.vault_id;
--> statement-breakpoint
ALTER TABLE "app"."transaction_receipts" FORCE ROW LEVEL SECURITY;
