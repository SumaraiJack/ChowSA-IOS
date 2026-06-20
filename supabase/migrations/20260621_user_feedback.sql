-- 20260621_user_feedback.sql
--
-- Help & Feedback sheet storage + automatic forwarding to support email.
--
-- Architecture:
--   1. Sheet inserts a row here.
--   2. AFTER INSERT trigger fires public.fire_feedback_email() which
--      pg_net.http_posts the row to the `send-feedback-email` Edge Function.
--   3. That function uses Resend to email the support inbox.
--
-- Same `app_settings` table + `app.edge_url` pattern we use for push
-- notifications, so deployment shape is identical.

create table if not exists public.user_feedback (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid references auth.users(id) on delete set null,
  user_email  text,
  user_handle text,
  category    text not null,
  message     text not null,
  created_at  timestamptz not null default now()
);

create index if not exists user_feedback_user_id_idx
  on public.user_feedback(user_id);

alter table public.user_feedback enable row level security;

-- Insert: any authenticated user can submit feedback for themselves.
drop policy if exists user_feedback_insert on public.user_feedback;
create policy user_feedback_insert
  on public.user_feedback for insert
  to authenticated
  with check (user_id = auth.uid());

-- Select: users can read their own rows (history view if we ever add one).
-- The service role bypasses RLS entirely for the email function.
drop policy if exists user_feedback_read_own on public.user_feedback;
create policy user_feedback_read_own
  on public.user_feedback for select
  to authenticated
  using (user_id = auth.uid());

-- ── Trigger → Edge Function ─────────────────────────────────────────────
create or replace function public.fire_feedback_email()
returns trigger
language plpgsql
security definer
set search_path = public, net
as $$
declare
  url    text;
  secret text;
begin
  select value into url
    from public.app_settings
   where key = 'feedback_email_url';
  select value into secret
    from public.app_settings
   where key = 'edge_secret';
  if url is null or url = '' then return new; end if;

  perform net.http_post(
    url     := url,
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer ' || coalesce(secret, '')
    ),
    body    := jsonb_build_object(
      'id',          new.id,
      'user_id',     new.user_id,
      'user_email',  new.user_email,
      'user_handle', new.user_handle,
      'category',    new.category,
      'message',     new.message,
      'created_at',  new.created_at
    )
  );
  return new;
end$$;

drop trigger if exists trg_fire_feedback_email on public.user_feedback;
create trigger trg_fire_feedback_email
  after insert on public.user_feedback
  for each row execute function public.fire_feedback_email();
