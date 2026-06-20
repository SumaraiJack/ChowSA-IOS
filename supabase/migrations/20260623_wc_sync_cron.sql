-- 20260623_wc_sync_cron.sql
--
-- Server-side World Cup result sync schedule.
--
-- What this migration does:
--   1. Enables pg_cron + pg_net (idempotent — `create extension if not exists`).
--   2. Seeds vault entries for the upstream feed URL and key. The function
--      reads from `vault.decrypted_secrets`, so rotating the upstream is
--      a one-row UPDATE in the dashboard, no redeploy.
--   3. Registers an active-window-gated cron job that:
--        • Fires every 15 minutes.
--        • Returns immediately if no match is "live" (kickoff ≤ now ≤
--          kickoff + 2h30m). Cheap predicate — wc_matches is small.
--        • Otherwise POSTs to the sync_wc_matches edge function with the
--          shared edge secret in the Authorization header.
--
-- The window check runs ENTIRELY inside Postgres before any HTTP work,
-- so an idle tournament never hits the network at all.

-- ── 1. Extensions ────────────────────────────────────────────────────────

create extension if not exists pg_cron with schema extensions;
create extension if not exists pg_net  with schema extensions;
create extension if not exists supabase_vault;

-- ── 2. Vault — upstream URL, upstream key, edge secret ───────────────────
--
-- Idempotent seed: insert when absent, otherwise leave the existing value
-- in place so a rotated key survives a re-run of the migration.

do $$
begin
  if not exists (select 1 from vault.secrets where name = 'wc_feed_url') then
    perform vault.create_secret(
      'https://worldcup26.ir/get/games',
      'wc_feed_url',
      'Upstream World Cup fixture/results feed.'
    );
  end if;

  if not exists (select 1 from vault.secrets where name = 'wc_feed_key') then
    perform vault.create_secret(
      '',                                              -- empty until provisioned
      'wc_feed_key',
      'Optional API key for the upstream WC feed.'
    );
  end if;

  if not exists (select 1 from vault.secrets where name = 'wc_sync_edge_secret') then
    perform vault.create_secret(
      encode(gen_random_bytes(32), 'hex'),
      'wc_sync_edge_secret',
      'Bearer token shared between pg_cron and sync_wc_matches edge fn.'
    );
  end if;

  if not exists (select 1 from vault.secrets where name = 'wc_sync_fn_url') then
    perform vault.create_secret(
      'https://REPLACE-PROJECT-REF.functions.supabase.co/sync_wc_matches',
      'wc_sync_fn_url',
      'Public URL of the sync_wc_matches edge function. UPDATE me with the real project ref before unscheduling the placeholder.'
    );
  end if;
end$$;

-- ── 3. Active-window predicate ───────────────────────────────────────────
--
-- True when ANY wc_matches row has a kickoff that falls inside the live
-- window: kickoff ≤ now ≤ kickoff + 2h30m. The job exits silently when
-- this returns false, so the upstream feed is hit zero times during the
-- months between fixtures.

create or replace function public.wc_has_active_window()
  returns boolean
  language sql
  stable
  security definer
  set search_path = public
as $$
  select exists (
    select 1
      from public.wc_matches
     where status <> 'finished'
       and match_time <= now()
       and match_time + interval '2 hours 30 minutes' >= now()
  );
$$;

revoke all on function public.wc_has_active_window() from public;
grant  execute on function public.wc_has_active_window() to postgres;

-- ── 4. Trigger procedure ─────────────────────────────────────────────────
--
-- Reads the URL + secret from vault each tick so a key rotation takes
-- effect on the very next run without restarting cron. Failing fast on a
-- missing URL keeps placeholder deployments from spamming junk requests.

create or replace function public.wc_sync_tick()
  returns void
  language plpgsql
  security definer
  set search_path = public
as $$
declare
  v_url     text;
  v_secret  text;
  v_request_id bigint;
begin
  if not public.wc_has_active_window() then
    return;                       -- no live match — silent exit
  end if;

  select decrypted_secret into v_url
    from vault.decrypted_secrets
   where name = 'wc_sync_fn_url'
   limit 1;

  select decrypted_secret into v_secret
    from vault.decrypted_secrets
   where name = 'wc_sync_edge_secret'
   limit 1;

  if v_url is null or v_url like '%REPLACE-PROJECT-REF%' then
    raise notice 'wc_sync_tick skipped — wc_sync_fn_url not provisioned';
    return;
  end if;

  select net.http_post(
           url     := v_url,
           headers := jsonb_build_object(
             'Content-Type',  'application/json',
             'Authorization', 'Bearer ' || coalesce(v_secret, '')
           ),
           body    := '{}'::jsonb
         )
    into v_request_id;
end$$;

revoke all on function public.wc_sync_tick() from public;
grant  execute on function public.wc_sync_tick() to postgres;

-- ── 5. Cron job ──────────────────────────────────────────────────────────
--
-- Unschedule any stale registration first so re-running this migration
-- doesn't accumulate duplicate timers.

do $$
declare
  jid bigint;
begin
  for jid in select jobid from cron.job where jobname = 'wc_sync_15m'
  loop
    perform cron.unschedule(jid);
  end loop;
end$$;

select cron.schedule(
  'wc_sync_15m',                  -- job name
  '*/15 * * * *',                 -- every 15 minutes
  $cron$ select public.wc_sync_tick(); $cron$
);
