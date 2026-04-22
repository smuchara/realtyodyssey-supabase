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
  getRequestClient,
  getServiceRoleClient,
  requireAuthenticatedUser,
} from "../_shared/supabase.ts";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return handleOptions();
  if (req.method !== "POST") return methodNotAllowed(req.method);

  try {
    const { user } = await requireAuthenticatedUser(req);
    const userClient = getRequestClient(req);
    const body = await parseJsonBody(req);

    const {
      unitId,
      amount,
      phoneNumber,
      paymentSetupId,
      requestedAdvanceMonths = 1,
      paymentIntent,
    } = body ?? {};

    if (!unitId || !amount) {
      return errorResponse("unitId and amount are required", 400);
    }

    const parsedAmount = Number(amount);
    if (!Number.isFinite(parsedAmount) || parsedAmount <= 0) {
      return errorResponse("amount must be a positive number", 400);
    }

    const months = Math.max(1, Math.min(3, Number(requestedAdvanceMonths) || 1));

    // -----------------------------------------------------------------------
    // 1. Eligibility pre-check (called with user JWT so auth.uid() resolves).
    //    Blocks payment if:
    //      - A pending STK exists for this unit in the last 10 minutes
    //      - Future months are pre-paid and the lock window is still active
    //      - The requested period is already fully paid
    // -----------------------------------------------------------------------
    const { data: eligibility, error: eligibilityError } = await userClient
      .rpc("get_tenant_advance_payment_eligibility", {
        p_unit_id: unitId,
        p_requested_months: months,
        p_user_id: null, // auth.uid() resolves from the user JWT
      });

    if (eligibilityError) {
      console.error("Eligibility check error:", eligibilityError);
      return errorResponse("Could not verify payment eligibility", 500);
    }

    if (!eligibility?.is_eligible) {
      return jsonResponse(
        {
          success: false,
          eligible: false,
          reason_code: eligibility?.reason_code ?? "unknown",
          reason: eligibility?.reason ?? "Payment not allowed at this time",
          lock_until_date: eligibility?.lock_until_date ?? null,
          covered_until_month: eligibility?.covered_until_month ?? null,
        },
        409,
      );
    }

    const serviceClient = getServiceRoleClient();

    // -----------------------------------------------------------------------
    // 2. Resolve payment setup
    // -----------------------------------------------------------------------
    let setup: Record<string, unknown>;
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
        .rpc("get_active_payment_setup_for_tenant", { p_unit_id: unitId });

      if (error || !data) {
        return errorResponse(
          "No active payment setup found for this unit",
          404,
        );
      }
      setup = Array.isArray(data) ? data[0] : data;
    }

    const shortCode = setup.paybill_number ?? setup.till_number ??
      (setup as Record<string, unknown>).paybillNumber ??
      (setup as Record<string, unknown>).tillNumber;
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

    // -----------------------------------------------------------------------
    // 3. Normalize phone number (Daraja expects 2547XXXXXXXX)
    // -----------------------------------------------------------------------
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

    // -----------------------------------------------------------------------
    // 4. Resolve workspace_id + property_id from unit (needed for STK record)
    // -----------------------------------------------------------------------
    const { data: unitData, error: unitError } = await serviceClient
      .from("units")
      .select("id, property_id, properties(workspace_id)")
      .eq("id", unitId)
      .single();

    if (unitError || !unitData) {
      return errorResponse("Unit not found", 404);
    }

    const propertyId = unitData.property_id as string;
    const workspaceId = (unitData.properties as { workspace_id: string })
      ?.workspace_id;

    if (!workspaceId) {
      return errorResponse("Could not resolve workspace for this unit", 500);
    }

    // -----------------------------------------------------------------------
    // 5. Determine payment context from eligibility response
    // -----------------------------------------------------------------------
    const availablePeriods: unknown[] = eligibility.available_periods ?? [];
    const firstPeriod = availablePeriods[0] as
      | Record<string, unknown>
      | undefined;
    const lastPeriod = availablePeriods[availablePeriods.length - 1] as
      | Record<string, unknown>
      | undefined;

    const resolvedIntent = months > 1
      ? "advance_payment"
      : (paymentIntent ?? (firstPeriod ? "current_rent" : "advance_payment"));

    const paymentContext = {
      payment_intent: resolvedIntent,
      requested_advance_months: months,
      eligible_from_month: eligibility.eligible_from_month ?? null,
      target_period_start: firstPeriod?.month_start ?? null,
      target_period_end: lastPeriod?.month_end ?? null,
      available_period_ids: availablePeriods.map(
        (p: unknown) => (p as Record<string, unknown>).rent_charge_period_id,
      ),
    };

    // -----------------------------------------------------------------------
    // 6. Persist the STK request BEFORE firing Daraja.
    //    The unique index uq_mpesa_stk_requests_unit_pending (status=pending)
    //    acts as a final race-condition guard at the DB level.
    // -----------------------------------------------------------------------
    const { data: stkRecord, error: stkInsertError } = await serviceClient
      .from("mpesa_stk_requests")
      .insert({
        workspace_id: workspaceId,
        property_id: propertyId,
        unit_id: unitId,
        payment_collection_setup_id: setup.id,
        amount: parsedAmount,
        phone_number: formattedPhone,
        status: "pending",
        payment_context: paymentContext,
      })
      .select("id")
      .single();

    if (stkInsertError) {
      // Unique constraint violation = concurrent pending request
      if (stkInsertError.code === "23505") {
        return jsonResponse(
          {
            success: false,
            eligible: false,
            reason_code: "payment_in_progress",
            reason:
              "A payment for this unit is already being processed. Please wait.",
            lock_until_date: null,
            covered_until_month: null,
          },
          409,
        );
      }
      console.error("Failed to create STK request record:", stkInsertError);
      return errorResponse("Failed to initiate payment session", 500);
    }

    const stkRequestId = stkRecord.id as string;

    // -----------------------------------------------------------------------
    // 7. Fire the STK push prompt via Daraja
    // -----------------------------------------------------------------------
    let stkResponse: Record<string, unknown>;
    try {
      stkResponse = await initiateStkPush({
        shortCode,
        passKey,
        amount: parsedAmount,
        phoneNumber: formattedPhone,
        accountReference: (setup.account_reference_hint as string) ||
          (setup.account_reference as string) || "Rent",
        transactionDesc: `Rent Payment - ${unitId}`,
        callbackUrl: buildSupabaseFunctionUrl("daraja-c2b-confirmation"),
      });
    } catch (stkError) {
      // STK push failed — mark the pre-created record as failed so the
      // unit's pending lock is released and the tenant can retry.
      await serviceClient
        .from("mpesa_stk_requests")
        .update({
          status: "failed",
          result_desc: stkError instanceof Error
            ? stkError.message
            : "STK push initiation failed",
        })
        .eq("id", stkRequestId);

      return errorResponse(
        stkError instanceof Error ? stkError.message : "M-Pesa request failed",
        502,
      );
    }

    // -----------------------------------------------------------------------
    // 8. Attach the CheckoutRequestID from Daraja to the persisted record
    // -----------------------------------------------------------------------
    await serviceClient
      .from("mpesa_stk_requests")
      .update({
        checkout_request_id: stkResponse.CheckoutRequestID as string,
        merchant_request_id: stkResponse.MerchantRequestID as string,
      })
      .eq("id", stkRequestId);

    return jsonResponse({
      success: true,
      checkoutRequestId: stkResponse.CheckoutRequestID,
      stkRequestId,
      customerMessage: stkResponse.CustomerMessage,
      responseDescription: stkResponse.ResponseDescription,
      eligibility: {
        eligible_from_month: eligibility.eligible_from_month,
        months_available: eligibility.months_available,
        covered_until_month: eligibility.covered_until_month,
      },
    });
  } catch (error) {
    return errorResponse(
      error instanceof Error ? error.message : "Internal Server Error",
      500,
    );
  }
});
