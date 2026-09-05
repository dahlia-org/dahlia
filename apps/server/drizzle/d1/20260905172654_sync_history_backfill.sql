UPDATE transaction_receipts
SET results_json = (
  SELECT json_group_array(json_object(
    'entity', json_extract(value, '$.entity'),
    'id', json_extract(value, '$.id'),
    'revision', json_extract(value, '$.revision')
  )) FROM json_each(response_json, '$.records')
);
--> statement-breakpoint
INSERT INTO sync_vault_state (owner_user_id, vault_id, latest_sequence)
SELECT history.owner_user_id, history.vault_id, max(history.sequence)
FROM (
  SELECT owner_user_id, vault_id, sequence FROM sync_changes
  UNION ALL
  SELECT owner_user_id, vault_id, cursor AS sequence FROM transaction_receipts
) AS history
JOIN user AS users ON users.id = history.owner_user_id
GROUP BY history.owner_user_id, history.vault_id;
