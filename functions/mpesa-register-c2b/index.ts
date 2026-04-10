import { registerC2BUrls, buildSupabaseFunctionUrl } from "../_shared/daraja.ts";
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
      .select("id,payment_method_type,paybill_number,till_number,lifecycle_status")
      .eq("id", setupId)
      .single();

    if (visibleSetupError || !visibleSetup) {
      return errorResponse("Payment setup not found", 404, visibleSetupError?.message);
    }

    if (
      visibleSetup.payment_method_type !== "mpesa_paybill" &&
      visibleSetup.payment_method_type !== "mpesa_till"
    ) {
      return errorResponse("Only paybill and till setups can register C2B URLs", 400);
    }

    if (visibleSetup.lifecycle_status !== "active") {
      return errorResponse("Payment setup must be active before registering C2B URLs", 400);
    }

    const serviceClient = getServiceRoleClient();
    const shortCode = visibleSetup.paybill_number ?? visibleSetup.till_number;

    try {
      const response = await registerC2BUrls({
        shortCode,
        confirmationUrl: buildSupabaseFunctionUrl("mpesa-c2b-confirmation"),
        validationUrl: buildSupabaseFunctionUrl("mpesa-c2b-validation"),
      });

      await serviceClient.rpc("mark_payment_collection_setup_mpesa_registration", {
        p_setup_id: setupId,
        p_status: "registered",
        p_response: response,
      });

      return jsonResponse({
        setupId,
        status: "registered",
        response,
      });
    } catch (registrationError) {
      const message = registrationError instanceof Error
        ? registrationError.message
        : "Unknown Daraja registration error";

      await serviceClient.rpc("mark_payment_collection_setup_mpesa_registration", {
        p_setup_id: setupId,
        p_status: "failed",
        p_response: { error: message },
      });

      return errorResponse("Daraja registration failed", 502, {
        setupId,
        message,
      });
    }
  } catch (error) {
    return errorResponse(
      error instanceof Error ? error.message : "Unexpected error",
      500,
    );
  }
});
