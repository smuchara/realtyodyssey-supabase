import {
  buildSupabaseFunctionUrl,
  registerC2BUrls,
  shouldSkipC2BRegistration,
} from "../_shared/daraja.ts";
import {
  errorResponse,
  handleOptions,
  jsonResponse,
  methodNotAllowed,
  parseJsonBody,
} from "../_shared/http.ts";
import {
  getServiceRoleClient,
  requireAuthenticatedUser,
} from "../_shared/supabase.ts";

// Attempt Daraja C2B URL registration in the background.
// This runs after the HTTP response has already been sent to the client,
// so slowness or failure from Safaricom's sandbox does not block the user.
async function attemptDarajaRegistration(
  setupId: string,
  shortCode: string,
): Promise<void> {
  const serviceClient = getServiceRoleClient();

  // Safaricom's sandbox C2B registration endpoint is permanently unreliable.
  // Skip the actual API call and mark as registered so testing can proceed.
  if (shouldSkipC2BRegistration()) {
    await serviceClient.rpc(
      "mark_payment_collection_setup_mpesa_registration",
      {
        p_setup_id: setupId,
        p_status: "registered",
        p_response: {
          note: "Skipped in sandbox — marked as registered for testing",
        },
      },
    );
    return;
  }

  try {
    const response = await registerC2BUrls({
      shortCode,
      confirmationUrl: buildSupabaseFunctionUrl("daraja-c2b-confirmation"),
      validationUrl: buildSupabaseFunctionUrl("daraja-c2b-validation"),
    });

    await serviceClient.rpc(
      "mark_payment_collection_setup_mpesa_registration",
      {
        p_setup_id: setupId,
        p_status: "registered",
        p_response: response,
      },
    );
  } catch (err) {
    const message = err instanceof Error
      ? err.message
      : "Unknown Daraja registration error";

    await serviceClient.rpc(
      "mark_payment_collection_setup_mpesa_registration",
      {
        p_setup_id: setupId,
        p_status: "failed",
        p_response: { error: message },
      },
    );
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return handleOptions();
  if (req.method !== "POST") return methodNotAllowed(req.method);

  try {
    const { client } = await requireAuthenticatedUser(req);
    const body = await parseJsonBody(req);
    const setupId = body?.setupId as string | undefined;

    if (!setupId) {
      return errorResponse("setupId is required", 400);
    }

    const { data: visibleSetup, error: visibleSetupError } = await client
      .from("payment_collection_setups")
      .select(
        "id,payment_method_type,paybill_number,till_number,lifecycle_status",
      )
      .eq("id", setupId)
      .single();

    if (visibleSetupError || !visibleSetup) {
      return errorResponse(
        "Payment setup not found",
        404,
        visibleSetupError?.message,
      );
    }

    if (
      visibleSetup.payment_method_type !== "mpesa_paybill" &&
      visibleSetup.payment_method_type !== "mpesa_till"
    ) {
      return errorResponse(
        "Only paybill and till setups can register C2B URLs",
        400,
      );
    }

    if (visibleSetup.lifecycle_status !== "active") {
      return errorResponse(
        "Payment setup must be active before registering C2B URLs",
        400,
      );
    }

    const shortCode = visibleSetup.paybill_number ?? visibleSetup.till_number;

    // Fire-and-forget: register URLs in background after response is sent.
    // This prevents Safaricom sandbox timeouts from blocking the user.
    // deno-lint-ignore no-explicit-any
    (globalThis as any).EdgeRuntime?.waitUntil(
      attemptDarajaRegistration(setupId, shortCode),
    );

    // Respond immediately — Daraja registration happens in the background.
    return jsonResponse({
      setupId,
      registration: { status: "pending" },
    });
  } catch (error) {
    return errorResponse(
      error instanceof Error ? error.message : "Unexpected error",
      500,
    );
  }
});
