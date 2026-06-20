-- 20260618_report_email_triggers.sql
--
-- Emails the moderation inbox whenever a user flags content via the
-- Report button (channel message or community post). Mirrors the
-- send-feedback-email plumbing: pg_net POSTs the new row to the
-- send-report-email Edge Function, which authenticates with
-- EDGE_SECRET and forwards a formatted alert through Resend to
-- chowsa.app.support@gmail.com.

-- ── 1. Stash the report-email function URL alongside the others.
INSERT INTO public.app_settings (key, value) VALUES (
  'report_email_url',
  'https://arxwrwzhzyzckveijexl.supabase.co/functions/v1/send-report-email'
)
ON CONFLICT (key) DO UPDATE SET value = excluded.value;

-- ── 2. Helper: fire_report_email(payload) — pg_net wrapper.
CREATE OR REPLACE FUNCTION public.fire_report_email(payload jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, net
AS $$
DECLARE
  url    text;
  secret text;
BEGIN
  SELECT value INTO url    FROM public.app_settings WHERE key = 'report_email_url';
  SELECT value INTO secret FROM public.app_settings WHERE key = 'edge_secret';
  IF url IS NULL OR url = '' THEN RETURN; END IF;

  PERFORM net.http_post(
    url     := url,
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer ' || coalesce(secret, '')
    ),
    body    := payload
  );
END$$;

REVOKE ALL ON FUNCTION public.fire_report_email(jsonb) FROM public;

-- ── 3. Trigger fn: channel_message_reports → email.
CREATE OR REPLACE FUNCTION public.notify_channel_message_report()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.fire_report_email(jsonb_build_object(
    'kind',        'channel_message',
    'report_id',   NEW.id,
    'reporter_id', NEW.reporter_id,
    'target_id',   NEW.message_id,
    'reason',      NEW.reason,
    'reported_at', NEW.reported_at
  ));
  RETURN NEW;
END$$;

DROP TRIGGER IF EXISTS trg_notify_channel_message_report
  ON public.channel_message_reports;
CREATE TRIGGER trg_notify_channel_message_report
  AFTER INSERT ON public.channel_message_reports
  FOR EACH ROW EXECUTE FUNCTION public.notify_channel_message_report();

-- ── 4. Trigger fn: post_reports → email.
CREATE OR REPLACE FUNCTION public.notify_post_report()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.fire_report_email(jsonb_build_object(
    'kind',        'community_post',
    'report_id',   NEW.id,
    'reporter_id', NEW.reporter_id,
    'target_id',   NEW.post_id,
    'reason',      NEW.reason,
    'reported_at', NEW.reported_at
  ));
  RETURN NEW;
END$$;

DROP TRIGGER IF EXISTS trg_notify_post_report
  ON public.post_reports;
CREATE TRIGGER trg_notify_post_report
  AFTER INSERT ON public.post_reports
  FOR EACH ROW EXECUTE FUNCTION public.notify_post_report();
