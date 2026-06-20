-- Adds receiver_id (UUID FK) and status to inbox_messages so the share-list
-- flow can target a recipient by id (not by the brittle receiver_handle text
-- match) AND so accepted/declined state lives on the row instead of being
-- inferred from is_read alone.
--
-- Also fixes the read/update RLS policies, which were matching
--   `auth.uid() IN (SELECT id FROM profiles WHERE display_name = receiver_handle)`
-- That join silently returned NO rows for every user whose handle didn't
-- happen to equal their display_name (which is most users post the
-- on_auth_user_created trigger — handle gets populated, display_name stays
-- null). Recipients couldn't see their own inbox + couldn't mark-read, which
-- broke the dual-badge sync the NotificationCenter listener was built for.

ALTER TABLE public.inbox_messages
  ADD COLUMN IF NOT EXISTS receiver_id uuid REFERENCES public.profiles(id) ON DELETE CASCADE;

ALTER TABLE public.inbox_messages
  ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'pending_import';

CREATE INDEX IF NOT EXISTS idx_inbox_messages_receiver_id
  ON public.inbox_messages (receiver_id);

CREATE INDEX IF NOT EXISTS idx_inbox_messages_receiver_handle_lower
  ON public.inbox_messages (lower(receiver_handle));

UPDATE public.inbox_messages im
SET receiver_id = p.id
FROM public.profiles p
WHERE im.receiver_id IS NULL
  AND lower(p.handle) = lower(im.receiver_handle);

DROP POLICY IF EXISTS "Users can view messages sent to them." ON public.inbox_messages;
DROP POLICY IF EXISTS "Users can update their own inbox messages." ON public.inbox_messages;

CREATE POLICY inbox_messages_read_self
  ON public.inbox_messages
  FOR SELECT
  TO authenticated
  USING (
    auth.uid() = receiver_id
    OR auth.uid() = sender_id
    OR lower(receiver_handle) = lower(
        COALESCE((SELECT handle FROM public.profiles WHERE id = auth.uid()), '')
       )
  );

CREATE POLICY inbox_messages_update_self
  ON public.inbox_messages
  FOR UPDATE
  TO authenticated
  USING (
    auth.uid() = receiver_id
    OR lower(receiver_handle) = lower(
        COALESCE((SELECT handle FROM public.profiles WHERE id = auth.uid()), '')
       )
  )
  WITH CHECK (
    auth.uid() = receiver_id
    OR lower(receiver_handle) = lower(
        COALESCE((SELECT handle FROM public.profiles WHERE id = auth.uid()), '')
       )
  );
