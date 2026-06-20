// lib/services/ad_reward_service.dart
//
// Rewarded-ad engine for ChowSA free-tier users — wired to Google AdMob via
// the google_mobile_ads SDK. Replaces the previous simulated playback.
//
// Free tier: 3 AI generations / day.
// Watching a rewarded ad grants 1 bonus generation (single-use, not banked).
//
// Lifecycle:
//   1. main.dart calls MobileAds.instance.initialize() then
//      AdRewardService.instance.warmUp() to pre-cache the first ad.
//   2. Each call to requestGeneration() that hits the quota wall shows the
//      prompt dialog. If the user taps "Watch a Short Ad", we show the
//      cached RewardedAd and reward on `onUserEarnedReward`.
//   3. After a successful show OR a load/show failure we kick off the next
//      pre-load so the gate is never cold on the second hit.
//
// Test Unit IDs:
//   App ID  (AndroidManifest): ca-app-pub-3940256099942544~3347511713
//   Rewarded:                  ca-app-pub-3940256099942544/5224354917
//   Swap both for the production AdMob units before launch.

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config/env_config.dart';
import 'entitlement_service.dart';

// =============================================================================
// Constants
// =============================================================================

const _kDailyFreeLimit    = 3;       // generations before paywall / ad prompt
const _kCountKey          = 'ad_gen_count_v1';
const _kDateKey           = 'ad_gen_date_v1';

// ── Per-kind scan quota (Recipe Scraper / AI Camera Scanner) ──────────────
//
// Spec: 2 free scans per day per kind, then a rewarded ad unlocks +1, then
// a SECOND rewarded ad unlocks +1 more. Hard cap: 4 scans / kind / day.
// Each kind has its own buckets — running the recipe scraper doesn't eat
// the camera scanner's quota and vice versa.
const int _kScanFreeBase   = 2;
const int _kScanMaxPerDay  = 4;
const String _kScanDateKey = 'scan_quota_date_v1';

/// Which kind of AI scan is being gated. Two independent buckets keyed
/// off this enum — Recipe Scraper (link/raw-text → AI recipe) vs.
/// Camera Scanner (fridge photo / gallery upload → ingredient list).
enum ScanKind { recipeScraper, cameraScanner }

extension ScanKindX on ScanKind {
  String get _countKey => switch (this) {
        ScanKind.recipeScraper => 'scan_count_recipe_v1',
        ScanKind.cameraScanner => 'scan_count_camera_v1',
      };
  String get _unlockKey => switch (this) {
        ScanKind.recipeScraper => 'scan_unlock_recipe_v1',
        ScanKind.cameraScanner => 'scan_unlock_camera_v1',
      };
  String get displayName => switch (this) {
        ScanKind.recipeScraper => 'recipe scrape',
        ScanKind.cameraScanner => 'camera scan',
      };
}

// ── Dev bypass ────────────────────────────────────────────────────────────────
// true  → every generation request succeeds instantly (no quota, no ads).
// false → real daily-quota gate applies.  Flip to false before production.
const bool kBypassProGate = true;

// ── AdMob Unit ID source ─────────────────────────────────────────────────────
// EnvConfig.adMobRewardedAdUnitId is the single source of truth — it returns
// the test unit when --dart-define=IS_PRODUCTION=true is NOT set, and the
// real ChowSA production unit when it is. Never hardcode a unit ID here.

// Retry backoff for failed loads — capped so we don't spam Google's edge
// during sustained network failures (offline plane mode, captive portals).
const Duration _kInitialRetryDelay = Duration(seconds: 3);
const Duration _kMaxRetryDelay     = Duration(minutes: 2);

// Design tokens used only in this file
const _kForest = Color(0xFF0C351E);
const _kOrange = Color(0xFFE59B27);
const _kCream  = Color(0xFFF4F1EA);

// =============================================================================
// AdRewardService — singleton so the pre-cached RewardedAd survives across
// every screen that hits requestGeneration(). Previously the class was a
// plain `new AdRewardService()` per-screen, which would have meant a fresh
// (uncached) RewardedAd field on every instance.
// =============================================================================

class AdRewardService {
  AdRewardService._internal();
  static final AdRewardService instance = AdRewardService._internal();

  /// Back-compat: existing call sites do `AdRewardService()` — keep that
  /// working by routing every constructor call to the singleton instance.
  factory AdRewardService() => instance;

  // ── Rewarded-ad state ────────────────────────────────────────────────────────

  RewardedAd? _rewardedAd;
  bool        _isLoading        = false;
  int         _consecutiveFails = 0;

  /// Public hook so main.dart can warm the cache at startup.
  void warmUp() => _loadRewardedAd();

  /// Fire-and-forget rewarded-ad pre-loader. Reentrancy-safe.
  void _loadRewardedAd() {
    if (_rewardedAd != null || _isLoading) return;
    _isLoading = true;

    RewardedAd.load(
      adUnitId: EnvConfig.adMobRewardedAdUnitId,
      request:  const AdRequest(),
      rewardedAdLoadCallback: RewardedAdLoadCallback(
        onAdLoaded: (ad) {
          _rewardedAd       = ad;
          _isLoading        = false;
          _consecutiveFails = 0;
          if (kDebugMode) debugPrint('[AdRewardService] RewardedAd cached.');
        },
        onAdFailedToLoad: (error) {
          _rewardedAd  = null;
          _isLoading   = false;
          _consecutiveFails++;

          // Exponential backoff, capped. 3s → 6s → 12s → … → 2 min.
          final delayMs = _kInitialRetryDelay.inMilliseconds *
              (1 << (_consecutiveFails - 1).clamp(0, 6));
          final delay   = Duration(milliseconds: delayMs)
              .compareTo(_kMaxRetryDelay) > 0
                ? _kMaxRetryDelay
                : Duration(milliseconds: delayMs);

          if (kDebugMode) {
            debugPrint(
              '[AdRewardService] RewardedAd load failed '
              '(code=${error.code} msg=${error.message}); '
              'retrying in ${delay.inSeconds}s '
              '(fail #$_consecutiveFails).',
            );
          }
          Future.delayed(delay, _loadRewardedAd);
        },
      ),
    );
  }

  /// Present the cached RewardedAd. Resolves to `true` if the user
  /// completed the ad and earned the reward; `false` on dismiss / failure.
  ///
  /// If no ad is cached we attempt a rapid synchronous reload — but rather
  /// than block the UI on it, we return `false` and let the prompt dialog
  /// show its existing "Maybe later" exit path. Next attempt will succeed
  /// because the load we just kicked off will have completed by then.
  Future<bool> _showRewardedAd() {
    final ad = _rewardedAd;
    if (ad == null) {
      // Cold cache — start a load so the NEXT show works.
      _loadRewardedAd();
      return Future.value(false);
    }

    // Clear our reference first so we never accidentally show the same
    // ad twice (SDK explicitly disallows it).
    _rewardedAd = null;

    final completer = Completer<bool>();
    bool rewarded = false;

    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdShowedFullScreenContent: (_) {
        if (kDebugMode) debugPrint('[AdRewardService] RewardedAd showing.');
      },
      onAdDismissedFullScreenContent: (ad) {
        ad.dispose();
        _loadRewardedAd(); // pre-cache next
        if (!completer.isCompleted) completer.complete(rewarded);
      },
      onAdFailedToShowFullScreenContent: (ad, error) {
        ad.dispose();
        _loadRewardedAd();
        if (kDebugMode) {
          debugPrint('[AdRewardService] Show failed: ${error.message}');
        }
        if (!completer.isCompleted) completer.complete(false);
      },
    );

    ad.show(
      onUserEarnedReward: (_, reward) {
        rewarded = true;
        if (kDebugMode) {
          debugPrint(
            '[AdRewardService] Reward earned: '
            '${reward.amount} ${reward.type}',
          );
        }
      },
    );

    return completer.future;
  }

  // ── Quota helpers ────────────────────────────────────────────────────────────

  Future<int> _getTodayCount() async {
    final prefs   = await SharedPreferences.getInstance();
    final dateStr = prefs.getString(_kDateKey);
    final today   = _dateStamp(DateTime.now());

    if (dateStr != today) {
      // New day — reset counter
      await prefs.setString(_kDateKey, today);
      await prefs.setInt(_kCountKey, 0);
      return 0;
    }
    return prefs.getInt(_kCountKey) ?? 0;
  }

  Future<void> _incrementCount() async {
    final prefs = await SharedPreferences.getInstance();
    final today = _dateStamp(DateTime.now());
    await prefs.setString(_kDateKey, today);
    await prefs.setInt(_kCountKey, (prefs.getInt(_kCountKey) ?? 0) + 1);
  }

  /// Returns true if the user still has free generations left today.
  Future<bool> canGenerateFree() async {
    final count = await _getTodayCount();
    return count < _kDailyFreeLimit;
  }

  /// Call this after a successful generation to record it.
  Future<void> recordGeneration() => _incrementCount();

  /// Returns [0, _kDailyFreeLimit] — how many free gens the user has used today.
  Future<int> usedTodayCount() => _getTodayCount();

  // ── Gate — call this before every AI generation ──────────────────────────────

  /// Shows the ad prompt if the free quota is exhausted.
  ///
  /// Returns `true`  → generation should proceed (Pro user, free slot
  ///                    available, or the user watched the ad and earned a
  ///                    bonus generation).
  /// Returns `false` → quota exhausted and user dismissed the ad prompt.
  Future<bool> requestGeneration(BuildContext context) async {
    // ── Pro / VIP / dev bypass — all three short-circuit identically ────────
    // Order: VIP whitelist > paid subscription > dev kBypassProGate flag.
    if (EntitlementService.instance.isPro) return true;
    if (kBypassProGate) return true;                   // dev bypass — unlimited
    if (await canGenerateFree()) return true;          // slot available

    // Quota full — show ad prompt
    if (!context.mounted) return false;
    final result = await _showAdPromptDialog(context); // null = dismissed
    return result == _AdResult.rewarded;
  }

  // ── Ad simulation ─────────────────────────────────────────────────────────────

  Future<_AdResult?> _showAdPromptDialog(BuildContext context) {
    return showDialog<_AdResult>(
      context:            context,
      barrierDismissible: true,
      // Hand the dialog a closure that drives the real RewardedAd. Keeps
      // the UI widget pure (no SDK imports leak into the build method) and
      // makes the dialog trivially testable with a mock callback.
      builder: (_) => _AdPromptDialog(onWatchAd: _showRewardedAd),
    );
  }

  // ── Utility ───────────────────────────────────────────────────────────────────

  String _dateStamp(DateTime dt) =>
      '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';

  // ── Per-kind scan quota ────────────────────────────────────────────────
  //
  // Same shape as MediaQuotaService: 2 free per kind per day, each
  // rewarded-ad watch ratchets the unlock ceiling by +1 up to a hard cap
  // of 4. Pro / dev-bypass skip the gate entirely.

  Future<void> _scanRolloverIfStale(SharedPreferences prefs) async {
    final stored = prefs.getString(_kScanDateKey);
    final today  = _dateStamp(DateTime.now());
    if (stored != today) {
      await prefs.setString(_kScanDateKey, today);
      for (final k in ScanKind.values) {
        await prefs.setInt(k._countKey,  0);
        await prefs.setInt(k._unlockKey, _kScanFreeBase);
      }
    }
  }

  /// Read-only snapshot: how many scans of [kind] used today, and the
  /// current unlock ceiling (2 → no ads watched, 3 → one watched, 4 →
  /// both watched).
  Future<({int used, int unlocked})> scanStatus(ScanKind kind) async {
    final prefs = await SharedPreferences.getInstance();
    await _scanRolloverIfStale(prefs);
    return (
      used:     prefs.getInt(kind._countKey)  ?? 0,
      unlocked: prefs.getInt(kind._unlockKey) ?? _kScanFreeBase,
    );
  }

  /// Gate one scan of [kind]. Returns true when the caller may proceed:
  /// Pro / dev bypass, slot under the current unlocked ceiling, or the
  /// user watched an ad. Returns false when the daily hard cap (4) is
  /// reached, or the user dismissed the ad prompt.
  Future<bool> requestScan(BuildContext context, ScanKind kind) async {
    if (EntitlementService.instance.isPro) return true;
    if (kBypassProGate) return true;

    final prefs = await SharedPreferences.getInstance();
    await _scanRolloverIfStale(prefs);

    final used     = prefs.getInt(kind._countKey)  ?? 0;
    final unlocked = prefs.getInt(kind._unlockKey) ?? _kScanFreeBase;

    if (used < unlocked) {
      await prefs.setInt(kind._countKey, used + 1);
      return true;
    }

    if (unlocked >= _kScanMaxPerDay) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
            "You've used all $_kScanMaxPerDay ${kind.displayName}s for today. "
            'Come back tomorrow, or upgrade to ChowSA Pro for unlimited scans.',
          ),
          behavior: SnackBarBehavior.floating,
        ));
      }
      return false;
    }

    // Past the free ceiling, under the hard cap → prompt the ad.
    if (!context.mounted) return false;
    final result = await _showAdPromptDialog(context);
    if (result != _AdResult.rewarded) return false;

    await prefs.setInt(kind._unlockKey, unlocked + 1);
    await prefs.setInt(kind._countKey,  used + 1);
    return true;
  }
}

// =============================================================================
// Internal enums
// =============================================================================

enum _AdResult { rewarded, dismissed }

// =============================================================================
// _AdPromptDialog — full ad-gate UI
// =============================================================================

class _AdPromptDialog extends StatefulWidget {
  const _AdPromptDialog({required this.onWatchAd});

  /// Invoked when the user taps "Watch a Short Ad". Returns true if the
  /// rewarded ad completed successfully and the user earned the reward.
  final Future<bool> Function() onWatchAd;

  @override
  State<_AdPromptDialog> createState() => _AdPromptDialogState();
}

class _AdPromptDialogState extends State<_AdPromptDialog> {

  // idle     → user sees the prompt (CTA + Pro upsell)
  // loading  → real AdMob ad is presenting full-screen above this dialog
  // done     → reward granted, success state visible

  _Phase _phase = _Phase.idle;

  Future<void> _startAd() async {
    setState(() => _phase = _Phase.playing);

    // Hand control to the singleton — it shows the real RewardedAd, awaits
    // dismiss, and resolves true if onUserEarnedReward fired.
    final earned = await widget.onWatchAd();

    if (!mounted) return;
    if (earned) {
      setState(() => _phase = _Phase.done);
    } else {
      // Show failed, no fill, or user dismissed early — drop back to the
      // idle prompt so they can retry or upgrade.
      setState(() => _phase = _Phase.idle);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No ad available right now — please try again in a moment.',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;

    return Dialog(
      backgroundColor:  _kCream,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: switch (_phase) {
            _Phase.idle   => _buildIdle(tt),
            _Phase.playing => _buildPlaying(tt),
            _Phase.done   => _buildDone(tt),
          },
        ),
      ),
    );
  }

  // ── Idle — ask user to watch ──────────────────────────────────────────────────

  Widget _buildIdle(TextTheme tt) {
    return Column(
      key: const ValueKey('idle'),
      mainAxisSize: MainAxisSize.min,
      children: [
        // Flame badge
        Container(
          width:  64,
          height: 64,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFFE8611A), Color(0xFFFF8F00)],
              begin:  Alignment.topLeft,
              end:    Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Icon(Icons.local_fire_department_rounded,
              color: Colors.white, size: 34),
        ),
        const SizedBox(height: 18),

        Text(
          "You've used today's free recipes",
          style: tt.titleMedium?.copyWith(
            fontWeight: FontWeight.w800,
            color:      _kForest,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 10),
        Text(
          'Free chefs get ${_kDailyFreeLimit} AI recipes per day. '
          'Watch a 15-second ad for 1 bonus generation — or upgrade to ChowSA Pro '
          'for unlimited cooking, no ads, ever.',
          style: tt.bodySmall?.copyWith(
            color:  const Color(0xFF55534E),
            height: 1.6,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),

        // Benefit chips
        Wrap(
          spacing:    8,
          runSpacing: 8,
          alignment:  WrapAlignment.center,
          children: const [
            _BenefitChip(label: '🔓 1 bonus recipe today'),
            _BenefitChip(label: '⏱ Only 15 seconds'),
            _BenefitChip(label: '🆓 Free'),
          ],
        ),
        const SizedBox(height: 24),

        // Watch ad CTA
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _startAd,
            icon:  const Icon(Icons.play_circle_outline_rounded, size: 20),
            label: const Text(
              'Watch a Short Ad',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
            ),
            style: FilledButton.styleFrom(
              backgroundColor: _kOrange,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape:   RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            ),
          ),
        ),
        const SizedBox(height: 10),

        // Pro upgrade link
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: () => Navigator.pop(context, _AdResult.dismissed),
            style: OutlinedButton.styleFrom(
              side:    const BorderSide(color: _kForest),
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape:   RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            ),
            child: RichText(
              text: const TextSpan(
                style: TextStyle(
                  fontSize:   13,
                  fontWeight: FontWeight.w600,
                  color:      _kForest,
                ),
                children: [
                  TextSpan(text: 'Upgrade to '),
                  TextSpan(
                    text:  'ChowSA Pro',
                    style: TextStyle(fontWeight: FontWeight.w900),
                  ),
                  TextSpan(text: ' — R49/month'),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),

        TextButton(
          onPressed: () => Navigator.pop(context, _AdResult.dismissed),
          child: const Text(
            'Maybe later',
            style: TextStyle(color: Color(0xFF55534E), fontSize: 13),
          ),
        ),
      ],
    );
  }

  // ── Playing — the real AdMob view is overlaid full-screen by the SDK,
  //    so this dialog body just shows a quiet "preparing" spinner that's
  //    visible for the brief moment between tap and the SDK presenting.
  //    The instant onAdDismissedFullScreenContent fires we flip to done.

  Widget _buildPlaying(TextTheme tt) {
    return Padding(
      key: const ValueKey('playing'),
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(
            valueColor: AlwaysStoppedAnimation<Color>(_kOrange),
          ),
          const SizedBox(height: 18),
          Text(
            'Preparing your ad…',
            style: tt.bodyMedium?.copyWith(
              color:      const Color(0xFF55534E),
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  // ── Done — reward granted ──────────────────────────────────────────────────────

  Widget _buildDone(TextTheme tt) {
    return Column(
      key: const ValueKey('done'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width:  72,
          height: 72,
          decoration: BoxDecoration(
            color:        _kForest.withAlpha(20),
            borderRadius: BorderRadius.circular(22),
            border:       Border.all(color: _kForest.withAlpha(50)),
          ),
          child: const Icon(Icons.check_circle_rounded, color: _kForest, size: 40),
        ),
        const SizedBox(height: 18),
        Text(
          'Bonus unlocked! 🎉',
          style: tt.titleMedium?.copyWith(
            fontWeight: FontWeight.w900,
            color:      _kForest,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'You earned 1 bonus recipe generation. '
          'Upgrade to ChowSA Pro to cook without limits.',
          style: tt.bodySmall?.copyWith(
            color:  const Color(0xFF55534E),
            height: 1.6,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: () => Navigator.pop(context, _AdResult.rewarded),
            style: FilledButton.styleFrom(
              backgroundColor: _kForest,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape:   RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            ),
            child: const Text(
              'Cook my bonus recipe!',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
            ),
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// Supporting widgets
// =============================================================================

enum _Phase { idle, playing, done }

class _BenefitChip extends StatelessWidget {
  const _BenefitChip({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color:        _kForest.withAlpha(15),
        borderRadius: BorderRadius.circular(20),
        border:       Border.all(color: _kForest.withAlpha(35)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize:   12,
          fontWeight: FontWeight.w600,
          color:      _kForest,
        ),
      ),
    );
  }
}
