// lib/services/notification_center.dart
//
// THIN COMPAT FACADE — the real source of truth is now
// [InboxController] in lib/state/inbox_controller.dart.
//
// This file is kept ONLY so legacy call sites that read
// `NotificationCenter.instance.messages.value` or call `.markRead(id)`
// continue to compile and behave identically while screens migrate to
// listening on `InboxController.instance.state` directly. Every method
// here is a one-line forward into the controller.
//
// Once every screen has been migrated, this file can be deleted and the
// callers updated to import `InboxController` directly.

import 'package:flutter/foundation.dart';

import '../models/inbox_message.dart';
import '../state/inbox_controller.dart';

class NotificationCenter {
  NotificationCenter._();
  static final NotificationCenter instance = NotificationCenter._();

  /// Live inbox list — mirrors `InboxController.instance.messages` 1:1.
  ValueNotifier<List<InboxMessage>> get messages =>
      InboxController.instance.messages;

  /// Live unread badge — mirrors `InboxController.instance.unreadCount`.
  ValueNotifier<int> get unreadCount =>
      InboxController.instance.unreadCount;

  /// Hydration is now handled inside `InboxController.start()` (called by
  /// SessionController on sign-in). The bootstrap method is kept as a
  /// no-op for callers that still invoke it on app boot.
  Future<void> bootstrap() async {/* no-op — controlled by SessionController */}

  void replaceAll(List<InboxMessage> list) {
    // No-op against the controller: the realtime stream IS the source of
    // truth. Legacy callers that previously used this to seed local cache
    // can stop calling it — the controller's own back-fill handles it.
  }

  void addIncoming(InboxMessage msg) =>
      InboxController.instance.addIncoming(msg);

  void markRead(String id) =>
      InboxController.instance.markRead(id);

  void markAllRead() =>
      InboxController.instance.markAllRead();

  void markImported(String id) =>
      InboxController.instance.markImported(id);

  void remove(String id) =>
      InboxController.instance.remove(id);

  void clear() {
    // Sign-out path — SessionController already calls dispose() on the
    // controller, which empties its notifiers. This is a no-op kept for
    // back-compat with any caller that still invokes it explicitly.
  }
}
