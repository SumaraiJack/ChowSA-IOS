// lib/state/session_controller.dart
//
// The ONLY place that calls start()/dispose() on the other controllers.
//
// Listens to Supabase auth state changes:
//   • signedIn       → boot all controllers with the user id + handle
//   • signedOut      → tear them down + clear local cache notifiers
//   • tokenRefreshed → no-op (controllers already hold a live session)
//
// Wired into the widget tree by _AppScope in main.dart.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'community_controller.dart';
import 'inbox_controller.dart';
import 'meal_plan_controller.dart';
import 'shared_assets_controller.dart';

class SessionController {
  SessionController._();
  static final SessionController instance = SessionController._();

  StreamSubscription<AuthState>? _authSub;
  bool _initialised = false;

  /// Public flag for screens that need to know whether the controllers
  /// have a hot session attached (e.g. show skeleton vs. empty state).
  final ValueNotifier<bool> isAuthenticated = ValueNotifier<bool>(false);

  Future<void> init() async {
    if (_initialised) return;
    _initialised = true;
    final client = Supabase.instance.client;

    // Boot for the current session (if any) immediately.
    final user = client.auth.currentUser;
    if (user != null) {
      await _bootAll(user);
    }

    _authSub = client.auth.onAuthStateChange.listen((event) {
      final u = event.session?.user;
      switch (event.event) {
        case AuthChangeEvent.signedIn:
        case AuthChangeEvent.initialSession:
        case AuthChangeEvent.userUpdated:
          if (u != null) unawaited(_bootAll(u));
          break;
        case AuthChangeEvent.signedOut:
          unawaited(_teardownAll());
          break;
        default:
          break;
      }
    });
  }

  Future<void> dispose() async {
    await _authSub?.cancel();
    _authSub = null;
    await _teardownAll();
    _initialised = false;
  }

  // ── Boot / teardown ─────────────────────────────────────────────────────────

  Future<void> _bootAll(User user) async {
    final handle = _resolveHandle(user);
    try {
      await Future.wait([
        InboxController.instance.start(uid: user.id, handle: handle),
        CommunityController.instance.start(uid: user.id),
        MealPlanController.instance.start(uid: user.id),
        SharedAssetsController.instance.start(uid: user.id),
      ]);
      isAuthenticated.value = true;
    } catch (e) {
      if (kDebugMode) debugPrint('[SessionController] boot: $e');
    }
  }

  Future<void> _teardownAll() async {
    isAuthenticated.value = false;
    await Future.wait([
      InboxController.instance.dispose(),
      CommunityController.instance.dispose(),
      MealPlanController.instance.dispose(),
      SharedAssetsController.instance.dispose(),
    ]);
  }

  String _resolveHandle(User u) {
    final m = u.userMetadata;
    final h = m?['handle'] as String?;
    if (h != null && h.isNotEmpty) return h;
    final username = m?['username'] as String?;
    if (username != null && username.isNotEmpty) return username;
    final email = u.email;
    if (email != null && email.isNotEmpty) return email.split('@').first;
    return 'Chef';
  }
}
