-- 20260625_wc_sync_no_vault.sql
--
-- Vault-free rewrite of the World Cup sync cron tick.
--
-- The dashboard SQL editor was throwing 42501 on `vault.secrets`, so this
-- migration removes every vault read/write from the wiring and bakes the
-- function URL + gating secret straight into `wc_sync_tick()`. The cron
-- schedule and the active-window predicate are unchanged.
--
-- ── BEFORE APPLYING ─────────────────────────────────────────────────────
-- Edit the two REPLACE_ME_* constants below to your real values:
--   • REPLACE_ME_FN_URL      → https://<project-ref>.functions.supabase.co/sync_wc_matches
--   • REPLACE_ME_EDGE_SECRET → same string you set as the function's
--                              WC_SYNC_EDGE_SECRET env var
-- ─────────────────────────────────────────────────────────────────────────

-- Belt-and-suspenders — these are idempotent if the prior migration ran.
create extension if not exists pg_cron with schema extensions;
create extension if not exists pg_net  with schema extensions;

-- Active-window predicate stays as-is. Recreated here so this migration
-- can be applied standalone on a project that never had 20260623 run.
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

-- ── Cron tick — inline URL + secret, no vault ─────────────────────────
--
-- Sends the gating token as the `X-Edge-Secret` header so the edge
-- function can authenticate without parsing a bearer scheme.

create or replace function public.wc_sync_tick()
  returns void
  language plpgsql
  security definer
  set search_path = public
as $$
declare
  v_url    constant text := 'REPLACE_ME_FN_URL';
  v_secret constant text := 'REPLACE_ME_EDGE_SECRET';
  v_request_id bigint;
begin
  if not public.wc_has_active_window() then
    return;                        -- no live match — silent exit
  end if;

  -- Refuse to call out while either constant is still a placeholder so
  -- a half-applied migration can't spam junk requests at the function.
  if v_url like '%REPLACE_ME%' or v_secret like '%REPLACE_ME%' then
    raise notice 'wc_sync_tick skipped — inline url/secret still placeholder';
    return;
  end if;

  select net.http_post(
           url     := v_url,
           headers := jsonb_build_object(
             'Content-Type',  'application/json',
             'X-Edge-Secret', v_secret
           ),
           body    := '{}'::jsonb
         )
    into v_request_id;
end$$;

revoke all on function public.wc_sync_tick() from public;
grant  execute on function public.wc_sync_tick() to postgres;

-- ── Schedule (re)registration ─────────────────────────────────────────
-- Unschedule any stale `wc_sync_15m` registration first so re-running
-- this migration doesn't accumulate duplicate timers.

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
  'wc_sync_15m',
  '*/15 * * * *',
  $cron$ select public.wc_sync_tick(); $cron$
);
