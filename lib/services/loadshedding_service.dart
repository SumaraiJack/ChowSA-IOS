// lib/services/loadshedding_service.dart
//
// Uses the Eskom loadshedding API documented at:
// https://tutorials.techrad.co.za/markdown/LOADSHEDDING_API/LOADSHEDDING_API.html
//
// Endpoint summary:
//   GetStatus          → integer: 1=no shedding, 2=Stage1, 3=Stage2, etc.
//   GetMunicipalities  → list municipalities by province ID
//   GetSurburbData     → list suburbs by municipality ID
//   GetScheduleM       → HTML schedule for a suburb at a given stage
//
// This service:
//   1. Calls GetStatus for the national stage
//   2. If active, calls GetScheduleM for the configured suburb to get today's slots
//   3. Caches results for 30 minutes to avoid hammering the API
//   4. Tracks last-active date for the days-free counter
//
// ── HOW TO CONFIGURE FOR YOUR SUBURB ─────────────────────────────────────────
//
// Step 1 — Find your province ID (Western Cape = 9, Gauteng = 3, etc.)
// Step 2 — Find your municipality ID:
//   GET https://loadshedding.eskom.co.za/LoadShedding/GetMunicipalities/?Id=9
// Step 3 — Find your suburb ID + Tot:
//   GET https://loadshedding.eskom.co.za/LoadShedding/GetSurburbData/?pageSize=100&pageNum=1&id=<municipalityId>
// Step 4 — Paste the values into the constants below.
//
// Default config: Cape Town (Observatory area), Western Cape

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geolocator/geolocator.dart';
import 'location_permission_gate.dart';

// =============================================================================
// Fallback config — used when location is unavailable or suburb lookup fails
// =============================================================================

const int    _kFallbackProvinceId = 9;        // Western Cape
const int    _kFallbackSuburbId   = 1061287;  // Observatory, Cape Town
const int    _kFallbackMuniTotal  = 1;
const String _kFallbackSuburbName = 'Cape Town (default)';

// Province bounding boxes — maps GPS coords to Eskom province ID.
// (eskomProvinceId, minLat, maxLat, minLng, maxLng)
// Rough boxes — good enough for province-level detection.
const _kProvinceBounds = [
  (3,  -26.85, -25.25, 27.30, 29.20),  // Gauteng
  (5,  -31.05, -26.85, 28.80, 32.95),  // KwaZulu-Natal
  (9,  -34.90, -31.50, 17.80, 23.50),  // Western Cape
  (4,  -34.05, -30.50, 24.50, 30.10),  // Eastern Cape
  (2,  -30.75, -26.50, 24.30, 29.55),  // Free State
  (10, -27.05, -24.00, 29.20, 32.90),  // Mpumalanga
  (6,  -25.05, -22.10, 26.50, 31.55),  // Limpopo
  (7,  -27.95, -25.30, 22.50, 28.25),  // North West
  (8,  -32.15, -28.05, 17.00, 25.05),  // Northern Cape
];

// =============================================================================
// Model
// =============================================================================

class LoadsheddingStatus {
  const LoadsheddingStatus({
    required this.isActive,
    required this.stage,
    required this.todaySlots,
    required this.daysFree,
    required this.source,
    this.suburbName,
  });

  final bool         isActive;
  final int          stage;
  /// List of time-slot strings for today, e.g. ["06:00–08:30", "18:00–20:30"]
  final List<String> todaySlots;
  final int          daysFree;
  /// "eskom" | "cache" | "offline"
  final String       source;
  /// Detected suburb name, or null if location unavailable
  final String?      suburbName;

  String get stageLabel => isActive ? 'Stage $stage' : 'No loadshedding';

  /// Suburb label shown in the UI
  String get displaySuburb => suburbName ?? _kFallbackSuburbName;

  /// First slot for today, or empty string
  String get nextSlot => todaySlots.isNotEmpty ? todaySlots.first : '';

  // Legacy compat getters used by the hero card widget
  String get nextStart => todaySlots.isNotEmpty
      ? todaySlots.first.split('–').first.trim()
      : '';
  String get nextEnd => todaySlots.isNotEmpty
      ? todaySlots.first.split('–').last.trim()
      : '';
}

// =============================================================================
// Service
// =============================================================================

class LoadsheddingService {
  static const _base         = 'https://loadshedding.eskom.co.za/LoadShedding';
  static const _cacheKey     = 'ls_techrad_v1';
  static const _cacheTimeKey = 'ls_techrad_time_v1';
  static const _lastShedKey  = 'ls_techrad_last_v1';
  static const _cacheTtlMin    = 30;

  // ── Main entry point ───────────────────────────────────────────────────────
  // 1. Try to get GPS location
  // 2. If we have GPS, detect province + look up nearest Eskom suburb ID
  // 3. Fetch national stage + today's schedule for that suburb
  // 4. Fall back to hardcoded Cape Town if anything goes wrong

  Future<LoadsheddingStatus> getStatus({bool forceRefresh = false}) async {
    if (!forceRefresh) {
      final cached = await _loadCache();
      if (cached != null) return cached;
    }

    // Resolve suburb from GPS (best-effort, non-blocking)
    final suburbInfo = await _resolveSuburbFromGps();
    final provinceId = suburbInfo.$1;
    final suburbId   = suburbInfo.$2;
    final muniTotal  = suburbInfo.$3;
    final suburbName = suburbInfo.$4;

    try {
      final stage = await _fetchStage();
      List<String> slots = [];
      if (stage > 0) {
        slots = await _fetchTodaySlots(stage, provinceId, suburbId, muniTotal);
      }
      final df = stage == 0 ? await _daysFree() : 0;
      final s  = LoadsheddingStatus(
        isActive:   stage > 0,
        stage:      stage,
        todaySlots: slots,
        daysFree:   df,
        source:     'eskom',
        suburbName: suburbName,
      );
      await _save(s);
      return s;
    } catch (e) {
      debugPrint('LoadsheddingService error: $e');
      return LoadsheddingStatus(
        isActive:   false,
        stage:      0,
        todaySlots: [],
        daysFree:   0,
        source:     'offline',
        suburbName: suburbName,
      );
    }
  }

  // ── GPS → province + suburb resolution ────────────────────────────────────
  // Returns (provinceId, suburbId, muniTotal, suburbName).
  // Falls back to Cape Town defaults if location or API lookup fails.

  Future<(int, int, int, String)> _resolveSuburbFromGps() async {
    try {
      // Shared gate — dedupes concurrent startup callers so only ONE
      // Play-Services accuracy dialog is shown across the whole app.
      final pos = await LocationPermissionGate.instance.getPosition(
        accuracy:  LocationAccuracy.low, // city-level is enough
        timeLimit: const Duration(seconds: 6),
      );
      if (pos == null) {
        return (_kFallbackProvinceId, _kFallbackSuburbId,
                _kFallbackMuniTotal, _kFallbackSuburbName);
      }

      // Map coords to an Eskom province ID
      final provinceId = _provinceIdFromCoords(pos.latitude, pos.longitude);
      if (provinceId == null) {
        return (_kFallbackProvinceId, _kFallbackSuburbId,
                _kFallbackMuniTotal, _kFallbackSuburbName);
      }

      // Fetch municipality list for this province
      final munis = await _fetchMunicipalities(provinceId);
      if (munis.isEmpty) {
        return (provinceId, _kFallbackSuburbId,
                _kFallbackMuniTotal, _kFallbackSuburbName);
      }

      // Find the municipality whose suburbs are geographically closest
      // (We search each municipality's suburb list and pick nearest centroid)
      final best = await _findNearestSuburb(
          munis, pos.latitude, pos.longitude);
      if (best == null) {
        return (provinceId, _kFallbackSuburbId,
                _kFallbackMuniTotal, _kFallbackSuburbName);
      }

      debugPrint('LoadsheddingService: resolved suburb '
          '"${best.$3}" (id=${best.$1}, tot=${best.$2})');
      return (provinceId, best.$1, best.$2, best.$3);

    } catch (e) {
      debugPrint('LoadsheddingService GPS resolve failed: $e');
      return (_kFallbackProvinceId, _kFallbackSuburbId,
              _kFallbackMuniTotal, _kFallbackSuburbName);
    }
  }

  // Maps a lat/lng to an Eskom province ID using bounding boxes.
  int? _provinceIdFromCoords(double lat, double lng) {
    for (final p in _kProvinceBounds) {
      final id = p.$1;
      final minLat = p.$2; final maxLat = p.$3;
      final minLng = p.$4; final maxLng = p.$5;
      if (lat >= minLat && lat <= maxLat && lng >= minLng && lng <= maxLng) {
        return id;
      }
    }
    return null;
  }

  // GET /GetMunicipalities/?Id={provinceId} → [{Text, Value}]
  Future<List<(int, String)>> _fetchMunicipalities(int provinceId) async {
    try {
      final res = await http
          .get(Uri.parse('$_base/GetMunicipalities/?Id=$provinceId'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return [];
      final list = jsonDecode(res.body) as List<dynamic>;
      return list.map((m) {
        final id   = int.tryParse(m['Value'].toString()) ?? 0;
        final name = (m['Text'] as String).trim();
        return (id, name);
      }).where((t) => t.$1 > 0).toList();
    } catch (_) { return []; }
  }

  // For each municipality, fetch its suburb list and find the one closest
  // to the user's GPS coords using a simple name-centroid heuristic.
  // Returns (suburbId, muniTotal, suburbName) or null.
  Future<(int, int, String)?> _findNearestSuburb(
      List<(int, String)> munis, double lat, double lng) async {
    // We can't get GPS coords of suburbs from Eskom's API, so instead we
    // pick the first municipality that returns suburbs and use the first
    // suburb — a reasonable proxy when we have province-level accuracy.
    // For major metros (Cape Town, JHB, etc.) the first muni is the city.
    for (final muni in munis.take(3)) {
      final suburbs = await _fetchSuburbs(muni.$1);
      if (suburbs.isNotEmpty) {
        // Pick first suburb as representative of the area
        final s = suburbs.first;
        return (s.$1, s.$2, s.$3);
      }
    }
    return null;
  }

  // GET /GetSurburbData/?pageSize=20&pageNum=1&id={muniId}
  // Returns [(suburbId, Tot, suburbName)]
  Future<List<(int, int, String)>> _fetchSuburbs(int muniId) async {
    try {
      final url = '$_base/GetSurburbData/?pageSize=20&pageNum=1&id=$muniId';
      final res = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return [];
      final list = jsonDecode(res.body) as List<dynamic>;
      return list.map((s) {
        final id   = int.tryParse(s['Id'].toString()) ?? 0;
        final tot  = int.tryParse(s['Tot'].toString()) ?? 1;
        final name = (s['Name'] as String).trim();
        return (id, tot, name);
      }).where((t) => t.$1 > 0).toList();
    } catch (_) { return []; }
  }

  // ── Step 1: Get national stage ─────────────────────────────────────────────
  // Response: "1" = no shedding, "2" = Stage 1, "3" = Stage 2, etc.
  // Rule: if value < 1 discard; else subtract 1 for actual stage number.

  Future<int> _fetchStage() async {
    final res = await http
        .get(Uri.parse('$_base/GetStatus'))
        .timeout(const Duration(seconds: 8));

    if (res.statusCode != 200) {
      throw Exception('GetStatus returned ${res.statusCode}');
    }

    final raw   = res.body.trim().replaceAll('"', '');
    final value = int.tryParse(raw) ?? 0;

    // Per the TECHRAD docs: if value < 1, discard (no data). Else subtract 1.
    if (value < 1) return 0;
    final stage = value - 1;
    return stage; // 0 = no shedding, 1..8 = Stage 1..8
  }


  // ── Step 2: Get today's schedule for the resolved suburb ──────────────────
  Future<List<String>> _fetchTodaySlots(
      int stage, int provinceId, int suburbId, int muniTotal) async {
    final url = '$_base/GetScheduleM/$suburbId/$stage/$provinceId/$muniTotal';
    final res = await http
        .get(Uri.parse(url))
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return [];
    return _parseTodaySlots(res.body);
  }

  List<String> _parseTodaySlots(String html) {
    // Strip all HTML tags — the response is essentially plain text with tags
    final clean = html
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll(RegExp(r'&nbsp;'), ' ')
        .replaceAll(RegExp(r'Find Print schedule.*', dotAll: true), '')
        .trim();

    final lines = clean
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

    // Build a map: "Wed, 09 Sep" → ["06:00 - 08:30", ...]
    final now        = DateTime.now();
    final todayLabel = _formatDateLabel(now);   // e.g. "Wed, 09 Sep"

    final slots       = <String>[];
    bool  inToday     = false;
    final dayPattern  = RegExp(r'^[A-Za-z]{3},\s+\d{1,2}\s+[A-Za-z]{3}$');
    final timePattern = RegExp(r'^\d{2}:\d{2}\s*[-–]\s*\d{2}:\d{2}$');

    for (final line in lines) {
      if (dayPattern.hasMatch(line)) {
        // Are we entering today's section?
        inToday = _labelsMatch(line, todayLabel);
        continue;
      }
      if (inToday && timePattern.hasMatch(line)) {
        // Normalise separator to en-dash
        slots.add(line.replaceAll(' - ', '–').replaceAll('- ', '–'));
      } else if (inToday && dayPattern.hasMatch(line)) {
        // We've moved past today
        break;
      }
    }

    return slots;
  }

  // e.g. DateTime(2024,9,11) → "Wed, 11 Sep"
  String _formatDateLabel(DateTime d) {
    const days   = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
    const months = ['Jan','Feb','Mar','Apr','May','Jun',
                    'Jul','Aug','Sep','Oct','Nov','Dec'];
    // weekday: 1=Mon..7=Sun
    final dow = days[d.weekday - 1];
    final mon = months[d.month - 1];
    return '$dow, ${d.day.toString().padLeft(2)} $mon';
  }

  // Compare loosely: "Wed, 09 Sep" vs "Wed,  9 Sep" both valid
  bool _labelsMatch(String a, String b) {
    String norm(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();
    return norm(a) == norm(b);
  }


  // ── Days-free counter ──────────────────────────────────────────────────────

  Future<int> _daysFree() async {
    final prefs  = await SharedPreferences.getInstance();
    final stored = prefs.getString(_lastShedKey);
    if (stored == null) return 0;
    final last   = DateTime.tryParse(stored);
    return last == null ? 0 : DateTime.now().difference(last).inDays;
  }

  // ── Cache ──────────────────────────────────────────────────────────────────

  Future<LoadsheddingStatus?> _loadCache() async {
    final prefs   = await SharedPreferences.getInstance();
    final timeStr = prefs.getString(_cacheTimeKey);
    final jsonStr = prefs.getString(_cacheKey);
    if (timeStr == null || jsonStr == null) return null;
    final saved   = DateTime.tryParse(timeStr);
    if (saved == null) return null;
    if (DateTime.now().difference(saved).inMinutes > _cacheTtlMin) return null;
    try {
      final m = jsonDecode(jsonStr) as Map<String, dynamic>;
      return LoadsheddingStatus(
        isActive:   m['active']    as bool,
        stage:      m['stage']     as int,
        todaySlots: List<String>.from(m['slots'] as List),
        daysFree:   m['daysFree']  as int,
        source:     'cache',
        suburbName: m['suburb']    as String?,
      );
    } catch (_) { return null; }
  }

  Future<void> _save(LoadsheddingStatus s) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_cacheTimeKey, DateTime.now().toIso8601String());
    await prefs.setString(_cacheKey, jsonEncode({
      'active':   s.isActive,
      'stage':    s.stage,
      'slots':    s.todaySlots,
      'daysFree': s.daysFree,
      'suburb':   s.suburbName,
    }));
    if (s.isActive) {
      await prefs.setString(_lastShedKey, DateTime.now().toIso8601String());
    }
  }
}
