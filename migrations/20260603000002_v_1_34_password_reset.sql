-- ============================================================
-- V1.34 – Password Reset Support
-- ============================================================
-- Supabase Auth handles the email delivery and token exchange
-- natively (resetPasswordForEmail / updateUser).  This migration
-- adds a server-side audit log so security teams can track reset
-- attempts, and a rate-limit RPC that the mobile app can call
-- before triggering the email.
-- ============================================================

-- ── Audit table ──────────────────────────────────────────────

create table if not exists public.password_reset_requests (
  id           uuid        primary key default gen_random_uuid(),
  email        text        not null,
  requested_at timestamptz not null default now(),
  ip_address   text,
  completed    boolean     not null default false,
  completed_at timestamptz
);

comment on table public.password_reset_requests is
  'Audit log of password-reset emails sent from the mobile app.';

alter table public.password_reset_requests enable row level security;

-- No user-facing RLS policies – this table is service-role only.
-- Authenticated users cannot read or write directly.

-- ── Rate-limit + log RPC ─────────────────────────────────────

create or replace function public.log_password_reset_request(
  p_email      text,
  p_ip_address text default null
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_recent_count int;
begin
  select count(*) into v_recent_count
  from public.password_reset_requests
  where email        = lower(trim(p_email))
    and requested_at > now() - interval '1 hour';

  -- Allow at most 3 reset requests per email per hour.
  if v_recent_count >= 3 then
    return false;
  end if;

  insert into public.password_reset_requests (email, ip_address)
  values (lower(trim(p_email)), p_ip_address);

  return true;
end;
$$;

comment on function public.log_password_reset_request(text, text) is
  'Logs a password-reset attempt and returns false when rate-limited (> 3 per hour).';

-- Allow both anon (unauthenticated) and authenticated callers –
-- the forgot-password screen is shown before the user logs in.
grant execute on function public.log_password_reset_request(text, text)
  to anon, authenticated;

-- ── Mark reset completed ──────────────────────────────────────

create or replace function public.mark_password_reset_completed(
  p_email text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.password_reset_requests
  set    completed    = true,
         completed_at = now()
  where  email        = lower(trim(p_email))
    and  completed    = false;
end;
$$;

comment on function public.mark_password_reset_completed(text) is
  'Marks all pending reset requests for an email as completed.';

grant execute on function public.mark_password_reset_completed(text)
  to authenticated;
