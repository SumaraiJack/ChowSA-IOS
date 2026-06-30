// lib/main.dart

import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'firebase_options.dart';
import 'config/supabase_config.dart';
import 'views/splash_screen.dart';
import 'views/auth_screen.dart';
import 'views/main_navigation_hub.dart';
import 'views/settings_screen.dart';
import 'models/user_profile.dart';
import 'services/ad_reward_service.dart';
import 'services/consent_service.dart';
import 'services/event_reminder_service.dart';
import 'services/local_hub_service.dart';
import 'services/notification_service.dart';
import 'services/price_estimate_service.dart';
import 'models/user_rank.dart';
import 'state/chat_bubble_theme.dart';
import 'state/session_controller.dart';
import 'state/share_intent_inbox.dart';
import 'state/vegan_mode.dart';
import 'state/weekly_budget.dart';

// =============================================================================
// Global font notifier — any widget can listen to this and rebuild instantly
// when the user picks a new font, even if it's on a pushed route.
// =============================================================================
final chowFontNotifier = ValueNotifier<String>('Default');

/// SharedPreferences key for persisting the user's ChowTheme selection.
const String kChowThemePrefKey = 'chowsa_active_theme';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ── Firebase + Crashlytics ───────────────────────────────────────────────
  // Initialise Firebase first so Crashlytics can hook FlutterError +
  // PlatformDispatcher.onError before any other code runs. Debug builds
  // disable collection so dev crashes don't pollute the prod console.
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    await FirebaseCrashlytics.instance
        .setCrashlyticsCollectionEnabled(!kDebugMode);
    FlutterError.onError = FirebaseCrashlytics.instance.recordFlutterFatalError;
    PlatformDispatcher.instance.onError = (error, stack) {
      FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
      return true;
    };
  } catch (e) {
    debugPrint('[Crashlytics] init failed: $e');
  }

  // Load persisted font + theme BEFORE runApp so the first frame is correct.
  final prefs = await SharedPreferences.getInstance();
  final savedFont  = prefs.getString('chowsa_selected_font') ?? 'Default';
  chowFontNotifier.value = savedFont;

  final savedTheme = ChowTheme.fromPersistKey(prefs.getString(kChowThemePrefKey));

  await Supabase.initialize(
    url:     SupabaseConfig.url,
    anonKey: SupabaseConfig.anonKey,
  );

  // Hydrate editable price baselines from Supabase so a row edit in
  // `price_baselines` re-prices the app with no APK release. Falls back to
  // the hardcoded keyword map on failure — see PriceEstimateService.init.
  unawaited(PriceEstimateService.instance.init());

  // Hydrate the vegan-mode toggle so the user's choice is in place by
  // the time the first scrape / pantry generation runs.
  unawaited(VeganMode.load());

  // Hydrate the global weekly food budget so the new home-hero card shows
  // the right number on first paint.
  unawaited(WeeklyBudget.load());

  // Share-to-ChowSA — registers the OS share-sheet receiver so URLs
  // shared from Instagram / TikTok / YouTube / etc. flow into the
  // scraper screen and auto-scrape. Best-effort; never blocks boot.
  unawaited(ShareIntentInbox.instance.boot());

  // ── Reactive state tier ───────────────────────────────────────────────────
  // SessionController owns auth lifecycle: on sign-in it boots Inbox,
  // Community, MealPlan and SharedAssets controllers; on sign-out it tears
  // them down. Every screen `ValueListenableBuilder`s off these notifiers
  // instead of holding its own subscription, killing the "stale until back
  // out" class of bugs across the whole app.
  unawaited(SessionController.instance.init());

  // PR 6: hydrate the chat-bubble theme preference so the very first
  // chat paint uses the user's saved palette, not the default.
  unawaited(ChatBubbleThemeController.instance.load());

  // Creator-rank title pick — hydrate before the Profile tab first paints
  // so the chosen tier title shows immediately on cold open.
  unawaited(RankTitleStore.instance.load());

  // Google Mobile Ads — must run AFTER the UMP consent gate completes.
  // UMP gathers IAB-TCF v2 consent (required by Google policy in the EEA /
  // UK / Switzerland; harmless elsewhere). MobileAds reads the result from
  // the SDK's local store automatically when serving ads.
  unawaited(() async {
    await ConsentService.instance.gather();
    if (!ConsentService.instance.canRequestAds) return;
    await MobileAds.instance.initialize();
    // Pre-warm a rewarded ad so the free-tier quota gate has one ready.
    AdRewardService.instance.warmUp();
  }());

  // Prime the local-notification scheduler (timezone DB + plugin handle) so
  // the first "Remind Me" tap doesn't pay the init cost on the UI thread.
  // Best-effort — surface errors via a debug print rather than blocking boot.
  unawaited(EventReminderService.instance.init());

  // Resolve the user's nearest community hub from device GPS. Rehydrates a
  // cached hub immediately for instant first paint, then refreshes from GPS
  // in the background. Permission denial is handled gracefully — the
  // CommunityHubScreen falls back to its existing suburb resolution.
  unawaited(LocalHubService.instance.bootstrap());

  // FCM push pipeline — Firebase init + permission prompt + token sync to
  // profiles.fcm_token + foreground/background handlers. Best-effort; on
  // failure the user just doesn't receive pushes for this session.
  unawaited(NotificationService.instance.init());

  // ── Payments intentionally OFF for v1.0 ──────────────────────────────
  // PayFast and Play Billing are both unwired for the first Play Store
  // release — every user gets full Pro features for free via
  // [EntitlementService.isPro] returning true. Restore the
  // `PlayBillingService.instance.init()` call here in v1.1 when the
  // Play Console SKU is live and we're ready to monetise.

  runApp(ChowSAApp(initialTheme: savedTheme));
}

// =============================================================================
// ChowSAApp
// =============================================================================

class ChowSAApp extends StatefulWidget {
  const ChowSAApp({super.key, this.initialTheme = ChowTheme.fresh});

  /// Theme to seed on cold start. main() reads it from SharedPreferences
  /// (key [kChowThemePrefKey]) before runApp so the very first frame
  /// renders in the user's last-picked theme — no flash of default.
  final ChowTheme initialTheme;

  @override
  State<ChowSAApp> createState() => _ChowSAAppState();
}

enum _AppStage { splash, auth, hub }

class _ChowSAAppState extends State<ChowSAApp> {
  // v4.2: the app is permanently light. Every ChowTheme bakes its own
  // (bright) palette into a single ThemeData, so themeMode is hard-locked
  // to ThemeMode.light in MaterialApp below and there's no need to track
  // it as state.
  late ChowTheme _chowTheme = widget.initialTheme;
  _AppStage _stage     = _AppStage.splash;

  void _onChowThemeChanged(ChowTheme t) {
    setState(() => _chowTheme = t);
    // Persist so the next cold start opens in the same theme.
    // Fire-and-forget — failure is non-fatal (theme just resets to Fresh).
    SharedPreferences.getInstance().then(
      (prefs) => prefs.setString(kChowThemePrefKey, t.persistKey),
    );
  }

  /// Called by SettingsScreen — updates the global notifier so every
  /// ValueListenableBuilder in the tree rebuilds immediately.
  void _onFontChanged(String font) {
    chowFontNotifier.value = font;
    // Also setState so MaterialApp theme/darkTheme are rebuilt
    setState(() {});
  }

  ThemeData _applyFont(ThemeData base, String font) {
    if (font == 'Default') return base;
    try {
      return base.copyWith(
        textTheme:        GoogleFonts.getTextTheme(font, base.textTheme),
        primaryTextTheme: GoogleFonts.getTextTheme(font, base.primaryTextTheme),
      );
    } catch (_) {
      return base;
    }
  }

  void _onSplashComplete() {
    final session = Supabase.instance.client.auth.currentSession;
    setState(() => _stage = session != null ? _AppStage.hub : _AppStage.auth);
  }

  void _onLoginSuccess(UserProfile _) => setState(() => _stage = _AppStage.hub);

  @override
  Widget build(BuildContext context) {
    // ValueListenableBuilder rebuilds this whenever chowFontNotifier changes
    return ValueListenableBuilder<String>(
      valueListenable: chowFontNotifier,
      builder: (context, font, _) {
        // v4.0: brightness is intrinsic to each ChowTheme — there is no
        // light/dark split. Route the same ThemeData to both slots so the
        // chosen theme wins regardless of the system brightness setting.
        final activeTheme = _applyFont(_chowTheme.lightTheme, font);

        return MaterialApp(
          title:                      'ChowSA',
          debugShowCheckedModeBanner: false,
          // Global key so the notification service can navigate without a
          // BuildContext when the user taps a push from the system tray.
          navigatorKey: NotificationService.navigatorKey,
          // Hard-locked to light — see _ChowSAAppState header comment.
          themeMode:                  ThemeMode.light,
          // ThemeAnimationDuration: smooth ~400ms cross-fade when the user
          // picks a new theme in Settings (per the v3.0 design spec — see
          // "Animation Guidelines: theme switch = 400ms easeInOut").
          themeAnimationDuration:     const Duration(milliseconds: 400),
          themeAnimationCurve:        Curves.easeInOut,
          theme:     activeTheme,
          darkTheme: activeTheme,
          // builder wraps the entire Navigator stack — including pushed routes
          // like SettingsScreen — so DefaultTextStyle updates immediately.
          builder: (ctx, child) {
            if (child == null) return const SizedBox();
            // ── Global font-scale cap ──────────────────────────────────
            // SA budget devices ship with system font size cranked up
            // ("Largest" = ~1.30, "Huge" on some OEM skins = ~1.45+),
            // which is enough to push the Bento tiles, channel cards,
            // and several share-sheet titles into overflow on small
            // screens. We clamp the effective text scaler to [0.85,
            // 1.20] — still respects user-preferred enlargement, but
            // never lets it run wild enough to break a layout. Applied
            // at the MaterialApp.builder so it covers every pushed
            // route automatically.
            final media   = MediaQuery.of(ctx);
            final clamped = media.copyWith(
              textScaler: media.textScaler.clamp(
                minScaleFactor: 0.85,
                maxScaleFactor: 1.20,
              ),
            );
            Widget body = MediaQuery(data: clamped, child: child);
            if (font != 'Default') {
              try {
                final f = GoogleFonts.getFont(font);
                body = DefaultTextStyle(
                  style: DefaultTextStyle.of(ctx).style.copyWith(
                    fontFamily:         f.fontFamily,
                    fontFamilyFallback: f.fontFamilyFallback,
                  ),
                  child: body,
                );
              } catch (_) {/* fall through with default font */}
            }
            return body;
          },
          home: switch (_stage) {
            _AppStage.splash => SplashScreen(onComplete: _onSplashComplete),
            _AppStage.auth   => AuthScreen(onLoginSuccess: _onLoginSuccess),
            _AppStage.hub    => MainNavigationHub(
                onChowThemeChanged: _onChowThemeChanged,
                onFontChanged:      _onFontChanged,
              ),
          },
        );
      },
    );
  }
}
