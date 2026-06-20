-- ============================================================
-- ChowSA — Community post images setup
-- Run this in: Supabase Dashboard → SQL Editor → paste → Run
-- ============================================================

-- 1. Add image_url column to community_posts (if not already there)
alter table public.community_posts
  add column if not exists image_url text;

-- 2. Create the 'posts' storage bucket (public so images load without signing)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'posts',
  'posts',
  true,
  5242880,  -- 5 MB max per image
  array['image/jpeg','image/png','image/webp','image/heic']
)
on conflict (id) do update set
  public             = true,
  file_size_limit    = 5242880,
  allowed_mime_types = array['image/jpeg','image/png','image/webp','image/heic'];

-- 3. RLS: authenticated users can upload to posts/ prefix
create policy "Authenticated users can upload posts"
  on storage.objects for insert
  to authenticated
  with check (bucket_id = 'posts');

-- 4. RLS: everyone can view/download post images (bucket is public)
create policy "Anyone can view post images"
  on storage.objects for select
  to public
  using (bucket_id = 'posts');

-- 5. RLS: users can only delete their own post images
create policy "Users can delete own post images"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'posts'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
