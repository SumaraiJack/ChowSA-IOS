// supabase/functions/specials-refresh/index.ts
//
// WS6 weekly cron — refreshes the `specials` overlay and ingests new SA
// crowd prices from Open Prices.
//
// Cost shape (per PLAN.md §WS6):
//   • One cheap AI call PER RETAILER PER WEEK to extract ~50 top deals
//     from each catalogue source (Gemini Flash, JSON output).
//   • One free Open Prices fetch per week (no AI).
//   • Per-user "Estimate basket" taps stay free via the WS1 price_cache.
//
// Deploy + schedule:
//   supabase functions deploy specials-refresh --no-verify-jwt
//   supabase functions schedule create specials-refresh \
//     --cron '0 4 * * 1'   # Mondays 04:00 UTC
//
// Required secrets:
//   supabase secrets set \
//     GEMINI_API_KEY=...                          \
//     RETAILER_CATALOGUE_URLS='pnp|https://...,checkers|https://...'
//
// RETAILER_CATALOGUE_URLS format: comma-separated `store|url` pairs. The
// function fetches each URL as text, hands it to Gemini, and inserts the
// extracted deals. Missing or empty → that retailer is skipped this week.

import { createClient } from 'jsr:@supabase/supabase-js@2';

// ── Types ────────────────────────────────────────────────────────────────
interface ExtractedDeal {
  item_name:  string;
  store:      string;
  price_zar:  number;
  valid_from: string; // YYYY-MM-DD
  valid_to:   string; // YYYY-MM-DD
}

// ── Helpers ──────────────────────────────────────────────────────────────
const normalize = (raw: string): string =>
  raw.toLowerCase()
     .replace(/[^a-z0-9\s]/g, ' ')
     .replace(/\s+/g, ' ')
     .trim();

const isoDate = (d: Date): string => d.toISOString().slice(0, 10);

const today    = (): string => isoDate(new Date());
const nextWeek = (): string => {
  const d = new Date();
  d.setUTCDate(d.getUTCDate() + 7);
  return isoDate(d);
};

// ── Gemini extraction ────────────────────────────────────────────────────
async function extractDealsFromCatalogue(
  store: string,
  catalogueText: string,
  apiKey: string,
): Promise<ExtractedDeal[]> {
  const prompt = `Extract the top 50 grocery specials from this South African
retailer (${store}) catalogue text. Return STRICT JSON array of objects with
shape {"item_name": string, "price_zar": number}. Skip non-grocery items,
non-numeric prices, and items where you can't pin a clear ZAR price.

Catalogue text:
${catalogueText.slice(0, 60_000)}`;

  const res = await fetch(
    `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-lite:generateContent?key=${apiKey}`,
    {
      method:  'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        contents: [{ role: 'user', parts: [{ text: prompt }] }],
        generationConfig: {
          responseMimeType: 'application/json',
          temperature:      0.1,
        },
      }),
    },
  );

  if (!res.ok) {
    console.error(`Gemini failed for ${store}: ${res.status}`);
    return [];
  }
  const data = await res.json();
  const text = data.candidates?.[0]?.content?.parts?.[0]?.text ?? '';
  let parsed: Array<{ item_name?: string; price_zar?: number }> = [];
  try {
    parsed = JSON.parse(text);
    if (!Array.isArray(parsed)) parsed = [];
  } catch {
    return [];
  }

  const valid_from = today();
  const valid_to   = nextWeek();
  return parsed
    .filter((d) => typeof d.item_name === 'string'
                && typeof d.price_zar === 'number'
                && d.price_zar > 0 && d.price_zar < 5000)
    .slice(0, 50)
    .map((d) => ({
      item_name: d.item_name!.trim(),
      store,
      price_zar: Number(d.price_zar!.toFixed(2)),
      valid_from,
      valid_to,
    }));
}

// ── Open Prices ingest ───────────────────────────────────────────────────
// Reads the public Open Prices SA slice and upserts into price_points.
// API docs: https://prices.openfoodfacts.org/api/docs
async function ingestOpenPricesSA(
  supabase: ReturnType<typeof createClient>,
): Promise<number> {
  try {
    const res = await fetch(
      'https://prices.openfoodfacts.org/api/v1/prices?location_country_code=ZA&size=50',
    );
    if (!res.ok) return 0;
    const data = await res.json();
    const items = (data.items ?? []) as Array<{
      product_name?: string;
      price?:       number;
      currency?:    string;
      location_osm_name?: string;
    }>;
    let n = 0;
    for (const it of items) {
      if (!it.product_name || !it.price || it.currency !== 'ZAR') continue;
      const norm = normalize(it.product_name);
      if (!norm) continue;
      // Open-Prices rows attribute to the system service-role inserter.
      // RLS on price_points requires a real user_id; we tag with a known
      // sentinel UUID — keep it consistent across runs via env var.
      const systemUserId = Deno.env.get('OPEN_PRICES_USER_ID');
      if (!systemUserId) continue;
      const { error } = await supabase.from('price_points').insert({
        raw_name:        it.product_name,
        normalized_name: norm,
        price_zar:       Number(it.price.toFixed(2)),
        store:           it.location_osm_name ?? null,
        user_id:         systemUserId,
      });
      if (!error) n++;
    }
    return n;
  } catch (e) {
    console.error('OpenPrices ingest failed:', e);
    return 0;
  }
}

// ── Entry ────────────────────────────────────────────────────────────────
Deno.serve(async () => {
  const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
  const serviceKey  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const geminiKey   = Deno.env.get('GEMINI_API_KEY') ?? '';
  const retailers   = (Deno.env.get('RETAILER_CATALOGUE_URLS') ?? '')
    .split(',')
    .map((p) => p.trim())
    .filter(Boolean)
    .map((p) => {
      const [store, url] = p.split('|').map((s) => s.trim());
      return { store, url };
    })
    .filter((r) => r.store && r.url);

  const supabase = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false },
  });

  let dealsInserted = 0;
  if (geminiKey && retailers.length > 0) {
    for (const r of retailers) {
      try {
        const catalogueRes = await fetch(r.url);
        if (!catalogueRes.ok) continue;
        const text  = await catalogueRes.text();
        const deals = await extractDealsFromCatalogue(r.store, text, geminiKey);
        if (deals.length === 0) continue;
        const rows = deals.map((d) => ({
          item_name:       d.item_name,
          normalized_name: normalize(d.item_name),
          store:           d.store,
          price_zar:       d.price_zar,
          valid_from:      d.valid_from,
          valid_to:        d.valid_to,
          source:          `ai:${r.store}`,
        }));
        const { error } = await supabase.from('specials').insert(rows);
        if (!error) dealsInserted += rows.length;
      } catch (e) {
        console.error(`Retailer ${r.store} failed:`, e);
      }
    }
  }

  const opIngested = await ingestOpenPricesSA(supabase);

  // Tidy expired rows so the table stays bounded.
  await supabase.from('specials').delete().lt('valid_to', today());

  return new Response(
    JSON.stringify({
      ok:              true,
      retailers:       retailers.length,
      deals_inserted:  dealsInserted,
      open_prices_ingested: opIngested,
    }),
    { headers: { 'Content-Type': 'application/json' } },
  );
});
