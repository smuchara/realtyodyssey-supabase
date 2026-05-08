import {
  errorResponse,
  handleOptions,
  jsonResponse,
  methodNotAllowed,
} from "../_shared/http.ts";
import { getServiceRoleClient } from "../_shared/supabase.ts";

type PushDelivery = {
  id: string;
  attempts: number;
  tenant_user_id: string;
  notification_id: string;
};

type TenantNotification = {
  id: string;
  type: string;
  title: string;
  body: string;
  request_id: string | null;
  ticket_id: string | null;
  payload: Record<string, unknown> | null;
};

type PushToken = {
  id: string;
  token: string;
  platform: "android" | "ios";
};

let cachedAccessToken: { token: string; expiresAt: number } | null = null;

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return handleOptions();
  if (req.method !== "POST") return methodNotAllowed(req.method);

  try {
    requireDispatchAuth(req);

    const serviceClient = getServiceRoleClient();
    const { data: deliveries, error: deliveriesError } = await serviceClient
      .from("tenant_push_deliveries")
      .select("id, attempts, tenant_user_id, notification_id")
      .eq("status", "pending")
      .lt("attempts", 3)
      .order("created_at", { ascending: true })
      .limit(50);

    if (deliveriesError) {
      return errorResponse(deliveriesError.message, 400);
    }

    const results = [];

    for (const delivery of (deliveries ?? []) as PushDelivery[]) {
      const result = await sendDelivery(serviceClient, delivery);
      results.push(result);
    }

    return jsonResponse({
      processed: results.length,
      results,
    });
  } catch (error) {
    return errorResponse(
      error instanceof Error ? error.message : "Internal Server Error",
      500,
    );
  }
});

function requireDispatchAuth(req: Request) {
  const secret = Deno.env.get("PUSH_DISPATCH_SECRET");
  if (!secret) {
    throw new Error("Missing environment variable: PUSH_DISPATCH_SECRET");
  }

  const provided = req.headers.get("x-push-dispatch-secret");
  if (provided !== secret) {
    throw new Error("Unauthorized");
  }
}

async function sendDelivery(
  serviceClient: ReturnType<typeof getServiceRoleClient>,
  delivery: PushDelivery,
) {
  const { data: notification, error: notificationError } = await serviceClient
    .from("tenant_notifications")
    .select("id, type, title, body, request_id, ticket_id, payload")
    .eq("id", delivery.notification_id)
    .maybeSingle();

  if (notificationError || notification == null) {
    await markDelivery(serviceClient, delivery, "failed", "Notification not found");
    return { id: delivery.id, status: "failed", reason: "notification_missing" };
  }

  const { data: tokens, error: tokensError } = await serviceClient
    .from("tenant_push_tokens")
    .select("id, token, platform")
    .eq("tenant_user_id", delivery.tenant_user_id)
    .eq("is_active", true);

  if (tokensError) {
    await markDelivery(serviceClient, delivery, "failed", tokensError.message);
    return { id: delivery.id, status: "failed", reason: tokensError.message };
  }

  const activeTokens = (tokens ?? []) as PushToken[];
  if (activeTokens.length === 0) {
    await markDelivery(serviceClient, delivery, "skipped", "No active push tokens");
    return { id: delivery.id, status: "skipped", reason: "no_tokens" };
  }

  let sent = 0;
  const errors: string[] = [];

  for (const pushToken of activeTokens) {
    try {
      await sendFcmMessage(pushToken, notification as TenantNotification);
      sent += 1;
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      errors.push(message);

      if (
        message.includes("UNREGISTERED") ||
        message.includes("registration-token-not-registered")
      ) {
        await serviceClient
          .from("tenant_push_tokens")
          .update({ is_active: false, updated_at: new Date().toISOString() })
          .eq("id", pushToken.id);
      }
    }
  }

  if (sent > 0) {
    await markDelivery(serviceClient, delivery, "sent", null);
    return { id: delivery.id, status: "sent", sent };
  }

  await markDelivery(serviceClient, delivery, "failed", errors.join("; "));
  return { id: delivery.id, status: "failed", reason: errors.join("; ") };
}

async function markDelivery(
  serviceClient: ReturnType<typeof getServiceRoleClient>,
  delivery: PushDelivery,
  status: "sent" | "failed" | "skipped",
  error: string | null,
) {
  await serviceClient
    .from("tenant_push_deliveries")
    .update({
      status,
      attempts: delivery.attempts + 1,
      last_error: error,
      sent_at: status === "sent" ? new Date().toISOString() : null,
      updated_at: new Date().toISOString(),
    })
    .eq("id", delivery.id);
}

async function sendFcmMessage(
  pushToken: PushToken,
  notification: TenantNotification,
) {
  const projectId = requiredEnv("FIREBASE_PROJECT_ID");
  const accessToken = await getFirebaseAccessToken();
  const payload = notification.payload ?? {};

  const response = await fetch(
    `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        message: {
          token: pushToken.token,
          notification: {
            title: notification.title,
            body: notification.body,
          },
          data: {
            notification_id: notification.id,
            type: notification.type,
            request_id: notification.request_id ?? "",
            ticket_id: notification.ticket_id ?? "",
            route: notification.type === "maintenance_delay_checkin"
              ? "maintenance/delay-checkin"
              : "maintenance/review",
            ticket_reference: stringify(payload["ticket_reference"]),
            request_reference: stringify(payload["request_reference"]),
          },
          android: {
            priority: "HIGH",
            notification: {
              channel_id: "maintenance_reviews",
              click_action: "FLUTTER_NOTIFICATION_CLICK",
            },
          },
          apns: {
            payload: {
              aps: {
                sound: "default",
              },
            },
          },
        },
      }),
    },
  );

  if (!response.ok) {
    throw new Error(await response.text());
  }
}

async function getFirebaseAccessToken() {
  if (cachedAccessToken && cachedAccessToken.expiresAt > Date.now() + 60_000) {
    return cachedAccessToken.token;
  }

  const now = Math.floor(Date.now() / 1000);
  const assertion = await signJwt({
    iss: requiredEnv("FIREBASE_CLIENT_EMAIL"),
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  });

  const response = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });

  if (!response.ok) {
    throw new Error(await response.text());
  }

  const json = await response.json() as {
    access_token: string;
    expires_in?: number;
  };
  cachedAccessToken = {
    token: json.access_token,
    expiresAt: Date.now() + (json.expires_in ?? 3600) * 1000,
  };
  return cachedAccessToken.token;
}

async function signJwt(claims: Record<string, unknown>) {
  const header = base64UrlEncode(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const body = base64UrlEncode(JSON.stringify(claims));
  const signingInput = `${header}.${body}`;
  const key = await importPrivateKey(requiredEnv("FIREBASE_PRIVATE_KEY"));
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(signingInput),
  );
  return `${signingInput}.${base64UrlEncode(signature)}`;
}

async function importPrivateKey(privateKeyPem: string) {
  const pem = privateKeyPem.replace(/\\n/g, "\n");
  const base64 = pem
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replace(/\s/g, "");
  const binary = Uint8Array.from(atob(base64), (char) => char.charCodeAt(0));

  return await crypto.subtle.importKey(
    "pkcs8",
    binary,
    {
      name: "RSASSA-PKCS1-v1_5",
      hash: "SHA-256",
    },
    false,
    ["sign"],
  );
}

function base64UrlEncode(value: string | ArrayBuffer) {
  const bytes = typeof value === "string"
    ? new TextEncoder().encode(value)
    : new Uint8Array(value);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary)
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

function requiredEnv(name: string) {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`Missing environment variable: ${name}`);
  return value;
}

function stringify(value: unknown) {
  return value == null ? "" : String(value);
}
