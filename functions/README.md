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
- `send-tenant-pushes`: dispatches queued tenant maintenance notifications and
  review prompts to Firebase Cloud Messaging for users who are outside the app.

Required environment variables:

- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- `SUPABASE_SERVICE_ROLE_KEY`
- `MPESA_CONSUMER_KEY`
- `MPESA_CONSUMER_SECRET`

Push notification environment variables:

- `PUSH_DISPATCH_SECRET`
- `FIREBASE_PROJECT_ID`
- `FIREBASE_CLIENT_EMAIL`
- `FIREBASE_PRIVATE_KEY`

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
- `send-tenant-pushes` is protected by `x-push-dispatch-secret` matching
  `PUSH_DISPATCH_SECRET`; do not put this value in Flutter.
- Deploy `send-tenant-pushes` with JWT verification disabled. The function uses
  its own dispatch secret instead.
- Configure a Supabase Database Webhook on `app.tenant_push_deliveries` inserts
  to call `send-tenant-pushes` with a `POST` request and the
  `x-push-dispatch-secret` header. Queued rows in `tenant_push_deliveries` will
  not become phone notifications until this function is called.
- Use webhook URL:
  `https://ifpfptvajcqdcpbtsfsc.functions.supabase.co/send-tenant-pushes`.
- To inspect the latest saved tokens and delivery rows, call the function with:
  `{"action":"diagnostics","tenant_user_id":"<auth user id>"}`.
- To send a server-side push test to the latest active token, call it with:
  `{"action":"debug_self_test","tenant_user_id":"<auth user id>"}`.

## Tenant push webhook setup

When deploying to a clean Supabase project, queued push deliveries are not sent
automatically until a Database Webhook calls `send-tenant-pushes`. This webhook
is required for maintenance status changes and completion-review prompts to
reach tenants while the app is closed.

Create the webhook from Supabase Dashboard → Database → Webhooks.

General:

- Name: `push_notification_flutter_android_app`

Conditions:

- Table: `app.tenant_push_deliveries`
- Events: `Insert`
- Do not select `Update` or `Delete`.

Preferred configuration:

- Type of webhook: `HTTP Request`
- Method: `POST`
- URL:
  `https://<project-ref>.supabase.co/functions/v1/send-tenant-pushes`
- Timeout: `5000`

Headers:

- `Content-Type`: `application/json`
- `x-push-dispatch-secret`: the exact `PUSH_DISPATCH_SECRET` value configured
  in Edge Function secrets.

Alternative URL format:

- `https://<project-ref>.functions.supabase.co/send-tenant-pushes`

After creating the webhook, test by changing a maintenance ticket status. A row
should be inserted into `app.tenant_push_deliveries`, the webhook should invoke
`send-tenant-pushes`, and the delivery status should move from `pending` to
`sent`.

If the function logs stay empty and delivery rows stay at `attempts = 0`, the
webhook is not firing. Recheck that the table is `app.tenant_push_deliveries`,
the event is only `Insert`, and the webhook type is `HTTP Request`.
