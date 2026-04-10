import { corsHeaders } from "./cors.ts";

export function jsonResponse(payload: unknown, init: ResponseInit = {}) {
  return new Response(JSON.stringify(payload), {
    ...init,
    headers: {
      "Content-Type": "application/json",
      ...corsHeaders,
      ...(init.headers ?? {}),
    },
  });
}

export function errorResponse(
  message: string,
  status = 400,
  details?: unknown,
) {
  return jsonResponse(
    {
      error: message,
      details: details ?? null,
    },
    { status },
  );
}

export function methodNotAllowed(method: string) {
  return errorResponse(`Method ${method} not allowed`, 405);
}

export function handleOptions() {
  return new Response("ok", {
    headers: corsHeaders,
  });
}

export async function parseJsonBody(req: Request) {
  try {
    return await req.json();
  } catch (_error) {
    throw new Error("Request body must be valid JSON");
  }
}
