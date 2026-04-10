import {
  buildSupabaseFunctionUrl,
  registerC2BUrls,
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

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return handleOptions();
  if (req.method !== "POST") return methodNotAllowed(req.method);

  try {
    const { client } = await requireAuthenticatedUser(req);
    const body = await parseJsonBody(req);

    const {
      scopeType,
      workspaceId = null,
      propertyId = null,
      unitId = null,
      paymentMethodType = "mpesa_paybill",
      displayName = null,
      accountName,
      accountNumber,
      accountReferenceHint = null,
      collectionInstructions = null,
      makeDefault = true,
      activate = true,
      priorityRank = 100,
      registerUrls = true,
    } = body ?? {};

    const { data: setupId, error: createError } = await client.rpc(
      "create_payment_collection_setup",
      {
        p_scope_type: scopeType,
        p_workspace_id: workspaceId,
        p_property_id: propertyId,
        p_unit_id: unitId,
        p_payment_method_type: paymentMethodType,
        p_display_name: displayName,
        p_account_name: accountName,
        p_account_number: accountNumber,
        p_account_reference_hint: accountReferenceHint,
        p_collection_instructions: collectionInstructions,
        p_make_default: makeDefault,
        p_activate: activate,
        p_priority_rank: priorityRank,
      },
    );

    if (createError || !setupId) {
      return errorResponse(
        "Could not create payment setup",
        400,
        createError?.message,
      );
    }

    let registration: Record<string, unknown> | null = null;

    if (
      registerUrls !== false &&
      activate === true &&
      (paymentMethodType === "mpesa_paybill" ||
        paymentMethodType === "mpesa_till")
    ) {
      const serviceClient = getServiceRoleClient();
      const { data: setup, error: setupError } = await serviceClient
        .from("payment_collection_setups")
        .select("id,paybill_number,till_number,payment_method_type")
        .eq("id", setupId)
        .single();

      if (setupError || !setup) {
        return errorResponse(
          "Payment setup was created but could not be loaded for M-Pesa registration",
          500,
          setupError?.message,
        );
      }

      const shortCode = setup.paybill_number ?? setup.till_number;

      try {
        const response = await registerC2BUrls({
          shortCode,
          confirmationUrl: buildSupabaseFunctionUrl("mpesa-c2b-confirmation"),
          validationUrl: buildSupabaseFunctionUrl("mpesa-c2b-validation"),
        });

        await serviceClient.rpc(
          "mark_payment_collection_setup_mpesa_registration",
          {
            p_setup_id: setupId,
            p_status: "registered",
            p_response: response,
          },
        );

        registration = {
          status: "registered",
          response,
        };
      } catch (registrationError) {
        const message = registrationError instanceof Error
          ? registrationError.message
          : "Unknown Daraja registration error";

        await serviceClient.rpc(
          "mark_payment_collection_setup_mpesa_registration",
          {
            p_setup_id: setupId,
            p_status: "failed",
            p_response: { error: message },
          },
        );

        registration = {
          status: "failed",
          error: message,
        };
      }
    }

    return jsonResponse({
      setupId,
      registration,
    });
  } catch (error) {
    return errorResponse(
      error instanceof Error ? error.message : "Unexpected error",
      500,
    );
  }
});
