// supabase/functions/verify_play_purchase/index.ts
//
// Verifies a Google Play Billing subscription purchase against the Play
// Developer API and records the entitlement in public.subscriptions. The
// `trg_subs_after_change` trigger then recomputes profiles.is_pro.
//
// Auth:
//   verify_jwt = TRUE — the user's Supabase JWT identifies who the purchase
//   belongs to. We never trust a user_id sent in the request body.
//
// Request body (JSON):
//   {
//     "package_name":    "com.chowsa.app",
//     "product_id":      "chowsa_pro_monthly",
//     "purchase_token":  "<from Play Billing>"
//   }
//
// Env:
//   GOOGLE_PLAY_SA_JSON       — service account JSON (full file as a string)
//   SUPABASE_URL              — auto
//   SUPABASE_SERVICE_ROLE_KEY — auto
//
// Returns: { ok: boolean, is_pro: boolean, expiry_time: string | null,
//            state: string, error?: string }

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";
import { GoogleAuth } from "https://esm.sh/google-auth-library@9";

const SCOPES = ["https://www.googleapis.com/auth/androidpublisher"];

interface VerifyBody {
  package_name:   string;
  product_id:     string;
  purchase_token: string;
}

// Subset of subscriptionsV2.get response we actually read.
interface SubV2Response {
  subscriptionState?:
    | "SUBSCRIPTION_STATE_ACTIVE"
    | "SUBSCRIPTION_STATE_IN_GRACE_PERIOD"
    | "SUBSCRIPTION_STATE_ON_HOLD"
    | "SUBSCRIPTION_STATE_PAUSED"
    | "SUBSCRIPTION_STATE_CANCELED"
    | "SUBSCRIPTION_STATE_EXPIRED";
  lineItems?: Array<{
    productId?:  string;
    expiryTime?: string;
    autoRenewingPlan?: { autoRenewEnabled?: boolean; recurringPrice?: unknown };
    offerDetails?: { basePlanId?: string; offerId?: string };
  }>;
  startTime?: string;
}

function mapState(s: SubV2Response["subscriptionState"] | undefined): string {
  switch (s) {
    case "SUBSCRIPTION_STATE_ACTIVE":          return "active";
    case "SUBSCRIPTION_STATE_IN_GRACE_PERIOD": return "in_grace_period";
    case "SUBSCRIPTION_STATE_ON_HOLD":         return "on_hold";
    case "SUBSCRIPTION_STATE_PAUSED":          return "paused";
    case "SUBSCRIPTION_STATE_CANCELED":        return "cancelled";
    case "SUBSCRIPTION_STATE_EXPIRED":         return "expired";
    default:                                   return "expired";
  }
}

async function playAccessToken(): Promise<string> {
  const saJson = Deno.env.get("GOOGLE_PLAY_SA_JSON");
  if (!saJson) throw new Error("GOOGLE_PLAY_SA_JSON not set");
  const auth = new GoogleAuth({
    credentials: JSON.parse(saJson),
    scopes:      SCOPES,
  });
  const client = await auth.getClient();
  const t      = await client.getAccessToken();
  return t.token!;
}

Deno.serve(async (req: Request) => {
  try {
    // Resolve the calling user from the JWT in Authorization. We use the
    // anon-keyed client just to decode the JWT — actual writes use service
    // role below.
    const authHeader = req.headers.get("Authorization") ?? "";
    if (!authHeader.startsWith("Bearer ")) {
      return jsonErr(401, "missing bearer token");
    }
    const userClient = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      { global: { headers: { Authorization: authHeader } } },
    );
    const { data: userData, error: userErr } = await userClient.auth.getUser();
    if (userErr || !userData?.user) {
      return jsonErr(401, "invalid session");
    }
    const userId = userData.user.id;

    const body = await req.json() as VerifyBody;
    if (!body.package_name || !body.product_id || !body.purchase_token) {
      return jsonErr(400, "missing package_name / product_id / purchase_token");
    }

    // Call Play Developer API — subscriptionsV2.get is the modern endpoint
    // that covers base plans + offers (the legacy v1 is monetised offers only).
    const accessToken = await playAccessToken();
    const url = `https://androidpublisher.googleapis.com/androidpublisher/v3/applications/${encodeURIComponent(body.package_name)}/purchases/subscriptionsv2/tokens/${encodeURIComponent(body.purchase_token)}`;
    const upstream = await fetch(url, {
      headers: { Authorization: `Bearer ${accessToken}` },
    });
    if (!upstream.ok) {
      const text = await upstream.text();
      return jsonErr(upstream.status, `play api ${upstream.status}: ${text}`);
    }
    const sub = await upstream.json() as SubV2Response;

    // Pull the line item that matches the product. Sub products always have
    // exactly one line item per base-plan/offer combo, but we still match by
    // productId defensively to avoid recording stray data.
    const line = (sub.lineItems ?? []).find(
      (l) => l.productId === body.product_id,
    ) ?? sub.lineItems?.[0];

    const state       = mapState(sub.subscriptionState);
    const expiryTime  = line?.expiryTime ?? null;
    const startTime   = sub.startTime ?? null;
    const autoRenew   = line?.autoRenewingPlan?.autoRenewEnabled ?? false;
    const basePlanId  = line?.offerDetails?.basePlanId ?? null;
    const offerId     = line?.offerDetails?.offerId ?? null;

    // Upsert by purchase_token (unique).
    const sb = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );
    const { error: upErr } = await sb
      .from("subscriptions")
      .upsert({
        user_id:        userId,
        platform:       "play_store",
        product_id:     body.product_id,
        purchase_token: body.purchase_token,
        base_plan_id:   basePlanId,
        offer_id:       offerId,
        start_time:     startTime,
        expiry_time:    expiryTime,
        auto_renewing:  autoRenew,
        state,
        raw:            sub,
        updated_at:     new Date().toISOString(),
      }, { onConflict: "purchase_token" });
    if (upErr) return jsonErr(500, `db upsert: ${upErr.message}`);

    const isPro = state === "active" || state === "in_grace_period";
    return new Response(JSON.stringify({
      ok:          true,
      is_pro:      isPro,
      expiry_time: expiryTime,
      state,
    }), { status: 200, headers: { "content-type": "application/json" } });
  } catch (e) {
    return jsonErr(500, `error: ${e}`);
  }
});

function jsonErr(status: number, message: string): Response {
  return new Response(JSON.stringify({ ok: false, error: message }), {
    status, headers: { "content-type": "application/json" },
  });
}
