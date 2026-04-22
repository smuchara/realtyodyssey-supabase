import { queryStkPushStatus } from "../_shared/daraja.ts";
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
    const { client } = await requireAuthenticatedUser(req);
    const serviceClient = getServiceRoleClient();
    const body = await parseJsonBody(req);
    const checkoutRequestId = typeof body?.checkoutRequestId === "string"
      ? body.checkoutRequestId.trim()
      : "";

    if (!checkoutRequestId) {
      return errorResponse("checkoutRequestId is required", 400);
    }

    const { data, error } = await client
      .schema("app")
      .rpc("get_tenant_mpesa_payment_status", {
        p_checkout_request_id: checkoutRequestId,
      });

    if (error) {
      return errorResponse(error.message, 400);
    }

    const currentStatus = (data as Record<string, unknown> | null) ?? {};

    const shouldRunStatusQuery = currentStatus["status"] === "pending" &&
      currentStatus["is_posted"] != true &&
      currentStatus["callback_received"] != true;

    if (shouldRunStatusQuery) {
      const { data: stkRequestRow, error: stkRequestError } =
        await serviceClient
          .from("mpesa_stk_requests")
          .select(`
          checkout_request_id,
          payment_collection_setup_id,
          payment_collection_setups (
            paybill_number,
            till_number,
            metadata
          )
        `)
          .eq("checkout_request_id", checkoutRequestId)
          .maybeSingle();

      if (!stkRequestError && stkRequestRow != null) {
        const row = stkRequestRow as Record<string, unknown>;
        const setupRaw = row["payment_collection_setups"];
        const setup = setupRaw && typeof setupRaw === "object"
          ? (setupRaw as Record<string, unknown>)
          : null;
        const shortCode = setup?.["paybill_number"]?.toString() ??
          setup?.["till_number"]?.toString();
        const metadataRaw = setup?.["metadata"];
        const metadata = metadataRaw && typeof metadataRaw === "object"
          ? (metadataRaw as Record<string, unknown>)
          : null;
        const passKey = metadata?.["mpesa_passkey"]?.toString() ??
          Deno.env.get("MPESA_PASSKEY");

        if (
          shortCode != null &&
          shortCode.trim().isNotEmpty &&
          passKey != null &&
          passKey.trim().isNotEmpty
        ) {
          try {
            const statusPayload = await queryStkPushStatus({
              shortCode: shortCode.trim(),
              passKey: passKey.trim(),
              checkoutRequestId,
            });
            const statusResultCode =
              typeof statusPayload.ResultCode === "number" ||
                typeof statusPayload.ResultCode === "string"
                ? String(statusPayload.ResultCode)
                : "";

            if (statusResultCode.length > 0) {
              await serviceClient
                .schema("app")
                .rpc("reconcile_mpesa_stk_request_from_status_query", {
                  p_checkout_request_id: checkoutRequestId,
                  p_status_payload: statusPayload,
                });

              const refreshed = await client
                .schema("app")
                .rpc("get_tenant_mpesa_payment_status", {
                  p_checkout_request_id: checkoutRequestId,
                });

              if (!refreshed.error) {
                return jsonResponse(refreshed.data ?? currentStatus);
              }
            }
          } catch (statusQueryError) {
            console.error(
              "STK status query reconciliation failed:",
              statusQueryError,
            );
          }
        }
      }
    }

    return jsonResponse(
      data ?? {
        checkout_request_id: checkoutRequestId,
        status: "pending",
        is_posted: false,
        callback_received: false,
        callback_processed: false,
      },
    );
  } catch (error) {
    return errorResponse(
      error instanceof Error ? error.message : "Internal Server Error",
      500,
    );
  }
});
