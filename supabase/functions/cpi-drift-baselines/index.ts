// supabase/functions/cpi-drift-baselines/index.ts
//
// WS6 monthly cron — applies Stats SA CPI food-group % drift to
// price_baselines so prices stay current automatically between manual
// NAMC/PACSA refreshes.
//
// Cost: zero AI calls. Just a multiplier + upsert.
//
// Deploy + schedule:
//   supabase functions deploy cpi-drift-baselines --no-verify-jwt
//   supabase functions schedule create cpi-drift-baselines \
//     --cron '0 5 1 * *'   # 1st of month 05:00 UTC
//
// Required secrets:
//   supabase secrets set CPI_DRIFT_JSON='{"dairy":0.4,"bakery":0.6,...}'
//
// CPI_DRIFT_JSON shape: object keyed by `price_baselines.category` whose
// value is the % change to apply this month (e.g. 0.5 means +0.5%).
// Missing categories are left untouched. Negative deltas are allowed.

import { createClient } from 'jsr:@supabase/supabase-js@2';

interface BaselineRow {
  keyword:       string;
  category:      string | null;
  avg_price_zar: number;
}

Deno.serve(async () => {
  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    { auth: { persistSession: false } },
  );

  let drift: Record<string, number> = {};
  try {
    drift = JSON.parse(Deno.env.get('CPI_DRIFT_JSON') ?? '{}');
  } catch {
    return new Response(
      JSON.stringify({ ok: false, error: 'CPI_DRIFT_JSON not valid JSON' }),
      { status: 400, headers: { 'Content-Type': 'application/json' } },
    );
  }
  if (Object.keys(drift).length === 0) {
    return new Response(
      JSON.stringify({ ok: true, applied: 0, reason: 'no drift configured' }),
      { headers: { 'Content-Type': 'application/json' } },
    );
  }

  const { data: rows, error } = await supabase
    .from('price_baselines')
    .select('keyword, category, avg_price_zar');
  if (error) {
    return new Response(
      JSON.stringify({ ok: false, error: error.message }),
      { status: 500, headers: { 'Content-Type': 'application/json' } },
    );
  }

  let applied = 0;
  for (const row of (rows ?? []) as BaselineRow[]) {
    const cat = row.category;
    if (!cat || !(cat in drift)) continue;
    const pct = drift[cat];
    if (!Number.isFinite(pct) || pct === 0) continue;
    const next = Number((row.avg_price_zar * (1 + pct / 100)).toFixed(2));
    // Sanity guard: never drift more than ±25% in a single tick.
    if (next <= 0 || next > row.avg_price_zar * 1.25 || next < row.avg_price_zar * 0.75) continue;
    const { error: upErr } = await supabase
      .from('price_baselines')
      .update({ avg_price_zar: next, updated_at: new Date().toISOString() })
      .eq('keyword', row.keyword);
    if (!upErr) applied++;
  }

  return new Response(
    JSON.stringify({ ok: true, applied }),
    { headers: { 'Content-Type': 'application/json' } },
  );
});
