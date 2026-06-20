-- 20260617_profiles_fcm_token.sql
--
-- Per-user FCM device token + freshness metadata. NotificationService._syncToken()
-- writes this on app start, on onTokenRefresh, and after sign-in. The Edge
-- Function `send_push` reads it to target the recipient's device.
--
-- v1: one token per user. Multi-device support comes later via a separate
-- device_tokens(id, user_id, token, platform) table — out of scope here.

alter table public.profiles
  add column if not exists fcm_token    text,
  add column if not exists fcm_token_at timestamptz,
  add column if not exists fcm_platform text;

comment on column public.profiles.fcm_token    is 'Firebase Cloud Messaging device token. Null for users who declined notifications.';
comment on column public.profiles.fcm_token_at is 'Last time NotificationService refreshed this token.';
comment on column public.profiles.fcm_platform is 'Source platform: android | ios.';
