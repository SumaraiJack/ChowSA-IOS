// lib/services/location_permission_gate.dart
//
// App-wide gate around `Geolocator.requestPermission()` to guarantee the OS
// permission dialog is only shown once at a time. Without this, two
// independent startup paths (e.g. LocalHubService.bootstrap() from main()
// and CommunityHubScreen kicking another refreshFromGps()) could each fire
// requestPermission() in the same frame and stack two identical OS dialogs
// on top of each other — which forced the user to tap "Turn on" twice.
//
// Behaviour:
//   • The first caller fires `Geolocator.requestPermission()`.
//   • Every caller that arrives while that future is still pending receives
//     the SAME future — no second OS dialog is shown.
//   • Once a permission has been granted-or-deniedForever we cache the
//     result and return it directly without ever touching the OS again,
//     so background pollers (weather, loadshedding, recipe scraper) don't
//     re-prompt mid-session.
//   • A `denied` (not deniedForever) result is NOT cached, so the user can
//     change their mind on a later action.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

class LocationPermissionGate {
  LocationPermissionGate._();
  static final LocationPermissionGate instance = LocationPermissionGate._();

  /// In-flight request — null when nothing is pending. Subsequent callers
  /// piggy-back on this future so we never trigger two simultaneous OS
  /// dialogs.
  Future<LocationPermission>? _inFlight;

  /// Sticky cached result. Only populated once the answer is final:
  /// `whileInUse`, `always`, or `deniedForever`. A transient `denied`
  /// stays unset so future user-initiated actions can try again.
  LocationPermission? _cached;

  /// Ensures we have a usable location permission. Returns the current
  /// permission state (granted or denied). Never throws — failures collapse
  /// to `LocationPermission.denied`.
  Future<LocationPermission> ensure() async {
    if (_cached != null) return _cached!;
    if (_inFlight != null) return _inFlight!;

    _inFlight = _doEnsure();
    try {
      final result = await _inFlight!;
      return result;
    } finally {
      _inFlight = null;
    }
  }

  Future<LocationPermission> _doEnsure() async {
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        // ONE OS dialog. Concurrent callers awaited _inFlight so this is
        // the only path that hits requestPermission this session.
        perm = await Geolocator.requestPermission();
      }
      // Cache only terminal states so a temporary "denied" doesn't lock
      // the user out for the whole session.
      if (perm == LocationPermission.whileInUse ||
          perm == LocationPermission.always     ||
          perm == LocationPermission.deniedForever) {
        _cached = perm;
      }
      return perm;
    } catch (_) {
      return LocationPermission.denied;
    }
  }

  /// True iff the current cached/asked permission grants foreground access.
  /// Use this from callers that prefer a simple bool over the enum.
  Future<bool> ensureGranted() async {
    final p = await ensure();
    return p == LocationPermission.whileInUse ||
           p == LocationPermission.always;
  }

  // ───────────────────────────────────────────────────────────────────────────
  //   getPosition() — serialised + briefly cached
  // ───────────────────────────────────────────────────────────────────────────
  //
  // Why this exists:
  //   On Android, Geolocator.getCurrentPosition() triggers Google Play
  //   Services' Location Accuracy resolution dialog ("For a better
  //   experience, your device will need to use Location Accuracy…") when
  //   high-accuracy mode is off. This dialog is independent of the
  //   runtime permission dialog handled by ensure() above.
  //
  //   On app startup four independent code paths race to fix the user's
  //   position — LocalHubService.bootstrap() (from main()),
  //   LoadsheddingService._resolveSuburbFromGps(), WeatherService, and
  //   CommunityHubScreen.refreshFromGps() — and each one was firing its
  //   own getCurrentPosition() call simultaneously. That stacked TWO
  //   identical Play-Services accuracy dialogs on top of each other,
  //   which is why "Turn on" / "No thanks" had to be tapped twice.
  //
  //   The latch below collapses concurrent callers onto a single in-flight
  //   future (so only ONE accuracy dialog is shown) and caches the
  //   resolved Position for a short window so back-to-back startup
  //   readers don't even hit Geolocator twice.
  //
  // Cache TTL is deliberately short — long enough to dedupe the startup
  // storm, short enough that subsequent user-initiated location actions
  // (e.g. "Use current location" in the recipe scraper) still get fresh
  // coordinates.

  static const Duration _kPositionCacheTtl = Duration(seconds: 30);

  Future<Position?>? _inFlightPosition;
  Position?          _cachedPosition;
  DateTime?          _cachedPositionAt;

  /// Returns a fresh-ish Position, deduplicating concurrent callers so the
  /// Play-Services accuracy resolution dialog is only shown once.
  ///
  /// Returns null if location services are off, the permission was denied,
  /// or the underlying Geolocator call timed out.
  Future<Position?> getPosition({
    LocationAccuracy accuracy  = LocationAccuracy.medium,
    Duration         timeLimit = const Duration(seconds: 8),
  }) async {
    // Cache hit — common path during the first few seconds after launch
    // while every service is asking for the user's coordinates.
    final cachedAt = _cachedPositionAt;
    if (_cachedPosition != null &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt) < _kPositionCacheTtl) {
      return _cachedPosition;
    }

    // A call is already running — piggy-back on it so we don't stack a
    // second Play-Services dialog. Note we discard the caller's accuracy
    // / timeLimit overrides in this branch; the first caller's settings
    // win. That's the right trade-off — preventing a second OS dialog is
    // more important than honouring a slightly different accuracy hint.
    if (_inFlightPosition != null) return _inFlightPosition!;

    _inFlightPosition = _doGetPosition(accuracy, timeLimit);
    try {
      final pos = await _inFlightPosition!;
      if (pos != null) {
        _cachedPosition   = pos;
        _cachedPositionAt = DateTime.now();
      }
      return pos;
    } finally {
      _inFlightPosition = null;
    }
  }

  Future<Position?> _doGetPosition(
    LocationAccuracy accuracy,
    Duration         timeLimit,
  ) async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      if (!await ensureGranted()) return null;

      // Fast path: Android often holds an internal lock on the GNSS stack
      // after a successful fix, so a second back-to-back getCurrentPosition()
      // call within ~10–30s can hang until timeLimit fires. Hand back the
      // last known fix immediately if it's available — it's identical to
      // what the OS would return anyway, and avoids the spurious "no GPS
      // fix" snackbar the user keeps seeing after their first pin drop.
      try {
        final last = await Geolocator.getLastKnownPosition();
        if (last != null &&
            last.latitude != 0.0 &&
            last.longitude != 0.0) {
          return last;
        }
      } catch (_) {/* fall through to live fix */}

      try {
        return await Geolocator.getCurrentPosition(
          locationSettings: LocationSettings(
            accuracy:  accuracy,
            timeLimit: timeLimit,
          ),
        );
      } catch (_) {
        // getCurrentPosition timed out or the platform threw — fall back to
        // any last known fix the OS still has on file. Better a slightly
        // stale pin than a dead button.
        try {
          return await Geolocator.getLastKnownPosition();
        } catch (_) {
          return _cachedPosition; // last-resort: our own previous fix
        }
      }
    } catch (_) {
      return null;
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  //   ensureServicesOnPrompt() — startup-time GPS hardware check
  // ───────────────────────────────────────────────────────────────────────────
  //
  // The runtime permission dialog and the OS-level GPS hardware toggle are
  // two separate things. ensure()/ensureGranted() above only handles the
  // permission. If a user has granted the permission but switched their
  // device's Location off in Quick Settings, every getCurrentPosition()
  // call silently times out — features like LocalHubService resolution,
  // weather, loadshedding suburb detection, and Spotted-pin drops all
  // degrade quietly with no UI feedback.
  //
  // This helper surfaces an actionable AlertDialog (the same shape the
  // channel_chat_screen "Spotted pin" flow uses) the first time the user
  // lands on a screen that depends on GPS — typically MainNavigationHub.
  // The "Open Settings" CTA routes to Geolocator.openLocationSettings(),
  // which is the same system redirect Android exposes for the Spotted pin.
  //
  // Session-level latch: we only prompt ONCE per app launch so the dialog
  // doesn't reappear every time the user dismisses it and returns to the
  // hub. A cold restart re-arms it.

  /// Per-session latch so the modal only fires once per app launch.
  bool _promptedThisSession = false;

  /// Permission-first GPS hardware check.
  ///
  /// 1. Request runtime location permission (Android system "Precise /
  ///    Approximate" dialog) via [ensure]. We DON'T touch UI until the
  ///    user has granted permission — chaining the GPS prompt before
  ///    permission is the cause of the "two dialogs back-to-back" UX
  ///    complaint.
  /// 2. If permission was granted AND the device-level GPS toggle is
  ///    off, show the ChowSA-branded modal exactly once. Its "Open
  ///    Settings" CTA invokes [Geolocator.openLocationSettings] so the
  ///    user lands directly on the system Location page to flip GPS on.
  Future<void> ensureServicesOnPrompt(BuildContext context) async {
    if (_promptedThisSession) return;

    final perm = await ensure();
    final granted = perm == LocationPermission.whileInUse ||
                    perm == LocationPermission.always;
    if (!granted) return;

    bool servicesOn;
    try {
      servicesOn = await Geolocator.isLocationServiceEnabled();
    } catch (_) {
      return; // no Play Services — skip silently
    }
    if (servicesOn) return;
    if (!context.mounted) return;

    _promptedThisSession = true;

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20)),
        title: const Text(
          'Turn on Location',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
        content: const Text(
          'ChowSA uses your location to find your nearest braai hub, fetch '
          'local weather, and detect loadshedding for your suburb. Your '
          "phone's GPS is currently switched off — turn it on in Settings "
          'to unlock the local features.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text(
              'Not now',
              style: TextStyle(
                color: Color(0xFFE59B27),
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              Geolocator.openLocationSettings();
            },
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFE59B27),
              foregroundColor: Colors.white,
            ),
            child: const Text(
              'Open Settings',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
  }
}
