-- =============================================================================
-- Migration: channel_messages_images — image attachments on hub messages
-- =============================================================================
--
-- Adds:
--   • channel_messages.image_url (nullable text) — public storage URL for an
--                                                   optional photo attached to
--                                                   the message.
--   • Storage bucket `whats-cooking-pics`         — public-read, auth-write,
--                                                   used by the Flutter
--                                                   composer's image attach
--                                                   button.
--
-- The bucket policies mirror the existing `posts` bucket pattern: anyone can
-- READ (so feeds render images for signed-out previews too if we ever expose
-- one), but only authenticated users can INSERT / UPDATE / DELETE objects.
-- =============================================================================

BEGIN;

-- ── 1. Column ────────────────────────────────────────────────────────────────
ALTER TABLE public.channel_messages
  ADD COLUMN IF NOT EXISTS image_url text;

COMMENT ON COLUMN public.channel_messages.image_url IS
  'Public URL of an optional image attached to the hub message. '
  'Stored in the whats-cooking-pics storage bucket.';

-- ── 2. Storage bucket ────────────────────────────────────────────────────────
INSERT INTO storage.buckets (id, name, public)
VALUES ('whats-cooking-pics', 'whats-cooking-pics', true)
ON CONFLICT (id) DO NOTHING;

-- ── 3. Storage policies ──────────────────────────────────────────────────────
-- DROP-then-CREATE so re-running the migration doesn't fail on duplicate names.

DROP POLICY IF EXISTS whats_cooking_pics_read   ON storage.objects;
DROP POLICY IF EXISTS whats_cooking_pics_insert ON storage.objects;
DROP POLICY IF EXISTS whats_cooking_pics_update ON storage.objects;
DROP POLICY IF EXISTS whats_cooking_pics_delete ON storage.objects;

CREATE POLICY whats_cooking_pics_read ON storage.objects
  FOR SELECT
  USING (bucket_id = 'whats-cooking-pics');

CREATE POLICY whats_cooking_pics_insert ON storage.objects
  FOR INSERT
  TO authenticated
  WITH CHECK (bucket_id = 'whats-cooking-pics');

CREATE POLICY whats_cooking_pics_update ON storage.objects
  FOR UPDATE
  TO authenticated
  USING      (bucket_id = 'whats-cooking-pics' AND owner = auth.uid())
  WITH CHECK (bucket_id = 'whats-cooking-pics' AND owner = auth.uid());

CREATE POLICY whats_cooking_pics_delete ON storage.objects
  FOR DELETE
  TO authenticated
  USING (bucket_id = 'whats-cooking-pics' AND owner = auth.uid());

COMMIT;
