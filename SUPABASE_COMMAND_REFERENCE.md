# Supabase Command Reference

This is the quick reference for the Supabase CLI commands we are most likely to use in this repository.

Use this when you need to:

- start or stop the local stack
- check status
- apply pending migrations without wiping data
- reset the local database
- inspect migration state
- link to a remote project
- push migrations to a linked remote project
- work with Edge Functions

## 1. Where to run commands

For this repo, the safest place to run raw Supabase CLI commands is:

```powershell
cd C:\RealtyOdyssey
```

Then use:

```powershell
cmd /c npx supabase --workdir . <command>
```

Use `cmd /c` on this machine because PowerShell may block `npm.ps1` or other script shims.

If you are already inside `C:\RealtyOdyssey\supabase`, you can use the wrapper:

```powershell
cd C:\RealtyOdyssey\supabase
cmd /c npm run supabase:cli -- status
```

That wrapper resolves to:

```powershell
npx supabase --workdir ..
```

## 2. Safe local commands

Start local Supabase:

```powershell
cd C:\RealtyOdyssey
cmd /c npx supabase --workdir . start
```

Check local status, URLs, and keys:

```powershell
cd C:\RealtyOdyssey
cmd /c npx supabase --workdir . status
```

Stop local Supabase:

```powershell
cd C:\RealtyOdyssey
cmd /c npx supabase --workdir . stop
```

List migrations known to the CLI:

```powershell
cd C:\RealtyOdyssey
cmd /c npx supabase --workdir . migration list
```

Apply pending local migrations without resetting data:

```powershell
cd C:\RealtyOdyssey
cmd /c npx supabase --workdir . db push --local
```

Preview what would be applied locally:

```powershell
cd C:\RealtyOdyssey
cmd /c npx supabase --workdir . db push --local --dry-run
```

Reset the local database and rerun the full migration chain:

```powershell
cd C:\RealtyOdyssey
cmd /c npx supabase --workdir . db reset
```

If you want the script wrapper version for reset:

```powershell
cd C:\RealtyOdyssey\supabase
cmd /c npm run supabase:db:reset
```

## 3. Common local migration workflows

### A. Apply one new migration without wiping the local DB

Use this after adding a new file under `supabase/migrations`:

```powershell
cd C:\RealtyOdyssey
cmd /c npx supabase --workdir . start
cmd /c npx supabase --workdir . db push --local --dry-run
cmd /c npx supabase --workdir . db push --local
cmd /c npx supabase --workdir . migration list
```

### B. Rebuild the local DB from scratch

Use this when you want a clean local validation pass:

```powershell
cd C:\RealtyOdyssey
cmd /c npx supabase --workdir . start
cmd /c npx supabase --workdir . db reset
cmd /c npx supabase --workdir . status
```

### C. Check whether a new migration file is in the chain

```powershell
cd C:\RealtyOdyssey
cmd /c npx supabase --workdir . migration list
```

## 4. Useful remote and production-facing commands

Authenticate Supabase CLI:

```powershell
cd C:\RealtyOdyssey
cmd /c npx supabase login
```

List accessible projects:

```powershell
cd C:\RealtyOdyssey
cmd /c npx supabase projects list
```

Link this repo to a remote project:

```powershell
cd C:\RealtyOdyssey
cmd /c npx supabase --workdir . link --project-ref YOUR_PROJECT_REF
```

Link with database password for DB commands:

```powershell
cd C:\RealtyOdyssey
cmd /c npx supabase --workdir . link --project-ref YOUR_PROJECT_REF --password YOUR_DB_PASSWORD
```

Pull remote schema drift into a migration:

```powershell
cd C:\RealtyOdyssey
cmd /c npx supabase --workdir . db pull
```

Push pending migrations to the linked remote project:

```powershell
cd C:\RealtyOdyssey
cmd /c npx supabase --workdir . db push
```

Important:

- `db push --local` targets your local running stack
- `db push` without `--local` targets the linked remote project
- `db reset` is local-only and destructive to local data

## 5. Edge Function commands we are likely to use

Serve functions locally:

```powershell
cd C:\RealtyOdyssey
cmd /c npx supabase --workdir . functions serve
```

List remote functions:

```powershell
cd C:\RealtyOdyssey
cmd /c npx supabase --workdir . functions list
```

Deploy one function:

```powershell
cd C:\RealtyOdyssey
cmd /c npx supabase --workdir . functions deploy mpesa-create-setup
```

Deploy callback functions without JWT verification:

```powershell
cd C:\RealtyOdyssey
cmd /c npx supabase --workdir . functions deploy daraja-c2b-validation --no-verify-jwt
cmd /c npx supabase --workdir . functions deploy daraja-c2b-confirmation --no-verify-jwt
```

Download an existing remote function:

```powershell
cd C:\RealtyOdyssey
cmd /c npx supabase --workdir . functions download FUNCTION_NAME
```

## 6. Command safety guide

Usually safe for local development:

- `start`
- `stop`
- `status`
- `migration list`
- `db push --local`
- `db reset`
- `functions serve`

Touches a linked remote project:

- `db push`
- `db pull`
- `link`
- `functions deploy`
- `functions list`
- `functions download`
- `secrets set`

Use extra care with:

- `db push` because it applies pending local migrations to the linked remote
- `db reset` because it recreates the local database
- `migration repair` because it changes migration history state

## 7. Recommended commands by scenario

I added a migration and want to apply it locally without losing data:

```powershell
cd C:\RealtyOdyssey
cmd /c npx supabase --workdir . db push --local
```

I want a clean local rebuild:

```powershell
cd C:\RealtyOdyssey
cmd /c npx supabase --workdir . db reset
```

I want to confirm the local stack is running:

```powershell
cd C:\RealtyOdyssey
cmd /c npx supabase --workdir . status
```

I want to see whether my migration file is recognized:

```powershell
cd C:\RealtyOdyssey
cmd /c npx supabase --workdir . migration list
```

I want to push approved migrations to the linked remote project:

```powershell
cd C:\RealtyOdyssey
cmd /c npx supabase --workdir . db push
```

## 8. Current project notes

The active migration chain lives in:

- [migrations](/c:/RealtyOdyssey/supabase/migrations)

The main runbooks are:

- [LOCAL_DEVELOPMENT.md](/c:/RealtyOdyssey/supabase/LOCAL_DEVELOPMENT.md)
- [PRODUCTION_SYNC.md](/c:/RealtyOdyssey/supabase/PRODUCTION_SYNC.md)

For rent/payments analytics, the current new migration file is:

- [20260411113000_v_1_11_rent_payments_dashboard_analytics.sql](/c:/RealtyOdyssey/supabase/migrations/20260411113000_v_1_11_rent_payments_dashboard_analytics.sql)
