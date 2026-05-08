-- ============================================================================
-- V 1 30: Push dispatch webhook repair
-- ============================================================================
-- Manual calls to send-tenant-pushes work, but ticket status changes only
-- create pending delivery rows. This migration restores automatic dispatch:
--   1. an after-insert trigger invokes the Edge Function through pg_net
--   2. a cron job retries pending rows every minute
--
-- The dispatch secret must live in Database Vault as PUSH_DISPATCH_SECRET.
-- Edge Function secrets are not readable from Postgres.
-- ============================================================================

create schema if not exists app;
create schema if not exists vault;

create extension if not exists pg_net;
create extension if not exists pg_cron;
create extension if not exists supabase_vault with schema vault;

create or replace function app.dispatch_pending_push_notifications()
returns void
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_base_url text;
  v_secret text;
  v_pending_count integer;
begin
  select count(*) into v_pending_count
  from app.tenant_push_deliveries
  where status = 'pending'
    and attempts < 3;

  if v_pending_count = 0 then
    return;
  end if;

  select decrypted_secret into v_base_url
  from vault.decrypted_secrets
  where name = 'SUPABASE_URL'
  limit 1;

  select decrypted_secret into v_secret
  from vault.decrypted_secrets
  where name = 'PUSH_DISPATCH_SECRET'
  limit 1;

  if nullif(trim(v_base_url), '') is null then
    v_base_url := 'https://ifpfptvajcqdcpbtsfsc.supabase.co';
  end if;

  if nullif(trim(v_secret), '') is null then
    raise warning 'push dispatcher: PUSH_DISPATCH_SECRET missing in vault';
    return;
  end if;

  perform net.http_post(
    url := rtrim(v_base_url, '/') || '/functions/v1/send-tenant-pushes',
    headers := jsonb_build_object(
      'Content-Type',
      'application/json',
      'x-push-dispatch-secret',
      v_secret
    ),
    body := '{"action":"dispatch_pending"}'::jsonb,
    timeout_milliseconds := 5000
  );
end;
$$;

create or replace function app.on_tenant_push_delivery_dispatch()
returns trigger
language plpgsql
security definer
set search_path = app, public
as $$
begin
  perform app.dispatch_pending_push_notifications();
  return null;
end;
$$;

drop trigger if exists trg_tenant_push_delivery_dispatch
  on app.tenant_push_deliveries;
create trigger trg_tenant_push_delivery_dispatch
  after insert on app.tenant_push_deliveries
  for each statement execute function app.on_tenant_push_delivery_dispatch();

do $$
begin
  if exists (
    select 1
    from cron.job
    where jobname = 'dispatch-pending-push-notifications'
  ) then
    perform cron.unschedule('dispatch-pending-push-notifications');
  end if;
end;
$$;

select cron.schedule(
  'dispatch-pending-push-notifications',
  '* * * * *',
  $$select app.dispatch_pending_push_notifications()$$
);
