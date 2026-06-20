-- =============================================================================
-- Migration: inbox_messages
-- =============================================================================
--
-- Backs the "share a list / recipe with another ChowSA user" feature.
-- The sender inserts a row addressed to a recipient handle; the recipient
-- subscribes via realtime to receive instant inbox pushes.
--
-- The Flutter code (main_navigation_hub.dart._subscribeToInbox) already
-- expects this table — but no migration ever shipped, so the insert was
-- failing silently and the realtime subscription had nothing to fire on.
--
-- Schema:
--   id               uuid PK
--   sender_id        uuid (auth.users)
--   receiver_handle  text  — recipient's profile handle (lowercase)
--   message_type     text  — 'shared_list' | 'shared_recipe' | future
--   payload          jsonb — message-type-specific body
--   is_read          boolean
--   created_at       timestamptz
--
-- RLS:
--   • Sender can INSERT rows where sender_id = auth.uid().
--   • Recipient can SELECT rows where their lowercase profile handle
--     equals receiver_handle (case-insensitive match via lower(...)).
--   • Recipient can UPDATE is_read on their own rows.
--   • Sender can DELETE their own outgoing rows (for cancel/retract).
--
-- Realtime: added to supabase_realtime publication so .onPostgresChanges
-- INSERT events fire on the recipient's device.
--
-- Idempotent.
-- =============================================================================

BEGIN;

-- ── 1. Table ────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.inbox_messages (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sender_id       uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  receiver_handle text NOT NULL CHECK (length(receiver_handle) BETWEEN 1 AND 80),
  message_type    text NOT NULL DEFAULT 'shared_list'
                  CHECK (length(message_type) BETWEEN 1 AND 40),
  payload         jsonb NOT NULL DEFAULT '{}'::jsonb,
  is_read         boolean NOT NULL DEFAULT false,
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_inbox_messages_recipient_recent
  ON public.inbox_messages (lower(receiver_handle), created_at DESC);

CREATE INDEX IF NOT EXISTS idx_inbox_messages_sender_recent
  ON public.inbox_messages (sender_id, created_at DESC);

-- ── 2. RLS ──────────────────────────────────────────────────────────────────
ALTER TABLE public.inbox_messages ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS inbox_messages_sender_insert ON public.inbox_messages;
CREATE POLICY inbox_messages_sender_insert ON public.inbox_messages
  FOR INSERT TO authenticated
  WITH CHECK (sender_id = auth.uid());

-- Recipient can read any row addressed to their handle. We match by
-- lower(profile.handle) AND lower(profile.username) so either form of
-- the recipient's identifier works.
DROP POLICY IF EXISTS inbox_messages_recipient_select ON public.inbox_messages;
CREATE POLICY inbox_messages_recipient_select ON public.inbox_messages
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1
        FROM public.profiles p
       WHERE p.id = auth.uid()
         AND (
              lower(coalesce(p.handle,   '')) = lower(receiver_handle)
           OR lower(coalesce(p.username, '')) = lower(receiver_handle)
         )
    )
    -- Sender can also read their own outgoing messages (useful for a
    -- "sent items" view later, harmless if unused).
    OR sender_id = auth.uid()
  );

-- Recipient can mark messages as read.
DROP POLICY IF EXISTS inbox_messages_recipient_mark_read ON public.inbox_messages;
CREATE POLICY inbox_messages_recipient_mark_read ON public.inbox_messages
  FOR UPDATE TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.profiles p
     WHERE p.id = auth.uid()
       AND (lower(coalesce(p.handle, '')) = lower(receiver_handle)
         OR lower(coalesce(p.username, '')) = lower(receiver_handle))
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.profiles p
     WHERE p.id = auth.uid()
       AND (lower(coalesce(p.handle, '')) = lower(receiver_handle)
         OR lower(coalesce(p.username, '')) = lower(receiver_handle))
  ));

-- Sender can delete their own outgoing rows (retract).
DROP POLICY IF EXISTS inbox_messages_sender_delete ON public.inbox_messages;
CREATE POLICY inbox_messages_sender_delete ON public.inbox_messages
  FOR DELETE TO authenticated
  USING (sender_id = auth.uid());

-- ── 3. Realtime publication ─────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
     WHERE pubname    = 'supabase_realtime'
       AND tablename  = 'inbox_messages'
  ) THEN
    EXECUTE 'ALTER PUBLICATION supabase_realtime ADD TABLE public.inbox_messages';
  END IF;
END$$;

COMMIT;

NOTIFY pgrst, 'reload schema';
