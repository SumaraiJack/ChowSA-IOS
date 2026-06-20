// lib/services/world_cup_service.dart
//
// State-management layer for the World Cup feature.
//
// Responsibilities:
//   • Expose [priorityMatch]  — a ValueNotifier<WcMatchModel?> the Home Screen
//     Ticker subscribes to. Always holds the highest-priority match:
//       1. Any live match (is_bafana_match DESC so Bafana floats first)
//       2. The next upcoming match by match_time
//       3. null once the tournament ends (ticker is hidden)
//
//   • Expose [allMatches]     — full fixture list for the Stadium fixture sheet.
//
//   • [stadiumChannelId]      — the community_channels UUID for the global
//     World Cup banter room (inserted by the migration).
//
//   • Realtime subscription via Supabase Postgres-changes so score and status
//     updates reflect instantly without polling — critical during live matches.
//
// Usage:
//   await WorldCupService.instance.init();   // call once in main()
//   ValueListenableBuilder(valueListenable: WorldCupService.instance.priorityMatch, …)

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/wc_match_model.dart';

class WorldCupService {
  WorldCupService._();
  static final instance = WorldCupService._();

  // ── Public state ───────────────────────────────────────────────────────────

  /// The single match to feature on the Home Ticker.
  /// null means no relevant match right now (hide the ticker).
  final ValueNotifier<WcMatchModel?> priorityMatch =
      ValueNotifier<WcMatchModel?>(null);

  /// Full sorted fixture list. Empty until [init] resolves.
  final ValueNotifier<List<WcMatchModel>> allMatches =
      ValueNotifier<List<WcMatchModel>>([]);

  /// The community_channels.id for the global stadium chat room.
  /// Populated by [init] via a one-shot DB lookup.
  ///
  /// Plain field retained for legacy callers. Prefer listening to
  /// [stadiumChannelIdNotifier] so widgets rebuild automatically when this
  /// resolves — it races against the fixture fetch, so widgets that read the
  /// plain field at first build often see null even after init() completes.
  String? stadiumChannelId;

  /// Notifier companion — fires when [stadiumChannelId] first becomes
  /// non-null (and on every subsequent change, though that's rare).
  final ValueNotifier<String?> stadiumChannelIdNotifier =
      ValueNotifier<String?>(null);

  // ── Internals ──────────────────────────────────────────────────────────────

  SupabaseClient get _db => Supabase.instance.client;
  RealtimeChannel? _channel;
  bool _initialised = false;

  /// Per-minute timer that re-emits live matches with a fresh client-side
  /// elapsed-minute count, so the LIVE Xʹ ticker in the home + hub advances
  /// every minute on its own — no cron, no realtime push needed. Stops
  /// automatically once no match is still live.
  Timer? _liveMinuteTicker;

  /// Hard cap on how long a match may stay "LIVE" client-side after
  /// kickoff. 90 min regulation + ~25 min for half-time + stoppage covers
  /// every realistic case. After this window the match is treated as
  /// finished locally so the Home banner / Soccer Hub roll on to the next
  /// fixture even if the upstream cron is slow to flip status.
  static const int _maxLiveMinutes = 115;

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  /// Must be called once at startup (after Supabase.initialize).
  /// Best-effort: never throws — errors are debugPrinted and the feature
  /// degrades to hidden rather than crashing boot.
  Future<void> init() async {
    if (_initialised) return;
    _initialised = true;
    try {
      await Future.wait([
        _fetchAndUpdate(),
        _resolveStadiumChannel(),
      ]);
      _subscribeToChanges();
      _startLiveMinuteTicker();
    } catch (e) {
      debugPrint('WorldCupService.init error: $e');
    }
  }

  void dispose() {
    _liveMinuteTicker?.cancel();
    _liveMinuteTicker = null;
    _channel?.unsubscribe();
    priorityMatch.dispose();
    allMatches.dispose();
    stadiumChannelIdNotifier.dispose();
  }

  // ── Live-minute ticker ─────────────────────────────────────────────────────
  //
  // Fires every 60s, recomputes elapsed minutes for any match whose status is
  // 'live' OR whose kickoff has just passed (and TheSportsDB hasn't flipped
  // upstream yet), and re-emits allMatches + priorityMatch. The notifiers'
  // subscribers (home ticker, hub hero, hub fixture list) rebuild and the
  // LIVE Xʹ counter advances by one. Stops as soon as no match is in play,
  // so it doesn't run permanently on idle days. Restarts on the next fetch
  // when a match transitions to live.

  void _startLiveMinuteTicker() {
    _liveMinuteTicker?.cancel();
    _liveMinuteTicker = Timer.periodic(const Duration(seconds: 60), (_) {
      _tickLiveMinutes();
    });
  }

  void _tickLiveMinutes() {
    final current = allMatches.value;
    if (current.isEmpty) return;
    final now = DateTime.now();
    final liveWindowStart =
        now.subtract(const Duration(minutes: _maxLiveMinutes));
    var anyActive = false;
    var anyDemoted = false;
    final patched = current.map((m) {
      final isFinished = m.isFinished;
      final isLive     = m.isLive;
      final justKicked = !isFinished && !isLive
          && m.matchTime.isBefore(now)
          && m.matchTime.isAfter(liveWindowStart);
      if (!isLive && !justKicked) return m;

      final elapsed = now.difference(m.matchTime).inMinutes;
      // Past the cap → demote locally so the Home banner / Soccer Hub
      // stop showing "LIVE 144ʹ" forever when the upstream cron lags.
      if (elapsed >= _maxLiveMinutes) {
        if (isFinished) return m;
        anyDemoted = true;
        return m.copyWith(status: 'finished');
      }
      anyActive = true;
      final shown = elapsed.clamp(1, _maxLiveMinutes);
      if (m.liveMinute == shown) return m;
      return m.copyWith(liveMinute: shown);
    }).toList(growable: false);

    if (!anyActive && !anyDemoted) return;
    allMatches.value = patched;
    priorityMatch.value = _pickPriority(patched);
  }

  // ── Data fetch ─────────────────────────────────────────────────────────────

  Future<void> _fetchAndUpdate() async {
    final rows = await _db
        .from('wc_matches')
        .select()
        .order('match_time', ascending: true);

    // The DB is now the single source of truth — scores + status are kept
    // current by the `sync_wc_matches` edge function (TheSportsDB, every
    // 15 min via pg_cron). No client-side scraping or hard-coded results.
    final dbMatches = (rows as List)
        .cast<Map<String, dynamic>>()
        .map(WcMatchModel.fromRow)
        .toList();

    // Patch the live-minute counter client-side: TheSportsDB's strProgress is
    // null/0 most of the time, so without this every live match would show
    // "LIVE 0'" forever. Compute elapsed minutes from match_time so the
    // counter ticks in real time, regardless of what the upstream feed says.
    final now = DateTime.now();
    final patched = dbMatches.map((m) {
      if (!m.isLive) return m;
      // Hard local cap — if upstream still says 'live' but kickoff was
      // more than _maxLiveMinutes ago, treat it as finished so the
      // ticker and hub roll forward. The DB will catch up via cron.
      final elapsed = now.difference(m.matchTime).inMinutes;
      if (elapsed >= _maxLiveMinutes) {
        return m.copyWith(status: 'finished');
      }
      final dbMin = m.liveMinute;
      if (dbMin > 0) return m;
      return m.copyWith(liveMinute: elapsed.clamp(1, _maxLiveMinutes));
    }).toList(growable: false);

    allMatches.value = patched;
    priorityMatch.value = _pickPriority(patched);
  }

  /// Next chronologically upcoming match across the whole tournament,
  /// regardless of Bafana involvement. Drives the Home dashboard banner.
  /// Falls back to [priorityMatch] semantics if nothing is in the future.
  WcMatchModel? get nextChronologicalUpcoming {
    final now = DateTime.now();
    final future = allMatches.value
        .where((m) => m.matchTime.isAfter(now))
        .toList()
      ..sort((a, b) => a.matchTime.compareTo(b.matchTime));
    return future.isEmpty ? null : future.first;
  }

  /// Resolves a community_channels.id for the stadium chat.
  ///
  /// Resolution order:
  ///   1. The row tagged `suburb = 'GLOBAL'` — the canonical world-wide
  ///      banter room.
  ///   2. Any row with `category = 'cooking'` — used as a fallback when
  ///      the GLOBAL seed hasn't landed in the live DB yet. This is what
  ///      stops the chat body from spinning on "Connecting to stadium…"
  ///      indefinitely after a fresh seed.
  ///   3. Any community_channels row at all — last-resort so the screen
  ///      can degrade to a real chat room rather than show an error.
  ///   4. null — no rows exist; the view-layer timeout will surface a
  ///      friendly empty state.
  Future<void> _resolveStadiumChannel() async {
    try {
      // Step 1 — GLOBAL cooking channel (the stadium banter room). We pin
      // the category filter because additional GLOBAL rows now exist for
      // other categories (e.g. braai), and an unfiltered `.maybeSingle()`
      // on `suburb='GLOBAL'` throws PGRST116 the moment more than one row
      // matches — which silently broke this resolver after the braai
      // migration and surfaced as "Stadium chat is offline".
      final globalRow = await _db
          .from('community_channels')
          .select('id')
          .eq('suburb',   'GLOBAL')
          .eq('category', 'cooking')
          .maybeSingle();
      var id = globalRow?['id'] as String?;

      // Step 2 — any cooking channel.
      if (id == null) {
        final cookingRow = await _db
            .from('community_channels')
            .select('id')
            .eq('category', 'cooking')
            .order('suburb')
            .limit(1)
            .maybeSingle();
        id = cookingRow?['id'] as String?;
      }

      // Step 3 — any channel.
      if (id == null) {
        final anyRow = await _db
            .from('community_channels')
            .select('id')
            .order('suburb')
            .limit(1)
            .maybeSingle();
        id = anyRow?['id'] as String?;
      }

      stadiumChannelId = id;
      // Fire the notifier so any listening widget rebuilds immediately,
      // even if it was built before this async lookup completed.
      stadiumChannelIdNotifier.value = id;
    } catch (e) {
      debugPrint('WorldCupService: could not resolve stadium channel: $e');
    }
  }

  /// Public re-run hook — used by the stadium screen's timeout fallback so
  /// it can kick the resolver again after a transient failure (network
  /// blip during boot, RLS not ready, etc.) without waiting for an app
  /// restart. Safe to call multiple times.
  Future<String?> retryStadiumChannelResolve() async {
    await _resolveStadiumChannel();
    return stadiumChannelId;
  }

  // ── Priority logic ─────────────────────────────────────────────────────────
  //
  // Selection order — no Bafana bias. The home card and the hub header want
  // the actual current event in the tournament, not only South Africa:
  //   1. Any live match (the WorldCupTicker renders the pulsing LIVE dot +
  //      live minute when this is returned). Earliest kickoff wins if more
  //      than one match is in play.
  //   2. Next upcoming match by kickoff.
  //   3. Most recent finished match within the past 24h (brief grace window).
  //   4. null (ticker hidden).
  //
  // isBafanaMatch is still surfaced by the model so the ticker can light up
  // the "BAFANA UPCOMING 🔥" / "MZANSI HYPE" treatment WHEN South Africa
  // happens to be the chosen match — but it no longer biases the selection.

  WcMatchModel? _pickPriority(List<WcMatchModel> matches) {
    if (matches.isEmpty) return null;
    final now = DateTime.now();

    // Exclude any DB-flagged-live match whose kickoff was longer ago
    // than _maxLiveMinutes — those are stuck rows that the upstream
    // cron hasn't yet flipped to finished.
    final liveAny = matches.where((m) {
      if (!m.isLive) return false;
      return now.difference(m.matchTime).inMinutes < _maxLiveMinutes;
    }).toList()
      ..sort((a, b) => a.matchTime.compareTo(b.matchTime));
    if (liveAny.isNotEmpty) return liveAny.first;

    // Fallback: a match whose kickoff has already passed but TheSportsDB
    // hasn't yet flipped to status='live' (their feed lags 5–15 min behind
    // real kickoff, and the cron only ticks every 15 min — together that
    // leaves a ~30 min window where a kicked-off match stays 'scheduled'
    // and the ticker shows the NEXT upcoming instead of the live one).
    // Treat scheduled rows within 2h30 of kickoff as effectively live and
    // return them with status='live' so the WorldCupTicker renders the
    // pulsing LIVE dot + minute counter.
    final freshKickoff =
        now.subtract(const Duration(minutes: _maxLiveMinutes));
    final justStarted = matches
        .where((m) => m.isUpcoming
            && m.matchTime.isBefore(now)
            && m.matchTime.isAfter(freshKickoff))
        .toList()
      ..sort((a, b) => a.matchTime.compareTo(b.matchTime));
    if (justStarted.isNotEmpty) {
      final m = justStarted.first;
      final elapsedMin = now.difference(m.matchTime).inMinutes;
      return m.copyWith(status: 'live', liveMinute: elapsedMin);
    }

    final upcomingAny = matches
        .where((m) => m.isUpcoming && m.matchTime.isAfter(now))
        .toList()
      ..sort((a, b) => a.matchTime.compareTo(b.matchTime));
    if (upcomingAny.isNotEmpty) return upcomingAny.first;

    final yesterday = now.subtract(const Duration(hours: 24));
    final recentFinished = matches
        .where((m) => m.isFinished && m.matchTime.isAfter(yesterday))
        .toList()
      ..sort((a, b) => b.matchTime.compareTo(a.matchTime));
    if (recentFinished.isNotEmpty) return recentFinished.first;

    return null;
  }

  // ── Realtime subscription ─────────────────────────────────────────────────
  //
  // Listens to INSERT, UPDATE, DELETE on wc_matches so score changes and
  // status transitions (scheduled → live → finished) push instantly to the
  // ticker without any polling.

  void _subscribeToChanges() {
    _channel = _db
        .channel('wc_matches_realtime')
        .onPostgresChanges(
          event:    PostgresChangeEvent.all,
          schema:   'public',
          table:    'wc_matches',
          callback: (_) => _fetchAndUpdate(),
        )
        .subscribe();
  }

  // ── Live stream for Match Center UI ───────────────────────────────────────
  //
  // The ValueNotifier path above is built for the Home Ticker (single
  // priority match). The Match Center / bracket views want the FULL fixture
  // list as a Stream so they can use StreamBuilder and react frame-by-frame
  // to score/status/bracket-resolution changes pushed by the edge function.
  //
  // Implementation: Supabase's `.stream()` provides a continuous snapshot
  // stream of the table. Rows are emitted in full on every INSERT / UPDATE
  // / DELETE — so score ticks, status transitions, and the team-name
  // updates that resolve_bracket_placeholders() writes all flow through the
  // same channel.

  /// Live snapshot of every match in `wc_matches`, ordered by kick-off.
  /// Re-emits on every database change.
  Stream<List<WcMatchModel>> watchAllMatches() {
    return _db
        .from('wc_matches')
        .stream(primaryKey: ['id'])
        .order('match_time')
        .map((rows) => rows
            .map(WcMatchModel.fromRow)
            .toList(growable: false));
  }

  /// Convenience: live snapshot filtered to a single knockout round, e.g.
  /// 'R32', 'R16', 'QF'. Sorted by [bracketSlot] so bracket diagrams render
  /// deterministically. Use one stream per round when laying out a tree.
  Stream<List<WcMatchModel>> watchRound(String roundCode) {
    return watchAllMatches().map((all) {
      final filtered = all.where((m) => m.roundCode == roundCode).toList()
        ..sort((a, b) {
          final ax = a.bracketSlot ?? 0;
          final bx = b.bracketSlot ?? 0;
          return ax.compareTo(bx);
        });
      return filtered;
    });
  }
}
