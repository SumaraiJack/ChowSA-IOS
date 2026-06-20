// supabase/functions/_shared/payfast.ts
//
// Shared PayFast signature engine used by BOTH the checkout-session creator
// (to sign outbound payloads) and the ITN webhook (to validate incoming
// posts). Keeping the algorithm in one place means a future change can't
// drift between sign-out and verify-in.
//
// PayFast signature algorithm — matches the current official PHP SDK
// (payfast/payfast-php-sdk) and their Checkout docs verbatim:
//   1. Iterate fields in INSERTION ORDER (NOT sorted). PayFast's verifier
//      walks $_POST in receive order, so the URL we send must list fields
//      in the same order we sign them. ksort'ing the signing string while
//      sending fields in raw insertion order — or vice versa — produces
//      the "Generated signature does not match" 400 on the sandbox.
//   2. URL-encode each value with PHP's urlencode() semantics: RFC 1738
//      (spaces as `+`, uppercase hex), and the extra characters
//      ! * ' ( ) ~ that encodeURIComponent leaves alone but urlencode does
//      not. Each value is trim()'d before encoding to mirror the PHP SDK.
//   3. Drop empty/null values (PayFast's `if (!empty($val))` guard).
//   4. Concatenate `key=value` pairs with `&`.
//   5. Append `&passphrase=<urlencoded passphrase>` if a passphrase is set.
//   6. MD5 the resulting string, lowercase hex.

import { crypto } from 'https://deno.land/std@0.208.0/crypto/mod.ts';
import { encodeHex } from 'https://deno.land/std@0.208.0/encoding/hex.ts';

/** RFC 1738 percent-encoding, matching PayFast's PHP urlencode() output. */
export function pfEncode(value: string): string {
  return encodeURIComponent(value)
    .replace(/%20/g, '+')
    .replace(/!/g,  '%21')
    .replace(/\*/g, '%2A')
    .replace(/'/g,  '%27')
    .replace(/\(/g, '%28')
    .replace(/\)/g, '%29')
    .replace(/~/g,  '%7E');
}

/**
 * Builds the signing string from a list of [key, value] pairs.
 *
 *   • Trims each value (PayFast's PHP wraps in trim() before urlencode()).
 *   • Drops empty values (their PHP guard: `if (!empty($val))`).
 *   • Sorts the remaining pairs ALPHABETICALLY BY KEY (their ksort step) —
 *     this is the step that was missing and produced the signature
 *     mismatch on the live sandbox checkout.
 *   • Appends `&passphrase=<urlencoded passphrase>` if a passphrase is set.
 *
 * The signing string this returns is the exact input the PHP SDK MD5s.
 */
export function pfSigString(
  pairs: ReadonlyArray<readonly [string, string]>,
  passphrase: string | null,
): string {
  // Insertion order preserved — DO NOT sort. PayFast's PHP SDK reads
  // $_POST in receive order, so our signing string must mirror the URL
  // field order. Trim + drop empties, then concat in given order.
  const cleaned = pairs
    .map(([k, v]) => [k, (v ?? '').toString().trim()] as [string, string])
    .filter(([, v]) => v !== '');
  const parts = cleaned.map(([k, v]) => `${k}=${pfEncode(v)}`);
  if (passphrase && passphrase.length > 0) {
    parts.push(`passphrase=${pfEncode(passphrase.trim())}`);
  }
  return parts.join('&');
}

/** MD5(signing string), lowercase hex. */
export async function pfSignature(
  pairs: ReadonlyArray<readonly [string, string]>,
  passphrase: string | null,
): Promise<string> {
  const sigStr = pfSigString(pairs, passphrase);
  const bytes  = new TextEncoder().encode(sigStr);
  const digest = await crypto.subtle.digest('MD5', bytes);
  return encodeHex(new Uint8Array(digest));
}

/**
 * Verify an ITN payload's signature. Pairs MUST be in the order they
 * appeared in the POST body — pass them in from a parser that preserves
 * insertion order (manual querystring split, NOT URLSearchParams).
 */
export async function pfVerifySignature(
  pairsInReceivedOrder: ReadonlyArray<readonly [string, string]>,
  claimedSignature: string,
  passphrase: string | null,
): Promise<boolean> {
  // Exclude the `signature` field itself from the recomputation.
  const filtered = pairsInReceivedOrder.filter(([k]) => k !== 'signature');
  const expected = await pfSignature(filtered, passphrase);
  // Constant-time compare to be safe even though MD5 is short.
  if (expected.length !== claimedSignature.length) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i++) {
    diff |= expected.charCodeAt(i) ^ claimedSignature.charCodeAt(i);
  }
  return diff === 0;
}

/**
 * Parse an ITN application/x-www-form-urlencoded body PRESERVING field
 * order — required for signature verification. URLSearchParams doesn't
 * guarantee order across runtimes, so we split manually.
 */
export function parseFormUrlEncoded(body: string): Array<[string, string]> {
  return body.split('&').map((kv) => {
    const eq = kv.indexOf('=');
    if (eq < 0) return [decodeURIComponent(kv.replace(/\+/g, ' ')), ''] as [string, string];
    const k = decodeURIComponent(kv.slice(0, eq).replace(/\+/g, ' '));
    const v = decodeURIComponent(kv.slice(eq + 1).replace(/\+/g, ' '));
    return [k, v] as [string, string];
  });
}

/** PayFast's published source-IP whitelist (CIDRless — exact host match). */
export const PAYFAST_SOURCE_HOSTS = [
  'www.payfast.co.za',
  'sandbox.payfast.co.za',
  'w1w.payfast.co.za',
  'w2w.payfast.co.za',
];

/** Base URL switch. PAYFAST_HOST=sandbox.payfast.co.za in dev. */
export function payfastBaseUrl(host: string): string {
  return `https://${host}/eng`;
}
