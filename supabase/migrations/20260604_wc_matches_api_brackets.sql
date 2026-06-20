-- =============================================================================
-- Migration: wc_matches_api_brackets
-- =============================================================================
--
-- Brings the World Cup data model up to spec for live third-party API ingest
-- and dynamic knockout-bracket progression.
--
-- What lands here:
--   1. New columns on wc_matches  — api_match_id, home_score, away_score,
--      home/away_team_placeholder, round_code, bracket_slot, feeder_*.
--   2. wc_group_standings view    — live group table computed from finished
--                                    group-stage results.
--   3. resolve_bracket_placeholders() — PL/pgSQL function that fills knockout
--                                    matches' team_a/team_b once feeders are
--                                    decided. Idempotent.
--   4. trg_wc_match_finished     — AFTER UPDATE trigger that fires the
--                                    resolver whenever a group match
--                                    transitions to 'finished'.
--
-- Idempotent — every CREATE uses IF NOT EXISTS / CREATE OR REPLACE.
-- =============================================================================

BEGIN;

-- ── 1. wc_matches columns ────────────────────────────────────────────────────
ALTER TABLE public.wc_matches
  ADD COLUMN IF NOT EXISTS api_match_id          text,
  -- home_score / away_score are the canonical names per spec; we keep the
  -- legacy team_a_score / team_b_score columns mirrored via the trigger
  -- below so existing Flutter code keeps reading the old fields without a
  -- breaking rename.
  ADD COLUMN IF NOT EXISTS home_score            int,
  ADD COLUMN IF NOT EXISTS away_score            int,
  -- Placeholder labels rendered in the UI until the resolver fills in the
  -- real team names. e.g. 'Winner Group A', 'Runner-up Group B',
  -- 'Winner of R32 M1'.
  ADD COLUMN IF NOT EXISTS home_team_placeholder text,
  ADD COLUMN IF NOT EXISTS away_team_placeholder text,
  -- Round / bracket coordinates.
  -- round_code ∈ {'GROUP','R32','R16','QF','SF','3RD','FINAL'}
  ADD COLUMN IF NOT EXISTS round_code            text NOT NULL DEFAULT 'GROUP',
  ADD COLUMN IF NOT EXISTS bracket_slot          int,
  -- Group-feeder fields — used when the placeholder is "Winner Group X" or
  -- "Runner-up Group X". feeder_group is the group letter; feeder_position
  -- is 1 (winner), 2 (runner-up), 3 (best third), 4 (fourth-best third)…
  ADD COLUMN IF NOT EXISTS home_feeder_group     text,
  ADD COLUMN IF NOT EXISTS home_feeder_position  int,
  ADD COLUMN IF NOT EXISTS away_feeder_group     text,
  ADD COLUMN IF NOT EXISTS away_feeder_position  int,
  -- Knockout-feeder fields — used when the placeholder is
  -- "Winner of R32 M14". Points at the match whose winner advances here.
  ADD COLUMN IF NOT EXISTS home_feeder_match_id  uuid REFERENCES public.wc_matches(id),
  ADD COLUMN IF NOT EXISTS away_feeder_match_id  uuid REFERENCES public.wc_matches(id);

CREATE UNIQUE INDEX IF NOT EXISTS wc_matches_api_id_uniq
  ON public.wc_matches (api_match_id)
  WHERE api_match_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_wc_matches_round
  ON public.wc_matches (round_code, bracket_slot);

-- Keep legacy team_a_score / team_b_score in sync with home_score / away_score
-- so existing readers (priority ticker, model) don't break. Bidirectional —
-- whichever side gets written, the other follows.
CREATE OR REPLACE FUNCTION public._wc_mirror_scores() RETURNS trigger AS $$
BEGIN
  IF NEW.home_score IS DISTINCT FROM OLD.home_score
     OR (TG_OP = 'INSERT' AND NEW.home_score IS NOT NULL) THEN
    NEW.team_a_score := COALESCE(NEW.home_score, 0);
  ELSIF NEW.team_a_score IS DISTINCT FROM OLD.team_a_score
        OR (TG_OP = 'INSERT' AND NEW.team_a_score IS NOT NULL) THEN
    NEW.home_score := NEW.team_a_score;
  END IF;

  IF NEW.away_score IS DISTINCT FROM OLD.away_score
     OR (TG_OP = 'INSERT' AND NEW.away_score IS NOT NULL) THEN
    NEW.team_b_score := COALESCE(NEW.away_score, 0);
  ELSIF NEW.team_b_score IS DISTINCT FROM OLD.team_b_score
        OR (TG_OP = 'INSERT' AND NEW.team_b_score IS NOT NULL) THEN
    NEW.away_score := NEW.team_b_score;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_wc_mirror_scores ON public.wc_matches;
CREATE TRIGGER trg_wc_mirror_scores
  BEFORE INSERT OR UPDATE ON public.wc_matches
  FOR EACH ROW EXECUTE FUNCTION public._wc_mirror_scores();

-- ── 2. wc_group_standings view ───────────────────────────────────────────────
-- Live group table built from finished group-stage rows. Tie-break order
-- (pts, gd, gf, name) is the standard FIFA hierarchy minus head-to-head /
-- fair-play (which require richer data than the matches table alone carries
-- — wire those in via api_match_id once the sync function lands per-match
-- discipline payloads).
CREATE OR REPLACE VIEW public.wc_group_standings AS
WITH legs AS (
  -- One row per (group, team, match) with that team's points + GD + GF
  -- for the match. team_a leg.
  SELECT
    m.group_code AS group_code,
    m.team_a     AS team,
    CASE
      WHEN m.home_score >  m.away_score THEN 3
      WHEN m.home_score =  m.away_score THEN 1
      ELSE 0
    END                                     AS points,
    COALESCE(m.home_score, 0)               AS gf,
    COALESCE(m.away_score, 0)               AS ga
  FROM public.wc_matches m
  WHERE m.round_code = 'GROUP' AND m.status = 'finished'
  UNION ALL
  SELECT
    m.group_code,
    m.team_b,
    CASE
      WHEN m.away_score >  m.home_score THEN 3
      WHEN m.away_score =  m.home_score THEN 1
      ELSE 0
    END,
    COALESCE(m.away_score, 0),
    COALESCE(m.home_score, 0)
  FROM public.wc_matches m
  WHERE m.round_code = 'GROUP' AND m.status = 'finished'
)
SELECT
  group_code,
  team,
  SUM(points)::int                                AS pts,
  SUM(gf)::int                                    AS gf,
  SUM(ga)::int                                    AS ga,
  SUM(gf - ga)::int                               AS gd,
  COUNT(*)::int                                   AS played,
  ROW_NUMBER() OVER (
    PARTITION BY group_code
    ORDER BY SUM(points) DESC, SUM(gf - ga) DESC, SUM(gf) DESC, team ASC
  )::int                                          AS position
FROM legs
GROUP BY group_code, team;

-- ── 3. resolve_bracket_placeholders() ────────────────────────────────────────
-- Idempotent. Iterates every knockout match whose team_a or team_b is still
-- a placeholder, and fills in the real team name if its feeder is decided:
--   • home/away_feeder_group + position → look up wc_group_standings
--   • home/away_feeder_match_id          → look up the winner of that match
-- Called by the AFTER UPDATE trigger and exposed as a security-definer
-- function so the edge function can invoke it via RPC after a sync.
CREATE OR REPLACE FUNCTION public.resolve_bracket_placeholders()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  r            record;
  resolved_home text;
  resolved_away text;
BEGIN
  FOR r IN
    SELECT *
      FROM public.wc_matches
     WHERE round_code <> 'GROUP'
       AND (
            home_team_placeholder IS NOT NULL
         OR away_team_placeholder IS NOT NULL
       )
  LOOP
    resolved_home := NULL;
    resolved_away := NULL;

    -- Home side
    IF r.home_team_placeholder IS NOT NULL THEN
      IF r.home_feeder_group IS NOT NULL AND r.home_feeder_position IS NOT NULL THEN
        SELECT team INTO resolved_home
          FROM public.wc_group_standings
         WHERE group_code = r.home_feeder_group
           AND position   = r.home_feeder_position;
      ELSIF r.home_feeder_match_id IS NOT NULL THEN
        SELECT
          CASE
            WHEN home_score > away_score THEN team_a
            WHEN away_score > home_score THEN team_b
            ELSE NULL
          END
          INTO resolved_home
          FROM public.wc_matches
         WHERE id = r.home_feeder_match_id
           AND status = 'finished';
      END IF;
    END IF;

    -- Away side
    IF r.away_team_placeholder IS NOT NULL THEN
      IF r.away_feeder_group IS NOT NULL AND r.away_feeder_position IS NOT NULL THEN
        SELECT team INTO resolved_away
          FROM public.wc_group_standings
         WHERE group_code = r.away_feeder_group
           AND position   = r.away_feeder_position;
      ELSIF r.away_feeder_match_id IS NOT NULL THEN
        SELECT
          CASE
            WHEN home_score > away_score THEN team_a
            WHEN away_score > home_score THEN team_b
            ELSE NULL
          END
          INTO resolved_away
          FROM public.wc_matches
         WHERE id = r.away_feeder_match_id
           AND status = 'finished';
      END IF;
    END IF;

    -- Persist whatever resolved. Clearing the placeholder is the signal to
    -- the UI to stop rendering "Winner Group A" and switch to the real name.
    IF resolved_home IS NOT NULL OR resolved_away IS NOT NULL THEN
      UPDATE public.wc_matches
         SET team_a                 = COALESCE(resolved_home, team_a),
             home_team_placeholder  = CASE WHEN resolved_home IS NOT NULL THEN NULL ELSE home_team_placeholder END,
             team_b                 = COALESCE(resolved_away, team_b),
             away_team_placeholder  = CASE WHEN resolved_away IS NOT NULL THEN NULL ELSE away_team_placeholder END
       WHERE id = r.id;
    END IF;
  END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION public.resolve_bracket_placeholders() TO authenticated, service_role;

-- ── 4. Trigger: status → 'finished' kicks the resolver ───────────────────────
CREATE OR REPLACE FUNCTION public._wc_match_finished_trigger()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF (TG_OP = 'UPDATE' AND OLD.status IS DISTINCT FROM 'finished' AND NEW.status = 'finished')
     OR (TG_OP = 'INSERT' AND NEW.status = 'finished') THEN
    -- Cascades naturally: resolving a R32 winner may unblock an R16 that
    -- referenced it via home_feeder_match_id, so we loop until stable.
    PERFORM public.resolve_bracket_placeholders();
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_wc_match_finished ON public.wc_matches;
CREATE TRIGGER trg_wc_match_finished
  AFTER INSERT OR UPDATE OF status ON public.wc_matches
  FOR EACH ROW EXECUTE FUNCTION public._wc_match_finished_trigger();

-- ── 5. RLS read access on the view ───────────────────────────────────────────
-- Views inherit RLS from the underlying tables. wc_matches is already
-- readable; surface a comment for clarity.
COMMENT ON VIEW public.wc_group_standings IS
  'Live group standings computed from finished wc_matches rows. ' ||
  'Used by resolve_bracket_placeholders() to fill knockout brackets.';

COMMIT;
