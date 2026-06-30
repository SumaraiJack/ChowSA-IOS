-- WS4: count of distinct users actively participating in a locality's
-- community channels. Drives the cold-start unlock gate on
-- CommunityHubScreen — below the threshold (kCommunityUnlockThreshold = 10
-- in Dart) the locality renders a friendly "coming to your area" state so
-- brand-new users never see empty channels.
--
-- "Active" === any user who has authored a channel_messages row in any
-- community_channels.suburb = $1. This mirrors PLAN.md §WS4 ("users who
-- have joined or posted in that locality") given there is no separate
-- members table — posting *is* the join signal.
--
-- SECURITY DEFINER so the count works regardless of RLS on channel_messages
-- (a viewer in a different locality still gets an honest count without
-- being able to read the underlying messages).

create or replace function public.get_locality_active_count(p_suburb text)
returns int
language sql
security definer
set search_path = public
stable
as $$
  select count(distinct cm.user_id)::int
    from public.channel_messages cm
    join public.community_channels cc on cc.id = cm.channel_id
   where cc.suburb = p_suburb;
$$;

revoke all on function public.get_locality_active_count(text) from public;
grant execute on function public.get_locality_active_count(text)
  to authenticated, anon;

comment on function public.get_locality_active_count(text) is
  'WS4 cold-start gate: distinct authors who have posted in any channel '
  'for the given suburb. Used to decide whether to unlock the local '
  'channel set or render the "coming to your area" placeholder.';
