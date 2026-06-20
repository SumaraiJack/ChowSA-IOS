-- 20260624_wc_sync_inline_secret.sql
--
-- Follow-up to 20260623_wc_sync_cron.sql.
--
-- The dashboard SQL editor is throwing 42501 against `vault.secrets`
-- (the postgres role can't write to the vault table directly), which
-- blocks the per-project provisioning step. This migration drops the
-- vault dependency from the cron tick and bakes the function URL +
-- bearer secret straight into the SQL function body.
--
-- The active-window predicate `wc_has_active_window()` is unchanged.
-- The cron job entry itself is unchanged — it still points at
-- `public.wc_sync_tick()`; we're just rewriting that function's body.
--
-- ── BEFORE APPLYING ─────────────────────────────────────────────────────
-- Edit the two REPLACE_ME_* constants below to your real values:
--   • REPLACE_ME_FN_URL      → https://<project-ref>.functions.supabase.co/sync_wc_matches
--   • REPLACE_ME_EDGE_SECRET → the same hex string you set via
--                              `supabase secrets set WC_SYNC_EDGE_SECRET=…`
-- ─────────────────────────────────────────────────────────────────────────

create or replace function public.wc_sync_tick()
  returns void
  language plpgsql
  security definer
  set search_path = public
as $$
declare
  -- ── Inline configuration ──────────────────────────────────────────
  -- Replace both literals before deploying. Re-running this migration
  -- swaps them in place; the cron schedule keeps firing without
  -- needing an unschedule/reschedule.
  v_url    constant text := 'REPLACE_ME_FN_URL';
  v_secret constant text := 'REPLACE_ME_EDGE_SECRET';
  v_request_id bigint;
begin
  if not public.wc_has_active_window() then
    return;                        -- no live match — silent exit
  end if;

  if v_url like '%REPLACE_ME%' or v_secret like '%REPLACE_ME%' then
    raise notice 'wc_sync_tick skipped — inline url/secret still placeholder';
    return;
  end if;

  select net.http_post(
           url     := v_url,
           headers := jsonb_build_object(
             'Content-Type',  'application/json',
             'Authorization', 'Bearer ' || v_secret
           ),
           body    := '{}'::jsonb
         )
    into v_request_id;
end$$;

revoke all on function public.wc_sync_tick() from public;
grant  execute on function public.wc_sync_tick() to postgres;
