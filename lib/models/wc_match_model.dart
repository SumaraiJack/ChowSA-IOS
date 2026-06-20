// lib/models/wc_match_model.dart
//
// Maps a row from the `wc_matches` Supabase table.
//
// Wire format:
//   id              uuid
//   team_a          text
//   team_b          text
//   team_a_flag     text   (emoji flag, e.g. '🇿🇦')
//   team_b_flag     text
//   team_a_score    int
//   team_b_score    int
//   match_time      timestamptz                — absolute UTC instant
//   stage           text   ('Group Stage', 'Quarter-final', …)
//   status          match_status enum → 'scheduled' | 'live' | 'finished'
//   is_bafana_match boolean
//   live_minute     int    (0 when not live)
//   venue           text                       — stadium, e.g. 'Estadio Azteca, Mexico City'
//   kickoff_local   text                       — human-readable venue-local label
//                                                e.g. 'Thu 11 Jun · 19:00 (Mexico City)'
//   group_code      text                       — 'A', 'B', 'C', …
//
// Date-time rendering policy:
//   • `matchTime` is the absolute instant — use it for sort, countdown, and
//     live-state logic.
//   • For dashboard cards/tickers, prefer `kickoffLocal` so fans see the
//     match's venue-local kickoff verbatim instead of their device-TZ
//     conversion (which would, for example, render a Mexico City 19:00
//     kickoff as 03:00 the next day for a SAST viewer).

class WcMatchModel {
  const WcMatchModel({
    required this.id,
    required this.teamA,
    required this.teamB,
    required this.teamAFlag,
    required this.teamBFlag,
    required this.teamAScore,
    required this.teamBScore,
    required this.matchTime,
    required this.stage,
    required this.status,
    required this.isBafanaMatch,
    required this.liveMinute,
    this.venue,
    this.kickoffLocal,
    this.groupCode,
    this.roundCode = 'GROUP',
    this.bracketSlot,
    this.apiMatchId,
    this.homeTeamPlaceholder,
    this.awayTeamPlaceholder,
  });

  final String   id;
  final String   teamA;
  final String   teamB;
  final String   teamAFlag;
  final String   teamBFlag;
  final int      teamAScore;
  final int      teamBScore;
  final DateTime matchTime;
  final String   stage;
  final String   status;     // 'scheduled' | 'live' | 'finished'
  final bool     isBafanaMatch;
  final int      liveMinute;

  /// Stadium name as published by FIFA, e.g. 'Estadio Azteca, Mexico City'.
  final String?  venue;

  /// Pre-formatted venue-local kickoff label for direct display on dashboard
  /// cards. Prefer this over `matchTime` formatting when rendering — see the
  /// date-time rendering policy in the file header.
  final String?  kickoffLocal;

  /// FIFA group letter, e.g. 'A', 'B'. Null for knockout-stage matches.
  final String?  groupCode;

  /// Round in our enum-ish vocabulary: 'GROUP' | 'R32' | 'R16' | 'QF' | 'SF'
  /// | '3RD' | 'FINAL'. Defaults to 'GROUP' for legacy rows.
  final String   roundCode;

  /// Slot index within a knockout round (e.g. R32 has slots 1..16). Null for
  /// group matches. Used to lay out bracket trees in the Match Center UI.
  final int?     bracketSlot;

  /// External provider's match id (api-football fixture.id, etc). Lets the
  /// sync edge function upsert by stable foreign key.
  final String?  apiMatchId;

  /// When a knockout slot's team isn't decided yet, the placeholder string
  /// the UI should render in place of the team name. e.g. 'Winner Group A',
  /// 'Winner of R32 M14'. Null once `resolve_bracket_placeholders()` fills
  /// the slot with the real team.
  final String?  homeTeamPlaceholder;
  final String?  awayTeamPlaceholder;

  /// True when the slot is unresolved — render placeholder instead of team.
  bool get homeIsPlaceholder => homeTeamPlaceholder != null;
  bool get awayIsPlaceholder => awayTeamPlaceholder != null;

  /// Renderable flag glyph for team A. The DB column [teamAFlag] may carry
  /// either:
  ///   • a 2-letter ISO 3166-1 alpha-2 code (e.g. 'MX', 'ZA') — converted
  ///     here to the regional-indicator emoji pair (🇲🇽, 🇿🇦), OR
  ///   • a literal flag emoji (legacy rows from the earlier seed) — passed
  ///     through verbatim, OR
  ///   • a non-letter fallback ('🏳️') — also passed through.
  /// UI widgets should always read this getter rather than the raw column
  /// so flags render correctly regardless of which storage format the row
  /// was written with.
  String get teamAFlagEmoji => _toFlagEmoji(teamAFlag);
  String get teamBFlagEmoji => _toFlagEmoji(teamBFlag);

  static String _toFlagEmoji(String raw) {
    final s = raw.trim();
    if (s.length != 2) return s;
    final upper = s.toUpperCase();
    final a = upper.codeUnitAt(0);
    final b = upper.codeUnitAt(1);
    // Only A–Z map to regional indicators; anything else falls through.
    if (a < 0x41 || a > 0x5A || b < 0x41 || b > 0x5A) return s;
    const base = 0x1F1E6; // regional indicator symbol 'A'
    return String.fromCharCodes([base + (a - 0x41), base + (b - 0x41)]);
  }

  /// Convenience accessors that fall back to the placeholder string when the
  /// real team name hasn't been filled in yet.
  String get homeDisplay => homeTeamPlaceholder ?? teamA;
  String get awayDisplay => awayTeamPlaceholder ?? teamB;

  bool get isLive     => status == 'live';
  bool get isFinished => status == 'finished';
  bool get isUpcoming => status == 'scheduled';

  /// Returns a copy of this model with the supplied fields overridden.
  /// Scores + status are authored server-side by the sync_wc_matches edge
  /// function (TheSportsDB) and read straight from the DB row; this helper
  /// is kept for any UI-side derivations.
  WcMatchModel copyWith({
    int?     teamAScore,
    int?     teamBScore,
    String?  status,
    int?     liveMinute,
  }) =>
      WcMatchModel(
        id:                  id,
        teamA:               teamA,
        teamB:               teamB,
        teamAFlag:           teamAFlag,
        teamBFlag:           teamBFlag,
        teamAScore:          teamAScore ?? this.teamAScore,
        teamBScore:          teamBScore ?? this.teamBScore,
        matchTime:           matchTime,
        stage:               stage,
        status:              status     ?? this.status,
        isBafanaMatch:       isBafanaMatch,
        liveMinute:          liveMinute ?? this.liveMinute,
        venue:               venue,
        kickoffLocal:        kickoffLocal,
        groupCode:           groupCode,
        roundCode:           roundCode,
        bracketSlot:         bracketSlot,
        apiMatchId:          apiMatchId,
        homeTeamPlaceholder: homeTeamPlaceholder,
        awayTeamPlaceholder: awayTeamPlaceholder,
      );

  factory WcMatchModel.fromRow(Map<String, dynamic> r) {
    return WcMatchModel(
      id:             r['id']              as String,
      teamA:          r['team_a']          as String,
      teamB:          r['team_b']          as String,
      teamAFlag:      r['team_a_flag']     as String? ?? '🏳️',
      teamBFlag:      r['team_b_flag']     as String? ?? '🏳️',
      teamAScore:     (r['team_a_score']   as int?) ?? 0,
      teamBScore:     (r['team_b_score']   as int?) ?? 0,
      matchTime:      DateTime.parse(r['match_time'] as String).toLocal(),
      stage:          r['stage']           as String,
      status:         r['status']          as String? ?? 'scheduled',
      isBafanaMatch:  (r['is_bafana_match'] as bool?) ?? false,
      liveMinute:     (r['live_minute']     as int?) ?? 0,
      venue:          r['venue']          as String?,
      kickoffLocal:   r['kickoff_local']  as String?,
      groupCode:      r['group_code']     as String?,
      roundCode:      (r['round_code']    as String?) ?? 'GROUP',
      bracketSlot:    r['bracket_slot']   as int?,
      apiMatchId:     r['api_match_id']   as String?,
      homeTeamPlaceholder: r['home_team_placeholder'] as String?,
      awayTeamPlaceholder: r['away_team_placeholder'] as String?,
    );
  }

  // Equality includes the mutable live-state fields so a realtime score /
  // status / minute update lands as a DIFFERENT instance even when the row id
  // is unchanged. Without this, ValueNotifier<WcMatchModel> silently swallows
  // updates (same id → equal → no rebuild), which is why the Home ticker can
  // get stuck at 0-0 while the hub list shows the correct live score.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is WcMatchModel &&
       other.id          == id &&
       other.teamAScore  == teamAScore &&
       other.teamBScore  == teamBScore &&
       other.status      == status &&
       other.liveMinute  == liveMinute);

  @override
  int get hashCode =>
      Object.hash(id, teamAScore, teamBScore, status, liveMinute);
}
