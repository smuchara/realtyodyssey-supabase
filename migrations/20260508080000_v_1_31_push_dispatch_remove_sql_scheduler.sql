-- ============================================================================
-- V 1 31: Remove SQL push dispatcher
-- ============================================================================
-- Push deliveries should be dispatched by a Supabase Database Webhook on
-- app.tenant_push_deliveries inserts, not by a Vault-backed SQL wrapper.
-- This stops the old pg_cron job and removes the trigger/function path that
-- logs "PUSH_DISPATCH_SECRET missing in vault".
-- ============================================================================

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

drop trigger if exists trg_tenant_push_delivery_dispatch
  on app.tenant_push_deliveries;

drop function if exists app.on_tenant_push_delivery_dispatch();
drop function if exists app.dispatch_pending_push_notifications();
