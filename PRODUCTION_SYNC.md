# Supabase Production Sync and Deployment

This folder is the Supabase project root for RealtyOdyssey production operations.

The canonical Supabase backend now lives in:

```powershell
C:\RealtyOdyssey\supabase
```

Important:

- Do not run raw `npx supabase ...` commands directly from `C:\RealtyOdyssey\supabase`
- The shared folder is the canonical Git repo, but the Supabase CLI still expects the parent folder as the workdir
- Use this parent folder when running migration and deployment commands:

```powershell
cd C:\RealtyOdyssey\supabase
```

If you want to stay inside the `supabase` folder, use the package script wrapper:

```powershell
cd C:\RealtyOdyssey
pnpm run supabase:cli -- migration list
```

## Migration chain policy

The active CLI migration chain is the clean v1 sequence in:

- [migrations](C:\RealtyOdyssey\supabase\migrations)

Historical chains now live in:

- [migrations_archive](C:\RealtyOdyssey\supabase\migrations_archive)

Do not treat archived files as pending migrations.

## 1. Install and authenticate the Supabase CLI

Use the official CLI installation instructions first:

- https://supabase.com/docs/reference/cli/introduction

Then authenticate:

```powershell
npx supabase login
npx supabase projects list
```

## 2. Link this local folder to production

The local metadata file `.temp/project-ref` currently points to:

```text
uraskpwkjryfjagqxcsu
```

If that is not the live production project, relink before doing anything else:

```powershell
npx supabase link --project-ref YOUR_PRODUCTION_PROJECT_REF
```

If you also want database commands like `db pull` and `db push` to work without extra prompts, provide the database password when linking:

```powershell
npx supabase link --project-ref YOUR_PRODUCTION_PROJECT_REF --password YOUR_DB_PASSWORD
```

## 3. Pull down remote-only Edge Functions before deploying

If production already contains functions that are not in this repository yet, download them first so they are preserved in git and reviewed locally.

List the deployed functions:

```powershell
npx supabase functions list
```

Download each production-only function into the local `functions/` directory:

```powershell
npx supabase functions download FUNCTION_NAME
```

Repeat that command for every function that exists in production but not locally yet.

If you prefer, you can also download a function from the Supabase Dashboard on the function details page.

## 4. Capture remote database drift before pushing migrations

If production has database changes that were made outside the local migration history, pull them down before any `db push`:

```powershell
npx supabase db pull
```

Review the generated migration carefully and commit it before introducing new production migrations.

When reviewing, make sure changes land inside `migrations/` and not inside a nested accidental folder.

## 5. Deploy database migrations safely

After the local migration history matches production:

```powershell
npx supabase db push
```

## 6. Deploy Edge Functions safely

Deploy named functions explicitly instead of blanket-deploying everything while production still has remote-only functions under review:

```powershell
npx supabase functions deploy mpesa-create-setup
npx supabase functions deploy mpesa-register-c2b
npx supabase functions deploy mpesa-c2b-validation --no-verify-jwt
npx supabase functions deploy mpesa-c2b-confirmation --no-verify-jwt
```

This is safer than a broad `supabase functions deploy` while we are still reconciling the production function set.

## 7. Set production secrets

Set or update the project secrets before invoking the functions:

```powershell
npx supabase secrets set MPESA_CONSUMER_KEY=your_key
npx supabase secrets set MPESA_CONSUMER_SECRET=your_secret
npx supabase secrets set MPESA_ENVIRONMENT=production
npx supabase secrets set FUNCTION_URL_MPESA_C2B_CONFIRMATION=https://YOUR_PROJECT_REF.supabase.co/functions/v1/mpesa-c2b-confirmation
npx supabase secrets set FUNCTION_URL_MPESA_C2B_VALIDATION=https://YOUR_PROJECT_REF.supabase.co/functions/v1/mpesa-c2b-validation
```

## 8. Recommended production rollout order

1. Link the correct production project.
2. Download any remote-only functions.
3. Run `supabase db pull` if production schema drift exists.
4. Commit the synced state to git.
5. Push migrations.
6. Deploy the named functions.
7. Test the live callback URLs and authenticated function calls.

## 9. CI/CD secrets to add in GitHub

The GitHub Actions workflows in this repo expect these repository or environment secrets:

- `SUPABASE_ACCESS_TOKEN`
- `SUPABASE_PROJECT_REF_PRODUCTION`
- `SUPABASE_DB_PASSWORD_PRODUCTION`

Use a protected `production` environment in GitHub so production deploys require approval.
