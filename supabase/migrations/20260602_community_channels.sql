-- =============================================================================
-- Migration: community_channels — Hyper-local "Eskom se Push"-style hubs
-- =============================================================================
--
-- Adds the backbone for ChowSA's hyper-local Community Engine:
--
--   • profiles.user_role             — RBAC discriminator ('user' | 'admin' | …)
--   • community_channels             — one row per suburb × category hub
--   • channel_messages               — all chatter inside a hub
--   • community_channels.pinned_message_id (FK → channel_messages.id)
--                                    — real-time admin pin mechanism
--
-- The FK between the two new tables forms a soft cycle (channel → pinned
-- message → channel), so we create the tables first WITHOUT the
-- pinned_message_id FK, then add the FK as a separate ALTER once both tables
-- exist. The FK uses ON DELETE SET NULL so deleting the pinned message
-- never cascades back into the channel.
--
-- All tables are wrapped in Row-Level Security with two complementary roles:
--   1. Authenticated users — read every channel, write their own messages.
--   2. Admins (profiles.user_role = 'admin') — can mutate channel metadata
--      AND set/clear the pinned_message_id pointer.
-- =============================================================================

BEGIN;

-- =============================================================================
-- 1. PROFILES TABLE EXTENSION
-- =============================================================================
-- RBAC discriminator. Default 'user' keeps existing rows backwards compatible.
-- A CHECK constraint keeps the role vocabulary tight so we never end up with
-- mis-cased values like 'Admin' / 'ADMIN' polluting auth checks downstream.
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS user_role text NOT NULL DEFAULT 'user'
    CHECK (user_role IN ('user', 'moderator', 'admin'));

CREATE INDEX IF NOT EXISTS idx_profiles_user_role
  ON public.profiles (user_role)
  WHERE user_role <> 'user';   -- partial index: only the rare elevated rows

-- Convenience helper used by every RLS policy below — avoids a sub-select in
-- each policy and lets PostgREST cache the lookup per request.
CREATE OR REPLACE FUNCTION public.is_admin(uid uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = uid AND p.user_role = 'admin'
  );
$$;


-- =============================================================================
-- 2. COMMUNITY CHANNELS TABLE
-- =============================================================================
-- One row per (suburb, category) channel. `name` carries the rendered
-- presentation form ("#Parklands-Gatherings"); `suburb` and `category` are
-- the structured fields the app filters on.
--
-- pinned_message_id starts NULL and is populated only when an admin pins a
-- message. The FK to channel_messages is added AFTER channel_messages exists
-- to break the cyclic dependency between the two tables.
CREATE TABLE IF NOT EXISTS public.community_channels (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name               text NOT NULL,
  suburb             text NOT NULL,
  category           text NOT NULL
                       CHECK (category IN ('spotted', 'gatherings', 'pantry', 'cooking')),
  pinned_message_id  uuid,                                -- FK added below
  created_at         timestamptz NOT NULL DEFAULT now(),
  -- A suburb can only have one channel per category, so the same hub never
  -- appears twice in a user's locality list.
  UNIQUE (suburb, category)
);

CREATE INDEX IF NOT EXISTS idx_community_channels_suburb
  ON public.community_channels (suburb);

CREATE INDEX IF NOT EXISTS idx_community_channels_category
  ON public.community_channels (category);


-- =============================================================================
-- 3. CHANNEL MESSAGES TABLE
-- =============================================================================
-- All chatter inside a channel. event_timestamp is the only optional column —
-- it's populated when the message describes a timed community event
-- ("Saturday braai at the park, 14:00") so the UI can group event messages
-- on a calendar strip above the chat thread.
--
-- channel_id uses ON DELETE CASCADE — deleting a channel removes its messages
-- in a single statement. user_id uses ON DELETE SET NULL so the message
-- history is preserved even after a user deletes their account.
CREATE TABLE IF NOT EXISTS public.channel_messages (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id       uuid NOT NULL
                     REFERENCES public.community_channels(id) ON DELETE CASCADE,
  user_id          uuid
                     REFERENCES public.profiles(id) ON DELETE SET NULL,
  message_text     text NOT NULL CHECK (length(message_text) BETWEEN 1 AND 2000),
  event_timestamp  timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now()
);

-- Channel feed reads always slice by (channel_id ORDER BY created_at DESC).
CREATE INDEX IF NOT EXISTS idx_channel_messages_channel_recent
  ON public.channel_messages (channel_id, created_at DESC);

-- Calendar strip query: upcoming timed events inside a channel.
CREATE INDEX IF NOT EXISTS idx_channel_messages_events
  ON public.channel_messages (channel_id, event_timestamp)
  WHERE event_timestamp IS NOT NULL;


-- =============================================================================
-- 4. CROSS-TABLE FK — pinned_message_id → channel_messages(id)
-- =============================================================================
-- Added AFTER both tables exist so the soft cycle resolves cleanly.
-- ON DELETE SET NULL is the critical guarantee: when a pinned message gets
-- deleted (moderation action, user account wipe via CASCADE, etc.), the
-- channel row stays intact and simply reverts to "no pinned message".
-- This prevents the table-level locking / dependency block that ON DELETE
-- NO ACTION or CASCADE would create in this loop.
ALTER TABLE public.community_channels
  DROP CONSTRAINT IF EXISTS community_channels_pinned_message_fk;

ALTER TABLE public.community_channels
  ADD CONSTRAINT community_channels_pinned_message_fk
    FOREIGN KEY (pinned_message_id)
    REFERENCES public.channel_messages(id)
    ON DELETE SET NULL
    DEFERRABLE INITIALLY DEFERRED;   -- lets a single tx insert msg + pin together


-- =============================================================================
-- ROW-LEVEL SECURITY
-- =============================================================================
ALTER TABLE public.community_channels ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.channel_messages   ENABLE ROW LEVEL SECURITY;

-- ── community_channels ──────────────────────────────────────────────────────
-- Anyone authenticated can read the channel list (locality discovery).
CREATE POLICY community_channels_read_all ON public.community_channels
  FOR SELECT
  TO authenticated
  USING (true);

-- Only admins can create / rename / delete a channel OR change its pinned
-- message pointer. This is the RBAC linchpin.
CREATE POLICY community_channels_admin_write ON public.community_channels
  FOR ALL
  TO authenticated
  USING      (public.is_admin(auth.uid()))
  WITH CHECK (public.is_admin(auth.uid()));

-- ── channel_messages ────────────────────────────────────────────────────────
-- Read: any authenticated user can read any channel's history.
CREATE POLICY channel_messages_read_all ON public.channel_messages
  FOR SELECT
  TO authenticated
  USING (true);

-- Write (INSERT): users can only post AS themselves.
CREATE POLICY channel_messages_insert_self ON public.channel_messages
  FOR INSERT
  TO authenticated
  WITH CHECK (user_id = auth.uid());

-- Edit (UPDATE): only the original author may edit their own message text.
CREATE POLICY channel_messages_update_self ON public.channel_messages
  FOR UPDATE
  TO authenticated
  USING      (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

-- Delete: the author OR any admin (moderation override).
CREATE POLICY channel_messages_delete_self_or_admin ON public.channel_messages
  FOR DELETE
  TO authenticated
  USING (user_id = auth.uid() OR public.is_admin(auth.uid()));


-- =============================================================================
-- REALTIME — opt the new tables into Supabase's replication slot so the
-- Flutter client can subscribe to live message + pin updates.
-- =============================================================================
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND tablename = 'channel_messages'
  ) THEN
    EXECUTE 'ALTER PUBLICATION supabase_realtime ADD TABLE public.channel_messages';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND tablename = 'community_channels'
  ) THEN
    EXECUTE 'ALTER PUBLICATION supabase_realtime ADD TABLE public.community_channels';
  END IF;
END
$$;


-- =============================================================================
-- 5. SEED DATA — default local hubs for a couple of pilot suburbs
-- =============================================================================
-- Inserts the four core category channels for Parklands and Table View. The
-- UNIQUE (suburb, category) constraint + ON CONFLICT DO NOTHING make this
-- safe to re-run if the migration is replayed.
INSERT INTO public.community_channels (name, suburb, category) VALUES
  -- ── Parklands ───────────────────────────────────────────────────────────
  ('#Parklands-Spotted',     'Parklands',  'spotted'),
  ('#Parklands-Gatherings',  'Parklands',  'gatherings'),
  ('#Parklands-Pantry',      'Parklands',  'pantry'),
  ('#Parklands-Cooking',     'Parklands',  'cooking'),
  -- ── Table View ──────────────────────────────────────────────────────────
  ('#TableView-Spotted',     'Table View', 'spotted'),
  ('#TableView-Gatherings',  'Table View', 'gatherings'),
  ('#TableView-Pantry',      'Table View', 'pantry'),
  ('#TableView-Cooking',     'Table View', 'cooking')
ON CONFLICT (suburb, category) DO NOTHING;

COMMIT;

-- =============================================================================
-- ROLLBACK CHEAT-SHEET (run manually if this migration ever needs reverting):
-- =============================================================================
-- BEGIN;
--   ALTER TABLE public.community_channels DROP CONSTRAINT IF EXISTS community_channels_pinned_message_fk;
--   DROP TABLE IF EXISTS public.channel_messages   CASCADE;
--   DROP TABLE IF EXISTS public.community_channels CASCADE;
--   DROP FUNCTION IF EXISTS public.is_admin(uuid);
--   ALTER TABLE public.profiles DROP COLUMN IF EXISTS user_role;
-- COMMIT;
