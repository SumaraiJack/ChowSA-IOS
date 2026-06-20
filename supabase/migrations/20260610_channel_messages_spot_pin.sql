-- =============================================================================
-- Migration: channel_messages_spot_pin
-- =============================================================================
--
-- Adds the location-pin fields to `channel_messages` so the Spotted channel
-- can carry a precise lat/lng coordinate alongside the message text. Used
-- by the "drop a pin when you spot a food truck / pop-up" feature.
--
-- Columns added (all nullable so existing rows remain valid):
--   • latitude       double precision  — WGS-84 latitude  (−90 .. 90)
--   • longitude      double precision  — WGS-84 longitude (−180 .. 180)
--   • location_name  text              — human-readable label, e.g.
--                                        "V&A Waterfront, Cape Town"
--   • is_spot_pin    boolean NOT NULL DEFAULT false — fast filter for
--                                        Spotted-pin rendering / map queries.
--
-- A CHECK constraint enforces that latitude and longitude are either both
-- present or both absent — a half-populated pin is meaningless. A partial
-- index on (lat, lng) WHERE is_spot_pin = true makes "show pins in the
-- viewport" queries cheap.
--
-- Idempotent — safe to re-run.
-- =============================================================================

BEGIN;

-- ── 1. Columns ──────────────────────────────────────────────────────────────
ALTER TABLE public.channel_messages
  ADD COLUMN IF NOT EXISTS latitude      double precision,
  ADD COLUMN IF NOT EXISTS longitude     double precision,
  ADD COLUMN IF NOT EXISTS location_name text,
  ADD COLUMN IF NOT EXISTS is_spot_pin   boolean NOT NULL DEFAULT false;

-- ── 2. Both-or-neither integrity check on the coordinate pair ───────────────
-- A row may not have a lone latitude without a longitude (or vice-versa).
-- WGS-84 ranges are also enforced — guards against UI bugs that might
-- write garbage coords (e.g. accidentally storing screen pixels).
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conname = 'channel_messages_coords_paired'
  ) THEN
    ALTER TABLE public.channel_messages
      ADD CONSTRAINT channel_messages_coords_paired
      CHECK (
        (latitude IS NULL AND longitude IS NULL)
        OR (
              latitude  BETWEEN  -90 AND  90
          AND longitude BETWEEN -180 AND 180
        )
      );
  END IF;
END$$;

-- ── 3. Map-query index ──────────────────────────────────────────────────────
-- Only Spotted pins need to be searchable by coordinate; chat-only messages
-- don't. A partial index keeps the index tiny and write-cheap.
CREATE INDEX IF NOT EXISTS idx_channel_messages_spot_pin_coords
  ON public.channel_messages (latitude, longitude)
  WHERE is_spot_pin = true;

-- ── 4. Lookup index for filtering by channel + spot-pin flag ────────────────
-- Used by the Spotted feed's "show only pins" toggle.
CREATE INDEX IF NOT EXISTS idx_channel_messages_channel_spot_pin
  ON public.channel_messages (channel_id, created_at DESC)
  WHERE is_spot_pin = true;

-- ── 5. Column comments — surface intent in the table editor ─────────────────
COMMENT ON COLUMN public.channel_messages.latitude       IS
  'WGS-84 latitude for a Spotted location pin. Paired with longitude.';
COMMENT ON COLUMN public.channel_messages.longitude      IS
  'WGS-84 longitude for a Spotted location pin. Paired with latitude.';
COMMENT ON COLUMN public.channel_messages.location_name  IS
  'Optional human label for the pin, e.g. "V&A Waterfront, Cape Town".';
COMMENT ON COLUMN public.channel_messages.is_spot_pin    IS
  'True when the message represents a Spotted location drop (food truck, '
  'pop-up, etc). Used by the UI for pin-marker rendering and map filters.';

COMMIT;
