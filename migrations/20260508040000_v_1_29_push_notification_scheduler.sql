-- ============================================================================
-- V 1 29: Push notification scheduler
-- ============================================================================
-- The send-tenant-pushes Edge Function processes rows from
-- tenant_push_deliveries but has no automatic caller. This migration adds
-- pg_net + pg_cron so the function is invoked every minute automatically.
--
-- Before running this migration, add two secrets to the Supabase Vault
-- (Dashboard → Database → Vault, or via SQL editor):
--
--   select vault.create_secret(
--     'https://<your-project-ref>.supabase.co',
--     'SUPABASE_URL'
--   );
--   select vault.create_secret(
--     '<your-push-dispatch-secret>',
--     'PUSH_DISPATCH_SECRET'
--   );
--
-- The PUSH_DISPATCH_SECRET value must match the secret you already set in
-- Dashboard → Edge Functions → Secrets for the send-tenant-pushes function.
-- ============================================================================

create extension if not exists pg_net;
create extension if not exists pg_cron;

-- Wrapper function: reads both secrets from Vault at call time and fires the
-- Edge Function. Secrets are never stored in migration source code.
create or replace function app.dispatch_pending_push_notifications()
returns void
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_url    text;
  v_secret text;
begin
  select decrypted_secret into v_url
    from vault.decrypted_secrets
   where name = 'SUPABASE_URL'
   limit 1;

  select decrypted_secret into v_secret
    from vault.decrypted_secrets
   where name = 'PUSH_DISPATCH_SECRET'
   limit 1;

  if v_url is null or v_secret is null then
    raise warning 'push dispatcher: SUPABASE_URL or PUSH_DISPATCH_SECRET not found in vault – skipping';
    return;
  end if;

  perform net.http_post(
    url     := v_url || '/functions/v1/send-tenant-pushes',
    headers := jsonb_build_object(
      'Content-Type',           'application/json',
      'x-push-dispatch-secret', v_secret
    ),
    body    := '{"action":"dispatch_pending"}'::jsonb
  );
end;
$$;

-- Remove any existing schedule so the migration is idempotent.
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

-- Fire every minute. pg_cron runs this as the postgres role so the
-- security-definer wrapper above controls Vault access.
select cron.schedule(
  'dispatch-pending-push-notifications',
  '* * * * *',
  $$select app.dispatch_pending_push_notifications()$$
);
