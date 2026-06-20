// lib/services/event_reminder_service.dart
//
// Local "Option B" notification engine — schedules an OS-level reminder
// exactly 2 hours before a community-channel message's event_timestamp.
//
// Architecture:
//   • flutter_local_notifications drives the native OS scheduler.
//   • Each scheduled notification is keyed by a stable integer hashed from
//     the message UUID so re-tapping "Remind Me" is idempotent (re-arming
//     the same notification just overwrites the previous one).
//   • The set of currently-reminded message IDs is mirrored into
//     SharedPreferences so the toggle state ("✓ Reminded" vs "🔔 Remind Me")
//     survives app restarts.
//
// This service is intentionally permission-aware: the first call to
// scheduleReminder() routes through ensurePermissions(), which both
// requests the runtime POST_NOTIFICATIONS permission on Android 13+ AND
// the equivalent on iOS, returning a clear bool so the UI can show an
// explanatory snackbar if permission is denied.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

class EventReminderService {
  EventReminderService._();
  static final instance = EventReminderService._();

  static const _kPrefsKey      = 'event_reminders_v1';
  static const _kChannelId     = 'chowsa_event_reminders';
  static const _kChannelName   = 'Community Event Reminders';
  static const _kChannelDesc   =
      'Pre-event reminders for ChowSA community gatherings, '
      'markets, and pop-ups.';
  static const _leadDuration   = Duration(hours: 2);

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;
  Set<String> _remindedIds = <String>{};

  // ── Init ─────────────────────────────────────────────────────────────────

  /// Idempotent. Call once during app boot (or lazily on first use — both
  /// paths cover the timezone DB load + plugin init).
  Future<void> init() async {
    if (_initialized) return;
    tzdata.initializeTimeZones();
    // Default to the device's local TZ — the iOS / Android plugin uses this
    // when interpreting `tz.TZDateTime` arguments to `zonedSchedule`.
    try {
      tz.setLocalLocation(tz.getLocation(DateTime.now().timeZoneName));
    } catch (_) {
      // Fallback: most SA users are on Africa/Johannesburg.
      try {
        tz.setLocalLocation(tz.getLocation('Africa/Johannesburg'));
      } catch (_) {
        // Last-ditch: leave at UTC.
      }
    }

    const android = AndroidInitializationSettings('@drawable/ic_stat_notification');
    const ios     = DarwinInitializationSettings(
      requestAlertPermission: false,    // requested explicitly on first use
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    await _plugin.initialize(const InitializationSettings(
      android: android,
      iOS:     ios,
      macOS:   ios,
    ));

    final prefs = await SharedPreferences.getInstance();
    _remindedIds = (prefs.getStringList(_kPrefsKey) ?? const <String>[]).toSet();
    _initialized = true;
  }

  // ── Permissions ──────────────────────────────────────────────────────────

  /// Returns true when both POST_NOTIFICATIONS and SCHEDULE_EXACT_ALARM are
  /// granted (or not applicable on this OS version).
  ///
  /// Android flow:
  ///   1. POST_NOTIFICATIONS (Android 13+ / API 33) — standard runtime dialog.
  ///   2. SCHEDULE_EXACT_ALARM (Android 12+ / API 31) — CANNOT be granted via
  ///      a runtime popup. The user must toggle it in:
  ///        Settings → Apps → chow_sa → Alarms and reminders
  ///
  ///      The flutter_local_notifications plugin tries to open that page, but
  ///      on some OEMs (Samsung, Xiaomi) or older plugin versions the built-in
  ///      request silently no-ops and the toggle stays greyed out. As a
  ///      fallback we fire an explicit system intent:
  ///        `android.settings.REQUEST_SCHEDULE_EXACT_ALARM`
  ///      targeting our own package, which Android is required to route to the
  ///      correct "Alarms and reminders" toggle screen.
  ///
  /// We do NOT request phone-state, call-log, or any other unrelated
  /// permission — only the two strictly needed for scheduled notifications.
  Future<bool> ensurePermissions() async {
    await init();

    if (Platform.isIOS || Platform.isMacOS) {
      final ios = _plugin.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();
      final ok = await ios?.requestPermissions(
        alert: true, badge: true, sound: true,
      );
      return ok ?? false;
    }

    if (Platform.isAndroid) {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();

      // ── 1. POST_NOTIFICATIONS — runtime prompt (Android 13+) ──────────
      final notifOk =
          await android?.requestNotificationsPermission() ?? true;
      if (!notifOk) return false;

      // ── 2. SCHEDULE_EXACT_ALARM — system Settings toggle (Android 12+) ─
      //
      // Try the plugin's built-in request first. If it returns false (user
      // denied or the plugin couldn't open the page), fall back to an
      // explicit intent that targets our package directly. This is the same
      // intent action Android uses internally — it ALWAYS lands on the
      // "Alarms and reminders" toggle for our specific app.
      var exactAlarmGranted =
          await android?.requestExactAlarmsPermission();

      if (exactAlarmGranted == false) {
        // Plugin request didn't grant it — open the system Settings page
        // via an explicit intent so the user sees the toggle and can flip
        // it manually.
        try {
          const intent = AndroidIntent(
            action: 'android.settings.REQUEST_SCHEDULE_EXACT_ALARM',
            data:   'package:com.example.chow_sa',
            flags: <int>[0x10000000], // FLAG_ACTIVITY_NEW_TASK
          );
          await intent.launch();
          // Give the user a few seconds to flip the toggle and come back.
          // Re-check after a brief delay so we can return accurate state.
          await Future<void>.delayed(const Duration(seconds: 2));
          exactAlarmGranted =
              await android?.requestExactAlarmsPermission();
        } catch (_) {
          // Intent launch failed (very old Android, restricted OEM ROM) —
          // fall through and return false so the UI shows a helpful snackbar.
        }
      }

      // null → API < 31 (no exact-alarm permission needed) → treat as ok.
      if (exactAlarmGranted == false) return false;

      return true;
    }

    return true;
  }

  // ── State ────────────────────────────────────────────────────────────────

  bool isReminded(String messageId) => _remindedIds.contains(messageId);

  /// Stable, non-negative 31-bit integer ID derived from the message UUID
  /// so the OS notification scheduler can address it deterministically.
  int _notificationIdFor(String messageId) {
    return messageId.hashCode & 0x7FFFFFFF;
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kPrefsKey, _remindedIds.toList());
  }

  // ── Schedule / cancel ────────────────────────────────────────────────────

  /// Returns one of:
  ///   ReminderOutcome.scheduled   — happy path
  ///   ReminderOutcome.tooLate     — event_timestamp − 2h has already passed
  ///   ReminderOutcome.denied      — user refused the notification permission
  Future<ReminderOutcome> scheduleReminder({
    required String   messageId,
    required String   eventName,
    required DateTime eventTimestamp,
  }) async {
    await init();

    final ok = await ensurePermissions();
    if (!ok) return ReminderOutcome.denied;

    final fireAtUtc = eventTimestamp.toUtc().subtract(_leadDuration);
    final nowUtc    = DateTime.now().toUtc();
    if (!fireAtUtc.isAfter(nowUtc)) {
      return ReminderOutcome.tooLate;
    }

    final fireAt = tz.TZDateTime.from(fireAtUtc, tz.local);

    const androidDetails = AndroidNotificationDetails(
      _kChannelId,
      _kChannelName,
      channelDescription: _kChannelDesc,
      importance: Importance.high,
      priority:   Priority.high,
      category:   AndroidNotificationCategory.event,
    );
    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    await _plugin.zonedSchedule(
      _notificationIdFor(messageId),
      '🔥 Don\'t miss out!',
      'The event $eventName is starting soon. Tap to view details!',
      fireAt,
      const NotificationDetails(android: androidDetails, iOS: iosDetails),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      payload: messageId,
    );

    _remindedIds.add(messageId);
    await _persist();
    return ReminderOutcome.scheduled;
  }

  Future<void> cancelReminder(String messageId) async {
    await init();
    await _plugin.cancel(_notificationIdFor(messageId));
    _remindedIds.remove(messageId);
    await _persist();
  }
}

enum ReminderOutcome { scheduled, tooLate, denied }
