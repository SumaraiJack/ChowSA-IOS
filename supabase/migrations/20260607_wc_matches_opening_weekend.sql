-- =============================================================================
-- Migration: wc_matches_opening_weekend
-- =============================================================================
--
-- Replaces every wc_matches row with the FULL 12-fixture opening weekend
-- (Thu 11 → Sun 14 June 2026), transcribed directly from the published
-- FIFA fixture list (Thursday–Sunday block).
--
-- Source data: user-supplied reference screenshot. Confirmed fields are
-- DATE, GROUP, TEAMS, VENUE.  Kickoff times were NOT in the source and
-- are seeded as 12:00:00 UTC of each fixture's published date — a neutral
-- placeholder that keeps the app's "Group by Date" header sorting on the
-- correct day for every viewer timezone.  Update match_time once FIFA
-- publishes the slot times; the kickoff_local label is flagged "(time TBC)"
-- so the dashboard reflects this clearly.
--
-- Schema notes (mapping to user's spec):
--   • 'group_label' in the spec  →  group_code column (text 'A'..'F')
--   • Flag values use ISO 3166-1 alpha-2 codes ('MX','ZA','KR','CZ', …).
--     The model's _toFlagEmoji converter passes non-2-letter strings
--     through verbatim, so Scotland's subdivision-tagged emoji is
--     embedded literally.
--   • is_bafana_match flagged true only on Mexico v South Africa.
--
-- Idempotent: full wipe + re-insert.
-- =============================================================================

BEGIN;

-- ── 1. Ensure the schema columns this seed writes to actually exist ─────────
-- These columns came from earlier migrations that may not have been applied
-- to every environment. `ADD COLUMN IF NOT EXISTS` is idempotent — a no-op
-- when the column already exists, so this is safe to re-run.
ALTER TABLE public.wc_matches
  ADD COLUMN IF NOT EXISTS venue         text,
  ADD COLUMN IF NOT EXISTS kickoff_local text,
  ADD COLUMN IF NOT EXISTS group_code    text;

-- ── 2. Wipe every existing row ──────────────────────────────────────────────
DELETE FROM public.wc_matches WHERE id IS NOT NULL;

-- ── 2. Insert opening-weekend fixtures, chronologically ─────────────────────

-- ─────────── Thursday, 11 June 2026 ─────────────────────────────────────────

-- Group A — Mexico v South Africa — Mexico City Stadium
INSERT INTO public.wc_matches (
  team_a, team_b, team_a_flag, team_b_flag,
  team_a_score, team_b_score,
  match_time, stage, status, is_bafana_match, live_minute,
  venue, kickoff_local, group_code
) VALUES (
  'Mexico', 'South Africa', 'MX', 'ZA',
  0, 0,
  '2026-06-11 12:00:00+00'::timestamptz, 'Group Stage', 'scheduled', true, 0,
  'Mexico City Stadium', 'Thu 11 Jun (time TBC)', 'A'
);

-- Group A — Korea Republic v Czechia — Estadio Guadalajara
INSERT INTO public.wc_matches (
  team_a, team_b, team_a_flag, team_b_flag,
  team_a_score, team_b_score,
  match_time, stage, status, is_bafana_match, live_minute,
  venue, kickoff_local, group_code
) VALUES (
  'Korea Republic', 'Czechia', 'KR', 'CZ',
  0, 0,
  '2026-06-11 12:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0,
  'Estadio Guadalajara', 'Thu 11 Jun (time TBC)', 'A'
);

-- ─────────── Friday, 12 June 2026 ───────────────────────────────────────────

-- Group B — Canada v Bosnia and Herzegovina — Toronto Stadium
INSERT INTO public.wc_matches (
  team_a, team_b, team_a_flag, team_b_flag,
  team_a_score, team_b_score,
  match_time, stage, status, is_bafana_match, live_minute,
  venue, kickoff_local, group_code
) VALUES (
  'Canada', 'Bosnia and Herzegovina', 'CA', 'BA',
  0, 0,
  '2026-06-12 12:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0,
  'Toronto Stadium', 'Fri 12 Jun (time TBC)', 'B'
);

-- Group D — USA v Paraguay — Los Angeles Stadium
INSERT INTO public.wc_matches (
  team_a, team_b, team_a_flag, team_b_flag,
  team_a_score, team_b_score,
  match_time, stage, status, is_bafana_match, live_minute,
  venue, kickoff_local, group_code
) VALUES (
  'USA', 'Paraguay', 'US', 'PY',
  0, 0,
  '2026-06-12 12:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0,
  'Los Angeles Stadium', 'Fri 12 Jun (time TBC)', 'D'
);

-- ─────────── Saturday, 13 June 2026 ─────────────────────────────────────────

-- Group C — Haiti v Scotland — Boston Stadium
-- Scotland's flag is the subdivision-tagged emoji 🏴󠁧󠁢󠁳󠁣󠁴󠁿;
-- the model passes non-2-letter strings through verbatim.
INSERT INTO public.wc_matches (
  team_a, team_b, team_a_flag, team_b_flag,
  team_a_score, team_b_score,
  match_time, stage, status, is_bafana_match, live_minute,
  venue, kickoff_local, group_code
) VALUES (
  'Haiti', 'Scotland', 'HT', '🏴󠁧󠁢󠁳󠁣󠁴󠁿',
  0, 0,
  '2026-06-13 12:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0,
  'Boston Stadium', 'Sat 13 Jun (time TBC)', 'C'
);

-- Group D — Australia v Türkiye — BC Place Vancouver
INSERT INTO public.wc_matches (
  team_a, team_b, team_a_flag, team_b_flag,
  team_a_score, team_b_score,
  match_time, stage, status, is_bafana_match, live_minute,
  venue, kickoff_local, group_code
) VALUES (
  'Australia', 'Türkiye', 'AU', 'TR',
  0, 0,
  '2026-06-13 12:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0,
  'BC Place Vancouver', 'Sat 13 Jun (time TBC)', 'D'
);

-- Group C — Brazil v Morocco — New York New Jersey Stadium
INSERT INTO public.wc_matches (
  team_a, team_b, team_a_flag, team_b_flag,
  team_a_score, team_b_score,
  match_time, stage, status, is_bafana_match, live_minute,
  venue, kickoff_local, group_code
) VALUES (
  'Brazil', 'Morocco', 'BR', 'MA',
  0, 0,
  '2026-06-13 12:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0,
  'New York New Jersey Stadium', 'Sat 13 Jun (time TBC)', 'C'
);

-- Group B — Qatar v Switzerland — San Francisco Bay Area Stadium
INSERT INTO public.wc_matches (
  team_a, team_b, team_a_flag, team_b_flag,
  team_a_score, team_b_score,
  match_time, stage, status, is_bafana_match, live_minute,
  venue, kickoff_local, group_code
) VALUES (
  'Qatar', 'Switzerland', 'QA', 'CH',
  0, 0,
  '2026-06-13 12:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0,
  'San Francisco Bay Area Stadium', 'Sat 13 Jun (time TBC)', 'B'
);

-- ─────────── Sunday, 14 June 2026 ───────────────────────────────────────────

-- Group E — Côte d'Ivoire v Ecuador — Philadelphia Stadium
INSERT INTO public.wc_matches (
  team_a, team_b, team_a_flag, team_b_flag,
  team_a_score, team_b_score,
  match_time, stage, status, is_bafana_match, live_minute,
  venue, kickoff_local, group_code
) VALUES (
  'Côte d''Ivoire', 'Ecuador', 'CI', 'EC',
  0, 0,
  '2026-06-14 12:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0,
  'Philadelphia Stadium', 'Sun 14 Jun (time TBC)', 'E'
);

-- Group E — Germany v Curaçao — Houston Stadium
INSERT INTO public.wc_matches (
  team_a, team_b, team_a_flag, team_b_flag,
  team_a_score, team_b_score,
  match_time, stage, status, is_bafana_match, live_minute,
  venue, kickoff_local, group_code
) VALUES (
  'Germany', 'Curaçao', 'DE', 'CW',
  0, 0,
  '2026-06-14 12:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0,
  'Houston Stadium', 'Sun 14 Jun (time TBC)', 'E'
);

-- Group F — Netherlands v Japan — Dallas Stadium
INSERT INTO public.wc_matches (
  team_a, team_b, team_a_flag, team_b_flag,
  team_a_score, team_b_score,
  match_time, stage, status, is_bafana_match, live_minute,
  venue, kickoff_local, group_code
) VALUES (
  'Netherlands', 'Japan', 'NL', 'JP',
  0, 0,
  '2026-06-14 12:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0,
  'Dallas Stadium', 'Sun 14 Jun (time TBC)', 'F'
);

-- Group F — Sweden v Tunisia — Estadio Monterrey
INSERT INTO public.wc_matches (
  team_a, team_b, team_a_flag, team_b_flag,
  team_a_score, team_b_score,
  match_time, stage, status, is_bafana_match, live_minute,
  venue, kickoff_local, group_code
) VALUES (
  'Sweden', 'Tunisia', 'SE', 'TN',
  0, 0,
  '2026-06-14 12:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0,
  'Estadio Monterrey', 'Sun 14 Jun (time TBC)', 'F'
);

COMMIT;
