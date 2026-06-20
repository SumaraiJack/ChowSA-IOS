// lib/utils/south_african_product_matcher.dart
//
// Lightweight brand-aware classifier for Mzansi grocery products.
//
// Why this exists: the generic `categoriseIngredient()` keyword engine treats
// every ingredient like a culinary noun ("chicken", "rice", "milk"). South
// African shoppers don't think that way — they think "Iwisa" (maize meal),
// "Lucky Star" (pilchards), "Mrs Ball's" (chutney), "Aromat" (seasoning),
// "Oros" (cordial). This matcher recognises those brand tokens first and
// routes them to the correct GroceryCategory before generic keywords get a
// chance to mis-classify them.
//
// Returns `null` when nothing matches — callers should fall through to their
// own categorisation logic.

import '../models/shopping_list.dart';

class SouthAfricanProductMatcher {
  SouthAfricanProductMatcher._(); // utility class — never instantiated

  // ── Brand → category lookup ─────────────────────────────────────────────────
  //
  // Each key is a lowercase brand-token or product-phrase. Multiple keys may
  // map to the same category (e.g. several maize-meal brands → pantry).
  // Order in this map does not matter — the matcher picks the FIRST key whose
  // lowercased form appears in the input string.

  static const Map<String, GroceryCategory> _brandMap = {
    // ── Pantry Staples ────────────────────────────────────────────────────
    // Maize meal / pap
    'white star':       GroceryCategory.pantry,
    'iwisa':            GroceryCategory.pantry,
    'ace ':             GroceryCategory.pantry,   // trailing space avoids "place" / "trace"
    'ace super':        GroceryCategory.pantry,
    'ace maize':        GroceryCategory.pantry,
    'nyala':            GroceryCategory.pantry,
    'impala maize':     GroceryCategory.pantry,
    'tafelberg':        GroceryCategory.pantry,
    'pap':              GroceryCategory.pantry,
    'mealie meal':      GroceryCategory.pantry,
    'mealiemeel':       GroceryCategory.pantry,
    'maize meal':       GroceryCategory.pantry,
    'krummelpap':       GroceryCategory.pantry,
    'stywe pap':        GroceryCategory.pantry,
    // Rice / grains
    'tastic':           GroceryCategory.pantry,
    'spekko':            GroceryCategory.pantry,
    'samp':             GroceryCategory.pantry,
    'umngqusho':        GroceryCategory.pantry,
    // Flour / baking
    'snowflake':        GroceryCategory.pantry,
    'sasko':            GroceryCategory.pantry,
    'royal baking':     GroceryCategory.pantry,
    'maizena':          GroceryCategory.pantry,
    // Canned veg / beans — Koo
    'koo':              GroceryCategory.pantry,
    "koo's":            GroceryCategory.pantry,
    'koo baked':        GroceryCategory.pantry,
    'koo chakalaka':    GroceryCategory.pantry,
    // Stock / soup
    'knorrox':          GroceryCategory.pantry,
    'knorr':            GroceryCategory.pantry,
    'royco':            GroceryCategory.pantry,
    'imana':            GroceryCategory.pantry,

    // ── Tinned Fish / Butcher ─────────────────────────────────────────────
    'lucky star':       GroceryCategory.butcher,
    'saldanha':         GroceryCategory.butcher,
    'glenryck':         GroceryCategory.butcher,
    'john west':        GroceryCategory.butcher,
    'pilchards':        GroceryCategory.butcher,
    'sardines':         GroceryCategory.butcher,
    'biltong':          GroceryCategory.butcher,
    'droëwors':         GroceryCategory.butcher,
    'drywors':          GroceryCategory.butcher,
    'boerewors':        GroceryCategory.butcher,
    'enterprise':       GroceryCategory.butcher,  // SA processed-meat brand
    'eskort':           GroceryCategory.butcher,  // bacon / sausages

    // ── Condiments & Sauces ──────────────────────────────────────────────
    "mrs ball":         GroceryCategory.condimentsAndSauces,
    "mrs balls":        GroceryCategory.condimentsAndSauces,
    "mrs ball's":       GroceryCategory.condimentsAndSauces,
    "ball's chutney":   GroceryCategory.condimentsAndSauces,
    "balls chutney":    GroceryCategory.condimentsAndSauces,
    'chutney':          GroceryCategory.condimentsAndSauces,
    'all gold':         GroceryCategory.condimentsAndSauces,
    'crosse & blackwell': GroceryCategory.condimentsAndSauces,
    'crosse and blackwell': GroceryCategory.condimentsAndSauces,
    'nandos':           GroceryCategory.condimentsAndSauces,
    "nando's":          GroceryCategory.condimentsAndSauces,
    'nandos peri':      GroceryCategory.condimentsAndSauces,
    'wellingtons':      GroceryCategory.condimentsAndSauces,
    'steers sauce':     GroceryCategory.condimentsAndSauces,
    'mama africa':      GroceryCategory.condimentsAndSauces,
    'spur sauce':       GroceryCategory.condimentsAndSauces,
    'black cat':        GroceryCategory.condimentsAndSauces,  // peanut butter
    'yum yum':          GroceryCategory.condimentsAndSauces,  // peanut butter

    // ── Spices & Herbs ───────────────────────────────────────────────────
    'aromat':           GroceryCategory.spicesAndHerbs,
    'rajah':            GroceryCategory.spicesAndHerbs,
    'robertsons':       GroceryCategory.spicesAndHerbs,
    "robertson's":      GroceryCategory.spicesAndHerbs,
    'ina paarman':      GroceryCategory.spicesAndHerbs,
    'cape herb':        GroceryCategory.spicesAndHerbs,
    'cape herb & spice': GroceryCategory.spicesAndHerbs,
    'masterspice':      GroceryCategory.spicesAndHerbs,
    'paprika':          GroceryCategory.spicesAndHerbs,
    'masala':           GroceryCategory.spicesAndHerbs,
    'garam masala':     GroceryCategory.spicesAndHerbs,
    'braai salt':       GroceryCategory.spicesAndHerbs,
    'braai spice':      GroceryCategory.spicesAndHerbs,
    'chicken spice':    GroceryCategory.spicesAndHerbs,
    'fish & chips spice': GroceryCategory.spicesAndHerbs,
    'peri-peri':        GroceryCategory.spicesAndHerbs,
    'peri peri':        GroceryCategory.spicesAndHerbs,

    // ── Beverages ────────────────────────────────────────────────────────
    'rooibos':          GroceryCategory.beverages,
    'freshpak':         GroceryCategory.beverages,
    'five roses':       GroceryCategory.beverages,
    '5 roses':          GroceryCategory.beverages,
    'joko':             GroceryCategory.beverages,
    'glen':             GroceryCategory.beverages,  // Glen tea
    'twinings':         GroceryCategory.beverages,
    'oros':             GroceryCategory.beverages,
    'halls':            GroceryCategory.beverages,  // SA cordial brand
    'caro':             GroceryCategory.beverages,  // Caro coffee substitute
    'ricoffy':          GroceryCategory.beverages,
    'frisco':           GroceryCategory.beverages,
    'jacobs coffee':    GroceryCategory.beverages,
    'milo':             GroceryCategory.beverages,
    'horlicks':         GroceryCategory.beverages,
    'ovaltine':         GroceryCategory.beverages,
    'liqui-fruit':      GroceryCategory.beverages,
    'liqui fruit':      GroceryCategory.beverages,
    'ceres':            GroceryCategory.beverages,  // Ceres juice
    'fanta':            GroceryCategory.beverages,
    'stoney':           GroceryCategory.beverages,
    'castle':           GroceryCategory.beverages,
    'savanna':          GroceryCategory.beverages,
    'amarula':          GroceryCategory.beverages,

    // ── Dairy ────────────────────────────────────────────────────────────
    'clover':           GroceryCategory.dairy,
    'parmalat':         GroceryCategory.dairy,
    'fairfield':        GroceryCategory.dairy,
    'douglasdale':      GroceryCategory.dairy,
    'danone':           GroceryCategory.dairy,
    'simonsberg':       GroceryCategory.dairy,
    'amasi':            GroceryCategory.dairy,
    'maas':             GroceryCategory.dairy,
    'inkomazi':         GroceryCategory.dairy,

    // ── Bakery ───────────────────────────────────────────────────────────
    'albany':           GroceryCategory.bakery,
    'sasko bread':      GroceryCategory.bakery,
    'blue ribbon':      GroceryCategory.bakery,
    'baker street':     GroceryCategory.bakery,

    // ── Frozen ───────────────────────────────────────────────────────────
    'mccain':           GroceryCategory.frozen,
    'mccains':          GroceryCategory.frozen,
    "mccain's":         GroceryCategory.frozen,
    'nestlé ice':       GroceryCategory.frozen,
    'magnum':           GroceryCategory.frozen,
    'rolo ice':         GroceryCategory.frozen,
    'country fair':     GroceryCategory.frozen, // frozen chicken — could go butcher
  };

  // ── Public API ──────────────────────────────────────────────────────────────

  /// Returns the matched grocery category for any input string containing a
  /// recognised South African brand or product token. Returns `null` when no
  /// brand is found — the caller should fall through to generic categorisation.
  ///
  /// Matching is case-insensitive substring containment. Specific multi-word
  /// brand phrases (e.g. "mrs ball's chutney") win over their generic shorter
  /// counterparts because Dart's Map iteration is insertion-ordered and the
  /// first matching key is returned.
  static GroceryCategory? determineCategory(String input) {
    if (input.trim().isEmpty) return null;
    final n = input.toLowerCase();

    // Walk the brand map and return the first match. This is O(n) over the
    // brand list — fine for a hundred-ish entries on every Add Item tap.
    for (final entry in _brandMap.entries) {
      if (n.contains(entry.key)) return entry.value;
    }
    return null;
  }

  /// Convenience getter for callers that need a display label string rather
  /// than the GroceryCategory enum value (e.g. for analytics or logging).
  static String? determineLabel(String input) =>
      determineCategory(input)?.displayName;
}
