// supabase/functions/cancel-subscription/index.ts
//
// Cancels the caller's ChowSA Pro entitlement WITHOUT deleting any of their
// data — Blueprints, pantry history, shared-recipe records all remain
// intact and read-only per the POPIA notice surfaced on the Pro screen.
//
// Flow:
//   1. App calls this function with the user's Supabase JWT.
//   2. We resolve auth.uid() and flip profiles.is_pro=false,
//      stamping pro_cancelled_at so the support / accounting team can see
//      when entitlement lapsed.
//   3. PayFast billing: the current checkout integration is one-shot
//      (no `subscription_type=1` token is stored), so there is nothing
//      to cancel on PayFast's side — the user simply won't be charged
//      again. If/when recurring billing is wired up, the stored token
//      should be POSTed to PayFast's /subscriptions/<token>/cancel here.
//
// Deploy with JWT verification ON — only the signed-in user can cancel
// their own subscription:
//   supabase functions deploy cancel-subscription

import { serve } from 'https://deno.land/std@0.208.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL    = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_ANON   = Deno.env.get('SUPABASE_ANON_KEY')!;
const SUPABASE_SR_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

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
    const authHeader = req.headers.get('Authorization') ?? '';
    if (!authHeader.startsWith('Bearer ')) {
      return json({ error: 'unauthenticated' }, 401, req);
    }
    const sb = createClient(SUPABASE_URL, SUPABASE_ANON, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: { user }, error: uerr } = await sb.auth.getUser();
    if (uerr || !user) return json({ error: 'unauthenticated' }, 401, req);

    // Service-role client for the profile update — bypasses RLS so we can
    // flip is_pro deterministically without needing a self-update policy.
    const sbAdmin = createClient(SUPABASE_URL, SUPABASE_SR_KEY);
    const { error: upErr } = await sbAdmin
      .from('profiles')
      .update({
        is_pro:            false,
        pro_cancelled_at:  new Date().toISOString(),
      })
      .eq('id', user.id);

    if (upErr) {
      console.error('[cancel-subscription] profile update failed:', upErr);
      return json({ error: 'db update failed' }, 500, req);
    }

    return json({ cancelled: true }, 200, req);
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
