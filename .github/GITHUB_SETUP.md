# GitHub Setup For Supabase Backend

This document covers the GitHub-side controls that complement the pipeline files committed in this repository.

## 1. Branch protection for `main`

Recommended `main` branch protection:

1. Require a pull request before merging
2. Require at least 1 approving review
3. Dismiss stale approvals when new commits are pushed
4. Require status checks to pass before merging
5. Require branches to be up to date before merging
6. Include administrators if you want the rule enforced consistently
7. Restrict direct pushes to `main`

Recommended required status checks:

- `Validate Local Stack`

Do not make the manual production workflow a required status check because it is intentionally on-demand.

## 2. Production environment protection

Create a GitHub environment named `production`.

Recommended settings:

1. Require reviewers before deployment
2. Allow deployments from `main`, and optionally from production release tags if you want tag-based function rollback
3. Store production secrets only on the `production` environment
4. Optionally add a wait timer if you want a final pause before deploy approval

Required secrets:

- `SUPABASE_ACCESS_TOKEN`
- `SUPABASE_PROJECT_REF_PRODUCTION`
- `SUPABASE_DB_PASSWORD_PRODUCTION`

## 3. Release tagging guidance

Before or immediately after a successful `main` production deploy, create a Git tag such as:

```text
supabase-prod-2026-04-11-01
```

Tagged releases make targeted function rollbacks safer because the manual production workflow can run from `main` or from a tag.

## 4. Recommended team operating model

- All migration and function work starts on a non-main branch
- Developers validate locally with Docker and the local Supabase stack
- Pull requests must include rollout and risk notes when production behavior changes
- `main` is the only branch that auto-deploys to production
- Manual production actions are reserved for approved hotfixes, targeted function redeploys, or controlled recovery actions
