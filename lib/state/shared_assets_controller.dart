// lib/state/shared_assets_controller.dart
//
// Holds the `shared_assets` realtime stream alive across hub rebuilds so
// the main navigation widget can't accidentally drop the subscription
// when the user backgrounds the app or navigates between tabs.
//
// Previously the subscription lived inside `MainNavigationHub.initState`,
// so a hub rebuild (triggered by theme changes / font swap / hot reload)
// could re-init it twice and double-toast incoming shares. Now lives in
// the SessionController lifecycle.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/shared_assets_service.dart';

class SharedAssetsController {
  SharedAssetsController._();
  static final SharedAssetsController instance = SharedAssetsController._();

  /// Latest unread shares — Home Screen banner listens here.
  final ValueNotifier<List<SharedAsset>> unread =
      ValueNotifier<List<SharedAsset>>(const []);

  /// IDs already surfaced via banner this session — kept here so a hub
  /// rebuild doesn't reset the dedup set.
  final Set<String> announcedIds = <String>{};

  StreamSubscription<List<SharedAsset>>? _sub;
  bool _running = false;

  Future<void> start({required String uid}) async {
    if (_running) return;
    _running = true;
    _sub = SharedAssetsService.instance
        .streamUnreadForCurrentUser()
        .listen(
          (rows) => unread.value = rows,
          onError: (e) {
            if (kDebugMode) debugPrint('[SharedAssetsController] $e');
          },
        );
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    _running = false;
    unread.value = const [];
    announcedIds.clear();
  }

  Future<void> markRead(String id) async {
    // Optimistic local drop.
    unread.value = unread.value.where((a) => a.id != id).toList();
    try {
      await SharedAssetsService.instance.markRead(id);
    } catch (_) {/* stream will reconcile next emission */}
  }
}
