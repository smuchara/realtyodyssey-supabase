// @ts-nocheck
type RegisterC2BUrlsInput = {
  shortCode: string;
  confirmationUrl: string;
  validationUrl: string;
  responseType?: "Completed" | "Cancelled";
};

type RegisterC2BUrlsResult = {
  ConversationID?: string;
  OriginatorConversationID?: string;
  ResponseDescription?: string;
  [key: string]: unknown;
};

function getEnv(name: string) {
  const value = Deno.env.get(name);
  if (!value) {
    throw new Error(`Missing environment variable: ${name}`);
  }

  return value;
}

function getDarajaBaseUrl() {
  const explicit = Deno.env.get("MPESA_DARAJA_BASE_URL");
  if (explicit) return explicit.replace(/\/$/, "");

  const environment = (Deno.env.get("MPESA_ENVIRONMENT") ?? "sandbox")
    .trim()
    .toLowerCase();

  return environment === "production"
    ? "https://api.safaricom.co.ke"
    : "https://sandbox.safaricom.co.ke";
}

function getOAuthUrl() {
  return (
    Deno.env.get("MPESA_OAUTH_URL") ??
      `${getDarajaBaseUrl()}/oauth/v1/generate?grant_type=client_credentials`
  );
}

function getRegisterUrl() {
  return (
    Deno.env.get("MPESA_C2B_REGISTER_URL") ??
      `${getDarajaBaseUrl()}/mpesa/c2b/v1/registerurl`
  );
}

/**
 * Returns true when running in the Daraja sandbox environment.
 * Used to skip broken sandbox behaviours like C2B URL registration.
 */
export function isSandboxMode(): boolean {
  const env = (Deno.env.get("MPESA_ENVIRONMENT") ?? "sandbox")
    .trim()
    .toLowerCase();
  return env !== "production";
}

/**
 * Returns true when C2B URL registration should be skipped entirely.
 * This is always true in sandbox (endpoint is unreliable) and can also
 * be forced via MPESA_SKIP_C2B_REGISTRATION=true in any environment.
 */
export function shouldSkipC2BRegistration(): boolean {
  const explicit = Deno.env.get("MPESA_SKIP_C2B_REGISTRATION");
  if (explicit === "true") return true;
  if (explicit === "false") return false;
  // Default: skip in sandbox, register in production
  return isSandboxMode();
}

export function buildSupabaseFunctionUrl(functionName: string) {
  const explicit = Deno.env.get(
    `FUNCTION_URL_${functionName.toUpperCase().replace(/-/g, "_")}`,
  );
  if (explicit) return explicit;

  return `${getEnv("SUPABASE_URL")}/functions/v1/${functionName}`;
}

export async function getDarajaAccessToken() {
  const consumerKey = getEnv("MPESA_CONSUMER_KEY");
  const consumerSecret = getEnv("MPESA_CONSUMER_SECRET");
  const credentials = btoa(`${consumerKey}:${consumerSecret}`);

  const response = await fetch(getOAuthUrl(), {
    method: "GET",
    signal: AbortSignal.timeout(25000),
    headers: {
      Authorization: `Basic ${credentials}`,
      "User-Agent": "realtyodyssey-backend/1.0",
      Accept: "application/json",
    },
  });

  const payload = await response.json();
  if (!response.ok || !payload?.access_token) {
    throw new Error(
      `Failed to obtain Daraja access token: ${JSON.stringify(payload)}`,
    );
  }

  return payload.access_token as string;
}

export async function registerC2BUrls(
  input: RegisterC2BUrlsInput,
): Promise<RegisterC2BUrlsResult> {
  const accessToken = await getDarajaAccessToken();
  const response = await fetch(getRegisterUrl(), {
    method: "POST",
    signal: AbortSignal.timeout(25000),
    headers: {
      Authorization: `Bearer ${accessToken}`,
      "Content-Type": "application/json",
      "User-Agent": "realtyodyssey-backend/1.0",
      Accept: "application/json",
    },
    body: JSON.stringify({
      ShortCode: input.shortCode,
      ResponseType: input.responseType ?? "Completed",
      ConfirmationURL: input.confirmationUrl,
      ValidationURL: input.validationUrl,
    }),
  });

  const payload = await response.json();
  if (!response.ok) {
    throw new Error(
      `Daraja register URL request failed: ${JSON.stringify(payload)}`,
    );
  }

  return payload as RegisterC2BUrlsResult;
}

export function getDarajaPassword(
  shortCode: string,
  passKey: string,
  timestamp: string,
) {
  return btoa(`${shortCode}${passKey}${timestamp}`);
}

export async function initiateStkPush(input: {
  shortCode: string;
  passKey: string;
  amount: number;
  phoneNumber: string;
  accountReference: string;
  transactionDesc: string;
  callbackUrl: string;
}): Promise<any> {
  const timestamp =
    new Date().toISOString().replace(/[-:T]/g, "").split(".")[0];
  const password = getDarajaPassword(input.shortCode, input.passKey, timestamp);
  const accessToken = await getDarajaAccessToken();

  const response = await fetch(
    `${getDarajaBaseUrl()}/mpesa/stkpush/v1/processrequest`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        BusinessShortCode: input.shortCode,
        Password: password,
        Timestamp: timestamp,
        TransactionType: "CustomerPayBillOnline",
        Amount: Math.round(input.amount),
        PartyA: input.phoneNumber,
        PartyB: input.shortCode,
        PhoneNumber: input.phoneNumber,
        CallBackURL: input.callbackUrl,
        AccountReference: input.accountReference.substring(0, 12),
        TransactionDesc: input.transactionDesc.substring(0, 13),
      }),
    },
  );

  const payload = await response.json();
  if (!response.ok) {
    throw new Error(`STK Push failed: ${JSON.stringify(payload)}`);
  }

  return payload;
}

