// lib/services/consent_service.dart
//
// Google User Messaging Platform (UMP) consent gate for AdMob.
//
// Why: Google Mobile Ads policies REQUIRE every app showing ads in the
// EEA / UK / Switzerland (and now globally as a best practice) to gather
// IAB-TCF v2 consent BEFORE initialising the ads SDK. Apps without a UMP
// dialog fail Play review or get removed.
//
// What it does:
//   1. Calls ConsentInformation.requestConsentInfoUpdate to find out
//      whether consent is required and whether a form is available.
//   2. If a form is available + status is "required", shows the Google
//      consent dialog so the user can pick personalised / non-personalised /
//      reject.
//   3. Stores the result via Google's TCF SDK. AdMob automatically reads it
//      from there when serving ads.
//   4. Returns a flag for whether ads can be requested at all (false only
//      if the user is in a jurisdiction that requires consent AND we still
//      haven't obtained any).
//
// Usage: call ConsentService.instance.gather() in main() BEFORE
// MobileAds.instance.initialize() and AdRewardService.warmUp(). If
// canRequestAds is false, don't initialise ads.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

class ConsentService {
  ConsentService._();
  static final ConsentService instance = ConsentService._();

  /// True once we've checked with UMP and (where required) gathered a
  /// consent decision from the user. Drives whether MobileAds.initialize()
  /// should be called.
  bool _canRequestAds = false;
  bool get canRequestAds => _canRequestAds;

  /// Runs the full UMP flow exactly once per process. Safe to call
  /// multiple times — subsequent calls are no-ops.
  ///
  /// Behaviour:
  ///   • In jurisdictions where consent is NOT required (e.g. SA), this
  ///     resolves quickly with canRequestAds == true and no dialog shown.
  ///   • In EEA/UK/Switzerland (or anywhere TCF applies), this shows the
  ///     Google-provided form, blocks until the user submits, then resolves.
  Future<void> gather() async {
    final params = ConsentRequestParameters();
    final completer = Completer<void>();

    ConsentInformation.instance.requestConsentInfoUpdate(
      params,
      () async {
        // Form available? Show it. The SDK no-ops the show() call when
        // the form has already been answered or isn't required.
        try {
          final available =
              await ConsentInformation.instance.isConsentFormAvailable();
          if (available) {
            await _loadAndShowFormIfRequired();
          }
        } catch (e) {
          if (kDebugMode) debugPrint('[Consent] form error: $e');
        }
        await _refreshCanRequest();
        if (!completer.isCompleted) completer.complete();
      },
      (FormError err) {
        if (kDebugMode) {
          debugPrint('[Consent] requestConsentInfoUpdate error: '
              '${err.errorCode} ${err.message}');
        }
        // On failure, fall back to "not required" so the user still gets a
        // working app (non-personalised ads). UMP errors should never break
        // the whole boot path.
        _canRequestAds = true;
        if (!completer.isCompleted) completer.complete();
      },
    );

    return completer.future;
  }

  Future<void> _loadAndShowFormIfRequired() async {
    final status = await ConsentInformation.instance.getConsentStatus();
    if (status != ConsentStatus.required) return;
    final form = await _loadForm();
    if (form == null) return;
    // form.show returns void in this SDK — the callback is the completion
    // signal. We wrap it in a completer so the rest of init() can await
    // the dialog before MobileAds.initialize() runs.
    final done = Completer<void>();
    form.show((FormError? error) {
      if (kDebugMode && error != null) {
        debugPrint('[Consent] form show error: '
            '${error.errorCode} ${error.message}');
      }
      if (!done.isCompleted) done.complete();
    });
    await done.future;
  }

  Future<ConsentForm?> _loadForm() {
    final completer = Completer<ConsentForm?>();
    ConsentForm.loadConsentForm(
      (form) => completer.complete(form),
      (FormError err) {
        if (kDebugMode) {
          debugPrint('[Consent] loadConsentForm error: '
              '${err.errorCode} ${err.message}');
        }
        completer.complete(null);
      },
    );
    return completer.future;
  }

  Future<void> _refreshCanRequest() async {
    try {
      _canRequestAds =
          await ConsentInformation.instance.canRequestAds();
    } catch (_) {
      _canRequestAds = true;
    }
  }

  /// Allows users to re-open the consent form from Settings. The SDK
  /// surfaces this option only in jurisdictions where the user has the
  /// right to change their mind (so the Settings tile should hide itself
  /// when this returns false).
  Future<bool> privacyOptionsRequired() async {
    final status =
        await ConsentInformation.instance.getPrivacyOptionsRequirementStatus();
    return status == PrivacyOptionsRequirementStatus.required;
  }

  Future<void> showPrivacyOptionsForm() async {
    final form = await _loadForm();
    if (form == null) return;
    final done = Completer<void>();
    form.show((FormError? error) {
      if (kDebugMode && error != null) {
        debugPrint('[Consent] privacy form error: '
            '${error.errorCode} ${error.message}');
      }
      if (!done.isCompleted) done.complete();
    });
    await done.future;
    await _refreshCanRequest();
  }

  /// Test-only: clears the cached consent so the dialog re-appears on next
  /// launch. Don't call this from production code.
  Future<void> resetForDebug() async {
    await ConsentInformation.instance.reset();
  }
}
