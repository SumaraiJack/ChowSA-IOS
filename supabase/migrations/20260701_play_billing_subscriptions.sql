-- 20260701_play_billing_subscriptions.sql
--
-- Play Billing subscription tracking.
--
-- One row per active subscription per user. Acts as the audit trail for
-- entitlement: profiles.is_pro is derived from the most-recent row's
-- expiry_time + state. PayFast subs can live here too with platform='payfast'
-- so both purchase paths converge on one entitlement model.
--
-- Verification happens server-side in the verify_play_purchase edge function
-- — clients NEVER set is_pro directly. The edge function calls Google's
-- subscriptionsV2.get with our service-account credentials, then writes the
-- row and (re)computes profiles.is_pro.

create table if not exists public.subscriptions (
  id              uuid        primary key default gen_random_uuid(),
  user_id         uuid        not null references auth.users(id) on delete cascade,
  platform        text        not null check (platform in ('play_store','payfast')),
  product_id      text        not null,
  purchase_token  text        not null,
  base_plan_id    text,
  offer_id        text,
  start_time      timestamptz,
  expiry_time     timestamptz,
  auto_renewing   boolean     default true,
  state           text        not null default 'active',
  raw             jsonb,
  created_at      timestamptz default now(),
  updated_at      timestamptz default now()
);

create unique index if not exists subscriptions_purchase_token_uk
  on public.subscriptions (purchase_token);
create index if not exists subscriptions_user_id_idx
  on public.subscriptions (user_id);
create index if not exists subscriptions_active_idx
  on public.subscriptions (user_id, state, expiry_time desc);

alter table public.subscriptions enable row level security;

drop policy if exists subs_self_read on public.subscriptions;
create policy subs_self_read on public.subscriptions
  for select to authenticated using (auth.uid() = user_id);

create or replace function public.recompute_is_pro(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_is_pro boolean;
begin
  select exists (
    select 1
    from public.subscriptions
    where user_id = p_user_id
      and state in ('active','in_grace_period')
      and (expiry_time is null or expiry_time > now())
  ) into v_is_pro;

  update public.profiles set is_pro = v_is_pro where id = p_user_id;
end;
$$;

create or replace function public.subs_after_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.recompute_is_pro(coalesce(new.user_id, old.user_id));
  return null;
end;
$$;

drop trigger if exists trg_subs_after_change on public.subscriptions;
create trigger trg_subs_after_change
  after insert or update or delete on public.subscriptions
  for each row execute function public.subs_after_change();
