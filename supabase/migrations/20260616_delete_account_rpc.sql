-- 20260616_delete_account_rpc.sql
--
-- POPIA right-to-be-forgotten: server-side RPC that fully removes the
-- calling user's auth row and (by cascade) every app table FK'd to it.
--
-- Why an RPC, not the JS admin SDK:
--   `supabase.auth.admin.deleteUser(...)` requires the service-role key,
--   which we cannot embed in a mobile client. A SECURITY DEFINER function
--   running as a privileged role lets the client call it under their own
--   JWT — the function itself reads auth.uid() and only ever deletes that
--   one row, so a malicious caller can't widen the blast radius.
--
-- Tables that FK auth.users ON DELETE CASCADE will be wiped automatically.
-- We additionally hard-delete a few app rows whose FK might be SET NULL or
-- which aren't directly tied to auth.users, so nothing is left orphaned.

create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'Not authenticated';
  end if;

  -- Best-effort cleanup of app tables that may not cascade. Each delete is
  -- guarded so a missing table (older project, dev branch, etc.) doesn't
  -- abort the whole transaction — the auth.users delete at the end is the
  -- POPIA-critical step.
  begin delete from public.profiles                where id      = uid; exception when undefined_table then null; end;
  begin delete from public.saved_recipes           where user_id = uid; exception when undefined_table then null; end;
  begin delete from public.shopping_lists          where user_id = uid; exception when undefined_table then null; end;
  begin delete from public.shopping_list_shares    where owner_id = uid or shared_with = uid; exception when undefined_table then null; end;
  begin delete from public.pantry_items            where user_id = uid; exception when undefined_table then null; end;
  begin delete from public.recipes                 where user_id = uid; exception when undefined_table then null; end;
  begin delete from public.community_posts         where author_id = uid; exception when undefined_table then null; end;
  begin delete from public.post_likes              where user_id = uid; exception when undefined_table then null; end;
  begin delete from public.post_comments           where user_id = uid; exception when undefined_table then null; end;
  begin delete from public.post_reports            where reporter_id = uid; exception when undefined_table then null; end;
  begin delete from public.channel_messages        where sender_id = uid; exception when undefined_table then null; end;
  begin delete from public.inbox_messages          where receiver_id = uid or sender_id = uid; exception when undefined_table then null; end;
  begin delete from public.friendships             where requester_id = uid or addressee_id = uid; exception when undefined_table then null; end;
  begin delete from public.braai_events            where host_id = uid; exception when undefined_table then null; end;
  begin delete from public.shared_assets           where user_id = uid; exception when undefined_table then null; end;
  begin delete from public.smart_suggestions       where user_id = uid; exception when undefined_table then null; end;

  -- Final POPIA step — drop the auth identity itself.
  delete from auth.users where id = uid;
end;
$$;

revoke all on function public.delete_my_account() from public;
grant execute on function public.delete_my_account() to authenticated;

comment on function public.delete_my_account() is
  'POPIA right-to-be-forgotten. Called by the mobile client from Profile -> '
  'Privacy & Data Settings -> Erase My Data. Deletes the calling user''s '
  'app data and the auth.users row. SECURITY DEFINER + auth.uid() scoping '
  'means the caller can only erase themselves.';
