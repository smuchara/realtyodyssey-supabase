-- ============================================================================
-- V 1 32: Remove leftover push cron jobs
-- ============================================================================
-- Earlier push-dispatch experiments created cron jobs by name and by direct
-- command. Remove any remaining jobs that reference the push dispatcher so the
-- Database Webhook is the only automatic caller.
-- ============================================================================

do $$
declare
  v_job record;
begin
  for v_job in
    select jobid
    from cron.job
    where jobname = 'dispatch-pending-push-notifications'
       or command like '%send-tenant-pushes%'
       or command like '%dispatch_pending_push_notifications%'
  loop
    perform cron.unschedule(v_job.jobid);
  end loop;
end;
$$;
