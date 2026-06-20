-- =============================================================================
-- Migration: wc_matches_seed — FIFA World Cup 2026 opening Group Stage fixtures
-- =============================================================================
--
-- Replaces the placeholder mock matches with the four confirmed opening
-- fixtures. Idempotent: safe to re-run.
--
-- Tables touched:
--   • public.wc_matches  — created if missing, otherwise just topped up with
--                          the new columns required for venue-local rendering
--
-- Time-zone policy (IMPORTANT — read before editing):
--   • match_time is timestamptz and ALWAYS stored as an absolute UTC instant.
--   • kickoff_local is the human-readable venue-local string the dashboard
--     should display verbatim (e.g. "Thu 11 Jun · 19:00 (Mexico City)").
--     This avoids `.toLocal()` shifting the displayed date for fans in other
--     time zones — a South African viewer of the Mexico fixture would
--     otherwise see "03:00, 12 Jun" because SAST is UTC+2 vs Mexico's UTC-6.
--   • venue is the stadium name as published by FIFA.
--
-- Kick-off time confirmations:
--   • Match 1 (MEX–RSA): 19:00 CDT (Mexico City, UTC-6, no DST) → 01:00 UTC
--     on 12 June. CONFIRMED via the user's spec.
--   • Match 2 (KOR–CZE), Match 3 (CAN–BIH), Match 4 (USA–PAR): times TBC.
--     Placeholders use realistic group-stage evening slots and are flagged
--     "TBC" in kickoff_local — overwrite once FIFA publishes the schedule.
-- =============================================================================

BEGIN;

-- ── 1. Status enum (idempotent) ──────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'match_status') THEN
    CREATE TYPE public.match_status AS ENUM ('scheduled', 'live', 'finished');
  END IF;
END$$;

-- ── 2. Base table (idempotent) ───────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.wc_matches (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  team_a          text        NOT NULL,
  team_b          text        NOT NULL,
  team_a_flag     text        NOT NULL DEFAULT '🏳️',
  team_b_flag     text        NOT NULL DEFAULT '🏳️',
  team_a_score    int         NOT NULL DEFAULT 0,
  team_b_score    int         NOT NULL DEFAULT 0,
  match_time      timestamptz NOT NULL,
  stage           text        NOT NULL DEFAULT 'Group Stage',
  status          public.match_status NOT NULL DEFAULT 'scheduled',
  is_bafana_match boolean     NOT NULL DEFAULT false,
  live_minute     int         NOT NULL DEFAULT 0
);

-- ── 3. New columns required for venue-local rendering (idempotent) ───────────
ALTER TABLE public.wc_matches
  ADD COLUMN IF NOT EXISTS venue          text,
  ADD COLUMN IF NOT EXISTS kickoff_local  text,
  ADD COLUMN IF NOT EXISTS group_code     text;

-- ── 4. Stable upsert keys ────────────────────────────────────────────────────
-- A natural unique key on (team_a, team_b, match_time) lets the seed be
-- re-run without duplicating fixtures.
CREATE UNIQUE INDEX IF NOT EXISTS wc_matches_natural_key
  ON public.wc_matches (team_a, team_b, match_time);

-- ── 5. Wipe stale placeholder fixtures ───────────────────────────────────────
-- Only removes rows in the opening-fixture window so any live-tournament rows
-- written later are preserved.
DELETE FROM public.wc_matches
 WHERE match_time >= '2026-06-11 00:00:00+00'
   AND match_time <  '2026-06-13 12:00:00+00';

-- ── 6. Seed the four official opening fixtures ───────────────────────────────
INSERT INTO public.wc_matches
  (team_a, team_b, team_a_flag, team_b_flag,
   match_time, stage, status, is_bafana_match,
   venue, kickoff_local, group_code)
VALUES
  -- Match 1 (Group A): Mexico vs South Africa — Estadio Azteca, Mexico City
  -- 19:00 CDT (UTC-6) on 11 Jun 2026 = 01:00 UTC on 12 Jun 2026
  ('Mexico', 'South Africa', '🇲🇽', '🇿🇦',
   '2026-06-12 01:00:00+00', 'Group Stage', 'scheduled', true,
   'Estadio Azteca, Mexico City',
   'Thu 11 Jun · 19:00 (Mexico City)',
   'A'),

  -- Match 2 (Group A): Korea Republic vs Czechia — Guadalajara Stadium
  -- TBC: placeholder 22:00 CDT 11 Jun = 04:00 UTC 12 Jun
  ('Korea Republic', 'Czechia', '🇰🇷', '🇨🇿',
   '2026-06-12 04:00:00+00', 'Group Stage', 'scheduled', false,
   'Estadio Akron, Guadalajara',
   'Thu 11 Jun · 22:00 (Guadalajara) — TBC',
   'A'),

  -- Match 3 (Group B): Canada vs Bosnia and Herzegovina — Toronto Stadium
  -- TBC: placeholder 16:00 EDT 12 Jun = 20:00 UTC 12 Jun
  ('Canada', 'Bosnia and Herzegovina', '🇨🇦', '🇧🇦',
   '2026-06-12 20:00:00+00', 'Group Stage', 'scheduled', false,
   'BMO Field, Toronto',
   'Fri 12 Jun · 16:00 (Toronto) — TBC',
   'B'),

  -- Match 4 (Group D): USA vs Paraguay — Los Angeles Stadium
  -- TBC: placeholder 19:00 PDT 12 Jun = 02:00 UTC 13 Jun
  ('USA', 'Paraguay', '🇺🇸', '🇵🇾',
   '2026-06-13 02:00:00+00', 'Group Stage', 'scheduled', false,
   'SoFi Stadium, Los Angeles',
   'Fri 12 Jun · 19:00 (Los Angeles) — TBC',
   'D')
ON CONFLICT (team_a, team_b, match_time) DO UPDATE
   SET team_a_flag    = EXCLUDED.team_a_flag,
       team_b_flag    = EXCLUDED.team_b_flag,
       stage          = EXCLUDED.stage,
       status         = EXCLUDED.status,
       is_bafana_match= EXCLUDED.is_bafana_match,
       venue          = EXCLUDED.venue,
       kickoff_local  = EXCLUDED.kickoff_local,
       group_code     = EXCLUDED.group_code;

COMMIT;
