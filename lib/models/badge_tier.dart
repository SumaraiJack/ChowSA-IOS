// lib/models/badge_tier.dart
//
// Mzansi Culinary Badges â€” gamified trophies for ChowSA power-users.
//
// Each [MzansiBadge] is a data-only object describing a single trophy.
// The [BadgeTier] enum provides the visual rarity tier used for border
// colour and glow intensity in the badge display widget.
//
// Unlock logic lives in the caller (e.g. BudgetService, PantryService,
// CommunityFeedScreen). Each badge exposes a [key] so the unlock state
// can be stored in Supabase (profiles.earned_badges text[]) or in
// SharedPreferences for offline-first builds.
//
// Usage:
//   // Check if unlocked
//   final earned = prefs.getStringList('earned_badges') ?? [];
//   final unlocked = earned.contains(MzansiBadges.potjiePioneer.key);
//
//   // Award a badge
//   if (!earned.contains(MzansiBadges.tanniesBlessing.key)) {
//     earned.add(MzansiBadges.tanniesBlessing.key);
//     await prefs.setStringList('earned_badges', earned);
//   }

// â”€â”€ BadgeTier â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

/// Visual rarity tier, used to choose border colour and glow effects.
enum BadgeTier {
  /// Common â€” green border, no glow.
  bronze,

  /// Uncommon â€” amber border, subtle glow.
  silver,

  /// Rare â€” orange border, glowing halo.
  gold,

  /// Legendary â€” gradient border, pulsing animation.
  diamond,
}

// â”€â”€ MzansiBadge â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

/// Immutable description of a single Mzansi Culinary Badge.
class MzansiBadge {
  /// Stable snake_case key â€” stored in DB / SharedPreferences to track unlock state.
  final String key;

  /// Trophy emoji shown large on the badge card.
  final String emoji;

  /// Short display title shown on the badge.
  final String title;

  /// One-line copy shown in the badge list.
  final String shortDescription;

  /// Full unlock criteria shown in the badge detail modal.
  final String unlockCriteria;

  /// Rarity tier â€” drives border colour and glow intensity.
  final BadgeTier tier;

  /// Optional: the icon shown in the badge grid when the trophy emoji isn't enough.
  final String? iconAssetPath;

  const MzansiBadge({
    required this.key,
    required this.emoji,
    required this.title,
    required this.shortDescription,
    required this.unlockCriteria,
    required this.tier,
    this.iconAssetPath,
  });
}

// â”€â”€ MzansiBadges â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

/// Static registry of all Mzansi Culinary Badges.
///
/// Import this class anywhere to check, award, or display badges.
/// Badges are immutable â€” add new ones here; never remove existing keys.
abstract final class MzansiBadges {

  // â”€â”€ 1. Potjie Pioneer â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  /// Awarded when the user saves 5 different slow-cook stew recipes.
  static const potjiePioneer = MzansiBadge(
    key:              'potjie_pioneer',
    emoji:            'ðŸª”',
    title:            'Potjie Pioneer',
    shortDescription: 'Saved 5 slow-cook stew recipes.',
    unlockCriteria:
        'Save 5 distinct slow-cook stew recipes to My Recipes. Potjies, '
        'bredie, oxtail, umngqusho stews â€” anything that simmers low and slow '
        'all counts. Keep stacking those legends, chef!',
    tier: BadgeTier.silver,
  );

  // â”€â”€ 2. Kota King / Queen â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  /// Awarded for generating a pantry meal using a quarter loaf + leftovers.
  static const kotaKingQueen = MzansiBadge(
    key:              'kota_king_queen',
    emoji:            'ðŸž',
    title:            'Kota King/Queen',
    shortDescription: 'Built a kota from a quarter loaf and leftovers.',
    unlockCriteria:
        'Generate a pantry recipe that includes a quarter loaf of bread '
        '(government loaf or any township bread) combined with at least '
        '2 leftover ingredients. True kota royalty!',
    tier: BadgeTier.gold,
  );

  // â”€â”€ 3. Tannie's Blessing â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  /// Awarded when a community post receives over 50 likes.
  static const tanniesBlessing = MzansiBadge(
    key:              'tannies_blessing',
    emoji:            'ðŸ«¶',
    title:            "Tannie's Blessing",
    shortDescription: 'Your community post got over 50 likes.',
    unlockCriteria:
        'Post a recipe or chow moment in the Community section and receive '
        'more than 50 likes. Tannie approves â€” your cooking has won the '
        'hearts of Mzansi!',
    tier: BadgeTier.gold,
  );

  // â”€â”€ 4. Midnight Selections â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  /// Awarded for generating a pantry meal between 11 PM and 3 AM.
  static const midnightSelections = MzansiBadge(
    key:              'midnight_selections',
    emoji:            'ðŸŒ™',
    title:            'Midnight Selections',
    shortDescription: 'Generated a pantry meal between 11 PM and 3 AM.',
    unlockCriteria:
        'Open the Pantry screen and generate a recipe at any point between '
        '23:00 and 03:00 local time. Night-shift chef behaviour unlocked. '
        'Load-shedding or not â€” you were hungry and you cooked!',
    tier: BadgeTier.diamond,
  );

  // â”€â”€ 5. Chutney Overlord â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  /// Awarded for adding local chutney accents to 10 distinct meals.
  static const chutneyOverlord = MzansiBadge(
    key:              'chutney_overlord',
    emoji:            'ðŸ«™',
    title:            'Chutney Overlord',
    shortDescription: "Added Mrs. Ball's or local chutney to 10 meals.",
    unlockCriteria:
        "Include chutney (Mrs. Ball's, Nando's peri-peri sauce, or any "
        "local SA chutney brand) as an ingredient in 10 distinct generated "
        "or saved recipes. Real South Africans put chutney on everything.",
    tier: BadgeTier.silver,
  );

  // â”€â”€ 6. Gatvol Chef â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  /// Awarded for generating a meal with 2 or fewer pantry ingredients.
  static const gatvolChef = MzansiBadge(
    key:              'gatvol_chef',
    emoji:            'ðŸ˜¤',
    title:            'Gatvol Chef',
    shortDescription: 'Generated a meal from 2 or fewer ingredients.',
    unlockCriteria:
        'Add 2 or fewer ingredients to your pantry and successfully generate '
        'a recipe. Sometimes the fridge is nearly empty and you still make it '
        'work. That is pure Mzansi resourcefulness, chom!',
    tier: BadgeTier.bronze,
  );

  // â”€â”€ 7. Chom of the Match â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  /// Awarded for attending and checking off items at 5 Bring & Braai events.
  static const chomOfTheMatch = MzansiBadge(
    key:              'chom_of_the_match',
    emoji:            'ðŸ†',
    title:            'Chom of the Match',
    shortDescription:
        "RSVP'd and checked off items at 5 Bring & Braai events.",
    unlockCriteria:
        'Accept an RSVP and claim at least one item in the Bring & Braai '
        'checklist for 5 separate events. The ultimate social chef â€” '
        'always shows up and always delivers!',
    tier: BadgeTier.diamond,
  );

  // â”€â”€ Full registry â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  /// All badges in display order.
  static const List<MzansiBadge> all = [
    potjiePioneer,
    kotaKingQueen,
    tanniesBlessing,
    midnightSelections,
    chutneyOverlord,
    gatvolChef,
    chomOfTheMatch,
  ];

  /// Look up a badge by its [key] string (from DB / SharedPreferences).
  /// Returns null when the key is not recognised (e.g. a future badge
  /// loaded from the server before a client update).
  static MzansiBadge? fromKey(String key) {
    for (final badge in all) {
      if (badge.key == key) return badge;
    }
    return null;
  }
}

// â”€â”€ BadgeTierExtension â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

extension BadgeTierExtension on BadgeTier {
  /// Primary border/accent colour for this tier.
  int get colour => switch (this) {
        BadgeTier.bronze  => 0xFF2E7D32,   // forest green
        BadgeTier.silver  => 0xFFFF8F00,   // amber
        BadgeTier.gold    => 0xFFE59B27,   // ChowSA orange
        BadgeTier.diamond => 0xFF6A1B9A,   // deep purple (legendary)
      };

  /// Human-readable rarity label.
  String get label => switch (this) {
        BadgeTier.bronze  => 'Common',
        BadgeTier.silver  => 'Uncommon',
        BadgeTier.gold    => 'Rare',
        BadgeTier.diamond => 'Legendary',
      };
}

// â”€â”€ Unlock helpers â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

/// Returns true when [badge] should be awarded for the Gatvol Chef criterion
/// (2 or fewer pantry ingredients used to generate recipes).
bool checkGatvolChef(int pantryItemCount) => pantryItemCount <= 2;

/// Returns true when the Midnight Selections criterion is met.
bool checkMidnightSelections() {
  final hour = DateTime.now().hour;
  return hour >= 23 || hour < 3;
}

/// Returns true when the Tannie's Blessing criterion is met.
bool checkTanniesBlessing(int likeCount) => likeCount > 50;

/// Returns true when the Potjie Pioneer criterion is met.
bool checkPotjiePioneer(int savedSlowCookCount) => savedSlowCookCount >= 5;

/// Returns true when the Chom of the Match criterion is met.
bool checkChomOfTheMatch(int completedBraaiEvents) =>
    completedBraaiEvents >= 5;
