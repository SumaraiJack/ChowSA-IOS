// lib/services/price_estimate_service.dart
//
// AI-powered "Estimate Total" for the Shopping List detail view.
//
// Sends the user's active list to Gemini with a strict, JSON-only system
// prompt and parses back per-item ZAR price estimates plus a grand
// total. The estimates are grounded in average SA supermarket pricing
// (Pick n Pay, Shoprite/Checkers, Spar, Woolworths) so the result lines
// up with what the user actually sees at the till.
//
// API key resolution mirrors the rest of the AI surfaces (Scraper +
// Pantry generator) — pulls from `kGeminiApiKey` first, falls back to
// the --dart-define `GEMINI_API_KEY`, and degrades to a built-in mock
// estimator when nothing is configured so the UI is always testable
// end-to-end.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/env.config.dart';

const _dartDefineKey =
    String.fromEnvironment('GEMINI_API_KEY', defaultValue: '');
final String _kPriceEstApiKey =
    kGeminiApiKey.isNotEmpty ? kGeminiApiKey : _dartDefineKey;

/// Per-item estimate carried back from the AI.
class PriceEstimate {
  const PriceEstimate({required this.originalName, required this.avgPriceZar});
  final String  originalName;
  final double  avgPriceZar;
}

/// Result of a single "Estimate Total" run. [byOriginalName] maps the
/// EXACT string the caller submitted to its estimate; widgets render
/// "Est. Avg: R{n}" by looking up their item by name.
class PriceEstimateResult {
  const PriceEstimateResult({
    required this.byOriginalName,
    required this.grandTotal,
  });
  final Map<String, double> byOriginalName;
  final double              grandTotal;
}

/// WS6: one active special hit for a normalised item — store + price.
class SpecialMatch {
  const SpecialMatch({required this.store, required this.priceZar});
  final String store;
  final double priceZar;
}

/// Thrown when the AI round-trip fails (network, quota, bad JSON, etc.).
/// The UI maps this to a friendly "Could not fetch price estimates"
/// SnackBar without exposing the underlying error string.
class PriceEstimateException implements Exception {
  const PriceEstimateException(this.message);
  final String message;
  @override
  String toString() => 'PriceEstimateException: $message';
}

class PriceEstimateService {
  PriceEstimateService._();
  static final instance = PriceEstimateService._();

  // Remote baselines loaded once from Supabase `price_baselines` on app start.
  // Sorted by specificity desc so multi-word matches win first, mirroring the
  // hardcoded map's iteration order. Null until init() succeeds; on failure
  // (offline, RLS, network) it stays null and the static [_baselines] map
  // remains the source of truth — the offline-resilience contract.
  List<MapEntry<String, double>>? _remoteBaselines;

  /// Hydrates the editable baselines from Supabase. Best-effort; safe to call
  /// before auth. A failure leaves the hardcoded fallback intact.
  Future<void> init() async {
    try {
      final rows = await Supabase.instance.client
          .from('price_baselines')
          .select('keyword, avg_price_zar, specificity')
          .order('specificity', ascending: false)
          .order('keyword', ascending: true);
      final list = <MapEntry<String, double>>[];
      for (final r in (rows as List)) {
        final m = r as Map<String, dynamic>;
        final k = (m['keyword'] as String?)?.toLowerCase();
        final p = (m['avg_price_zar'] as num?)?.toDouble();
        if (k == null || k.isEmpty || p == null) continue;
        list.add(MapEntry(k, p));
      }
      if (list.isNotEmpty) {
        _remoteBaselines = list;
        debugPrint('PriceEstimateService: loaded ${list.length} remote baselines.');
      }
    } catch (e) {
      debugPrint('PriceEstimateService: baseline load failed ($e); using hardcoded fallback.');
    }
  }

  // ── Specials overlay (WS6) ────────────────────────────────────────────
  //
  // Batch-fetches every active special whose normalized_name matches one
  // of the user's list items. The `specials` table is refreshed weekly by
  // a Supabase Edge Function cron (server-side AI extract from retailer
  // catalogues) — the app only ever reads, never writes. Failure returns
  // an empty map so a flaky network simply hides the badge.

  /// Active special for a normalised item, or null when the item is not on
  /// special today.
  Future<Map<String, SpecialMatch>> fetchActiveSpecials(
      Iterable<String> normalized) async {
    final keys = normalized.toSet().toList();
    if (keys.isEmpty) return const {};
    try {
      final today = DateTime.now().toUtc().toIso8601String().substring(0, 10);
      final rows = await Supabase.instance.client
          .from('specials')
          .select('normalized_name, store, price_zar, valid_to')
          .inFilter('normalized_name', keys)
          .gte('valid_to', today);
      final out = <String, SpecialMatch>{};
      for (final r in (rows as List)) {
        final m = r as Map<String, dynamic>;
        final k = m['normalized_name'] as String?;
        final s = m['store']           as String?;
        final p = (m['price_zar'] as num?)?.toDouble();
        if (k == null || s == null || p == null) continue;
        // Keep the cheapest live special when the same normalised item
        // appears at multiple retailers.
        final existing = out[k];
        if (existing == null || p < existing.priceZar) {
          out[k] = SpecialMatch(store: s, priceZar: p);
        }
      }
      return out;
    } catch (_) {
      return const {};
    }
  }

  /// Public wrapper so callers don't have to know the normalisation rule.
  String normalizeForSpecials(String raw) => _normalize(raw);

  // ── Cache plumbing (Supabase price_cache) ─────────────────────────────
  //
  // Normalisation is intentionally simple: lower-case, collapse whitespace,
  // strip punctuation. This keeps "1L Milk", "1l milk ", and "1l, milk"
  // sharing one cache row without dragging in a stemming library. Pack-size
  // and bulk pricing are absorbed by the local engine downstream — the cache
  // key is the *user-typed* shape, not the parsed shape.
  String _normalize(String raw) {
    final lower = raw.toLowerCase().trim();
    final cleaned = lower
        .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return cleaned;
  }

  Future<Map<String, double>> _readCache(Iterable<String> normalized) async {
    final keys = normalized.toSet().toList();
    if (keys.isEmpty) return const {};
    try {
      final rows = await Supabase.instance.client
          .from('price_cache')
          .select('normalized_name, avg_price_zar')
          .inFilter('normalized_name', keys);
      final out = <String, double>{};
      for (final r in (rows as List)) {
        final m = r as Map<String, dynamic>;
        final k = m['normalized_name'] as String?;
        final p = (m['avg_price_zar'] as num?)?.toDouble();
        if (k != null && p != null) out[k] = p;
      }
      return out;
    } catch (e) {
      debugPrint('PriceEstimateService: cache read failed ($e); skipping.');
      return const {};
    }
  }

  Future<void> _writeCache(Map<String, double> normalizedPrices, String source) async {
    if (normalizedPrices.isEmpty) return;
    // Skip when there's no auth session — RLS would reject the insert anyway.
    final session = Supabase.instance.client.auth.currentSession;
    if (session == null) return;
    final now = DateTime.now().toUtc().toIso8601String();
    final payload = normalizedPrices.entries
        .where((e) => e.key.isNotEmpty && e.value > 0)
        .map((e) => {
              'normalized_name': e.key,
              'avg_price_zar':   double.parse(e.value.toStringAsFixed(2)),
              'source':          source,
              'updated_at':      now,
            })
        .toList(growable: false);
    if (payload.isEmpty) return;
    try {
      await Supabase.instance.client
          .from('price_cache')
          .upsert(payload, onConflict: 'normalized_name');
    } catch (e) {
      // Cache writes are best-effort — a failure must never break estimate().
      debugPrint('PriceEstimateService: cache write failed ($e); ignoring.');
    }
  }

  // gemini-2.5-flash-lite — same cheap, fast text model the rest of the
  // app uses for structured JSON tasks. The system instruction below
  // pins the role + JSON contract.
  late final GenerativeModel _model = GenerativeModel(
    model:             'gemini-2.5-flash-lite',
    apiKey:            _kPriceEstApiKey,
    systemInstruction: Content.system(_systemPrompt),
    generationConfig:  GenerationConfig(
      responseMimeType: 'application/json',
      temperature:      0.1,
    ),
  );

  static const String _systemPrompt = '''
You are a localized South African retail pricing data aggregator. Estimate the
average price in South African Rand (ZAR) for the following grocery items,
keeping values grounded in realistic average pricing across major local
supermarkets: Pick n Pay, Shoprite / Checkers, Spar, and Woolworths.

Use these recent SA shelf baselines as anchors when computing your estimate:
- 1L UHT Full Cream Milk  ........... R18.00
- 6 x 1L UHT Full Cream Milk ........ R102.00 (apply ~5% bulk discount)
- 700g White Bread Loaf ............. R18.50
- 700g Brown Bread Loaf ............. R20.00
- Dozen Large Eggs .................. R55.00
- 500g Beef Mince ................... R85.00
- 1kg Chicken Pieces ................ R75.00
- 1kg Boerewors ..................... R120.00
- Cup a Soup (single packet) ........ R25.50
- 2.5kg White Sugar ................. R65.00
- 1kg Cake Flour .................... R40.00
- 2kg Mealie Meal ................... R50.00
- 750ml Sunflower Oil ............... R55.00

Pack-size and bulk pricing rules (Tier 2 — smart multiplier):
- "6 pack" / "6 x 1L" / "6x500ml" => price = (single unit) * count * 0.95.
- "12 pack" / "dozen"             => price = (single unit) * 12  * 0.92.
- "2 pack" / "twin pack"          => price = (single unit) * 2   * 0.97.
- If a size is named ("2L", "500g", "1kg") use the closest matching SA shelf
  baseline; never blindly extrapolate without grounding.

Sanity guard rails (Tier 3 — cap outliers):
- Staple groceries must fall inside R8.00 and R600.00 unless the item is
  clearly a meat slab or bulk pack >5 kg.
- Never return a price under R2.00 for a recognisable item — treat that as
  an OCR / parsing artefact and use the closest baseline above instead.
- If the input string looks like an OCR fragment ("itm", "tmt", "...3g"),
  return 0 and skip it from grand_total.

Return STRICTLY a valid JSON object matching this exact structure:
{
  "items": [
    { "original_name": "6 pack milk", "avg_price": 102.00 },
    { "original_name": "White Bread", "avg_price": 18.50 }
  ],
  "grand_total": 120.50
}

Rules:
- Do not include any markdown code blocks (like ```json) or conversational text
  in your response. Return raw JSON text only.
- The "original_name" value MUST be copied character-for-character from the
  input list so the caller can match the row by name.
- All prices are in ZAR. Use two decimal places.
- If an item is completely unrecognizable, unpriced, or highly custom
  (e.g. "keys", "plastic bag"), return 0 for its "avg_price" and OMIT it
  from the "grand_total" computation.
- "grand_total" MUST equal the arithmetic sum of every "avg_price" that is
  greater than 0.
''';

  /// Estimates prices for [items].
  ///
  /// Returns null when the API key is missing AND we couldn't compute a
  /// reasonable fallback — the UI should treat null as "feature
  /// unavailable" rather than crash.
  Future<PriceEstimateResult> estimate(List<String> items) async {
    final cleaned = items
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    if (cleaned.isEmpty) {
      return const PriceEstimateResult(byOriginalName: {}, grandTotal: 0);
    }

    // ── Cache lookup (WS1) ───────────────────────────────────────────
    // Hit Supabase `price_cache` for every requested item; anything we
    // already know skips both the AI round-trip and the local engine.
    final normalizedByOriginal = <String, String>{
      for (final o in cleaned) o: _normalize(o),
    };
    final cacheHits = await _readCache(normalizedByOriginal.values);

    final byOriginal = <String, double>{};
    final misses    = <String>[];
    for (final o in cleaned) {
      final n = normalizedByOriginal[o]!;
      final hit = cacheHits[n];
      if (hit != null && hit > 0) {
        byOriginal[o] = hit;
      } else {
        misses.add(o);
      }
    }

    // Everything was cached — short-circuit, zero AI calls.
    if (misses.isEmpty) {
      final total = byOriginal.values.fold<double>(0, (a, b) => a + b);
      return PriceEstimateResult(byOriginalName: byOriginal, grandTotal: total);
    }

    // ── Mock mode ────────────────────────────────────────────────────
    // No key configured — return synthetic estimates so dev builds and
    // UI screenshots can demo the full layout. Prices roughly track
    // SA shelf averages so the screen doesn't look ridiculous.
    if (_kPriceEstApiKey.isEmpty) {
      final mock = _mockEstimate(misses);
      final merged = <String, double>{...byOriginal, ...mock.byOriginalName};
      unawaited(_writeCache({
        for (final e in mock.byOriginalName.entries)
          if (e.value > 0) normalizedByOriginal[e.key]!: e.value,
      }, 'baseline'));
      final total = merged.values.where((v) => v > 0).fold<double>(0, (a, b) => a + b);
      return PriceEstimateResult(byOriginalName: merged, grandTotal: total);
    }

    final prompt =
        'Estimate ZAR prices for these grocery list items as plain JSON. '
        'Copy each "original_name" exactly as written below:\n\n'
        '${jsonEncode(misses)}';

    late final GenerateContentResponse response;
    try {
      response = await _model.generateContent([Content.text(prompt)]);
    } on GenerativeAIException catch (e) {
      throw PriceEstimateException(e.message);
    } catch (e) {
      throw PriceEstimateException(e.toString());
    }

    final text = response.text?.trim();
    if (text == null || text.isEmpty) {
      throw const PriceEstimateException('Empty AI response.');
    }
    final parsed = _parse(text, misses);

    // Persist AI/local results for the misses to the shared cache, then
    // merge with the cache-hit slice so the caller sees one combined map.
    unawaited(_writeCache({
      for (final e in parsed.byOriginalName.entries)
        if (e.value > 0) normalizedByOriginal[e.key]!: e.value,
    }, 'ai'));

    final merged = <String, double>{...byOriginal, ...parsed.byOriginalName};
    final total = merged.values.where((v) => v > 0).fold<double>(0, (a, b) => a + b);
    return PriceEstimateResult(byOriginalName: merged, grandTotal: total);
  }

  // ── Parsing ────────────────────────────────────────────────────────

  PriceEstimateResult _parse(String raw, List<String> originals) {
    // Strip the rare ```json fence the model occasionally insists on,
    // defensive over the responseMimeType: 'application/json' config.
    final unfenced = _stripFence(raw);

    Map<String, dynamic> data;
    try {
      data = jsonDecode(unfenced) as Map<String, dynamic>;
    } catch (e) {
      throw PriceEstimateException('Bad JSON: $e');
    }

    final by = <String, double>{};
    final itemsJson = (data['items'] as List<dynamic>?) ?? const [];
    for (final entry in itemsJson) {
      if (entry is! Map<String, dynamic>) continue;
      final name = entry['original_name'] as String?;
      final raw  = (entry['avg_price'] as num?)?.toDouble();
      if (name == null || raw == null) continue;
      // Tier-3 sanity clamp: a recognisable item that came back as a
      // suspiciously tiny or astronomical value is almost certainly a
      // model hallucination or an OCR artefact. Snap it to the local
      // baseline so the user never sees a "6-pack milk = R7.50" row.
      // _sanityClamp ALSO replaces a 0 (model said "couldn't price")
      // with the local-engine estimate — no more orphan rows in the UI.
      by[name] = _sanityClamp(name, raw);
    }

    // Fallback for rows the model dropped entirely OR returned zero
    // for. Run them through the local engine so every row in the UI
    // carries a real number and rolls into the basket total — no more
    // orphan "— (no SA shelf match)" rows.
    for (final o in originals) {
      final existing = by[o] ?? 0;
      if (existing <= 0) {
        by[o] = _localEstimate(o);
      }
    }

    // Recompute the grand total against the (possibly augmented) row
    // values so the basket card matches the visible per-row sum.
    final finalSum = by.values.where((v) => v > 0).fold<double>(0, (a, b) => a + b);
    return PriceEstimateResult(byOriginalName: by, grandTotal: finalSum);
  }

  String _stripFence(String s) {
    final t = s.trim();
    final m = RegExp(r'^```(?:json)?\s*([\s\S]*?)\s*```$').firstMatch(t);
    return m != null ? m.group(1)! : t;
  }

  // ── Mock fallback (no API key) ─────────────────────────────────────

  PriceEstimateResult _mockEstimate(List<String> items) {
    // Tier-3 / fallback engine: looked up locally when no API key is
    // configured. Mirrors the system-prompt baselines so the UI shows
    // the same numbers whether Gemini answered or we fell back.
    final by = <String, double>{};
    var total = 0.0;
    for (final raw in items) {
      final price = _sanityClamp(raw, _localEstimate(raw));
      by[raw] = price;
      if (price > 0) total += price;
    }
    debugPrint('PriceEstimateService: returning local-engine estimates.');
    return PriceEstimateResult(byOriginalName: by, grandTotal: total);
  }

  // ── Local pricing engine (Tier 2 + Tier 3) ─────────────────────────────
  //
  // Single source of truth for the offline / API-keyless path AND for
  // the post-parse sanity clamp on the Gemini response. SA shelf
  // averages — keep these aligned with the system-prompt baselines.

  // Map iteration order matters — longer / more specific keys MUST sit
  // above their shorter parents so "tomato sauce" wins before "tomato",
  // "cup a soup" wins before "soup", etc.
  static const Map<String, double> _baselines = {
    // ── Specific multi-word matches (must precede single-word keys) ──
    'tomato sauce':  32.99,   // 700ml SA ketchup baseline
    'cup a soup':    25.50,
    'long life milk':19.50,
    'uht milk':      19.50,
    'baking powder': 18.00,
    'caster sugar':  35.00,
    'cake flour':    40.00,
    'icing sugar':   45.00,
    'olive oil':     130.00,
    'sunflower oil': 55.00,
    'peanut butter': 65.00,
    'corned beef':   55.00,
    'baked beans':   24.00,
    'maize meal':    50.00,
    'mealie meal':   50.00,

    // ── Single-word staples ─────────────────────────────────────────
    'milk':       19.50,   // 1L UHT
    'bread':      18.50,
    'eggs':       45.00,   // dozen
    'butter':     65.00,
    'cheese':     95.00,
    'yoghurt':    35.00,
    'cream':      45.00,
    'chicken':    75.00,
    'beef':       150.00,
    'mince':      85.00,
    'lamb':       220.00,
    'wors':       120.00,
    'boerewors':  120.00,
    'fish':       95.00,
    'hake':       120.00,
    'tuna':       30.00,
    'pap':        50.00,
    'mealie':     50.00,
    'rice':       45.00,
    'spaghetti':  18.99,
    'pasta':      18.99,
    'noodles':    20.00,
    'tomato':     25.00,
    'tomatoes':   25.00,
    'onion':      24.50,
    'onions':     24.50,
    'garlic':     19.99,
    'ginger':     18.50,
    'potato':     30.00,
    'potatoes':   30.00,
    'carrot':     20.00,
    'carrots':    20.00,
    'spinach':    20.00,
    'cabbage':    25.00,
    'lettuce':    18.00,
    'cucumber':   18.00,
    'pepper':     20.00,
    'apple':      35.00,
    'banana':     24.00,
    'orange':     30.00,
    'lemon':      18.00,
    'avocado':    25.00,
    'oil':        55.00,
    'sugar':      35.00,
    'flour':      40.00,
    'maizena':    28.00,
    'salt':       15.00,
    'rooibos':    45.00,
    'coffee':     75.00,
    'tea':        55.00,
    'chips':      22.00,
    'crisps':     22.00,
    'soup':       25.50,
    'soap':       25.00,
    'toothpaste': 35.00,
    'jam':        38.00,
    'honey':      55.00,
    'cereal':     65.00,
    'oats':       45.00,
    'biscuit':    25.00,
    'chocolate':  40.00,
    'sauce':      32.99,
    'ketchup':    32.99,
    'mayonnaise': 55.00,
    'mayo':       55.00,
    'mustard':    35.00,
    'vinegar':    25.00,
    'aromat':     35.00,
    'stock':      28.00,
    'cube':       28.00,
  };

  /// Sensible min/max for staple groceries. Anything outside the band is
  /// almost certainly a model glitch or OCR misread — we clamp it back
  /// to the closest baseline so the user never sees R7.50 for milk or
  /// R750 for a loaf of bread.
  static const double _kMinReasonable = 8.0;
  static const double _kMaxReasonable = 600.0;

  /// Pulls a base unit price from the keyword table.
  ///
  /// Prefers the Supabase-backed remote baselines (loaded once by [init])
  /// so prices can be re-tuned without an APK release. Falls through to
  /// the hardcoded [_baselines] map when remote is unavailable — the
  /// offline-resilience contract.
  double _baselineFor(String raw) {
    final lower = raw.toLowerCase();
    final remote = _remoteBaselines;
    if (remote != null) {
      for (final entry in remote) {
        if (lower.contains(entry.key)) return entry.value;
      }
    }
    for (final entry in _baselines.entries) {
      if (lower.contains(entry.key)) return entry.value;
    }
    return 25.0; // generic shelf-fallback
  }

  /// Detects "6 pack", "12 x", "twin pack", etc., returns (count, factor).
  /// `count` is 1 when no pack-size is detected so callers can multiply
  /// blindly. `factor` is the bulk discount applied per unit.
  (int, double) _packMultiplier(String raw) {
    final lower = raw.toLowerCase();
    final twelve = RegExp(r'\b(?:12\s*[x×*]|12\s*pack|dozen)\b').hasMatch(lower);
    if (twelve) return (12, 0.92);
    final six = RegExp(r'\b(?:6\s*[x×*]|6\s*pack|six\s*pack)\b').hasMatch(lower);
    if (six) return (6, 0.95);
    final two = RegExp(r'\b(?:2\s*[x×*]|2\s*pack|twin\s*pack|two\s*pack)\b')
        .hasMatch(lower);
    if (two) return (2, 0.97);
    return (1, 1.0);
  }

  /// Full local pricing pass — keyword baseline × pack multiplier.
  double _localEstimate(String raw) {
    final base       = _baselineFor(raw);
    final (n, factor) = _packMultiplier(raw);
    return base * n * factor;
  }

  /// Wraps an externally-supplied estimate (Gemini) in a guard rail so
  /// suspect values get snapped back to the local baseline. Recognised
  /// items NEVER come back below `_kMinReasonable`; nothing comes back
  /// above `_kMaxReasonable` unless the local engine itself agrees.
  double _sanityClamp(String name, double provided) {
    final local = _localEstimate(name);
    // Model said "couldn't price" — fall through to the local-engine
    // estimate (which itself falls through to the R25 generic baseline
    // if nothing matched). The UI never shows an orphan row again.
    if (provided <= 0) return local;
    // Tight asymmetric bounds: allow the model up to ~2× the local
    // baseline either side, beyond that snap to local.
    final low  = (local * 0.5).clamp(_kMinReasonable, _kMaxReasonable);
    final high = (local * 2.0).clamp(_kMinReasonable, _kMaxReasonable);
    if (provided < low)  return local;
    if (provided > high) return local;
    return provided;
  }
}
