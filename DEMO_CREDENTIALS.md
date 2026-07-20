# RealtyOdyssey Demo — Login Credentials & Cheat Sheet

This documents the accounts created by `supabase/seed.sql`. It is demo data only —
fake tenants, fake payments, fake everything — meant for showing off the product
before the official launch. Do not run this seed against a database that will
later serve real users without wiping it first.

**Every fabricated account below (staff, tenants, fundis, security guards)
uses the same password:**

```
Demo@2026!
```

The owner/company account is the exception — see below.

---

## 1. Company / Property Management Company (PMC) — full admin access

This is **your own existing account** (`yidad43473@fisedo.com`, created
through the real signup flow) — the seed doesn't create it or touch its
password, it just attaches the whole demo workspace to it and upgrades its
account type to Property Management Company so every PMC-gated page (QR
access, guest invites, security team) actually shows up.

Log in at the admin web app's `/login` page with your own email + your own
password, same as always. This is the account to demo the owner dashboards,
properties list, rent payments, maintenance, access/security, community hub,
and user management from.

---

## 2. Staff accounts (workspace members)

These have a role and property-level access across all 15 properties, but are
not the workspace owner.

| Name | Role | Email |
|---|---|---|
| David Otieno | Property Manager | `david.otieno@ridgewayproperties.demo` |
| Faith Njeri | Caretaker | `faith.njeri@ridgewayproperties.demo` |
| Peter Kamau | Legal | `peter.kamau@ridgewayproperties.demo` |

---

## 3. Fundis / service providers (maintenance)

These are the maintenance tickets' assigned providers. Kennedy, Mary, Alice,
and Chidi have real logins (usable in the provider portal); Peter Njoroge,
Samuel Kiprotich, Sipho Nkosi, and Liam O'Connor are "unclaimed" profiles (no
login — realistic for providers who haven't signed up for an account yet).

| Name | Specialty | Location | Email (if claimed) |
|---|---|---|---|
| Kennedy Otieno | Plumbing | Nairobi, Kenya | `kennedy.otieno@fundi.demo` |
| Mary Wanjala | Electrical | Nairobi, Kenya | `mary.wanjala@fundi.demo` |
| Alice Wambugu | Painting | Nairobi, Kenya | `alice.wambugu@fundi.demo` |
| Chidi Okafor | Electrical | Lagos, Nigeria | `chidi.okafor@fundi.demo` |
| Peter Njoroge | General Repairs | Nairobi, Kenya | — (unclaimed) |
| Samuel Kiprotich | HVAC | Nairobi, Kenya | — (unclaimed) |
| Sipho Nkosi | Plumbing | Cape Town, South Africa | — (unclaimed) |
| Liam O'Connor | General Repairs | London, United Kingdom | — (unclaimed) |

---

## 4. Security guards

| Name | Role | Assigned Property | Email |
|---|---|---|---|
| Joseph Mutua | Security Guard | Ridgeway Heights Apartments (Nairobi) | `joseph.mutua@ridgewaysecurity.demo` |
| Irene Chepkoech | Gate Supervisor | Greenwood Court (Nairobi) | `irene.chepkoech@ridgewaysecurity.demo` |
| Grace Adeyemi | Security Guard | Lagos Marina Towers (Lagos) | `grace.adeyemi@ridgewaysecurity.demo` |
| Liu Wei | Security Guard | Dubai Marina Heights (Dubai) | `liu.wei@ridgewaysecurity.demo` |

---

## 5. Tenants — logging in as one

Tenant accounts are **generated randomly at seed time** (random name + a
fragment of the unit's ID), so there's no fixed list — but every tenant uses
the same password (`Demo@2026!`) and their email always follows this pattern:

```
firstname.lastname.<unit-fragment>@tenant.demo
```

To find one to log in as, open **Supabase Studio → SQL Editor** (local:
`http://127.0.0.1:54323`) and run one of these:

**One tenant per property (good spread for a demo):**
```sql
select distinct on (p.display_name)
  p.display_name as property, p.city_town, u.label as unit,
  la.tenant_name, au.email
from app.lease_agreements la
join auth.users au on au.id = la.tenant_user_id
join app.units u on u.id = la.unit_id
join app.properties p on p.id = la.property_id
where la.status = 'active'
order by p.display_name, la.start_date desc;
```

**A tenant with close to two years of payment history (great for showing off
the collection-trend chart):**
```sql
select la.tenant_name, au.email, p.display_name as property, u.label as unit,
       la.start_date, current_date - la.start_date as tenancy_length
from app.lease_agreements la
join auth.users au on au.id = la.tenant_user_id
join app.units u on u.id = la.unit_id
join app.properties p on p.id = la.property_id
where la.status = 'active'
order by la.start_date asc
limit 10;
```

**A tenant who's currently behind on rent (for the "revenue at risk" / overdue
view):**
```sql
select la.tenant_name, au.email, p.display_name as property, u.label as unit,
       count(*) filter (where rcp.charge_status = 'overdue') as overdue_months
from app.lease_agreements la
join auth.users au on au.id = la.tenant_user_id
join app.units u on u.id = la.unit_id
join app.properties p on p.id = la.property_id
join app.rent_charge_periods rcp on rcp.lease_agreement_id = la.id
where la.status = 'active'
group by la.tenant_name, au.email, p.display_name, u.label
having count(*) filter (where rcp.charge_status = 'overdue') > 0
order by overdue_months desc
limit 10;
```

**All tenants at once** (useful to scroll and just pick one):
```sql
select la.tenant_name, au.email, p.display_name as property, u.label as unit
from app.lease_agreements la
join auth.users au on au.id = la.tenant_user_id
join app.units u on u.id = la.unit_id
join app.properties p on p.id = la.property_id
where la.status = 'active'
order by p.display_name, u.label;
```

Log in with whichever email you pick + `Demo@2026!` in the tenant mobile app
(or the tenant-facing web routes, if applicable).

---

## 6. The demo portfolio at a glance

15 properties across 10 countries, every property type represented:

| Property | City, Country | Type |
|---|---|---|
| Ridgeway Heights Apartments | Nairobi, Kenya | Apartment |
| Greenwood Court | Nairobi, Kenya | Apartment |
| Karen Acacia House | Nairobi, Kenya | House |
| Sunrise Business Park | Nairobi, Kenya | Commercial |
| Lagos Marina Towers | Lagos, Nigeria | Apartment |
| Victoria Island Business Centre | Lagos, Nigeria | Building |
| Cape Town Waterfront Residences | Cape Town, South Africa | Apartment |
| Thames View Apartments | London, United Kingdom | Apartment |
| Canary Wharf Office Suites | London, United Kingdom | Commercial |
| Dubai Marina Heights | Dubai, UAE | Apartment |
| Manhattan Skyline Lofts | New York, USA | Apartment |
| Toronto Harbourfront Suites | Toronto, Canada | Apartment |
| Sydney Harbour Residences | Sydney, Australia | Apartment |
| Mumbai Business Hub | Mumbai, India | Building |
| Berlin Mitte Lofts | Berlin, Germany | Apartment |

~90 units total, ~65 occupied with 1–24 months of rent history each (so the
collection-trend charts show real depth), ~7 mid-invite, the rest vacant.
~60 maintenance tickets spanning every workflow state. Guest passes, a
4-person security team, and a live community feed are seeded too.

---

## 7. Quick reference — where to log in

- **Admin web app** (owner/staff/security/PMC): the app's `/login` page — owner logs in with their own real credentials, everyone else with `Demo@2026!`
- **Supabase SQL Editor** (to run the lookup queries above): your project's dashboard → SQL Editor
- **Tenant mobile app**: point it at the same Supabase project, sign in with any tenant email above

`seed.sql` is not idempotent and is not tied to `supabase db reset` in this
setup — it was run once directly via the SQL Editor. If you ever need to
reseed from scratch, the fabricated tables (properties, units, tenants,
maintenance, etc.) need to be cleared first; your own owner account and its
workspace are left alone either way since the script only creates a
workspace for it if one doesn't already exist.
