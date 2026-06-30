// lib/utils/measurement_format.dart
//
// SA-friendly metric formatting for recipe ingredients.
//
// Recipes ingested from international sources arrive in imperial units
// (cups, teaspoons, tablespoons) — which baffles most South African
// home cooks who weigh dry goods in **grams** and measure liquids in
// **millilitres**. This util converts on the display layer only:
// stored ingredient data keeps its original unit so the scraper /
// community feed don't need re-training, and we render a clean metric
// label at the leaf widget.
//
// Conventions:
//   • 1 cup        = 250 ml  (SA metric standard, not the 240 ml US one)
//   • 1 tablespoon = 15 ml
//   • 1 teaspoon   = 5 ml
//   • Dry solids in cups → grams via [_drySolidDensity] when we
//     recognise the ingredient (flour, sugar, butter, oats, etc.).
//   • Anything we don't recognise → ml (always safe for a recipe).
//   • Already-metric inputs ("250 ml", "100 g") pass through unchanged.
//
// Public surface:
//   • [formatIngredientMeasure] — the qty+unit label shown to the user.
//   • [formatIngredientLine]    — full "qty unit name" string for
//     clipboard exports / share sheets / community posts.

import '../models/ingredient.dart';

/// Conversion factors → millilitres.
const _imperialToMl = <String, double>{
  'cup':           250,
  'cups':          250,
  'c':             250,
  'tablespoon':    15,
  'tablespoons':   15,
  'tbsp':          15,
  'tbs':           15,
  'tb':            15,
  'teaspoon':      5,
  'teaspoons':     5,
  'tsp':           5,
  'ts':            5,
};

/// Grams per single cup (250 ml) for common dry solids. Keys are
/// case-insensitive substrings matched against the ingredient name.
/// Order matters — earlier entries win when multiple match (e.g.
/// "brown sugar" hits "brown sugar" before "sugar"). Values come from
/// the King Arthur Flour and Joy of Cooking weight tables, rounded
/// for clean labels.
const _drySolidGramsPerCup = <String, int>{
  // Sugars
  'brown sugar':         220,
  'icing sugar':         125,
  'powdered sugar':      125,
  'caster sugar':        200,
  'castor sugar':        200,
  'granulated sugar':    200,
  'white sugar':         200,
  'sugar':               200,
  // Flours
  'cake flour':          120,
  'self raising flour':  125,
  'self-raising flour':  125,
  'bread flour':         130,
  'strong flour':        130,
  'wholewheat flour':    130,
  'whole wheat flour':   130,
  'whole-wheat flour':   130,
  'rye flour':           130,
  'almond flour':        100,
  'coconut flour':       115,
  'flour':               125,
  // Dairy & fats
  'butter':              230,
  'margarine':           230,
  'lard':                225,
  // Grains, starches, baking
  'oats':                90,
  'rolled oats':         90,
  'rice':                200,
  'breadcrumbs':         110,
  'cornflour':           120,
  'corn starch':         120,
  'cornstarch':          120,
  'cocoa':               100,
  'cacao':               100,
  'desiccated coconut':  80,
  'coconut':             80,
  'chocolate chips':     175,
  'choc chips':          175,
  'raisins':             145,
  'sultanas':            145,
  'currants':            145,
  'nuts':                120,
  'chopped nuts':        120,
  'almonds':             140,
  'pecans':              110,
  'walnuts':             110,
  'mealie meal':         140,
  'maize meal':          140,
  // Hard cheeses
  'parmesan':            100,
  'cheddar':             110,
  'cheese':              110,
};

/// Returns grams-per-cup if [name] looks like a dry solid we know;
/// null otherwise.
int? _gramsPerCupFor(String? name) {
  if (name == null || name.isEmpty) return null;
  final hay = name.toLowerCase();
  for (final entry in _drySolidGramsPerCup.entries) {
    if (hay.contains(entry.key)) return entry.value;
  }
  return null;
}

/// Rounds [ml] to a clean SA-kitchen number. Small amounts keep
/// 0.5/1 ml precision; medium amounts snap to 5/10 ml; large amounts
/// snap to 25 ml so a "1 cup" → "250 ml" not "247 ml".
double _roundMl(double ml) {
  if (ml < 5) return double.parse(ml.toStringAsFixed(1));
  if (ml < 50) {
    return (ml / 1).round().toDouble();
  }
  if (ml < 200) {
    return (ml / 5).round() * 5.0;
  }
  return (ml / 25).round() * 25.0;
}

/// Rounds [g] to a clean SA-kitchen number using the same snap-scale
/// as [_roundMl].
double _roundGrams(double g) {
  if (g < 10) return double.parse(g.toStringAsFixed(1));
  if (g < 100) {
    return (g / 5).round() * 5.0;
  }
  return (g / 25).round() * 25.0;
}

String _trimZero(double v) {
  if (v == v.roundToDouble()) return v.toInt().toString();
  // Don't end with a trailing zero like "2.50".
  final s = v.toStringAsFixed(2);
  return s.endsWith('0') ? s.substring(0, s.length - 1) : s;
}

/// Lower-cased, whitespace-trimmed unit string suitable for lookup.
String? _normaliseUnit(String? unit) =>
    unit?.toLowerCase().trim().replaceAll('.', '');

/// Returns true when [unit] is already a metric label (g, kg, ml, l)
/// and just needs a clean qty + unit rendering, not conversion.
bool _isAlreadyMetric(String? unit) {
  final u = _normaliseUnit(unit);
  if (u == null) return false;
  const metric = {'g', 'gram', 'grams', 'kg', 'ml', 'millilitre',
                  'millilitres', 'milliliter', 'milliliters', 'l',
                  'litre', 'litres', 'liter', 'liters'};
  return metric.contains(u);
}

/// Formats [ingredient]'s quantity + unit as an SA-friendly metric
/// label. Returns an empty string when there's nothing to display
/// (no quantity AND no unit).
///
/// Examples:
///   • `2 cups cake flour`           → `250 g`
///   • `0.5 tsp salt`                → `2.5 ml`
///   • `1.8 cups milk`               → `450 ml`
///   • `100 g butter`                → `100 g` (unchanged)
///   • `1 large egg` (no unit)       → ``    (caller renders just the name)
String formatIngredientMeasure(Ingredient ingredient) {
  final qty  = ingredient.quantity;
  final unit = ingredient.unit;

  // ── Already metric — keep the source label, just clean the qty.
  if (qty != null && _isAlreadyMetric(unit)) {
    return '${_trimZero(qty)} ${unit!.trim()}';
  }

  // ── Imperial volume → metric.
  final factor = _imperialToMl[_normaliseUnit(unit) ?? ''];
  if (factor != null && qty != null) {
    final ml = qty * factor;
    // Try grams if it's a recognised dry solid AND the original unit
    // was a cup-style volume (mass conversion makes no sense from a
    // teaspoon of nutmeg).
    final gPerCup = (_normaliseUnit(unit) ?? '').startsWith('cup')
        ? _gramsPerCupFor(ingredient.displayName)
        : null;
    if (gPerCup != null) {
      final grams = ml * gPerCup / 250.0;
      return '${_trimZero(_roundGrams(grams))} g';
    }
    return '${_trimZero(_roundMl(ml))} ml';
  }

  // ── Fallthrough — keep whatever we were given so we never silently
  // drop a measurement. Counts ("1 large egg") land here with unit
  // = "large" or unit = null; we render qty + unit as-is.
  //
  // Defensive dedupe: when the AI puts the same noun in both unit and
  // name (e.g. `unit:"bay leaves", name:"bay leaves"`) the recipe used
  // to render "2 bay leaves bay leaves". Drop the unit when it's a
  // case-insensitive prefix/suffix of the ingredient name.
  if (qty != null && unit != null && unit.isNotEmpty) {
    final u = unit.trim();
    final n = (ingredient.displayName).toLowerCase();
    if (n.contains(u.toLowerCase())) return _trimZero(qty);
    return '${_trimZero(qty)} $u';
  }
  if (qty != null) return _trimZero(qty);
  if (unit != null && unit.isNotEmpty) return unit.trim();
  return '';
}

/// Convenience: the full "qty unit name" line used for share sheets,
/// clipboard exports, and community posts.
String formatIngredientLine(Ingredient ingredient) {
  final measure = formatIngredientMeasure(ingredient);
  final name    = ingredient.displayName;
  if (measure.isEmpty) return name;
  return '$measure $name';
}
