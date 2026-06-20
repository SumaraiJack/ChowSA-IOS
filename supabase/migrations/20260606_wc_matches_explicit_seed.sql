-- =============================================================================
-- Migration: wc_matches_explicit_seed
-- =============================================================================
--
-- Fully explicit clean-and-reseed for public.wc_matches. Targets the columns
-- as they appear in the live Supabase table editor:
--
--   id              uuid                  (default gen_random_uuid())
--   team_a          text                  NOT NULL
--   team_b          text                  NOT NULL
--   team_a_flag     text                  NOT NULL DEFAULT '🏳️'
--   team_b_flag     text                  NOT NULL DEFAULT '🏳️'
--   team_a_score    int                   NOT NULL DEFAULT 0
--   team_b_score    int                   NOT NULL DEFAULT 0
--   match_time      timestamptz           NOT NULL
--   stage           text                  NOT NULL DEFAULT 'Group Stage'
--   status          public.match_status   NOT NULL DEFAULT 'scheduled'
--   is_bafana_match boolean               NOT NULL DEFAULT false
--   live_minute     int                   NOT NULL DEFAULT 0
--
-- Anything else on the table (venue, kickoff_local, group_code,
-- api_match_id, round_code, bracket_slot, home_score, away_score, …)
-- relies on its column default — this script only writes the twelve
-- columns above, so it's safe to run even if those extra columns aren't
-- present yet.
--
-- Flag values use 2-letter ISO 3166-1 alpha-2 codes per spec:
--   Mexico='MX', South Africa='ZA', Korea Republic='KR', Czechia='CZ',
--   Canada='CA', Bosnia and Herzegovina='BA', USA='US', Paraguay='PY'.
--
-- Idempotent — full wipe then re-insert. Safe to re-run any number of times.
-- =============================================================================

BEGIN;

-- ── 1. Wipe every existing row in wc_matches ─────────────────────────────────
DELETE FROM public.wc_matches WHERE id IS NOT NULL;

-- ── 2. Insert the four confirmed opening fixtures ────────────────────────────

-- Match 1 (Group A): Mexico vs South Africa
-- 19:00 CDT (UTC-6) on 11 Jun 2026 = 01:00 UTC on 12 Jun 2026.
INSERT INTO public.wc_matches (
  team_a,
  team_b,
  team_a_flag,
  team_b_flag,
  team_a_score,
  team_b_score,
  match_time,
  stage,
  status,
  is_bafana_match,
  live_minute
) VALUES (
  'Mexico',
  'South Africa',
  'MX',
  'ZA',
  0,
  0,
  '2026-06-11 19:00:00-06'::timestamptz,
  'Group Stage',
  'scheduled',
  true,
  0
);

-- Match 2 (Group A): Korea Republic vs Czechia
-- 12 Jun 2026, placeholder 18:00 CDT (UTC-6) = 00:00 UTC on 13 Jun 2026.
INSERT INTO public.wc_matches (
  team_a,
  team_b,
  team_a_flag,
  team_b_flag,
  team_a_score,
  team_b_score,
  match_time,
  stage,
  status,
  is_bafana_match,
  live_minute
) VALUES (
  'Korea Republic',
  'Czechia',
  'KR',
  'CZ',
  0,
  0,
  '2026-06-12 18:00:00-06'::timestamptz,
  'Group Stage',
  'scheduled',
  false,
  0
);

-- Match 3 (Group B): Canada vs Bosnia and Herzegovina
-- 12 Jun 2026, placeholder 16:00 EDT (UTC-4) = 20:00 UTC on 12 Jun 2026.
INSERT INTO public.wc_matches (
  team_a,
  team_b,
  team_a_flag,
  team_b_flag,
  team_a_score,
  team_b_score,
  match_time,
  stage,
  status,
  is_bafana_match,
  live_minute
) VALUES (
  'Canada',
  'Bosnia and Herzegovina',
  'CA',
  'BA',
  0,
  0,
  '2026-06-12 16:00:00-04'::timestamptz,
  'Group Stage',
  'scheduled',
  false,
  0
);

-- Match 4 (Group D): USA vs Paraguay
-- 13 Jun 2026, placeholder 19:00 PDT (UTC-7) = 02:00 UTC on 14 Jun 2026.
INSERT INTO public.wc_matches (
  team_a,
  team_b,
  team_a_flag,
  team_b_flag,
  team_a_score,
  team_b_score,
  match_time,
  stage,
  status,
  is_bafana_match,
  live_minute
) VALUES (
  'USA',
  'Paraguay',
  'US',
  'PY',
  0,
  0,
  '2026-06-13 19:00:00-07'::timestamptz,
  'Group Stage',
  'scheduled',
  false,
  0
);

COMMIT;
