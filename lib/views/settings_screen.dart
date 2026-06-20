// lib/views/settings_screen.dart

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../main.dart' show chowFontNotifier;
import '../services/smart_suggestions_service.dart';
import '../theme/app_theme.dart';
import '../state/chat_bubble_theme.dart';
import 'privacy_settings_screen.dart';

// =============================================================================
// ChowSA App Theme — Mzansi Organic Luxury (the only theme)
//
// Every legacy palette (braaiNight, capeTown, joziFire, soweto, roseGold,
// frangipani, winelands, springbok, bafana, proteas, mzansiFire,
// obsidianCopper, obsidianEmbers, karooCanvas) has been deleted. There is
// now ONE cohesive theme defined in lib/theme/app_theme.dart — see the
// "Mzansi Organic Luxury" doc-comment there for the full palette rationale.
//
// The ChowTheme enum still exists with a single value so the existing
// MaterialApp + Settings plumbing keeps working without invasive surgery.
// The Settings UI no longer shows a theme picker — there's nothing to pick.
// =============================================================================

// Three switchable themes per the v3.0 design overhaul. Token sets and
// ThemeData live in lib/theme/app_theme.dart — this enum is just the
// picker spine that the SettingsScreen and MaterialApp consume.

enum ChowTheme {
  /// Default — modern green-anchored grocery-aisle premium.
  fresh,
  /// Hidden Easter-egg theme — only surfaced when the signed-in handle
  /// matches the gate in SettingsScreen. See [kBlushGateHandle].
  blush;

  /// The single allowed handle for the Protea Blush Easter egg.
  /// Case-insensitive match — see SettingsScreen build().
  static const String kBlushGateHandle = 'Melrose';

  /// Back-compat alias — older code paths and SharedPreferences values
  /// still resolve to the current Fresh default cleanly.
  static ChowTheme get mzansiOrganicLuxury => ChowTheme.fresh;

  String get displayName => switch (this) {
    ChowTheme.fresh    => 'Chow SA Fresh',
    ChowTheme.blush    => 'Protea Blush',
  };

  String get description => switch (this) {
    ChowTheme.fresh    => 'Forest green · cream canvas · amber accent',
    ChowTheme.blush    => 'Rosy blush · coral accents · berry-wine elegance',
  };

  /// Primary-anchor swatch for picker preview tiles.
  Color get primaryColor => switch (this) {
    ChowTheme.fresh    => ChowFreshTokens.forest,
    ChowTheme.blush    => ChowBlushTokens.berry,
  };

  /// Accent swatch for picker preview tiles.
  Color get accentColor => switch (this) {
    ChowTheme.fresh    => ChowFreshTokens.amber,
    ChowTheme.blush    => ChowBlushTokens.coral,
  };

  /// Canvas swatch for picker preview tiles.
  Color get canvasColor => switch (this) {
    ChowTheme.fresh    => ChowFreshTokens.cream,
    ChowTheme.blush    => ChowBlushTokens.blush,
  };

  /// Card / surface swatch for picker preview tiles.
  Color get surfaceColor => switch (this) {
    ChowTheme.fresh    => ChowFreshTokens.chalk,
    ChowTheme.blush    => ChowBlushTokens.chalk,
  };

  /// The (light) ThemeData for this palette. v4.2 removed every dark
  /// variant from the codebase — `lightTheme` and `darkTheme` now return
  /// the same instance so any leftover caller using either accessor still
  /// renders the daylight palette.
  ThemeData get lightTheme => switch (this) {
    ChowTheme.fresh    => AppTheme.freshLight,
    ChowTheme.blush    => AppTheme.blushLight,
  };

  ThemeData get darkTheme => lightTheme;

  /// Stable string for SharedPreferences persistence.
  String get persistKey => name;

  /// Inverse of [persistKey] — defaults to fresh on any unknown value,
  /// which also catches the now-removed `'classic'` (Savanna Dusk) and
  /// `'heritage'` (Karoo Twilight) persisted values so returning users
  /// land on a valid light palette.
  static ChowTheme fromPersistKey(String? key) {
    if (key == null) return ChowTheme.fresh;
    return ChowTheme.values.firstWhere(
      (t) => t.name == key,
      orElse: () => ChowTheme.fresh,
    );
  }
}


// =============================================================================
// Design tokens
// =============================================================================

const _kForest = Color(0xFF0C351E);
const _kOrange = Color(0xFFE59B27);
const _kCream  = Color(0xFFF4F1EA);

// =============================================================================
// SettingsScreen
// =============================================================================

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.isMetric,
    required this.defaultServings,
    required this.onMetricChanged,
    required this.onServingsChanged,
    this.chowTheme,
    this.onChowThemeChanged,
    this.onFontChanged,
    this.onAccountDeleted,
    this.currentUserHandle,
  });

  // v4.2: the Brightness/Dark Mode picker was removed — every ChowTheme is
  // intrinsically light — so themeMode plumbing was also dropped from this
  // screen. main.dart locks MaterialApp.themeMode to ThemeMode.light.
  final bool      isMetric;
  final int       defaultServings;

  final void Function(bool)      onMetricChanged;
  final void Function(int)       onServingsChanged;

  final ChowTheme?                   chowTheme;
  final void Function(ChowTheme)?    onChowThemeChanged;
  final void Function(String)?       onFontChanged;

  /// Fired after the POPIA delete_my_account RPC succeeds. The hub uses this
  /// to tear down the auth session and return the user to AuthScreen — see
  /// MainNavigationHub._onSignOut for the matching teardown.
  final Future<void> Function()?     onAccountDeleted;

  /// Signed-in user's @handle. Used by the theme picker to gate the
  /// hidden Protea Blush Easter egg — only surfaces when this matches
  /// [ChowTheme.kBlushGateHandle] (case-insensitive). Null for cold-start
  /// flows or test harnesses; the picker simply hides the theme in that case.
  final String?                      currentUserHandle;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late bool       _isMetric;
  late int        _servings;
  late ChowTheme  _chowTheme;
  String          _selectedFont = 'Default';

  static const _fontPrefKey = 'chowsa_selected_font';

  // ── Font catalogue ─────────────────────────────────────────────────────────
  // Girly: Pacifico, Dancing Script, Playfair Display, Satisfy, Courgette
  // Masculine: Oswald, Bebas Neue, Roboto Condensed, Anton, Barlow Condensed
  static const _fonts = [
    ('Default',            '🍴  Default',           false),
    ('Pacifico',           '🌸  Pacifico',           true),   // girly — rounded & playful
    ('Dancing Script',     '💃  Dancing Script',     true),   // girly — flowing cursive
    ('Playfair Display',   '🌺  Playfair Display',   true),   // girly — elegant serif
    ('Satisfy',            '🌷  Satisfy',            true),   // girly — handwritten
    ('Courgette',          '🦋  Courgette',          true),   // girly — soft italic
    ('Oswald',             '🔥  Oswald',             false),  // masculine — bold condensed
    ('Bebas Neue',         '⚡  Bebas Neue',          false),  // masculine — all-caps bold
    ('Roboto Condensed',   '🛠️  Roboto Condensed',   false),  // masculine — clean & tight
    ('Anton',              '🏋️  Anton',              false),  // masculine — heavy impact
    ('Barlow Condensed',   '🚀  Barlow Condensed',   false),  // masculine — modern strong
  ];

  TextStyle _fontStyle(String fontName, {double? fontSize, FontWeight? fontWeight}) {
    if (fontName == 'Default') {
      return TextStyle(fontSize: fontSize, fontWeight: fontWeight);
    }
    try {
      return GoogleFonts.getFont(
        fontName,
        fontSize: fontSize,
        fontWeight: fontWeight,
      );
    } catch (_) {
      return TextStyle(fontSize: fontSize, fontWeight: fontWeight);
    }
  }

  Future<void> _loadFont() async {
    // Read from the global notifier first (instant, no async needed)
    final current = chowFontNotifier.value;
    if (mounted && current.isNotEmpty) {
      setState(() => _selectedFont = current);
    }
    // Also verify against SharedPreferences (source of truth on cold start)
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_fontPrefKey);
    if (saved != null && mounted && saved != _selectedFont) {
      setState(() => _selectedFont = saved);
    }
  }

  Future<void> _saveFont(String fontName) async {
    // Update local state for the chip highlight in this screen
    setState(() => _selectedFont = fontName);
    // Update the global notifier — this instantly rebuilds every
    // ValueListenableBuilder in the tree, including MaterialApp.builder,
    // so the font change is visible RIGHT NOW without exiting settings.
    chowFontNotifier.value = fontName;
    // Also fire the callback so ChowSAApp.setState rebuilds theme/darkTheme
    widget.onFontChanged?.call(fontName);
    // Persist the choice
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_fontPrefKey, fontName);
  }

  @override
  void initState() {
    super.initState();
    _isMetric  = widget.isMetric;
    _servings  = widget.defaultServings;
    _chowTheme = widget.chowTheme ?? ChowTheme.fresh;
    _loadFont();
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: _kCream,
      appBar: AppBar(
        backgroundColor:    _kCream,
        surfaceTintColor:   Colors.transparent,
        elevation:          0,
        leading: IconButton(
          icon:      const Icon(Icons.arrow_back_ios_new_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          'Settings',
          style: tt.titleLarge?.copyWith(
            fontWeight: FontWeight.w800,
            color:      _kForest,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: [

          // ── App Theme picker — Fresh / Heritage / Classic ───────────────────
          //
          // Three full-width preview tiles. Each shows a mini-palette (anchor
          // / canvas / surface / accent) + the theme's name and description.
          // Tapping a tile fires onChowThemeChanged which propagates up to
          // MaterialApp.theme via main.dart's setState — the whole app
          // cross-fades to the new look in ~400ms.
          _SectionLabel(label: 'App Theme'),
          _SettingsCard(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // ── Easter egg gate ────────────────────────────────
                    // Protea Blush is hidden unless the signed-in handle
                    // matches kBlushGateHandle exactly (case-insensitive).
                    // Everyone else sees the default 3-theme picker.
                    ...() {
                      final handle = widget.currentUserHandle?.trim() ?? '';
                      final unlocked = handle.toLowerCase() ==
                          ChowTheme.kBlushGateHandle.toLowerCase();
                      final visible = ChowTheme.values
                          .where((t) =>
                              t != ChowTheme.blush || unlocked)
                          .toList(growable: false);
                      return [
                        for (final theme in visible) ...[
                          _ThemePickerTile(
                            theme:    theme,
                            selected: _chowTheme == theme,
                            onTap: () {
                              setState(() => _chowTheme = theme);
                              widget.onChowThemeChanged?.call(theme);
                            },
                          ),
                          const SizedBox(height: 10),
                        ],
                      ];
                    }(),
                    const _ComingSoonThemeTile(),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),

          // ── Measurements ───────────────────────────────────────────────────
          _SectionLabel(label: 'Measurements'),
          // ── Chat Bubbles (PR 6) ───────────────────────────────────────────
          _SectionLabel(label: 'Chat Bubbles'),
          _SettingsCard(
            children: const [
              _ChatBubbleThemeRow(),
            ],
          ),

          const SizedBox(height: 16),

          _SettingsCard(
            children: [
              _SettingsRow(
                icon:     Icons.straighten_rounded,
                title:    'Units System',
                subtitle: _isMetric ? 'grams, ml, °C' : 'oz, lbs, °F',
                child: SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: true,  label: Text('Metric')),
                    ButtonSegment(value: false, label: Text('Imperial')),
                  ],
                  selected:           {_isMetric},
                  onSelectionChanged: (s) {
                    setState(() => _isMetric = s.first);
                    widget.onMetricChanged(s.first);
                  },
                  style: ButtonStyle(
                    shape: WidgetStatePropertyAll(
                      RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),

          // ── Cooking Preferences ────────────────────────────────────────────
          _SectionLabel(label: 'Cooking Preferences'),
          _SettingsCard(
            children: [
              _SettingsRow(
                icon:     Icons.people_outline_rounded,
                title:    'Default Serving Size',
                subtitle: 'Used by AI when generating recipes',
                child: _ServingCounter(
                  value:     _servings,
                  onChanged: (v) {
                    setState(() => _servings = v);
                    widget.onServingsChanged(v);
                  },
                ),
              ),
            ],
          ),

          const SizedBox(height: 24),

          // ── Text & Display ────────────────────────────────────────────────
          _SectionLabel(label: 'Text & Display'),
          _SettingsCard(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Row(
                  children: [
                    const Icon(Icons.text_fields_rounded, size: 20,
                        color: Color(0xFF0C351E)),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('App Font Style',
                            style: TextStyle(fontWeight: FontWeight.w700,
                                fontSize: 14)),
                          Text('Choose your vibe',
                            style: TextStyle(fontSize: 11, color: Color(0xFF55534E))),
                        ],
                      ),
                    ),
                    // Preview chip
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0C351E).withAlpha(12),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        _selectedFont == 'Default' ? 'Default' : _selectedFont,
                        style: _fontStyle(_selectedFont,
                            fontSize: 12, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              // ── Font grid ──────────────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Girly section
                    Padding(
                      padding: const EdgeInsets.only(left: 4, bottom: 6, top: 4),
                      child: Text('✨ Girly',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
                            color: const Color(0xFFD4748A))),
                    ),
                    Wrap(
                      spacing: 8, runSpacing: 8,
                      children: _fonts
                          .where((f) => f.$3 || f.$1 == 'Default')
                          .map((f) => _FontChip(
                            label:       f.$2,
                            fontName:    f.$1,
                            isSelected:  _selectedFont == f.$1,
                            onTap:       () => _saveFont(f.$1),
                          ))
                          .toList(),
                    ),
                    const SizedBox(height: 12),
                    // Masculine section
                    Padding(
                      padding: const EdgeInsets.only(left: 4, bottom: 6),
                      child: Text('💪 Bold',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
                            color: const Color(0xFF455A64))),
                    ),
                    Wrap(
                      spacing: 8, runSpacing: 8,
                      children: _fonts
                          .where((f) => !f.$3 && f.$1 != 'Default')
                          .map((f) => _FontChip(
                            label:       f.$2,
                            fontName:    f.$1,
                            isSelected:  _selectedFont == f.$1,
                            onTap:       () => _saveFont(f.$1),
                          ))
                          .toList(),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 24),

          // ── Privacy & Data Settings ────────────────────────────────────────
          // POPIA right-to-be-forgotten entry point. Pushes a sub-screen with
          // a data-handling summary + the destructive "Erase My Data" flow.
          _SectionLabel(label: 'Privacy'),
          _SettingsCard(
            children: [
              ListTile(
                leading:  const Icon(Icons.shield_outlined, color: _kForest),
                title:    const Text(
                  'Privacy & Data Settings',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                ),
                subtitle: const Text(
                  'POPIA data terms · erase my data',
                  style: TextStyle(fontSize: 12),
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20)),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => PrivacySettingsScreen(
                        onAccountDeleted: () async {
                          // 1. Run the hub's sign-out teardown (clears the
                          //    profile, pops the stack back to AuthScreen).
                          await widget.onAccountDeleted?.call();
                          // 2. Confirm to the user. Use the root messenger
                          //    because by this point the Settings/Privacy
                          //    screens have been popped off the stack.
                          final messenger = ScaffoldMessenger.maybeOf(
                              context);
                          messenger?.showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Account and personal data successfully erased.',
                                style: TextStyle(fontWeight: FontWeight.w600),
                              ),
                              behavior: SnackBarBehavior.floating,
                            ),
                          );
                        },
                      ),
                    ),
                  );
                },
              ),
            ],
          ),

          const SizedBox(height: 24),

          // ── ChowSA Pro ─────────────────────────────────────────────────────
          _ProCard(),
        ],
      ),
    );
  }

}

// =============================================================================
// _ServingCounter — +/− counter widget
// =============================================================================

class _ServingCounter extends StatelessWidget {
  const _ServingCounter({required this.value, required this.onChanged});

  final int              value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _CounterButton(
          icon:      Icons.remove_rounded,
          onPressed: value > 1 ? () => onChanged(value - 1) : null,
        ),
        Container(
          width:  44,
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color:        const Color(0xFFF4F1EA),
            borderRadius: BorderRadius.circular(8),
            border:       Border.all(color: const Color(0xFFE6E2D8)),
          ),
          child: Text(
            '$value',
            style: const TextStyle(
              fontSize:   16,
              fontWeight: FontWeight.w800,
              color:      _kForest,
            ),
          ),
        ),
        _CounterButton(
          icon:      Icons.add_rounded,
          onPressed: value < 12 ? () => onChanged(value + 1) : null,
        ),
      ],
    );
  }
}

class _CounterButton extends StatelessWidget {
  const _CounterButton({required this.icon, required this.onPressed});

  final IconData     icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon:      Icon(icon, size: 20),
      onPressed: onPressed,
      color:     onPressed != null ? _kOrange : Colors.grey.withAlpha(100),
      style: IconButton.styleFrom(
        minimumSize:   const Size(36, 36),
        padding:       EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}

// =============================================================================
// _ProCard — ChowSA Pro upsell tile
// =============================================================================

// _ProCard — Partner Link tile only for v1.0.
//
// The ChowSA Pro upsell that used to live here was removed for the
// first Play Store release: every user gets Pro features for free via
// [EntitlementService.isPro], so a "Subscribe" button would just
// confuse people. The Partner Link feature is unrelated to Pro and
// stays.
//
// When Play Billing lands in v1.1, re-add the _ProTile back above the
// Partner Link section — see git history for the original
// PlayBillingService-backed upsell + manage-subscription tile.
class _ProCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionLabel(label: 'Partner Link'),
        _SettingsCard(children: [_PartnerLinkTile()]),
      ],
    );
  }
}

// =============================================================================
// Small sub-widgets
// =============================================================================

// ── _PaletteDot — small swatch used by the picker tiles ──────────────────────

class _PaletteDot extends StatelessWidget {
  const _PaletteDot({required this.color, this.border, this.size = 18});

  final Color  color;
  final Color? border;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width:  size,
        height: size,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: border != null
              ? Border.all(color: border!, width: 1)
              : null,
        ),
      );
}

// ── _ThemePickerTile ─────────────────────────────────────────────────────────
//
// Full-width picker row for one ChowTheme. Layout:
//
//   ┌─────────────────────────────────────────────────────┐
//   │ [●●●●]  ChowSA Fresh                          ●    │  ← anchor/canvas/surface/accent dots
//   │         Avocado green · cream canvas · mango       │     + selection indicator
//   └─────────────────────────────────────────────────────┘
//
// When selected: 2.5px ring in the theme's own accent color (mango / honey /
// orange) so the active state visually reinforces what's about to be applied.

/// Placeholder tile shown beneath the active theme picker — signals to
/// users that more palettes are on the way after Savanna Dusk was retired.
class _ComingSoonThemeTile extends StatelessWidget {
  const _ComingSoonThemeTile();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: BoxDecoration(
        color:        cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: cs.outlineVariant.withValues(alpha: 0.6),
          style: BorderStyle.solid,
        ),
      ),
      child: Row(
        children: [
          Container(
            width:  44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color:        _kCream,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Text('🍲', style: TextStyle(fontSize: 22)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'More local themes cooking soon… ✨',
                  style: TextStyle(
                    fontSize:   13.5,
                    fontWeight: FontWeight.w800,
                    color:      cs.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'We retired Savanna Dusk. A fresh batch of palettes is '
                  'simmering — check back soon.',
                  style: TextStyle(
                    fontSize: 11.5,
                    color:    cs.onSurfaceVariant,
                    height:   1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ThemePickerTile extends StatelessWidget {
  const _ThemePickerTile({
    required this.theme,
    required this.selected,
    required this.onTap,
  });

  final ChowTheme    theme;
  final bool         selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve:    Curves.easeOutQuart,
        padding:  const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: theme.canvasColor,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected ? theme.accentColor : theme.primaryColor.withAlpha(28),
            width: selected ? 2.5 : 1,
          ),
        ),
        child: Row(
          children: [
            // ── 4-dot palette preview ────────────────────────────────────
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: theme.surfaceColor,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: theme.primaryColor.withAlpha(20), width: 1),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(children: [
                    _PaletteDot(color: theme.primaryColor, size: 16),
                    const SizedBox(width: 5),
                    _PaletteDot(color: theme.canvasColor,
                        border: theme.primaryColor.withAlpha(60), size: 16),
                  ]),
                  const SizedBox(height: 5),
                  Row(children: [
                    _PaletteDot(color: theme.surfaceColor,
                        border: theme.primaryColor.withAlpha(40), size: 16),
                    const SizedBox(width: 5),
                    _PaletteDot(color: theme.accentColor, size: 16),
                  ]),
                ],
              ),
            ),
            const SizedBox(width: 14),

            // ── Label column ─────────────────────────────────────────────
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    theme.displayName,
                    style: tt.bodyLarge?.copyWith(
                      color:         theme.primaryColor,
                      fontWeight:    FontWeight.w900,
                      letterSpacing: -0.2,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    theme.description,
                    style: tt.bodySmall?.copyWith(
                      fontSize: 11.5,
                      height:   1.35,
                      color:    theme.primaryColor.withAlpha(180),
                    ),
                  ),
                ],
              ),
            ),

            // ── Selected indicator — accent-colored check or hollow ring ──
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: selected
                  ? Container(
                      key: const ValueKey('selected'),
                      width: 28, height: 28,
                      decoration: BoxDecoration(
                        color: theme.accentColor,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.check_rounded,
                          color: Colors.white, size: 18),
                    )
                  : SizedBox(
                      key: const ValueKey('idle'),
                      width: 28, height: 28,
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: theme.primaryColor.withAlpha(60),
                            width: 1.5),
                          shape:  BoxShape.circle,
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 0, 8),
        child: Text(
          label.toUpperCase(),
          style: const TextStyle(
            fontSize:      11,
            fontWeight:    FontWeight.w700,
            color:         Color(0xFF55534E),
            letterSpacing: 1.2,
          ),
        ),
      );
}

// =============================================================================
// _ChatBubbleThemeRow — picker for the curated chat-bubble palette (PR 6)
// =============================================================================

class _ChatBubbleThemeRow extends StatelessWidget {
  const _ChatBubbleThemeRow();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: ChatBubbleThemeController.instance.selectedId,
      builder: (ctx, selectedId, _) {
        final selected =
            ChatBubbleThemeController.themeForId(selectedId);
        return _SettingsRow(
          icon:     Icons.chat_bubble_outline_rounded,
          title:    'Bubble theme',
          subtitle: 'Currently: ${selected.label}',
          child: SizedBox(
            height: 56,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount:   kChatBubbleThemes.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (_, i) {
                final t = kChatBubbleThemes[i];
                final isSel = t.id == selectedId;
                return InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () =>
                      ChatBubbleThemeController.instance.setSelected(t.id),
                  child: Container(
                    width: 84,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 6),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: isSel
                            ? const Color(0xFF0C351E)
                            : const Color(0xFFE6E2D8),
                        width: isSel ? 2 : 1,
                      ),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _Swatch(color: t.other),
                            const SizedBox(width: 4),
                            _Swatch(color: t.own),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          t.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize:   10.5,
                            fontWeight: FontWeight.w800,
                            color:      Color(0xFF0C351E),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 18, height: 18,
      decoration: BoxDecoration(
        color:        color,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFFE6E2D8)),
      ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color:        Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: const [
            BoxShadow(
              color:      Color(0x0C000000),
              blurRadius: 8,
              offset:     Offset(0, 2),
            ),
          ],
        ),
        child: Column(children: children),
      );
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.icon,
    required this.title,
    required this.child,
    this.subtitle,
  });

  final IconData icon;
  final String   title;
  final String?  subtitle;
  final Widget   child;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: _kForest),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: tt.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        style: tt.bodySmall?.copyWith(color: const Color(0xFF55534E)),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

// =============================================================================
// _FontChip — tappable chip showing font name rendered in that font
// =============================================================================
class _FontChip extends StatelessWidget {
  const _FontChip({
    required this.label,
    required this.fontName,
    required this.isSelected,
    required this.onTap,
  });

  final String       label;
  final String       fontName;
  final bool         isSelected;
  final VoidCallback onTap;

  TextStyle get _style {
    if (fontName == 'Default') {
      return const TextStyle(fontSize: 13, fontWeight: FontWeight.w600);
    }
    try {
      return GoogleFonts.getFont(fontName,
          fontSize: 13, fontWeight: FontWeight.w600);
    } catch (_) {
      return const TextStyle(fontSize: 13, fontWeight: FontWeight.w600);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? const Color(0xFF0C351E)
              : const Color(0xFF0C351E).withAlpha(10),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: isSelected
                ? const Color(0xFF0C351E)
                : const Color(0xFF0C351E).withAlpha(35),
            width: isSelected ? 1.5 : 1.0,
          ),
        ),
        child: Text(
          label,
          style: _style.copyWith(
            color: isSelected ? Colors.white : const Color(0xFF0C351E),
          ),
        ),
      ),
    );
  }
}

// ── _PartnerLinkTile — set / clear the current user's partner_id ─────────

class _PartnerLinkTile extends StatefulWidget {
  const _PartnerLinkTile();

  @override
  State<_PartnerLinkTile> createState() => _PartnerLinkTileState();
}

class _PartnerLinkTileState extends State<_PartnerLinkTile> {
  final _ctrl = TextEditingController();
  String? _linkedHandle;
  bool    _loading = false;

  @override
  void initState() {
    super.initState();
    _loadCurrent();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _loadCurrent() async {
    final partnerId =
        await SmartSuggestionsService.instance.currentPartnerId();
    if (!mounted || partnerId == null) return;
    // Resolve the partner's handle for display.
    try {
      final row = await Supabase.instance.client
          .from('profiles')
          .select('handle, username')
          .eq('id', partnerId)
          .maybeSingle();
      if (!mounted) return;
      final h = (row?['handle']   as String?)
             ?? (row?['username'] as String?);
      if (h != null && h.isNotEmpty) setState(() => _linkedHandle = h);
    } catch (_) {/* surface as not-linked */}
  }

  Future<void> _link() async {
    if (_loading) return;
    final raw = _ctrl.text.trim();
    if (raw.isEmpty) return;
    setState(() => _loading = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final match = await SmartSuggestionsService.instance
          .linkPartnerByHandle(raw);
      if (!mounted) return;
      final h = (match['handle']   as String?)
             ?? (match['username'] as String?)
             ?? raw;
      setState(() {
        _linkedHandle = h;
        _loading      = false;
        _ctrl.clear();
      });
      messenger.showSnackBar(SnackBar(
        content:  Text('Linked to @$h 🔗'),
        behavior: SnackBarBehavior.floating,
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      messenger.showSnackBar(SnackBar(
        content:  Text(e is StateError ? e.message : '$e'),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  Future<void> _unlink() async {
    setState(() => _loading = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await SmartSuggestionsService.instance.unlinkPartner();
      if (!mounted) return;
      setState(() {
        _linkedHandle = null;
        _loading      = false;
      });
      messenger.showSnackBar(const SnackBar(
        content:  Text('Partner unlinked.'),
        behavior: SnackBarBehavior.floating,
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      messenger.showSnackBar(SnackBar(
        content:  Text('Could not unlink: $e'),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_linkedHandle != null) {
      return ListTile(
        leading: const Icon(Icons.link_rounded, color: Color(0xFFE91E63)),
        title:   Text(
          '@$_linkedHandle',
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        subtitle: const Text(
          'Sharing your Smart Suggestions planner with this user.',
          style: TextStyle(fontSize: 12),
        ),
        trailing: TextButton(
          onPressed: _loading ? null : _unlink,
          child: const Text('Unlink'),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Link a partner to share your Smart Suggestions planner. They\'ll '
            'see meals you approve in real time. One-time set-up.',
            style: TextStyle(fontSize: 12.5, height: 1.4),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _ctrl,
                  autocorrect: false,
                  enabled: !_loading,
                  onSubmitted: (_) => _link(),
                  decoration: const InputDecoration(
                    prefixText: '@',
                    hintText:   'Partner handle',
                    border:     OutlineInputBorder(),
                    isDense:    true,
                    contentPadding: EdgeInsets.symmetric(
                        horizontal: 12, vertical: 12),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _loading ? null : _link,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFE91E63),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 18, vertical: 12),
                ),
                child: _loading
                    ? const SizedBox(
                        width: 16, height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('Link',
                        style: TextStyle(fontWeight: FontWeight.w800)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
