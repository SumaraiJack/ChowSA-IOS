-- =============================================================================
-- Migration: braai_events — Bring & Braai planner schema
-- =============================================================================

-- ── braai_events ─────────────────────────────────────────────────────────────
-- One row per Bring & Braai event created by a user.
CREATE TABLE IF NOT EXISTS public.braai_events (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  creator_id  uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  title       text NOT NULL,
  location    text,
  date_time   timestamptz NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);

-- ── braai_items ──────────────────────────────────────────────────────────────
-- Items on the "what to bring" checklist for an event.
-- A user "claims" an item by setting brought_by_user_id.
-- They describe their exact contribution in exact_contribution.
CREATE TABLE IF NOT EXISTS public.braai_items (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id             uuid NOT NULL REFERENCES public.braai_events(id) ON DELETE CASCADE,
  item_name            text NOT NULL,
  target_quantity      text,                -- e.g. "6 cans", "2 kg"
  brought_by_user_id   uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  brought_by_handle    text,               -- denormalised for display without join
  exact_contribution   text,               -- user-edited: "6 Castle Lites", "4 T-Bone Chops"
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now()
);

-- ── braai_rsvps ──────────────────────────────────────────────────────────────
-- Tracks who has been invited and their RSVP status.
CREATE TABLE IF NOT EXISTS public.braai_rsvps (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id   uuid NOT NULL REFERENCES public.braai_events(id) ON DELETE CASCADE,
  user_id    uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  status     text NOT NULL DEFAULT 'pending'   -- 'pending' | 'accepted' | 'declined'
             CHECK (status IN ('pending', 'accepted', 'declined')),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (event_id, user_id)
);

-- ── notifications ─────────────────────────────────────────────────────────────
-- Generic inbox; braai invitations land here with type = 'braai_invite'.
CREATE TABLE IF NOT EXISTS public.notifications (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  recipient_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  sender_id    uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  type         text NOT NULL,                   -- 'braai_invite' | etc.
  payload      jsonb NOT NULL DEFAULT '{}',     -- { event_id, event_title, rsvp_id }
  is_read      boolean NOT NULL DEFAULT false,
  created_at   timestamptz NOT NULL DEFAULT now()
);

-- ── Indexes ───────────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_braai_items_event_id
  ON public.braai_items (event_id);

CREATE INDEX IF NOT EXISTS idx_braai_rsvps_user_id
  ON public.braai_rsvps (user_id);

CREATE INDEX IF NOT EXISTS idx_notifications_recipient_unread
  ON public.notifications (recipient_id, is_read)
  WHERE is_read = false;

-- ── updated_at auto-stamp trigger for braai_items ─────────────────────────────
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS braai_items_updated_at ON public.braai_items;
CREATE TRIGGER braai_items_updated_at
  BEFORE UPDATE ON public.braai_items
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ── Row-Level Security ────────────────────────────────────────────────────────
ALTER TABLE public.braai_events  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.braai_items   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.braai_rsvps   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

-- braai_events: creator can do everything; invited users can read their events
CREATE POLICY braai_events_creator ON public.braai_events
  FOR ALL USING (auth.uid() = creator_id);

CREATE POLICY braai_events_invited_read ON public.braai_events
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.braai_rsvps r
      WHERE r.event_id = id AND r.user_id = auth.uid()
    )
  );

-- braai_items: visible to event creator + accepted/pending RSVPs
CREATE POLICY braai_items_event_members ON public.braai_items
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM public.braai_events e
      WHERE e.id = event_id AND e.creator_id = auth.uid()
    )
    OR
    EXISTS (
      SELECT 1 FROM public.braai_rsvps r
      WHERE r.event_id = event_id AND r.user_id = auth.uid()
    )
  );

-- braai_rsvps: creator manages; invitee can update their own row
CREATE POLICY braai_rsvps_all ON public.braai_rsvps
  FOR ALL USING (
    user_id = auth.uid()
    OR EXISTS (
      SELECT 1 FROM public.braai_events e
      WHERE e.id = event_id AND e.creator_id = auth.uid()
    )
  );

-- notifications: each user sees only their own
CREATE POLICY notifications_recipient ON public.notifications
  FOR ALL USING (recipient_id = auth.uid());
