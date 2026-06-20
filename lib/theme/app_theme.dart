// lib/theme/app_theme.dart
//
// ChowSA Design System v4.0 â€” three psychologically distinct themes.
// Brightness is intrinsic to each theme; the Settings "Light/Dark" picker
// has been removed. There is no neutral light/dark variant â€” the chosen
// theme IS the look.
//
//   1. Chow SA Fresh   â€” Trust & Appetite (cream + forest + amber)
//   2. Karoo Twilight  â€” Comfort & Evening Focus (slate + ember-gold)
//   (Karoo Twilight retired in v4.2; Savanna Dusk retired in v4.3.)

import 'package:flutter/material.dart';

// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
//   ChowColors â€” semantic, theme-aware color accessor
// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

class ChowColors {
  const ChowColors._({
    required this.title,
    required this.body,
    required this.caption,
    required this.brand,
    required this.brandText,
    required this.accent,
    required this.accentText,
    required this.surface,
    required this.surfaceLow,
    required this.surfaceHigh,
    required this.border,
  });

  factory ChowColors.of(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ChowColors._(
      title:       cs.onSurface,
      body:        cs.onSurfaceVariant,
      caption:     cs.onSurfaceVariant.withAlpha(160),
      brand:       cs.primary,
      brandText:   cs.onPrimary,
      accent:      cs.secondary,
      accentText:  cs.onSecondary,
      surface:     cs.surface,
      surfaceLow:  cs.surfaceContainerLow,
      surfaceHigh: cs.surfaceContainerHigh,
      border:      cs.outlineVariant,
    );
  }

  final Color title;
  final Color body;
  final Color caption;
  final Color brand;
  final Color brandText;
  final Color accent;
  final Color accentText;
  final Color surface;
  final Color surfaceLow;
  final Color surfaceHigh;
  final Color border;
}

extension ChowColorsX on BuildContext {
  ChowColors get chow => ChowColors.of(this);
}

// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
//   TOKEN CLASSES
// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

/// Theme 1 â€” Chow SA Fresh (Trust & Appetite).
abstract final class ChowFreshTokens {
  static const Color forest      = Color(0xFF1E4D2B); // Deep forest green
  static const Color forestDeep  = Color(0xFF103019);
  static const Color amber       = Color(0xFFF5A623); // Warm amber-orange
  static const Color amberDeep   = Color(0xFFCC8313);
  static const Color cream       = Color(0xFFF8F6F1); // Off-white scaffold
  static const Color chalk       = Color(0xFFFFFFFF); // Card surface
  static const Color mist        = Color(0xFFEEEBE3);
  static const Color charcoal    = Color(0xFF1F2A24); // Heading
  static const Color graphite    = Color(0xFF5C6660); // Body
  static const Color slate       = Color(0xFF8B928E);
  static const Color hairline    = Color(0xFFE0DDD3);
  static const Color success     = Color(0xFF3FA34D);
  static const Color error       = Color(0xFFC84B4B);
}

// (Karoo Twilight removed in v4.2 â€” the app is light-only.)

/// Theme 4 â€” Protea Blush (Romance & Warmth). Hidden Easter-egg theme,
/// surfaced only when the signed-in handle matches the gate in
/// SettingsScreen._ThemePickerTile.
abstract final class ChowBlushTokens {
  static const Color blush       = Color(0xFFFFF5F6); // Scaffold â€” pale rosy white
  static const Color chalk       = Color(0xFFFFFFFF); // Card surface â€” vanilla cream
  static const Color petal       = Color(0xFFFCE4E8); // Elevated tint
  static const Color berry       = Color(0xFF6B1D2F); // Heading / AppBar â€” protea wine
  static const Color berryDeep   = Color(0xFF4A1320); // Pressed berry
  static const Color coral       = Color(0xFFE25B75); // Accent CTA â€” bright coral pink
  static const Color coralDeep   = Color(0xFFC03A56);
  static const Color rose        = Color(0xFFF8B5C0); // Soft rose secondary
  static const Color charcoal    = Color(0xFF2A1218); // Body text on light
  static const Color mauve       = Color(0xFF7A5560); // Caption / muted body
  static const Color hairline    = Color(0xFFF5D6DC); // Subtle rose divider
  static const Color shadowTint  = Color(0x1AE25B75); // Soft rose card shadow
  static const Color success     = Color(0xFF3FA34D);
  static const Color error       = Color(0xFFC84B4B);
}


// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
//   AppTheme
// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

abstract final class AppTheme {

  // â”€â”€ Back-compat tokens (used widely across views). Mapped to Fresh. â”€â”€â”€â”€â”€
  static const Color kBottleGreen = ChowFreshTokens.forest;
  static const Color kAlabaster   = ChowFreshTokens.cream;
  static const Color kCreamSand   = ChowFreshTokens.mist;
  static const Color kProteaGold  = ChowFreshTokens.amber;
  static const Color kMidnight    = ChowFreshTokens.charcoal;
  static const Color kEarthGrey   = ChowFreshTokens.graphite;
  static const Color kHairline    = ChowFreshTokens.hairline;
  static const Color kStoneBorder = Color(0xFFB0ACA1);

  // â”€â”€ Public theme getters â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  // v4.2: dark variants removed. Every palette is intrinsically light, and
  // the legacy "Dark" getters alias to the same ThemeData so old callers
  // still compile without rendering anything dark.
  static ThemeData get freshLight    => _fresh;
  static ThemeData get freshDark     => _fresh;
  static ThemeData get blushLight    => _proteaBlush;
  static ThemeData get blushDark     => _proteaBlush;

  static ThemeData get mzansiOrganicLuxury => _fresh;

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //   THEME 1 â€” Chow SA Fresh
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

  static final ThemeData _fresh = _buildTheme(
    brightness: Brightness.light,
    scheme: const ColorScheme(
      brightness:            Brightness.light,
      primary:               ChowFreshTokens.forest,
      onPrimary:             Colors.white,
      primaryContainer:      Color(0xFFCFE0D4),
      onPrimaryContainer:    ChowFreshTokens.forestDeep,
      secondary:             ChowFreshTokens.amber,
      onSecondary:           ChowFreshTokens.charcoal,
      secondaryContainer:    Color(0xFFFFE2B5),
      onSecondaryContainer:  Color(0xFF4A3105),
      tertiary:              Color(0xFF3A7361),
      onTertiary:            Colors.white,
      tertiaryContainer:     Color(0xFFC4D8CC),
      onTertiaryContainer:   ChowFreshTokens.forestDeep,
      error:                 ChowFreshTokens.error,
      onError:               Colors.white,
      errorContainer:        Color(0xFFF7DCDC),
      onErrorContainer:      Color(0xFF410E0B),
      surface:               ChowFreshTokens.cream,
      onSurface:             ChowFreshTokens.charcoal,
      onSurfaceVariant:      ChowFreshTokens.graphite,
      surfaceContainerLowest:Colors.white,
      surfaceContainerLow:   Color(0xFFF3F0E9),
      surfaceContainer:      ChowFreshTokens.mist,
      surfaceContainerHigh:  Color(0xFFE5E0D3),
      surfaceContainerHighest:Color(0xFFD8D2C2),
      outline:               Color(0xFFA7B3AB),
      outlineVariant:        ChowFreshTokens.hairline,
      shadow:                Colors.black,
      scrim:                 Colors.black,
      inverseSurface:        ChowFreshTokens.forestDeep,
      onInverseSurface:      ChowFreshTokens.cream,
      inversePrimary:        Color(0xFF9CC1B0),
    ),
    anchor:       ChowFreshTokens.forest,
    accent:       ChowFreshTokens.amber,
    scaffoldBg:   ChowFreshTokens.cream,
    cardBg:       ChowFreshTokens.chalk,
    dialogBg:     Colors.white,
    sheetBg:      ChowFreshTokens.cream,
    navBg:        Colors.white,
    headingColor: ChowFreshTokens.charcoal,
    bodyColor:    ChowFreshTokens.graphite,
    hairline:     ChowFreshTokens.hairline,
    accentTextOn: ChowFreshTokens.charcoal,
    anchorTextOn: Colors.white,
  );

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //   THEME 4 â€” Protea Blush (hidden Easter egg)
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

  static final ThemeData _proteaBlush = _buildTheme(
    brightness: Brightness.light,
    scheme: const ColorScheme(
      brightness:            Brightness.light,
      primary:               ChowBlushTokens.berry,
      onPrimary:             Colors.white,
      primaryContainer:      ChowBlushTokens.rose,
      onPrimaryContainer:    ChowBlushTokens.berryDeep,
      secondary:             ChowBlushTokens.coral,
      onSecondary:           Colors.white,
      secondaryContainer:    Color(0xFFFFD0DA),
      onSecondaryContainer:  Color(0xFF5A0A1F),
      tertiary:              ChowBlushTokens.rose,
      onTertiary:            ChowBlushTokens.berryDeep,
      tertiaryContainer:     Color(0xFFFFDEE5),
      onTertiaryContainer:   ChowBlushTokens.berryDeep,
      error:                 ChowBlushTokens.error,
      onError:               Colors.white,
      errorContainer:        Color(0xFFF7DCDC),
      onErrorContainer:      Color(0xFF410E0B),
      surface:               ChowBlushTokens.blush,
      onSurface:             ChowBlushTokens.berry,
      onSurfaceVariant:      ChowBlushTokens.mauve,
      surfaceContainerLowest:Colors.white,
      surfaceContainerLow:   Color(0xFFFFF0F2),
      surfaceContainer:      ChowBlushTokens.petal,
      surfaceContainerHigh:  Color(0xFFF8D0D8),
      surfaceContainerHighest:Color(0xFFF2BCC6),
      outline:               Color(0xFFD4A0AC),
      outlineVariant:        ChowBlushTokens.hairline,
      shadow:                Color(0x33E25B75),
      scrim:                 Colors.black,
      inverseSurface:        ChowBlushTokens.berryDeep,
      onInverseSurface:      ChowBlushTokens.blush,
      inversePrimary:        ChowBlushTokens.rose,
    ),
    anchor:       ChowBlushTokens.berry,
    accent:       ChowBlushTokens.coral,
    scaffoldBg:   ChowBlushTokens.blush,
    cardBg:       ChowBlushTokens.chalk,
    dialogBg:     Colors.white,
    sheetBg:      ChowBlushTokens.blush,
    navBg:        Colors.white,
    headingColor: ChowBlushTokens.berry,
    bodyColor:    ChowBlushTokens.mauve,
    hairline:     ChowBlushTokens.hairline,
    accentTextOn: Colors.white,
    anchorTextOn: Colors.white,
  );

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //   Shared theme builder
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

  static ThemeData _buildTheme({
    required Brightness  brightness,
    required ColorScheme scheme,
    required Color       anchor,
    required Color       accent,
    required Color       scaffoldBg,
    required Color       cardBg,
    required Color       dialogBg,
    required Color       sheetBg,
    required Color       navBg,
    required Color       headingColor,
    required Color       bodyColor,
    required Color       hairline,
    required Color       accentTextOn,
    required Color       anchorTextOn,
  }) {
    final base = ThemeData(useMaterial3: true, colorScheme: scheme);

    final textTheme = base.textTheme.copyWith(
      displayLarge:  base.textTheme.displayLarge?.copyWith(
        color: headingColor, fontWeight: FontWeight.w900,
        letterSpacing: -1.2, height: 1.05),
      displayMedium: base.textTheme.displayMedium?.copyWith(
        color: headingColor, fontWeight: FontWeight.w900,
        letterSpacing: -1.0, height: 1.05),
      displaySmall:  base.textTheme.displaySmall?.copyWith(
        color: headingColor, fontWeight: FontWeight.w800,
        letterSpacing: -0.6, height: 1.1),
      headlineLarge: base.textTheme.headlineLarge?.copyWith(
        color: headingColor, fontWeight: FontWeight.w800, letterSpacing: -0.3),
      headlineMedium:base.textTheme.headlineMedium?.copyWith(
        color: headingColor, fontWeight: FontWeight.w800, letterSpacing: -0.2),
      headlineSmall: base.textTheme.headlineSmall?.copyWith(
        color: headingColor, fontWeight: FontWeight.w800, letterSpacing: -0.1),
      titleLarge:    base.textTheme.titleLarge?.copyWith(
        color: headingColor, fontWeight: FontWeight.w700),
      titleMedium:   base.textTheme.titleMedium?.copyWith(
        color: headingColor, fontWeight: FontWeight.w700, letterSpacing: 0.1),
      titleSmall:    base.textTheme.titleSmall?.copyWith(
        color: headingColor, fontWeight: FontWeight.w700, letterSpacing: 0.1),
      bodyLarge:     base.textTheme.bodyLarge?.copyWith(
        color: bodyColor, height: 1.55, letterSpacing: 0.1),
      bodyMedium:    base.textTheme.bodyMedium?.copyWith(
        color: bodyColor, height: 1.5, letterSpacing: 0.15),
      bodySmall:     base.textTheme.bodySmall?.copyWith(
        color: bodyColor, height: 1.45, letterSpacing: 0.2),
      labelLarge:    base.textTheme.labelLarge?.copyWith(
        color: headingColor, fontWeight: FontWeight.w700, letterSpacing: 0.2),
      labelMedium:   base.textTheme.labelMedium?.copyWith(
        color: bodyColor, fontWeight: FontWeight.w600, letterSpacing: 0.3),
      labelSmall:    base.textTheme.labelSmall?.copyWith(
        color: bodyColor, fontWeight: FontWeight.w600, letterSpacing: 0.4),
    );

    return base.copyWith(
      textTheme:               textTheme,
      primaryTextTheme:        textTheme,
      primaryColor:            anchor,

      scaffoldBackgroundColor: scaffoldBg,
      canvasColor:             scaffoldBg,
      // ignore: deprecated_member_use
      dialogBackgroundColor:   dialogBg,

      appBarTheme: AppBarTheme(
        backgroundColor:  anchor,
        foregroundColor:  anchorTextOn,
        surfaceTintColor: Colors.transparent,
        shadowColor:      Colors.transparent,
        elevation:        0,
        scrolledUnderElevation: 0,
        centerTitle:      false,
        titleTextStyle: TextStyle(
          color:         anchorTextOn,
          fontSize:      18,
          fontWeight:    FontWeight.w900,
          letterSpacing: -0.2,
        ),
        iconTheme:        IconThemeData(color: anchorTextOn),
        actionsIconTheme: IconThemeData(color: anchorTextOn),
      ),

      cardTheme: CardThemeData(
        color:            cardBg,
        surfaceTintColor: Colors.transparent,
        shadowColor:      Colors.transparent,
        elevation:        0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: hairline, width: 1),
        ),
        margin: EdgeInsets.zero,
      ),

      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: accentTextOn,
          elevation:       0,
          shadowColor:     Colors.transparent,
          textStyle: const TextStyle(
            fontWeight:    FontWeight.w800,
            fontSize:      14.5,
            letterSpacing: 0.2,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: accentTextOn,
          textStyle: const TextStyle(fontWeight: FontWeight.w800),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: anchor,
          side: BorderSide(color: anchor, width: 1.2),
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: accent,
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),

      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: accent,
        foregroundColor: accentTextOn,
        elevation:       3,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),

      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor:    navBg,
        selectedItemColor:  anchor,
        unselectedItemColor:bodyColor,
        type:               BottomNavigationBarType.fixed,
        elevation:          0,
        showSelectedLabels: true,
        showUnselectedLabels:true,
        selectedLabelStyle: TextStyle(
          fontWeight: FontWeight.w800, fontSize: 11.5, color: anchor),
        unselectedLabelStyle: TextStyle(
          fontWeight: FontWeight.w600, fontSize: 11.5, color: bodyColor),
        selectedIconTheme:   IconThemeData(color: anchor,   size: 24),
        unselectedIconTheme: IconThemeData(color: bodyColor, size: 22),
      ),

      navigationBarTheme: NavigationBarThemeData(
        backgroundColor:  navBg,
        surfaceTintColor: Colors.transparent,
        shadowColor:      Colors.transparent,
        elevation:        0,
        height:           72,
        indicatorColor:   scheme.primaryContainer,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final on = states.contains(WidgetState.selected);
          return TextStyle(
            fontSize:   11.5,
            fontWeight: on ? FontWeight.w800 : FontWeight.w600,
            color:      on ? anchor : bodyColor,
            letterSpacing: 0.2,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final on = states.contains(WidgetState.selected);
          return IconThemeData(
            color: on ? anchor : bodyColor,
            size:  on ? 24 : 22,
          );
        }),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled:    true,
        fillColor: brightness == Brightness.light ? Colors.white : cardBg,
        hintStyle: TextStyle(
          color: bodyColor.withAlpha(130), fontSize: 14),
        labelStyle:         TextStyle(color: bodyColor),
        floatingLabelStyle: TextStyle(color: anchor, fontWeight: FontWeight.w700),
        prefixIconColor: bodyColor,
        suffixIconColor: bodyColor,
        contentPadding: const EdgeInsets.symmetric(
            horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide:   BorderSide(color: hairline, width: 1),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide:   BorderSide(color: hairline, width: 1),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide:   BorderSide(color: anchor, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide:   BorderSide(color: scheme.error, width: 1),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide:   BorderSide(color: scheme.error, width: 1.5),
        ),
      ),

      listTileTheme: ListTileThemeData(
        textColor:         headingColor,
        iconColor:         anchor,
        selectedColor:     anchor,
        selectedTileColor: scheme.surfaceContainerHigh,
        titleTextStyle: TextStyle(
          color:      headingColor,
          fontSize:   15,
          fontWeight: FontWeight.w600,
        ),
        subtitleTextStyle: TextStyle(
          color:    bodyColor,
          fontSize: 13,
          height:   1.4,
        ),
        leadingAndTrailingTextStyle: TextStyle(
          color:    bodyColor,
          fontSize: 12,
        ),
      ),
      dividerTheme: DividerThemeData(
        color: hairline, thickness: 1, space: 1),
      chipTheme: ChipThemeData(
        backgroundColor: cardBg,
        selectedColor:   accent.withAlpha(50),
        secondarySelectedColor: accent,
        labelStyle: textTheme.labelMedium?.copyWith(
          color: headingColor, fontWeight: FontWeight.w600),
        secondaryLabelStyle: TextStyle(
          color: accentTextOn, fontWeight: FontWeight.w700),
        side: BorderSide(color: hairline),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? accentTextOn : bodyColor),
        trackColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? accent : hairline),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor:   accent,
        inactiveTrackColor: hairline,
        thumbColor:         accent,
        overlayColor:       accent.withAlpha(40),
      ),

      snackBarTheme: SnackBarThemeData(
        backgroundColor: anchor,
        contentTextStyle: TextStyle(
          color: anchorTextOn, fontWeight: FontWeight.w600),
        actionTextColor: accent,
        behavior:        SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor:  dialogBg,
        surfaceTintColor: Colors.transparent,
        elevation:        2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        titleTextStyle:   TextStyle(
          color: headingColor, fontWeight: FontWeight.w900, fontSize: 18),
        contentTextStyle: TextStyle(
          color: bodyColor, fontWeight: FontWeight.w500),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor:  sheetBg,
        surfaceTintColor: Colors.transparent,
        elevation:        0,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),

      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: anchor,
        linearTrackColor: hairline,
        circularTrackColor: hairline,
      ),
      iconTheme: IconThemeData(color: anchor, size: 22),
      splashColor:    accent.withAlpha(30),
      highlightColor: accent.withAlpha(18),
      hoverColor:     accent.withAlpha(14),
      focusColor:     accent.withAlpha(30),
    );
  }
}
