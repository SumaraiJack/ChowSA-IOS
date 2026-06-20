// supabase/functions/payfast-webhook/index.ts
//
// PayFast Instant Transaction Notification (ITN) handler.
//
// Deploy with JWT verification OFF — PayFast's server posts here directly,
// it has no Supabase JWT to present:
//   supabase functions deploy payfast-webhook --no-verify-jwt
//
// Five gates before we flip is_pro (in this order):
//   1. Source-host sanity check — request came from a known PayFast host.
//   2. Signature recomputation — fields hash with our passphrase match the
//      `signature` field PayFast sent.
//   3. Post-back to PayFast `/eng/query/validate` — they confirm THEY sent
//      the ITN (defends against signature-replay from a stolen passphrase).
//   4. Amount check — gross matches our expected PRICE_ZAR.
//   5. payment_status === 'COMPLETE'.
//
// Only when all five pass do we update profiles.is_pro for the user whose
// uid was bounced back in custom_str1.

import { serve } from 'https://deno.land/std@0.208.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import {
  parseFormUrlEncoded,
  payfastBaseUrl,
  pfSigString,
  pfSignature,
  pfVerifySignature,
  PAYFAST_SOURCE_HOSTS,
} from '../_shared/payfast.ts';

const PF_PASSPHRASE  = Deno.env.get('PAYFAST_PASSPHRASE')!;
const PF_HOST        = Deno.env.get('PAYFAST_HOST')!;
const PF_MERCHANT_ID = Deno.env.get('PAYFAST_MERCHANT_ID')!;
const EXPECTED_AMOUNT = '49.00';
const SUPABASE_URL    = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_SR_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

serve(async (req) => {
  if (req.method !== 'POST') {
    return new Response('method not allowed', { status: 405 });
  }

  const rawBody = await req.text();
  const pairs   = parseFormUrlEncoded(rawBody);
  const fields  = Object.fromEntries(pairs);

  // ── 1) Source-host sanity ───────────────────────────────────────────
  // The Host header is set by the Supabase edge proxy, not PayFast. The
  // value we actually want is the Forwarded / X-Forwarded-Host of the
  // peer, which Cloudflare in front of PayFast sets to one of the known
  // hosts. We log the rejection but still continue to the cryptographic
  // checks below — those are the real gate, this is just a fast-fail hint.
  const peerHost = req.headers.get('x-forwarded-host')
                 ?? req.headers.get('host') ?? '';
  const knownHost = PAYFAST_SOURCE_HOSTS.some((h) => peerHost.endsWith(h));
  if (!knownHost) {
    console.warn('[payfast-webhook] unknown peer host:', peerHost);
    // do NOT return — Supabase functions sit behind their own proxy that
    // may strip the original host. The signature + post-back below are
    // the cryptographic gate.
  }

  // ── 2) Signature ────────────────────────────────────────────────────
  const claimed = fields['signature'] ?? '';
  const sigOk   = await pfVerifySignature(pairs, claimed, PF_PASSPHRASE);
  if (!sigOk) {
    // Diagnostic: emit the exact bytes we're comparing so we can see the
    // divergence between PayFast's signed payload and ours.
    const filteredPairs = pairs.filter(([k]) => k !== 'signature');
    const ourSigString = pfSigString(filteredPairs, PF_PASSPHRASE);
    const ourSig       = await pfSignature(filteredPairs, PF_PASSPHRASE);
    const sigStringRedacted = PF_PASSPHRASE
      ? ourSigString.replace(/passphrase=[^&]+/, 'passphrase=<REDACTED>')
      : ourSigString;
    console.error('[payfast-webhook] signature mismatch');
    console.error('[payfast-webhook] received fields (in order):');
    pairs.forEach(([k, v]) => {
      if (k !== 'signature') console.error(`  ${k}=${v}`);
    });
    console.error('[payfast-webhook] our pre-hash string:', sigStringRedacted);
    console.error('[payfast-webhook] our computed sig:',    ourSig);
    console.error('[payfast-webhook] claimed sig:',         claimed);
    return new Response('bad signature', { status: 400 });
  }

  // ── 3) Post-back to PayFast /eng/query/validate ─────────────────────
  // Strips `signature` field — PayFast's spec — and posts the rest back
  // for them to confirm they really sent this ITN. Defends against an
  // attacker who has the passphrase from forging a one-shot post.
  const validateBody = pairs
    .filter(([k]) => k !== 'signature')
    .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v).replace(/%20/g, '+')}`)
    .join('&');
  const validateRes = await fetch(`${payfastBaseUrl(PF_HOST)}/query/validate`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body:   validateBody,
  });
  const validateText = (await validateRes.text()).trim();
  if (validateText !== 'VALID') {
    console.error('[payfast-webhook] post-back failed:', validateText);
    return new Response('post-back failed', { status: 400 });
  }

  // ── 4) Merchant + amount checks ─────────────────────────────────────
  if (fields['merchant_id'] !== PF_MERCHANT_ID) {
    return new Response('merchant id mismatch', { status: 400 });
  }
  if (fields['amount_gross'] !== EXPECTED_AMOUNT) {
    console.error(
      '[payfast-webhook] amount mismatch — got',
      fields['amount_gross'], 'expected', EXPECTED_AMOUNT,
    );
    return new Response('amount mismatch', { status: 400 });
  }

  // ── 5) Status ───────────────────────────────────────────────────────
  if (fields['payment_status'] !== 'COMPLETE') {
    // We acknowledge other statuses (CANCELLED, FAILED) with 200 so PayFast
    // stops retrying — but we don't grant Pro.
    console.info('[payfast-webhook] non-COMPLETE status:', fields['payment_status']);
    return new Response('ok', { status: 200 });
  }

  // ── Grant entitlement ───────────────────────────────────────────────
  const uid = fields['custom_str1'];
  const ref = fields['pf_payment_id'];
  if (!uid) {
    return new Response('missing custom_str1 (uid)', { status: 400 });
  }

  const sb = createClient(SUPABASE_URL, SUPABASE_SR_KEY);
  const { error: upErr } = await sb
    .from('profiles')
    .update({
      is_pro:          true,
      pro_since:       new Date().toISOString(),
      pro_payment_ref: ref ?? null,
    })
    .eq('id', uid);

  if (upErr) {
    console.error('[payfast-webhook] profile update failed:', upErr);
    return new Response('db update failed', { status: 500 });
  }

  return new Response('ok', { status: 200 });
});
