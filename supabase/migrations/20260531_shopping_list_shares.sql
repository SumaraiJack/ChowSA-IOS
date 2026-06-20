-- =============================================================================
-- Migration: shopping_list_shares
--
-- Dedicated relation table for the "Share List" feature. Replaces the
-- generic shared_assets fallback the UI was using — gives shopping-list
-- shares a typed home with proper FKs so the inbox UI can join on list_id
-- and render a live preview instead of a blob payload.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.shopping_list_shares (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  list_id      text NOT NULL,                   -- ShoppingList.id from the client
  list_name    text NOT NULL,                   -- denormalised for inbox preview
  sender_id    uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  sender_handle text,                            -- denormalised display name
  receiver_id  uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  items        jsonb NOT NULL DEFAULT '[]'::jsonb,
  is_read      boolean NOT NULL DEFAULT false,
  created_at   timestamptz NOT NULL DEFAULT now(),

  -- One sender can only share the SAME list once to the SAME receiver; a
  -- second tap on Send becomes a no-op upsert instead of spamming the inbox.
  UNIQUE (list_id, sender_id, receiver_id)
);

-- ── Indexes ───────────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_shopping_list_shares_receiver_unread
  ON public.shopping_list_shares (receiver_id, is_read)
  WHERE is_read = false;

CREATE INDEX IF NOT EXISTS idx_shopping_list_shares_sender
  ON public.shopping_list_shares (sender_id);

-- ── Row-Level Security ────────────────────────────────────────────────────────
ALTER TABLE public.shopping_list_shares ENABLE ROW LEVEL SECURITY;

-- Sender can insert rows where they are the sender_id.
CREATE POLICY shopping_list_shares_send
  ON public.shopping_list_shares
  FOR INSERT TO authenticated
  WITH CHECK (auth.uid() = sender_id);

-- Both sender and receiver can read their own shares.
CREATE POLICY shopping_list_shares_read
  ON public.shopping_list_shares
  FOR SELECT TO authenticated
  USING (auth.uid() = sender_id OR auth.uid() = receiver_id);

-- Receiver can mark their own row as read.
CREATE POLICY shopping_list_shares_mark_read
  ON public.shopping_list_shares
  FOR UPDATE TO authenticated
  USING (auth.uid() = receiver_id);

-- Either party can delete the row (decline / undo send).
CREATE POLICY shopping_list_shares_delete
  ON public.shopping_list_shares
  FOR DELETE TO authenticated
  USING (auth.uid() = sender_id OR auth.uid() = receiver_id);

-- ── Comments ──────────────────────────────────────────────────────────────────
COMMENT ON TABLE public.shopping_list_shares IS
  'Per-recipient delivery record for the Share List feature. One row per '
  '(list_id, sender, receiver) triple.';

COMMENT ON COLUMN public.shopping_list_shares.items IS
  'Snapshot of the list items at send time. Receiver sees what the sender '
  'sent even if the sender later modifies their own copy of the list.';
