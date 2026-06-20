-- =============================================================================
-- Migration: recipes_loadshedding_braai
--
-- Adds the missing is_loadshedding_friendly and is_braai_ready columns to the
-- recipes table. Both default to false so existing rows remain valid with no
-- backfill, and INSERT statements from the Dart client no longer crash with
-- "could not find the column in the schema cache".
-- =============================================================================

ALTER TABLE public.recipes
  ADD COLUMN IF NOT EXISTS is_loadshedding_friendly boolean NOT NULL DEFAULT false;

ALTER TABLE public.recipes
  ADD COLUMN IF NOT EXISTS is_braai_ready boolean NOT NULL DEFAULT false;

-- ── Comments ──────────────────────────────────────────────────────────────────
COMMENT ON COLUMN public.recipes.is_loadshedding_friendly IS
  'True when the recipe can be prepared without mains electricity '
  '(raw/cold, braai, gas hob, skottel, potjie).';

COMMENT ON COLUMN public.recipes.is_braai_ready IS
  'True only when the cooking method explicitly uses a braai grid, '
  'kettle braai, potjie pot, skottel, or open fire/coals.';
