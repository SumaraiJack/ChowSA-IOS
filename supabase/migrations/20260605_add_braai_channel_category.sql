-- Adds 'braai' to the list of allowed community channel categories so the
-- Local Braai Hub writes to its own dedicated channel instead of leaking
-- into the What's Cooking thread.

ALTER TABLE public.community_channels
  DROP CONSTRAINT IF EXISTS community_channels_category_check;

ALTER TABLE public.community_channels
  ADD CONSTRAINT community_channels_category_check
  CHECK (category IN ('spotted','gatherings','pantry','cooking','braai'));

-- Seed a braai channel for every suburb that already has at least one channel.
-- Mirrors the '#{Suburb}-Braai' naming convention used by the other seeds.
INSERT INTO public.community_channels (name, suburb, category)
SELECT
  '#' || regexp_replace(suburb, '\s+', '', 'g') || '-Braai' AS name,
  suburb,
  'braai'
FROM (SELECT DISTINCT suburb FROM public.community_channels) sub
ON CONFLICT (suburb, category) DO NOTHING;
