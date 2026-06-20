-- =============================================================================
-- Migration: wc_matches_clean_seed
-- =============================================================================
--
-- The earlier seed (20260603_wc_matches_seed.sql) only deleted rows inside
-- a narrow opening-fixture window before its UPSERT, so the stale mock
-- fixtures sitting OUTSIDE that window (South Africa vs Morocco, Brazil vs
-- Argentina, Spain vs Germany, …) survived every previous re-seed. This
-- migration wipes the table unconditionally and re-inserts ONLY the four
-- confirmed opening fixtures.
--
-- Safe to re-run: the table is repopulated from scratch each time.
--
-- Time-zone policy (see also 20260603_wc_matches_seed.sql header):
--   • match_time is the absolute UTC instant.
--   • kickoff_local is the venue-local human label the dashboard should
--     display verbatim, so a SAST viewer doesn't see Mexico's 19:00 render
--     as the next morning.
-- =============================================================================

BEGIN;

-- ── 1. Wipe ALL existing match rows ──────────────────────────────────────────
-- Plain DELETE (not TRUNCATE) so the unique-index + trigger machinery
-- introduced in earlier migrations keeps its state, and any FKs pointing
-- at wc_matches (currently none from app tables, but defensive) get the
-- ordinary cascade path. `id IS NOT NULL` matches every row.
DELETE FROM public.wc_matches WHERE id IS NOT NULL;

-- ── 2. Insert ONLY the four confirmed opening fixtures ───────────────────────
-- Time-zone derivations:
--   Match 1: 19:00 CDT (UTC-6) on 11 Jun 2026 → 01:00 UTC on 12 Jun 2026.
--            Spec'd kick-off, CONFIRMED.
--   Match 2: 12 Jun 2026 per spec. Placeholder kickoff 18:00 CDT (UTC-6)
--            → 00:00 UTC on 13 Jun. Flagged TBC in kickoff_local.
--   Match 3: 12 Jun 2026 per spec. Placeholder kickoff 16:00 EDT (UTC-4)
--            → 20:00 UTC on 12 Jun. Flagged TBC in kickoff_local.
--   Match 4: 13 Jun 2026 per spec. Placeholder kickoff 19:00 PDT (UTC-7)
--            → 02:00 UTC on 14 Jun. Flagged TBC in kickoff_local.
INSERT INTO public.wc_matches
  (team_a, team_b, team_a_flag, team_b_flag,
   match_time, stage, status, is_bafana_match,
   venue, kickoff_local, group_code, round_code)
VALUES
  -- Match 1 (Group A): Mexico vs South Africa — Estadio Azteca
  ('Mexico', 'South Africa', '🇲🇽', '🇿🇦',
   '2026-06-12 01:00:00+00', 'Group Stage', 'scheduled', true,
   'Estadio Azteca, Mexico City',
   'Thu 11 Jun · 19:00 (Mexico City)',
   'A', 'GROUP'),

  -- Match 2 (Group A): Korea Republic vs Czechia — Estadio Akron, Guadalajara
  ('Korea Republic', 'Czechia', '🇰🇷', '🇨🇿',
   '2026-06-13 00:00:00+00', 'Group Stage', 'scheduled', false,
   'Estadio Akron, Guadalajara',
   'Fri 12 Jun · 18:00 (Guadalajara) — TBC',
   'A', 'GROUP'),

  -- Match 3 (Group B): Canada vs Bosnia and Herzegovina — BMO Field, Toronto
  ('Canada', 'Bosnia and Herzegovina', '🇨🇦', '🇧🇦',
   '2026-06-12 20:00:00+00', 'Group Stage', 'scheduled', false,
   'BMO Field, Toronto',
   'Fri 12 Jun · 16:00 (Toronto) — TBC',
   'B', 'GROUP'),

  -- Match 4 (Group D): USA vs Paraguay — SoFi Stadium, Los Angeles
  ('USA', 'Paraguay', '🇺🇸', '🇵🇾',
   '2026-06-14 02:00:00+00', 'Group Stage', 'scheduled', false,
   'SoFi Stadium, Los Angeles',
   'Sat 13 Jun · 19:00 (Los Angeles) — TBC',
   'D', 'GROUP');

COMMIT;
