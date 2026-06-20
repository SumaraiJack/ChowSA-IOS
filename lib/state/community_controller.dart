// lib/state/community_controller.dart
//
// Single source of truth for the Community tab. Owns:
//   • the per-suburb `community_channels` stream
//   • one Realtime channel on `channel_messages` — captures INSERT, UPDATE
//     and DELETE so badges decrement when a post is retracted and don't
//     pop back up after a stream re-emit triggered by an unrelated cat.
//   • an in-memory `_readMessageIds` set so locally-cleared posts can't be
//     resurrected by a stale RPC seed.
//   • `messageUpdates` notifier — fires the latest UPDATE row so feed
//     widgets can refresh likes/upvotes without re-entering the screen.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/community_hub_service.dart';

class CommunityState {
  const CommunityState({
    this.suburb           = '',
    this.channels         = const <CommunityChannel>[],
    this.unreadByCategory = const <String, int>{},
    this.isLoading        = false,
  });

  final String                  suburb;
  final List<CommunityChannel>  channels;
  final Map<String, int>        unreadByCategory;
  final bool                    isLoading;

  CommunityChannel? channelFor(ChannelCategory cat) {
    for (final c in channels) {
      if (c.category == cat) return c;
    }
    return null;
  }

  int unreadFor(ChannelCategory cat) =>
      unreadByCategory[cat.wire] ?? 0;
}

class CommunityController {
  CommunityController._();
  static final CommunityController instance = CommunityController._();

  // ── Public reactive surface ─────────────────────────────────────────────────

  final ValueNotifier<CommunityState> state =
      ValueNotifier<CommunityState>(const CommunityState());

  /// Last `channel_messages` UPDATE row (likes / upvote counts / edits).
  /// Feed widgets hold per-message data and `.addListener` here to refresh
  /// in real time without having to re-subscribe to the table themselves.
  final ValueNotifier<Map<String, dynamic>?> messageUpdates =
      ValueNotifier<Map<String, dynamic>?>(null);

  // ── Internal ───────────────────────────────────────────────────────────────

  StreamSubscription<List<CommunityChannel>>? _channelsSub;
  RealtimeChannel? _messagesChannel;
  String? _uid;
  String? _suburb;
  bool _running = false;
  Timer? _unreadDebounce;

  /// channel_id → category wire string. Rebuilt from the channels stream.
  /// Needed because realtime payloads carry channel_id, not the category.
  final Map<String, String> _channelToCategory = {};

  /// IDs of messages the current user has personally marked-read by
  /// opening the containing category. Survives stream re-emits so a fresh
  /// unread-count refresh triggered by an unrelated category can't
  /// resurrect a previously-cleared badge.
  final Set<String> _readMessageIds = {};

  /// Per-category set of unread message IDs observed via realtime since
  /// boot. Adds on INSERT, removes on DELETE / markCategoryViewed.
  final Map<String, Set<String>> _unreadIdsByCategory = {};

  /// Last RPC-derived counts. Used as a seed BEFORE any realtime events
  /// land, then capped by the local id-sets so a stale RPC reply can't
  /// override a locally-cleared category.
  Map<String, int> _serverCounts = {};

  /// Per-category timestamp of the last markCategoryViewed call. Within
  /// `_kViewedCooldown` after a view, any RPC count for that category is
  /// forced to 0 — the server's `last_viewed_at` row update may not have
  /// propagated to the RPC's SELECT plan yet, and the cooldown stops a
  /// re-pulled RPC from bouncing the badge back up.
  final Map<String, DateTime> _recentlyViewedAt = {};
  static const _kViewedCooldown = Duration(seconds: 60);

  // ── Lifecycle ───────────────────────────────────────────────────────────────

  Future<void> start({required String uid}) async {
    if (_running && _uid == uid) return;
    if (_running) await dispose();
    _running = true;
    _uid     = uid;
    state.value = const CommunityState(isLoading: true);
    await _resolveSuburbAndSubscribe();
  }

  Future<void> dispose() async {
    _unreadDebounce?.cancel();
    _unreadDebounce = null;
    await _channelsSub?.cancel();
    await _messagesChannel?.unsubscribe();
    _channelsSub = null;
    _messagesChannel = null;
    _suburb = null;
    _uid    = null;
    _running = false;
    _channelToCategory.clear();
    _readMessageIds.clear();
    _unreadIdsByCategory.clear();
    _serverCounts = {};
    _recentlyViewedAt.clear();
    messageUpdates.value = null;
    state.value = const CommunityState();
  }

  Future<void> refreshSuburb() async {
    if (!_running) return;
    await _resolveSuburbAndSubscribe();
  }

  /// Mark a category as viewed. Moves every locally-tracked unread id for
  /// that category into `_readMessageIds` so a subsequent stream re-emit
  /// can't bring them back, sets the cooldown so the RPC reply can't
  /// either, and fires the server-side mark-viewed RPC.
  Future<void> markCategoryViewed(ChannelCategory cat) async {
    final wire = cat.wire;
    final ids = _unreadIdsByCategory[wire];
    if (ids != null && ids.isNotEmpty) {
      _readMessageIds.addAll(ids);
      ids.clear();
    }
    _recentlyViewedAt[wire] = DateTime.now();
    // Local count goes to 0 immediately; RPC reconciles in the background.
    _emit();
    final suburb = _suburb;
    if (suburb == null) return;
    try {
      await Supabase.instance.client.rpc(
        'mark_category_viewed',
        params: {'p_suburb': suburb, 'p_category': wire},
      );
      // After the server acknowledges the view, pull fresh counts so
      // _serverCounts[wire] reflects the new last_viewed_at (0 for this
      // category). Without this refresh, _serverCounts holds the pre-view
      // count indefinitely. Once the 60s cooldown expires, _combinedCounts
      // falls back to that stale server value and re-lights the badge —
      // the "ghost notification" bug.
      unawaited(_refreshUnreadCounts(suburb));
    } catch (_) {/* best-effort */}
  }

  // ── Internal wiring ─────────────────────────────────────────────────────────

  Future<void> _resolveSuburbAndSubscribe() async {
    String suburb;
    try {
      suburb = await CommunityHubService.instance.resolveActiveSuburb();
    } catch (_) {
      suburb = 'Table View';
    }
    _suburb = suburb;

    // Pre-populate the channel→category map with a one-shot fetch BEFORE
    // starting the realtime subscription. Without this, the first realtime
    // INSERT that arrives while the stream hasn't emitted yet finds an empty
    // map, resolves wire==null, and silently discards the badge increment
    // (the "missing notifications" bug).
    try {
      final seed = await CommunityHubService.instance.fetchChannelsForSuburb(suburb);
      _channelToCategory
        ..clear()
        ..addEntries(seed.map((c) => MapEntry(c.id, c.category.wire)));
    } catch (_) {/* best-effort; stream will populate shortly */}

    await _channelsSub?.cancel();
    _channelsSub = CommunityHubService.instance
        .watchChannelsForSuburb(suburb)
        .listen(
          (channels) {
            _channelToCategory
              ..clear()
              ..addEntries(channels.map((c) => MapEntry(c.id, c.category.wire)));
            state.value = CommunityState(
              suburb:           suburb,
              channels:         channels,
              unreadByCategory: _combinedCounts(),
              isLoading:        false,
            );
          },
          onError: (e) {
            if (kDebugMode) debugPrint('[CommunityController] channels: $e');
          },
        );

    await _subscribeMessageEvents(suburb);
    unawaited(_refreshUnreadCounts(suburb));
  }

  Future<void> _subscribeMessageEvents(String suburb) async {
    await _messagesChannel?.unsubscribe();
    _messagesChannel = Supabase.instance.client
        .channel('community-hub:$suburb')
        .onPostgresChanges(
          event:  PostgresChangeEvent.insert,
          schema: 'public',
          table:  'channel_messages',
          callback: (p) => _handleInsert(p.newRecord, suburb),
        )
        .onPostgresChanges(
          event:  PostgresChangeEvent.update,
          schema: 'public',
          table:  'channel_messages',
          callback: (p) => _handleUpdate(p.newRecord, p.oldRecord, suburb),
        )
        .onPostgresChanges(
          event:  PostgresChangeEvent.delete,
          schema: 'public',
          table:  'channel_messages',
          callback: (p) => _handleDelete(p.oldRecord, suburb),
        )
        .subscribe();
  }

  // ── Realtime event handlers ─────────────────────────────────────────────────

  void _handleInsert(Map<String, dynamic> row, String suburb) {
    final id    = row['id'] as String?;
    final chId  = row['channel_id'] as String?;
    if (id == null || chId == null) return;
    // Don't count the user's own posts as unread — the server RPC already
    // filters these, but the local realtime path must match or sharing a
    // recipe to What's Cooking lights your own category badge.
    if (row['user_id'] == _uid) return;
    if (_readMessageIds.contains(id)) return; // never resurrect a cleared one
    final wire = _channelToCategory[chId];
    if (wire != null) {
      _unreadIdsByCategory.putIfAbsent(wire, () => <String>{}).add(id);
      _emit();
    }
    _scheduleUnreadRefresh(suburb);
  }

  void _handleDelete(Map<String, dynamic> row, String suburb) {
    final id = row['id'] as String?;
    if (id == null) return;
    // Purge from every tracking set so a self-delete drops the badge to 0
    // and a delete of a previously-read post can't leak into _readMessageIds
    // either (in case the same id is later reissued).
    _readMessageIds.remove(id);
    var changed = false;
    for (final set in _unreadIdsByCategory.values) {
      if (set.remove(id)) changed = true;
    }
    if (changed) _emit();
    _scheduleUnreadRefresh(suburb);
  }

  void _handleUpdate(
    Map<String, dynamic> newRow,
    Map<String, dynamic> oldRow,
    String suburb,
  ) {
    // Edits / status flips: if a post becomes hidden, treat as delete.
    final newStatus = newRow['status'] as String?;
    if (newStatus == 'deleted' || newStatus == 'hidden') {
      _handleDelete(newRow, suburb);
    }
    // Fan out the row so feed widgets can refresh likes/upvotes/edits
    // in real time without holding their own subscription.
    messageUpdates.value = Map<String, dynamic>.from(newRow);
  }

  void _scheduleUnreadRefresh(String suburb) {
    _unreadDebounce?.cancel();
    _unreadDebounce = Timer(const Duration(milliseconds: 350), () {
      unawaited(_refreshUnreadCounts(suburb));
    });
  }

  Future<void> _refreshUnreadCounts(String suburb) async {
    try {
      final rows = await Supabase.instance.client.rpc(
        'count_unread_per_category',
        params: {'p_suburb': suburb},
      );
      if (rows is! List) return;
      final next = <String, int>{};
      for (final r in rows) {
        if (r is Map) {
          final name  = r['category_name'] as String?;
          final count = (r['unread_count'] as num?)?.toInt() ?? 0;
          if (name != null) next[name] = count;
        }
      }
      _serverCounts = next;
      _emit();
    } catch (e) {
      if (kDebugMode) debugPrint('[CommunityController] unread: $e');
    }
  }

  // ── Emit / combine ──────────────────────────────────────────────────────────

  /// Merges the server-seed counts with the local id-sets and the
  /// recently-viewed cooldown so a stream re-emit triggered by an
  /// unrelated category can never resurrect a cleared badge.
  Map<String, int> _combinedCounts() {
    final out = <String, int>{};
    final now = DateTime.now();
    final keys = <String>{..._serverCounts.keys, ..._unreadIdsByCategory.keys};
    for (final wire in keys) {
      final viewedAt = _recentlyViewedAt[wire];
      final local    = _unreadIdsByCategory[wire]?.length ?? 0;
      if (viewedAt != null && now.difference(viewedAt) < _kViewedCooldown) {
        // Cooldown suppresses only the (potentially-stale) RPC count.
        // Local realtime INSERTs that landed AFTER the view must still
        // surface — otherwise new messages posted while the cooldown
        // window is open get swallowed and the badge gets "stuck" at 0
        // until the next unrelated event fires _emit().
        out[wire] = local;
        continue;
      }
      final server = _serverCounts[wire] ?? 0;
      // Once we've started tracking a category via realtime, the local
      // set is authoritative (it filters out _readMessageIds). Fall back
      // to the server seed only when we have no realtime data yet.
      out[wire] = local > 0 ? local : server;
    }
    return out;
  }

  void _emit() {
    state.value = CommunityState(
      suburb:           state.value.suburb,
      channels:         state.value.channels,
      unreadByCategory: _combinedCounts(),
      isLoading:        state.value.isLoading,
    );
  }
}
