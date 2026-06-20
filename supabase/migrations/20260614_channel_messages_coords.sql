-- =============================================================================
-- Migration: channel_messages_coords
-- =============================================================================
--
-- Adds the missing coordinate columns to channel_messages and reloads
-- PostgREST's schema cache so the Flutter client can immediately insert
-- Spotted-pin rows without the PGRST204 "could not find the 'latitude'
-- column" error.
--
-- Pairs with 20260613 (which added is_spot_pin) — these three columns
-- complete the Spotted-pin schema.
--
-- All three columns are nullable so existing non-pin rows stay valid.
-- A CHECK enforces both-or-neither lat/lng and WGS-84 ranges so a UI bug
-- can't write garbage coords.
--
-- Idempotent.
-- =============================================================================

BEGIN;

ALTER TABLE public.channel_messages
  ADD COLUMN IF NOT EXISTS latitude      double precision,
  ADD COLUMN IF NOT EXISTS longitude     double precision,
  ADD COLUMN IF NOT EXISTS location_name text;

-- Both-or-neither + WGS-84 range guard.
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

-- Partial index — only Spotted pins need to be queryable by coordinate.
CREATE INDEX IF NOT EXISTS idx_channel_messages_spot_pin_coords
  ON public.channel_messages (latitude, longitude)
  WHERE is_spot_pin = true;

COMMENT ON COLUMN public.channel_messages.latitude      IS
  'WGS-84 latitude for a Spotted location pin. Paired with longitude.';
COMMENT ON COLUMN public.channel_messages.longitude     IS
  'WGS-84 longitude for a Spotted location pin. Paired with latitude.';
COMMENT ON COLUMN public.channel_messages.location_name IS
  'Optional human-readable label for the pin, e.g. "V&A Waterfront, Cape Town".';

COMMIT;

NOTIFY pgrst, 'reload schema';
