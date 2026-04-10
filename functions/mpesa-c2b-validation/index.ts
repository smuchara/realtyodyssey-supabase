import {
  handleOptions,
  jsonResponse,
  methodNotAllowed,
  parseJsonBody,
} from "../_shared/http.ts";
import { getServiceRoleClient } from "../_shared/supabase.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return handleOptions();
  if (req.method !== "POST") return methodNotAllowed(req.method);

  try {
    const payload = await parseJsonBody(req);
    const serviceClient = getServiceRoleClient();

    const { data, error } = await serviceClient.rpc(
      "record_mpesa_c2b_callback",
      {
        p_event_type: "c2b_validation",
        p_payload: payload,
      },
    );

    if (error) {
      return jsonResponse(
        {
          ResultCode: 1,
          ResultDesc: "Could not validate the M-Pesa payment request",
        },
        { status: 200 },
      );
    }

    const matchedSetupId = data?.payment_collection_setup_id ?? null;
    if (!matchedSetupId) {
      return jsonResponse(
        {
          ResultCode: 1,
          ResultDesc: "Unknown or inactive payment destination",
        },
        { status: 200 },
      );
    }

    return jsonResponse(
      {
        ResultCode: 0,
        ResultDesc: "Accepted",
      },
      { status: 200 },
    );
  } catch (error) {
    return jsonResponse(
      {
        ResultCode: 1,
        ResultDesc: error instanceof Error ? error.message : "Unexpected error",
      },
      { status: 200 },
    );
  }
});
