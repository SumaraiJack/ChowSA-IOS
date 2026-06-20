// lib/state/chat_bubble_theme.dart
//
// PR 6: curated chat-bubble palette + persisted user preference.
//
// Five presets. Each carries an `own` colour (right-aligned, user's own
// messages) and an `other` colour (left-aligned, everyone else). Colours
// are tuned against the forest-green app shell so every pair stays on
// brand — no full colour picker by design.
//
// Persistence: SharedPreferences key 'chat_bubble_theme_v1' stores the
// selected preset id. Default is 'forest_mzansi'.

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

@immutable
class ChatBubbleTheme {
  const ChatBubbleTheme({
    required this.id,
    required this.label,
    required this.own,
    required this.other,
  });

  /// Stable id persisted to SharedPreferences. Never rename.
  final String id;
  /// Human-readable label for the picker.
  final String label;
  /// Fill colour for the user's own (right-aligned) bubbles.
  final Color  own;
  /// Fill colour for everyone else's (left-aligned) bubbles.
  final Color  other;
}

/// Curated preset palette. Order here = order in the picker.
const List<ChatBubbleTheme> kChatBubbleThemes = [
  ChatBubbleTheme(
    id:    'forest_mzansi',
    label: 'Forest Mzansi',
    own:   Color(0xFFE7F0E9),
    other: Color(0xFFF4F1EA),
  ),
  ChatBubbleTheme(
    id:    'warm_sand',
    label: 'Warm Sand',
    own:   Color(0xFFFFE9C7),
    other: Color(0xFFF4F1EA),
  ),
  ChatBubbleTheme(
    id:    'midnight_dusk',
    label: 'Midnight Dusk',
    own:   Color(0xFFD9E0E8),
    other: Color(0xFFEDEDED),
  ),
  ChatBubbleTheme(
    id:    'protea_gold',
    label: 'Protea Gold',
    own:   Color(0xFFFDE2A4),
    other: Color(0xFFFFFBF1),
  ),
  ChatBubbleTheme(
    id:    'classic_chat',
    label: 'Classic Green',
    own:   Color(0xFFDCF8C6),
    other: Color(0xFFFFFFFF),
  ),
];

const String _kDefaultId = 'forest_mzansi';
const String _kPrefKey   = 'chat_bubble_theme_v1';

/// Process-wide controller. Notifier-based so every bubble can listen and
/// recolour the instant the user taps a new preset — no rebuild dance.
class ChatBubbleThemeController {
  ChatBubbleThemeController._();
  static final ChatBubbleThemeController instance =
      ChatBubbleThemeController._();

  /// Selected preset id. Always corresponds to a real entry in
  /// [kChatBubbleThemes] — the load path coerces unknown ids back to the
  /// default.
  final ValueNotifier<String> selectedId =
      ValueNotifier<String>(_kDefaultId);

  bool _loaded = false;

  /// Hydrates [selectedId] from SharedPreferences. Safe to call multiple
  /// times — only the first call hits disk.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kPrefKey);
    if (raw != null && _isKnownId(raw)) {
      selectedId.value = raw;
    }
  }

  Future<void> setSelected(String id) async {
    if (!_isKnownId(id)) return;
    selectedId.value = id;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPrefKey, id);
  }

  ChatBubbleTheme get current => themeForId(selectedId.value);

  static ChatBubbleTheme themeForId(String id) {
    for (final t in kChatBubbleThemes) {
      if (t.id == id) return t;
    }
    return kChatBubbleThemes.first;
  }

  static bool _isKnownId(String id) =>
      kChatBubbleThemes.any((t) => t.id == id);
}
