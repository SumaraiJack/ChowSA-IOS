// lib/config/servings_pref.dart
//
// Shared SharedPreferences key + default for the user's preferred serving
// size. Centralised here so MainNavigationHub (settings owner) and
// PantryService (Gemini prompt builder) never drift on the key name.

import 'package:shared_preferences/shared_preferences.dart';

/// SharedPreferences key holding the user's preferred serving size as an int.
const String kServingsPrefKey = 'default_servings_v1';

/// Fallback when the user has never opened settings.
/// Matches the spec's "default to 2 if not set" instruction.
const int kServingsDefault = 2;

/// Convenience reader — returns the persisted serving size or the default.
/// Safe to call from any layer (services, screens, background work).
Future<int> readDefaultServings() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getInt(kServingsPrefKey) ?? kServingsDefault;
}

/// Convenience writer — persists the value. Use from settings change handlers.
Future<void> writeDefaultServings(int value) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setInt(kServingsPrefKey, value);
}
