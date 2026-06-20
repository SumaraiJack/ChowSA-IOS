-- =============================================================================
-- Migration: locality_feed
-- Adds suburb_district + city to profiles (user home location) and to
-- community_posts (poster's location stamped at write time).
-- Both columns are nullable so existing rows remain valid with no backfill.
-- =============================================================================

-- ── profiles ──────────────────────────────────────────────────────────────────
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS suburb_district text,
  ADD COLUMN IF NOT EXISTS city            text;

-- ── community_posts ───────────────────────────────────────────────────────────
ALTER TABLE public.community_posts
  ADD COLUMN IF NOT EXISTS suburb_district text,
  ADD COLUMN IF NOT EXISTS city            text;

-- ── Indexes — support the city-wide and nearby feed queries efficiently ───────
CREATE INDEX IF NOT EXISTS idx_community_posts_suburb_district
  ON public.community_posts (suburb_district)
  WHERE suburb_district IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_community_posts_city
  ON public.community_posts (city)
  WHERE city IS NOT NULL;

-- ── Comments ──────────────────────────────────────────────────────────────────
COMMENT ON COLUMN public.profiles.suburb_district IS
  'User''s home suburb or district (e.g. "Table View"). Used to seed the '
  'localised community feed.';

COMMENT ON COLUMN public.profiles.city IS
  'User''s home city (e.g. "Cape Town"). Used for the city-wide feed scope.';

COMMENT ON COLUMN public.community_posts.suburb_district IS
  'Poster''s suburb_district at time of posting, copied from profiles row.';

COMMENT ON COLUMN public.community_posts.city IS
  'Poster''s city at time of posting, copied from profiles row.';
