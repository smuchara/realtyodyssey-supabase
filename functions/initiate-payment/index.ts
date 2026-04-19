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
      invoiceId, // This is the rent_charge_period_id
      phoneNumber, // Optional: override phone number for STK prompt
    } = body ?? {};

    if (!invoiceId) {
      return errorResponse("invoiceId is required", 400);
    }

    const serviceClient = getServiceRoleClient();

    // 1. Fetch Invoice (Rent Charge Period)
    const { data: invoice, error: invoiceError } = await serviceClient
      .from("rent_charge_periods")
      .select(`
        id,
        workspace_id,
        property_id,
        unit_id,
        scheduled_amount,
        outstanding_amount,
        charge_status
      `)
      .eq("id", invoiceId)
      .single();

    if (invoiceError || !invoice) {
      return errorResponse("Invoice not found", 404);
    }

    if (invoice.charge_status === "paid") {
      return errorResponse("Invoice is already paid", 400);
    }

    // 2. Fetch Active Payment Setup for the Unit/Property/Workspace
    // We reuse the RPC logic or just query the setups directly
    const { data: setup, error: setupError } = await serviceClient
      .schema("app")
      .rpc("get_active_payment_setup_for_tenant", {
        p_unit_id: invoice.unit_id,
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

    // 4. Normalize Phone Number
    let formattedPhone = phoneNumber || user.phone ||
      user.user_metadata?.phone || "";
    formattedPhone = formattedPhone.toString().replace(/[\s\-\+]/g, "");
    if (formattedPhone.startsWith("0")) {
      formattedPhone = "254" + formattedPhone.substring(1);
    } else if (!formattedPhone.startsWith("254")) {
      formattedPhone = "254" + formattedPhone;
    }

    if (formattedPhone.length !== 12) {
      return errorResponse(
        "Invalid phone number format. Use 254XXXXXXXXX",
        400,
      );
    }

    // 5. Pre-persist STK Request (Status: PENDING)
    const { data: stkRequest, error: requestError } = await serviceClient
      .from("mpesa_stk_requests")
      .insert({
        workspace_id: invoice.workspace_id,
        property_id: invoice.property_id,
        unit_id: invoice.unit_id,
        rent_charge_period_id: invoice.id,
        payment_collection_setup_id: setup.id,
        amount: invoice.outstanding_amount,
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
        amount: invoice.outstanding_amount,
        phoneNumber: formattedPhone,
        accountReference: setup.account_reference_hint || "Rent",
        transactionDesc: `Rent ${invoice.id.substring(0, 8)}`,
        callbackUrl: buildSupabaseFunctionUrl("mpesa-callback"),
        transactionType
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
