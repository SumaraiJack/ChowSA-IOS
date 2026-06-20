-- ChowSA: post_reports table
-- Run this in: Supabase Dashboard → SQL Editor → New Query → paste + Run

create table if not exists public.post_reports (
  id           uuid primary key default gen_random_uuid(),
  post_id      text not null,
  reporter_id  uuid references auth.users(id) on delete set null,
  reason       text not null default 'Community report',
  reported_at  timestamptz not null default now(),
  reviewed     boolean not null default false,
  reviewed_by  uuid references auth.users(id) on delete set null,
  reviewed_at  timestamptz
);

create index if not exists post_reports_post_id_idx  on public.post_reports(post_id);
create index if not exists post_reports_reviewed_idx on public.post_reports(reviewed);

alter table public.post_reports enable row level security;

-- Any logged-in user can submit a report
create policy "Users can report posts"
  on public.post_reports for insert
  to authenticated
  with check (true);

-- Only users with role=admin in their metadata can read reports
create policy "Admins can view reports"
  on public.post_reports for select
  to authenticated
  using (
    (select raw_user_meta_data->>'role'
     from auth.users
     where id = auth.uid()) = 'admin'
  );
