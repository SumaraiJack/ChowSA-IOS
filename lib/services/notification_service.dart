// lib/services/notification_service.dart
//
// Native push-notification pipeline for ChowSA. Three trigger sources today:
//   • Kitchen Circle invites          (friendships row insert)
//   • Shopping list shares             (shopping_list_shares row insert)
//   • Meal-planner sends               (inbox_messages row, type='meal_plan')
//
// Architecture:
//
//   ┌──────────────┐   trigger      ┌─────────────────┐   FCM API
//   │   Supabase   │ ─────────────► │  Edge Function  │ ──────────► Google FCM
//   │   Postgres   │   (NOTIFY)     │ send_push.ts    │
//   └──────────────┘                └─────────────────┘                │
//                                                                     ▼
//                                           ┌──────────────────────────────┐
//                                           │ User device — onMessage /    │
//                                           │ onBackgroundMessage handlers │
//                                           └──────────────────────────────┘
//
// Token storage: profiles.fcm_token (single device per user for v1; upgrade
// to a separate `device_tokens` table when multi-device support is needed).
//
// The background handler MUST be a top-level function (not a class method
// or closure) because the OS spins up a fresh Dart isolate to dispatch it.

import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../firebase_options.dart';
import '../views/channel_chat_screen.dart';
import '../views/community_feed_screen.dart';
import '../views/meal_planner_screen.dart';

// ═══════════════════════════════════════════════════════════════════════════
//   Top-level background handler
// ═══════════════════════════════════════════════════════════════════════════
//
// Triggered by Firebase when a message arrives while the app is in the
// background OR fully terminated. Must be annotated `@pragma('vm:entry-point')`
// so tree-shaking doesn't strip it from release builds. Keep this function
// minimal and side-effect-free beyond surfacing the notification — heavy
// work belongs in the foreground onMessage handler.

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  // IMPORTANT: do NOT render a local notification here when the FCM message
  // carries a `notification` block. While the app is backgrounded/terminated
  // Android AUTO-DISPLAYS that block on the 'chowsa_default' channel, so
  // showing a flutter_local_notifications mirror on top produced TWO
  // notifications for one event (the duplicate-share-notification bug).
  // Only data-only messages (no notification block) need a manual render.
  if (message.notification == null && message.data.isNotEmpty) {
    await NotificationService._showLocal(
      title: message.data['title'] as String? ?? 'ChowSA',
      body:  message.data['body']  as String? ?? '',
      payload: message.data['route'] as String?,
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//   NotificationService — singleton
// ═══════════════════════════════════════════════════════════════════════════

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  /// Global navigator key — handed to MaterialApp so taps on system-tray
  /// notifications can push the right screen without needing a
  /// BuildContext. Routed by [_onMessageOpenedApp] below.
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  static final FlutterLocalNotificationsPlugin _local =
      FlutterLocalNotificationsPlugin();

  /// Android notification channel used for every ChowSA push. iOS uses its
  /// own per-message routing so it's not relevant there.
  ///
  /// Importance.max + enableLights + enableVibration is the recipe Android
  /// uses to actually pop a heads-up banner over the lock screen / other
  /// apps. Importance.high alone is silently demoted to a tray entry on
  /// many OEM ROMs (Xiaomi, Samsung) — the user's "no heads-up" report.
  static const AndroidNotificationChannel _channel = AndroidNotificationChannel(
    'chowsa_default',
    'ChowSA notifications',
    description:
        'Kitchen Circle invites, shopping list shares, and meal-plan sends.',
    importance:       Importance.max,
    enableLights:     true,
    enableVibration:  true,
    playSound:        true,
  );

  bool _initialised = false;

  /// Call from main.dart AFTER Supabase.initialize() so we have an auth
  /// session when uploading the token. Safe to call multiple times.
  Future<void> init() async {
    if (_initialised) return;
    _initialised = true;

    await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

    // 1) Local notification plugin — used by the background handler AND
    //    for showing foreground messages (Android won't auto-render those).
    const initSettings = InitializationSettings(
      android: AndroidInitializationSettings('@drawable/ic_stat_notification'),
    );
    await _local.initialize(initSettings);
    await _local
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_channel);

    // 2) Runtime permission prompt (Android 13+ / API 33+).
    await FirebaseMessaging.instance.requestPermission(
      alert: true, badge: true, sound: true,
    );

    // 3) Wire handlers.
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
    FirebaseMessaging.onMessage.listen(_onForegroundMessage);
    FirebaseMessaging.onMessageOpenedApp.listen(_onMessageOpenedApp);

    // Cold-launch path: the app was fully terminated and the user tapped
    // a heads-up notification to open it. onMessageOpenedApp DOESN'T fire
    // in that case — only getInitialMessage() does.
    final initial = await FirebaseMessaging.instance.getInitialMessage();
    if (initial != null) {
      // Defer so the navigator key has had a chance to mount.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _onMessageOpenedApp(initial);
      });
    }

    // 4) Push the device token to profiles.fcm_token so the Edge Function
    //    can target this user. Listen for token refresh too — Google
    //    rotates these on app reinstall, restore from backup, etc.
    await _syncToken();
    FirebaseMessaging.instance.onTokenRefresh.listen((_) => _syncToken());

    // 5) Re-sync on every auth state change. init() runs fire-and-forget at
    //    cold boot IN PARALLEL with session restore, so the first _syncToken()
    //    above almost always no-ops (currentUser is still null). And after a
    //    reinstall/rebuild the token is stable for the whole session, so
    //    onTokenRefresh never fires either — leaving the OLD token from the
    //    previous build in profiles.fcm_token. FCM then rejects every push
    //    with UNREGISTERED and no system notification ever shows. Writing the
    //    token once the session lands (signedIn / initialSession / refresh)
    //    fixes that.
    Supabase.instance.client.auth.onAuthStateChange.listen((data) {
      switch (data.event) {
        case AuthChangeEvent.signedIn:
        case AuthChangeEvent.initialSession:
        case AuthChangeEvent.tokenRefreshed:
          unawaited(_syncToken());
        default:
          break;
      }
    });
  }

  /// Foreground messages: Android does NOT auto-render the system tray
  /// notification while the app is in the foreground, so we surface it
  /// ourselves via flutter_local_notifications.
  Future<void> _onForegroundMessage(RemoteMessage message) async {
    await _showLocal(
      title:   message.notification?.title ?? 'ChowSA',
      body:    message.notification?.body  ?? '',
      payload: message.data['route'] as String?,
    );
  }

  /// User tapped the system notification while the app was backgrounded.
  /// `message.data['route']` is the deep-link path emitted by the Edge
  /// Function. Currently supported:
  ///   • '/meal-plan'         — shared meal planner payload
  ///   • '/community/post'    — @mention or post-level deep-link
  ///   • '/community/channel' — @mention inside a per-suburb chat room
  void _onMessageOpenedApp(RemoteMessage message) {
    _route(message.data);
  }

  /// Resolves a notification's `route` payload to an actual screen push.
  /// The full FCM `data` map is passed through so per-route handlers can
  /// read whatever fields they need (post_id, channel_id, message_id,
  /// shared_asset_id, …) without an explosion of named parameters.
  Future<void> _route(Map<String, dynamic> data) async {
    final nav   = navigatorKey.currentState;
    final route = data['route'] as String?;
    if (nav == null || route == null) return;

    switch (route) {
      case '/meal-plan':
        await _routeMealPlan(nav, data['shared_asset_id'] as String?);

      case '/community/post':
        // Push the community feed and tell it which post to scroll to.
        // The feed's State reads `initialPostId` once on mount, then
        // hunts for the matching post id in its hydrated list, scrolls
        // it into view, and briefly highlights it.
        nav.push(MaterialPageRoute<void>(
          builder: (_) => CommunityFeedScreen(
            initialPostId: data['post_id'] as String?,
          ),
        ));

      case '/community/channel':
        // Push the per-suburb chat with the channel id, and pass the
        // mentioned message id so the existing pinned-banner jump-to
        // scaffolding can scroll it into view + flash the highlight.
        final channelId = data['channel_id'] as String?;
        if (channelId == null) return;
        nav.push(MaterialPageRoute<void>(
          builder: (_) => ChannelChatScreen(
            channelId:        channelId,
            isAdmin:          false,
            initialMessageId: data['message_id'] as String?,
          ),
        ));
    }
  }

  Future<void> _routeMealPlan(NavigatorState nav, String? sharedAssetId) async {
    Map<String, dynamic>? payload;
    if (sharedAssetId != null) {
      try {
        final row = await Supabase.instance.client
            .from('shared_assets')
            .select('payload')
            .eq('id', sharedAssetId)
            .maybeSingle();
        payload = (row?['payload'] as Map?)?.cast<String, dynamic>();
      } catch (e) {
        if (kDebugMode) debugPrint('[NotificationService] payload fetch: $e');
      }
    }
    nav.push(MaterialPageRoute<void>(
      builder: (_) => MealPlannerScreen(incomingShare: payload),
    ));
  }

  /// Dismisses every active ChowSA notification — both ones rendered by
  /// the local plugin (foreground path) AND ones posted directly by
  /// FCM into the Android system tray (background/terminated path),
  /// because [FlutterLocalNotificationsPlugin.cancelAll] delegates to
  /// `NotificationManagerCompat.cancelAll()` on Android, which covers
  /// the whole NotificationManager — not just our own posts.
  ///
  /// Use this from any state transition that should "consume" a
  /// notification — e.g. accepting / declining a Kitchen Circle invite,
  /// opening a shared shopping list, viewing the inbox. The launcher
  /// badge count resets to 0 once every active notification is gone.
  Future<void> cancelAllShadeNotifications() async {
    try {
      await _local.cancelAll();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[NotificationService] cancelAll failed: $e');
      }
    }
  }

  static Future<void> _showLocal({
    required String  title,
    required String  body,
    String?          payload,
  }) async {
    await _local.show(
      DateTime.now().millisecondsSinceEpoch.remainder(1 << 31),
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          _channel.id,
          _channel.name,
          channelDescription: _channel.description,
          // Importance.max + Priority.max + fullScreenIntent=false (don't
          // hijack the lock screen) is the official combo for a heads-up
          // banner that stays on top of whatever the user is doing.
          importance: Importance.max,
          priority:   Priority.max,
          ticker:     'ChowSA',
          // Monochrome silhouette — coloured launcher icons render as a
          // solid white square in the status bar on Android 5+.
          icon:       '@drawable/ic_stat_notification',
        ),
      ),
      payload: payload,
    );
  }

  /// Reads FirebaseMessaging.instance.getToken() and upserts it into the
  /// signed-in user's profile row. No-ops when the user isn't authenticated
  /// yet — the next call from onTokenRefresh / next app start will catch up.
  Future<void> _syncToken() async {
    try {
      final uid = Supabase.instance.client.auth.currentUser?.id;
      if (uid == null) return;
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null) return;
      await Supabase.instance.client.from('profiles').update({
        'fcm_token':       token,
        'fcm_token_at':    DateTime.now().toIso8601String(),
        'fcm_platform':    'android',
      }).eq('id', uid);
    } catch (e) {
      if (kDebugMode) debugPrint('[NotificationService] token sync failed: $e');
    }
  }
}
