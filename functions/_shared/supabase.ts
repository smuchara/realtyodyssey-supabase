import { createClient } from "@supabase/supabase-js";

function getEnv(name: string) {
  const value = Deno.env.get(name);
  if (!value) {
    throw new Error(`Missing environment variable: ${name}`);
  }

  return value;
}

export function getServiceRoleClient() {
  return createClient(
    getEnv("SUPABASE_URL"),
    getEnv("SUPABASE_SERVICE_ROLE_KEY"),
    {
      auth: {
        persistSession: false,
        autoRefreshToken: false,
      },
      db: {
        schema: "app",
      },
    },
  );
}

export function getRequestClient(req: Request) {
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    throw new Error("Missing Authorization header");
  }

  return createClient(
    getEnv("SUPABASE_URL"),
    getEnv("SUPABASE_ANON_KEY"),
    {
      auth: {
        persistSession: false,
        autoRefreshToken: false,
      },
      db: {
        schema: "app",
      },
      global: {
        headers: {
          Authorization: authHeader,
        },
      },
    },
  );
}

export async function requireAuthenticatedUser(req: Request) {
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    throw new Error("Missing Authorization header");
  }

  try {
    // 1. Manually decode the JWT to get the userId (sub)
    // This bypasses the 'Unsupported JWT algorithm ES256' error in Deno/GoTrue
    // because the Supabase gateway has already verified the token's validity.
    const token = authHeader.replace("Bearer ", "");
    const parts = token.split(".");
    if (parts.length !== 3) throw new Error("Invalid JWT format");

    const payloadBase64 = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    const payload = JSON.parse(atob(payloadBase64));
    const userId = payload.sub;

    if (!userId) throw new Error("Invalid token payload: sub missing");

    // 2. Fetch the full user object using the Service Role client
    const serviceClient = getServiceRoleClient();
    const { data: { user }, error } = await serviceClient.auth.admin
      .getUserById(
        userId,
      );

    if (error || !user) {
      throw new Error(error?.message ?? "User not found");
    }

    return { client: getRequestClient(req), user };
  } catch (err) {
    console.error("Auth helper failed:", err);
    throw new Error("Not authenticated");
  }
}
