// supabase/functions/send_push/index.ts
//
// Single Edge Function that fans every ChowSA notification trigger into FCM.
//
// Trigger sources (Postgres → http hook via pg_net + fire_push):
//   1. friendships              insert + status='pending'   → 'kitchen_invite'
//   2. shopping_list_shares     insert                       → 'list_shared'   (legacy)
//   3. inbox_messages           insert, type='shared_list'   → 'list_shared'
//   4. inbox_messages           insert, type='shared_recipe' → 'recipe_shared'
//   5. inbox_messages           insert, type='meal_plan'     → 'meal_plan'
//   6. community_posts / channel_messages insert with @mention → 'mention'

import { serve } from 'https://deno.land/std@0.208.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { GoogleAuth } from 'https://esm.sh/google-auth-library@9';

const FCM_PROJECT_ID    = Deno.env.get('FCM_PROJECT_ID')!;
const FCM_SA_JSON       = Deno.env.get('FCM_SERVICE_ACCOUNT_JSON')!;
const SUPABASE_URL      = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_SR_KEY   = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const EDGE_SECRET       = Deno.env.get('EDGE_SECRET')!;

type PushType =
  | 'kitchen_invite'
  | 'list_shared'
  | 'recipe_shared'
  | 'meal_plan'
  | 'mention';

interface PushEvent {
  type:         PushType;
  to_user_id:   string;
  from_handle?: string;
  route?:       string;
  data?:        Record<string, string>;
}

function titleBodyFor(e: PushEvent): { title: string; body: string } {
  const who = e.from_handle ?? 'Someone';
  switch (e.type) {
    case 'kitchen_invite':
      return { title: 'New Kitchen Circle invite',
               body:  `${who} wants to cook with you on ChowSA.` };
    case 'list_shared':
      return { title: 'Shopping list shared with you',
               body:  `${who} shared a shopping list.` };
    case 'recipe_shared':
      return { title: 'Recipe shared with you',
               body:  `${who} sent you a recipe. Tap to view.` };
    case 'meal_plan':
      return { title: 'Meal plan sent',
               body:  `${who} sent you a meal plan.` };
    case 'mention':
      return { title: `${who} mentioned you`,
               body:  e.data?.preview ?? `${who} tagged you in a community post.` };
  }
}

async function fcmAccessToken(): Promise<string> {
  const auth = new GoogleAuth({
    credentials: JSON.parse(FCM_SA_JSON),
    scopes:      ['https://www.googleapis.com/auth/firebase.messaging'],
  });
  const client = await auth.getClient();
  const token  = await client.getAccessToken();
  return token.token!;
}

serve(async (req) => {
  try {
    // Bearer-token gate — pg_net sends 'Authorization: Bearer <EDGE_SECRET>'.
    const incoming = req.headers.get('authorization')
                  ?? req.headers.get('Authorization')
                  ?? '';
    if (incoming.trim() !== `Bearer ${EDGE_SECRET}`.trim()) {
      return new Response('unauthorized', { status: 401 });
    }

    const event = await req.json() as PushEvent;

    // 1. Look up the recipient's device token.
    const sb = createClient(SUPABASE_URL, SUPABASE_SR_KEY);
    const { data: profile, error } = await sb
      .from('profiles')
      .select('fcm_token')
      .eq('id', event.to_user_id)
      .single();
    if (error || !profile?.fcm_token) {
      return new Response('No token for recipient', { status: 204 });
    }

    // 2. Build the FCM v1 payload.
    const { title, body } = titleBodyFor(event);
    const payload = {
      message: {
        token: profile.fcm_token,
        notification: { title, body },
        data: {
          type:  event.type,
          route: event.route ?? '/inbox',
          ...(event.data ?? {}),
        },
        android: {
          priority: 'HIGH',
          notification: {
            channel_id:              'chowsa_default',
            notification_priority:   'PRIORITY_MAX',
            default_sound:           true,
            default_vibrate_timings: true,
          },
        },
      },
    };

    // 3. POST to FCM HTTP v1.
    const accessToken = await fcmAccessToken();
    const res = await fetch(
      `https://fcm.googleapis.com/v1/projects/${FCM_PROJECT_ID}/messages:send`,
      {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${accessToken}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify(payload),
      },
    );
    if (!res.ok) {
      return new Response(await res.text(), { status: res.status });
    }
    return new Response('ok', { status: 200 });
  } catch (e) {
    return new Response(`error: ${e}`, { status: 500 });
  }
});
