This directory contains the GitHub Actions pipeline for the Supabase backend.

- `supabase-backend.yml` handles database-focused work. Every branch and pull request runs local-only validation against a disposable Supabase stack, and pushes to `main` deploy only the migration chain to the live production project.
- `supabase-functions.yml` handles edge-function-only work. It validates edge functions without booting the local database, and pushes to `main` deploy only the changed function directories. Changes to `functions/_shared` or shared runtime config trigger a full function redeploy.
- `supabase-manual-operations.yml` supports controlled db-only, functions-only, or full production actions after explicit confirmation.
- Production deployment expects the GitHub `production` environment plus these secrets:
  - `SUPABASE_ACCESS_TOKEN`
  - `SUPABASE_PROJECT_REF_PRODUCTION`
  - `SUPABASE_DB_PASSWORD_PRODUCTION`
- The automatic production database job fails early if any required production secret is missing, and it only proceeds for `push` events on `main`.
- The automatic production functions job needs only:
  - `SUPABASE_ACCESS_TOKEN`
  - `SUPABASE_PROJECT_REF_PRODUCTION`
- Current tracked edge functions:
  - `mpesa-create-setup`
  - `mpesa-register-c2b`
  - `mpesa-c2b-validation`
  - `mpesa-c2b-confirmation`
