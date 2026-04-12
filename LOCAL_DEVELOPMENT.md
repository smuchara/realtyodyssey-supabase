# Supabase Local Development Runbook

This document explains how to run the RealtyOdyssey Supabase stack locally with Docker and connect it to either the Next.js app in this repo or the Flutter app in the separate mobile repo.

Quick command lookup:

- [SUPABASE_COMMAND_REFERENCE.md](C:\RealtyOdyssey\supabase\SUPABASE_COMMAND_REFERENCE.md)

The local Supabase project root is:

```text
C:\RealtyOdyssey\supabase
```

The correct folder to run raw CLI commands from is the parent folder that contains the shared `supabase` directory:

```powershell
cd C:\RealtyOdyssey\supabase
```

If you want to stay inside the `supabase` folder, use the wrapper script:

```powershell
cd C:\RealtyOdyssey
pnpm run supabase:cli -- status
```

That wrapper runs:

```powershell
npx supabase --workdir ..
```

## 1. Prerequisites

- Docker Desktop installed and running
- Node.js installed
- `npx supabase` available

Quick checks:

```powershell
docker --version
node -v
npx supabase --version
```

## 2. Important folder roles

- Active local migration chain:
  - [migrations](C:\RealtyOdyssey\supabase\migrations)
- Historical archived migrations and backups:
  - [migrations_archive](C:\RealtyOdyssey\supabase\migrations_archive)
- Edge Functions:
  - [functions](C:\RealtyOdyssey\supabase\functions)
- CLI config:
  - [config.toml](C:\RealtyOdyssey\supabase\config.toml)

Supabase CLI reads migrations only from `supabase/migrations` when the workdir is `C:\RealtyOdyssey`.
The clean `v_1_01` to `v_1_10` chain is already the active migration set.

## 3. Core local commands

Run these from:

```powershell
cd C:\RealtyOdyssey
```

Start local Supabase:

```powershell
npx supabase --workdir . start
```

Check status and get local URLs and keys:

```powershell
npx supabase --workdir . status
```

Reset the local database and rerun all migrations:

```powershell
npx supabase --workdir . db reset
```

Stop local Supabase:

```powershell
npx supabase --workdir . stop
```

View current migration state:

```powershell
npx supabase --workdir . migration list
```

## 4. Typical clean local test flow

1. Start Docker Desktop.
2. Make sure the migration chain you want to test is in `migrations`.
3. Start the local stack:

```powershell
npx supabase --workdir . start
```

4. Reset the local DB from scratch:

```powershell
npx supabase --workdir . db reset
```

5. Run:

```powershell
npx supabase --workdir . status
```

6. Copy the local URL and publishable key into your app env file.
7. Restart the app dev server.
8. Test sign-up, onboarding, invitations, tenancy, occupancy, payments, and functions.

## 5. Local connection values

When the local stack is running, `supabase status` prints values like:

- Project URL: `http://127.0.0.1:54321`
- REST: `http://127.0.0.1:54321/rest/v1`
- Edge Functions: `http://127.0.0.1:54321/functions/v1`
- Database: `postgresql://postgres:postgres@127.0.0.1:54322/postgres`
- Publishable key: local public client key
- Secret key: local service key

Use the `Publishable` key for browser/mobile app clients.

Do not use the `Secret` key in public app code.

## 5A. Local email testing

Local auth emails use the app site URL configured in:

- [config.toml](C:\RealtyOdyssey\supabase\config.toml)

Current local app URL for auth links:

- App localhost: `http://localhost:3000`

Local email inbox for Supabase auth testing:

- Inbucket web UI: `http://127.0.0.1:54324`
- Also works as: `http://localhost:54324`

Useful local mail ports:

- SMTP: `127.0.0.1:54325`
- POP3: `127.0.0.1:54326`

Use this flow to test signup, confirmation, and password reset emails locally:

```powershell
cd C:\RealtyOdyssey
cmd /c npx supabase --workdir . start
cmd /c npx supabase --workdir . status
pnpm dev
```

Then:

1. Open the app at `http://localhost:3000`
2. Trigger a signup, magic link, invite, or password reset flow
3. Open the local inbox at `http://127.0.0.1:54324`
4. Open the message and use the confirmation or recovery link

If the mail UI is empty, make sure:

- the Supabase local stack is running
- the app is pointed to local Supabase
- the auth flow you tested actually sends an email

## 6. Connect the Next.js app to local Supabase

The web app reads these env vars:

- `NEXT_PUBLIC_SUPABASE_URL`
- `NEXT_PUBLIC_SUPABASE_ANON_KEY`
- `NEXT_PUBLIC_APP_URL`

Update:

- [apps/portfolio/.env.local](C:\RealtyOdyssey\realtyodyssey-frontend\apps\portfolio\.env.local)

Example:

```env
NEXT_PUBLIC_SUPABASE_URL=http://127.0.0.1:54321
NEXT_PUBLIC_SUPABASE_ANON_KEY=YOUR_LOCAL_PUBLISHABLE_KEY
NEXT_PUBLIC_APP_URL=http://localhost:3000
```

Then restart the Next.js app:

```powershell
pnpm dev
```

Important:

- Use the local publishable key shown by `supabase status`
- Set `NEXT_PUBLIC_APP_URL=http://localhost:3000` so invite and email links use the local app URL
- Do not leave the app pointed at production while testing local DB changes

## 7. Connect a Flutter app to local Supabase

For Flutter, use the same local values:

- URL: `http://127.0.0.1:54321`
- Key: local `Publishable` key from `supabase status`

Example:

```dart
await Supabase.initialize(
  url: 'http://127.0.0.1:54321',
  anonKey: 'YOUR_LOCAL_PUBLISHABLE_KEY',
);
```

Notes for Flutter testing:

- Android emulator usually cannot use `127.0.0.1` to reach services on your host machine
- Use your machine LAN IP or emulator-specific host mapping if needed

Common options:

- Android emulator:
  - `http://10.0.2.2:54321`
- iOS simulator:
  - often `http://127.0.0.1:54321` works
- Physical device:
  - use your laptop IP, for example `http://192.168.x.x:54321`

If you use a LAN IP for Flutter, keep the same publishable key.

## 8. Local Edge Functions

Local functions are exposed at:

```text
http://127.0.0.1:54321/functions/v1
```

Example endpoints:

- `http://127.0.0.1:54321/functions/v1/mpesa-create-setup`
- `http://127.0.0.1:54321/functions/v1/mpesa-register-c2b`
- `http://127.0.0.1:54321/functions/v1/mpesa-c2b-validation`
- `http://127.0.0.1:54321/functions/v1/mpesa-c2b-confirmation`

If you need function-specific local env or secrets, use Supabase local secret tooling or `.env` files as supported by the CLI and function runtime.

If you want to test function logic after the DB is stable:

```powershell
npx supabase --workdir . functions serve
```

## 9. Clean chain test workflow

The active migration chain is already the clean rebuild.

Use this flow:

1. Start local Supabase:

```powershell
npx supabase --workdir . start
```

2. Reset the local DB:

```powershell
npx supabase --workdir . db reset
```

3. Update your app env values to the local URL and publishable key.
4. Restart the app.
5. Test the app locally.

If you need the old chain for reference, it is archived under:

- [pre_20260409_active_chain_backup](C:\RealtyOdyssey\supabase\migrations_archive\pre_20260409_active_chain_backup)
- [pre_20260408114752_sql_editor_history](C:\RealtyOdyssey\supabase\migrations_archive\pre_20260408114752_sql_editor_history)

## 10. Common troubleshooting

### Storage timeout after `db reset`

Symptom:

```text
failed to execute http request: Get "http://127.0.0.1:54321/storage/v1/bucket": context deadline exceeded
```

This usually means local services restarted slowly after the SQL finished.

Recovery:

```powershell
npx supabase --workdir . status
npx supabase --workdir . stop
npx supabase --workdir . start
npx supabase --workdir . db reset
```

If needed:

```powershell
npx supabase --workdir . db reset --debug
```

### App still hitting production

Check:

- [apps/portfolio/.env.local](C:\RealtyOdyssey\realtyodyssey-frontend\apps\portfolio\.env.local)

Make sure it uses:

- `http://127.0.0.1:54321`
- local publishable key

Then fully restart the app dev server.

### Flutter app cannot reach local Supabase

Use:

- `10.0.2.2` for Android emulator
- host LAN IP for physical device

Also make sure Windows firewall is not blocking Docker ports.

### CLI confusion about workdir

Correct:

```powershell
cd C:\RealtyOdyssey
npx supabase --workdir . status
```

Avoid running raw CLI commands from inside `supabase\` unless you use the wrapper script.

## 11. Safe local vs production mental model

Safe local-only commands:

- `supabase start`
- `supabase stop`
- `supabase status`
- `supabase db reset`
- `supabase functions serve`

Production-affecting commands:

- `supabase db push`
- `supabase db pull`
- `supabase migration repair`
- `supabase functions deploy`
- `supabase secrets set`

Use local-only commands while validating the rebuilt migration chain.

## 12. Recommended validation checklist

After a clean local reset, test:

1. Sign up a new owner account
2. Workspace creation
3. Property onboarding
4. Documents upload
5. Collaboration invites and acceptance
6. Accountability and PCA flow
7. Property activation
8. Units and occupancy dashboard
9. Tenant invitation flow
10. Mobile tenant summary RPC
11. Payment setup creation
12. Payment tables and matching workflow
13. M-Pesa callback event recording

## 13. After local validation passes

When the clean chain is proven locally:

1. Keep `migrations` as the canonical migration history
2. Keep historical material only in `migrations_archive`
3. Re-test once more on local
4. Only then plan production rollout steps

Do not switch production deployment back on until the local clean chain passes the critical flows end to end.

## 14. How this maps to CI/CD

The GitHub Actions pipeline mirrors this same separation:

- Feature branches and pull requests validate locally only
- `main` validates first, then deploys to production

That means your safe workflow is:

1. Make migration or function changes on a non-main branch
2. Test with local Supabase and your local apps
3. Open a pull request and let CI rerun the same local validation
4. Merge to `main` only when the local branch behavior is proven
5. Let the protected production job push the approved state live
