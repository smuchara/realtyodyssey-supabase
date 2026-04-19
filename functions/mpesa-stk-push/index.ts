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
      unitId,
      amount,
      phoneNumber, // User explicitly requested to use this
      paymentSetupId,
    } = body ?? {};

    if (!unitId || !amount) {
      return errorResponse("unitId and amount are required", 400);
    }

    const serviceClient = getServiceRoleClient();

    // 1. Resolve the payment setup
    // If paymentSetupId is provided, use it. Otherwise, look up the best setup for the unit.
    let setup;
    if (paymentSetupId) {
      const { data, error } = await serviceClient
        .from("payment_collection_setups")
        .select("*")
        .eq("id", paymentSetupId)
        .single();
      if (error || !data) return errorResponse("Payment setup not found", 404);
      setup = data;
    } else {
      const { data, error } = await serviceClient
        .schema("app")
        .rpc("get_active_payment_setup_for_tenant", { p_unit_id: unitId })
        .maybeSingle();

      if (error || !data) {
        return errorResponse(
          "No active payment setup found for this unit",
          404,
        );
      }
      setup = data;
    }

    // 2. Map fields from the setup
    const shortCode = setup.paybill_number ?? setup.till_number ?? setup.paybillNumber ?? setup.tillNumber;
    const passKey = Deno.env.get("MPESA_PASSKEY");

    if (!shortCode) {
      console.error("Payment setup found but missing shortcode:", setup);
      return errorResponse(
        "Payment setup is incomplete (missing paybill or till number)",
        400,
      );
    }

    if (!passKey) {
      return errorResponse(
        "M-Pesa Passkey is not configured in Supabase Secrets",
        400,
      );
    }

    // 3. Normalize phone number (Daraja expects 2547XXXXXXXX)
    let formattedPhone = phoneNumber || user.phone ||
      user.user_metadata?.phone || "";
    formattedPhone = formattedPhone.toString().replace(/\+/g, "").replace(
      /\s/g,
      "",
    );
    if (formattedPhone.startsWith("0")) {
      formattedPhone = "254" + formattedPhone.substring(1);
    }
    if (!formattedPhone.startsWith("254")) {
      formattedPhone = "254" + formattedPhone;
    }

    // 4. Trigger STK Push via Daraja
    const stkResponse = await initiateStkPush({
      shortCode,
      passKey,
      amount,
      phoneNumber: formattedPhone,
      accountReference: setup.account_reference || "Rent",
      transactionDesc: `Rent Payment - ${unitId}`,
      callbackUrl: buildSupabaseFunctionUrl("daraja-c2b-confirmation"),
    });

    return jsonResponse({
      success: true,
      checkoutRequestId: stkResponse.CheckoutRequestID,
      customerMessage: stkResponse.CustomerMessage,
      responseDescription: stkResponse.ResponseDescription,
    });
  } catch (error) {
    return errorResponse(
      error instanceof Error ? error.message : "Internal Server Error",
      500,
    );
  }
});
