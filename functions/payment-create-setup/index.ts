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

async function attemptDarajaRegistration(
  setupId: string,
  shortCode: string,
): Promise<void> {
  const serviceClient = getServiceRoleClient();

  if (shouldSkipC2BRegistration()) {
    await serviceClient.rpc(
      "mark_payment_collection_setup_mpesa_registration",
      {
        p_setup_id: setupId,
        p_status: "registered",
        p_response: {
          note: "Skipped in sandbox - marked as registered for testing",
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

    const {
      scopeType,
      workspaceId = null,
      propertyId = null,
      unitId = null,
      paymentMethodType = "mpesa_paybill",
      displayName = null,
      accountName,
      accountNumber = null,
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

    const shouldRegister = registerUrls !== false &&
      activate === true &&
      (paymentMethodType === "mpesa_paybill" ||
        paymentMethodType === "mpesa_till");

    if (shouldRegister) {
      const serviceClient = getServiceRoleClient();
      const { data: setup, error: setupError } = await serviceClient
        .from("payment_collection_setups")
        .select("id,paybill_number,till_number,payment_method_type")
        .eq("id", setupId)
        .single();

      if (setupError || !setup) {
        return jsonResponse({
          setupId,
          registration: {
            status: "skipped",
            reason: "Could not load setup for Daraja registration",
          },
        });
      }

      const shortCode = setup.paybill_number ?? setup.till_number;

      // deno-lint-ignore no-explicit-any
      (globalThis as any).EdgeRuntime?.waitUntil(
        attemptDarajaRegistration(setupId, shortCode),
      );
    }

    return jsonResponse({
      setupId,
      registration: shouldRegister ? { status: "pending" } : null,
    });
  } catch (error) {
    return errorResponse(
      error instanceof Error ? error.message : "Unexpected error",
      500,
    );
  }
});
