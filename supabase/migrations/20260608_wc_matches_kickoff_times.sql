-- =============================================================================
-- Migration: wc_matches_kickoff_times
-- =============================================================================
--
-- Updates 10 of the 12 opening-weekend fixtures with their confirmed
-- kickoff times, transcribed from FIFA Match Story (SAST display).
-- Stored as absolute UTC instants so the device-local "Group by Date"
-- sticky headers in the fixture sheet resolve correctly for every
-- viewer timezone — and specifically match Match Story's day groupings
-- for SAST viewers.
--
-- Conversion: SAST = UTC+2, no DST. So SAST 21:00 → UTC 19:00 same day,
-- SAST 04:00 → UTC 02:00 same day, etc. Brazil v Morocco is the edge
-- case: SAST Sun 00:00 = UTC Sat 22:00, which is why the row is stored
-- on 2026-06-13 but appears under the Sunday header for SA viewers.
--
-- Two fixtures (Côte d'Ivoire v Ecuador, Sweden v Tunisia) were not
-- visible in the source screenshot; their match_time stays at the
-- noon-UTC placeholder until FIFA publishes their slots, and their
-- kickoff_local label is updated to flag this clearly.
-- =============================================================================

BEGIN;

-- ── Thu 11 Jun 2026 ─────────────────────────────────────────────────────────
UPDATE public.wc_matches
   SET match_time    = '2026-06-11 19:00:00+00'::timestamptz,
       kickoff_local = 'Thu 11 Jun · 21:00 SAST'
 WHERE team_a = 'Mexico' AND team_b = 'South Africa';

-- ── Fri 12 Jun 2026 ─────────────────────────────────────────────────────────
UPDATE public.wc_matches
   SET match_time    = '2026-06-12 02:00:00+00'::timestamptz,
       kickoff_local = 'Fri 12 Jun · 04:00 SAST'
 WHERE team_a = 'Korea Republic' AND team_b = 'Czechia';

UPDATE public.wc_matches
   SET match_time    = '2026-06-12 19:00:00+00'::timestamptz,
       kickoff_local = 'Fri 12 Jun · 21:00 SAST'
 WHERE team_a = 'Canada' AND team_b = 'Bosnia and Herzegovina';

-- ── Sat 13 Jun 2026 ─────────────────────────────────────────────────────────
UPDATE public.wc_matches
   SET match_time    = '2026-06-13 01:00:00+00'::timestamptz,
       kickoff_local = 'Sat 13 Jun · 03:00 SAST'
 WHERE team_a = 'USA' AND team_b = 'Paraguay';

UPDATE public.wc_matches
   SET match_time    = '2026-06-13 19:00:00+00'::timestamptz,
       kickoff_local = 'Sat 13 Jun · 21:00 SAST'
 WHERE team_a = 'Qatar' AND team_b = 'Switzerland';

-- Brazil v Morocco: Sat 22:00 UTC = Sun 00:00 SAST. Stored on the 13th,
-- groups under Sunday for SA viewers via toLocal() — matches Match Story.
UPDATE public.wc_matches
   SET match_time    = '2026-06-13 22:00:00+00'::timestamptz,
       kickoff_local = 'Sun 14 Jun · 00:00 SAST'
 WHERE team_a = 'Brazil' AND team_b = 'Morocco';

-- ── Sun 14 Jun 2026 ─────────────────────────────────────────────────────────
UPDATE public.wc_matches
   SET match_time    = '2026-06-14 01:00:00+00'::timestamptz,
       kickoff_local = 'Sun 14 Jun · 03:00 SAST'
 WHERE team_a = 'Haiti' AND team_b = 'Scotland';

UPDATE public.wc_matches
   SET match_time    = '2026-06-14 04:00:00+00'::timestamptz,
       kickoff_local = 'Sun 14 Jun · 06:00 SAST'
 WHERE team_a = 'Australia' AND team_b = 'Türkiye';

UPDATE public.wc_matches
   SET match_time    = '2026-06-14 17:00:00+00'::timestamptz,
       kickoff_local = 'Sun 14 Jun · 19:00 SAST'
 WHERE team_a = 'Germany' AND team_b = 'Curaçao';

UPDATE public.wc_matches
   SET match_time    = '2026-06-14 20:00:00+00'::timestamptz,
       kickoff_local = 'Sun 14 Jun · 22:00 SAST'
 WHERE team_a = 'Netherlands' AND team_b = 'Japan';

-- ── Still TBC — not visible in source screenshot ────────────────────────────
UPDATE public.wc_matches
   SET kickoff_local = 'Sun 14 Jun (time TBC)'
 WHERE (team_a = 'Côte d''Ivoire' AND team_b = 'Ecuador')
    OR (team_a = 'Sweden'         AND team_b = 'Tunisia');

COMMIT;
