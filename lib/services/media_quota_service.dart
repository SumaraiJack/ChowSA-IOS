// lib/services/media_quota_service.dart
//
// Freemium daily quota for community-hub rich media.
//
// Spec:
//   • Free tier: chat / text posts are UNLIMITED across every community
//     category.
//   • Free tier: 1 complimentary high-res photo upload AND 1 location pin
//     per day. Once the free allocation is spent, the next photo / pin is
//     gated behind a rewarded video ad; one ad → +1 photo (or +1 pin) per
//     watch, capped at 3 of each per calendar day.
//   • Pro tier: unlimited photos and pins, no ads.
//   • Daily reset fires at 00:00 local system time — the date stamp uses
//     `DateTime.now()` so the reset always tracks the user's wall clock.
//
// Storage: SharedPreferences (offline-first, survives sign-out so a Pro
// user who downgrades doesn't get a stale "infinite" cached state).

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ad_reward_service.dart';
import 'entitlement_service.dart';

/// Which kind of rich-media slot the caller is asking about.
enum MediaKind { photo, pin }

extension MediaKindX on MediaKind {
  String get label => switch (this) {
        MediaKind.photo => 'photo',
        MediaKind.pin   => 'location pin',
      };
}

/// Snapshot of the user's quota state for a given [MediaKind]. UI surfaces
/// use this to render counters / locks without re-querying the service.
class MediaQuotaStatus {
  const MediaQuotaStatus({
    required this.kind,
    required this.usedToday,
    required this.unlocked,
    required this.isPro,
  });

  /// Total uses recorded today.
  final int usedToday;

  /// Highest slot the user has earned today (1 = base free, 2 = after one
  /// rewarded ad, 3 = after two rewarded ads).
  final int unlocked;

  final MediaKind kind;
  final bool      isPro;

  /// Can the user fire this kind off RIGHT NOW with no further interaction?
  bool get canUseImmediately => isPro || usedToday < unlocked;

  /// Has the user hit the hard daily ceiling (3) so even another ad won't
  /// unlock another slot?
  bool get isCappedForToday =>
      !isPro && usedToday >= MediaQuotaService.kMaxPerDay;
}

class MediaQuotaService {
  MediaQuotaService._();
  static final instance = MediaQuotaService._();

  /// 1 free + 2 ad-unlocked = 3 per day per kind.
  static const int kFreeBaseSlots = 1;
  static const int kMaxPerDay     = 3;

  static const _kPhotoCountKey   = 'media_quota_photo_count_v1';
  static const _kPhotoUnlockKey  = 'media_quota_photo_unlocked_v1';
  static const _kPinCountKey     = 'media_quota_pin_count_v1';
  static const _kPinUnlockKey    = 'media_quota_pin_unlocked_v1';
  static const _kDateKey         = 'media_quota_date_v1';

  String _todayStamp() {
    final dt = DateTime.now();
    return '${dt.year}-'
           '${dt.month.toString().padLeft(2, '0')}-'
           '${dt.day.toString().padLeft(2, '0')}';
  }

  Future<void> _rolloverIfStale(SharedPreferences prefs) async {
    final stored = prefs.getString(_kDateKey);
    final today  = _todayStamp();
    if (stored != today) {
      // New local calendar day → wipe yesterday's counters AND the unlock
      // ladder so the user starts fresh tomorrow at slot 1.
      await prefs.setString(_kDateKey, today);
      await prefs.setInt(_kPhotoCountKey,  0);
      await prefs.setInt(_kPinCountKey,    0);
      await prefs.setInt(_kPhotoUnlockKey, kFreeBaseSlots);
      await prefs.setInt(_kPinUnlockKey,   kFreeBaseSlots);
    }
  }

  String _countKey(MediaKind k)  =>
      k == MediaKind.photo ? _kPhotoCountKey  : _kPinCountKey;
  String _unlockKey(MediaKind k) =>
      k == MediaKind.photo ? _kPhotoUnlockKey : _kPinUnlockKey;

  Future<MediaQuotaStatus> statusFor(MediaKind kind) async {
    final isPro = EntitlementService.instance.isPro;
    final prefs = await SharedPreferences.getInstance();
    await _rolloverIfStale(prefs);
    return MediaQuotaStatus(
      kind:      kind,
      usedToday: prefs.getInt(_countKey(kind))  ?? 0,
      unlocked:  prefs.getInt(_unlockKey(kind)) ?? kFreeBaseSlots,
      isPro:     isPro,
    );
  }

  /// Gates a single use of [kind].
  ///
  /// Resolution order:
  ///   1. Pro / VIP → granted instantly, no recording.
  ///   2. Under today's unlocked ceiling → recorded silently.
  ///   3. Already at the unlocked ceiling but below the hard cap of 3 →
  ///      prompts the rewarded-ad dialog; one watch raises the ceiling by
  ///      1 AND records the use.
  ///   4. At the hard cap → snackbar telling the user to come back
  ///      tomorrow. Returns false.
  Future<bool> requestUse(BuildContext context, MediaKind kind) async {
    if (EntitlementService.instance.isPro) return true;

    final prefs = await SharedPreferences.getInstance();
    await _rolloverIfStale(prefs);

    final used     = prefs.getInt(_countKey(kind))  ?? 0;
    final unlocked = prefs.getInt(_unlockKey(kind)) ?? kFreeBaseSlots;

    if (used < unlocked) {
      // Within the user's current unlock ceiling — record and proceed.
      await prefs.setInt(_countKey(kind), used + 1);
      return true;
    }

    // Hit the daily hard cap — neither ads nor another upgrade prompt
    // will help; just inform the user.
    if (unlocked >= kMaxPerDay) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
            "You're at today's free ${kind.label} limit ($kMaxPerDay/day). "
            'Try again tomorrow, or upgrade to ChowSA Pro for unlimited '
            'media.',
          ),
          behavior: SnackBarBehavior.floating,
        ));
      }
      return false;
    }

    // Within the cap but past the unlocked ceiling → offer the rewarded
    // ad. AdRewardService already owns the watch-an-ad dialog; we reuse
    // it so the UX matches the AI-generation flow.
    final granted = await AdRewardService().requestGeneration(context);
    if (!granted) return false;

    // Ad granted → ratchet the unlock ceiling and consume one slot.
    await prefs.setInt(_unlockKey(kind), unlocked + 1);
    await prefs.setInt(_countKey(kind),  used + 1);
    return true;
  }
}
