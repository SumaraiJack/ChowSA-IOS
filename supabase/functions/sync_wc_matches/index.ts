// supabase/functions/sync_wc_matches/index.ts
//
// Server-side World Cup result sync — TheSportsDB edition (free, no API key).
//
// Strategy: iterate a small date window of eventsday.php and merge each day's
// events. Default window is yesterday..tomorrow (covers recent finals, live,
// and upcoming-soon). A larger one-off backfill can be requested by POSTing
// { "days_back": N, "days_fwd": M }.
//
// Backstop: after merging, any not-yet-finished row whose kickoff is at least
// 2h45 in the past is flipped to `finished` so they move out of UPCOMING into
// FINISHED even when TheSportsDB doesn't carry that fixture (placeholder 0-0
// stays until a real upstream score lands).
//
// verify_jwt is DISABLED (auth = X-Edge-Secret) so pg_cron isn't JWT-gated.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";

const LEAGUE_ID = "4429";

interface TsdbEvent {
  idEvent?: string; strHomeTeam?: string; strAwayTeam?: string;
  intHomeScore?: string | null; intAwayScore?: string | null;
  strStatus?: string | null; strProgress?: string | null; strTimestamp?: string | null;
}

interface SyncResult {
  fetched: number; upserted: number; promoted: number; skipped: number;
  days: number; demoted_past: number; errors: string[];
}

function toIntOrNull(v: string | null | undefined): number | null {
  if (v === null || v === undefined || v === "") return null;
  const n = parseInt(v, 10);
  return Number.isFinite(n) ? n : null;
}

function normName(s: string): string {
  let x = s.toLowerCase().trim().normalize("NFD").replace(/[̀-ͯ]/g, "");
  x = x.replace(/[^a-z0-9' ]/g, " ").replace(/\s+/g, " ").trim();
  const alias: Record<string, string> = {
    // Existing
    "usa": "united states",
    "united states of america": "united states",
    "south korea": "korea republic",
    "republic of korea": "korea republic",
    "ivory coast": "cote d'ivoire",
    "turkey": "turkiye",
    "czech republic": "czechia",
    "bosnia": "bosnia and herzegovina",
    "bosnia herzegovina": "bosnia and herzegovina",
    // Africa — common DB vs TheSportsDB mismatches that were silently
    // dropping rows on every sync run (visible as stuck 0-0 finals
    // in the FINISHED tab).
    "dr congo": "congo dr",
    "drc": "congo dr",
    "democratic republic of the congo": "congo dr",
    "republic of the congo": "congo",
    "cape verde": "cabo verde",
    "swaziland": "eswatini",
    // Misc upstream-naming gotchas
    "iran": "ir iran",
    "north macedonia": "macedonia",
    "saudi arabia": "ksa",
  };
  return alias[x] ?? x;
}

function deriveStatus(statusRaw: string, scoresPresent: boolean, kickoffPast: boolean): "finished" | "live" | "scheduled" {
  const s = (statusRaw || "").toUpperCase().trim();
  const finishedSet = new Set(["FT","AET","PEN","MATCH FINISHED","AFTER EXTRA TIME","PENALTIES","FT_PEN"]);
  const liveSet     = new Set(["1H","2H","HT","ET","BT","P","LIVE","INPLAY","IN PLAY"]);
  if (finishedSet.has(s)) return "finished";
  if (liveSet.has(s)) return "live";
  if (scoresPresent && kickoffPast) return "finished";
  return "scheduled";
}

function ymd(d: Date): string { return d.toISOString().slice(0, 10); }

async function fetchWindow(key: string, daysBack: number, daysFwd: number): Promise<{ events: TsdbEvent[]; days: number }> {
  const base = `https://www.thesportsdb.com/api/v1/json/${key}`;
  const out = new Map<string, TsdbEvent>();
  const today = new Date();
  const dates: string[] = [];
  for (let i = -daysBack; i <= daysFwd; i++) {
    const d = new Date(today.getTime() + i * 86400000);
    dates.push(ymd(d));
  }
  for (const date of dates) {
    const res = await fetch(`${base}/eventsday.php?d=${date}&l=${LEAGUE_ID}`, { headers: { accept: "application/json" } });
    if (!res.ok) continue;
    const body = await res.json().catch(() => ({}));
    const arr = Array.isArray(body?.events) ? body.events : [];
    for (const e of arr) { if (e?.idEvent) out.set(String(e.idEvent), e); }
  }
  return { events: [...out.values()], days: dates.length };
}

Deno.serve(async (req: Request) => {
  const incomingSecret = req.headers.get("x-edge-secret");
  const localSecret    = Deno.env.get("WC_SYNC_EDGE_SECRET");
  if (!incomingSecret || !localSecret || incomingSecret.trim() !== localSecret.trim()) {
    return new Response(JSON.stringify({ error: "Unauthorized" }),
      { status: 401, headers: { "Content-Type": "application/json" } });
  }

  // Default sync window. daysBack was 1, which left a hard gap:
  // TheSportsDB often publishes final scores 24–72 hours after the
  // whistle. Pulling 3 days back means a Tuesday-night match still
  // has Wed, Thu, Fri runs to pick up the late score. daysFwd stays
  // at 1 — we don't need much forward horizon since the kickoff
  // ticker handles upcoming fixtures from the DB row directly.
  let daysBack = 3, daysFwd = 1;
  try {
    const b = await req.json();
    if (b && typeof b === "object") {
      if (Number.isFinite(b.days_back)) daysBack = Math.min(40, Math.max(0, b.days_back));
      if (Number.isFinite(b.days_fwd))  daysFwd  = Math.min(40, Math.max(0, b.days_fwd));
    }
  } catch { /* defaults */ }

  const key = Deno.env.get("THESPORTSDB_KEY") || "3";
  const sb  = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const result: SyncResult = { fetched: 0, upserted: 0, promoted: 0, skipped: 0, days: 0, demoted_past: 0, errors: [] };

  try {
    const { events, days } = await fetchWindow(key, daysBack, daysFwd);
    result.fetched = events.length;
    result.days = days;
    if (events.length === 0) result.errors.push("no events returned");

    const { data: dbRows, error: dbErr } = await sb
      .from("wc_matches")
      .select("id, api_match_id, team_a, team_b, team_a_score, team_b_score, status, match_time");
    if (dbErr) throw dbErr;

    const byApiId = new Map<string, typeof dbRows[number]>();
    const byPair  = new Map<string, typeof dbRows[number]>();
    const pairKey = (a: string, b: string) => `${normName(a)}|${normName(b)}`;
    for (const r of dbRows ?? []) {
      if (r.api_match_id) byApiId.set(r.api_match_id, r);
      byPair.set(pairKey(r.team_a, r.team_b), r);
      byPair.set(pairKey(r.team_b, r.team_a), r);
    }

    const nowMs = Date.now();
    for (const ev of events) {
      const a = ev.strHomeTeam ?? "";
      const b = ev.strAwayTeam ?? "";
      if (!a || !b) { result.skipped++; continue; }
      const apiId = ev.idEvent ? String(ev.idEvent) : null;
      const aS = toIntOrNull(ev.intHomeScore);
      const bS = toIntOrNull(ev.intAwayScore);
      const scoresPresent = aS !== null || bS !== null;
      const aScore = aS ?? 0;
      const bScore = bS ?? 0;
      const kickoffPast = ev.strTimestamp ? (Date.parse(ev.strTimestamp + "Z") < nowMs) : false;
      const minute = toIntOrNull(ev.strProgress) ?? 0;
      const status = deriveStatus(ev.strStatus ?? "", scoresPresent, kickoffPast);

      let row = apiId ? byApiId.get(apiId) : undefined;
      if (!row) row = byPair.get(pairKey(a, b));
      if (!row) { result.skipped++; continue; }

      if (row.team_a_score === aScore && row.team_b_score === bScore &&
          row.status === status && (apiId == null || row.api_match_id === apiId)) {
        continue;
      }

      const update: Record<string, unknown> = {
        team_a_score: aScore, team_b_score: bScore,
        home_score:   aScore, away_score:   bScore,
        status, live_minute: minute,
        updated_at: new Date().toISOString(),
      };
      if (apiId && !row.api_match_id) update.api_match_id = apiId;

      const { error: upErr } = await sb.from("wc_matches").update(update).eq("id", row.id);
      if (upErr) { result.errors.push(`row ${row.id}: ${upErr.message}`); continue; }
      result.upserted++;
      if (status === "finished" && row.status !== "finished") result.promoted++;
    }

    // Stuck-zero re-scan: any DB row that's already 'finished' but
    // still shows 0-0 (either because we promoted it locally via the
    // backstop below, or because a previous sync run hit a team-name
    // mismatch) gets a fresh attempt against the events we just
    // fetched. Without this pass, a stuck 0-0 row stayed 0-0 forever
    // — even after the team-name aliases above started matching it,
    // because the main upsert loop only walks the fetched events
    // looking for DB rows, not the other way around.
    const { data: stuckZero, error: zeroErr } = await sb
      .from("wc_matches")
      .select("id, team_a, team_b, api_match_id, status, team_a_score, team_b_score, match_time")
      .eq("status", "finished")
      .eq("team_a_score", 0)
      .eq("team_b_score", 0);
    if (!zeroErr && stuckZero && stuckZero.length > 0) {
      // Build a name-keyed lookup of the freshly-fetched events so we
      // can rescue rows whose team_name pair finally aliases through.
      const evByPair = new Map<string, TsdbEvent>();
      const evByApiId = new Map<string, TsdbEvent>();
      for (const ev of events) {
        const a = ev.strHomeTeam ?? "";
        const b = ev.strAwayTeam ?? "";
        if (!a || !b) continue;
        evByPair.set(pairKey(a, b), ev);
        evByPair.set(pairKey(b, a), ev);
        if (ev.idEvent) evByApiId.set(String(ev.idEvent), ev);
      }
      for (const row of stuckZero) {
        const ev = (row.api_match_id && evByApiId.get(row.api_match_id))
                ?? evByPair.get(pairKey(row.team_a, row.team_b));
        if (!ev) continue;
        const aS = toIntOrNull(ev.intHomeScore);
        const bS = toIntOrNull(ev.intAwayScore);
        if (aS === null && bS === null) continue;  // upstream still has no score
        const aScore = aS ?? 0;
        const bScore = bS ?? 0;
        if (aScore === 0 && bScore === 0) continue;  // genuine 0-0, leave alone
        const { error: upErr } = await sb.from("wc_matches").update({
          team_a_score: aScore, team_b_score: bScore,
          home_score:   aScore, away_score:   bScore,
          updated_at:   new Date().toISOString(),
          ...(ev.idEvent && !row.api_match_id
              ? { api_match_id: String(ev.idEvent) }
              : {}),
        }).eq("id", row.id);
        if (upErr) result.errors.push(`zero-rescan ${row.id}: ${upErr.message}`);
        else result.upserted++;
      }
    }

    // Backstop: any DB row whose kickoff was ≥ 2h45 ago but is still not
    // 'finished' — promote it. Covers fixtures TheSportsDB doesn't carry
    // (real 2026 WC data is sparse) so the FINISHED tab actually reflects
    // what's in the past. Scores stay 0-0 until a real source provides them.
    const cutoffIso = new Date(nowMs - 2.75 * 3600 * 1000).toISOString();
    const { data: stale, error: staleErr } = await sb
      .from("wc_matches")
      .select("id")
      .neq("status", "finished")
      .lt("match_time", cutoffIso);
    if (!staleErr && stale && stale.length > 0) {
      const ids = stale.map(r => r.id);
      const { error: bumpErr } = await sb
        .from("wc_matches")
        .update({ status: "finished", updated_at: new Date().toISOString() })
        .in("id", ids);
      if (bumpErr) result.errors.push(`backstop: ${bumpErr.message}`);
      else result.demoted_past = ids.length;
    }

    return new Response(JSON.stringify(result), { status: 200, headers: { "content-type": "application/json" } });
  } catch (e) {
    result.errors.push(String(e));
    return new Response(JSON.stringify(result), { status: 500, headers: { "content-type": "application/json" } });
  }
});
