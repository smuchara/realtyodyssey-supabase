-- ============================================================================
-- V 1 29 patch: Push dispatcher – direct pg_net call from cron
-- ============================================================================
-- Replaces the vault/GUC wrapper approach. The cron job calls the Edge
-- Function directly every minute. The URL and dispatch secret are the same
-- values already set in the Edge Function's Supabase secrets environment –
-- no external secret layer needed.
--
-- Fill in the two placeholders before pushing this migration:
--   <project-ref>     → your Supabase project ref (e.g. abcdefghijklmnop)
--   <dispatch-secret> → value of PUSH_DISPATCH_SECRET in Edge Function secrets
-- ============================================================================

-- Drop the GUC-based wrapper; no longer needed.
drop function if exists app.dispatch_pending_push_notifications();

-- Replace existing schedule with the direct call.
do $$
begin
  if exists (
    select 1 from cron.job
     where jobname = 'dispatch-pending-push-notifications'
  ) then
    perform cron.unschedule('dispatch-pending-push-notifications');
  end if;
end;
$$;

select cron.schedule(
  'dispatch-pending-push-notifications',
  '* * * * *',
  $$
  select net.http_post(
    url     := 'https://<project-ref>.supabase.co/functions/v1/send-tenant-pushes',
    headers := '{"Content-Type":"application/json","x-push-dispatch-secret":"<dispatch-secret>"}'::jsonb,
    body    := '{"action":"dispatch_pending"}'::jsonb
  );
  $$
);
