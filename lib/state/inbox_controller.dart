// lib/state/inbox_controller.dart
//
// Single source of truth for the inbox bell + Profile bell + inbox list.
//
// Owns two live Supabase streams and reconciles them into ONE reactive state:
//   • `inbox_messages` — actual shopping/recipe/meal-plan shares
//   • `notifications`  — global notification feed used by the bell badges
//
// Anything that previously called `NotificationCenter.instance.*` or
// `NotificationsFeedService.instance.*` now flows through here. Those two
// services are kept as thin compat facades so older call sites still work,
// but all mutation + read paths land in this controller.
//
// Lifecycle:
//   • `start(uid)`  — called by SessionController on sign-in / app boot.
//   • `dispose()`   — called by SessionController on sign-out.
// Re-entering `start` while already running is a no-op (idempotent).

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/inbox_message.dart';

class InboxState {
  const InboxState({
    this.messages         = const <InboxMessage>[],
    this.unreadInboxCount = 0,
    this.notifications    = const <Map<String, dynamic>>[],
    this.unreadBellCount  = 0,
  });

  /// Shopping-list / recipe / meal-plan shares — what the InboxScreen lists.
  final List<InboxMessage> messages;

  /// Unread count specifically for inbox shares.
  final int unreadInboxCount;

  /// Raw rows from the `notifications` table. Surfaces invites, system
  /// messages, etc. — anything that should light the Profile bell.
  final List<Map<String, dynamic>> notifications;

  /// Total unread for the bell badge — UNION of unread shares + unread
  /// notification rows. Both bells (Home Screen + Profile) read this.
  final int unreadBellCount;
}

class InboxController {
  InboxController._();
  static final InboxController instance = InboxController._();

  // ── Public reactive surface ─────────────────────────────────────────────────

  final ValueNotifier<InboxState> state =
      ValueNotifier<InboxState>(const InboxState());

  /// Convenience pointer for callers that only need the badge int.
  /// Both bell icons listen to this single notifier.
  final ValueNotifier<int> unreadCount = ValueNotifier<int>(0);

  /// Back-compat shim — old call sites read `messages.value` directly.
  /// Mirrors `state.value.messages` on every emission.
  final ValueNotifier<List<InboxMessage>> messages =
      ValueNotifier<List<InboxMessage>>(const []);

  // ── Internal state ──────────────────────────────────────────────────────────

  static const _prefKey = 'inbox_messages_v1';

  StreamSubscription<List<Map<String, dynamic>>>? _inboxSub;
  StreamSubscription<List<Map<String, dynamic>>>? _notifSub;
  RealtimeChannel? _inboxInsertChannel;
  String? _userHandle;
  String? _uid;
  bool _running = false;
  bool _hydrated = false;

  // Local view of inbox rows from the stream. Stream emissions are the
  // authoritative source — local mutations (markRead, remove) update this
  // map optimistically and the next stream tick reconciles.
  final Map<String, InboxMessage> _byId = {};

  // ── Lifecycle ───────────────────────────────────────────────────────────────

  Future<void> start({required String uid, required String handle}) async {
    if (_running && _uid == uid) return;
    if (_running) {
      // User changed — tear down first.
      await dispose();
    }
    _running    = true;
    _uid        = uid;
    _userHandle = handle.trim().toLowerCase();

    await _hydrateFromCache();

    final db = Supabase.instance.client;

    // ── inbox_messages stream — filtered by receiver_handle ─────────────────
    _inboxSub = db
        .from('inbox_messages')
        .stream(primaryKey: ['id'])
        .order('created_at')
        .listen(
          _onInboxRows,
          onError: (e) {
            if (kDebugMode) debugPrint('[InboxController] inbox stream: $e');
          },
        );

    // ── notifications stream — bell badge unified counter ──────────────────
    _notifSub = db
        .from('notifications')
        .stream(primaryKey: ['id'])
        .eq('recipient_id', uid)
        .order('created_at')
        .listen(
          _onNotificationRows,
          onError: (e) {
            if (kDebugMode) debugPrint('[InboxController] notif stream: $e');
          },
        );

    // ── Back-fill any rows missed while offline ─────────────────────────────
    await _backfillMissed();
  }

  Future<void> dispose() async {
    await _inboxSub?.cancel();
    await _notifSub?.cancel();
    await _inboxInsertChannel?.unsubscribe();
    _inboxSub = null;
    _notifSub = null;
    _inboxInsertChannel = null;
    _byId.clear();
    _uid        = null;
    _userHandle = null;
    _running    = false;
    state.value = const InboxState();
    unreadCount.value = 0;
    messages.value    = const [];
  }

  // ── Stream handlers ─────────────────────────────────────────────────────────

  void _onInboxRows(List<Map<String, dynamic>> rows) {
    final handle = _userHandle;
    if (handle == null) return;
    // Stream is unfiltered (Supabase's filter chain doesn't compose with
    // .stream() on every PostgREST version) — filter client-side.
    final next = <String, InboxMessage>{};
    for (final r in rows) {
      final rcv = (r['receiver_handle'] as String?)?.toLowerCase() ?? '';
      if (rcv != handle) continue;
      final status = r['status'] as String?;
      if (status == 'deleted') continue;
      try {
        final msg = InboxMessage.fromInboxRow(r);
        // Server-side `is_read` is authoritative when the row has been
        // BUMPED (resend bumps created_at). If the server's createdAt is
        // strictly newer than what we held locally, treat the row as a
        // fresh notification — drop the optimistic isRead/isImported
        // flags so the badge lights up again. Otherwise, preserve local
        // flips that haven't round-tripped yet to avoid a flicker.
        final serverIsRead = r['is_read'] == true;
        final prior = _byId[msg.id];
        if (prior != null) {
          final isResend = msg.receivedAt.isAfter(prior.receivedAt);
          if (isResend) {
            // Resend — trust server completely.
            msg.isRead     = serverIsRead;
            msg.isImported = status == 'imported';
          } else {
            // Same row, no resend — keep optimistic local flips.
            msg.isRead     = msg.isRead     || prior.isRead;
            msg.isImported = msg.isImported || prior.isImported;
          }
        }
        // Status='imported' on the server implies local imported.
        if (status == 'imported') msg.isImported = true;
        next[msg.id] = msg;
      } catch (e) {
        if (kDebugMode) debugPrint('[InboxController] parse: $e');
      }
    }
    _byId
      ..clear()
      ..addAll(next);
    _emit();
    unawaited(_persist());
  }

  void _onNotificationRows(List<Map<String, dynamic>> rows) {
    final unread = rows.where((r) => r['is_read'] != true).length;
    _emit(notifRows: rows, notifUnread: unread);
  }

  // ── Mutations (optimistic, then persist) ────────────────────────────────────

  /// Marks a single inbox message as read. Optimistic local flip + server
  /// write to both `inbox_messages.is_read` and the matching
  /// `notifications.is_read` row so both bells clear in the same frame.
  Future<void> markRead(String id) async {
    final m = _byId[id];
    if (m == null || m.isRead) {
      // Still flip the matching notification row in case the share lives
      // there but not in the inbox table (e.g. invite-style payload).
      unawaited(_markNotificationRead(id));
      return;
    }
    m.isRead = true;
    _emit();
    unawaited(_persist());
    try {
      await Supabase.instance.client
          .from('inbox_messages')
          .update({'is_read': true})
          .eq('id', id);
    } catch (e) {
      if (kDebugMode) debugPrint('[InboxController] markRead: $e');
    }
    unawaited(_markNotificationRead(id));
  }

  Future<void> _markNotificationRead(String id) async {
    try {
      await Supabase.instance.client
          .from('notifications')
          .update({'is_read': true})
          .eq('id', id);
    } catch (_) {/* best-effort */}
  }

  /// Bulk mark every unread inbox + notification row as read for this user.
  Future<void> markAllRead() async {
    var changed = false;
    for (final m in _byId.values) {
      if (!m.isRead) { m.isRead = true; changed = true; }
    }
    if (changed) {
      _emit();
      unawaited(_persist());
    }
    final uid = _uid;
    final handle = _userHandle;
    if (uid == null || handle == null) return;
    try {
      final db = Supabase.instance.client;
      await db
          .from('inbox_messages')
          .update({'is_read': true})
          .eq('receiver_handle', handle)
          .eq('is_read', false);
      await db
          .from('notifications')
          .update({'is_read': true})
          .eq('recipient_id', uid)
          .eq('is_read', false);
    } catch (e) {
      if (kDebugMode) debugPrint('[InboxController] markAllRead: $e');
    }
  }

  /// Mark all unread notifications of a given `type` as read. Used by the
  /// shared-assets banner OPEN handler so the bell badge drops cleanly.
  Future<void> markAllReadOfType(String type) async {
    final uid = _uid;
    if (uid == null) return;
    try {
      await Supabase.instance.client
          .from('notifications')
          .update({'is_read': true})
          .eq('recipient_id', uid)
          .eq('type', type)
          .eq('is_read', false);
    } catch (e) {
      if (kDebugMode) debugPrint('[InboxController] markAllReadOfType: $e');
    }
  }

  /// Flag a message as imported (recipe saved / list claimed). Implies read.
  /// Server status flips to `imported` so the missed-back-fill skips it.
  Future<void> markImported(String id) async {
    final m = _byId[id];
    if (m != null) {
      var changed = false;
      if (!m.isImported) { m.isImported = true; changed = true; }
      if (!m.isRead)     { m.isRead     = true; changed = true; }
      if (changed) {
        _emit();
        unawaited(_persist());
      }
    }
    try {
      await Supabase.instance.client
          .from('inbox_messages')
          .update({'status': 'imported', 'is_read': true})
          .eq('id', id);
    } catch (e) {
      if (kDebugMode) debugPrint('[InboxController] markImported: $e');
    }
    unawaited(_markNotificationRead(id));
  }

  /// Soft-deletes a message — UI removes it instantly, server marks
  /// `status='deleted'` so the missed-back-fill keeps it hidden.
  Future<void> remove(String id) async {
    final removed = _byId.remove(id);
    if (removed != null) {
      _emit();
      unawaited(_persist());
    }
    try {
      await Supabase.instance.client
          .from('inbox_messages')
          .update({'status': 'deleted'})
          .eq('id', id);
    } catch (e) {
      if (kDebugMode) debugPrint('[InboxController] remove: $e');
    }
  }

  /// Compat path for the realtime hub: callers can push a freshly-parsed
  /// InboxMessage into local state immediately (e.g. from a Realtime INSERT
  /// payload) without waiting for the stream tick.
  void addIncoming(InboxMessage msg) {
    if (_byId.containsKey(msg.id)) return;
    _byId[msg.id] = msg;
    _emit();
    unawaited(_persist());
  }

  // ── Persistence + back-fill ─────────────────────────────────────────────────

  Future<void> _hydrateFromCache() async {
    if (_hydrated) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw   = prefs.getString(_prefKey);
      if (raw != null) {
        final list = (jsonDecode(raw) as List<dynamic>)
            .map((e) => InboxMessage.fromJson(e as Map<String, dynamic>))
            .toList();
        for (final m in list) {
          _byId[m.id] = m;
        }
        _emit();
      }
    } catch (_) {/* corrupt or missing — ignore */}
    _hydrated = true;
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefKey,
        jsonEncode(_byId.values.map((m) => m.toJson()).toList()),
      );
    } catch (_) {/* best-effort */}
  }

  Future<void> _backfillMissed() async {
    final handle = _userHandle;
    if (handle == null) return;
    try {
      final rows = await Supabase.instance.client
          .from('inbox_messages')
          .select()
          .eq('receiver_handle', handle)
          .not('status', 'in', '("deleted","imported")')
          .order('created_at', ascending: false)
          .limit(50);
      for (final r in rows) {
        try {
          final msg = InboxMessage.fromInboxRow(r);
          _byId.putIfAbsent(msg.id, () => msg);
        } catch (_) {}
      }
      _emit();
      unawaited(_persist());
    } catch (e) {
      if (kDebugMode) debugPrint('[InboxController] backfill: $e');
    }
  }

  // ── Internal emit ───────────────────────────────────────────────────────────

  void _emit({
    List<Map<String, dynamic>>? notifRows,
    int? notifUnread,
  }) {
    final list = _byId.values.toList()
      ..sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
    final dedup = _dedupe(list);
    final unreadInbox = dedup.where((m) => !m.isRead).length;
    final notifs = notifRows ?? state.value.notifications;
    // Bell badge mirrors EXACTLY what the inbox screen renders — i.e.
    // unread rows from `inbox_messages`. System `notifications` rows are
    // tracked for other surfaces (Kitchen Circle invite tile etc.) but
    // are NOT added into the envelope/bell badge, because they can't be
    // seen or cleared from the inbox list — adding them produced the
    // "badge shows 4, inbox shows 2" mismatch.
    final bell = unreadInbox;
    state.value = InboxState(
      messages:         dedup,
      unreadInboxCount: unreadInbox,
      notifications:    notifs,
      unreadBellCount:  bell,
    );
    unreadCount.value = bell;
    messages.value    = dedup;
  }

  /// Collapse multiple cards from the same sender+listName signature so the
  /// recipient never sees the same shared item twice.
  List<InboxMessage> _dedupe(List<InboxMessage> list) {
    final bySig = <String, InboxMessage>{};
    for (final m in list) {
      final sig = '${m.fromHandle.toLowerCase()}|${m.listName.toLowerCase()}';
      final existing = bySig[sig];
      if (existing == null || m.receivedAt.isAfter(existing.receivedAt)) {
        bySig[sig] = m;
      }
    }
    final out = bySig.values.toList()
      ..sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
    return out;
  }
}
