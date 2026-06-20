-- =============================================================================
-- Migration: smart_suggestions_engine
-- =============================================================================
--
-- Tables / changes powering the Smart Suggestions Engine — exclusive AI
-- meal-idea generator for one user (Melrose) that shares approved meals
-- with her linked partner (SumaraiJack) in real time.
--
-- Changes:
--   • profiles.partner_id     — one-sided self-ref FK. Melrose's row points
--                                at Sumarai. Sumarai's listener filters
--                                "any profile where partner_id = my id".
--   • profiles.feature_flags  — jsonb feature gate. Smart Suggestions UI is
--                                only rendered when feature_flags->>'smart_
--                                suggestions' = 'true'. Toggle per user
--                                from the Supabase dashboard — no client
--                                build needed.
--   • weekly_planner          — Melrose's approved AI meal ideas. Owner can
--                                read/write; linked partner can read only.
--                                Added to supabase_realtime so Sumarai's
--                                .stream() pushes updates instantly.
--
-- No new shopping_history table — the top-ingredients aggregation reads
-- directly from shopping_list_items joined to shopping_lists.
--
-- Idempotent — safe to re-run.
-- =============================================================================

BEGIN;

-- ── 1. profiles.partner_id + feature_flags ──────────────────────────────────
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS partner_id    uuid REFERENCES public.profiles(id)
                              ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS feature_flags jsonb NOT NULL DEFAULT '{}'::jsonb;

-- Fast lookup for "who is partnered to me" (Sumarai's listener path).
CREATE INDEX IF NOT EXISTS idx_profiles_partner
  ON public.profiles (partner_id)
  WHERE partner_id IS NOT NULL;

COMMENT ON COLUMN public.profiles.partner_id    IS
  'One-sided partner link. Owner reads partner-shared data by following '
  'this FK; partner reads owner-shared data by querying profiles where '
  'partner_id = auth.uid().';
COMMENT ON COLUMN public.profiles.feature_flags IS
  'Per-user feature gates. Smart Suggestions reads '
  '`feature_flags->>''smart_suggestions''` and renders only when "true".';

-- ── 2. weekly_planner ───────────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_type WHERE typname = 'meal_slot_kind'
  ) THEN
    CREATE TYPE public.meal_slot_kind AS ENUM ('breakfast', 'lunch', 'supper');
  END IF;
END$$;

CREATE TABLE IF NOT EXISTS public.weekly_planner (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id            uuid NOT NULL
                       REFERENCES auth.users(id) ON DELETE CASCADE,
  meal_slot          public.meal_slot_kind NOT NULL,
  title              text NOT NULL CHECK (length(title) BETWEEN 1 AND 160),
  summary            text,
  ingredients        jsonb NOT NULL DEFAULT '[]'::jsonb,
  instructions       jsonb NOT NULL DEFAULT '[]'::jsonb,
  source_ingredients jsonb NOT NULL DEFAULT '[]'::jsonb,  -- top ingredients fed to the AI
  suggested_for      date,                                 -- optional target day
  created_at         timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_weekly_planner_user_recent
  ON public.weekly_planner (user_id, created_at DESC);

ALTER TABLE public.weekly_planner ENABLE ROW LEVEL SECURITY;

-- ── Owner policies (full read/write of own rows) ────────────────────────────
DROP POLICY IF EXISTS weekly_planner_owner_select ON public.weekly_planner;
CREATE POLICY weekly_planner_owner_select ON public.weekly_planner
  FOR SELECT TO authenticated
  USING (user_id = auth.uid());

DROP POLICY IF EXISTS weekly_planner_owner_insert ON public.weekly_planner;
CREATE POLICY weekly_planner_owner_insert ON public.weekly_planner
  FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS weekly_planner_owner_update ON public.weekly_planner;
CREATE POLICY weekly_planner_owner_update ON public.weekly_planner
  FOR UPDATE TO authenticated
  USING      (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS weekly_planner_owner_delete ON public.weekly_planner;
CREATE POLICY weekly_planner_owner_delete ON public.weekly_planner
  FOR DELETE TO authenticated
  USING (user_id = auth.uid());

-- ── Partner policy (read-only — partner sees owner's rows) ──────────────────
-- "I can see this row if I am the partner of the row's owner."
-- Looks up profiles.partner_id of the row owner; if it equals auth.uid()
-- then the row is visible. Read-only by design.
DROP POLICY IF EXISTS weekly_planner_partner_select ON public.weekly_planner;
CREATE POLICY weekly_planner_partner_select ON public.weekly_planner
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1
      FROM public.profiles p
     WHERE p.id         = weekly_planner.user_id
       AND p.partner_id = auth.uid()
  ));

-- ── 3. Realtime publication ─────────────────────────────────────────────────
-- Required so Sumarai's `.stream()` listener pushes INSERT/UPDATE events
-- the moment Melrose approves a meal. Idempotent guard.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
      FROM pg_publication_tables
     WHERE pubname    = 'supabase_realtime'
       AND tablename  = 'weekly_planner'
  ) THEN
    EXECUTE 'ALTER PUBLICATION supabase_realtime ADD TABLE public.weekly_planner';
  END IF;
END$$;

COMMIT;
