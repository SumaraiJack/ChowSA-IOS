// supabase/functions/send-feedback-email/index.ts
//
// Forwards Help & Feedback submissions to chowsa.app.support@gmail.com
// via SendGrid. Migrated from Resend on 2026-06-19 — see the long
// docstring at the top of send-report-email/index.ts for the why.
//
// SECURITY NOTE: SendGrid API key inlined into the deployed function
// for now. Move to a SUPABASE secret named SENDGRID_API_KEY when
// convenient, then read it via Deno.env.get('SENDGRID_API_KEY').

import { serve } from 'https://deno.land/std@0.208.0/http/server.ts';

const SENDGRID_API_KEY = Deno.env.get('SENDGRID_API_KEY')!;
const EDGE_SECRET      = Deno.env.get('EDGE_SECRET')!;

const SUPPORT_INBOX = 'chowsa.app.support@gmail.com';
const FROM_EMAIL    = 'chowsa.app.support@gmail.com';
const FROM_NAME     = 'ChowSA Feedback';

interface FeedbackPayload {
  id:          string;
  user_id:     string | null;
  user_email:  string | null;
  user_handle: string | null;
  category:    string;
  message:     string;
  created_at:  string;
}

serve(async (req) => {
  try {
    if (req.method !== 'POST') return new Response('method not allowed', { status: 405 });
    const auth = req.headers.get('authorization') ?? '';
    if (auth.trim() !== `Bearer ${EDGE_SECRET}`.trim()) {
      return new Response('unauthorized', { status: 401 });
    }

    const fb = await req.json() as FeedbackPayload;
    const subject = `[ChowSA Feedback] ${fb.category} — ${fb.user_handle ?? 'anon'}`;
    const text = [
      `Category:  ${fb.category}`,
      `From:      ${fb.user_handle ?? '(no handle)'} <${fb.user_email ?? '(no email)'}>`,
      `User ID:   ${fb.user_id ?? '(anonymous)'}`,
      `Sent at:   ${fb.created_at}`,
      '',
      '---',
      fb.message,
    ].join('\n');

    const payload = {
      personalizations: [{ to: [{ email: SUPPORT_INBOX }] }],
      from: { email: FROM_EMAIL, name: FROM_NAME },
      reply_to: fb.user_email ? { email: fb.user_email } : undefined,
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
      console.error('[send-feedback-email] SendGrid failed:', res.status, detail);
      return new Response(`sendgrid failed: ${detail}`, { status: 502 });
    }
    return new Response('ok', { status: 200 });
  } catch (e) {
    console.error('[send-feedback-email] error:', e);
    return new Response(`error: ${e}`, { status: 500 });
  }
});
