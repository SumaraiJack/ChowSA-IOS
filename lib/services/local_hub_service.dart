// lib/services/local_hub_service.dart
//
// Resolves the user's primary local hub from device GPS by calling the
// PostGIS-backed `get_nearest_hubs` RPC in Supabase. Exposes the result as
// a ValueNotifier<HubModel?> so any widget (e.g. CommunityHubScreen) can
// listen and rebuild when the hub changes.
//
// Permission policy:
//   • If location services are off OR the user denies permission, we
//     silently fall back to a `null` hub. Upstream UI is expected to fall
//     back to its existing suburb-string resolution path.
//   • We never block app startup on the GPS fetch — the bootstrap runs
//     fire-and-forget from main().

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/hub_model.dart';
import 'location_permission_gate.dart';

class LocalHubService {
  LocalHubService._();
  static final instance = LocalHubService._();

  static const _kPrefsHubId       = 'chowsa_local_hub_id';
  static const _kPrefsHubName     = 'chowsa_local_hub_name';
  static const _kPrefsHubSlug     = 'chowsa_local_hub_slug';
  static const _kPrefsHubProvince = 'chowsa_local_hub_province';

  /// Active local hub, or `null` if not yet resolved / permission denied.
  /// UI should `ValueListenableBuilder` against this.
  final ValueNotifier<HubModel?> currentHub = ValueNotifier<HubModel?>(null);

  /// True while the GPS → Supabase RPC chain is in flight.
  /// Set to false once the chain completes OR the fallback kicks in, so
  /// widgets can show a loading placeholder only for the brief first-open
  /// window rather than indefinitely.
  final ValueNotifier<bool> isLoading = ValueNotifier<bool>(false);

  // Hard ceiling on the full GPS + RPC round-trip. After this the cached
  // value is used as-is, even if GPS hasn't locked yet.
  static const _kRefreshTimeout = Duration(seconds: 12);

  SupabaseClient get _sb => Supabase.instance.client;

  /// Best-effort startup:
  ///   1. Immediately rehydrate the last-known hub from SharedPreferences
  ///      (instant first paint — no spinner visible to the user).
  ///   2. Fire a GPS refresh in the background to update if the user has moved.
  ///      The refresh is capped at [_kRefreshTimeout]; if it takes longer the
  ///      cached value (already set in step 1) is kept and loading clears.
  Future<void> bootstrap() async {
    await _rehydrateFromCache();
    unawaited(refreshFromGps());
  }

  Future<void> _rehydrateFromCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final id = prefs.getString(_kPrefsHubId);
      if (id == null) return;
      currentHub.value = HubModel(
        id:             id,
        name:           prefs.getString(_kPrefsHubName)     ?? '',
        slug:           prefs.getString(_kPrefsHubSlug)     ?? '',
        province:       prefs.getString(_kPrefsHubProvince) ?? '',
        distanceMeters: 0.0,
      );
    } catch (_) {
      // Cache rehydrate is best-effort.
    }
  }

  /// Re-runs GPS → Supabase RPC and updates [currentHub].
  ///
  /// Loading lifecycle:
  ///   isLoading → true  on entry
  ///   isLoading → false once a hub is found, the RPC returns empty, GPS
  ///                     fails, OR the hard [_kRefreshTimeout] elapses —
  ///                     whichever comes first.
  ///
  /// If the timeout fires before the chain completes, the function returns
  /// the last value from [currentHub] (which may already be the cached hub
  /// from [bootstrap]), so the UI is never left hanging forever.
  Future<HubModel?> refreshFromGps({
    double maxDistanceMeters = 25000,
    int    limit             = 3,
  }) async {
    isLoading.value = true;
    try {
      final result = await _doRefresh(
        maxDistanceMeters: maxDistanceMeters,
        limit:             limit,
      ).timeout(
        _kRefreshTimeout,
        onTimeout: () {
          // GPS or RPC took too long. Keep whatever is already in currentHub
          // (either the cache from bootstrap or null) — don't null it out.
          debugPrint(
            'LocalHubService: refresh timed out after '
            '${_kRefreshTimeout.inSeconds}s — using cached hub.',
          );
          return currentHub.value;
        },
      );
      return result;
    } catch (e) {
      debugPrint('LocalHubService: refreshFromGps error: $e');
      return currentHub.value; // fall back to whatever was already loaded
    } finally {
      // Always clear the loading flag — even on error or timeout — so the
      // UI never stays on a spinner indefinitely.
      isLoading.value = false;
    }
  }

  /// Inner refresh logic, called by [refreshFromGps] inside the timeout.
  Future<HubModel?> _doRefresh({
    required double maxDistanceMeters,
    required int    limit,
  }) async {
    final pos = await _getPosition();
    if (pos == null) return currentHub.value; // permission denied / no fix

    final hubs = await fetchLocalHubs(
      pos.latitude,
      pos.longitude,
      maxDistanceMeters: maxDistanceMeters,
      limit:             limit,
    );
    final primary = hubs.isEmpty ? null : hubs.first;
    if (primary != null) {
      currentHub.value = primary;
      unawaited(_persist(primary));
    }
    return primary ?? currentHub.value;
  }

  /// Calls the `get_nearest_hubs` RPC and decodes to typed models.
  /// Public so screens can show the full ranked list when useful.
  Future<List<HubModel>> fetchLocalHubs(
    double lat,
    double lon, {
    double maxDistanceMeters = 25000,
    int    limit             = 3,
  }) async {
    try {
      final res = await _sb.rpc('get_nearest_hubs', params: {
        'user_lat':            lat,
        'user_lon':            lon,
        'max_distance_meters': maxDistanceMeters,
        'limit_count':         limit,
      });
      if (res is! List) return const [];
      return res
          .cast<Map<String, dynamic>>()
          .map(HubModel.fromJson)
          .toList(growable: false);
    } catch (e) {
      debugPrint('LocalHubService: get_nearest_hubs failed: $e');
      return const [];
    }
  }

  /// Acquires a position with the standard permission-prompt flow. Returns
  /// `null` on any denial / disabled-service / timeout path.
  Future<Position?> _getPosition() async {
    // Single gate handles permission AND the Play-Services accuracy
    // resolution dialog — concurrent callers from main()/loadshedding/
    // weather/community-hub all share one in-flight future + a 30s
    // result cache, so the OS dialog only ever surfaces once.
    return LocationPermissionGate.instance.getPosition(
      accuracy:  LocationAccuracy.medium,
      timeLimit: const Duration(seconds: 8),
    );
  }

  Future<void> _persist(HubModel hub) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kPrefsHubId,       hub.id);
      await prefs.setString(_kPrefsHubName,     hub.name);
      await prefs.setString(_kPrefsHubSlug,     hub.slug);
      await prefs.setString(_kPrefsHubProvince, hub.province);
    } catch (_) {
      // Persistence is best-effort.
    }
  }
}
