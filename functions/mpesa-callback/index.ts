import { jsonResponse } from "../_shared/http.ts";
import { getServiceRoleClient } from "../_shared/supabase.ts";

Deno.serve(async (req: Request) => {
  // Daraja callbacks are POST
  if (req.method !== "POST") {
    return new Response("Method Not Allowed", { status: 405 });
  }

  try {
    const payload = await req.json();
    const stkCallback = payload?.Body?.stkCallback ?? null;
    const checkoutRequestId =
      typeof stkCallback?.CheckoutRequestID === "string"
        ? stkCallback.CheckoutRequestID
        : null;
    const resultCode =
      typeof stkCallback?.ResultCode === "string" ||
        typeof stkCallback?.ResultCode === "number"
        ? String(stkCallback.ResultCode)
        : null;
    const resultDesc =
      typeof stkCallback?.ResultDesc === "string"
        ? stkCallback.ResultDesc
        : null;

    console.log(
      "M-Pesa STK Callback Received:",
      JSON.stringify(payload, null, 2),
    );

    const serviceClient = getServiceRoleClient();
    let callbackEventId: string | null = null;

    if (checkoutRequestId) {
      const { data: callbackEvent, error: callbackEventError } =
        await serviceClient
          .from("mpesa_stk_callback_events")
          .insert({
            checkout_request_id: checkoutRequestId,
            result_code: resultCode,
            result_desc: resultDesc,
            payload,
          })
          .select("id")
          .single();

      if (callbackEventError) {
        console.error("Error saving STK callback event:", callbackEventError);
      } else {
        callbackEventId = callbackEvent?.id ?? null;
      }
    }

    const { data, error } = callbackEventId
      ? await serviceClient
          .schema("app")
          .rpc("process_mpesa_stk_callback_event", {
            p_event_id: callbackEventId,
          })
      : await serviceClient
          .schema("app")
          .rpc("record_mpesa_stk_callback", { p_payload: payload });

    if (error) {
      console.error("Error processing M-Pesa callback:", error);

      if (callbackEventId) {
        await serviceClient
          .from("mpesa_stk_callback_events")
          .update({
            processing_status: "failed",
            processing_error: error.message,
            processed_at: new Date().toISOString(),
          })
          .eq("id", callbackEventId);
      }

      if (checkoutRequestId) {
        await serviceClient
          .from("mpesa_stk_requests")
          .update({
            result_code: resultCode,
            result_desc:
              `Callback received but processing failed: ${error.message}`,
            raw_callback_payload: payload,
            updated_at: new Date().toISOString(),
          })
          .eq("checkout_request_id", checkoutRequestId);
      }

      // We still return 200 to Safaricom to stop retries,
      // but we log the error for internal debugging.
      return jsonResponse({
        ResultCode: 0,
        ResultDesc: "Accepted with processing error",
      });
    }

    console.log("M-Pesa callback processed successfully:", data);

    // Daraja expects a specific response format
    return jsonResponse({
      ResultCode: 0,
      ResultDesc: "Success",
    });
  } catch (error) {
    console.error("M-Pesa Callback Critical Failure:", error);

    // Always return 200 to Safaricom unless you want them to retry (which is risky if partially processed)
    return jsonResponse({
      ResultCode: 0,
      ResultDesc: "Accepted with critical error",
    });
  }
});
