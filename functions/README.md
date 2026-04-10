# M-Pesa Daraja Edge Functions

This folder contains the first Supabase Edge Function layer for the
RealtyOdyssey payments module.

Functions:

- `mpesa-create-setup`: creates an M-Pesa payment setup through a secure RPC and
  optionally registers C2B URLs with Daraja.
- `mpesa-register-c2b`: retries Daraja C2B URL registration for an existing
  active paybill or till setup.
- `mpesa-c2b-validation`: public callback endpoint for Daraja validation
  requests.
- `mpesa-c2b-confirmation`: public callback endpoint for Daraja confirmation
  requests.

Required environment variables:
- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- `SUPABASE_SERVICE_ROLE_KEY`
- `MPESA_CONSUMER_KEY`
- `MPESA_CONSUMER_SECRET`

Optional environment variables:

- `MPESA_ENVIRONMENT`
  - `sandbox` or `production`
- `MPESA_DARAJA_BASE_URL`
- `MPESA_OAUTH_URL`
- `MPESA_C2B_REGISTER_URL`
- `FUNCTION_URL_MPESA_C2B_CONFIRMATION`
- `FUNCTION_URL_MPESA_C2B_VALIDATION`

Notes:

- If `FUNCTION_URL_MPESA_C2B_CONFIRMATION` and
  `FUNCTION_URL_MPESA_C2B_VALIDATION` are not set, the functions derive callback
  URLs from `SUPABASE_URL`.
- The current implementation is designed for C2B paybill and till flows first.
- Send Money setups are persisted in the database but do not call Daraja URL
  registration.
