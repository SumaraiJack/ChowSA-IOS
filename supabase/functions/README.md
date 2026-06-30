# ChowSA — Supabase Edge Functions (WS6)

Two server-side cron jobs that keep prices and specials current without
spending user-tap AI tokens. Both are **written but not deployed** — see
`Deploy checklist` below.

## Functions

### `specials-refresh` — weekly (Mondays 04:00 UTC)

- Pulls each retailer catalogue listed in `RETAILER_CATALOGUE_URLS` and
  hands it to Gemini Flash to extract the top ~50 specials. **One AI call
  per retailer per week — total weekly AI spend.**
- Ingests free SA price points from Open Food Facts' Open Prices API.
- Tidies expired `specials` rows so the table stays bounded.
- Writes into `specials` (service role; client-side RLS read-only).

### `cpi-drift-baselines` — monthly (1st of month 05:00 UTC)

- Reads `price_baselines`, multiplies each row by `(1 + pct/100)` for its
  category using the `CPI_DRIFT_JSON` secret.
- Zero AI cost. Sanity-clamped to ±25% per tick.

## Deploy checklist

```sh
# One-time
supabase functions deploy specials-refresh --no-verify-jwt
supabase functions deploy cpi-drift-baselines --no-verify-jwt

# Secrets
supabase secrets set \
  GEMINI_API_KEY=<your-gemini-key> \
  RETAILER_CATALOGUE_URLS='pnp|https://...,checkers|https://...' \
  OPEN_PRICES_USER_ID=<dedicated-service-uuid> \
  CPI_DRIFT_JSON='{"dairy":0.4,"bakery":0.6,"pantry":0.3,"produce":0.5,"meat":0.7,"beverages":0.2,"snacks":0.3,"condiments":0.3,"baking":0.4,"household":0.2}'

# Cron
supabase functions schedule create specials-refresh    --cron '0 4 * * 1'
supabase functions schedule create cpi-drift-baselines --cron '0 5 1 * *'
```

The `OPEN_PRICES_USER_ID` should be a real auth user created specifically
for ingest attribution (so the RLS check on `price_points.user_id` passes
without weakening the policy).

## Monthly NAMC/PACSA refresh (human task)

NAMC and PACSA publish monthly PDFs; the user (or an LLM agent) reads
them and updates the affected rows in `price_baselines` directly via the
Supabase MCP / dashboard. **Not weekly** — PLAN explicitly notes the
sources only publish monthly, so weekly re-reads waste tokens.

## Sources (PLAN.md Appendix A)

- NAMC Food Basket monthly report → primary staple price source
- PACSA Food Basket → lower-income end of the price range
- Stats SA CPI food-group inflation → monthly drift
- Open Prices (Open Food Facts) → crowd `price_points`
- Apify retailer scrapers → **parked**. Do not deploy without user OK.
