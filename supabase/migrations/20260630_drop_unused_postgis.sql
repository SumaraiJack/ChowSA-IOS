-- 20260630_drop_unused_postgis.sql
--
-- Supabase Security Advisor flagged public.spatial_ref_sys (PostGIS system
-- table) for RLS-disabled. The table is owned by the postgis extension so
-- we can't enable RLS on it directly.
--
-- ChowSA stores every location as plain double-precision latitude/longitude
-- columns (channel_messages, community_posts, hubs) — no geometry/geography
-- columns anywhere — so PostGIS is genuinely unused. Dropping the extension
-- removes spatial_ref_sys and clears the warning. If spatial queries are ever
-- needed later, re-add the extension into a dedicated `extensions` schema
-- where the linter won't flag it.

drop extension if exists postgis cascade;
