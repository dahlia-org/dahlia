CREATE FUNCTION "agent"."user_resource_id"(target_user_id uuid) RETURNS text
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE
  alphabet CONSTANT text := '0123456789abcdefghjkmnpqrstvwxyz';
  bits bit(130) := B'00' || (('x' || replace(target_user_id::text, '-', ''))::bit(128));
  result text := 'user_';
  part integer;
BEGIN
  FOR part IN 0..25 LOOP
    result := result || substr(alphabet, substring(bits FROM part * 5 + 1 FOR 5)::integer + 1, 1);
  END LOOP;
  RETURN result;
END;
$$;--> statement-breakpoint
ALTER POLICY "agent_message_owner" ON "agent"."mastra_messages" TO public USING (EXISTS (
  SELECT 1 FROM "agent"."mastra_threads" owner_thread
  WHERE owner_thread.id = "agent"."mastra_messages"."thread_id" AND owner_thread."resourceId" = "agent"."user_resource_id"(nullif(current_setting('app.user_id', true), '')::uuid)
)) WITH CHECK (EXISTS (
  SELECT 1 FROM "agent"."mastra_threads" owner_thread
  WHERE owner_thread.id = "agent"."mastra_messages"."thread_id" AND owner_thread."resourceId" = "agent"."user_resource_id"(nullif(current_setting('app.user_id', true), '')::uuid)
));--> statement-breakpoint
ALTER POLICY "agent_resource_owner" ON "agent"."mastra_resources" TO public USING ("agent"."mastra_resources"."id" = "agent"."user_resource_id"(nullif(current_setting('app.user_id', true), '')::uuid)) WITH CHECK ("agent"."mastra_resources"."id" = "agent"."user_resource_id"(nullif(current_setting('app.user_id', true), '')::uuid));--> statement-breakpoint
ALTER POLICY "agent_thread_owner" ON "agent"."mastra_threads" TO public USING ("agent"."mastra_threads"."resourceId" = "agent"."user_resource_id"(nullif(current_setting('app.user_id', true), '')::uuid)) WITH CHECK ("agent"."mastra_threads"."resourceId" = "agent"."user_resource_id"(nullif(current_setting('app.user_id', true), '')::uuid));--> statement-breakpoint
ALTER POLICY "ai_thread_run_owner" ON "agent"."ai_thread_runs" TO public USING ("agent"."ai_thread_runs"."resource_id" = "agent"."user_resource_id"(nullif(current_setting('app.user_id', true), '')::uuid)) WITH CHECK ("agent"."ai_thread_runs"."resource_id" = "agent"."user_resource_id"(nullif(current_setting('app.user_id', true), '')::uuid));
