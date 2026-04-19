// @ts-nocheck: Deno globals not recognized in some IDE environments
import {
  buildSupabaseFunctionUrl,
  initiateStkPush,
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

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return handleOptions();
  if (req.method !== "POST") return methodNotAllowed(req.method);

  try {
    const { user } = await requireAuthenticatedUser(req);
    const body = await parseJsonBody(req);

    const {
      invoiceId, // Optional: for specific rent charge periods
      unitId, // Optional: for advance payments/top-ups
      amount, // Required if no invoiceId
      phoneNumber, // Optional: override phone number for STK prompt
    } = body ?? {};

    // 1. Resolve logical "Invoice" or "Unit" for payment
    let targetUnitId = unitId;
    let targetAmount = amount;
    const targetInvoiceId = (invoiceId && invoiceId !== "MOCK_INVOICE_ID")
      ? invoiceId
      : null;
    let targetWorkspaceId;
    let targetPropertyId;

    if (!targetUnitId && !targetInvoiceId) {
      return errorResponse(
        "Missing identification: either invoiceId or unitId must be provided",
        400,
      );
    }

    const serviceClient = getServiceRoleClient();

    if (targetInvoiceId) {
      // Flow A: Paying a specific invoice
      const { data: invoice, error: invoiceError } = await serviceClient
        .from("rent_charge_periods")
        .select(`
          id,
          workspace_id,
          property_id,
          unit_id,
          outstanding_amount,
          charge_status
        `)
        .eq("id", targetInvoiceId)
        .single();

      if (invoiceError || !invoice) {
        return errorResponse(`Invoice not found: ${targetInvoiceId}`, 404);
      }

      if (invoice.charge_status === "paid") {
        return errorResponse("Invoice is already paid", 400);
      }

      targetUnitId = invoice.unit_id;
      targetAmount = invoice.outstanding_amount;
      targetWorkspaceId = invoice.workspace_id;
      targetPropertyId = invoice.property_id;
    } else {
      // Flow B: Advance Payment / Unit Top-up
      if (!targetUnitId) {
        return errorResponse("unitId is required for advance payments", 400);
      }
      if (!targetAmount || targetAmount <= 0) {
        return errorResponse(
          `Valid amount (> 0) is required for advance payments. Received: ${targetAmount}`,
          400,
        );
      }

      const { data: unit, error: unitError } = await serviceClient
        .from("units")
        .select("id, property_id, properties!inner(workspace_id)")
        .eq("id", targetUnitId)
        .single();

      if (unitError || !unit) {
        return errorResponse(`Unit not found: ${targetUnitId}`, 404);
      }

      targetWorkspaceId = unit.properties.workspace_id;
      targetPropertyId = unit.property_id;
    }

    // 2. Fetch Active Payment Setup
    const { data: setup, error: setupError } = await serviceClient
      .schema("app")
      .rpc("get_active_payment_setup_for_tenant", {
        p_unit_id: targetUnitId,
      })
      .maybeSingle();

    if (setupError || !setup) {
      return errorResponse(
        "No active payment methods found for this property",
        404,
      );
    }

    // 3. Resolve Credentials and Transaction Type
    const shortCode = setup.paybill_number ?? setup.till_number;
    const passKey = setup.metadata?.mpesa_passkey ??
      Deno.env.get("MPESA_PASSKEY");
    const transactionType = setup.payment_method_type === "mpesa_paybill"
      ? "CustomerPayBillOnline"
      : "CustomerBuyGoodsOnline";

    if (!shortCode || !passKey) {
      return errorResponse(
        "Payment setup is incomplete (missing shortcode or passkey)",
        500,
      );
    }

    // 4. Resolve and Normalize Phone Number
    let rawPhone = phoneNumber || user.phone ||
      user.user_metadata?.phone;

    // Fallback: If no phone in Auth/Body, try Unit Snapshot
    if (!rawPhone && targetUnitId) {
      const { data: snapshot } = await serviceClient
        .from("unit_occupancy_snapshots")
        .select("current_tenant_phone")
        .eq("unit_id", targetUnitId)
        .maybeSingle();

      if (snapshot?.current_tenant_phone) {
        rawPhone = snapshot.current_tenant_phone;
      }
    }

    if (!rawPhone) {
      return errorResponse(
        "Phone number not found. Please provide a phoneNumber in the request or update your profile.",
        400,
      );
    }

    let formattedPhone = rawPhone.toString().replace(/[\s\-\+]/g, "");
    if (formattedPhone.startsWith("0")) {
      formattedPhone = "254" + formattedPhone.substring(1);
    } else if (!formattedPhone.startsWith("254")) {
      formattedPhone = "254" + formattedPhone;
    }

    if (formattedPhone.length !== 12) {
      return errorResponse(
        `Invalid phone number format: ${formattedPhone}. Expected 254XXXXXXXXX (12 digits)`,
        400,
      );
    }

    // 5. Pre-persist STK Request (Status: PENDING)
    const { data: stkRequest, error: requestError } = await serviceClient
      .from("mpesa_stk_requests")
      .insert({
        workspace_id: targetWorkspaceId,
        property_id: targetPropertyId,
        unit_id: targetUnitId,
        rent_charge_period_id: targetInvoiceId,
        payment_collection_setup_id: setup.id,
        amount: targetAmount,
        phone_number: formattedPhone,
        status: "pending",
      })
      .select()
      .single();

    if (requestError) {
      console.error("Failed to create STK request:", requestError);
      return errorResponse("Failed to initialize payment tracking", 500);
    }

    // 6. Call Daraja
    try {
      const stkResponse = await initiateStkPush({
        shortCode,
        passKey,
        amount: targetAmount,
        phoneNumber: formattedPhone,
        accountReference: setup.account_reference_hint || "Rent",
        transactionDesc: targetInvoiceId
          ? `Rent ${targetInvoiceId.substring(0, 8)}`
          : `Advance Pay ${targetUnitId.substring(0, 8)}`,
        callbackUrl: buildSupabaseFunctionUrl("mpesa-callback"),
        transactionType,
      });

      // 7. Update Request with Daraja IDs
      await serviceClient
        .from("mpesa_stk_requests")
        .update({
          checkout_request_id: stkResponse.CheckoutRequestID,
          merchant_request_id: stkResponse.MerchantRequestID,
        })
        .eq("id", stkRequest.id);

      return jsonResponse({
        success: true,
        checkoutRequestId: stkResponse.CheckoutRequestID,
        customerMessage: stkResponse.CustomerMessage ||
          "Please enter your M-Pesa PIN on your phone.",
      });
    } catch (darajaError) {
      // Mark as failed if Daraja rejects immediately
      await serviceClient
        .from("mpesa_stk_requests")
        .update({
          status: "failed",
          result_desc: darajaError.message,
        })
        .eq("id", stkRequest.id);

      return errorResponse(darajaError.message, 500);
    }
  } catch (error) {
    return errorResponse(
      error instanceof Error ? error.message : "Internal Server Error",
      500,
    );
  }
});
