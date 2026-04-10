-- ============================================================================
-- V 1 07: Units, Occupancy, Tenancy, and Invitations
-- ============================================================================
-- Purpose
--   - Create the final lease, invitation, tenancy, and occupancy tables
--   - Capture the hardened tenant invite lifecycle used by web and mobile
--   - Provide owner occupancy dashboard RPCs and tenant invite acceptance flows
--   - Initialize and keep occupancy snapshots synchronized with tenancy changes
-- ============================================================================

create schema if not exists app;

do $$ begin
  create type app.unit_occupancy_status_enum as enum (
    'vacant', 'invited', 'pending_confirmation', 'occupied', 'disputed'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type app.lease_agreement_status_enum as enum (
    'draft', 'pending_confirmation', 'confirmed', 'disputed',
    'active', 'expired', 'terminated_early', 'overstayed'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type app.lease_type_enum as enum ('fixed_term', 'month_to_month', 'informal');
exception when duplicate_object then null; end $$;

do $$ begin
  create type app.lease_confirmation_status_enum as enum (
    'awaiting_tenant', 'confirmed', 'disputed'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type app.lease_billing_cycle_enum as enum (
    'weekly', 'monthly', 'quarterly', 'semi_annual', 'annual'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type app.tenant_invitation_status_enum as enum (
    'pending_delivery', 'pending', 'sent', 'opened',
    'signup_started', 'accepted', 'expired', 'cancelled'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type app.tenant_invitation_delivery_channel_enum as enum ('email', 'sms');
exception when duplicate_object then null; end $$;

do $$ begin
  create type app.unit_tenancy_status_enum as enum (
    'pending_agreement', 'scheduled', 'active', 'ended', 'cancelled'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type app.unit_occupancy_dashboard_series_enum as enum (
    'occupancy_trend', 'vacancy_turnover_trend'
  );
exception when duplicate_object then null; end $$;

insert into app.lookup_audit_action_types (code, label, sort_order)
values
  ('LEASE_CAPTURED', 'Lease Captured', 160),
  ('TENANT_INVITE_SENT', 'Tenant Invite Sent', 161),
  ('LEASE_CONFIRMATION_UPDATED', 'Lease Confirmation Updated', 162),
  ('OCCUPANCY_STATUS_UPDATED', 'Occupancy Status Updated', 163)
on conflict (code) do update
set label = excluded.label, sort_order = excluded.sort_order;

create table if not exists app.lease_agreements (
  id uuid primary key default gen_random_uuid(),
  lease_chain_id uuid not null default gen_random_uuid(),
  version_no integer not null default 1,
  property_id uuid not null references app.properties(id) on delete cascade,
  unit_id uuid not null references app.units(id) on delete cascade,
  tenant_user_id uuid references auth.users(id) on delete set null,
  tenant_name text,
  tenant_phone text,
  entered_by_user_id uuid not null references auth.users(id) on delete restrict,
  lease_type app.lease_type_enum not null,
  start_date date not null,
  end_date date,
  billing_cycle app.lease_billing_cycle_enum not null default 'monthly',
  rent_amount numeric(12, 2) not null,
  currency_code text not null default 'KES',
  status app.lease_agreement_status_enum not null default 'draft',
  confirmation_status app.lease_confirmation_status_enum not null default 'awaiting_tenant',
  tenant_confirmed_at timestamptz,
  tenant_disputed_at timestamptz,
  tenant_response_notes text,
  agreement_notes text,
  terms_snapshot jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint uq_lease_agreements_chain_version unique (lease_chain_id, version_no),
  constraint chk_lease_agreements_version_no check (version_no > 0),
  constraint chk_lease_agreements_rent_amount check (rent_amount >= 0),
  constraint chk_lease_agreements_currency_code check (char_length(trim(currency_code)) = 3),
  constraint chk_lease_agreements_tenant_phone_len
    check (tenant_phone is null or char_length(trim(tenant_phone)) between 7 and 32),
  constraint chk_lease_agreements_tenant_name_len
    check (tenant_name is null or char_length(trim(tenant_name)) between 2 and 160),
  constraint chk_lease_agreements_dates
    check (
      (lease_type = 'fixed_term' and end_date is not null and end_date > start_date)
      or (lease_type <> 'fixed_term' and (end_date is null or end_date > start_date))
    )
);

create table if not exists app.tenant_invitations (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references app.properties(id) on delete cascade,
  unit_id uuid not null references app.units(id) on delete cascade,
  lease_agreement_id uuid not null references app.lease_agreements(id) on delete restrict,
  invited_by_user_id uuid not null references auth.users(id) on delete restrict,
  linked_user_id uuid references auth.users(id) on delete set null,
  invited_phone_number text,
  invited_email text,
  invited_name text,
  delivery_channel app.tenant_invitation_delivery_channel_enum not null default 'email',
  token_hash text not null,
  status app.tenant_invitation_status_enum not null default 'pending_delivery',
  sent_at timestamptz,
  opened_at timestamptz,
  signup_started_at timestamptz,
  expires_at timestamptz not null,
  accepted_at timestamptz,
  cancelled_at timestamptz,
  resent_count integer not null default 0,
  last_resent_at timestamptz,
  delivery_attempt_count integer not null default 0,
  last_delivery_error text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint uq_tenant_invitations_lease unique (lease_agreement_id),
  constraint chk_tenant_invitations_phone_len
    check (invited_phone_number is null or char_length(trim(invited_phone_number)) between 7 and 32),
  constraint chk_tenant_invitations_email_len
    check (invited_email is null or char_length(trim(invited_email)) between 5 and 320),
  constraint chk_tenant_invitations_name_len
    check (invited_name is null or char_length(trim(invited_name)) between 2 and 160),
  constraint chk_tenant_invitations_resent_count check (resent_count >= 0),
  constraint chk_tenant_invitations_delivery_attempt_count check (delivery_attempt_count >= 0),
  constraint chk_tenant_invitations_email_or_phone
    check (invited_email is not null or invited_phone_number is not null),
  constraint chk_tenant_invitations_delivery_identity
    check (
      (delivery_channel = 'email' and invited_email is not null)
      or (delivery_channel = 'sms' and invited_phone_number is not null)
    )
);

create table if not exists app.unit_occupancy_snapshots (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references app.properties(id) on delete cascade,
  unit_id uuid not null unique references app.units(id) on delete cascade,
  occupancy_status app.unit_occupancy_status_enum not null default 'vacant',
  current_lease_agreement_id uuid references app.lease_agreements(id) on delete set null,
  current_tenant_invitation_id uuid references app.tenant_invitations(id) on delete set null,
  current_tenant_user_id uuid references auth.users(id) on delete set null,
  current_tenant_name text,
  current_tenant_phone text,
  vacant_since timestamptz,
  occupancy_started_at timestamptz,
  last_occupied_at timestamptz,
  last_vacancy_started_at timestamptz,
  last_vacancy_ended_at timestamptz,
  last_vacancy_duration_days integer,
  last_status_changed_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint chk_unit_occupancy_snapshots_tenant_phone_len
    check (current_tenant_phone is null or char_length(trim(current_tenant_phone)) between 7 and 32),
  constraint chk_unit_occupancy_snapshots_tenant_name_len
    check (current_tenant_name is null or char_length(trim(current_tenant_name)) between 2 and 160),
  constraint chk_unit_occupancy_snapshots_vacancy_duration_non_negative
    check (last_vacancy_duration_days is null or last_vacancy_duration_days >= 0)
);

create table if not exists app.unit_tenancies (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references app.properties(id) on delete cascade,
  unit_id uuid not null references app.units(id) on delete cascade,
  lease_agreement_id uuid not null references app.lease_agreements(id) on delete restrict,
  tenant_invitation_id uuid references app.tenant_invitations(id) on delete set null,
  tenant_user_id uuid not null references auth.users(id) on delete restrict,
  status app.unit_tenancy_status_enum not null default 'pending_agreement',
  starts_on date not null,
  ends_on date,
  activated_at timestamptz,
  ended_at timestamptz,
  created_by_user_id uuid references auth.users(id) on delete set null,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint chk_unit_tenancies_dates check (ends_on is null or ends_on > starts_on)
);

create table if not exists app.unit_occupancy_dashboard_chart_points (
  id uuid primary key default gen_random_uuid(),
  property_id uuid references app.properties(id) on delete cascade,
  series_kind app.unit_occupancy_dashboard_series_enum not null,
  label text not null,
  sort_order integer not null,
  occupied_units integer,
  occupancy_rate numeric(5,2),
  vacant_units integer,
  turnover_count integer,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint chk_unit_occupancy_dashboard_chart_points_label_len
    check (char_length(trim(label)) between 1 and 40),
  constraint chk_unit_occupancy_dashboard_chart_points_sort_order
    check (sort_order > 0),
  constraint chk_unit_occupancy_dashboard_chart_points_occupied_units
    check (occupied_units is null or occupied_units >= 0),
  constraint chk_unit_occupancy_dashboard_chart_points_occupancy_rate
    check (occupancy_rate is null or (occupancy_rate >= 0 and occupancy_rate <= 100)),
  constraint chk_unit_occupancy_dashboard_chart_points_vacant_units
    check (vacant_units is null or vacant_units >= 0),
  constraint chk_unit_occupancy_dashboard_chart_points_turnover_count
    check (turnover_count is null or turnover_count >= 0),
  constraint chk_unit_occupancy_dashboard_chart_points_payload
    check (
      (
        series_kind = 'occupancy_trend'
        and occupied_units is not null
        and occupancy_rate is not null
        and vacant_units is null
        and turnover_count is null
      )
      or (
        series_kind = 'vacancy_turnover_trend'
        and vacant_units is not null
        and turnover_count is not null
        and occupied_units is null
        and occupancy_rate is null
      )
    )
);

drop trigger if exists trg_lease_agreements_updated_at on app.lease_agreements;
create trigger trg_lease_agreements_updated_at
before update on app.lease_agreements for each row execute function app.set_updated_at();

drop trigger if exists trg_tenant_invitations_updated_at on app.tenant_invitations;
create trigger trg_tenant_invitations_updated_at
before update on app.tenant_invitations for each row execute function app.set_updated_at();

drop trigger if exists trg_unit_occupancy_snapshots_updated_at on app.unit_occupancy_snapshots;
create trigger trg_unit_occupancy_snapshots_updated_at
before update on app.unit_occupancy_snapshots for each row execute function app.set_updated_at();

drop trigger if exists trg_unit_tenancies_updated_at on app.unit_tenancies;
create trigger trg_unit_tenancies_updated_at
before update on app.unit_tenancies for each row execute function app.set_updated_at();

drop trigger if exists trg_unit_occupancy_dashboard_chart_points_updated_at on app.unit_occupancy_dashboard_chart_points;
create trigger trg_unit_occupancy_dashboard_chart_points_updated_at
before update on app.unit_occupancy_dashboard_chart_points
for each row execute function app.set_updated_at();

create index if not exists idx_lease_agreements_property on app.lease_agreements (property_id);
create index if not exists idx_lease_agreements_unit on app.lease_agreements (unit_id);
create index if not exists idx_lease_agreements_status on app.lease_agreements (status);
create index if not exists idx_lease_agreements_confirmation_status on app.lease_agreements (confirmation_status);
create index if not exists idx_lease_agreements_end_date on app.lease_agreements (end_date) where end_date is not null;
create unique index if not exists uq_lease_agreements_unit_open_lifecycle
  on app.lease_agreements (unit_id)
  where status in ('pending_confirmation', 'confirmed', 'active', 'disputed');

create index if not exists idx_tenant_invitations_property_status on app.tenant_invitations (property_id, status);
create index if not exists idx_tenant_invitations_unit_status on app.tenant_invitations (unit_id, status);
create index if not exists idx_tenant_invitations_invited_email
  on app.tenant_invitations (lower(invited_email))
  where invited_email is not null;
create unique index if not exists uq_tenant_invitations_unit_live
  on app.tenant_invitations (unit_id)
  where status in ('pending_delivery', 'pending', 'sent', 'opened', 'signup_started');
create unique index if not exists uq_tenant_invitations_token_hash on app.tenant_invitations (token_hash);
create index if not exists idx_tenant_invitations_expires_at on app.tenant_invitations (expires_at);

create index if not exists idx_unit_occupancy_snapshots_property on app.unit_occupancy_snapshots (property_id);
create index if not exists idx_unit_occupancy_snapshots_status on app.unit_occupancy_snapshots (occupancy_status);
create index if not exists idx_unit_occupancy_snapshots_vacant_since
  on app.unit_occupancy_snapshots (vacant_since) where vacant_since is not null;
create index if not exists idx_unit_occupancy_snapshots_last_occupied_at
  on app.unit_occupancy_snapshots (last_occupied_at) where last_occupied_at is not null;

create index if not exists idx_unit_tenancies_property_status on app.unit_tenancies (property_id, status);
create index if not exists idx_unit_tenancies_unit_status on app.unit_tenancies (unit_id, status);
create index if not exists idx_unit_tenancies_tenant_user on app.unit_tenancies (tenant_user_id, status);
create unique index if not exists uq_unit_tenancies_unit_open
  on app.unit_tenancies (unit_id)
  where status in ('pending_agreement', 'scheduled', 'active');
create unique index if not exists uq_unit_tenancies_lease on app.unit_tenancies (lease_agreement_id);

create index if not exists idx_unit_occupancy_dashboard_chart_points_series_kind
  on app.unit_occupancy_dashboard_chart_points (series_kind);
create index if not exists idx_unit_occupancy_dashboard_chart_points_property_series
  on app.unit_occupancy_dashboard_chart_points (property_id, series_kind, sort_order);
create unique index if not exists uq_unit_occupancy_dashboard_chart_points_property_series
  on app.unit_occupancy_dashboard_chart_points (property_id, series_kind, sort_order)
  where property_id is not null;
create unique index if not exists uq_unit_occupancy_dashboard_chart_points_global_series
  on app.unit_occupancy_dashboard_chart_points (series_kind, sort_order)
  where property_id is null;

revoke all on table app.lease_agreements from public, anon, authenticated;
revoke all on table app.tenant_invitations from public, anon, authenticated;
revoke all on table app.unit_occupancy_snapshots from public, anon, authenticated;
revoke all on table app.unit_tenancies from public, anon, authenticated;
revoke all on table app.unit_occupancy_dashboard_chart_points from public, anon, authenticated;

create or replace function app.has_tenancy_management_access(p_property_id uuid)
returns boolean
language sql
stable
security definer
set search_path = app, public
as $$
  select
    app.is_property_workspace_owner(p_property_id)
    or exists (
      select 1
      from app.property_memberships pm
      join app.roles r on r.id = pm.role_id and r.deleted_at is null
      join app.lookup_domain_scopes ds on ds.id = pm.domain_scope_id and ds.deleted_at is null
      where pm.property_id = p_property_id
        and pm.user_id = auth.uid()
        and pm.status = 'active'
        and pm.deleted_at is null
        and (pm.ends_at is null or pm.ends_at > now())
        and (
          upper(coalesce(r.key, '')) in ('OWNER', 'PROPERTY_MANAGER')
          or ds.code in ('TENANCY', 'FULL_PROPERTY')
        )
    );
$$;

create or replace function app.assert_tenancy_management_access(p_property_id uuid)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;
  if not app.has_tenancy_management_access(p_property_id) then
    raise exception 'Forbidden: requires owner or tenancy management access';
  end if;
end;
$$;

create or replace function app.get_tenancy_accessible_property_ids(p_property_id uuid default null)
returns table (property_id uuid)
language sql
stable
security definer
set search_path = app, public
as $$
  select p.id
  from app.properties p
  where p.deleted_at is null
    and p.status = 'active'
    and (p_property_id is null or p.id = p_property_id)
    and app.has_tenancy_management_access(p.id);
$$;

create or replace function app.to_monthly_rent_amount(
  p_amount numeric,
  p_billing_cycle app.lease_billing_cycle_enum
)
returns numeric
language sql
immutable
security definer
set search_path = app, public
as $$
  select case coalesce(p_billing_cycle, 'monthly'::app.lease_billing_cycle_enum)
    when 'weekly' then round((coalesce(p_amount, 0) * 52.0 / 12.0)::numeric, 2)
    when 'monthly' then round(coalesce(p_amount, 0)::numeric, 2)
    when 'quarterly' then round((coalesce(p_amount, 0) / 3.0)::numeric, 2)
    when 'semi_annual' then round((coalesce(p_amount, 0) / 6.0)::numeric, 2)
    when 'annual' then round((coalesce(p_amount, 0) / 12.0)::numeric, 2)
  end;
$$;

create or replace function app.get_effective_lease_status(
  p_status app.lease_agreement_status_enum,
  p_confirmation_status app.lease_confirmation_status_enum,
  p_start_date date,
  p_end_date date
)
returns app.lease_agreement_status_enum
language plpgsql
stable
security definer
set search_path = app, public
as $$
declare
  v_status app.lease_agreement_status_enum := coalesce(p_status, 'draft'::app.lease_agreement_status_enum);
begin
  if coalesce(p_confirmation_status, 'awaiting_tenant'::app.lease_confirmation_status_enum) = 'disputed' then
    return 'disputed';
  end if;
  if v_status in ('terminated_early', 'overstayed', 'disputed') then
    return v_status;
  end if;
  if p_end_date is not null and p_end_date < current_date then
    return 'expired';
  end if;
  if v_status = 'confirmed' and p_start_date <= current_date then
    return 'active';
  end if;
  return v_status;
end;
$$;

create or replace function app.get_effective_tenant_invitation_status(
  p_status app.tenant_invitation_status_enum,
  p_expires_at timestamptz,
  p_accepted_at timestamptz,
  p_cancelled_at timestamptz
)
returns app.tenant_invitation_status_enum
language plpgsql
stable
security definer
set search_path = app, public
as $$
begin
  if p_accepted_at is not null or p_status = 'accepted' then
    return 'accepted';
  end if;
  if p_cancelled_at is not null or p_status = 'cancelled' then
    return 'cancelled';
  end if;
  if p_status in ('pending_delivery', 'pending', 'sent', 'opened', 'signup_started')
     and p_expires_at <= now() then
    return 'expired';
  end if;
  return coalesce(p_status, 'pending'::app.tenant_invitation_status_enum);
end;
$$;

create or replace function app.get_dashboard_tenant_invitation_status(
  p_status app.tenant_invitation_status_enum
)
returns text
language sql
immutable
security definer
set search_path = app, public
as $$
  select case p_status
    when 'pending_delivery'::app.tenant_invitation_status_enum then 'pending'
    when 'opened'::app.tenant_invitation_status_enum then 'sent'
    when 'signup_started'::app.tenant_invitation_status_enum then 'sent'
    else p_status::text
  end;
$$;

create or replace function app.sync_related_property_id_from_unit()
returns trigger
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_property_id uuid;
begin
  if new.unit_id is null then
    return new;
  end if;

  select u.property_id
    into v_property_id
  from app.units u
  where u.id = new.unit_id
    and u.deleted_at is null
  limit 1;

  if v_property_id is null then
    raise exception 'Unit not found or deleted';
  end if;

  new.property_id := v_property_id;
  return new;
end;
$$;

drop trigger if exists trg_lease_agreements_property_sync on app.lease_agreements;
create trigger trg_lease_agreements_property_sync
before insert or update of unit_id, property_id on app.lease_agreements
for each row execute function app.sync_related_property_id_from_unit();

drop trigger if exists trg_tenant_invitations_property_sync on app.tenant_invitations;
create trigger trg_tenant_invitations_property_sync
before insert or update of unit_id, property_id on app.tenant_invitations
for each row execute function app.sync_related_property_id_from_unit();

drop trigger if exists trg_unit_occupancy_snapshots_property_sync on app.unit_occupancy_snapshots;
create trigger trg_unit_occupancy_snapshots_property_sync
before insert or update of unit_id, property_id on app.unit_occupancy_snapshots
for each row execute function app.sync_related_property_id_from_unit();

drop trigger if exists trg_unit_tenancies_property_sync on app.unit_tenancies;
create trigger trg_unit_tenancies_property_sync
before insert or update of unit_id, property_id on app.unit_tenancies
for each row execute function app.sync_related_property_id_from_unit();

create or replace function app.ensure_unit_occupancy_snapshot_exists(
  p_unit_id uuid,
  p_actor_user_id uuid default auth.uid()
)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_unit record;
begin
  select u.property_id, p.status as property_status, p.onboarding_completed_at
    into v_unit
  from app.units u
  join app.properties p on p.id = u.property_id
  where u.id = p_unit_id
    and u.deleted_at is null
    and p.deleted_at is null
  limit 1;

  if v_unit.property_id is null then
    raise exception 'Unit not found or deleted';
  end if;

  insert into app.unit_occupancy_snapshots (
    property_id, unit_id, occupancy_status, vacant_since, last_status_changed_at, created_by
  )
  values (
    v_unit.property_id,
    p_unit_id,
    'vacant',
    case
      when v_unit.property_status = 'active' or v_unit.onboarding_completed_at is not null
        then coalesce(v_unit.onboarding_completed_at, now())
      else null
    end,
    now(),
    p_actor_user_id
  )
  on conflict (unit_id) do nothing;
end;
$$;

create or replace function app.create_unit_occupancy_snapshot_from_unit()
returns trigger
language plpgsql
security definer
set search_path = app, public
as $$
begin
  if new.deleted_at is null then
    perform app.ensure_unit_occupancy_snapshot_exists(new.id, auth.uid());
  end if;
  return new;
end;
$$;

drop trigger if exists trg_units_create_occupancy_snapshot on app.units;
create trigger trg_units_create_occupancy_snapshot
after insert on app.units
for each row execute function app.create_unit_occupancy_snapshot_from_unit();

create or replace function app.sync_unit_occupancy_snapshot(
  p_unit_id uuid,
  p_actor_user_id uuid default auth.uid()
)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_unit record;
  v_snapshot app.unit_occupancy_snapshots%rowtype;
  v_lease record;
  v_invite record;
  v_previous_status app.unit_occupancy_status_enum;
  v_next_status app.unit_occupancy_status_enum := 'vacant';
  v_next_lease_id uuid;
  v_next_invite_id uuid;
  v_next_tenant_user_id uuid;
  v_next_tenant_name text;
  v_next_tenant_phone text;
  v_next_vacant_since timestamptz;
  v_next_occupancy_started_at timestamptz;
  v_next_last_occupied_at timestamptz;
  v_next_last_vacancy_started_at timestamptz;
  v_next_last_vacancy_ended_at timestamptz;
  v_next_last_vacancy_duration_days integer;
  v_next_last_status_changed_at timestamptz;
  v_was_vacancy boolean;
  v_is_vacancy boolean;
  v_now timestamptz := now();
  v_action_id uuid;
begin
  perform app.ensure_unit_occupancy_snapshot_exists(p_unit_id, p_actor_user_id);

  select u.property_id, p.status as property_status, p.onboarding_completed_at
    into v_unit
  from app.units u
  join app.properties p on p.id = u.property_id
  where u.id = p_unit_id
    and u.deleted_at is null
    and p.deleted_at is null
  limit 1;

  if v_unit.property_id is null then
    raise exception 'Unit not found or deleted';
  end if;

  select *
    into v_snapshot
  from app.unit_occupancy_snapshots s
  where s.unit_id = p_unit_id
  limit 1;

  select
    l.id,
    l.tenant_user_id,
    l.tenant_name,
    l.tenant_phone,
    l.start_date,
    l.end_date,
    l.status,
    l.confirmation_status,
    app.get_effective_lease_status(l.status, l.confirmation_status, l.start_date, l.end_date) as effective_status
  into v_lease
  from app.lease_agreements l
  where l.unit_id = p_unit_id
  order by
    case app.get_effective_lease_status(l.status, l.confirmation_status, l.start_date, l.end_date)
      when 'disputed' then 1
      when 'active' then 2
      when 'confirmed' then 3
      when 'pending_confirmation' then 4
      when 'draft' then 5
      when 'expired' then 6
      when 'terminated_early' then 7
      when 'overstayed' then 8
      else 9
    end,
    l.updated_at desc,
    l.created_at desc
  limit 1;

  select
    i.id,
    i.linked_user_id,
    i.invited_name,
    i.invited_phone_number,
    i.status,
    app.get_effective_tenant_invitation_status(i.status, i.expires_at, i.accepted_at, i.cancelled_at) as effective_status
  into v_invite
  from app.tenant_invitations i
  where i.unit_id = p_unit_id
  order by
    case app.get_effective_tenant_invitation_status(i.status, i.expires_at, i.accepted_at, i.cancelled_at)
      when 'signup_started' then 1
      when 'opened' then 2
      when 'sent' then 3
      when 'pending' then 4
      when 'pending_delivery' then 5
      when 'accepted' then 6
      when 'expired' then 7
      when 'cancelled' then 8
      else 9
    end,
    i.updated_at desc,
    i.created_at desc
  limit 1;

  if coalesce(v_lease.effective_status::text, '') = 'disputed' then
    v_next_status := 'disputed';
    v_next_lease_id := v_lease.id;
  elsif coalesce(v_lease.effective_status::text, '') = 'active' then
    v_next_status := 'occupied';
    v_next_lease_id := v_lease.id;
  elsif coalesce(v_lease.effective_status::text, '') in ('pending_confirmation', 'confirmed') then
    v_next_lease_id := v_lease.id;

    if coalesce(v_invite.effective_status::text, '') in ('pending_delivery', 'pending', 'sent', 'opened', 'signup_started') then
      if v_invite.linked_user_id is not null
         or v_lease.tenant_user_id is not null
         or coalesce(v_lease.effective_status::text, '') = 'confirmed'
         or coalesce(v_invite.effective_status::text, '') in ('opened', 'signup_started') then
        v_next_status := 'pending_confirmation';
      else
        v_next_status := 'invited';
      end if;
    else
      v_next_status := 'pending_confirmation';
    end if;
  elsif coalesce(v_invite.effective_status::text, '') in ('pending_delivery', 'pending', 'sent', 'opened', 'signup_started') then
    v_next_invite_id := v_invite.id;

    if v_invite.linked_user_id is not null
       or coalesce(v_invite.effective_status::text, '') in ('opened', 'signup_started') then
      v_next_status := 'pending_confirmation';
    else
      v_next_status := 'invited';
    end if;
  else
    v_next_status := 'vacant';
  end if;

  if v_next_invite_id is null and coalesce(v_invite.effective_status::text, '') in ('pending_delivery', 'pending', 'sent', 'opened', 'signup_started') then
    v_next_invite_id := v_invite.id;
  end if;

  if v_next_lease_id is null and coalesce(v_lease.effective_status::text, '') in ('pending_confirmation', 'confirmed', 'active', 'disputed') then
    v_next_lease_id := v_lease.id;
  end if;

  v_next_tenant_user_id := coalesce(v_lease.tenant_user_id, v_invite.linked_user_id);
  v_next_tenant_name := coalesce(
    nullif(trim(v_lease.tenant_name), ''),
    nullif(trim(v_invite.invited_name), ''),
    nullif(trim(v_snapshot.current_tenant_name), '')
  );
  v_next_tenant_phone := coalesce(
    nullif(trim(v_lease.tenant_phone), ''),
    nullif(trim(v_invite.invited_phone_number), ''),
    nullif(trim(v_snapshot.current_tenant_phone), '')
  );

  v_previous_status := v_snapshot.occupancy_status;
  v_was_vacancy := v_snapshot.occupancy_status in ('vacant', 'invited', 'pending_confirmation');
  v_is_vacancy := v_next_status in ('vacant', 'invited', 'pending_confirmation');

  v_next_vacant_since := v_snapshot.vacant_since;
  v_next_occupancy_started_at := v_snapshot.occupancy_started_at;
  v_next_last_occupied_at := v_snapshot.last_occupied_at;
  v_next_last_vacancy_started_at := v_snapshot.last_vacancy_started_at;
  v_next_last_vacancy_ended_at := v_snapshot.last_vacancy_ended_at;
  v_next_last_vacancy_duration_days := v_snapshot.last_vacancy_duration_days;
  v_next_last_status_changed_at := coalesce(v_snapshot.last_status_changed_at, v_now);

  if v_is_vacancy then
    if not v_was_vacancy then
      v_next_vacant_since := case
        when v_unit.property_status = 'active' or v_unit.onboarding_completed_at is not null then v_now
        else null
      end;
    else
      v_next_vacant_since := coalesce(
        v_snapshot.vacant_since,
        case
          when v_unit.property_status = 'active' or v_unit.onboarding_completed_at is not null then v_now
          else null
        end
      );
    end if;

    if v_next_status <> 'disputed' then
      v_next_occupancy_started_at := null;
    end if;
  else
    if v_was_vacancy and v_snapshot.vacant_since is not null then
      v_next_last_vacancy_started_at := v_snapshot.vacant_since;
      v_next_last_vacancy_ended_at := v_now;
      v_next_last_vacancy_duration_days := greatest(
        0,
        floor(extract(epoch from (v_now - v_snapshot.vacant_since)) / 86400)
      )::int;
    end if;
    v_next_vacant_since := null;
  end if;

  if v_next_status = 'occupied' then
    v_next_occupancy_started_at := coalesce(
      case when v_lease.start_date is not null then v_lease.start_date::timestamptz else null end,
      v_snapshot.occupancy_started_at,
      v_now
    );

    if v_snapshot.occupancy_status is distinct from 'occupied' then
      v_next_last_occupied_at := v_now;
    end if;
  elsif v_next_status <> 'disputed' then
    v_next_occupancy_started_at := null;
  end if;

  if v_snapshot.occupancy_status is distinct from v_next_status then
    v_next_last_status_changed_at := v_now;
  end if;

  update app.unit_occupancy_snapshots
     set occupancy_status = v_next_status,
         current_lease_agreement_id = v_next_lease_id,
         current_tenant_invitation_id = v_next_invite_id,
         current_tenant_user_id = v_next_tenant_user_id,
         current_tenant_name = v_next_tenant_name,
         current_tenant_phone = v_next_tenant_phone,
         vacant_since = v_next_vacant_since,
         occupancy_started_at = v_next_occupancy_started_at,
         last_occupied_at = v_next_last_occupied_at,
         last_vacancy_started_at = v_next_last_vacancy_started_at,
         last_vacancy_ended_at = v_next_last_vacancy_ended_at,
         last_vacancy_duration_days = v_next_last_vacancy_duration_days,
         last_status_changed_at = v_next_last_status_changed_at,
         updated_at = v_now
   where unit_id = p_unit_id
   returning * into v_snapshot;

  if v_previous_status is distinct from v_next_status then
    v_action_id := app.get_audit_action_id_by_code('OCCUPANCY_STATUS_UPDATED');

    if v_action_id is not null then
      insert into app.audit_logs (
        property_id, unit_id, actor_user_id, action_type_id, payload
      )
      values (
        v_unit.property_id,
        p_unit_id,
        p_actor_user_id,
        v_action_id,
        jsonb_build_object(
          'from_status', coalesce(v_previous_status::text, 'unknown'),
          'to_status', v_next_status::text,
          'lease_agreement_id', v_next_lease_id,
          'tenant_invitation_id', v_next_invite_id
        )
      );
    end if;
  end if;
end;
$$;

create or replace function app.queue_unit_occupancy_snapshot_sync_from_row()
returns trigger
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_unit_id uuid;
begin
  if tg_op = 'DELETE' then
    v_unit_id := old.unit_id;
  else
    v_unit_id := new.unit_id;
  end if;

  if v_unit_id is not null then
    perform app.sync_unit_occupancy_snapshot(v_unit_id, auth.uid());
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_lease_agreements_sync_snapshot on app.lease_agreements;
create trigger trg_lease_agreements_sync_snapshot
after insert or update or delete on app.lease_agreements
for each row execute function app.queue_unit_occupancy_snapshot_sync_from_row();

drop trigger if exists trg_tenant_invitations_sync_snapshot on app.tenant_invitations;
create trigger trg_tenant_invitations_sync_snapshot
after insert or update or delete on app.tenant_invitations
for each row execute function app.queue_unit_occupancy_snapshot_sync_from_row();

drop trigger if exists trg_unit_tenancies_sync_snapshot on app.unit_tenancies;
create trigger trg_unit_tenancies_sync_snapshot
after insert or update or delete on app.unit_tenancies
for each row execute function app.queue_unit_occupancy_snapshot_sync_from_row();

create or replace function app.expire_tenant_invitations(
  p_property_id uuid default null,
  p_unit_id uuid default null
)
returns integer
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_unit_ids uuid[] := array[]::uuid[];
  v_updated_rows integer := 0;
  v_unit_id uuid;
begin
  with expired as (
    update app.tenant_invitations i
       set status = 'expired', updated_at = now()
     where i.status in ('pending_delivery', 'pending', 'sent', 'opened', 'signup_started')
       and i.expires_at <= now()
       and (p_property_id is null or i.property_id = p_property_id)
       and (p_unit_id is null or i.unit_id = p_unit_id)
    returning i.unit_id
  )
  select coalesce(array_agg(distinct unit_id), array[]::uuid[]), count(*)
    into v_unit_ids, v_updated_rows
  from expired;

  foreach v_unit_id in array v_unit_ids loop
    perform app.sync_unit_occupancy_snapshot(v_unit_id, null);
  end loop;

  return coalesce(v_updated_rows, 0);
end;
$$;

create or replace function app.refresh_lease_agreement_statuses(
  p_property_id uuid default null,
  p_unit_id uuid default null
)
returns integer
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_unit_ids uuid[] := array[]::uuid[];
  v_updated_rows integer := 0;
  v_unit_id uuid;
begin
  with updated_rows as (
    update app.lease_agreements l
       set status = app.get_effective_lease_status(
             l.status,
             l.confirmation_status,
             l.start_date,
             l.end_date
           ),
           updated_at = now()
     where (p_property_id is null or l.property_id = p_property_id)
       and (p_unit_id is null or l.unit_id = p_unit_id)
       and app.get_effective_lease_status(
             l.status,
             l.confirmation_status,
             l.start_date,
             l.end_date
           ) is distinct from l.status
    returning l.unit_id
  )
  select coalesce(array_agg(distinct unit_id), array[]::uuid[]), count(*)
    into v_unit_ids, v_updated_rows
  from updated_rows;

  foreach v_unit_id in array v_unit_ids loop
    perform app.sync_unit_occupancy_snapshot(v_unit_id, null);
  end loop;

  return coalesce(v_updated_rows, 0);
end;
$$;

create or replace function app.refresh_unit_tenancy_statuses(
  p_property_id uuid default null,
  p_unit_id uuid default null
)
returns integer
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_unit_ids uuid[] := array[]::uuid[];
  v_updated_rows integer := 0;
  v_unit_id uuid;
begin
  with updated_rows as (
    update app.unit_tenancies t
       set status = case
             when t.status <> 'cancelled'
                  and (t.ended_at is not null or (t.ends_on is not null and t.ends_on < current_date))
               then 'ended'::app.unit_tenancy_status_enum
             when t.status = 'scheduled'
                  and t.starts_on <= current_date
               then 'active'::app.unit_tenancy_status_enum
             else t.status
           end,
           activated_at = case
             when t.status = 'scheduled' and t.starts_on <= current_date and t.activated_at is null
               then now()
             else t.activated_at
           end,
           ended_at = case
             when t.status <> 'cancelled'
                  and (t.ended_at is not null or (t.ends_on is not null and t.ends_on < current_date))
               then coalesce(t.ended_at, now())
             else t.ended_at
           end,
           updated_at = now()
     where (p_property_id is null or t.property_id = p_property_id)
       and (p_unit_id is null or t.unit_id = p_unit_id)
       and (
         (t.status = 'scheduled' and t.starts_on <= current_date)
         or (
           t.status <> 'cancelled'
           and (t.ended_at is not null or (t.ends_on is not null and t.ends_on < current_date))
           and t.status <> 'ended'
         )
       )
    returning t.unit_id
  )
  select coalesce(array_agg(distinct unit_id), array[]::uuid[]), count(*)
    into v_unit_ids, v_updated_rows
  from updated_rows;

  foreach v_unit_id in array v_unit_ids loop
    perform app.sync_unit_occupancy_snapshot(v_unit_id, null);
  end loop;

  return coalesce(v_updated_rows, 0);
end;
$$;

create or replace function app.refresh_tenancy_dashboard_state(p_property_id uuid default null)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_property_id uuid;
begin
  for v_property_id in
    select property_id
    from app.get_tenancy_accessible_property_ids(p_property_id)
  loop
    perform app.expire_tenant_invitations(v_property_id, null);
    perform app.refresh_lease_agreement_statuses(v_property_id, null);
    perform app.refresh_unit_tenancy_statuses(v_property_id, null);
  end loop;
end;
$$;

create or replace function app.enqueue_tenant_invitation_notifications(
  p_invitation_id uuid
)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_invite record;
  v_action_href text;
begin
  select
    i.id,
    i.property_id,
    i.unit_id,
    i.lease_agreement_id,
    coalesce(nullif(trim(p.display_name), ''), 'Untitled Property') as property_name,
    coalesce(nullif(trim(u.label), ''), 'Unlabelled Unit') as unit_label
  into v_invite
  from app.tenant_invitations i
  join app.properties p on p.id = i.property_id
  join app.units u on u.id = i.unit_id
  where i.id = p_invitation_id
  limit 1;

  if v_invite.id is null then
    raise exception 'Tenant invitation not found: %', p_invitation_id;
  end if;

  v_action_href := format('/owner/units?property=%s', v_invite.property_id);

  with recipient_pool as (
    select p.created_by as user_id
    from app.properties p
    where p.id = v_invite.property_id
      and p.deleted_at is null
    union
    select pm.user_id
    from app.property_memberships pm
    join app.roles r
      on r.id = pm.role_id
     and r.deleted_at is null
    join app.lookup_domain_scopes ds
      on ds.id = pm.domain_scope_id
     and ds.deleted_at is null
    where pm.property_id = v_invite.property_id
      and pm.deleted_at is null
      and pm.status = 'active'
      and (pm.ends_at is null or pm.ends_at > now())
      and (
        upper(coalesce(r.key, '')) in ('OWNER', 'PROPERTY_MANAGER')
        or ds.code in ('TENANCY', 'FULL_PROPERTY')
      )
  )
  insert into app.user_notifications (
    user_id,
    property_id,
    notification_type,
    title,
    message,
    metadata
  )
  select
    rp.user_id,
    v_invite.property_id,
    'tenant_invite_created',
    'Tenant invite issued',
    format('%s at %s now has a lease awaiting tenant confirmation.', v_invite.unit_label, v_invite.property_name),
    jsonb_build_object(
      'action_href', v_action_href,
      'actor_user_id', auth.uid(),
      'tenant_invitation_id', v_invite.id,
      'lease_agreement_id', v_invite.lease_agreement_id,
      'unit_id', v_invite.unit_id,
      'event', 'tenant_invite_created'
    )
  from recipient_pool rp
  where rp.user_id is not null;
end;
$$;

create or replace function app.create_tenant_invitation(
  p_unit_id uuid,
  p_tenant_phone text default null,
  p_tenant_email text default null,
  p_delivery_channel app.tenant_invitation_delivery_channel_enum default 'email',
  p_tenant_name text default null,
  p_lease_type app.lease_type_enum default 'fixed_term',
  p_start_date date default current_date,
  p_end_date date default null,
  p_rent_amount numeric default 0,
  p_notes text default null,
  p_billing_cycle app.lease_billing_cycle_enum default 'monthly',
  p_currency_code text default 'KES',
  p_expires_in_days integer default 7
)
returns jsonb
language plpgsql
security definer
set search_path = app, public, extensions
as $$
declare
  v_unit record;
  v_snapshot record;
  v_tenant_phone text;
  v_tenant_email text;
  v_tenant_name text;
  v_notes text;
  v_currency_code text;
  v_token text;
  v_expires_at timestamptz;
  v_lease_id uuid;
  v_invitation_id uuid;
  v_lease_action_id uuid;
  v_invite_action_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  v_tenant_phone := nullif(trim(coalesce(p_tenant_phone, '')), '');
  v_tenant_email := nullif(trim(lower(coalesce(p_tenant_email, ''))), '');
  v_tenant_name := nullif(trim(coalesce(p_tenant_name, '')), '');
  v_notes := nullif(trim(coalesce(p_notes, '')), '');
  v_currency_code := upper(coalesce(nullif(trim(p_currency_code), ''), 'KES'));
  v_expires_at := now() + make_interval(days => greatest(coalesce(p_expires_in_days, 7), 1));

  if p_delivery_channel = 'email' and v_tenant_email is null then
    raise exception 'Tenant email is required for email delivery';
  end if;
  if p_delivery_channel = 'sms' and v_tenant_phone is null then
    raise exception 'Tenant phone number is required for SMS delivery';
  end if;
  if p_rent_amount is null or p_rent_amount < 0 then
    raise exception 'Rent amount must be zero or greater';
  end if;

  select
    u.id as unit_id,
    u.property_id,
    coalesce(nullif(trim(u.label), ''), 'Unlabelled Unit') as unit_label,
    u.expected_rate,
    p.status as property_status,
    coalesce(nullif(trim(p.display_name), ''), 'Untitled Property') as property_name
  into v_unit
  from app.units u
  join app.properties p on p.id = u.property_id
  where u.id = p_unit_id
    and u.deleted_at is null
    and p.deleted_at is null
  limit 1;

  if v_unit.unit_id is null then
    raise exception 'Unit not found or deleted';
  end if;
  if v_unit.property_status <> 'active' then
    raise exception 'Tenant invites can only be created for active properties';
  end if;

  perform app.assert_tenancy_management_access(v_unit.property_id);
  perform app.expire_tenant_invitations(v_unit.property_id, p_unit_id);
  perform app.refresh_lease_agreement_statuses(v_unit.property_id, p_unit_id);
  perform app.refresh_unit_tenancy_statuses(v_unit.property_id, p_unit_id);
  perform app.ensure_unit_occupancy_snapshot_exists(p_unit_id, auth.uid());

  select occupancy_status into v_snapshot
  from app.unit_occupancy_snapshots
  where unit_id = p_unit_id
  limit 1;

  if coalesce(v_snapshot.occupancy_status::text, '') in ('occupied', 'disputed') then
    raise exception 'This unit is not currently available for a new tenant invite';
  end if;

  if exists (
    select 1
    from app.tenant_invitations i
    where i.unit_id = p_unit_id
      and app.get_effective_tenant_invitation_status(i.status, i.expires_at, i.accepted_at, i.cancelled_at)
          in ('pending_delivery', 'pending', 'sent', 'opened', 'signup_started')
  ) then
    raise exception 'A live tenant invitation already exists for this unit';
  end if;

  if exists (
    select 1
    from app.lease_agreements l
    where l.unit_id = p_unit_id
      and app.get_effective_lease_status(l.status, l.confirmation_status, l.start_date, l.end_date)
          in ('pending_confirmation', 'confirmed', 'active', 'disputed')
  ) then
    raise exception 'A live lease agreement already exists for this unit';
  end if;

  if exists (
    select 1
    from app.unit_tenancies t
    where t.unit_id = p_unit_id
      and t.status in ('pending_agreement', 'scheduled', 'active')
  ) then
    raise exception 'This unit already has an open tenancy';
  end if;

  if p_lease_type = 'fixed_term' and (p_end_date is null or p_end_date <= p_start_date) then
    raise exception 'Fixed-term leases require an end date after the start date';
  end if;
  if p_lease_type <> 'fixed_term' and p_end_date is not null and p_end_date <= p_start_date then
    raise exception 'Lease end date must be after the start date';
  end if;

  v_token := encode(extensions.gen_random_bytes(24), 'hex');

  insert into app.lease_agreements (
    property_id, unit_id, tenant_name, tenant_phone, entered_by_user_id, lease_type,
    start_date, end_date, billing_cycle, rent_amount, currency_code, status,
    confirmation_status, agreement_notes, terms_snapshot
  )
  values (
    v_unit.property_id,
    p_unit_id,
    v_tenant_name,
    v_tenant_phone,
    auth.uid(),
    p_lease_type,
    p_start_date,
    p_end_date,
    coalesce(p_billing_cycle, 'monthly'),
    p_rent_amount,
    v_currency_code,
    'pending_confirmation',
    'awaiting_tenant',
    v_notes,
    jsonb_build_object(
      'captured_from', 'owner_web_invite',
      'captured_at', now(),
      'expected_rate_at_capture', v_unit.expected_rate,
      'unit_label', v_unit.unit_label,
      'property_name', v_unit.property_name,
      'delivery_channel', p_delivery_channel::text,
      'tenant_email', v_tenant_email
    )
  )
  returning id into v_lease_id;

  insert into app.tenant_invitations (
    property_id, unit_id, lease_agreement_id, invited_by_user_id, invited_phone_number,
    invited_email, invited_name, token_hash, delivery_channel, status, sent_at,
    expires_at, metadata
  )
  values (
    v_unit.property_id,
    p_unit_id,
    v_lease_id,
    auth.uid(),
    v_tenant_phone,
    v_tenant_email,
    v_tenant_name,
    app.hash_token(v_token),
    p_delivery_channel,
    'sent',
    now(),
    v_expires_at,
    jsonb_build_object(
      'lease_type', p_lease_type::text,
      'lease_start_date', p_start_date,
      'lease_end_date', p_end_date,
      'rent_amount', p_rent_amount,
      'currency_code', v_currency_code,
      'billing_cycle', coalesce(p_billing_cycle, 'monthly')::text,
      'notes', v_notes
    )
  )
  returning id into v_invitation_id;

  perform app.sync_unit_occupancy_snapshot(p_unit_id, auth.uid());
  perform app.touch_property_activity(v_unit.property_id);
  perform app.enqueue_tenant_invitation_notifications(v_invitation_id);

  v_lease_action_id := app.get_audit_action_id_by_code('LEASE_CAPTURED');
  if v_lease_action_id is not null then
    insert into app.audit_logs (property_id, unit_id, actor_user_id, action_type_id, payload)
    values (
      v_unit.property_id,
      p_unit_id,
      auth.uid(),
      v_lease_action_id,
      jsonb_build_object(
        'lease_agreement_id', v_lease_id,
        'lease_type', p_lease_type::text,
        'billing_cycle', coalesce(p_billing_cycle, 'monthly')::text,
        'rent_amount', p_rent_amount,
        'currency_code', v_currency_code
      )
    );
  end if;

  v_invite_action_id := app.get_audit_action_id_by_code('TENANT_INVITE_SENT');
  if v_invite_action_id is not null then
    insert into app.audit_logs (property_id, unit_id, actor_user_id, action_type_id, payload)
    values (
      v_unit.property_id,
      p_unit_id,
      auth.uid(),
      v_invite_action_id,
      jsonb_build_object(
        'tenant_invitation_id', v_invitation_id,
        'lease_agreement_id', v_lease_id,
        'delivery_channel', p_delivery_channel::text,
        'expires_at', v_expires_at
      )
    );
  end if;

  return jsonb_build_object(
    'property_id', v_unit.property_id,
    'unit_id', p_unit_id,
    'lease_agreement_id', v_lease_id,
    'tenant_invitation_id', v_invitation_id,
    'status', 'sent',
    'delivery_channel', p_delivery_channel::text,
    'expires_at', v_expires_at,
    'token', v_token
  );
end;
$$;

create or replace function app.get_tenant_invitation_by_token(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_invite record;
  v_effective_status app.tenant_invitation_status_enum;
  v_response_status text;
begin
  if p_token is null or length(trim(p_token)) = 0 then
    raise exception 'Invitation token is required';
  end if;

  select
    i.id,
    i.property_id,
    i.unit_id,
    i.lease_agreement_id,
    i.invited_name,
    i.invited_email,
    i.invited_phone_number,
    i.delivery_channel,
    i.status,
    i.expires_at,
    i.accepted_at,
    i.cancelled_at,
    i.opened_at,
    i.signup_started_at,
    p.display_name as property_name,
    u.label as unit_label,
    l.lease_type,
    l.start_date,
    l.end_date,
    l.billing_cycle,
    l.rent_amount,
    l.currency_code,
    l.confirmation_status,
    l.status as lease_status
  into v_invite
  from app.tenant_invitations i
  join app.properties p on p.id = i.property_id
  join app.units u on u.id = i.unit_id
  join app.lease_agreements l on l.id = i.lease_agreement_id
  where i.token_hash = app.hash_token(trim(p_token))
  limit 1;

  if v_invite.id is null then
    raise exception 'Invitation not found';
  end if;

  v_effective_status := app.get_effective_tenant_invitation_status(
    v_invite.status, v_invite.expires_at, v_invite.accepted_at, v_invite.cancelled_at
  );

  if v_effective_status = 'expired' then
    raise exception 'Invitation has expired';
  end if;
  if v_effective_status = 'cancelled' then
    raise exception 'Invitation has been cancelled';
  end if;

  update app.tenant_invitations
     set status = case
           when status in ('pending_delivery', 'pending', 'sent') then 'opened'
           else status
         end,
         opened_at = coalesce(opened_at, now()),
         updated_at = now()
   where id = v_invite.id;

  v_response_status := case
    when v_effective_status in ('pending_delivery', 'pending', 'sent') then 'opened'
    else v_effective_status::text
  end;

  return jsonb_build_object(
    'tenant_invitation_id', v_invite.id,
    'property_id', v_invite.property_id,
    'unit_id', v_invite.unit_id,
    'lease_agreement_id', v_invite.lease_agreement_id,
    'property_name', coalesce(nullif(trim(v_invite.property_name), ''), 'Untitled Property'),
    'unit_label', coalesce(nullif(trim(v_invite.unit_label), ''), 'Unlabelled Unit'),
    'invited_name', v_invite.invited_name,
    'invited_email', v_invite.invited_email,
    'invited_phone_number', v_invite.invited_phone_number,
    'delivery_channel', v_invite.delivery_channel::text,
    'status', v_response_status,
    'lease', jsonb_build_object(
      'lease_type', v_invite.lease_type::text,
      'start_date', v_invite.start_date,
      'end_date', v_invite.end_date,
      'billing_cycle', v_invite.billing_cycle::text,
      'rent_amount', v_invite.rent_amount,
      'currency_code', v_invite.currency_code,
      'confirmation_status', v_invite.confirmation_status::text,
      'status', v_invite.lease_status::text
    )
  );
end;
$$;

create or replace function app.accept_tenant_invitation(
  p_token text,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_invite record;
  v_user_email text;
  v_effective_status app.tenant_invitation_status_enum;
  v_tenancy_id uuid;
  v_target_tenancy_status app.unit_tenancy_status_enum;
  v_action_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;
  if p_token is null or length(trim(p_token)) = 0 then
    raise exception 'Invitation token is required';
  end if;

  select u.email into v_user_email
  from auth.users u
  where u.id = auth.uid()
  limit 1;

  select
    i.*,
    l.start_date,
    l.end_date,
    l.confirmation_status,
    l.status as lease_status
  into v_invite
  from app.tenant_invitations i
  join app.lease_agreements l on l.id = i.lease_agreement_id
  where i.token_hash = app.hash_token(trim(p_token))
  limit 1;

  if v_invite.id is null then
    raise exception 'Invitation not found';
  end if;

  v_effective_status := app.get_effective_tenant_invitation_status(
    v_invite.status, v_invite.expires_at, v_invite.accepted_at, v_invite.cancelled_at
  );

  if v_effective_status = 'expired' then
    raise exception 'Invitation has expired';
  end if;
  if v_effective_status = 'cancelled' then
    raise exception 'Invitation has been cancelled';
  end if;
  if v_effective_status = 'accepted' then
    raise exception 'Invitation has already been accepted';
  end if;

  if v_invite.invited_email is not null
     and lower(trim(v_invite.invited_email)) <> lower(trim(coalesce(v_user_email, ''))) then
    raise exception 'Authenticated email does not match the invited email';
  end if;

  if exists (
    select 1
    from app.unit_tenancies t
    where t.unit_id = v_invite.unit_id
      and t.status in ('pending_agreement', 'scheduled', 'active')
      and t.tenant_user_id <> auth.uid()
  ) then
    raise exception 'This unit already has an active or scheduled tenant';
  end if;

  v_target_tenancy_status := case
    when v_invite.start_date <= current_date then 'active'::app.unit_tenancy_status_enum
    else 'scheduled'::app.unit_tenancy_status_enum
  end;

  update app.tenant_invitations
     set linked_user_id = auth.uid(),
         status = 'accepted'::app.tenant_invitation_status_enum,
         accepted_at = now(),
         updated_at = now()
   where id = v_invite.id;

  update app.lease_agreements
     set tenant_user_id = auth.uid(),
         confirmation_status = 'confirmed'::app.lease_confirmation_status_enum,
         tenant_confirmed_at = now(),
         tenant_response_notes = nullif(trim(coalesce(p_notes, '')), ''),
         status = case
           when start_date <= current_date then 'active'::app.lease_agreement_status_enum
           else 'confirmed'::app.lease_agreement_status_enum
         end,
         updated_at = now()
   where id = v_invite.lease_agreement_id;

  insert into app.unit_tenancies (
    property_id, unit_id, lease_agreement_id, tenant_invitation_id, tenant_user_id,
    status, starts_on, ends_on, activated_at, created_by_user_id, notes
  )
  values (
    v_invite.property_id,
    v_invite.unit_id,
    v_invite.lease_agreement_id,
    v_invite.id,
    auth.uid(),
    v_target_tenancy_status,
    v_invite.start_date,
    v_invite.end_date,
    case when v_target_tenancy_status = 'active' then now() else null end,
    auth.uid(),
    nullif(trim(coalesce(p_notes, '')), '')
  )
  on conflict (lease_agreement_id)
  do update
    set tenant_user_id = excluded.tenant_user_id,
        tenant_invitation_id = excluded.tenant_invitation_id,
        status = excluded.status,
        starts_on = excluded.starts_on,
        ends_on = excluded.ends_on,
        activated_at = excluded.activated_at,
        updated_at = now()
  returning id into v_tenancy_id;

  perform app.sync_unit_occupancy_snapshot(v_invite.unit_id, auth.uid());
  perform app.touch_property_activity(v_invite.property_id);

  v_action_id := app.get_audit_action_id_by_code('LEASE_CONFIRMATION_UPDATED');
  if v_action_id is not null then
    insert into app.audit_logs (property_id, unit_id, actor_user_id, action_type_id, payload)
    values (
      v_invite.property_id,
      v_invite.unit_id,
      auth.uid(),
      v_action_id,
      jsonb_build_object(
        'tenant_invitation_id', v_invite.id,
        'lease_agreement_id', v_invite.lease_agreement_id,
        'tenancy_id', v_tenancy_id,
        'confirmation_status', 'confirmed',
        'tenancy_status', v_target_tenancy_status::text
      )
    );
  end if;

  return jsonb_build_object(
    'tenant_invitation_id', v_invite.id,
    'lease_agreement_id', v_invite.lease_agreement_id,
    'tenancy_id', v_tenancy_id,
    'unit_id', v_invite.unit_id,
    'property_id', v_invite.property_id,
    'tenancy_status', v_target_tenancy_status::text,
    'lease_status', case when v_invite.start_date <= current_date then 'active' else 'confirmed' end
  );
end;
$$;

create or replace function app.dispute_tenant_invitation(
  p_token text,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_invite record;
  v_user_email text;
  v_effective_status app.tenant_invitation_status_enum;
  v_action_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;
  if p_token is null or length(trim(p_token)) = 0 then
    raise exception 'Invitation token is required';
  end if;
  if p_reason is null or length(trim(p_reason)) < 3 then
    raise exception 'A dispute reason is required';
  end if;

  select u.email into v_user_email
  from auth.users u
  where u.id = auth.uid()
  limit 1;

  select i.*
    into v_invite
  from app.tenant_invitations i
  where i.token_hash = app.hash_token(trim(p_token))
  limit 1;

  if v_invite.id is null then
    raise exception 'Invitation not found';
  end if;

  v_effective_status := app.get_effective_tenant_invitation_status(
    v_invite.status, v_invite.expires_at, v_invite.accepted_at, v_invite.cancelled_at
  );

  if v_effective_status = 'expired' then
    raise exception 'Invitation has expired';
  end if;
  if v_effective_status = 'cancelled' then
    raise exception 'Invitation has been cancelled';
  end if;
  if v_effective_status = 'accepted' then
    raise exception 'Invitation has already been accepted';
  end if;

  if v_invite.invited_email is not null
     and lower(trim(v_invite.invited_email)) <> lower(trim(coalesce(v_user_email, ''))) then
    raise exception 'Authenticated email does not match the invited email';
  end if;

  update app.tenant_invitations
     set linked_user_id = auth.uid(),
         status = 'signup_started'::app.tenant_invitation_status_enum,
         signup_started_at = coalesce(signup_started_at, now()),
         updated_at = now()
   where id = v_invite.id;

  update app.lease_agreements
     set tenant_user_id = auth.uid(),
         confirmation_status = 'disputed'::app.lease_confirmation_status_enum,
         tenant_disputed_at = now(),
         tenant_response_notes = trim(p_reason),
         status = 'disputed'::app.lease_agreement_status_enum,
         updated_at = now()
   where id = v_invite.lease_agreement_id;

  perform app.sync_unit_occupancy_snapshot(v_invite.unit_id, auth.uid());
  perform app.touch_property_activity(v_invite.property_id);

  v_action_id := app.get_audit_action_id_by_code('LEASE_CONFIRMATION_UPDATED');
  if v_action_id is not null then
    insert into app.audit_logs (property_id, unit_id, actor_user_id, action_type_id, payload)
    values (
      v_invite.property_id,
      v_invite.unit_id,
      auth.uid(),
      v_action_id,
      jsonb_build_object(
        'tenant_invitation_id', v_invite.id,
        'lease_agreement_id', v_invite.lease_agreement_id,
        'confirmation_status', 'disputed',
        'reason', trim(p_reason)
      )
    );
  end if;

  return jsonb_build_object(
    'tenant_invitation_id', v_invite.id,
    'lease_agreement_id', v_invite.lease_agreement_id,
    'status', 'disputed'
  );
end;
$$;

create or replace function app.resend_tenant_invitation(
  p_invitation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = app, public, extensions
as $$
declare
  v_invite record;
  v_token text;
  v_expires_at timestamptz;
  v_action_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  select
    i.id,
    i.property_id,
    i.unit_id,
    i.status,
    i.delivery_channel,
    i.invited_email,
    i.invited_phone_number,
    p.display_name as property_name,
    u.label as unit_label,
    app.get_effective_tenant_invitation_status(i.status, i.expires_at, i.accepted_at, i.cancelled_at) as effective_status
  into v_invite
  from app.tenant_invitations i
  join app.properties p on p.id = i.property_id
  join app.units u on u.id = i.unit_id
  where i.id = p_invitation_id
  limit 1;

  if v_invite.id is null then
    raise exception 'Invitation not found';
  end if;

  perform app.assert_tenancy_management_access(v_invite.property_id);

  if v_invite.effective_status in ('accepted', 'cancelled') then
    raise exception 'Cannot resend an invitation that is already %s', v_invite.effective_status::text;
  end if;

  v_token := encode(extensions.gen_random_bytes(24), 'hex');
  v_expires_at := now() + interval '7 days';

  update app.tenant_invitations
     set token_hash = app.hash_token(v_token),
         status = 'sent',
         expires_at = v_expires_at,
         resent_count = coalesce(resent_count, 0) + 1,
         last_resent_at = now(),
         delivery_attempt_count = coalesce(delivery_attempt_count, 0) + 1,
         last_delivery_error = null,
         updated_at = now()
   where id = p_invitation_id;

  perform app.sync_unit_occupancy_snapshot(v_invite.unit_id, auth.uid());
  perform app.touch_property_activity(v_invite.property_id);

  v_action_id := app.get_audit_action_id_by_code('TENANT_INVITE_SENT');
  if v_action_id is not null then
    insert into app.audit_logs (property_id, unit_id, actor_user_id, action_type_id, payload)
    values (
      v_invite.property_id,
      v_invite.unit_id,
      auth.uid(),
      v_action_id,
      jsonb_build_object(
        'tenant_invitation_id', v_invite.id,
        'delivery_channel', v_invite.delivery_channel::text,
        'resent', true,
        'expires_at', v_expires_at
      )
    );
  end if;

  return jsonb_build_object(
    'tenant_invitation_id', v_invite.id,
    'property_id', v_invite.property_id,
    'unit_id', v_invite.unit_id,
    'delivery_channel', v_invite.delivery_channel::text,
    'invited_email', v_invite.invited_email,
    'invited_phone_number', v_invite.invited_phone_number,
    'property_name', coalesce(nullif(trim(v_invite.property_name), ''), 'Untitled Property'),
    'unit_label', coalesce(nullif(trim(v_invite.unit_label), ''), 'Unlabelled Unit'),
    'expires_at', v_expires_at,
    'token', v_token
  );
end;
$$;

create or replace function app.get_unit_occupancy_portfolio_base(
  p_property_id uuid default null
)
returns table (
  property_id uuid,
  property_name text,
  city_town text,
  area_neighborhood text,
  unit_id uuid,
  unit_label text,
  block text,
  floor text,
  occupancy_status app.unit_occupancy_status_enum,
  current_lease_agreement_id uuid,
  lease_status app.lease_agreement_status_enum,
  confirmation_status app.lease_confirmation_status_enum,
  lease_start_date date,
  lease_end_date date,
  days_until_lease_end integer,
  rent_amount numeric,
  monthly_rent_amount numeric,
  currency_code text,
  billing_cycle app.lease_billing_cycle_enum,
  tenant_name text,
  tenant_phone text,
  tenant_user_id uuid,
  tenant_invitation_id uuid,
  tenant_invitation_status app.tenant_invitation_status_enum,
  invitation_expires_at timestamptz,
  expected_rate numeric,
  expected_monthly_rent numeric,
  vacant_since timestamptz,
  last_occupied_at timestamptz,
  last_vacancy_duration_days integer,
  pending_action_code text,
  pending_action_label text,
  revenue_risk_amount numeric,
  is_revenue_at_risk boolean,
  lease_expiry_bucket text,
  can_invite boolean
)
language sql
stable
security definer
set search_path = app, public
as $$
  with accessible_properties as (
    select accessible.property_id
    from app.get_tenancy_accessible_property_ids(p_property_id) as accessible
  ),
  base as (
    select
      p.id as property_id,
      coalesce(nullif(trim(p.display_name), ''), 'Untitled Property') as property_name,
      p.city_town,
      p.area_neighborhood,
      u.id as unit_id,
      coalesce(nullif(trim(u.label), ''), 'Unlabelled Unit') as unit_label,
      u.block,
      u.floor,
      coalesce(s.occupancy_status, 'vacant'::app.unit_occupancy_status_enum) as occupancy_status,
      l.id as current_lease_agreement_id,
      case
        when l.id is null then null
        else app.get_effective_lease_status(l.status, l.confirmation_status, l.start_date, l.end_date)
      end as lease_status,
      l.confirmation_status,
      l.start_date as lease_start_date,
      l.end_date as lease_end_date,
      case when l.end_date is null then null else (l.end_date - current_date) end as days_until_lease_end,
      l.rent_amount,
      case when l.id is null then null else app.to_monthly_rent_amount(l.rent_amount, l.billing_cycle) end as monthly_rent_amount,
      l.currency_code,
      l.billing_cycle,
      coalesce(
        nullif(trim(s.current_tenant_name), ''),
        nullif(trim(l.tenant_name), ''),
        nullif(trim(i.invited_name), '')
      ) as tenant_name,
      coalesce(
        nullif(trim(s.current_tenant_phone), ''),
        nullif(trim(l.tenant_phone), ''),
        nullif(trim(i.invited_phone_number), '')
      ) as tenant_phone,
      coalesce(s.current_tenant_user_id, l.tenant_user_id, i.linked_user_id) as tenant_user_id,
      i.id as tenant_invitation_id,
      case
        when i.id is null then null
        else app.get_effective_tenant_invitation_status(i.status, i.expires_at, i.accepted_at, i.cancelled_at)
      end as tenant_invitation_status,
      i.expires_at as invitation_expires_at,
      u.expected_rate,
      u.expected_rate as expected_monthly_rent,
      s.vacant_since,
      s.last_occupied_at,
      s.last_vacancy_duration_days
    from accessible_properties ap
    join app.properties p on p.id = ap.property_id
    join app.units u on u.property_id = p.id and u.deleted_at is null
    left join app.unit_occupancy_snapshots s on s.unit_id = u.id
    left join app.lease_agreements l on l.id = s.current_lease_agreement_id
    left join app.tenant_invitations i on i.id = s.current_tenant_invitation_id
    where p.deleted_at is null
      and p.status = 'active'
  )
  select
    base.property_id,
    base.property_name,
    base.city_town,
    base.area_neighborhood,
    base.unit_id,
    base.unit_label,
    base.block,
    base.floor,
    base.occupancy_status,
    base.current_lease_agreement_id,
    base.lease_status,
    base.confirmation_status,
    base.lease_start_date,
    base.lease_end_date,
    base.days_until_lease_end,
    base.rent_amount,
    base.monthly_rent_amount,
    base.currency_code,
    base.billing_cycle,
    base.tenant_name,
    base.tenant_phone,
    base.tenant_user_id,
    base.tenant_invitation_id,
    base.tenant_invitation_status,
    base.invitation_expires_at,
    base.expected_rate,
    base.expected_monthly_rent,
    base.vacant_since,
    base.last_occupied_at,
    base.last_vacancy_duration_days,
    case
      when base.lease_status = 'disputed' or base.confirmation_status = 'disputed' then 'lease_disputed'
      when base.occupancy_status = 'pending_confirmation' then 'tenant_confirmation_pending'
      when base.occupancy_status = 'invited'
           and coalesce(base.tenant_invitation_status::text, '') in ('pending_delivery', 'pending', 'sent', 'opened', 'signup_started')
        then 'invite_pending'
      when base.occupancy_status = 'vacant' then 'vacant_unit'
      else null
    end as pending_action_code,
    case
      when base.lease_status = 'disputed' or base.confirmation_status = 'disputed' then 'Lease terms disputed'
      when base.occupancy_status = 'pending_confirmation' then 'Awaiting tenant confirmation'
      when base.occupancy_status = 'invited'
           and coalesce(base.tenant_invitation_status::text, '') in ('pending_delivery', 'pending', 'sent', 'opened', 'signup_started')
        then 'Invite still outstanding'
      when base.occupancy_status = 'vacant' then 'Vacant without tenant'
      else null
    end as pending_action_label,
    round(
      case
        when base.occupancy_status in ('vacant', 'invited', 'pending_confirmation')
          then coalesce(base.expected_monthly_rent, base.monthly_rent_amount, 0)
        when base.lease_end_date between current_date and (current_date + 90)
          then coalesce(base.monthly_rent_amount, base.expected_monthly_rent, 0)
        else 0
      end,
      2
    ) as revenue_risk_amount,
    (
      base.occupancy_status in ('vacant', 'invited', 'pending_confirmation')
      or base.lease_end_date between current_date and (current_date + 90)
    ) as is_revenue_at_risk,
    case
      when base.lease_end_date between current_date and (current_date + 30) then '0_30'
      when base.lease_end_date between (current_date + 31) and (current_date + 60) then '31_60'
      when base.lease_end_date between (current_date + 61) and (current_date + 90) then '61_90'
      else null
    end as lease_expiry_bucket,
    base.occupancy_status = 'vacant' as can_invite
  from base
  order by base.property_name asc, coalesce(base.block, '') asc, coalesce(base.floor, '') asc, base.unit_label asc;
$$;

create or replace function app.get_units_occupancy_property_options()
returns table (
  property_id uuid,
  property_name text,
  city_town text,
  area_neighborhood text,
  unit_count integer,
  occupied_count integer,
  vacant_count integer
)
language plpgsql
security definer
set search_path = app, public
as $$
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  perform app.refresh_tenancy_dashboard_state(null);

  return query
  with accessible_properties as (
    select accessible.property_id
    from app.get_tenancy_accessible_property_ids(null) as accessible
  )
  select
    p.id as property_id,
    coalesce(nullif(trim(p.display_name), ''), 'Untitled Property') as property_name,
    p.city_town,
    p.area_neighborhood,
    count(u.id)::int as unit_count,
    (count(u.id) filter (
      where coalesce(s.occupancy_status, 'vacant'::app.unit_occupancy_status_enum) = 'occupied'
    ))::int as occupied_count,
    (count(u.id) filter (
      where coalesce(s.occupancy_status, 'vacant'::app.unit_occupancy_status_enum) = 'vacant'
    ))::int as vacant_count
  from accessible_properties ap
  join app.properties p on p.id = ap.property_id
  join app.units u on u.property_id = p.id and u.deleted_at is null
  left join app.unit_occupancy_snapshots s on s.unit_id = u.id
  where p.deleted_at is null
    and p.status = 'active'
  group by p.id, p.display_name, p.city_town, p.area_neighborhood
  order by coalesce(nullif(trim(p.display_name), ''), 'Untitled Property') asc;
end;
$$;

create or replace function app.get_unit_occupancy_dashboard_chart_series(
  p_property_id uuid default null,
  p_series_kind app.unit_occupancy_dashboard_series_enum default 'occupancy_trend'::app.unit_occupancy_dashboard_series_enum
)
returns jsonb
language sql
stable
security definer
set search_path = app, public
as $$
  with scoped_points as (
    select
      points.label,
      points.sort_order,
      points.occupied_units,
      points.occupancy_rate,
      points.vacant_units,
      points.turnover_count
    from app.unit_occupancy_dashboard_chart_points as points
    where points.series_kind = p_series_kind
      and (
        points.property_id = p_property_id
        or (
          points.property_id is null
          and (
            p_property_id is null
            or not exists (
              select 1
              from app.unit_occupancy_dashboard_chart_points as property_override
              where property_override.series_kind = p_series_kind
                and property_override.property_id = p_property_id
            )
          )
        )
      )
  )
  select coalesce(
    jsonb_agg(
      case
        when p_series_kind = 'occupancy_trend'::app.unit_occupancy_dashboard_series_enum then
          jsonb_build_object(
            'label', scoped_points.label,
            'occupied_units', scoped_points.occupied_units,
            'occupancy_rate', scoped_points.occupancy_rate
          )
        else
          jsonb_build_object(
            'label', scoped_points.label,
            'vacant_units', scoped_points.vacant_units,
            'turnover_count', scoped_points.turnover_count
          )
      end
      order by scoped_points.sort_order
    ),
    '[]'::jsonb
  )
  from scoped_points;
$$;

create or replace function app.get_units_occupancy_dashboard(p_property_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_dashboard jsonb;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  perform app.refresh_tenancy_dashboard_state(p_property_id);

  with base as (
    select *
    from app.get_unit_occupancy_portfolio_base(p_property_id)
  ),
  expiry_bucket_template as (
    select '0_30'::text as bucket_key, '0-30 days'::text as label, 1 as sort_order
    union all
    select '31_60', '31-60 days', 2
    union all
    select '61_90', '61-90 days', 3
  ),
  expiry_bucket_totals as (
    select
      lease_expiry_bucket as bucket_key,
      count(*)::int as unit_count,
      round(coalesce(sum(coalesce(monthly_rent_amount, expected_monthly_rent, 0)), 0), 2) as rent_at_risk
    from base
    where lease_expiry_bucket is not null
    group by lease_expiry_bucket
  ),
  attention_units as (
    select
      base.property_id,
      base.property_name,
      base.unit_id,
      base.unit_label,
      base.pending_action_code,
      base.pending_action_label,
      base.lease_expiry_bucket,
      base.days_until_lease_end,
      base.revenue_risk_amount,
      case
        when base.pending_action_code = 'lease_disputed' then 1
        when base.lease_expiry_bucket = '0_30' then 2
        when base.pending_action_code = 'tenant_confirmation_pending' then 3
        when base.pending_action_code = 'invite_pending' then 4
        when base.pending_action_code = 'vacant_unit' then 5
        when base.lease_expiry_bucket = '31_60' then 6
        when base.lease_expiry_bucket = '61_90' then 7
        else 99
      end as priority_order,
      case
        when base.pending_action_code = 'lease_disputed' then 'Tenant has disputed the recorded lease terms.'
        when base.pending_action_code = 'tenant_confirmation_pending' then 'The lease exists, but occupancy should not activate until confirmation is recorded.'
        when base.pending_action_code = 'invite_pending' then 'An invite is live, but the tenant has not completed confirmation.'
        when base.pending_action_code = 'vacant_unit' then 'This unit is live in the portfolio but has no active tenant workflow.'
        when base.lease_expiry_bucket is not null then format(
          'Lease expires in %s day%s and needs renewal attention.',
          greatest(coalesce(base.days_until_lease_end, 0), 0),
          case when greatest(coalesce(base.days_until_lease_end, 0), 0) = 1 then '' else 's' end
        )
        else 'Operational review recommended.'
      end as reason
    from base
    where base.pending_action_code is not null
       or base.lease_expiry_bucket is not null
  )
  select jsonb_build_object(
    'summary',
    jsonb_build_object(
      'currency_code', 'KES',
      'property_count', count(distinct property_id)::int,
      'total_units', count(*)::int,
      'occupied_units', (count(*) filter (where occupancy_status = 'occupied'))::int,
      'occupancy_rate',
        case
          when count(*) = 0 then 0
          else round(
            ((count(*) filter (where occupancy_status = 'occupied'))::numeric / count(*)::numeric) * 100,
            1
          )
        end,
      'vacant_units', (count(*) filter (where occupancy_status = 'vacant'))::int,
      'revenue_at_risk_amount', round(coalesce(sum(case when is_revenue_at_risk then revenue_risk_amount else 0 end), 0), 2),
      'revenue_at_risk_units', (count(*) filter (where is_revenue_at_risk))::int,
      'vacancy_exposure_amount', round(
        coalesce(
          sum(
            case
              when occupancy_status in ('vacant', 'invited', 'pending_confirmation') then revenue_risk_amount
              else 0
            end
          ),
          0
        ),
        2
      ),
      'expiring_revenue_amount', round(
        coalesce(
          sum(
            case
              when lease_expiry_bucket is not null then coalesce(monthly_rent_amount, expected_monthly_rent, 0)
              else 0
            end
          ),
          0
        ),
        2
      ),
      'upcoming_expiries_count', (count(*) filter (where lease_expiry_bucket is not null))::int,
      'upcoming_expiries_rent', round(
        coalesce(
          sum(
            case
              when lease_expiry_bucket is not null then coalesce(monthly_rent_amount, expected_monthly_rent, 0)
              else 0
            end
          ),
          0
        ),
        2
      ),
      'avg_vacancy_duration_days',
        round(
          avg(
            case
              when occupancy_status in ('vacant', 'invited', 'pending_confirmation') and vacant_since is not null
                then extract(epoch from (now() - vacant_since)) / 86400.0
              when last_vacancy_duration_days is not null
                then last_vacancy_duration_days::numeric
              else null
            end
          ),
          1
        ),
      'pending_actions_count',
        (count(*) filter (
          where pending_action_code in (
            'invite_pending',
            'tenant_confirmation_pending',
            'lease_disputed',
            'vacant_unit'
          )
        ))::int
    ),
    'status_breakdown',
    jsonb_build_object(
      'vacant', (count(*) filter (where occupancy_status = 'vacant'))::int,
      'invited', (count(*) filter (where occupancy_status = 'invited'))::int,
      'pending_confirmation', (count(*) filter (where occupancy_status = 'pending_confirmation'))::int,
      'occupied', (count(*) filter (where occupancy_status = 'occupied'))::int,
      'disputed', (count(*) filter (where occupancy_status = 'disputed'))::int
    ),
    'pending_actions',
    jsonb_build_object(
      'total_units',
        (count(*) filter (
          where pending_action_code in (
            'invite_pending',
            'tenant_confirmation_pending',
            'lease_disputed',
            'vacant_unit'
          )
        ))::int,
      'pending_invites', (count(*) filter (where pending_action_code = 'invite_pending'))::int,
      'pending_confirmations', (count(*) filter (where pending_action_code = 'tenant_confirmation_pending'))::int,
      'disputed_leases', (count(*) filter (where pending_action_code = 'lease_disputed'))::int,
      'vacant_without_tenant', (count(*) filter (where pending_action_code = 'vacant_unit'))::int
    ),
    'lease_expiry_buckets',
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'bucket_key', template.bucket_key,
          'label', template.label,
          'unit_count', coalesce(totals.unit_count, 0),
          'rent_at_risk', coalesce(totals.rent_at_risk, 0)
        )
        order by template.sort_order
      )
      from expiry_bucket_template template
      left join expiry_bucket_totals totals on totals.bucket_key = template.bucket_key
    ), '[]'::jsonb),
    'occupancy_trend', app.get_unit_occupancy_dashboard_chart_series(p_property_id, 'occupancy_trend'::app.unit_occupancy_dashboard_series_enum),
    'vacancy_turnover_trend', app.get_unit_occupancy_dashboard_chart_series(p_property_id, 'vacancy_turnover_trend'::app.unit_occupancy_dashboard_series_enum),
    'attention_units',
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'property_id', property_id,
          'property_name', property_name,
          'unit_id', unit_id,
          'unit_label', unit_label,
          'pending_action_code', pending_action_code,
          'pending_action_label', pending_action_label,
          'lease_expiry_bucket', lease_expiry_bucket,
          'reason', reason,
          'revenue_risk_amount', revenue_risk_amount,
          'days_until_lease_end', days_until_lease_end
        )
        order by priority_order, revenue_risk_amount desc, property_name, unit_label
      )
      from (
        select *
        from attention_units
        order by priority_order, revenue_risk_amount desc, property_name, unit_label
        limit 5
      ) ranked_attention
    ), '[]'::jsonb)
  )
  into v_dashboard
  from base;

  return coalesce(
    v_dashboard,
    jsonb_build_object(
      'summary', jsonb_build_object(
        'currency_code', 'KES',
        'property_count', 0,
        'total_units', 0,
        'occupied_units', 0,
        'occupancy_rate', 0,
        'vacant_units', 0,
        'revenue_at_risk_amount', 0,
        'revenue_at_risk_units', 0,
        'vacancy_exposure_amount', 0,
        'expiring_revenue_amount', 0,
        'upcoming_expiries_count', 0,
        'upcoming_expiries_rent', 0,
        'avg_vacancy_duration_days', null,
        'pending_actions_count', 0
      ),
      'status_breakdown', jsonb_build_object(
        'vacant', 0,
        'invited', 0,
        'pending_confirmation', 0,
        'occupied', 0,
        'disputed', 0
      ),
      'pending_actions', jsonb_build_object(
        'total_units', 0,
        'pending_invites', 0,
        'pending_confirmations', 0,
        'disputed_leases', 0,
        'vacant_without_tenant', 0
      ),
      'lease_expiry_buckets', '[]'::jsonb,
      'occupancy_trend', app.get_unit_occupancy_dashboard_chart_series(p_property_id, 'occupancy_trend'::app.unit_occupancy_dashboard_series_enum),
      'vacancy_turnover_trend', app.get_unit_occupancy_dashboard_chart_series(p_property_id, 'vacancy_turnover_trend'::app.unit_occupancy_dashboard_series_enum),
      'attention_units', '[]'::jsonb
    )
  );
end;
$$;

create or replace function app.get_unit_occupancy_rows(p_property_id uuid default null)
returns table (
  property_id uuid,
  property_name text,
  city_town text,
  area_neighborhood text,
  unit_id uuid,
  unit_label text,
  block text,
  floor text,
  occupancy_status text,
  current_lease_agreement_id uuid,
  lease_status text,
  confirmation_status text,
  lease_start_date date,
  lease_end_date date,
  days_until_lease_end integer,
  rent_amount numeric,
  monthly_rent_amount numeric,
  currency_code text,
  billing_cycle text,
  tenant_name text,
  tenant_phone text,
  tenant_user_id uuid,
  tenant_invitation_id uuid,
  tenant_invitation_status text,
  invitation_expires_at timestamptz,
  expected_rate numeric,
  expected_monthly_rent numeric,
  vacant_since timestamptz,
  last_occupied_at timestamptz,
  last_vacancy_duration_days integer,
  pending_action_code text,
  pending_action_label text,
  revenue_risk_amount numeric,
  is_revenue_at_risk boolean,
  lease_expiry_bucket text,
  can_invite boolean
)
language plpgsql
security definer
set search_path = app, public
as $$
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  perform app.refresh_tenancy_dashboard_state(p_property_id);

  return query
  select
    base.property_id,
    base.property_name,
    base.city_town,
    base.area_neighborhood,
    base.unit_id,
    base.unit_label,
    base.block,
    base.floor,
    base.occupancy_status::text,
    base.current_lease_agreement_id,
    base.lease_status::text,
    base.confirmation_status::text,
    base.lease_start_date,
    base.lease_end_date,
    base.days_until_lease_end,
    base.rent_amount,
    base.monthly_rent_amount,
    base.currency_code,
    base.billing_cycle::text,
    base.tenant_name,
    base.tenant_phone,
    base.tenant_user_id,
    base.tenant_invitation_id,
    case
      when base.tenant_invitation_status is null then null
      else app.get_dashboard_tenant_invitation_status(base.tenant_invitation_status)
    end,
    base.invitation_expires_at,
    base.expected_rate,
    base.expected_monthly_rent,
    base.vacant_since,
    base.last_occupied_at,
    base.last_vacancy_duration_days,
    base.pending_action_code,
    base.pending_action_label,
    base.revenue_risk_amount,
    base.is_revenue_at_risk,
    base.lease_expiry_bucket,
    base.can_invite
  from app.get_unit_occupancy_portfolio_base(p_property_id) base;
end;
$$;

create or replace function app.initialize_unit_occupancy_snapshots_for_property(
  p_property_id uuid,
  p_actor_user_id uuid default auth.uid()
)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_unit_id uuid;
begin
  for v_unit_id in
    select u.id
    from app.units u
    where u.property_id = p_property_id
      and u.deleted_at is null
  loop
    perform app.ensure_unit_occupancy_snapshot_exists(v_unit_id, p_actor_user_id);
    perform app.sync_unit_occupancy_snapshot(v_unit_id, p_actor_user_id);
  end loop;
end;
$$;

create or replace function app.activate_property(
  p_property_id uuid
)
returns void
language plpgsql
security definer
set search_path = app, public
as $$
declare
  v_session_id uuid;
  v_action_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  perform app.assert_property_full_access(p_property_id);

  update app.properties
     set status = 'active',
         onboarding_completed_at = coalesce(onboarding_completed_at, now()),
         current_step_key = 'done',
         last_activity_at = now()
   where id = p_property_id
     and deleted_at is null
     and identity_completed_at is not null;

  if not found then
    raise exception 'Property not found, deleted, or identity not completed';
  end if;

  select s.id
    into v_session_id
  from app.property_onboarding_sessions s
  where s.property_id = p_property_id
    and s.deleted_at is null
  limit 1;

  if v_session_id is not null then
    update app.property_onboarding_sessions
       set status = 'completed',
           current_step_key = 'done',
           last_activity_at = now()
     where id = v_session_id
       and deleted_at is null;

    update app.property_onboarding_step_states
       set status = 'completed',
           completed_by = coalesce(completed_by, auth.uid()),
           completed_at = coalesce(completed_at, now()),
           data_snapshot = coalesce(data_snapshot, '{}'::jsonb) || jsonb_build_object('activatedAt', now()),
           locked_by = null,
           locked_at = null,
           lock_expires_at = null
     where session_id = v_session_id
       and step_key = 'review'
       and deleted_at is null;
  end if;

  perform app.initialize_unit_occupancy_snapshots_for_property(p_property_id, auth.uid());
  perform app.touch_property_activity(p_property_id);
  perform app.enqueue_property_activation_notifications(p_property_id);

  v_action_id := app.get_audit_action_id_by_code('PROPERTY_ACTIVATED');

  if v_action_id is not null then
    insert into app.audit_logs (
      property_id,
      actor_user_id,
      action_type_id,
      payload
    )
    values (
      p_property_id,
      auth.uid(),
      v_action_id,
      jsonb_build_object('status', 'active')
    );
  end if;
end;
$$;

alter table app.lease_agreements enable row level security;
alter table app.tenant_invitations enable row level security;
alter table app.unit_occupancy_snapshots enable row level security;
alter table app.unit_tenancies enable row level security;

alter table app.lease_agreements force row level security;
alter table app.tenant_invitations force row level security;
alter table app.unit_occupancy_snapshots force row level security;
alter table app.unit_tenancies force row level security;

drop policy if exists lease_agreements_select_tenancy_control on app.lease_agreements;
create policy lease_agreements_select_tenancy_control
on app.lease_agreements
for select
to authenticated
using (
  app.has_tenancy_management_access(app.lease_agreements.property_id)
  or tenant_user_id = auth.uid()
);

drop policy if exists tenant_invitations_select_tenancy_control on app.tenant_invitations;
create policy tenant_invitations_select_tenancy_control
on app.tenant_invitations
for select
to authenticated
using (
  app.has_tenancy_management_access(app.tenant_invitations.property_id)
  or linked_user_id = auth.uid()
);

drop policy if exists unit_occupancy_snapshots_select_tenancy_control on app.unit_occupancy_snapshots;
create policy unit_occupancy_snapshots_select_tenancy_control
on app.unit_occupancy_snapshots
for select
to authenticated
using (
  app.has_tenancy_management_access(app.unit_occupancy_snapshots.property_id)
  or current_tenant_user_id = auth.uid()
);

drop policy if exists unit_tenancies_select_tenancy_control on app.unit_tenancies;
create policy unit_tenancies_select_tenancy_control
on app.unit_tenancies
for select
to authenticated
using (
  app.has_tenancy_management_access(app.unit_tenancies.property_id)
  or tenant_user_id = auth.uid()
);

grant usage on schema app to anon;

revoke all on function app.create_tenant_invitation(
  uuid,
  text,
  text,
  app.tenant_invitation_delivery_channel_enum,
  text,
  app.lease_type_enum,
  date,
  date,
  numeric,
  text,
  app.lease_billing_cycle_enum,
  text,
  integer
) from public, anon, authenticated;

revoke all on function app.get_tenant_invitation_by_token(text) from public, anon, authenticated;
revoke all on function app.accept_tenant_invitation(text, text) from public, anon, authenticated;
revoke all on function app.dispute_tenant_invitation(text, text) from public, anon, authenticated;
revoke all on function app.resend_tenant_invitation(uuid) from public, anon, authenticated;
revoke all on function app.get_units_occupancy_property_options() from public, anon, authenticated;
revoke all on function app.get_units_occupancy_dashboard(uuid) from public, anon, authenticated;
revoke all on function app.get_unit_occupancy_rows(uuid) from public, anon, authenticated;

grant execute on function app.create_tenant_invitation(
  uuid,
  text,
  text,
  app.tenant_invitation_delivery_channel_enum,
  text,
  app.lease_type_enum,
  date,
  date,
  numeric,
  text,
  app.lease_billing_cycle_enum,
  text,
  integer
) to authenticated;

grant execute on function app.get_tenant_invitation_by_token(text) to authenticated, anon;
grant execute on function app.accept_tenant_invitation(text, text) to authenticated;
grant execute on function app.dispute_tenant_invitation(text, text) to authenticated;
grant execute on function app.resend_tenant_invitation(uuid) to authenticated;
grant execute on function app.get_units_occupancy_property_options() to authenticated;
grant execute on function app.get_units_occupancy_dashboard(uuid) to authenticated;
grant execute on function app.get_unit_occupancy_rows(uuid) to authenticated;
