-- =============================================================================
-- Migration: wc_matches_full_group_stage
-- =============================================================================
--
-- Full 72-fixture seed for the 2026 FIFA World Cup group stage.
-- Source: Wikipedia per-group articles (2026_FIFA_World_Cup_Group_A
-- through _Group_L), cross-checked against published kickoff times in
-- venue-local timezones.  Each match_time is stored as the absolute UTC
-- instant; kickoff_local carries the SAST (UTC+2) human label so the
-- ChowSA dashboard displays times relevant to the SA audience without
-- any client-side timezone math.
--
-- Naming convention:
--   • Team names follow the user's preferred form:
--     "Korea Republic", "Czechia", "Türkiye", "USA", "Côte d'Ivoire".
--   • Flags use ISO 3166-1 alpha-2 (2-letter) codes; the model converts
--     to regional-indicator emoji at render time.
--   • Scotland and England flags are the subdivision-tagged emoji
--     embedded literally (the converter passes non-2-letter through).
--   • is_bafana_match = true on every South Africa fixture (3 matches).
--
-- Idempotent: full wipe + re-insert.
-- =============================================================================

BEGIN;

-- Ensure the columns referenced below exist (no-op if already added).
ALTER TABLE public.wc_matches
  ADD COLUMN IF NOT EXISTS venue         text,
  ADD COLUMN IF NOT EXISTS kickoff_local text,
  ADD COLUMN IF NOT EXISTS group_code    text;

DELETE FROM public.wc_matches WHERE id IS NOT NULL;

-- ─────────── Group A ────────────────────────────────────────────────────────
INSERT INTO public.wc_matches (team_a, team_b, team_a_flag, team_b_flag, team_a_score, team_b_score, match_time, stage, status, is_bafana_match, live_minute, venue, kickoff_local, group_code) VALUES
  ('Mexico',         'South Africa',   'MX', 'ZA', 0, 0, '2026-06-11 19:00:00+00'::timestamptz, 'Group Stage', 'scheduled', true,  0, 'Estadio Azteca, Mexico City',         'Thu 11 Jun · 21:00 SAST', 'A'),
  ('Korea Republic', 'Czechia',        'KR', 'CZ', 0, 0, '2026-06-12 02:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'Estadio Akron, Zapopan',              'Fri 12 Jun · 04:00 SAST', 'A'),
  ('Czechia',        'South Africa',   'CZ', 'ZA', 0, 0, '2026-06-18 16:00:00+00'::timestamptz, 'Group Stage', 'scheduled', true,  0, 'Mercedes-Benz Stadium, Atlanta',      'Thu 18 Jun · 18:00 SAST', 'A'),
  ('Mexico',         'Korea Republic', 'MX', 'KR', 0, 0, '2026-06-19 01:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'Estadio Akron, Zapopan',              'Fri 19 Jun · 03:00 SAST', 'A'),
  ('Czechia',        'Mexico',         'CZ', 'MX', 0, 0, '2026-06-25 01:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'Estadio Azteca, Mexico City',         'Thu 25 Jun · 03:00 SAST', 'A'),
  ('South Africa',   'Korea Republic', 'ZA', 'KR', 0, 0, '2026-06-25 01:00:00+00'::timestamptz, 'Group Stage', 'scheduled', true,  0, 'Estadio BBVA, Guadalupe',             'Thu 25 Jun · 03:00 SAST', 'A');

-- ─────────── Group B ────────────────────────────────────────────────────────
INSERT INTO public.wc_matches (team_a, team_b, team_a_flag, team_b_flag, team_a_score, team_b_score, match_time, stage, status, is_bafana_match, live_minute, venue, kickoff_local, group_code) VALUES
  ('Canada',                 'Bosnia and Herzegovina', 'CA', 'BA', 0, 0, '2026-06-12 19:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'BMO Field, Toronto',          'Fri 12 Jun · 21:00 SAST', 'B'),
  ('Qatar',                  'Switzerland',            'QA', 'CH', 0, 0, '2026-06-13 19:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'Levi''s Stadium, Santa Clara', 'Sat 13 Jun · 21:00 SAST', 'B'),
  ('Switzerland',            'Bosnia and Herzegovina', 'CH', 'BA', 0, 0, '2026-06-18 19:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'SoFi Stadium, Inglewood',     'Thu 18 Jun · 21:00 SAST', 'B'),
  ('Canada',                 'Qatar',                  'CA', 'QA', 0, 0, '2026-06-18 22:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'BC Place, Vancouver',         'Fri 19 Jun · 00:00 SAST', 'B'),
  ('Switzerland',            'Canada',                 'CH', 'CA', 0, 0, '2026-06-24 19:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'BC Place, Vancouver',         'Wed 24 Jun · 21:00 SAST', 'B'),
  ('Bosnia and Herzegovina', 'Qatar',                  'BA', 'QA', 0, 0, '2026-06-24 19:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'Lumen Field, Seattle',        'Wed 24 Jun · 21:00 SAST', 'B');

-- ─────────── Group C ────────────────────────────────────────────────────────
INSERT INTO public.wc_matches (team_a, team_b, team_a_flag, team_b_flag, team_a_score, team_b_score, match_time, stage, status, is_bafana_match, live_minute, venue, kickoff_local, group_code) VALUES
  ('Brazil',   'Morocco',  'BR', 'MA',                   0, 0, '2026-06-13 22:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'MetLife Stadium, East Rutherford',    'Sun 14 Jun · 00:00 SAST', 'C'),
  ('Haiti',    'Scotland', 'HT', '🏴󠁧󠁢󠁳󠁣󠁴󠁿',                  0, 0, '2026-06-14 01:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'Gillette Stadium, Foxborough',        'Sun 14 Jun · 03:00 SAST', 'C'),
  ('Scotland', 'Morocco',  '🏴󠁧󠁢󠁳󠁣󠁴󠁿', 'MA',                   0, 0, '2026-06-19 22:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'Gillette Stadium, Foxborough',        'Sat 20 Jun · 00:00 SAST', 'C'),
  ('Brazil',   'Haiti',    'BR', 'HT',                   0, 0, '2026-06-20 00:30:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'Lincoln Financial Field, Philadelphia','Sat 20 Jun · 02:30 SAST', 'C'),
  ('Scotland', 'Brazil',   '🏴󠁧󠁢󠁳󠁣󠁴󠁿', 'BR',                   0, 0, '2026-06-24 22:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'Hard Rock Stadium, Miami Gardens',    'Thu 25 Jun · 00:00 SAST', 'C'),
  ('Morocco',  'Haiti',    'MA', 'HT',                   0, 0, '2026-06-24 22:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'Mercedes-Benz Stadium, Atlanta',      'Thu 25 Jun · 00:00 SAST', 'C');

-- ─────────── Group D ────────────────────────────────────────────────────────
INSERT INTO public.wc_matches (team_a, team_b, team_a_flag, team_b_flag, team_a_score, team_b_score, match_time, stage, status, is_bafana_match, live_minute, venue, kickoff_local, group_code) VALUES
  ('USA',       'Paraguay',  'US', 'PY', 0, 0, '2026-06-13 01:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'SoFi Stadium, Inglewood',          'Sat 13 Jun · 03:00 SAST', 'D'),
  ('Australia', 'Türkiye',   'AU', 'TR', 0, 0, '2026-06-14 04:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'BC Place, Vancouver',              'Sun 14 Jun · 06:00 SAST', 'D'),
  ('USA',       'Australia', 'US', 'AU', 0, 0, '2026-06-19 19:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'Lumen Field, Seattle',             'Fri 19 Jun · 21:00 SAST', 'D'),
  ('Türkiye',   'Paraguay',  'TR', 'PY', 0, 0, '2026-06-20 03:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'Levi''s Stadium, Santa Clara',     'Sat 20 Jun · 05:00 SAST', 'D'),
  ('Türkiye',   'USA',       'TR', 'US', 0, 0, '2026-06-26 02:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'SoFi Stadium, Inglewood',          'Fri 26 Jun · 04:00 SAST', 'D'),
  ('Paraguay',  'Australia', 'PY', 'AU', 0, 0, '2026-06-26 02:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'Levi''s Stadium, Santa Clara',     'Fri 26 Jun · 04:00 SAST', 'D');

-- ─────────── Group E ────────────────────────────────────────────────────────
INSERT INTO public.wc_matches (team_a, team_b, team_a_flag, team_b_flag, team_a_score, team_b_score, match_time, stage, status, is_bafana_match, live_minute, venue, kickoff_local, group_code) VALUES
  ('Germany',       'Curaçao',        'DE', 'CW', 0, 0, '2026-06-14 17:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'NRG Stadium, Houston',                 'Sun 14 Jun · 19:00 SAST', 'E'),
  ('Côte d''Ivoire','Ecuador',        'CI', 'EC', 0, 0, '2026-06-14 23:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'Lincoln Financial Field, Philadelphia','Mon 15 Jun · 01:00 SAST', 'E'),
  ('Germany',       'Côte d''Ivoire', 'DE', 'CI', 0, 0, '2026-06-20 20:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'BMO Field, Toronto',                   'Sat 20 Jun · 22:00 SAST', 'E'),
  ('Ecuador',       'Curaçao',        'EC', 'CW', 0, 0, '2026-06-21 00:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'Arrowhead Stadium, Kansas City',       'Sun 21 Jun · 02:00 SAST', 'E'),
  ('Curaçao',       'Côte d''Ivoire', 'CW', 'CI', 0, 0, '2026-06-25 20:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'Lincoln Financial Field, Philadelphia','Thu 25 Jun · 22:00 SAST', 'E'),
  ('Ecuador',       'Germany',        'EC', 'DE', 0, 0, '2026-06-25 20:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'MetLife Stadium, East Rutherford',     'Thu 25 Jun · 22:00 SAST', 'E');

-- ─────────── Group F ────────────────────────────────────────────────────────
INSERT INTO public.wc_matches (team_a, team_b, team_a_flag, team_b_flag, team_a_score, team_b_score, match_time, stage, status, is_bafana_match, live_minute, venue, kickoff_local, group_code) VALUES
  ('Netherlands', 'Japan',       'NL', 'JP', 0, 0, '2026-06-14 20:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'AT&T Stadium, Arlington',         'Sun 14 Jun · 22:00 SAST', 'F'),
  ('Sweden',      'Tunisia',     'SE', 'TN', 0, 0, '2026-06-15 02:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'Estadio BBVA, Guadalupe',         'Mon 15 Jun · 04:00 SAST', 'F'),
  ('Netherlands', 'Sweden',      'NL', 'SE', 0, 0, '2026-06-20 17:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'NRG Stadium, Houston',            'Sat 20 Jun · 19:00 SAST', 'F'),
  ('Tunisia',     'Japan',       'TN', 'JP', 0, 0, '2026-06-21 04:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'Estadio BBVA, Guadalupe',         'Sun 21 Jun · 06:00 SAST', 'F'),
  ('Japan',       'Sweden',      'JP', 'SE', 0, 0, '2026-06-25 23:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'AT&T Stadium, Arlington',         'Fri 26 Jun · 01:00 SAST', 'F'),
  ('Tunisia',     'Netherlands', 'TN', 'NL', 0, 0, '2026-06-25 23:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'Arrowhead Stadium, Kansas City',  'Fri 26 Jun · 01:00 SAST', 'F');

-- ─────────── Group G ────────────────────────────────────────────────────────
INSERT INTO public.wc_matches (team_a, team_b, team_a_flag, team_b_flag, team_a_score, team_b_score, match_time, stage, status, is_bafana_match, live_minute, venue, kickoff_local, group_code) VALUES
  ('Belgium',     'Egypt',       'BE', 'EG', 0, 0, '2026-06-15 19:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'Lumen Field, Seattle',     'Mon 15 Jun · 21:00 SAST', 'G'),
  ('Iran',        'New Zealand', 'IR', 'NZ', 0, 0, '2026-06-16 01:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'SoFi Stadium, Inglewood',  'Tue 16 Jun · 03:00 SAST', 'G'),
  ('Belgium',     'Iran',        'BE', 'IR', 0, 0, '2026-06-21 19:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'SoFi Stadium, Inglewood',  'Sun 21 Jun · 21:00 SAST', 'G'),
  ('New Zealand', 'Egypt',       'NZ', 'EG', 0, 0, '2026-06-22 01:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'BC Place, Vancouver',      'Mon 22 Jun · 03:00 SAST', 'G'),
  ('Egypt',       'Iran',        'EG', 'IR', 0, 0, '2026-06-27 03:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'Lumen Field, Seattle',     'Sat 27 Jun · 05:00 SAST', 'G'),
  ('New Zealand', 'Belgium',     'NZ', 'BE', 0, 0, '2026-06-27 03:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'BC Place, Vancouver',      'Sat 27 Jun · 05:00 SAST', 'G');

-- ─────────── Group H ────────────────────────────────────────────────────────
INSERT INTO public.wc_matches (team_a, team_b, team_a_flag, team_b_flag, team_a_score, team_b_score, match_time, stage, status, is_bafana_match, live_minute, venue, kickoff_local, group_code) VALUES
  ('Spain',        'Cape Verde',   'ES', 'CV', 0, 0, '2026-06-15 16:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'Mercedes-Benz Stadium, Atlanta',   'Mon 15 Jun · 18:00 SAST', 'H'),
  ('Saudi Arabia', 'Uruguay',      'SA', 'UY', 0, 0, '2026-06-15 22:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'Hard Rock Stadium, Miami Gardens', 'Tue 16 Jun · 00:00 SAST', 'H'),
  ('Spain',        'Saudi Arabia', 'ES', 'SA', 0, 0, '2026-06-21 16:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'Mercedes-Benz Stadium, Atlanta',   'Sun 21 Jun · 18:00 SAST', 'H'),
  ('Uruguay',      'Cape Verde',   'UY', 'CV', 0, 0, '2026-06-21 22:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'Hard Rock Stadium, Miami Gardens', 'Mon 22 Jun · 00:00 SAST', 'H'),
  ('Cape Verde',   'Saudi Arabia', 'CV', 'SA', 0, 0, '2026-06-27 00:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'NRG Stadium, Houston',             'Sat 27 Jun · 02:00 SAST', 'H'),
  ('Uruguay',      'Spain',        'UY', 'ES', 0, 0, '2026-06-27 00:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'Estadio Akron, Zapopan',           'Sat 27 Jun · 02:00 SAST', 'H');

-- ─────────── Group I ────────────────────────────────────────────────────────
INSERT INTO public.wc_matches (team_a, team_b, team_a_flag, team_b_flag, team_a_score, team_b_score, match_time, stage, status, is_bafana_match, live_minute, venue, kickoff_local, group_code) VALUES
  ('France',  'Senegal', 'FR', 'SN', 0, 0, '2026-06-16 19:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'MetLife Stadium, East Rutherford', 'Tue 16 Jun · 21:00 SAST', 'I'),
  ('Iraq',    'Norway',  'IQ', 'NO', 0, 0, '2026-06-16 22:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'Gillette Stadium, Foxborough',     'Wed 17 Jun · 00:00 SAST', 'I'),
  ('France',  'Iraq',    'FR', 'IQ', 0, 0, '2026-06-22 21:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'Lincoln Financial Field, Philadelphia', 'Mon 22 Jun · 23:00 SAST', 'I'),
  ('Norway',  'Senegal', 'NO', 'SN', 0, 0, '2026-06-23 00:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'MetLife Stadium, East Rutherford', 'Tue 23 Jun · 02:00 SAST', 'I'),
  ('Norway',  'France',  'NO', 'FR', 0, 0, '2026-06-26 19:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'Gillette Stadium, Foxborough',     'Fri 26 Jun · 21:00 SAST', 'I'),
  ('Senegal', 'Iraq',    'SN', 'IQ', 0, 0, '2026-06-26 19:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'BMO Field, Toronto',               'Fri 26 Jun · 21:00 SAST', 'I');

-- ─────────── Group J ────────────────────────────────────────────────────────
INSERT INTO public.wc_matches (team_a, team_b, team_a_flag, team_b_flag, team_a_score, team_b_score, match_time, stage, status, is_bafana_match, live_minute, venue, kickoff_local, group_code) VALUES
  ('Argentina', 'Algeria',   'AR', 'DZ', 0, 0, '2026-06-17 01:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'Arrowhead Stadium, Kansas City', 'Wed 17 Jun · 03:00 SAST', 'J'),
  ('Austria',   'Jordan',    'AT', 'JO', 0, 0, '2026-06-17 04:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'Levi''s Stadium, Santa Clara',   'Wed 17 Jun · 06:00 SAST', 'J'),
  ('Argentina', 'Austria',   'AR', 'AT', 0, 0, '2026-06-22 17:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'AT&T Stadium, Arlington',        'Mon 22 Jun · 19:00 SAST', 'J'),
  ('Jordan',    'Algeria',   'JO', 'DZ', 0, 0, '2026-06-23 03:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'Levi''s Stadium, Santa Clara',   'Tue 23 Jun · 05:00 SAST', 'J'),
  ('Algeria',   'Austria',   'DZ', 'AT', 0, 0, '2026-06-28 02:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'Arrowhead Stadium, Kansas City', 'Sun 28 Jun · 04:00 SAST', 'J'),
  ('Jordan',    'Argentina', 'JO', 'AR', 0, 0, '2026-06-28 02:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'AT&T Stadium, Arlington',        'Sun 28 Jun · 04:00 SAST', 'J');

-- ─────────── Group K ────────────────────────────────────────────────────────
INSERT INTO public.wc_matches (team_a, team_b, team_a_flag, team_b_flag, team_a_score, team_b_score, match_time, stage, status, is_bafana_match, live_minute, venue, kickoff_local, group_code) VALUES
  ('Portugal',   'DR Congo',    'PT', 'CD', 0, 0, '2026-06-17 17:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'NRG Stadium, Houston',             'Wed 17 Jun · 19:00 SAST', 'K'),
  ('Uzbekistan', 'Colombia',    'UZ', 'CO', 0, 0, '2026-06-18 02:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'Estadio Azteca, Mexico City',      'Thu 18 Jun · 04:00 SAST', 'K'),
  ('Portugal',   'Uzbekistan',  'PT', 'UZ', 0, 0, '2026-06-23 17:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'NRG Stadium, Houston',             'Tue 23 Jun · 19:00 SAST', 'K'),
  ('Colombia',   'DR Congo',    'CO', 'CD', 0, 0, '2026-06-24 02:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'Estadio Akron, Zapopan',           'Wed 24 Jun · 04:00 SAST', 'K'),
  ('Colombia',   'Portugal',    'CO', 'PT', 0, 0, '2026-06-27 23:30:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'Hard Rock Stadium, Miami Gardens', 'Sun 28 Jun · 01:30 SAST', 'K'),
  ('DR Congo',   'Uzbekistan',  'CD', 'UZ', 0, 0, '2026-06-27 23:30:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'Mercedes-Benz Stadium, Atlanta',   'Sun 28 Jun · 01:30 SAST', 'K');

-- ─────────── Group L ────────────────────────────────────────────────────────
INSERT INTO public.wc_matches (team_a, team_b, team_a_flag, team_b_flag, team_a_score, team_b_score, match_time, stage, status, is_bafana_match, live_minute, venue, kickoff_local, group_code) VALUES
  ('England', 'Croatia', '🏴󠁧󠁢󠁥󠁮󠁧󠁿', 'HR', 0, 0, '2026-06-17 20:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'AT&T Stadium, Arlington',           'Wed 17 Jun · 22:00 SAST', 'L'),
  ('Ghana',   'Panama',  'GH', 'PA',                   0, 0, '2026-06-17 23:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'BMO Field, Toronto',                'Thu 18 Jun · 01:00 SAST', 'L'),
  ('England', 'Ghana',   '🏴󠁧󠁢󠁥󠁮󠁧󠁿', 'GH', 0, 0, '2026-06-23 20:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'Gillette Stadium, Foxborough',      'Tue 23 Jun · 22:00 SAST', 'L'),
  ('Panama',  'Croatia', 'PA', 'HR',                   0, 0, '2026-06-23 23:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'BMO Field, Toronto',                'Wed 24 Jun · 01:00 SAST', 'L'),
  ('Panama',  'England', 'PA', '🏴󠁧󠁢󠁥󠁮󠁧󠁿', 0, 0, '2026-06-27 21:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'MetLife Stadium, East Rutherford',  'Sat 27 Jun · 23:00 SAST', 'L'),
  ('Croatia', 'Ghana',   'HR', 'GH',                   0, 0, '2026-06-27 21:00:00+00'::timestamptz, 'Group Stage', 'scheduled', false, 0, 'Lincoln Financial Field, Philadelphia', 'Sat 27 Jun · 23:00 SAST', 'L');

COMMIT;
