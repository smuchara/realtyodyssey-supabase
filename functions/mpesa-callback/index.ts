// @ts-nocheck: Deno globals not recognized in some IDE environments
import {
  jsonResponse,
} from "../_shared/http.ts";
import {
  getServiceRoleClient,
} from "../_shared/supabase.ts";

Deno.serve(async (req: Request) => {
  // Daraja callbacks are POST
  if (req.method !== "POST") {
    return new Response("Method Not Allowed", { status: 405 });
  }

  try {
    const payload = await req.json();
    console.log("M-Pesa STK Callback Received:", JSON.stringify(payload, null, 2));

    const serviceClient = getServiceRoleClient();

    // 1. Record the callback via RPC
    // This RPC handles:
    // - Deduplication (using CheckoutRequestID)
    // - Updating stk_requests table
    // - Creating payment record + allocation on success
    // - Refreshing invoice state
    const { data, error } = await serviceClient
      .schema("app")
      .rpc("record_mpesa_stk_callback", { p_payload: payload });

    if (error) {
      console.error("Error processing M-Pesa callback:", error);
      // We still return 200 to Safaricom to stop retries, 
      // but we log the error for internal debugging.
      return jsonResponse({ ResultCode: 0, ResultDesc: "Accepted with processing error" });
    }

    console.log("M-Pesa callback processed successfully:", data);

    // Daraja expects a specific response format
    return jsonResponse({
      ResultCode: 0,
      ResultDesc: "Success"
    });

  } catch (error) {
    console.error("M-Pesa Callback Critical Failure:", error);
    // Always return 200 to Safaricom unless you want them to retry (which is risky if partially processed)
    return jsonResponse({ ResultCode: 0, ResultDesc: "Accepted with critical error" });
  }
});
