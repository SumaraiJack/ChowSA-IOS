// lib/state/vegan_mode.dart
//
// Global vegan-mode flag. When on, recipe scrapes (link / image / raw
// text) and pantry-AI generation both ask the model for vegan
// alternatives instead of the original meat / dairy / egg shape.
//
// The flag is a process-wide ValueNotifier so every widget that needs
// to read or display the state can bind to it directly via
// ValueListenableBuilder. Persistence is best-effort: a failed write
// just means the toggle resets to false on the next cold start.

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _kVeganPrefKey = 'chowsa_vegan_mode';

class VeganMode {
  VeganMode._();

  /// Bind UI to this. Defaults to false until [load] hydrates from disk.
  static final ValueNotifier<bool> enabled = ValueNotifier<bool>(false);

  /// Restore the persisted value. Call once from main() after
  /// SharedPreferences is available so the first paint reflects the
  /// user's last choice.
  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      enabled.value = prefs.getBool(_kVeganPrefKey) ?? false;
    } catch (_) {
      // Best-effort.
    }
  }

  /// Flip and persist.
  static Future<void> set(bool value) async {
    enabled.value = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kVeganPrefKey, value);
    } catch (_) {
      // Best-effort.
    }
  }

  /// Inline-able instruction the scraper / pantry generator prepends to
  /// every Gemini prompt when [enabled.value] is true. Empty string when
  /// vegan mode is off so callers can concatenate unconditionally.
  static String get promptDirective => enabled.value
      ? '\n\nVEGAN MODE — STRICT. The user has switched on vegan mode. '
        'EVERY ingredient must be 100% plant-based. Replace any meat, '
        'fish, poultry, dairy, eggs, honey, or gelatine with a widely-'
        'available South African vegan alternative. Apply these specific '
        'swaps where applicable:\n'
        '  • Beef mince / minced meat → Fry\'s Soy Mince or Quorn Mince\n'
        '  • Chicken pieces → Fry\'s Chicken-Style Strips or marinated tofu\n'
        '  • Bacon → Fry\'s Streaky Style Bacon or rice-paper bacon\n'
        '  • Sausages / boerewors → Fry\'s Traditional Sausages\n'
        '  • Fish / tuna → marinated jackfruit or chickpea "tuna"\n'
        '  • Cow\'s milk / full-cream milk → oat milk (preferred for SA '
        '    baking), soy milk for savoury, almond milk for cereal\n'
        '  • Cream / heavy cream → oat cream or coconut cream (full-fat)\n'
        '  • Butter → Flora Plant butter or Stork Bake plant block\n'
        '  • Cheese → Nature\'s Source vegan cheese or cashew cheese\n'
        '  • Feta → Nature\'s Source feta-style block\n'
        '  • Yoghurt / amasi → coconut yoghurt or oat yoghurt\n'
        '  • Eggs (baking) → flax egg (1 tbsp flax + 3 tbsp water) or '
        '    aquafaba (3 tbsp = 1 egg)\n'
        '  • Eggs (savoury) → silken tofu scramble or chickpea-flour omelette\n'
        '  • Honey → maple syrup or agave nectar\n'
        '  • Gelatine → agar-agar (1 tsp agar = 8 sheets gelatine)\n'
        '  • Worcestershire sauce → vegan Worcestershire (check label)\n'
        'Adjust quantities, cooking times and method steps wherever the '
        'substitution changes the technique (e.g. soy mince browns in '
        'about half the time of beef mince — note this in the step). '
        'Keep the dish recognisable as the original. Prefix the title '
        'with "Vegan " when a substitution was made.\n'
      : '';
}
