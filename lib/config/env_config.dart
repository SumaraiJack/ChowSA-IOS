// lib/config/env_config.dart

import 'dart:io' show Platform;

//
// Centralised environment switch for credentials that differ between
// development and production builds (AdMob unit IDs today; add more as
// needed). The whole point of this file is that NO other source file in
// the app should hardcode a test-vs-prod string — they all read EnvConfig.
//
// ─────────────────────────────────────────────────────────────────────────────
//  How the switch works
// ─────────────────────────────────────────────────────────────────────────────
// `isProduction` reads a compile-time --dart-define flag. Flutter's
// `bool.fromEnvironment` only resolves at build time, so production builds
// MUST be invoked with the flag explicitly — there is no runtime way to
// flip this, which is exactly the safety property we want.
//
//   # Local dev / CI / debug — defaults to test IDs, no flag needed:
//   flutter run
//   flutter build apk --debug
//
//   # Production Play Store bundle — flip the flag ON:
//   flutter build appbundle --release --dart-define=IS_PRODUCTION=true
//
// If you forget the flag on a production build the worst case is shipping
// AdMob TEST ads (no revenue) — that's a deliberate fail-safe. The reverse
// scenario — accidentally shipping real prod IDs from a dev machine — is
// what gets your AdMob account suspended for invalid traffic, so we
// default to test IDs and require an explicit opt-in to swap.
//
// ─────────────────────────────────────────────────────────────────────────────
//  AndroidManifest.xml — the AdMob App ID lives in native land too
// ─────────────────────────────────────────────────────────────────────────────
// The AdMob *App ID* must appear as a `<meta-data>` tag inside the
// AndroidManifest's `<application>` block — Dart code cannot inject it
// because the Google Mobile Ads SDK reads it during process init, before
// any Flutter engine code runs. We bridge the Dart/Gradle gap with a
// manifestPlaceholder declared in android/app/build.gradle.kts (see the
// "build.gradle.kts" snippet below in this file's doc-comment) and the
// manifest references `${admobAppId}` instead of a hardcoded string.

abstract final class EnvConfig {
  EnvConfig._();

  // ── Build-time switch ─────────────────────────────────────────────────
  /// Read at compile time from --dart-define=IS_PRODUCTION=true.
  /// Defaults to false so accidental builds ship test ads, not real ones.
  static const bool isProduction =
      bool.fromEnvironment('IS_PRODUCTION', defaultValue: false);

  // ── AdMob — App IDs ───────────────────────────────────────────────────
  // Android + iOS have separate AdMob apps under pub-4825357853521156.
  static const String _kProdAdMobAppIdAndroid = 'ca-app-pub-4825357853521156~9984542080';
  static const String _kProdAdMobAppIdIos     = 'ca-app-pub-4825357853521156~4176851058';
  static const String _kTestAdMobAppIdAndroid = 'ca-app-pub-3940256099942544~3347511713';
  static const String _kTestAdMobAppIdIos     = 'ca-app-pub-3940256099942544~1458002511';

  /// AdMob Application ID. Used by AndroidManifest via a manifestPlaceholder
  /// AND surfaced in Dart so we can sanity-check it from main() if needed.
  static String get adMobAppId {
    if (Platform.isIOS) {
      return isProduction ? _kProdAdMobAppIdIos : _kTestAdMobAppIdIos;
    }
    return isProduction ? _kProdAdMobAppIdAndroid : _kTestAdMobAppIdAndroid;
  }

  // ── AdMob — Rewarded Ad Unit IDs ──────────────────────────────────────
  static const String _kProdRewardedAdUnitIdAndroid =
      'ca-app-pub-4825357853521156/2264461012';
  static const String _kProdRewardedAdUnitIdIos =
      'ca-app-pub-4825357853521156/1808075102';
  static const String _kTestRewardedAdUnitIdAndroid =
      'ca-app-pub-3940256099942544/5224354917';
  static const String _kTestRewardedAdUnitIdIos =
      'ca-app-pub-3940256099942544/1712485313';

  /// Rewarded ad unit ID used by AdRewardService._loadRewardedAd().
  static String get adMobRewardedAdUnitId {
    if (Platform.isIOS) {
      return isProduction ? _kProdRewardedAdUnitIdIos : _kTestRewardedAdUnitIdIos;
    }
    return isProduction ? _kProdRewardedAdUnitIdAndroid : _kTestRewardedAdUnitIdAndroid;
  }

  // ── Sanity helper ─────────────────────────────────────────────────────
  /// Plain-English label for debug logs / Settings -> About screens.
  /// "PROD" only ever appears when the dart-define flag is set.
  static String get buildEnvLabel => isProduction ? 'PROD' : 'DEV';
}
