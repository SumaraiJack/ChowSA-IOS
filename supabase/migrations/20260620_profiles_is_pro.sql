-- 20260620_profiles_is_pro.sql
--
-- ChowSA Pro entitlement flag. Flipped to true by the payfast-webhook
-- Edge Function once an ITN is validated as paid + signed by PayFast.
-- Read by EntitlementService on the client to gate paywalled features.

alter table public.profiles
  add column if not exists is_pro          boolean      not null default false,
  add column if not exists pro_since       timestamptz,
  add column if not exists pro_payment_ref text;

comment on column public.profiles.is_pro          is 'True once PayFast ITN confirmed payment_status=COMPLETE.';
comment on column public.profiles.pro_since       is 'Timestamp of first successful PayFast payment.';
comment on column public.profiles.pro_payment_ref is 'PayFast pf_payment_id from the ITN — useful for support / refund lookups.';

-- RLS: users can already SELECT their own profile row via the existing
-- "see_own_profile" policy (auth.uid() = id). is_pro is part of that row,
-- so no new SELECT policy is needed.
--
-- CRITICAL: clients must NOT be able to UPDATE is_pro themselves — only
-- the webhook (running under the service-role key) sets it. Add a column-
-- level guard on UPDATE so even if a permissive update policy exists, the
-- is_pro / pro_since / pro_payment_ref columns are read-only to clients.

create or replace function public.profiles_block_pro_self_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Service role bypasses RLS entirely and runs as `service_role`, not
  -- `authenticated`, so we only guard authenticated callers.
  if current_setting('role', true) = 'authenticated' then
    if new.is_pro          is distinct from old.is_pro
       or new.pro_since       is distinct from old.pro_since
       or new.pro_payment_ref is distinct from old.pro_payment_ref then
      raise exception 'Pro entitlement columns are server-managed';
    end if;
  end if;
  return new;
end$$;

drop trigger if exists trg_profiles_block_pro_self_update on public.profiles;
create trigger trg_profiles_block_pro_self_update
  before update on public.profiles
  for each row execute function public.profiles_block_pro_self_update();
