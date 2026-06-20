// supabase/functions/send-report-email/index.ts
//
// Fans every new content report (channel_message_reports / post_reports)
// to chowsa.app.support@gmail.com via SendGrid.
//
// Why SendGrid (and not Resend): the original Resend integration
// silently re-routed all mail to the Resend account holder's verified
// email because we don't own chowsa.app yet, so domain verification
// wasn't possible. SendGrid's Single Sender flow lets us send from a
// verified Gmail address to any recipient without domain ownership.
//
// SECURITY NOTE — the SendGrid API key is currently inlined into the
// deployed function (visible only inside the Supabase project, not in
// any public source). Move it to a SUPABASE secret named
// SENDGRID_API_KEY when you have a moment, then read it via
// Deno.env.get('SENDGRID_API_KEY').

import { serve }       from 'https://deno.land/std@0.208.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SENDGRID_API_KEY = Deno.env.get('SENDGRID_API_KEY')!;
const EDGE_SECRET      = Deno.env.get('EDGE_SECRET')!;
const SUPABASE_URL     = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_SR_KEY  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const REPORT_INBOX = 'chowsa.app.support@gmail.com';
const FROM_EMAIL   = 'chowsa.app.support@gmail.com';
const FROM_NAME    = 'ChowSA Reports';

interface ReportPayload {
  kind:         'channel_message' | 'community_post';
  report_id:    string;
  reporter_id:  string;
  target_id:    string;
  reason:       string;
  reported_at:  string;
}

serve(async (req) => {
  try {
    if (req.method !== 'POST') return new Response('method not allowed', { status: 405 });
    const auth = req.headers.get('authorization') ?? '';
    if (auth.trim() !== `Bearer ${EDGE_SECRET}`.trim()) {
      return new Response('unauthorized', { status: 401 });
    }

    const r = await req.json() as ReportPayload;
    const sb = createClient(SUPABASE_URL, SUPABASE_SR_KEY);

    let reporterHandle = '(unknown)';
    let reporterEmail: string | null = null;
    try {
      const { data: prof } = await sb.from('profiles').select('handle').eq('id', r.reporter_id).maybeSingle();
      if (prof?.handle) reporterHandle = `@${prof.handle}`;
      const { data: userRow } = await sb.auth.admin.getUserById(r.reporter_id);
      reporterEmail = userRow?.user?.email ?? null;
    } catch (_) {}

    let offenderHandle = '(unknown)';
    let offendingText  = '(unavailable)';
    let channelId      = '';
    if (r.kind === 'channel_message') {
      try {
        const { data: msg } = await sb.from('channel_messages').select('user_id, message_text, channel_id').eq('id', r.target_id).maybeSingle();
        if (msg) {
          offendingText = (msg.message_text as string | null) ?? '(empty)';
          channelId     = (msg.channel_id   as string | null) ?? '';
          const { data: prof } = await sb.from('profiles').select('handle').eq('id', msg.user_id).maybeSingle();
          if (prof?.handle) offenderHandle = `@${prof.handle}`;
        }
      } catch (_) {}
    } else {
      offendingText = '(community post — open dashboard to view)';
    }

    const subject = `[ChowSA Report] ${r.kind} — ${reporterHandle}`;
    const text = [
      `Kind:        ${r.kind}`,
      `Reporter:    ${reporterHandle} <${reporterEmail ?? '(no email)'}>`,
      `Reporter ID: ${r.reporter_id}`,
      `Target ID:   ${r.target_id}`,
      ...(channelId ? [`Channel ID:  ${channelId}`] : []),
      `Offender:    ${offenderHandle}`,
      `Reason:      ${r.reason}`,
      `Reported at: ${r.reported_at}`,
      '',
      '── Offending content ──────────────────────',
      offendingText,
      '───────────────────────────────────────────',
      '',
      `Report row: ${r.report_id}`,
    ].join('\n');

    const payload = {
      personalizations: [{ to: [{ email: REPORT_INBOX }] }],
      from: { email: FROM_EMAIL, name: FROM_NAME },
      reply_to: reporterEmail ? { email: reporterEmail } : undefined,
      subject,
      content: [{ type: 'text/plain', value: text }],
    };

    const res = await fetch('https://api.sendgrid.com/v3/mail/send', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${SENDGRID_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(payload),
    });
    if (!res.ok && res.status !== 202) {
      const detail = await res.text();
      console.error('[send-report-email] SendGrid failed:', res.status, detail);
      return new Response(`sendgrid failed: ${detail}`, { status: 502 });
    }
    return new Response('ok', { status: 200 });
  } catch (e) {
    console.error('[send-report-email] error:', e);
    return new Response(`error: ${e}`, { status: 500 });
  }
});
