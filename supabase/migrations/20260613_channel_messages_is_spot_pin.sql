-- =============================================================================
-- Migration: channel_messages_is_spot_pin
-- =============================================================================
--
-- Adds the missing is_spot_pin column to channel_messages and reloads the
-- PostgREST schema cache so the column is immediately visible to the
-- Flutter client (otherwise inserts that include "is_spot_pin" fail with
-- PGRST204 "could not find the column in the schema cache" until the
-- next deploy).
--
-- This is the minimal subset of the original 20260610 migration — the
-- lat/lng coordinate columns are added in that one. Run this on its own
-- if you're only chasing the PGRST204 crash; run 20260610 too if you also
-- want the latitude / longitude / location_name columns.
--
-- Idempotent.
-- =============================================================================

BEGIN;

ALTER TABLE public.channel_messages
  ADD COLUMN IF NOT EXISTS is_spot_pin boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.channel_messages.is_spot_pin IS
  'True when the message represents a Spotted location drop (food truck, '
  'pop-up). Used by the UI for pin-marker rendering and map filters.';

COMMIT;

-- Reload the PostgREST schema cache so the new column is immediately
-- queryable / insertable from the Flutter client. Runs OUTSIDE the
-- transaction because NOTIFY is per-session and the listener picks it up
-- when the current xact ends.
NOTIFY pgrst, 'reload schema';
