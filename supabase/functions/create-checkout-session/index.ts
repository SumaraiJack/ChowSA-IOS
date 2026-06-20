// supabase/functions/create-checkout-session/index.ts
//
// Mints a PayFast checkout URL for the calling user. Flow:
//   1. App calls this function with the user's Supabase JWT (handled
//      automatically by the supabase-js client).
//   2. Function reads auth.uid() + email, builds the PayFast field set,
//      MD5-signs it with the passphrase, and returns the redirect URL.
//   3. App opens that URL in an in-app browser (see PayFastService.dart).
//   4. PayFast pings the webhook server-to-server with the ITN.
//
// Secrets required (set via `supabase secrets set`):
//   PAYFAST_MERCHANT_ID
//   PAYFAST_MERCHANT_KEY
//   PAYFAST_PASSPHRASE
//   PAYFAST_HOST          e.g. 'sandbox.payfast.co.za' or 'www.payfast.co.za'
//   PAYFAST_NOTIFY_URL    full https URL of the payfast-webhook function
//   PAYFAST_RETURN_URL    deep-link the user lands on after paying
//   PAYFAST_CANCEL_URL    deep-link for cancel
//
// Deploy with JWT verification ON (the default) — only signed-in users
// should be able to start a checkout:
//   supabase functions deploy create-checkout-session

import { serve } from 'https://deno.land/std@0.208.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { pfSigString, pfSignature, payfastBaseUrl } from '../_shared/payfast.ts';

const PF_MERCHANT_ID  = Deno.env.get('PAYFAST_MERCHANT_ID')!;
const PF_MERCHANT_KEY = Deno.env.get('PAYFAST_MERCHANT_KEY')!;
const PF_PASSPHRASE   = Deno.env.get('PAYFAST_PASSPHRASE')!;
const PF_HOST         = Deno.env.get('PAYFAST_HOST')!;
const PF_NOTIFY_URL   = Deno.env.get('PAYFAST_NOTIFY_URL')!;
// PayFast rejects non-http(s) schemes (e.g. chowsa:// deep links) with a
// 400 "url format is invalid" error. The app returns to foreground via the
// AppLifecycle resume hook + refreshEntitlement, so an https landing page
// is sufficient — user just closes the browser tab.
const HTTPS_RX = /^https?:\/\//i;
function ensureHttps(envValue: string | undefined, fallback: string): string {
  const v = (envValue ?? '').trim();
  return HTTPS_RX.test(v) ? v : fallback;
}
const PF_RETURN_URL   = ensureHttps(Deno.env.get('PAYFAST_RETURN_URL'),  'https://chowsa.co.za/pro/success');
const PF_CANCEL_URL   = ensureHttps(Deno.env.get('PAYFAST_CANCEL_URL'),  'https://chowsa.co.za/pro/cancel');
const SUPABASE_URL    = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_ANON   = Deno.env.get('SUPABASE_ANON_KEY')!;

// Single ChowSA Pro SKU for now. When we add annual / family tiers, switch
// to a `priceTier` request param + a server-side lookup table.
const PRICE_ZAR      = '49.00';
const ITEM_NAME      = 'ChowSA Pro';
const ITEM_DESC      = 'Unlimited AI recipe generations + ad-free experience';

function corsHeaders(req: Request): Record<string, string> {
  return {
    'Access-Control-Allow-Origin':  req.headers.get('origin') ?? '*',
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
  };
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders(req) });
  }
  try {
    // ── Identify the caller via their Supabase JWT ────────────────────
    const authHeader = req.headers.get('Authorization') ?? '';
    if (!authHeader.startsWith('Bearer ')) {
      return json({ error: 'unauthenticated' }, 401, req);
    }
    const sb = createClient(SUPABASE_URL, SUPABASE_ANON, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: { user }, error: uerr } = await sb.auth.getUser();
    if (uerr || !user) return json({ error: 'unauthenticated' }, 401, req);

    // m_payment_id is OUR id — used as idempotency key on the webhook. The
    // user's UID is too sensitive to expose in PayFast's dashboard, so we
    // use a fresh uuid here AND stash the uid in custom_str1, which PayFast
    // bounces back in the ITN.
    const ourPaymentId = crypto.randomUUID();

    // Build the raw field set. Empty / null values are kept here only
    // briefly so the per-key reasoning below stays readable — they are
    // stripped before signing AND before URL construction so the request
    // and the signature operate on the SAME set of fields.
    const raw: Array<[string, string]> = [
      ['merchant_id',   PF_MERCHANT_ID],
      ['merchant_key',  PF_MERCHANT_KEY],
      ['return_url',    PF_RETURN_URL],
      ['cancel_url',    PF_CANCEL_URL],
      ['notify_url',    PF_NOTIFY_URL],
      ['name_first',    (user.user_metadata?.handle as string) ?? 'ChowSA'],
      ['email_address', user.email ?? ''],
      ['m_payment_id',  ourPaymentId],
      ['amount',        PRICE_ZAR],
      ['item_name',     ITEM_NAME],
      ['item_description', ITEM_DESC],
      ['custom_str1',   user.id], // Supabase auth.uid bounce-back
    ];

    // Strip blanks ONCE so signing-string and URL stay in lock-step.
    const pairs = raw
      .map(([k, v]) => [k, (v ?? '').toString().trim()] as [string, string])
      .filter(([, v]) => v !== '');

    // ── DIAGNOSTIC LOGGING ──────────────────────────────────────────
    // Per spec: log the EXACT pre-hash string so PayFast's "signature
    // does not match" complaint can be compared byte-for-byte against
    // what their PHP SDK would compute on the same fields. Passphrase
    // is redacted because it's a secret; everything else is harmless.
    const sigString = pfSigString(pairs, PF_PASSPHRASE);
    const sigStringRedacted = PF_PASSPHRASE
      ? sigString.replace(
          new RegExp(`passphrase=[^&]+`),
          'passphrase=<REDACTED>',
        )
      : sigString;
    console.log('[create-checkout-session] fields used for signing (insertion order):');
    pairs.forEach(([k, v]) => console.log(`  ${k}=${v}`));
    console.log('[create-checkout-session] pre-hash string:', sigStringRedacted);

    const signature = await pfSignature(pairs, PF_PASSPHRASE);
    console.log('[create-checkout-session] computed signature:', signature);
    pairs.push(['signature', signature]);

    // Build the GET-redirect URL from the SAME `pairs` list — guarantees
    // PayFast verifies on the exact field set we signed.
    const url = new URL(`${payfastBaseUrl(PF_HOST)}/process`);
    for (const [k, v] of pairs) url.searchParams.append(k, v);

    return json({
      checkout_url: url.toString(),
      payment_id:   ourPaymentId,
    }, 200, req);
  } catch (e) {
    return json({ error: `${e}` }, 500, req);
  }
});

function json(body: unknown, status: number, req: Request): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...corsHeaders(req) },
  });
}
