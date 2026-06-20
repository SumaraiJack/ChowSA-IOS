-- 20260619_drop_channel_message_likes.sql
--
-- Retires the channel_message_likes junction table. The single-heart
-- like button on Live Banter chat bubbles was removed for v1.0 so the
-- chat layout matches the rest of the Community Hub (which uses the
-- newer channel_message_reactions emoji-palette flow instead). With
-- no remaining client of the junction table, the cleanest move is to
-- drop it and any policies/indexes attached to it.

DROP TABLE IF EXISTS public.channel_message_likes CASCADE;
