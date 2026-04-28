-- ============================================================================
-- V 1 33: Lease Directory and Portfolio Summary RPCs
-- ============================================================================
-- Provides the backend for /owner/documents replacing all mock data.
--
-- get_lease_directory(p_property_id)
--   Returns all lease agreements for the caller's managed properties with
--   tenant info, unit/property context, computed UI status, days remaining,
--   document count, template info, and recent activity.
--
-- get_lease_portfolio_summary(p_property_id)
--   Returns aggregate KPI counts for the portfolio overview cards.
-- ============================================================================

create schema if not exists app;

-- ─── get_lease_directory ─────────────────────────────────────────────────────

create or replace function app.get_lease_directory(
  p_property_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, public
as $$
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  return coalesce(
    (
      select jsonb_agg(row order by row.start_date desc)
      from (
        select
          l.id,
          l.property_id,
          p.display_name                                           as property_name,
          l.unit_id,
          coalesce(nullif(trim(u.label), ''), 'Unlabelled Unit')  as unit_label,
          coalesce(nullif(trim(u.block), ''), null)               as unit_block,
          coalesce(nullif(trim(u.floor), ''), null)               as unit_floor,

          -- Tenant identity: prefer name from lease, fall back to latest invite
          coalesce(
            nullif(trim(l.tenant_name), ''),
            nullif(trim(i.invited_name), ''),
            coalesce(l.tenant_user_id::text, null)
          )                                                        as tenant_name,
          coalesce(l.tenant_user_id::text, i.linked_user_id::text) as tenant_id,
          coalesce(i.invited_email, '')                            as tenant_email,
          coalesce(i.invited_phone_number, '')                     as tenant_phone,

          l.lease_type::text,
          l.start_date,
          l.end_date,
          l.rent_amount,
          l.currency_code,
          l.billing_cycle::text,
          l.status::text                                           as db_status,
          l.confirmation_status::text,
          l.agreement_notes                                        as special_conditions,

          -- Computed UI status
          case
            when l.confirmation_status = 'disputed'               then 'disputed'
            when l.status in ('terminated_early', 'overstayed')   then 'terminated'
            when l.status = 'disputed'                             then 'disputed'
            when l.end_date is not null
              and l.end_date < current_date
              and l.status not in ('terminated_early', 'disputed') then 'expired'
            when l.lease_type = 'month_to_month'
              and l.status in ('active', 'confirmed')              then 'month_to_month'
            when l.end_date is not null
              and l.end_date between current_date and current_date + interval '60 days'
              and l.status in ('active', 'confirmed')              then 'expiring_soon'
            when l.status in ('active', 'confirmed')               then 'active'
            when l.status = 'pending_confirmation'                 then 'pending_confirmation'
            else l.status::text
          end                                                       as ui_status,

          -- Days remaining (null for month-to-month or no end date)
          case when l.end_date is not null
               then (l.end_date - current_date)::integer
               else null
          end                                                       as days_remaining,

          -- Document count from V 1 26 table
          (
            select count(*)::integer
            from app.lease_documents d
            where d.lease_agreement_id = l.id
              and d.status = 'uploaded'
          )                                                         as document_count,

          -- Has formal acceptance record (V 1 26)
          exists (
            select 1 from app.lease_acceptance_records ar
            where ar.lease_agreement_id = l.id
          )                                                         as has_acceptance_record,

          -- Accepted full name (for evidence display)
          (
            select ar.accepted_full_name
            from app.lease_acceptance_records ar
            where ar.lease_agreement_id = l.id
            limit 1
          )                                                         as accepted_full_name,

          -- Accepted at timestamp
          (
            select ar.recorded_at
            from app.lease_acceptance_records ar
            where ar.lease_agreement_id = l.id
            limit 1
          )                                                         as accepted_at,

          -- Template info
          ltv.version_label                                         as template_version_label,
          lt.name                                                   as template_name,
          lt.id                                                     as template_id,

          -- Renewal: is there a newer active lease for the same unit?
          exists (
            select 1 from app.lease_agreements l2
            where l2.unit_id = l.unit_id
              and l2.id <> l.id
              and l2.created_at > l.created_at
              and l2.status in ('active', 'confirmed', 'pending_confirmation')
          )                                                         as is_renewed,

          l.created_at,
          l.updated_at

        from app.lease_agreements l
        join app.units u       on u.id = l.unit_id     and u.deleted_at is null
        join app.properties p  on p.id = l.property_id and p.deleted_at is null
        -- Latest invite for this lease (lateral)
        left join lateral (
          select invited_name, invited_email, invited_phone_number, linked_user_id
          from app.tenant_invitations ti
          where ti.lease_agreement_id = l.id
          order by ti.created_at desc
          limit 1
        ) i on true
        -- Template version
        left join app.lease_template_versions ltv on ltv.id = l.template_version_id
        left join app.lease_templates lt           on lt.id = ltv.template_id

        where p.deleted_at is null
          and (p_property_id is null or l.property_id = p_property_id)
          and (
            p.workspace_id in (
              select w.id from app.workspaces w
              where w.owner_user_id = auth.uid()
            )
            or exists (
              select 1 from app.workspace_memberships wm
              where wm.workspace_id = p.workspace_id
                and wm.user_id = auth.uid()
                and wm.status = 'active'
            )
          )
      ) row
    ),
    '[]'::jsonb
  );
end;
$$;

-- ─── get_lease_portfolio_summary ─────────────────────────────────────────────

create or replace function app.get_lease_portfolio_summary(
  p_property_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = app, public
as $$
declare
  v_total_active        integer := 0;
  v_expiring_30         integer := 0;
  v_expiring_60         integer := 0;
  v_expiring_90         integer := 0;
  v_expired             integer := 0;
  v_disputed            integer := 0;
  v_month_to_month      integer := 0;
  v_documents_on_file   integer := 0;
  v_pending_accept      integer := 0;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  select
    count(*) filter (
      where l.status in ('active', 'confirmed')
        and (l.end_date is null or l.end_date >= current_date)
        and l.confirmation_status <> 'disputed'
        and l.lease_type <> 'month_to_month'
    ),
    count(*) filter (
      where l.status in ('active', 'confirmed')
        and l.end_date between current_date and current_date + interval '30 days'
        and l.confirmation_status <> 'disputed'
    ),
    count(*) filter (
      where l.status in ('active', 'confirmed')
        and l.end_date between current_date + interval '1 day' and current_date + interval '60 days'
        and l.confirmation_status <> 'disputed'
    ),
    count(*) filter (
      where l.status in ('active', 'confirmed')
        and l.end_date between current_date + interval '1 day' and current_date + interval '90 days'
        and l.confirmation_status <> 'disputed'
    ),
    count(*) filter (
      where (l.end_date is not null and l.end_date < current_date
             and l.status not in ('terminated_early', 'disputed'))
        or l.status = 'expired'
    ),
    count(*) filter (
      where l.confirmation_status = 'disputed' or l.status = 'disputed'
    ),
    count(*) filter (
      where l.lease_type = 'month_to_month'
        and l.status in ('active', 'confirmed')
        and l.confirmation_status <> 'disputed'
    ),
    count(*) filter (
      where l.status = 'pending_confirmation'
    )
  into
    v_total_active,
    v_expiring_30,
    v_expiring_60,
    v_expiring_90,
    v_expired,
    v_disputed,
    v_month_to_month,
    v_pending_accept
  from app.lease_agreements l
  join app.properties p on p.id = l.property_id and p.deleted_at is null
  where (p_property_id is null or l.property_id = p_property_id)
    and (
      p.workspace_id in (select w.id from app.workspaces w where w.owner_user_id = auth.uid())
      or exists (
        select 1 from app.workspace_memberships wm
        where wm.workspace_id = p.workspace_id
          and wm.user_id = auth.uid()
          and wm.status = 'active'
      )
    );

  -- Count leases that have at least one uploaded document
  select count(distinct d.lease_agreement_id)::integer
  into v_documents_on_file
  from app.lease_documents d
  join app.lease_agreements l on l.id = d.lease_agreement_id
  join app.properties p        on p.id = l.property_id and p.deleted_at is null
  where d.status = 'uploaded'
    and (p_property_id is null or l.property_id = p_property_id)
    and (
      p.workspace_id in (select w.id from app.workspaces w where w.owner_user_id = auth.uid())
      or exists (
        select 1 from app.workspace_memberships wm
        where wm.workspace_id = p.workspace_id
          and wm.user_id = auth.uid()
          and wm.status = 'active'
      )
    );

  return jsonb_build_object(
    'total_active',      v_total_active,
    'expiring_in_30',    v_expiring_30,
    'expiring_in_60',    v_expiring_60,
    'expiring_in_90',    v_expiring_90,
    'expired',           v_expired,
    'disputed',          v_disputed,
    'month_to_month',    v_month_to_month,
    'pending_accept',    v_pending_accept,
    'documents_on_file', v_documents_on_file
  );
end;
$$;

-- ─── Grants ───────────────────────────────────────────────────────────────────

revoke all on function app.get_lease_directory(uuid)         from public, anon, authenticated;
revoke all on function app.get_lease_portfolio_summary(uuid) from public, anon, authenticated;

grant execute on function app.get_lease_directory(uuid)         to authenticated;
grant execute on function app.get_lease_portfolio_summary(uuid) to authenticated;
