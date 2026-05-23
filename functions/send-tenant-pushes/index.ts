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

type DispatchRequest = {
  action?: "dispatch_pending" | "debug_self_test" | "diagnostics";
  tenant_user_id?: string;
  title?: string;
  body?: string;
};

class HttpError extends Error {
  constructor(message: string, readonly status: number) {
    super(message);
  }
}

let cachedAccessToken: { token: string; expiresAt: number } | null = null;

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return handleOptions();
  if (req.method !== "POST") return methodNotAllowed(req.method);

  try {
    requireDispatchAuth(req);

    const body = await readDispatchRequest(req);
    const serviceClient = getServiceRoleClient();
    const action = body.action ?? "dispatch_pending";

    if (action === "diagnostics") {
      return jsonResponse(await getDiagnostics(serviceClient, body));
    }

    if (action === "debug_self_test") {
      return jsonResponse(await sendDebugSelfTest(serviceClient, body));
    }

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

    console.log("push dispatch complete", { processed: results.length });
    return jsonResponse({
      processed: results.length,
      results,
    });
  } catch (error) {
    console.error("push dispatch failed", error);
    return errorResponse(
      error instanceof Error ? error.message : "Internal Server Error",
      error instanceof HttpError ? error.status : 500,
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
    throw new HttpError("Unauthorized", 401);
  }
}

async function readDispatchRequest(req: Request): Promise<DispatchRequest> {
  const contentType = req.headers.get("content-type") ?? "";
  if (!contentType.includes("application/json")) return {};

  try {
    return await req.json() as DispatchRequest;
  } catch (_error) {
    throw new HttpError("Request body must be valid JSON", 400);
  }
}

async function sendDelivery(
  serviceClient: ReturnType<typeof getServiceRoleClient>,
  delivery: PushDelivery,
) {
  console.log("processing push delivery", {
    delivery_id: delivery.id,
    notification_id: delivery.notification_id,
    tenant_user_id: delivery.tenant_user_id,
    attempts: delivery.attempts,
  });

  const { data: notification, error: notificationError } = await serviceClient
    .from("tenant_notifications")
    .select("id, type, title, body, request_id, ticket_id, payload")
    .eq("id", delivery.notification_id)
    .maybeSingle();

  if (notificationError || notification == null) {
    await markDelivery(
      serviceClient,
      delivery,
      "failed",
      "Notification not found",
    );
    return {
      id: delivery.id,
      status: "failed",
      reason: "notification_missing",
    };
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
    console.warn("push delivery skipped: no active tokens", {
      delivery_id: delivery.id,
      tenant_user_id: delivery.tenant_user_id,
    });
    await markDelivery(
      serviceClient,
      delivery,
      "skipped",
      "No active push tokens",
    );
    return { id: delivery.id, status: "skipped", reason: "no_tokens" };
  }

  let sent = 0;
  const errors: string[] = [];

  for (const pushToken of activeTokens) {
    try {
      await sendFcmMessage(pushToken, notification as TenantNotification);
      sent += 1;
      console.log("fcm send succeeded", {
        delivery_id: delivery.id,
        token_id: pushToken.id,
        platform: pushToken.platform,
      });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      errors.push(message);
      console.error("fcm send failed", {
        delivery_id: delivery.id,
        token_id: pushToken.id,
        platform: pushToken.platform,
        error: message,
      });

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

async function getDiagnostics(
  serviceClient: ReturnType<typeof getServiceRoleClient>,
  request: DispatchRequest,
) {
  let tokenQuery = serviceClient
    .from("tenant_push_tokens")
    .select("id, tenant_user_id, platform, token, is_active, last_seen_at")
    .order("last_seen_at", { ascending: false })
    .limit(10);

  let deliveryQuery = serviceClient
    .from("tenant_push_deliveries")
    .select(
      "id, notification_id, tenant_user_id, status, attempts, last_error, " +
        "sent_at, created_at",
    )
    .order("created_at", { ascending: false })
    .limit(10);

  if (request.tenant_user_id) {
    tokenQuery = tokenQuery.eq("tenant_user_id", request.tenant_user_id);
    deliveryQuery = deliveryQuery.eq(
      "tenant_user_id",
      request.tenant_user_id,
    );
  }

  const [{ data: tokens, error: tokensError }, {
    data: deliveries,
    error: deliveriesError,
  }] = await Promise.all([tokenQuery, deliveryQuery]);

  if (tokensError) throw new HttpError(tokensError.message, 400);
  if (deliveriesError) throw new HttpError(deliveriesError.message, 400);

  return {
    tokens: (tokens ?? []).map((token) => ({
      ...token,
      token: maskToken(token.token),
    })),
    deliveries: deliveries ?? [],
  };
}

async function sendDebugSelfTest(
  serviceClient: ReturnType<typeof getServiceRoleClient>,
  request: DispatchRequest,
) {
  let query = serviceClient
    .from("tenant_push_tokens")
    .select("id, token, platform, tenant_user_id, last_seen_at")
    .eq("is_active", true)
    .order("last_seen_at", { ascending: false })
    .limit(5);

  if (request.tenant_user_id) {
    query = query.eq("tenant_user_id", request.tenant_user_id);
  }

  const { data, error } = await query;
  if (error) throw new HttpError(error.message, 400);

  const tokens = (data ?? []) as Array<
    PushToken & {
      tenant_user_id: string;
      last_seen_at: string;
    }
  >;

  if (tokens.length === 0) {
    return {
      status: "skipped",
      reason: "missing_fcm_token",
      tenant_user_id: request.tenant_user_id ?? null,
    };
  }

  const notification: TenantNotification = {
    id: crypto.randomUUID(),
    type: "debug_push_test",
    title: request.title ?? "RealtyOdyssey push test",
    body: request.body ?? "If you see this, Firebase push is working.",
    request_id: null,
    ticket_id: null,
    payload: {
      request_reference: "DEBUG",
      ticket_reference: "DEBUG",
    },
  };

  const results = [];
  for (const token of tokens) {
    try {
      await sendFcmMessage(token, notification);
      results.push({
        token_id: token.id,
        token: maskToken(token.token),
        tenant_user_id: token.tenant_user_id,
        platform: token.platform,
        status: "sent",
      });
    } catch (error) {
      results.push({
        token_id: token.id,
        token: maskToken(token.token),
        tenant_user_id: token.tenant_user_id,
        platform: token.platform,
        status: "failed",
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }

  return {
    status: results.some((result) => result.status === "sent")
      ? "sent"
      : "failed",
    results,
  };
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
            title: notification.title,
            body: notification.body,
            request_id: notification.request_id ?? "",
            ticket_id: notification.ticket_id ?? "",
            route: routeForNotification(notification.type),
            ticket_reference: stringify(payload["ticket_reference"]),
            request_reference: stringify(payload["request_reference"]),
          },
          android: {
            priority: "HIGH",
            notification: {
              channel_id: "default",
              click_action: "FLUTTER_NOTIFICATION_CLICK",
              sound: "default",
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

function maskToken(token: string) {
  if (token.length <= 16) return "***";
  return `${token.slice(0, 8)}...${token.slice(-8)}`;
}

function routeForNotification(type: string) {
  if (type === "maintenance_status_update") return "maintenance/tracking";
  if (type === "maintenance_delay_checkin") return "maintenance/delay-checkin";
  if (type === "access_scan_approved") return "access/history";
  if (type === "access_scan_warning") return "access";
  if (type === "access_scan_denied") return "access";
  return "maintenance/review";
}
