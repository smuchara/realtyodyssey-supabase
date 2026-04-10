This directory contains the GitHub Actions pipeline for the Supabase backend.

- Every branch and pull request runs local-only validation against a disposable Supabase stack.
- Pushes to `main` run the same validation first, then deploy migrations and the tracked Edge Functions to the live project.
- A separate manual production workflow supports controlled db-only, functions-only, or full deploy actions after explicit confirmation.
- Production deployment expects the GitHub `production` environment plus these secrets:
  - `SUPABASE_ACCESS_TOKEN`
  - `SUPABASE_PROJECT_REF_PRODUCTION`
  - `SUPABASE_DB_PASSWORD_PRODUCTION`
