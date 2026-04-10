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

## 10. Branch strategy and pipeline behavior

The GitHub Actions pipeline for this repo now follows this model:

1. Every branch and pull request:
   - checks out the repo into a `supabase/` path on the runner
   - type-checks the Node utilities
   - runs Deno format, lint, and type checks for Edge Functions
   - starts a disposable local Supabase stack
   - runs a full local `db reset` from the migration chain
2. Pushes to `main`:
   - run the same local validation first
   - then link to the production project
   - then run `db push`
   - then deploy the tracked Edge Functions

This gives us local-style verification on non-main branches and production rollout only from `main`.

## 11. Important GitHub Actions checkout detail

Because this repository itself is named `supabase`, the workflow checks it out into a subfolder called `supabase/` inside the runner workspace.

That preserves the folder shape the Supabase CLI expects:

```text
$GITHUB_WORKSPACE/
  supabase/
    config.toml
    migrations/
    functions/
```

The workflow then runs CLI commands from the workspace root with:

```bash
supabase ... --workdir .
```

This is the CI equivalent of the local parent-folder workflow described earlier in this document.

## 12. Recommended branch protection rules

Configure GitHub branch protection for `main` with these minimum controls:

1. Require a pull request before merging
2. Require at least 1 approval
3. Dismiss stale approvals on new commits
4. Require branches to be up to date before merging
5. Require the `Validate Local Stack` status check to pass
6. Restrict direct pushes to `main`

This keeps production deploys flowing only from reviewed, validated changes.

## 13. Production environment approval guidance

Create a protected GitHub environment named `production`.

Recommended settings:

- require reviewer approval before deployment
- store production secrets on the environment, not as plain repository secrets
- allow deployments from `main`, and optionally from approved release tags if you want tag-based function rollback
- optionally add a short wait timer if you want an additional pause before approval

The automatic `main` deploy and the manual operations workflow both target this environment.

## 14. Safer manual deploy and rollback playbook

Automatic deployment from `main` should remain the normal path.

Use the manual workflow only when you need one of these:

- redeploy functions without changing the database
- push database-only changes after an approved operational pause
- redeploy from a known-good release tag

Recommended manual recovery model:

1. Tag known-good production states after successful releases
2. For Edge Function regressions:
   - run the manual workflow from the most recent good tag
   - choose `deploy_functions_only`
   - deploy only the affected functions
3. For migration regressions:
   - prefer a forward-fix migration over an ad hoc rollback
   - validate the fix locally
   - merge the fix to `main`
   - let the protected deploy path push it live
4. If the issue is urgent and function-only:
   - use the manual workflow from `main` or a release tag
   - require production approval before execution

Important:

- Supabase database rollback is not inherently safe as a generic automated action
- for schema issues, a controlled forward-fix migration is usually the safest production response
- function rollback is much safer than schema rollback, which is why the manual workflow supports targeted function redeploys
