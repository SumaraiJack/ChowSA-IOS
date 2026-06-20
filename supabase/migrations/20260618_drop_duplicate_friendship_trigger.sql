-- 20260618_drop_duplicate_friendship_trigger.sql
--
-- Drops the legacy `on_friendship_pending` trigger on public.friendships.
--
-- Why: an earlier migration (added via the dashboard SQL editor, never
-- committed to this folder) created an AFTER INSERT trigger called
-- `on_friendship_pending` that called `notify_friendship_invite()`.
-- The current migration 20260619_push_triggers.sql ALSO creates an
-- AFTER INSERT trigger (trg_notify_friendship_invite) pointing at the
-- same function. Result: every friendships INSERT fired the function
-- twice → two rows in public.notifications AND two fire_push() calls
-- → users received duplicate FCM push notifications and a launcher
-- badge of 2 for every single Kitchen Circle invite.
--
-- Idempotent: safe to re-run if the legacy trigger has already been
-- dropped manually.

DROP TRIGGER IF EXISTS on_friendship_pending ON public.friendships;
