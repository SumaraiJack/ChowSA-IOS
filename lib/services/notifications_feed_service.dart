// lib/services/notifications_feed_service.dart
//
// THIN COMPAT FACADE — replaced by [InboxController].
//
// All notification + inbox state now flows through
// `InboxController.instance` so the Home Screen bell, the Profile bell
// and the inbox list rebuild from a single ValueNotifier.
//
// Each method on this class forwards into the controller, which already
// owns the `notifications` + `inbox_messages` streams. Once every screen
// has migrated to read `InboxController.instance.state` directly this
// file can be deleted.

import 'package:flutter/foundation.dart';

import '../state/inbox_controller.dart';

class NotificationsFeedService {
  NotificationsFeedService._();
  static final NotificationsFeedService instance = NotificationsFeedService._();

  /// Unified bell badge — UNION of unread shares + unread notifications.
  ValueNotifier<int> get unreadCount =>
      InboxController.instance.unreadCount;

  /// Raw notification rows for screens (e.g. Kitchen Circle invite list)
  /// that still consume the row shape directly.
  ValueNotifier<List<Map<String, dynamic>>> get rows {
    // We expose a derived notifier rebuilt from controller state so
    // callers retain the type they're used to.
    final n = ValueNotifier<List<Map<String, dynamic>>>(
        InboxController.instance.state.value.notifications);
    InboxController.instance.state.addListener(() {
      n.value = InboxController.instance.state.value.notifications;
    });
    return n;
  }

  /// Boot path retained for back-compat; SessionController already starts
  /// the controller on sign-in, so this becomes a no-op.
  void start() {/* no-op — owned by SessionController */}

  Future<void> stop() async {/* no-op — owned by SessionController */}

  Future<void> markAllRead() => InboxController.instance.markAllRead();

  Future<void> markRead(String id) => InboxController.instance.markRead(id);

  Future<void> markAllReadOfType(String type) =>
      InboxController.instance.markAllReadOfType(type);
}
