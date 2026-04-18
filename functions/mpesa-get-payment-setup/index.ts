import {
  errorResponse,
  handleOptions,
  jsonResponse,
  methodNotAllowed,
  parseJsonBody,
} from "../_shared/http.ts";
import { requireAuthenticatedUser } from "../_shared/supabase.ts";

/**
 * GET /mpesa-get-payment-setup
 * POST body: { unitId: string }
 *
 * Returns the active M-Pesa payment setup details for a tenant's unit.
 * Resolution priority: unit scope → property scope → workspace scope.
 *
 * Called by the Flutter tenant app when the tenant taps "Pay Rent".
 * Also usable by the owner/admin web app to preview what the tenant sees.
 */
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return handleOptions();

  // Accept both GET (with query param) and POST (with JSON body) for flexibility
  if (req.method !== "POST" && req.method !== "GET") {
    return methodNotAllowed(req.method);
  }

  try {
    const { client } = await requireAuthenticatedUser(req);

    // Resolve unitId from body (POST) or query string (GET)
    let unitId: string | undefined;

    if (req.method === "POST") {
      const body = await parseJsonBody(req);
      unitId = body?.unitId as string | undefined;
    } else {
      const url = new URL(req.url);
      unitId = url.searchParams.get("unitId") ?? undefined;
    }

    if (!unitId) {
      return errorResponse("unitId is required", 400);
    }

    // UUID format check
    const UUID_RE =
      /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
    if (!UUID_RE.test(unitId)) {
      return errorResponse("unitId must be a valid UUID", 400);
    }

    const { data, error } = await client.rpc(
      "get_active_payment_setup_for_tenant",
      { p_unit_id: unitId },
    );

    if (error) {
      // The RPC raises explicit exceptions for auth / not-found cases
      if (error.message?.includes("Not authenticated")) {
        return errorResponse("Not authenticated", 401);
      }
      if (error.message?.includes("Forbidden")) {
        return errorResponse("You do not have a confirmed tenancy for this unit", 403);
      }
      if (error.message?.includes("Unit not found")) {
        return errorResponse("Unit not found", 404);
      }
      return errorResponse("Could not load payment setup", 500, error.message);
    }

    // RPC returns a row set; take the first (and only) row
    const setup = Array.isArray(data) ? data[0] : data;

    if (!setup) {
      return jsonResponse(
        {
          setup: null,
          message:
            "No active payment setup has been configured for this unit. " +
            "Please contact your landlord.",
        },
        200,
      );
    }

    // Determine the human-readable payment type label
    const paymentTypeLabel: Record<string, string> = {
      mpesa_paybill: "M-Pesa Paybill",
      mpesa_till: "M-Pesa Till Number",
      mpesa_send_money: "M-Pesa Send Money",
    };

    // Build a Flutter-friendly response with only display-safe fields
    return jsonResponse({
      setup: {
        paymentMethodType: setup.payment_method_type,
        paymentMethodLabel:
          paymentTypeLabel[setup.payment_method_type] ?? setup.payment_method_type,
        displayName: setup.display_name,
        accountName: setup.account_name,
        // Only one of these will be non-null based on payment method type
        paybillNumber: setup.paybill_number ?? null,
        tillNumber: setup.till_number ?? null,
        sendMoneyPhone: setup.send_money_phone ?? null,
        // The account reference the tenant should enter when paying
        accountReference: setup.account_reference,
        // Optional step-by-step instructions from the owner
        collectionInstructions: setup.collection_instructions ?? null,
        // Which scope this setup was found at (informational)
        setupScope: setup.setup_scope,
      },
    });
  } catch (error) {
    return errorResponse(
      error instanceof Error ? error.message : "Unexpected error",
      500,
    );
  }
});
