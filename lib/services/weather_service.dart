// lib/services/weather_service.dart
//
// Lightweight live-weather worker for ChowSA.
//
// ─── Architecture ────────────────────────────────────────────────────────────
//
//   • Singleton WeatherService.instance — no DI needed; one timer process-wide.
//   • Broadcast Stream<WeatherReading> — any widget can subscribe via
//     StreamBuilder and receives the latest reading instantly (replayed from
//     the in-memory cache) plus every refresh that follows.
//   • Refresh cadence: every 30 minutes via Timer.periodic. The timer is
//     STARTED on the first subscriber and STOPPED when the last subscriber
//     cancels — battery-friendly idle behaviour.
//   • Location resolution tier list (each falls through on failure):
//       1. profiles.city of the signed-in user → geocoded via Open-Meteo
//       2. Device GPS via Geolocator (best-effort, may be denied)
//       3. Cape Town default (-33.9249, 18.4241)
//   • Weather source: Open-Meteo current temperature endpoint — free,
//     keyless, generous rate limits.
//   • Pure http package, no third-party 'weather' wrapper required.
//
// ─── Usage ───────────────────────────────────────────────────────────────────
//
//   StreamBuilder<WeatherReading>(
//     stream: WeatherService.instance.stream,
//     builder: (ctx, snap) {
//       final reading = snap.data;
//       return Text(reading?.formatted ?? '--°C');
//     },
//   );
//
// The first frame after subscribe will receive the cached reading (or null
// when nothing has been fetched yet). Subsequent emissions arrive every
// 30 minutes and on any explicit refresh() call (e.g. pull-to-refresh).

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'location_permission_gate.dart';

// ─── WeatherReading ──────────────────────────────────────────────────────────

@immutable
class WeatherReading {
  /// Integer Celsius reading (rounded).
  final int    celsius;

  /// Human-readable resolved location label (e.g. "Cape Town", "Bloemfontein"
  /// — falls back to "Nearby" when only GPS was used, or "Cape Town" when the
  /// default ran).
  final String locationLabel;

  /// Wall-clock time the reading was fetched. Useful for debug overlays / UX
  /// that wants to show "updated 12 min ago".
  final DateTime fetchedAt;

  const WeatherReading({
    required this.celsius,
    required this.locationLabel,
    required this.fetchedAt,
  });

  /// Pre-formatted display string, e.g. "18°C".
  String get formatted => '$celsius°C';
}

// ─── WeatherService ──────────────────────────────────────────────────────────

class WeatherService {
  WeatherService._();

  /// Process-wide singleton — every subscriber shares the same timer.
  static final WeatherService instance = WeatherService._();

  // ── Tunables ───────────────────────────────────────────────────────────────
  static const Duration _refreshInterval = Duration(minutes: 30);
  static const Duration _httpTimeout     = Duration(seconds: 8);

  // Cape Town defaults — used as the final fallback so the widget is never
  // stuck at '--°C' on a working network even with denied permissions.
  static const double _kCapeTownLat = -33.9249;
  static const double _kCapeTownLng =  18.4241;

  // ── Internals ──────────────────────────────────────────────────────────────
  late final StreamController<WeatherReading> _controller =
      StreamController<WeatherReading>.broadcast(
        onListen: _handleFirstListener,
        onCancel: _handleLastListenerGone,
      );

  Timer?          _refreshTimer;
  WeatherReading? _cached;
  bool            _fetchInFlight = false;

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Broadcast stream of weather readings. Subscribe via StreamBuilder.
  /// The first subscriber triggers an immediate fetch + starts the 30-minute
  /// timer; the timer stops automatically when the last subscriber cancels.
  ///
  /// Broadcast streams don't replay past events to new listeners, so when a
  /// second screen subscribes mid-session it would otherwise wait until the
  /// next 30-minute tick to receive a value. Callers should pass
  /// [latest] to `StreamBuilder.initialData` to seed the first frame with
  /// the cached reading.
  Stream<WeatherReading> get stream => _controller.stream;

  /// Synchronous last known reading. Returns null until the first fetch
  /// resolves.
  WeatherReading? get latest => _cached;

  /// Force a fetch outside the 30-minute cadence (e.g. pull-to-refresh).
  /// Safe to call repeatedly — concurrent calls coalesce into one in-flight
  /// request.
  Future<void> refresh() => _fetchAndEmit();

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  void _handleFirstListener() {
    // First subscriber — fire an immediate fetch so they see real data ASAP,
    // then arm the 30-minute timer.
    _fetchAndEmit();
    _refreshTimer ??= Timer.periodic(_refreshInterval, (_) => _fetchAndEmit());
  }

  void _handleLastListenerGone() {
    // Drop the timer when nobody's listening — keeps the radio + CPU idle.
    _refreshTimer?.cancel();
    _refreshTimer = null;
  }

  // ── Fetch pipeline ─────────────────────────────────────────────────────────

  Future<void> _fetchAndEmit() async {
    if (_fetchInFlight) return;
    _fetchInFlight = true;
    try {
      final reading = await _resolveAndFetch();
      if (reading != null) {
        _cached = reading;
        if (!_controller.isClosed) _controller.add(reading);
      }
    } catch (_) {
      // Swallow — UI keeps showing the last good reading. The next 30-min
      // tick will retry automatically.
    } finally {
      _fetchInFlight = false;
    }
  }

  /// Walks the 3-tier location resolution and returns the first reading that
  /// succeeds. Returns null only when ALL three tiers fail.
  Future<WeatherReading?> _resolveAndFetch() async {
    // ── Tier 1: profiles.city of the signed-in user ─────────────────────────
    final cityName = await _readProfileCity();
    if (cityName != null && cityName.isNotEmpty) {
      final geo = await _geocodeCity(cityName);
      if (geo != null) {
        final temp = await _fetchTempForCoords(geo.$1, geo.$2);
        if (temp != null) {
          return WeatherReading(
            celsius:       temp,
            locationLabel: cityName,
            fetchedAt:     DateTime.now(),
          );
        }
      }
    }

    // ── Tier 2: device GPS ─────────────────────────────────────────────────
    try {
      // Shared gate handles BOTH the permission dialog AND the Play-
      // Services accuracy resolution dialog, and dedupes concurrent
      // callers so the OS prompt is only shown once across the app.
      final pos = await LocationPermissionGate.instance.getPosition(
        accuracy:  LocationAccuracy.low,
        timeLimit: const Duration(seconds: 8),
      );
      if (pos != null) {
        final temp = await _fetchTempForCoords(pos.latitude, pos.longitude);
        if (temp != null) {
          return WeatherReading(
            celsius:       temp,
            locationLabel: 'Nearby',
            fetchedAt:     DateTime.now(),
          );
        }
      }
    } catch (_) { /* GPS unavailable — fall through */ }

    // ── Tier 3: Cape Town default ──────────────────────────────────────────
    final temp = await _fetchTempForCoords(_kCapeTownLat, _kCapeTownLng);
    if (temp == null) return null;
    return WeatherReading(
      celsius:       temp,
      locationLabel: 'Cape Town',
      fetchedAt:     DateTime.now(),
    );
  }

  /// Reads `profiles.city` for the signed-in user. Returns null when not
  /// authenticated, when the column is empty, or on any network/auth failure.
  Future<String?> _readProfileCity() async {
    try {
      final uid = Supabase.instance.client.auth.currentUser?.id;
      if (uid == null) return null;
      final row = await Supabase.instance.client
          .from('profiles')
          .select('city')
          .eq('id', uid)
          .maybeSingle();
      final city = row?['city'] as String?;
      final clean = city?.trim();
      return (clean == null || clean.isEmpty) ? null : clean;
    } catch (_) {
      return null;
    }
  }

  /// Resolves a city name to (lat, lng) via Open-Meteo's free geocoding API.
  /// Returns null when the name doesn't resolve or on any failure.
  Future<(double, double)?> _geocodeCity(String name) async {
    try {
      final uri = Uri.parse(
        'https://geocoding-api.open-meteo.com/v1/search'
        '?name=${Uri.encodeQueryComponent(name)}'
        '&count=1&language=en&format=json',
      );
      final res = await http.get(uri).timeout(_httpTimeout);
      if (res.statusCode != 200) return null;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final results = body['results'] as List<dynamic>?;
      if (results == null || results.isEmpty) return null;
      final first = results.first as Map<String, dynamic>;
      final lat = (first['latitude']  as num?)?.toDouble();
      final lng = (first['longitude'] as num?)?.toDouble();
      if (lat == null || lng == null) return null;
      return (lat, lng);
    } catch (_) {
      return null;
    }
  }

  /// Single Open-Meteo round-trip for an explicit lat/lng pair.
  /// Returns the rounded Celsius value on success, null on any failure.
  Future<int?> _fetchTempForCoords(double lat, double lng) async {
    try {
      final uri = Uri.parse(
        'https://api.open-meteo.com/v1/forecast'
        '?latitude=${lat.toStringAsFixed(4)}'
        '&longitude=${lng.toStringAsFixed(4)}'
        '&current=temperature_2m&temperature_unit=celsius',
      );
      final res = await http.get(uri).timeout(_httpTimeout);
      if (res.statusCode != 200) return null;
      final body    = jsonDecode(res.body) as Map<String, dynamic>;
      final tempNum = body['current']?['temperature_2m'] as num?;
      return tempNum?.round();
    } catch (_) {
      return null;
    }
  }
}
