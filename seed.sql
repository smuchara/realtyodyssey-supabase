-- ============================================================================
-- RealtyOdyssey — Local Demo Seed Data
-- ============================================================================
-- Populates a database with a large, realistic, internally consistent demo
-- portfolio spanning multiple countries: ~15 properties of every type across
-- major world cities, ~90 units, dozens of tenancies each with between one
-- month and two years of rent-collection history (so collection-trend charts
-- have real depth), a maintenance pipeline that exercises every ticket state,
-- QR access control, guest passes, a security team, a community feed, and
-- the reference records the admin web app's dashboards read from.
--
-- The workspace owner is an EXISTING account (yidad43473@fisedo.com,
-- created through the real signup flow) — this script does not create that
-- account or touch its password, it only attaches a workspace + all of the
-- above data to it, and upgrades it to a Property Management Company account
-- so the PMC-only pages actually show up. A workspace is only created for it
-- if one doesn't already exist. Every OTHER seeded person (staff, tenants,
-- fundis, security guards) is a fabricated account this script creates, and
-- all of those share one password: Demo@2026!
--
-- Usage:
--   Run this file directly in the Supabase SQL editor against the target
--   project. It is not idempotent — re-running it against a database that
--   already has this data will fail on unique-constraint violations.
--
-- Design notes (read before editing):
--   - The Supabase CLI's seed runner validates every top-level statement in
--     this file against the schema as migrations left it, before any of
--     THIS file's own statements have run. A later statement can therefore
--     never reference a table/view this file itself created earlier (e.g. a
--     staging table) — only tables the migrations already created. Anything
--     that needs to chain several dependent inserts together is written as
--     one PL/pgSQL DO block (which runs procedurally, so this restriction
--     doesn't apply inside it) or as a single WITH-chained statement.
--   - app.units has an AFTER INSERT trigger (trg_units_create_occupancy_snapshot)
--     that auto-creates a 'vacant' app.unit_occupancy_snapshots row for every
--     unit the moment it's inserted. Every later write to that table in this
--     file is therefore an UPSERT (`on conflict (unit_id) do update`), never
--     a plain INSERT — the row already exists.
--   - A fixed setseed() call up front makes the "random" mix of paid/late/
--     overdue tenants, ticket states, etc. reproducible across reseeds.
-- ============================================================================

set search_path = app, public, extensions;
select setseed(0.42);

-- ----------------------------------------------------------------------------
-- 0. Every Supabase Auth account this demo needs, created up front
-- ----------------------------------------------------------------------------
-- app.handle_new_user() (AFTER INSERT trigger on auth.users) reads
-- raw_user_meta_data.first_name / last_name / account_type (and, for PMC
-- accounts, company_name / primary_contact_name / primary_contact_phone)
-- and creates the matching app.profiles row automatically.

do $$
declare
  v_row record;
  v_id  uuid;
begin
  for v_row in
    select * from (values
      ('david.otieno@ridgewayproperties.demo', 'David', 'Otieno', 'owner', '{}'::jsonb),
      ('faith.njeri@ridgewayproperties.demo', 'Faith', 'Njeri', 'owner', '{}'::jsonb),
      ('peter.kamau@ridgewayproperties.demo', 'Peter', 'Kamau', 'owner', '{}'::jsonb),
      ('kennedy.otieno@fundi.demo', 'Kennedy', 'Otieno', 'resident', '{}'::jsonb),
      ('mary.wanjala@fundi.demo', 'Mary', 'Wanjala', 'resident', '{}'::jsonb),
      ('alice.wambugu@fundi.demo', 'Alice', 'Wambugu', 'resident', '{}'::jsonb),
      ('chidi.okafor@fundi.demo', 'Chidi', 'Okafor', 'resident', '{}'::jsonb),
      ('joseph.mutua@ridgewaysecurity.demo', 'Joseph', 'Mutua', 'resident', '{}'::jsonb),
      ('irene.chepkoech@ridgewaysecurity.demo', 'Irene', 'Chepkoech', 'resident', '{}'::jsonb),
      ('grace.adeyemi@ridgewaysecurity.demo', 'Grace', 'Adeyemi', 'resident', '{}'::jsonb),
      ('liu.wei@ridgewaysecurity.demo', 'Liu', 'Wei', 'resident', '{}'::jsonb)
    ) as t(email, first_name, last_name, account_type, extra_meta)
  loop
    v_id := gen_random_uuid();

    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
      last_sign_in_at, raw_app_meta_data, raw_user_meta_data,
      created_at, updated_at,
      confirmation_token, email_change, email_change_token_new, recovery_token
    ) values (
      '00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated',
      v_row.email, extensions.crypt('Demo@2026!', extensions.gen_salt('bf')), now(),
      now(),
      '{"provider":"email","providers":["email"]}'::jsonb,
      (jsonb_build_object('first_name', v_row.first_name, 'last_name', v_row.last_name, 'account_type', v_row.account_type) || v_row.extra_meta),
      now(), now(),
      '', '', '', ''
    );

    insert into auth.identities (
      id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at
    ) values (
      gen_random_uuid(), v_id, v_id::text,
      jsonb_build_object('sub', v_id::text, 'email', v_row.email),
      'email', now(), now(), now()
    );

    insert into public.profiles (user_id, username, avatar_url)
    values (v_id, split_part(v_row.email, '@', 1), 'https://i.pravatar.cc/300?u=' || v_row.email);
  end loop;
end $$;

-- ----------------------------------------------------------------------------
-- 1. Workspace + PMC owner + staff
-- ----------------------------------------------------------------------------
-- The workspace owner is YOUR existing account (yidad43473@fisedo.com,
-- created through the real signup flow) rather than a fabricated user.
-- Everything below is written to work whether or not that account already
-- has a workspace: a new one is only created if it doesn't.

-- Upgrade the existing account to a Property Management Company so the
-- PMC-gated pages (QR access, guest invites, security team) actually show
-- up in the app for it, not just in the database.
update app.profiles
set account_type = 'property_management_company',
    company_name = coalesce(company_name, coalesce(first_name || ' ', '') || coalesce(last_name, '') || ' Properties'),
    primary_contact_name = coalesce(primary_contact_name, nullif(trim(coalesce(first_name, '') || ' ' || coalesce(last_name, '')), '')),
    updated_at = now()
where id = (select id from auth.users where email = 'yidad43473@fisedo.com');

insert into app.workspaces (name, slug, owner_user_id, created_by)
select coalesce(pr.company_name, 'My Property Portfolio'),
       'demo-portfolio-' || substr(u.id::text, 1, 8),
       u.id, u.id
from auth.users u
left join app.profiles pr on pr.id = u.id
where u.email = 'yidad43473@fisedo.com'
  and not exists (select 1 from app.workspaces w where w.owner_user_id = u.id);

insert into app.workspace_memberships (workspace_id, user_id, role, status)
select w.id, u.id, 'workspace_admin', 'active'
from auth.users u
join app.workspaces w on w.owner_user_id = u.id
where u.email = 'yidad43473@fisedo.com'
  and not exists (
    select 1 from app.workspace_memberships wm where wm.workspace_id = w.id and wm.user_id = u.id
  );

insert into app.workspace_memberships (workspace_id, user_id, role, status)
select (select id from app.workspaces where owner_user_id = (select id from auth.users where email = 'yidad43473@fisedo.com')), u.id, 'workspace_member', 'active'
from auth.users u
where u.email in (
  'david.otieno@ridgewayproperties.demo',
  'faith.njeri@ridgewayproperties.demo',
  'peter.kamau@ridgewayproperties.demo'
);

-- ----------------------------------------------------------------------------
-- 2. Properties — a global portfolio, every property type represented
-- ----------------------------------------------------------------------------

insert into app.properties (
  workspace_id, property_type_id, usage_type_id, status, display_name,
  internal_ref_code, city_town, area_neighborhood, address_description,
  map_source_id, latitude, longitude, map_label,
  identity_completed_at, onboarding_completed_at, current_step_key, last_activity_at,
  created_by
)
select
  (select id from app.workspaces where owner_user_id = (select id from auth.users where email = 'yidad43473@fisedo.com')),
  (select id from app.lookup_property_types where code = v.ptype),
  (select id from app.lookup_usage_types where code = v.usage_code),
  'active', v.display_name, v.ref_code, v.city, v.area,
  v.area || ', ' || v.city || ', ' || v.country,
  (select id from app.lookup_map_sources where code = 'GOOGLE_MAPS'),
  v.lat, v.lng, v.display_name || ', ' || v.city,
  now() - ((90 + (random() * 500)::int) || ' days')::interval,
  now() - ((80 + (random() * 480)::int) || ' days')::interval,
  'completed', now() - (( 1 + (random()*72)::int) || ' hours')::interval,
  (select id from auth.users where email = 'yidad43473@fisedo.com')
from (values
  ('Ridgeway Heights Apartments','APARTMENT','LONG_TERM','RHA-001','Nairobi','Kilimani','Kenya',-1.2921,36.7872),
  ('Greenwood Court','APARTMENT','LONG_TERM','GWC-002','Nairobi','Lavington','Kenya',-1.2777,36.7688),
  ('Karen Acacia House','HOUSE','LONG_TERM','KAH-003','Nairobi','Karen','Kenya',-1.3197,36.6859),
  ('Sunrise Business Park','COMMERCIAL','MIXED','SBP-004','Nairobi','Westlands','Kenya',-1.2648,36.8033),
  ('Lagos Marina Towers','APARTMENT','LONG_TERM','LMT-005','Lagos','Victoria Island','Nigeria',6.4281,3.4219),
  ('Victoria Island Business Centre','BUILDING','MIXED','VBC-006','Lagos','Victoria Island','Nigeria',6.4304,3.4241),
  ('Cape Town Waterfront Residences','APARTMENT','LONG_TERM','CWR-007','Cape Town','V&A Waterfront','South Africa',-33.9036,18.4200),
  ('Thames View Apartments','APARTMENT','LONG_TERM','TVA-008','London','Southbank','United Kingdom',51.5045,-0.0865),
  ('Canary Wharf Office Suites','COMMERCIAL','MIXED','CWO-009','London','Canary Wharf','United Kingdom',51.5054,-0.0235),
  ('Dubai Marina Heights','APARTMENT','LONG_TERM','DMH-010','Dubai','Dubai Marina','United Arab Emirates',25.0805,55.1403),
  ('Manhattan Skyline Lofts','APARTMENT','LONG_TERM','MSL-011','New York','Midtown','United States',40.7549,-73.9840),
  ('Toronto Harbourfront Suites','APARTMENT','LONG_TERM','THS-012','Toronto','Harbourfront','Canada',43.6389,-79.3805),
  ('Sydney Harbour Residences','APARTMENT','LONG_TERM','SHR-013','Sydney','Circular Quay','Australia',-33.8610,151.2107),
  ('Mumbai Business Hub','BUILDING','MIXED','MBH-014','Mumbai','Bandra Kurla Complex','India',19.0656,72.8683),
  ('Berlin Mitte Lofts','APARTMENT','LONG_TERM','BML-015','Berlin','Mitte','Germany',52.5200,13.4050)
) as v(display_name, ptype, usage_code, ref_code, city, area, country, lat, lng);

insert into app.property_admin_contacts (property_id, mode, contact_name, contact_email, contact_phone, linked_user_id, created_by)
select p.id, 'SELF',
       coalesce(pr.primary_contact_name, nullif(trim(coalesce(pr.first_name, '') || ' ' || coalesce(pr.last_name, '')), ''), 'Property Owner'),
       'yidad43473@fisedo.com', pr.primary_contact_phone,
       u.id, u.id
from app.properties p
join auth.users u on u.email = 'yidad43473@fisedo.com'
left join app.profiles pr on pr.id = u.id
where p.workspace_id = (select id from app.workspaces where owner_user_id = u.id);

insert into app.property_memberships (property_id, user_id, role_id, domain_scope_id, status, granted_by)
select p.id, u.id, r.id,
       (select id from app.lookup_domain_scopes where code = 'FULL_PROPERTY'),
       'active',
       (select id from auth.users where email = 'yidad43473@fisedo.com')
from app.properties p
cross join (values
  ('david.otieno@ridgewayproperties.demo', 'PROPERTY_MANAGER'),
  ('faith.njeri@ridgewayproperties.demo', 'CARETAKER'),
  ('peter.kamau@ridgewayproperties.demo', 'LEGAL')
) as s(email, role_key)
join auth.users u on u.email = s.email
join app.roles r on r.key = s.role_key
where p.workspace_id = (select id from app.workspaces where owner_user_id = (select id from auth.users where email = 'yidad43473@fisedo.com'));

insert into app.community_zones (workspace_id, property_id, center_lat, center_lng, radius_km, title, auto_title, color)
select (select id from app.workspaces where owner_user_id = (select id from auth.users where email = 'yidad43473@fisedo.com')), p.id,
       p.latitude, p.longitude, 10, p.display_name || ' Community', p.area_neighborhood || ', ' || p.city_town, '#3b82f6'
from app.properties p
where p.workspace_id = (select id from app.workspaces where owner_user_id = (select id from auth.users where email = 'yidad43473@fisedo.com'));

-- ----------------------------------------------------------------------------
-- 3. Units — a varied mix of sizes and layouts per property
-- ----------------------------------------------------------------------------

do $$
declare
  v_prop        record;
  v_workspace_id uuid;
  n             int;
  v_preset      text;
  v_bed         int;
  v_bath        int;
  v_rent        numeric(12,2);
  v_label       text;
  presets       text[] := array['BEDSITTER','STUDIO','1BR','2BR','3BR'];
  beds          int[]  := array[0,0,1,2,3];
  baths         int[]  := array[1,1,1,2,2];
  idx           int;
begin
  select w.id into v_workspace_id
  from app.workspaces w
  join auth.users u on u.id = w.owner_user_id
  where u.email = 'yidad43473@fisedo.com';

  for v_prop in
    select p.id, p.display_name, v.base_rent, v.unit_count, v.ptype
    from app.properties p
    join (values
      ('Ridgeway Heights Apartments', 25000::numeric, 8, 'APARTMENT'),
      ('Greenwood Court', 32000::numeric, 6, 'APARTMENT'),
      ('Karen Acacia House', 120000::numeric, 1, 'HOUSE'),
      ('Sunrise Business Park', 90000::numeric, 4, 'COMMERCIAL'),
      ('Lagos Marina Towers', 380000::numeric, 9, 'APARTMENT'),
      ('Victoria Island Business Centre', 550000::numeric, 5, 'BUILDING'),
      ('Cape Town Waterfront Residences', 14000::numeric, 7, 'APARTMENT'),
      ('Thames View Apartments', 1900::numeric, 8, 'APARTMENT'),
      ('Canary Wharf Office Suites', 3200::numeric, 4, 'COMMERCIAL'),
      ('Dubai Marina Heights', 6800::numeric, 9, 'APARTMENT'),
      ('Manhattan Skyline Lofts', 3400::numeric, 7, 'APARTMENT'),
      ('Toronto Harbourfront Suites', 2500::numeric, 6, 'APARTMENT'),
      ('Sydney Harbour Residences', 3000::numeric, 6, 'APARTMENT'),
      ('Mumbai Business Hub', 180000::numeric, 5, 'BUILDING'),
      ('Berlin Mitte Lofts', 1500::numeric, 7, 'APARTMENT')
    ) as v(display_name, base_rent, unit_count, ptype) on v.display_name = p.display_name
    where p.workspace_id = v_workspace_id
  loop
    for n in 1..v_prop.unit_count loop
      if v_prop.ptype = 'HOUSE' then
        v_label := 'Main House';
        v_preset := 'CUSTOM';
        v_bed := 4; v_bath := 3;
        v_rent := v_prop.base_rent;
      elsif v_prop.ptype in ('COMMERCIAL','BUILDING') then
        v_label := 'Suite ' || lpad(n::text, 2, '0');
        v_preset := 'CUSTOM';
        v_bed := 0; v_bath := 1 + (n % 2);
        v_rent := round((v_prop.base_rent * (0.8 + random() * 0.4))::numeric, 2);
      else
        idx := 1 + (n % 5);
        v_label := 'Unit ' || (100 + n)::text;
        v_preset := presets[idx];
        v_bed := beds[idx];
        v_bath := baths[idx];
        v_rent := round((v_prop.base_rent * (0.65 + v_bed * 0.2) * (0.9 + random() * 0.2))::numeric, 2);
      end if;

      insert into app.units (property_id, label, floor, preset_id, bedrooms, bathrooms, parking, expected_rate)
      values (
        v_prop.id, v_label, 'Floor ' || (1 + (n % 6))::text,
        (select id from app.lookup_unit_presets where code = v_preset),
        v_bed, v_bath, (n % 3), v_rent
      );
    end loop;
  end loop;
end $$;

-- ----------------------------------------------------------------------------
-- 4. Payment collection setups — one per property
-- ----------------------------------------------------------------------------

insert into app.payment_collection_setups (
  workspace_id, property_id, scope_type, payment_method_type, lifecycle_status, is_default, priority_rank,
  display_name, account_name, paybill_number, account_reference_hint, collection_instructions,
  activated_at, created_by_user_id, mpesa_c2b_registration_status, mpesa_c2b_registered_at
)
select
  (select id from app.workspaces where owner_user_id = (select id from auth.users where email = 'yidad43473@fisedo.com')), p.id,
  'property', v.method::app.payment_method_type_enum, 'active', true, 1,
  p.display_name || ' Collections',
  coalesce((select company_name from app.profiles where id = (select id from auth.users where email = 'yidad43473@fisedo.com')), 'Property Owner'),
  v.paybill,
  'Use your unit number as the account reference',
  case when v.method = 'mpesa_paybill' then 'Pay via M-Pesa > Lipa na M-Pesa > Pay Bill'
       else 'Pay via bank transfer using the account details on your invoice' end,
  now() - interval '100 days',
  (select id from auth.users where email = 'yidad43473@fisedo.com'),
  case when v.method = 'mpesa_paybill' then 'registered' else 'not_required' end::app.mpesa_registration_status_enum,
  case when v.method = 'mpesa_paybill' then now() - interval '95 days' else null end
from app.properties p
join (values
  ('Ridgeway Heights Apartments', 'mpesa_paybill', '400200'),
  ('Greenwood Court', 'mpesa_paybill', '400201'),
  ('Karen Acacia House', 'mpesa_paybill', '400202'),
  ('Sunrise Business Park', 'mpesa_paybill', '400203'),
  ('Lagos Marina Towers', 'bank_transfer', null),
  ('Victoria Island Business Centre', 'bank_transfer', null),
  ('Cape Town Waterfront Residences', 'bank_transfer', null),
  ('Thames View Apartments', 'bank_transfer', null),
  ('Canary Wharf Office Suites', 'bank_transfer', null),
  ('Dubai Marina Heights', 'bank_transfer', null),
  ('Manhattan Skyline Lofts', 'bank_transfer', null),
  ('Toronto Harbourfront Suites', 'bank_transfer', null),
  ('Sydney Harbour Residences', 'bank_transfer', null),
  ('Mumbai Business Hub', 'bank_transfer', null),
  ('Berlin Mitte Lofts', 'bank_transfer', null)
) as v(display_name, method, paybill) on v.display_name = p.display_name
where p.workspace_id = (select id from app.workspaces where owner_user_id = (select id from auth.users where email = 'yidad43473@fisedo.com'));

-- ----------------------------------------------------------------------------
-- 5. Fundis / service providers
-- ----------------------------------------------------------------------------

insert into app.fundi_profiles (workspace_id, name, specialty, location, phone, rating, completed_jobs, available, user_id)
values
  ((select id from app.workspaces where owner_user_id = (select id from auth.users where email = 'yidad43473@fisedo.com')), 'Kennedy Otieno', 'Plumbing', 'Nairobi, Kenya', '+254733200001', 4.80, 34, true, (select id from auth.users where email='kennedy.otieno@fundi.demo')),
  ((select id from app.workspaces where owner_user_id = (select id from auth.users where email = 'yidad43473@fisedo.com')), 'Mary Wanjala', 'Electrical', 'Nairobi, Kenya', '+254733200002', 4.60, 21, true, (select id from auth.users where email='mary.wanjala@fundi.demo')),
  ((select id from app.workspaces where owner_user_id = (select id from auth.users where email = 'yidad43473@fisedo.com')), 'Alice Wambugu', 'Painting', 'Nairobi, Kenya', '+254733200003', 4.90, 40, true, (select id from auth.users where email='alice.wambugu@fundi.demo')),
  ((select id from app.workspaces where owner_user_id = (select id from auth.users where email = 'yidad43473@fisedo.com')), 'Chidi Okafor', 'Electrical', 'Lagos, Nigeria', '+234801200004', 4.70, 28, true, (select id from auth.users where email='chidi.okafor@fundi.demo')),
  ((select id from app.workspaces where owner_user_id = (select id from auth.users where email = 'yidad43473@fisedo.com')), 'Peter Njoroge', 'General Repairs', 'Nairobi, Kenya', '+254733200005', 4.20, 15, true, null),
  ((select id from app.workspaces where owner_user_id = (select id from auth.users where email = 'yidad43473@fisedo.com')), 'Samuel Kiprotich', 'HVAC', 'Nairobi, Kenya', '+254733200006', 4.00, 9, false, null),
  ((select id from app.workspaces where owner_user_id = (select id from auth.users where email = 'yidad43473@fisedo.com')), 'Sipho Nkosi', 'Plumbing', 'Cape Town, South Africa', '+27821200007', 4.50, 19, true, null),
  ((select id from app.workspaces where owner_user_id = (select id from auth.users where email = 'yidad43473@fisedo.com')), 'Liam O''Connor', 'General Repairs', 'London, United Kingdom', '+447911200008', 4.30, 12, true, null);

insert into app.vendor_invites (workspace_id, profile_type, full_name, email, phone, specializations, status, invited_by)
values (
  (select id from app.workspaces where owner_user_id = (select id from auth.users where email = 'yidad43473@fisedo.com')), 'individual', 'James Mburu',
  'james.mburu@vendor.demo', '+254733200009', array['electrical'], 'pending',
  (select id from auth.users where email='yidad43473@fisedo.com')
);

-- ----------------------------------------------------------------------------
-- 6. Lease templates
-- ----------------------------------------------------------------------------

with tpl as (
  insert into app.lease_templates (
    workspace_id, property_id, name, description, lease_type, property_category,
    default_duration_months, renewal_behavior, notice_period_days, status, created_by
  ) values (
    (select id from app.workspaces where owner_user_id = (select id from auth.users where email = 'yidad43473@fisedo.com')),
    null, 'Standard Residential Lease',
    'Default fixed-term residential lease used across all apartment and house units worldwide.',
    'fixed_term', 'apartment', 12, 'manual', 60, 'active',
    (select id from auth.users where email = 'yidad43473@fisedo.com')
  )
  returning id
)
insert into app.lease_template_versions (
  template_id, version_number, version_label, sections, placeholder_keys, status, published_at, published_by, created_by
)
select tpl.id, 1, 'v1.0',
  jsonb_build_array(
    jsonb_build_object('key','parties','title','Parties to the Agreement','body','This agreement is made between {{landlord_name}} ("the Landlord") and {{tenant_name}} ("the Tenant") for the unit at {{property_name}}, {{unit_label}}.'),
    jsonb_build_object('key','term','title','Term','body','This lease shall run for a fixed term commencing on {{start_date}} and ending on {{end_date}}, unless renewed or terminated earlier in accordance with this agreement.'),
    jsonb_build_object('key','rent','title','Rent','body','The Tenant shall pay rent of {{rent_amount}} per month, due on or before the {{rent_due_day}} of each month, to the Landlord''s designated collection account.'),
    jsonb_build_object('key','maintenance','title','Maintenance & Repairs','body','The Landlord shall maintain the structure, plumbing and electrical systems in good repair. The Tenant shall promptly report any defects via the tenant maintenance portal.'),
    jsonb_build_object('key','termination','title','Termination','body','Either party may terminate this agreement by providing {{notice_period_days}} days'' written notice, subject to the terms herein.')
  ),
  array['landlord_name','tenant_name','property_name','unit_label','start_date','end_date','rent_amount','rent_due_day','notice_period_days'],
  'active', now() - interval '300 days', (select id from auth.users where email = 'yidad43473@fisedo.com'),
  (select id from auth.users where email = 'yidad43473@fisedo.com')
from tpl;

with tpl as (
  insert into app.lease_templates (
    workspace_id, property_id, name, description, lease_type, property_category,
    default_duration_months, renewal_behavior, notice_period_days, status, created_by
  ) values (
    (select id from app.workspaces where owner_user_id = (select id from auth.users where email = 'yidad43473@fisedo.com')),
    (select id from app.properties where display_name = 'Sunrise Business Park'),
    'Commercial Lease Agreement', 'Lease terms for retail, office and suite units.',
    'fixed_term', 'commercial_space', 24, 'converts_to_month_to_month', 90, 'active',
    (select id from auth.users where email = 'yidad43473@fisedo.com')
  )
  returning id
)
insert into app.lease_template_versions (
  template_id, version_number, version_label, sections, placeholder_keys, status, published_at, published_by, created_by
)
select tpl.id, 1, 'v1.0',
  jsonb_build_array(
    jsonb_build_object('key','parties','title','Parties to the Agreement','body','This commercial lease is made between {{landlord_name}} and {{tenant_name}} for {{unit_label}} at {{property_name}}.'),
    jsonb_build_object('key','term','title','Term','body','The initial term is 24 months from {{start_date}} to {{end_date}}, converting to a month-to-month tenancy thereafter unless renewed.'),
    jsonb_build_object('key','rent','title','Rent & Service Charge','body','Monthly rent of {{rent_amount}} is payable in advance on or before the {{rent_due_day}} of each month, exclusive of service charge and utilities.'),
    jsonb_build_object('key','use','title','Permitted Use','body','The Tenant shall use the premises solely for lawful commercial/retail/office purposes and shall not sublet without the Landlord''s written consent.')
  ),
  array['landlord_name','tenant_name','property_name','unit_label','start_date','end_date','rent_amount','rent_due_day'],
  'active', now() - interval '280 days', (select id from auth.users where email = 'yidad43473@fisedo.com'),
  (select id from auth.users where email = 'yidad43473@fisedo.com')
from tpl;

-- ----------------------------------------------------------------------------
-- 7. Tenants + leases + up to 24 months of rent-collection history
-- ----------------------------------------------------------------------------
-- Every unit gets a roll: ~72% occupied by a tenant with an active lease
-- going back 1-24 months (full rent-charge/payment history for that whole
-- span), ~8% mid-invite (lease drafted, invitation sent/opened, no tenant
-- yet), and the rest stay vacant (already true by default — see the trigger
-- note at the top of this file).

do $$
declare
  v_owner_id     uuid;
  v_workspace_id uuid;
  v_faith_id     uuid;
  u              record;
  v_roll         numeric;
  v_first        text;
  v_last         text;
  v_tenant_id    uuid;
  v_lease_id     uuid;
  v_invite_id    uuid;
  v_access_profile_id uuid;
  v_access_token_id   uuid;
  v_currency     text;
  v_pay_method   text;
  v_record_source text;
  v_months_ago   int;
  v_lease_cycles int;
  v_unpaid_months int;
  v_month        int;
  v_period_start date;
  v_period_end   date;
  v_due          date;
  v_paid         boolean;
  v_pmethod_roll numeric;
  v_charge_id    uuid;
  v_payment_id   uuid;
  v_email        text;
  first_names text[] := array['James','Mary','John','Patricia','Robert','Jennifer','Michael','Linda','David','Elizabeth','Richard','Susan','Joseph','Jessica','Thomas','Sarah','Charles','Karen','Daniel','Nancy','Kwame','Amara','Chidi','Ngozi','Sipho','Thandiwe','Amit','Priya','Arjun','Divya','Liam','Olivia','Noah','Emma','Wei','Mei','Ahmed','Fatima','Omar','Layla','Carlos','Sofia','Diego','Valentina','Wanjiru','Otieno','Njoroge','Achieng','Kagiso','Nomvula'];
  last_names  text[] := array['Mwangi','Kariuki','Otieno','Adeyemi','Okafor','Nkosi','Dlamini','Smith','Johnson','Williams','Brown','Taylor','Anderson','Thomas','Patel','Sharma','Khan','Ali','Garcia','Martinez','Rossi','Muller','Schmidt','Nguyen','Tanaka','Kim','Silva','Costa','Novak','Kowalski','Wanjiru','Njoroge','Achieng','Kamau','Wambugu'];
begin
  select id into v_owner_id from auth.users where email = 'yidad43473@fisedo.com';
  select id into v_workspace_id from app.workspaces where owner_user_id = v_owner_id;
  select id into v_faith_id from auth.users where email = 'faith.njeri@ridgewayproperties.demo';

  for u in
    select un.id as unit_id, un.property_id, un.expected_rate, p.city_town, p.display_name
    from app.units un
    join app.properties p on p.id = un.property_id
    where p.workspace_id = v_workspace_id
    order by un.id
  loop
    v_currency := case u.city_town
      when 'Nairobi' then 'KES' when 'Lagos' then 'NGN' when 'Cape Town' then 'ZAR'
      when 'London' then 'GBP' when 'Dubai' then 'AED' when 'New York' then 'USD'
      when 'Toronto' then 'CAD' when 'Sydney' then 'AUD' when 'Mumbai' then 'INR'
      when 'Berlin' then 'EUR' else 'KES' end;

    v_roll := random();

    if v_roll < 0.72 then
      -- Occupied: create the tenant and their full history.
      v_first := first_names[1 + floor(random() * array_length(first_names, 1))::int];
      v_last  := last_names[1 + floor(random() * array_length(last_names, 1))::int];
      v_email := lower(v_first) || '.' || lower(v_last) || '.' || substr(u.unit_id::text, 1, 6) || '@tenant.demo';
      v_tenant_id := gen_random_uuid();

      insert into auth.users (
        instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
        last_sign_in_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
        confirmation_token, email_change, email_change_token_new, recovery_token
      ) values (
        '00000000-0000-0000-0000-000000000000', v_tenant_id, 'authenticated', 'authenticated',
        v_email, extensions.crypt('Demo@2026!', extensions.gen_salt('bf')), now(), now(),
        '{"provider":"email","providers":["email"]}'::jsonb,
        jsonb_build_object('first_name', v_first, 'last_name', v_last, 'account_type', 'resident'),
        now(), now(), '', '', '', ''
      );
      insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
      values (gen_random_uuid(), v_tenant_id, v_tenant_id::text, jsonb_build_object('sub', v_tenant_id::text, 'email', v_email), 'email', now(), now(), now());
      insert into public.profiles (user_id, username, avatar_url)
      values (v_tenant_id, split_part(v_email, '@', 1), 'https://i.pravatar.cc/300?u=' || v_email);

      v_months_ago := 1 + floor(random() * 24)::int;
      -- A 12-month lease term renews in place: whichever 12-month boundary
      -- from start_date is the next one at/after today is the current
      -- term's end_date. This makes end dates land naturally across the
      -- next 12 months (some soon, some far off) instead of every lease
      -- always having exactly 12 months left, which is what left the
      -- 30/60/90-day Lease Expiry Forecast permanently empty.
      v_lease_cycles := floor(v_months_ago::numeric / 12)::int + 1;
      v_unpaid_months := case
        when random() < 0.75 then 0
        when random() < 0.90 then 1
        when random() < 0.97 then 2
        else 3
      end;

      insert into app.lease_agreements (
        property_id, unit_id, tenant_user_id, tenant_name, tenant_phone, entered_by_user_id,
        lease_type, start_date, end_date, billing_cycle, rent_due_day_of_month,
        rent_amount, currency_code, status, confirmation_status, tenant_confirmed_at, agreement_notes
      ) values (
        u.property_id, u.unit_id, v_tenant_id, v_first || ' ' || v_last, '+254700' || lpad((100000 + floor(random()*899999))::int::text, 6, '0'),
        v_owner_id, 'fixed_term',
        (current_date - (v_months_ago || ' months')::interval)::date,
        (current_date - (v_months_ago || ' months')::interval + ((v_lease_cycles * 12) || ' months')::interval)::date,
        'monthly', 5, u.expected_rate, v_currency, 'active', 'confirmed',
        current_date - (v_months_ago || ' months')::interval + interval '1 day',
        'Seeded demo lease agreement.'
      ) returning id into v_lease_id;

      insert into app.tenant_invitations (
        property_id, unit_id, lease_agreement_id, invited_by_user_id, linked_user_id,
        invited_email, invited_name, delivery_channel, token_hash, status,
        sent_at, opened_at, signup_started_at, expires_at, accepted_at,
        pmc_company_id, occupant_type
      ) values (
        u.property_id, u.unit_id, v_lease_id, v_owner_id, v_tenant_id,
        v_email, v_first || ' ' || v_last, 'email',
        encode(extensions.gen_random_bytes(24), 'hex'), 'accepted',
        current_date - (v_months_ago || ' months')::interval,
        current_date - (v_months_ago || ' months')::interval + interval '2 hours',
        current_date - (v_months_ago || ' months')::interval + interval '3 hours',
        current_date - (v_months_ago || ' months')::interval + interval '10 days',
        current_date - (v_months_ago || ' months')::interval + interval '1 day',
        v_owner_id, 'tenant_occupant'
      ) returning id into v_invite_id;

      insert into app.unit_tenancies (
        property_id, unit_id, lease_agreement_id, tenant_invitation_id, tenant_user_id,
        status, starts_on, activated_at, created_by_user_id, pmc_company_id, occupant_type
      ) values (
        u.property_id, u.unit_id, v_lease_id, v_invite_id, v_tenant_id,
        'active', (current_date - (v_months_ago || ' months')::interval)::date,
        current_date - (v_months_ago || ' months')::interval + interval '1 day',
        v_owner_id, v_owner_id, 'tenant_occupant'
      );

      insert into app.lease_acceptance_records (
        property_id, unit_id, lease_agreement_id, tenant_invitation_id, tenant_user_id, accepted_by_user_id,
        accepted_full_name, checkbox_confirmed, acceptance_method, accepted_at
      ) values (
        u.property_id, u.unit_id, v_lease_id, v_invite_id, v_tenant_id, v_tenant_id,
        v_first || ' ' || v_last, true, 'checkbox_acknowledgment',
        current_date - (v_months_ago || ' months')::interval + interval '1 day'
      );

      insert into app.unit_occupancy_snapshots (
        property_id, unit_id, occupancy_status, current_lease_agreement_id, current_tenant_invitation_id,
        current_tenant_user_id, current_tenant_name, current_tenant_phone,
        occupancy_started_at, last_occupied_at, last_status_changed_at, created_by
      ) values (
        u.property_id, u.unit_id, 'occupied', v_lease_id, v_invite_id, v_tenant_id,
        v_first || ' ' || v_last, null,
        current_date - (v_months_ago || ' months')::interval + interval '1 day',
        current_date - (v_months_ago || ' months')::interval + interval '1 day',
        current_date - (v_months_ago || ' months')::interval + interval '1 day',
        v_owner_id
      )
      on conflict (unit_id) do update set
        occupancy_status = excluded.occupancy_status,
        current_lease_agreement_id = excluded.current_lease_agreement_id,
        current_tenant_invitation_id = excluded.current_tenant_invitation_id,
        current_tenant_user_id = excluded.current_tenant_user_id,
        current_tenant_name = excluded.current_tenant_name,
        current_tenant_phone = excluded.current_tenant_phone,
        occupancy_started_at = excluded.occupancy_started_at,
        last_occupied_at = excluded.last_occupied_at,
        last_status_changed_at = excluded.last_status_changed_at,
        updated_at = now();

      -- QR access (PMC-managed workspace).
      insert into app.access_profiles (
        user_id, pmc_company_id, property_id, unit_id, occupant_type, lease_agreement_id, tenant_invitation_id,
        status, activated_at
      ) values (
        v_tenant_id, v_owner_id, u.property_id, u.unit_id, 'tenant_occupant', v_lease_id, v_invite_id,
        'active', current_date - (v_months_ago || ' months')::interval + interval '1 day'
      ) returning id into v_access_profile_id;

      insert into app.access_tokens (access_profile_id, token_value, token_hash, status, valid_from, valid_until)
      values (
        v_access_profile_id, 'RGW-' || upper(substr(md5(v_access_profile_id::text), 1, 10)),
        encode(extensions.digest(v_access_profile_id::text, 'sha256'), 'hex'),
        'active', now() - interval '1 day', now() + interval '6 days'
      ) returning id into v_access_token_id;

      insert into app.access_events (access_profile_id, access_token_id, event_type, pmc_company_id, property_id, unit_id, scanned_by, event_at)
      values (v_access_profile_id, v_access_token_id, 'check_in', v_owner_id, u.property_id, u.unit_id, v_faith_id, now() - interval '3 days');

      if random() < 0.5 then
        insert into app.access_events (access_profile_id, access_token_id, event_type, pmc_company_id, property_id, unit_id, scanned_by, event_at)
        values (v_access_profile_id, v_access_token_id, 'check_out', v_owner_id, u.property_id, u.unit_id, v_faith_id, now() - interval '2 days');
      end if;

      insert into app.community_zone_members (community_zone_id, user_id, property_id)
      select cz.id, v_tenant_id, u.property_id from app.community_zones cz where cz.property_id = u.property_id;

      -- Rent history: every billing month from lease start through now.
      v_pay_method := case when v_currency = 'KES' then 'mpesa_paybill' else 'bank_transfer' end;
      v_record_source := case when v_currency = 'KES' then 'mobile_money_import' else 'bank_statement_import' end;

      for v_month in 0..(v_months_ago - 1) loop
        v_period_start := (date_trunc('month', now()) - (v_month || ' months')::interval)::date;
        v_period_end := (v_period_start + interval '1 month' - interval '1 day')::date;
        v_due := v_period_start + 4;
        v_paid := v_month >= v_unpaid_months;

        insert into app.rent_charge_periods (
          workspace_id, property_id, unit_id, lease_agreement_id,
          billing_period_start, billing_period_end, due_on,
          scheduled_amount, amount_paid, outstanding_amount, currency_code, charge_status,
          last_payment_at, fully_paid_at, created_by_user_id
        ) values (
          v_workspace_id, u.property_id, u.unit_id, v_lease_id,
          v_period_start, v_period_end, v_due,
          u.expected_rate,
          case when v_paid then u.expected_rate else 0 end,
          case when v_paid then 0 else u.expected_rate end,
          v_currency,
          case when v_paid then 'paid' when v_due < current_date then 'overdue' else 'scheduled' end::app.rent_charge_status_enum,
          case when v_paid then (v_due - interval '1 day') else null end,
          case when v_paid then (v_due - interval '1 day') else null end,
          v_owner_id
        ) returning id into v_charge_id;

        if v_paid then
          v_pmethod_roll := random();
          insert into app.payment_records (
            workspace_id, property_id, unit_id, lease_agreement_id,
            recorded_status, record_source, allocation_status, payment_method_type,
            amount, allocated_amount, currency_code, paid_at,
            payer_name, payer_user_id, reference_code, recorded_by_user_id
          ) values (
            v_workspace_id, u.property_id, u.unit_id, v_lease_id,
            'recorded',
            case when v_pmethod_roll < 0.88 then v_record_source else 'manual_entry' end::app.payment_record_source_enum,
            'fully_applied',
            case when v_pmethod_roll < 0.88 then v_pay_method::app.payment_method_type_enum
                 when v_pmethod_roll < 0.95 then 'cash'::app.payment_method_type_enum
                 else 'cheque'::app.payment_method_type_enum end,
            u.expected_rate, u.expected_rate, v_currency, (v_due - interval '1 day'),
            v_first || ' ' || v_last, v_tenant_id,
            'RGW' || to_char(v_due, 'YYMM') || upper(substr(v_lease_id::text, 1, 6)) || v_month,
            v_owner_id
          ) returning id into v_payment_id;

          insert into app.payment_allocations (
            workspace_id, property_id, unit_id, payment_record_id, rent_charge_period_id,
            allocation_source, allocated_amount, allocated_by_user_id, allocated_at
          ) values (
            v_workspace_id, u.property_id, u.unit_id, v_payment_id, v_charge_id,
            'automatic', u.expected_rate, v_owner_id, (v_due - interval '1 day')
          );
        end if;
      end loop;

    elsif v_roll < 0.80 then
      -- Mid-invite: lease drafted, invitation sent/opened, unit stays vacant
      -- but shows up as "invited" in the pipeline.
      v_first := first_names[1 + floor(random() * array_length(first_names, 1))::int];
      v_last  := last_names[1 + floor(random() * array_length(last_names, 1))::int];
      v_email := lower(v_first) || '.' || lower(v_last) || '.' || substr(u.unit_id::text, 1, 6) || '@invitee.demo';

      insert into app.lease_agreements (
        property_id, unit_id, tenant_name, tenant_phone, entered_by_user_id,
        lease_type, start_date, end_date, billing_cycle, rent_amount, currency_code,
        status, confirmation_status, agreement_notes
      ) values (
        u.property_id, u.unit_id, v_first || ' ' || v_last, '+254700' || lpad((100000 + floor(random()*899999))::int::text, 6, '0'),
        v_owner_id, 'fixed_term',
        (current_date + 5 + floor(random()*10)::int),
        ((current_date + 5 + floor(random()*10)::int) + interval '12 months')::date,
        'monthly', u.expected_rate, v_currency, 'pending_confirmation', 'awaiting_tenant',
        'Awaiting tenant sign-up.'
      ) returning id into v_lease_id;

      insert into app.tenant_invitations (
        property_id, unit_id, lease_agreement_id, invited_by_user_id,
        invited_email, invited_name, delivery_channel, token_hash, status, sent_at, expires_at,
        pmc_company_id, occupant_type
      ) values (
        u.property_id, u.unit_id, v_lease_id, v_owner_id,
        v_email, v_first || ' ' || v_last, 'email',
        encode(extensions.gen_random_bytes(24), 'hex'),
        case when random() < 0.5 then 'sent' else 'opened' end::app.tenant_invitation_status_enum,
        now() - ((1 + floor(random()*5)::int) || ' days')::interval,
        now() + ((2 + floor(random()*8)::int) || ' days')::interval,
        v_owner_id, 'tenant_occupant'
      );

      insert into app.unit_occupancy_snapshots (property_id, unit_id, occupancy_status, last_status_changed_at, created_by)
      values (u.property_id, u.unit_id, 'invited', now() - interval '1 day', v_owner_id)
      on conflict (unit_id) do update set
        occupancy_status = excluded.occupancy_status,
        last_status_changed_at = excluded.last_status_changed_at,
        updated_at = now();
    end if;
    -- Remaining ~20% stay vacant — the AFTER INSERT trigger on app.units
    -- already gave every unit a 'vacant' occupancy snapshot by default.
  end loop;
end $$;

-- ----------------------------------------------------------------------------
-- 7b. Occupancy & vacancy/turnover trend history (for /owner/units charts)
-- ----------------------------------------------------------------------------
-- app.get_unit_occupancy_dashboard_chart_series() reads only from this
-- table, and the "Occupancy Trend" / "Vacancy vs Turnover" widgets show a
-- placeholder whenever it returns zero rows for their series_kind + property
-- scope — there is no other way to populate them, and nothing else derives
-- these rows automatically. property_id is null for the portfolio-wide
-- ("All properties") view; each property additionally gets its own rows for
-- when it's selected individually.

-- Portfolio-wide occupancy trend (6 months, ramping to the real current
-- occupied count across all ~92 units).
insert into app.unit_occupancy_dashboard_chart_points (
  property_id, series_kind, label, sort_order, occupied_units, occupancy_rate
)
select null, 'occupancy_trend'::app.unit_occupancy_dashboard_series_enum,
       to_char(date_trunc('month', now()) - (v.months_back || ' months')::interval, 'Mon YYYY'),
       6 - v.months_back,
       v.occupied,
       round(v.occupied::numeric / (select count(*) from app.units un join app.properties p on p.id = un.property_id where p.workspace_id = (select id from app.workspaces where owner_user_id = (select id from auth.users where email = 'yidad43473@fisedo.com'))) * 100, 2)
from (values (5, 55), (4, 59), (3, 62), (2, 65), (1, 67), (0, 68)) as v(months_back, occupied);

-- Portfolio-wide vacancy/turnover trend — vacant count is the complement of
-- the occupancy trend above against the same total unit count.
insert into app.unit_occupancy_dashboard_chart_points (
  property_id, series_kind, label, sort_order, vacant_units, turnover_count
)
select null, 'vacancy_turnover_trend'::app.unit_occupancy_dashboard_series_enum,
       to_char(date_trunc('month', now()) - (v.months_back || ' months')::interval, 'Mon YYYY'),
       6 - v.months_back,
       (select count(*) from app.units un join app.properties p on p.id = un.property_id where p.workspace_id = (select id from app.workspaces where owner_user_id = (select id from auth.users where email = 'yidad43473@fisedo.com'))) - v.occupied,
       v.turnover
from (values (5, 55, 2), (4, 59, 4), (3, 62, 3), (2, 65, 5), (1, 67, 3), (0, 68, 2)) as v(months_back, occupied, turnover);

-- Per-property trend rows, so the same charts also work when a single
-- property is selected from the dropdown. Ramps from ~72% of that
-- property's actual current occupied count (5 months ago) up to exactly
-- its real current count (this month).
do $$
declare
  v_prop  record;
  v_month int;
  v_occ   int;
begin
  for v_prop in
    select p.id,
           count(u.id)::int as total_units,
           count(*) filter (where s.occupancy_status = 'occupied')::int as final_occupied
    from app.properties p
    join app.units u on u.property_id = p.id
    left join app.unit_occupancy_snapshots s on s.unit_id = u.id
    where p.workspace_id = (select id from app.workspaces where owner_user_id = (select id from auth.users where email = 'yidad43473@fisedo.com'))
    group by p.id
  loop
    for v_month in 0..5 loop
      if v_month = 0 then
        v_occ := v_prop.final_occupied;
      else
        v_occ := least(v_prop.total_units, greatest(0, round(v_prop.final_occupied * (0.72 + 0.056 * (5 - v_month)))::int));
      end if;

      insert into app.unit_occupancy_dashboard_chart_points (
        property_id, series_kind, label, sort_order, occupied_units, occupancy_rate
      ) values (
        v_prop.id, 'occupancy_trend',
        to_char(date_trunc('month', now()) - (v_month || ' months')::interval, 'Mon YYYY'),
        6 - v_month, v_occ,
        round(v_occ::numeric / greatest(v_prop.total_units, 1) * 100, 2)
      );

      insert into app.unit_occupancy_dashboard_chart_points (
        property_id, series_kind, label, sort_order, vacant_units, turnover_count
      ) values (
        v_prop.id, 'vacancy_turnover_trend',
        to_char(date_trunc('month', now()) - (v_month || ' months')::interval, 'Mon YYYY'),
        6 - v_month, v_prop.total_units - v_occ,
        floor(random() * 3)::int
      );
    end loop;
  end loop;
end $$;

-- ----------------------------------------------------------------------------
-- 8. Documents (property + a sample of lease documents)
-- ----------------------------------------------------------------------------

insert into app.property_documents (property_id, unit_id, document_type_id, storage_path, file_name, mime_type, verification_status_id, verified_by, verified_at, uploaded_by)
select p.id, null,
       (select id from app.lookup_document_types where code = d.doc_code),
       'property-documents/' || p.id || '/' || d.doc_code || '.pdf',
       d.doc_code || '.pdf', 'application/pdf',
       (select id from app.lookup_verification_statuses where code = 'VERIFIED'),
       (select id from auth.users where email = 'yidad43473@fisedo.com'), now() - interval '80 days',
       (select id from auth.users where email = 'yidad43473@fisedo.com')
from app.properties p
cross join (values ('TITLE_DEED'), ('UTILITY_BILL')) as d(doc_code)
where p.workspace_id = (select id from app.workspaces where owner_user_id = (select id from auth.users where email = 'yidad43473@fisedo.com'));

insert into app.lease_documents (property_id, unit_id, lease_agreement_id, document_type, document_name, storage_path, status, uploaded_by, uploaded_at, verified_at, verified_by)
select la.property_id, la.unit_id, la.id, 'lease_agreement',
       'Lease Agreement — ' || la.tenant_name || '.pdf',
       'lease-documents/' || la.id || '/lease-agreement.pdf',
       'verified',
       (select id from auth.users where email = 'yidad43473@fisedo.com'),
       la.tenant_confirmed_at, la.tenant_confirmed_at,
       (select id from auth.users where email = 'yidad43473@fisedo.com')
from app.lease_agreements la
where la.status = 'active'
order by la.id
limit 25;

-- Renewal in progress on one long-standing lease, for the Lease Workflows page.
insert into app.lease_agreements (
  lease_chain_id, version_no, property_id, unit_id, tenant_user_id, tenant_name, tenant_phone,
  entered_by_user_id, lease_type, start_date, end_date, billing_cycle, rent_amount, currency_code,
  status, confirmation_status, agreement_notes
)
select la.lease_chain_id, 2, la.property_id, la.unit_id, la.tenant_user_id, la.tenant_name, la.tenant_phone,
       (select id from auth.users where email = 'yidad43473@fisedo.com'),
       'fixed_term', la.end_date, la.end_date + interval '12 months', 'monthly',
       la.rent_amount * 1.08, la.currency_code, 'draft', 'awaiting_tenant',
       'Renewal draft — rent adjustment pending tenant sign-off. Not yet sent to the tenant.'
from app.lease_agreements la
where la.status = 'active'
order by la.start_date asc
limit 1;

insert into app.lease_activity_events (property_id, unit_id, lease_agreement_id, actor_user_id, event_type, event_title, event_description)
select la.property_id, la.unit_id, la.id,
       (select id from auth.users where email = 'yidad43473@fisedo.com'),
       'lease_accepted', 'Lease accepted by tenant',
       'Tenant accepted the lease agreement via the mobile app.'
from app.lease_agreements la
where la.status = 'active'
order by la.id
limit 20;

-- ----------------------------------------------------------------------------
-- 9. Maintenance — a full pipeline across every ticket state
-- ----------------------------------------------------------------------------

do $$
declare
  v_ten          record;
  v_ref          text;
  v_ticket_id    uuid;
  v_fundi_id     uuid;
  v_status_roll  numeric;
  v_category     text;
  v_area         text;
  v_urgency      text;
  v_priority     text;
  v_created_ago  interval;
  categories text[] := array['plumbing','electrical','hvac','structural','windows_doors','appliances','painting','security','general_repairs','other'];
  areas      text[] := array['kitchen','bathroom','bedroom','living_room','balcony','ceiling','common_area','parking','gate','rooftop'];
  urgencies  text[] := array['standard','moderate','emergency'];
  titles     text[] := array[
    'Leaking tap', 'Light fixture not working', 'AC not cooling', 'Broken window latch',
    'Water stain on ceiling', 'Gate lock malfunction', 'Burst pipe', 'Breaker keeps tripping',
    'Door struggling to close', 'Fence gate hinge broken', 'Blocked drain', 'Peeling paint',
    'Intercom not working', 'Noisy water heater', 'Cracked tile', 'Faulty smoke detector'
  ];
begin
  for v_ten in
    select ut.tenant_user_id, ut.property_id, ut.unit_id, p.workspace_id
    from app.unit_tenancies ut
    join app.properties p on p.id = ut.property_id
    where ut.status = 'active'
    order by random()
    limit 60
  loop
    v_category := categories[1 + floor(random() * array_length(categories,1))::int];
    v_area := areas[1 + floor(random() * array_length(areas,1))::int];
    v_urgency := urgencies[1 + floor(random() * array_length(urgencies,1))::int];
    v_priority := case v_urgency when 'emergency' then 'high' when 'moderate' then 'medium' else 'low' end;
    v_created_ago := ((1 + floor(random() * 180)::int) || ' days')::interval;

    v_ref := app.generate_maintenance_reference();

    insert into app.maintenance_requests (
      reference, tenant_user_id, workspace_id, property_id, unit_id, title, description,
      category_id, area_id, urgency, priority, status, created_at
    ) values (
      v_ref, v_ten.tenant_user_id, v_ten.workspace_id, v_ten.property_id, v_ten.unit_id,
      titles[1 + floor(random() * array_length(titles,1))::int],
      'Tenant-reported issue requiring attention from the maintenance team.',
      (select id from app.maintenance_categories where code = v_category),
      (select id from app.maintenance_areas where code = v_area),
      v_urgency, v_priority, 'submitted', now() - v_created_ago
    );

    select id into v_ticket_id from app.maintenance_tickets where request_id = (select id from app.maintenance_requests where reference = v_ref);

    select id into v_fundi_id from app.fundi_profiles order by random() limit 1;

    v_status_roll := random();

    if v_status_roll < 0.15 then
      -- new: leave as-is (unassigned).
      null;
    elsif v_status_roll < 0.30 then
      update app.maintenance_tickets set assigned_fundi_id = v_fundi_id, assigned_at = now() - v_created_ago + interval '1 day', status = 'assigned'
      where id = v_ticket_id;
    elsif v_status_roll < 0.45 then
      update app.maintenance_tickets set assigned_fundi_id = v_fundi_id, assigned_at = now() - v_created_ago + interval '1 day',
        started_at = now() - v_created_ago + interval '2 days', status = 'in_progress', estimated_cost = round((500 + random()*4500)::numeric, 2)
      where id = v_ticket_id;
    elsif v_status_roll < 0.55 then
      update app.maintenance_tickets set assigned_fundi_id = v_fundi_id, assigned_at = now() - v_created_ago + interval '1 day',
        started_at = now() - v_created_ago + interval '2 days', status = 'approval_needed', estimated_cost = round((3000 + random()*7000)::numeric, 2)
      where id = v_ticket_id;
      insert into app.maintenance_approval_requests (ticket_id, reason, requested_amount, note, status, requested_by)
      values (v_ticket_id, 'Repair cost exceeds standard budget', round((3000 + random()*7000)::numeric, 2),
              'Additional parts required beyond the standard callout.', 'pending', v_ten.tenant_user_id);
    elsif v_status_roll < 0.63 then
      update app.maintenance_tickets set assigned_fundi_id = v_fundi_id, assigned_at = now() - v_created_ago + interval '1 day',
        started_at = now() - v_created_ago + interval '2 days', status = 'paused', estimated_cost = round((5000 + random()*10000)::numeric, 2)
      where id = v_ticket_id;
      with pause as (
        insert into app.ticket_pause_events (ticket_id, fundi_id, reason_code, reason_codes, work_note, amount_spent, materials_used)
        values (v_ticket_id, v_fundi_id, 'funding_delay', array['funding_delay'],
                'Partial repair completed; remaining work needs owner-approved budget before continuing.',
                round((2000 + random()*3000)::numeric, 2), 'Replacement parts')
        returning id, ticket_id
      )
      insert into app.ticket_funding_holds (ticket_id, pause_event_id, amount_needed, note)
      select pause.ticket_id, pause.id, round((8000 + random()*7000)::numeric, 2), 'Awaiting funding approval to complete the repair.'
      from pause;
    elsif v_status_roll < 0.70 then
      update app.maintenance_tickets set assigned_at = now() - v_created_ago + interval '1 day',
        started_at = now() - v_created_ago + interval '2 days', status = 'reassigning', assigned_fundi_id = null
      where id = v_ticket_id;
      insert into app.maintenance_activity_log (ticket_id, event_type, label, actor_name)
      values (v_ticket_id, 'status_changed', 'Ticket released for reassignment', 'Faith Njeri');
    elsif v_status_roll < 0.90 then
      update app.maintenance_tickets set assigned_fundi_id = v_fundi_id, assigned_at = now() - v_created_ago + interval '1 day',
        started_at = now() - v_created_ago + interval '2 days', status = 'completed',
        completed_at = now() - v_created_ago + interval '4 days', resolution_days = 3,
        estimated_cost = round((500 + random()*4500)::numeric, 2), actual_cost = round((500 + random()*4500)::numeric, 2)
      where id = v_ticket_id;
      insert into app.maintenance_ticket_feedback (ticket_id, request_id, tenant_user_id, workspace_id, property_id, unit_id, feedback_type, service_rating, service_comment, resolution_status, submitted_at)
      select v_ticket_id, mr.id, v_ten.tenant_user_id, v_ten.workspace_id, v_ten.property_id, v_ten.unit_id,
             'completion_review', 3 + floor(random()*3)::int, 'Resolved to my satisfaction.', 'resolved', now() - v_created_ago + interval '5 days'
      from app.maintenance_requests mr where mr.reference = v_ref;
    else
      update app.maintenance_tickets set assigned_fundi_id = v_fundi_id, assigned_at = now() - v_created_ago + interval '1 day',
        started_at = now() - v_created_ago + interval '2 days', status = 'verified',
        completed_at = now() - v_created_ago + interval '4 days', resolution_days = 3, completion_state = 'verified',
        estimated_cost = round((500 + random()*4500)::numeric, 2), actual_cost = round((500 + random()*4500)::numeric, 2)
      where id = v_ticket_id;
      insert into app.maintenance_ticket_feedback (ticket_id, request_id, tenant_user_id, workspace_id, property_id, unit_id, feedback_type, service_rating, service_comment, resolution_status, submitted_at)
      select v_ticket_id, mr.id, v_ten.tenant_user_id, v_ten.workspace_id, v_ten.property_id, v_ten.unit_id,
             'completion_review', 4 + floor(random()*2)::int, 'Great work, verified and closed.', 'resolved', now() - v_created_ago + interval '5 days'
      from app.maintenance_requests mr where mr.reference = v_ref;
    end if;
  end loop;
end $$;

-- ----------------------------------------------------------------------------
-- 10. Guest invitations
-- ----------------------------------------------------------------------------

do $$
declare
  v_ap        record;
  v_guest_id  uuid;
  guest_names text[] := array['Peter Otieno','Grace Njoki','Tom Kiplangat','Delivery Rider','Mum Visiting','Amaka Obi','Sophie Turner','Ravi Shah','Chen Li','Fatou Diallo'];
begin
  for v_ap in
    select id, user_id, pmc_company_id, property_id, unit_id from app.access_profiles order by random() limit 18
  loop
    with gi as (
      insert into app.guest_invitations (
        inviter_access_profile_id, inviter_user_id, pmc_company_id, property_id, unit_id,
        guest_name, guest_phone, status, invited_at, invite_link_token
      ) values (
        v_ap.id, v_ap.user_id, v_ap.pmc_company_id, v_ap.property_id, v_ap.unit_id,
        guest_names[1 + floor(random() * array_length(guest_names,1))::int],
        '+254700' || lpad((100000 + floor(random()*899999))::int::text, 6, '0'),
        case when random() < 0.85 then 'active' else 'revoked' end::app.guest_access_status_enum,
        now() - ((1 + floor(random()*10)::int) || ' days')::interval,
        encode(extensions.gen_random_bytes(16), 'hex')
      )
      returning id, status, invited_at
    )
    insert into app.guest_access_tokens (guest_invitation_id, token_value, token_hash, status, issued_at)
    select gi.id, 'GST-' || upper(substr(md5(gi.id::text), 1, 10)), encode(extensions.digest(gi.id::text, 'sha256'), 'hex'), gi.status, gi.invited_at
    from gi;
  end loop;
end $$;

insert into app.guest_access_events (guest_invitation_id, guest_access_token_id, event_type, pmc_company_id, property_id, unit_id, scanned_by, event_at)
select gi.id, gt.id, 'check_in', gi.pmc_company_id, gi.property_id, gi.unit_id,
       (select id from auth.users where email = 'faith.njeri@ridgewayproperties.demo'), gi.invited_at + interval '2 hours'
from app.guest_invitations gi
join app.guest_access_tokens gt on gt.guest_invitation_id = gi.id
where gi.status = 'active'
order by gi.id
limit 10;

-- ----------------------------------------------------------------------------
-- 11. Security team
-- ----------------------------------------------------------------------------

insert into app.security_staff_invitations (pmc_company_id, invited_by_user_id, linked_user_id, full_name, email, phone, role, property_id, gate_zone_name, token_hash, status, sent_at, expires_at, accepted_at)
select (select id from auth.users where email='yidad43473@fisedo.com'),
       (select id from auth.users where email='yidad43473@fisedo.com'),
       (select id from auth.users where email=s.email),
       s.full_name, s.email, s.phone, s.role::app.security_staff_role_enum,
       (select id from app.properties where display_name = s.property_name),
       s.gate_zone, encode(extensions.gen_random_bytes(24),'hex'), 'accepted',
       now() - interval '60 days', now() + interval '305 days', now() - interval '58 days'
from (values
  ('Joseph Mutua', 'joseph.mutua@ridgewaysecurity.demo', '+254744400001', 'security_guard', 'Ridgeway Heights Apartments', 'Main Gate'),
  ('Irene Chepkoech', 'irene.chepkoech@ridgewaysecurity.demo', '+254744400002', 'gate_supervisor', 'Greenwood Court', 'Main Gate'),
  ('Grace Adeyemi', 'grace.adeyemi@ridgewaysecurity.demo', '+2348011140003', 'security_guard', 'Lagos Marina Towers', 'Main Gate'),
  ('Liu Wei', 'liu.wei@ridgewaysecurity.demo', '+97140004000', 'security_guard', 'Dubai Marina Heights', 'Main Gate')
) as s(full_name, email, phone, role, property_name, gate_zone);

insert into app.security_staff_profiles (user_id, pmc_company_id, invitation_id, full_name, email, phone, role, status, profile_photo_url, activated_at)
select (select id from auth.users where email = si.email), si.pmc_company_id, si.id, si.full_name, si.email, si.phone, si.role,
       'active', 'https://i.pravatar.cc/300?u=' || si.email, si.accepted_at
from app.security_staff_invitations si;

insert into app.security_location_assignments (staff_profile_id, pmc_company_id, property_id, gate_zone_name, is_active, assigned_at)
select sp.id, sp.pmc_company_id, si.property_id, si.gate_zone_name, true, si.accepted_at
from app.security_staff_profiles sp
join app.security_staff_invitations si on si.id = sp.invitation_id;

insert into app.security_scan_events (
  pmc_company_id, property_id, unit_id, scanned_by_staff_id, scanned_by_user_id, location_assignment_id, gate_zone_name,
  access_profile_id, person_type, person_name, unit_label, scan_action, scan_result, denial_reason, scanned_at
)
select ap.pmc_company_id, ap.property_id, ap.unit_id, sp.id, sp.user_id, la.id, la.gate_zone_name,
       ap.id, 'tenant_occupant', pr.first_name || ' ' || pr.last_name, u.label,
       e.scan_action::app.security_scan_action_enum, e.scan_result::app.security_scan_result_enum, e.denial_reason, now() - e.ago
from app.access_profiles ap
join app.units u on u.id = ap.unit_id
join app.profiles pr on pr.id = ap.user_id
join app.security_location_assignments la on la.property_id = ap.property_id
join app.security_staff_profiles sp on sp.id = la.staff_profile_id
cross join (values
  ('entry', 'approved', null::text, interval '6 days'),
  ('exit',  'approved', null::text, interval '5 days 20 hours'),
  ('entry', 'warning', 'QR code expiring within 24 hours', interval '10 hours')
) as e(scan_action, scan_result, denial_reason, ago)
where random() < 0.4;

-- ----------------------------------------------------------------------------
-- 12. Community hub — posts, comments, reactions, poll (flagship properties)
-- ----------------------------------------------------------------------------

with post as (
  insert into app.community_posts (community_zone_id, author_user_id, author_display_name, post_type, content, title, is_urgent, is_pinned, notify, view_count, created_at)
  select cz.id, (select id from auth.users where email='yidad43473@fisedo.com'), coalesce((select company_name from app.profiles where id = (select id from auth.users where email='yidad43473@fisedo.com')), 'Property Owner'),
         'announcement',
         'Scheduled water interruption this Thursday from 9am to 3pm while the county carries out mains maintenance. Please store enough water in advance.',
         'Scheduled Water Interruption — Thursday', true, true, true, 42, now() - interval '2 days'
  from app.community_zones cz join app.properties p on p.id = cz.property_id
  where p.display_name = 'Ridgeway Heights Apartments'
  returning id
)
insert into app.community_comments (post_id, author_user_id, author_display_name, content)
select post.id, u.id, coalesce(pr.first_name || ' ' || pr.last_name, 'Tenant'), 'Thanks for the heads up, filling up my tanks tonight.'
from post
join app.unit_occupancy_snapshots uos on uos.property_id = (select id from app.properties where display_name = 'Ridgeway Heights Apartments') and uos.current_tenant_user_id is not null
join auth.users u on u.id = uos.current_tenant_user_id
join app.profiles pr on pr.id = u.id
limit 1;

with post as (
  insert into app.community_posts (community_zone_id, author_user_id, author_display_name, post_type, content, title, notify, view_count, created_at)
  select cz.id, (select id from auth.users where email='yidad43473@fisedo.com'), coalesce((select company_name from app.profiles where id = (select id from auth.users where email='yidad43473@fisedo.com')), 'Property Owner'),
         'announcement',
         'The estate garden along the west wing has been replanted — please keep pets off the new flower beds for a few weeks while they establish.',
         'New Garden Landscaping', true, 18, now() - interval '6 days'
  from app.community_zones cz join app.properties p on p.id = cz.property_id
  where p.display_name = 'Greenwood Court'
  returning id
)
select 1 from post;

insert into app.community_posts (community_zone_id, author_user_id, author_display_name, post_type, content, image_url, created_at)
select cz.id, uos.current_tenant_user_id, coalesce(pr.first_name || ' ' || pr.last_name, 'Tenant'), 'discussion', d.content, d.image_url, now() - d.ago
from (values
  ('Ridgeway Heights Apartments', 'Does anyone know a reliable dry cleaner nearby? Mine just closed down.', null::text, interval '1 day'),
  ('Ridgeway Heights Apartments', 'Great sunset from the rooftop this evening, this city never disappoints.', 'https://picsum.photos/seed/ridgeway-sunset/900/600', interval '4 hours'),
  ('Lagos Marina Towers', 'Is anyone else finding the building WiFi slow in the evenings, or is it just my unit?', null, interval '2 days'),
  ('Thames View Apartments', 'Lost a set of house keys near the entrance yesterday. Please let me know if found!', null, interval '10 hours'),
  ('Dubai Marina Heights', 'The new gym equipment on level 2 is fantastic, thanks management!', 'https://picsum.photos/seed/dubai-gym/900/600', interval '2 days'),
  ('Manhattan Skyline Lofts', 'Anyone hosting a rooftop watch party this weekend?', null, interval '1 day')
) as d(property_name, content, image_url, ago)
join app.properties p on p.display_name = d.property_name
join app.community_zones cz on cz.property_id = p.id
join lateral (
  select current_tenant_user_id
  from app.unit_occupancy_snapshots
  where property_id = p.id and current_tenant_user_id is not null
  order by random()
  limit 1
) uos on true
join app.profiles pr on pr.id = uos.current_tenant_user_id;

with post as (
  insert into app.community_posts (community_zone_id, author_user_id, author_display_name, post_type, content, title, notify, created_at)
  select cz.id, (select id from auth.users where email='yidad43473@fisedo.com'), coalesce((select company_name from app.profiles where id = (select id from auth.users where email='yidad43473@fisedo.com')), 'Property Owner'),
         'poll',
         'We are planning the next estate clean-up day. Which weekend works best for most residents?',
         'Vote: Estate Clean-Up Day', true, now() - interval '3 days'
  from app.community_zones cz join app.properties p on p.id = cz.property_id
  where p.display_name = 'Ridgeway Heights Apartments'
  returning id
), opts as (
  insert into app.community_poll_options (post_id, label, sort_order)
  select post.id, o.label, o.sort_order
  from post cross join (values ('This Saturday',1), ('Next Saturday',2), ('This Sunday',3)) as o(label, sort_order)
  returning id, post_id, label
)
insert into app.community_poll_votes (post_id, option_id, user_id)
select (select post_id from opts limit 1),
       (select id from opts order by random() limit 1),
       uos.current_tenant_user_id
from app.unit_occupancy_snapshots uos
where uos.property_id = (select id from app.properties where display_name = 'Ridgeway Heights Apartments')
  and uos.current_tenant_user_id is not null
limit 8;

insert into app.community_post_likes (post_id, user_id)
select p.id, uos.current_tenant_user_id
from app.community_posts p
join app.community_zones cz on cz.id = p.community_zone_id
join app.unit_occupancy_snapshots uos on uos.property_id = cz.property_id and uos.current_tenant_user_id is not null
where p.title = 'Scheduled Water Interruption — Thursday'
limit 6;

insert into app.community_comment_reactions (comment_id, user_id, reaction_type, content)
select c.id, uos.current_tenant_user_id, 'emoji', '👍'
from app.community_comments c
join app.community_posts p on p.id = c.post_id
join app.community_zones cz on cz.id = p.community_zone_id
join app.unit_occupancy_snapshots uos on uos.property_id = cz.property_id and uos.current_tenant_user_id is not null
where c.content = 'Thanks for the heads up, filling up my tanks tonight.'
limit 1;

-- ----------------------------------------------------------------------------
-- 13. Tenant alerts (home-screen action items) + pending RBAC invitation
-- ----------------------------------------------------------------------------

insert into app.tenant_alerts (tenant_user_id, property_id, unit_id, category, priority, title, message, action_label, action_type, related_entity_type, created_at)
select uos.current_tenant_user_id, uos.property_id, uos.unit_id,
       a.category, a.priority, a.title, a.message, a.action_label, a.action_type, a.related_entity_type, now() - a.ago
from (values
  ('maintenance', 'high', 'Rate your completed repair', 'A recent maintenance ticket was marked complete. Let us know how it went.', 'Rate Service', 'rate_maintenance', 'maintenance_ticket', interval '4 days'),
  ('rent', 'high', 'Rent overdue', 'Your rent payment for this month is overdue. Pay now to avoid late fees.', 'Pay Rent', 'pay_rent', 'rent_charge', interval '2 days'),
  ('rent', 'medium', 'Rent due reminder', 'Your rent for this month is due soon.', 'Pay Rent', 'pay_rent', 'rent_charge', interval '1 day'),
  ('guest', 'low', 'Guest checked in', 'Your invited guest checked in at the gate.', 'View Guest', 'view_guest', 'guest_invitation', interval '20 hours'),
  ('community', 'low', 'New estate announcement', 'Management posted a new community update.', 'View', 'view_community', 'community_post', interval '2 days'),
  ('system', 'medium', 'Upcoming maintenance notice', 'Scheduled maintenance may affect your unit this week.', 'Dismiss', 'dismiss', null, interval '1 day')
) as a(category, priority, title, message, action_label, action_type, related_entity_type, ago)
join lateral (
  select current_tenant_user_id, property_id, unit_id
  from app.unit_occupancy_snapshots
  where current_tenant_user_id is not null
  order by random() limit 1
) uos on true;

insert into app.user_invitations (workspace_id, invited_by_user_id, email, full_name, role_id, portal_type, token_hash, status, sent_at, expires_at)
values (
  (select id from app.workspaces where owner_user_id = (select id from auth.users where email = 'yidad43473@fisedo.com')),
  (select id from auth.users where email = 'yidad43473@fisedo.com'),
  'brenda.otieno@ridgewayproperties.demo', 'Brenda Otieno',
  (select id from app.roles where key = 'ANALYST'), 'owner',
  encode(extensions.gen_random_bytes(24), 'hex'), 'sent', now() - interval '1 day', now() + interval '6 days'
);

-- ============================================================================
-- Done. Log in with your own account (yidad43473@fisedo.com) to see the
-- seeded workspace as the owner. See DEMO_CREDENTIALS.md (next to this file)
-- for every OTHER seeded login — staff, fundis, security guards — and
-- ready-to-run SQL queries for finding a tenant to log in as (their emails
-- are randomised per seed run). Every fabricated account shares one
-- password: Demo@2026!
-- ============================================================================
