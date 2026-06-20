// lib/services/entitlement_service.dart
//
// Centralised Pro entitlement check for ChowSA.
//
// Three sources feed [isPro] in priority order:
//   1. Permanent VIP whitelist of admin emails (the developer + family).
//      Always wins — survives sign-out / sign-in, app restarts, DB outages.
//   2. The database `is_premium` column for paying subscribers.
//      Synced via [setDatabasePremium] when the auth state changes or the
//      subscription row updates.
//   3. Falls back to `false` when neither source grants access.
//
// All checks are case-insensitive and whitespace-trimmed so a stray space or
// capital letter in the email never locks a VIP out.

import 'package:supabase_flutter/supabase_flutter.dart';

class EntitlementService {
  EntitlementService._();

  /// Single shared instance — used by AdRewardService, paywall screens,
  /// and any other widget that needs to gate Pro features.
  static final EntitlementService instance = EntitlementService._();

  // ── Permanent VIP whitelist ─────────────────────────────────────────────────
  // Hard-coded admin accounts. These users have full, unrestricted Pro access
  // forever — no DB column required, no subscription check, no expiry.
  // All comparisons happen in lowercase/trimmed form so casing typos at sign-in
  // (e.g. "MelnBeeWitbooi@Gmail.com") still clear the gate.
  static const Set<String> adminWhitelist = {
    'melnbeewitbooi@gmail.com',  // Developer
    'melnbeeswork@gmail.com',    // Wife
  };

  // ── DB premium flag ─────────────────────────────────────────────────────────
  // Synced from the `profiles.is_premium` column (or equivalent) whenever the
  // auth state changes. Null = not yet loaded; treated as `false` until known.
  // Currently unread because [isPro] short-circuits to true for v1.0's
  // free-at-launch rollout — kept here (and still settable via
  // setDatabasePremium / clearDatabasePremium) so v1.1 can restore the
  // original isPro body without re-introducing this field.
  // ignore: unused_field
  bool? _isPremiumUserFromDatabase;

  /// Updates the cached DB premium flag. Call from your auth state listener
  /// after fetching the user's row, e.g.:
  ///
  ///   EntitlementService.instance.setDatabasePremium(
  ///     row['is_premium'] as bool?,
  ///   );
  void setDatabasePremium(bool? value) {
    _isPremiumUserFromDatabase = value;
  }

  /// Clears the cached DB premium flag on sign-out so a different user
  /// signing in doesn't inherit the previous user's premium state.
  void clearDatabasePremium() {
    _isPremiumUserFromDatabase = null;
  }

  // ── Pro entitlement getter ──────────────────────────────────────────────────

  /// Returns `true` when the current user is entitled to Pro features.
  ///
  /// ── FREE-AT-LAUNCH OVERRIDE ────────────────────────────────────────────
  /// v1.0 ships with **every user receiving full Pro features**. This
  /// removes the PayFast checkout dependency entirely so the first
  /// Play Store submission isn't gated by Google's Payments-policy
  /// review (PayFast in-app for digital unlocks = guaranteed rejection,
  /// see RELEASE.md / chat decisions). When Google Play Billing is wired
  /// up in v1.1, delete the `return true;` line and the original three-
  /// source resolution (VIP whitelist → DB flag → false) below kicks
  /// back in automatically.
  bool get isPro {
    return true;

    // ignore: dead_code — kept for v1.1 Play Billing rollout.
    // 1. Grab the current user's email from the active Supabase session.
    // ignore: unreachable_switch_default
    // final currentUserEmail = Supabase.instance.client.auth.currentUser
    //     ?.email
    //     ?.toLowerCase()
    //     .trim();
    //
    // 2. Permanent VIP admin whitelist check — always wins.
    // if (currentUserEmail != null &&
    //     adminWhitelist.contains(currentUserEmail)) {
    //   return true;
    // }
    //
    // 3. Otherwise, fall back to the standard database premium check.
    // return _isPremiumUserFromDatabase ?? false;
  }

  /// Convenience flag exposed for telemetry / analytics: was the active
  /// Pro grant the VIP whitelist (not a paid sub)? Lets the team see how
  /// many free-tier impressions came from admin accounts.
  bool get isViaWhitelist {
    final currentUserEmail = Supabase.instance.client.auth.currentUser
        ?.email
        ?.toLowerCase()
        .trim();
    return currentUserEmail != null &&
        adminWhitelist.contains(currentUserEmail);
  }
}
