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
    headers: {
      Authorization: `Basic ${credentials}`,
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
    headers: {
      Authorization: `Bearer ${accessToken}`,
      "Content-Type": "application/json",
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
