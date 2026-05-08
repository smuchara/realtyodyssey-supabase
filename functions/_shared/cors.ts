export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": [
    "authorization",
    "x-client-info",
    "apikey",
    "content-type",
    "x-push-dispatch-secret",
  ].join(", "),
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
} as const;
