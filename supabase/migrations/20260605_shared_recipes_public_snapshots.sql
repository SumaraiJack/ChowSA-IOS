-- Public snapshot table for recipes shared into community channels. Every
-- authenticated user can read any row (so chat viewers can open shared
-- recipes), but only the original sharer can write the row.
--
-- This decouples sharing from the private `recipes` table, which is locked
-- to its owner by RLS. The chat carries a `[shared_recipe:<id>]` marker
-- that points back to a row here.

CREATE TABLE IF NOT EXISTS public.shared_recipes (
  id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shared_by                 uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  title                     text NOT NULL,
  ingredients               jsonb NOT NULL DEFAULT '[]'::jsonb,
  instructions              jsonb NOT NULL DEFAULT '[]'::jsonb,
  is_loadshedding_friendly  boolean NOT NULL DEFAULT false,
  is_braai_ready            boolean NOT NULL DEFAULT false,
  source_url                text,
  created_at                timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_shared_recipes_shared_by
  ON public.shared_recipes (shared_by);

ALTER TABLE public.shared_recipes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS shared_recipes_read_all ON public.shared_recipes;
CREATE POLICY shared_recipes_read_all
  ON public.shared_recipes
  FOR SELECT
  TO authenticated
  USING (true);

DROP POLICY IF EXISTS shared_recipes_insert_self ON public.shared_recipes;
CREATE POLICY shared_recipes_insert_self
  ON public.shared_recipes
  FOR INSERT
  TO authenticated
  WITH CHECK (auth.uid() = shared_by);

DROP POLICY IF EXISTS shared_recipes_delete_self ON public.shared_recipes;
CREATE POLICY shared_recipes_delete_self
  ON public.shared_recipes
  FOR DELETE
  TO authenticated
  USING (auth.uid() = shared_by);
