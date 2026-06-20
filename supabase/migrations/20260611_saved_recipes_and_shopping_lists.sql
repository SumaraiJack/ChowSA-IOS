-- =============================================================================
-- Migration: shopping_lists (and items)
-- =============================================================================
--
-- Two new tables backing the "Add to Shopping List" CTA on the generated
-- pantry recipe card:
--
--   • shopping_lists       — user-named lists (one row per list)
--   • shopping_list_items  — line items belonging to a list (FK on list_id)
--
-- The companion "Save Recipe" CTA writes to the EXISTING `recipes` table
-- via RecipeRepository.insert — no new recipe table is created here.
--
-- Idempotent — every CREATE uses IF NOT EXISTS.
-- =============================================================================

BEGIN;

-- ── 1. shopping_lists ───────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.shopping_lists (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL
                REFERENCES auth.users(id) ON DELETE CASCADE,
  name        text NOT NULL CHECK (length(name) BETWEEN 1 AND 120),
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_shopping_lists_user_created
  ON public.shopping_lists (user_id, created_at DESC);

ALTER TABLE public.shopping_lists ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS shopping_lists_self_select ON public.shopping_lists;
CREATE POLICY shopping_lists_self_select ON public.shopping_lists
  FOR SELECT TO authenticated
  USING (user_id = auth.uid());

DROP POLICY IF EXISTS shopping_lists_self_insert ON public.shopping_lists;
CREATE POLICY shopping_lists_self_insert ON public.shopping_lists
  FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS shopping_lists_self_update ON public.shopping_lists;
CREATE POLICY shopping_lists_self_update ON public.shopping_lists
  FOR UPDATE TO authenticated
  USING      (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS shopping_lists_self_delete ON public.shopping_lists;
CREATE POLICY shopping_lists_self_delete ON public.shopping_lists
  FOR DELETE TO authenticated
  USING (user_id = auth.uid());

-- ── 2. shopping_list_items ──────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.shopping_list_items (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  list_id    uuid NOT NULL
                REFERENCES public.shopping_lists(id) ON DELETE CASCADE,
  name       text NOT NULL CHECK (length(name) BETWEEN 1 AND 200),
  quantity   text,
  unit       text,
  checked    boolean NOT NULL DEFAULT false,
  position   int NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_shopping_list_items_list
  ON public.shopping_list_items (list_id, position, created_at);

ALTER TABLE public.shopping_list_items ENABLE ROW LEVEL SECURITY;

-- Item access is gated by ownership of the parent list — the EXISTS
-- subquery rides on shopping_lists' own RLS policies, so users can only
-- read/write items in lists they own.
DROP POLICY IF EXISTS shopping_list_items_via_list_select ON public.shopping_list_items;
CREATE POLICY shopping_list_items_via_list_select ON public.shopping_list_items
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.shopping_lists l
     WHERE l.id = shopping_list_items.list_id
       AND l.user_id = auth.uid()
  ));

DROP POLICY IF EXISTS shopping_list_items_via_list_insert ON public.shopping_list_items;
CREATE POLICY shopping_list_items_via_list_insert ON public.shopping_list_items
  FOR INSERT TO authenticated
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.shopping_lists l
     WHERE l.id = shopping_list_items.list_id
       AND l.user_id = auth.uid()
  ));

DROP POLICY IF EXISTS shopping_list_items_via_list_update ON public.shopping_list_items;
CREATE POLICY shopping_list_items_via_list_update ON public.shopping_list_items
  FOR UPDATE TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.shopping_lists l
     WHERE l.id = shopping_list_items.list_id
       AND l.user_id = auth.uid()
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.shopping_lists l
     WHERE l.id = shopping_list_items.list_id
       AND l.user_id = auth.uid()
  ));

DROP POLICY IF EXISTS shopping_list_items_via_list_delete ON public.shopping_list_items;
CREATE POLICY shopping_list_items_via_list_delete ON public.shopping_list_items
  FOR DELETE TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.shopping_lists l
     WHERE l.id = shopping_list_items.list_id
       AND l.user_id = auth.uid()
  ));

COMMIT;
