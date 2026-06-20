-- 20260629_wc_thesportsdb_sync.sql
--
-- World Cup live-score pipeline fixes (captures changes applied to live):
--
--   1. wc_matches.updated_at column — the sync edge function writes it; it was
--      missing, so every UPDATE failed with a schema-cache error.
--   2. wc_has_active_window() widened — the old version only opened while a
--      match was physically in progress, so finished matches that were never
--      synced (the cron used to 401) could never be backfilled. Now it opens
--      whenever any not-yet-finished match kicks off within the next 12h,
--      which keeps syncing until every played match is marked finished and
--      pre-warms upcoming ones, then idles.
--   3. wc_matches added to the realtime publication so score/status updates
--      push to the app's WorldCupService stream instantly (live ticker).
--
-- NOTE: the matching fix for the cron itself was redeploying the
-- `sync_wc_matches` edge function with verify_jwt = false (the platform JWT
-- gate was returning 401 before the function's own X-Edge-Secret check ran)
-- and switching its data source to TheSportsDB (free; API-Football's free plan
-- blocks the 2026 season). Those live in the function, not this migration.

alter table public.wc_matches add column if not exists updated_at timestamptz;

create or replace function public.wc_has_active_window()
returns boolean
language plpgsql
security definer
as $function$
begin
  return exists (
    select 1
    from public.wc_matches
    where status <> 'finished'
      and match_time <= now() + interval '12 hours'
  );
end;
$function$;

-- Add wc_matches to the realtime publication (idempotent guard).
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and tablename = 'wc_matches'
  ) then
    alter publication supabase_realtime add table public.wc_matches;
  end if;
end$$;
