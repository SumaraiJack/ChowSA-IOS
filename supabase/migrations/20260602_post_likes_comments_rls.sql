-- =============================================================================
-- Migration: post_likes / post_comments RLS policies
-- =============================================================================
--
-- RLS has been enabled on both tables in Supabase but no policies exist yet —
-- which means every read and write is currently denied. This migration adds
-- the standard four-policy set used everywhere else in ChowSA:
--
--   SELECT — any authenticated user can read (the community feed is shared).
--   INSERT — you can only create rows attributed to your own auth.uid().
--   UPDATE — comments only: author may edit their own body. Likes are
--            toggle-only (insert/delete) so they need no UPDATE policy.
--   DELETE — you can take back your own like / delete your own comment.
--
-- ENABLE ROW LEVEL SECURITY statements are idempotent — re-running them on
-- already-enabled tables is a no-op, so this migration is safe to replay.
-- =============================================================================

BEGIN;

ALTER TABLE public.post_likes    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.post_comments ENABLE ROW LEVEL SECURITY;

-- ── post_likes ──────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS post_likes_read_all      ON public.post_likes;
DROP POLICY IF EXISTS post_likes_insert_self   ON public.post_likes;
DROP POLICY IF EXISTS post_likes_delete_self   ON public.post_likes;

CREATE POLICY post_likes_read_all ON public.post_likes
  FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY post_likes_insert_self ON public.post_likes
  FOR INSERT
  TO authenticated
  WITH CHECK (user_id = auth.uid());

CREATE POLICY post_likes_delete_self ON public.post_likes
  FOR DELETE
  TO authenticated
  USING (user_id = auth.uid());

-- No UPDATE policy: a like is a toggle, never edited in place.

-- ── post_comments ───────────────────────────────────────────────────────────

DROP POLICY IF EXISTS post_comments_read_all     ON public.post_comments;
DROP POLICY IF EXISTS post_comments_insert_self  ON public.post_comments;
DROP POLICY IF EXISTS post_comments_update_self  ON public.post_comments;
DROP POLICY IF EXISTS post_comments_delete_self  ON public.post_comments;

CREATE POLICY post_comments_read_all ON public.post_comments
  FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY post_comments_insert_self ON public.post_comments
  FOR INSERT
  TO authenticated
  WITH CHECK (user_id = auth.uid());

CREATE POLICY post_comments_update_self ON public.post_comments
  FOR UPDATE
  TO authenticated
  USING      (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

CREATE POLICY post_comments_delete_self ON public.post_comments
  FOR DELETE
  TO authenticated
  USING (user_id = auth.uid());

COMMIT;
