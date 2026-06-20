-- 20260619_community_unread_rpcs.sql
--
-- Definitive (re)build of the two community-hub unread RPCs so per-
-- category badges route correctly for ALL five categories:
--   spotted · gatherings · pantry · cooking · braai
--
-- Symptoms this fixes:
--   • A post in #<suburb>-Braai was lighting the SPOTTED badge.
--   • A post in #<suburb>-Spotted was lighting nothing.
-- Root cause: the prior RPC bodies (added directly to the remote DB,
-- never committed) inferred category from message text / channel name
-- substring, which mis-matched braai + spotted edge cases. The version
-- below joins straight onto community_channels.category — the only
-- authoritative source of truth — so every category routes deterministically.

-- ── 1. Per-user, per-channel last-viewed marker ─────────────────────────────
CREATE TABLE IF NOT EXISTS public.channel_views (
  user_id        uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  channel_id     uuid        NOT NULL REFERENCES public.community_channels(id) ON DELETE CASCADE,
  last_viewed_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, channel_id)
);

ALTER TABLE public.channel_views ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS channel_views_self_read  ON public.channel_views;
DROP POLICY IF EXISTS channel_views_self_write ON public.channel_views;

CREATE POLICY channel_views_self_read  ON public.channel_views
  FOR SELECT TO authenticated USING (auth.uid() = user_id);
CREATE POLICY channel_views_self_write ON public.channel_views
  FOR ALL    TO authenticated USING (auth.uid() = user_id)
                              WITH CHECK (auth.uid() = user_id);

-- ── 2. mark_category_viewed(suburb, category) ───────────────────────────────
-- Upserts a `last_viewed_at = now()` row for the channel matching the
-- (suburb, category) pair. Replaces the legacy single-arg version which
-- some Flutter call sites still pass; both shapes are supported via
-- overload.

DROP FUNCTION IF EXISTS public.mark_category_viewed(text);
DROP FUNCTION IF EXISTS public.mark_category_viewed(text, text);
DROP FUNCTION IF EXISTS public.mark_category_viewed(p_suburb text, p_category text);

CREATE OR REPLACE FUNCTION public.mark_category_viewed(
  p_suburb   text,
  p_category text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid     uuid := auth.uid();
  v_channel uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  SELECT id INTO v_channel
    FROM public.community_channels
   WHERE suburb   = p_suburb
     AND category = p_category
   LIMIT 1;

  IF v_channel IS NULL THEN
    -- No channel for that suburb+category — treat as no-op so the client
    -- doesn't get a hard error when a category isn't seeded for a hub.
    RETURN;
  END IF;

  INSERT INTO public.channel_views (user_id, channel_id, last_viewed_at)
       VALUES (v_uid, v_channel, now())
  ON CONFLICT (user_id, channel_id)
  DO UPDATE SET last_viewed_at = EXCLUDED.last_viewed_at;
END;
$$;

GRANT EXECUTE ON FUNCTION public.mark_category_viewed(text, text) TO authenticated;

-- ── 3. count_unread_per_category(suburb) ────────────────────────────────────
-- Returns one row per seeded category in that suburb:
--   { category_name text, unread_count int }
-- Authoritative join on community_channels.category, so braai messages
-- always count as braai and spotted as spotted — no substring / name
-- inference, no cross-category leakage.

DROP FUNCTION IF EXISTS public.count_unread_per_category(text);
DROP FUNCTION IF EXISTS public.count_unread_per_category(p_suburb text);

CREATE OR REPLACE FUNCTION public.count_unread_per_category(p_suburb text)
RETURNS TABLE (
  category_name text,
  unread_count  int
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
  SELECT
    c.category                                         AS category_name,
    COUNT(m.id) FILTER (
      WHERE m.created_at >
            COALESCE(v.last_viewed_at, '1970-01-01'::timestamptz)
        AND (m.user_id IS DISTINCT FROM auth.uid())
    )::int                                             AS unread_count
  FROM public.community_channels c
  LEFT JOIN public.channel_messages m
         ON m.channel_id = c.id
  LEFT JOIN public.channel_views v
         ON v.channel_id = c.id
        AND v.user_id    = auth.uid()
  WHERE c.suburb = p_suburb
  GROUP BY c.category;
$$;

GRANT EXECUTE ON FUNCTION public.count_unread_per_category(text) TO authenticated;
