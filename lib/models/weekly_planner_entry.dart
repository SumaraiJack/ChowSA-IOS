// lib/models/weekly_planner_entry.dart
//
// Maps a row from the shared `weekly_planner` Supabase table — Melrose
// writes them, SumaraiJack reads them via .stream().

enum MealSlot { breakfast, lunch, supper }

extension MealSlotX on MealSlot {
  String get wire => switch (this) {
        MealSlot.breakfast => 'breakfast',
        MealSlot.lunch     => 'lunch',
        MealSlot.supper    => 'supper',
      };

  String get displayName => switch (this) {
        MealSlot.breakfast => 'Breakfast',
        MealSlot.lunch     => 'Lunch',
        MealSlot.supper    => 'Supper',
      };

  String get emoji => switch (this) {
        MealSlot.breakfast => '🍳',
        MealSlot.lunch     => '🥗',
        MealSlot.supper    => '🍲',
      };

  static MealSlot? fromWire(String? s) => switch (s) {
        'breakfast' => MealSlot.breakfast,
        'lunch'     => MealSlot.lunch,
        'supper'    => MealSlot.supper,
        _           => null,
      };
}

class WeeklyPlannerEntry {
  const WeeklyPlannerEntry({
    required this.id,
    required this.userId,
    required this.mealSlot,
    required this.title,
    required this.summary,
    required this.ingredients,
    required this.instructions,
    required this.sourceIngredients,
    required this.suggestedFor,
    required this.createdAt,
  });

  final String       id;
  final String       userId;
  final MealSlot     mealSlot;
  final String       title;
  final String?      summary;
  final List<String> ingredients;
  final List<String> instructions;
  /// The top-ingredients list the AI was conditioned on. Surfaced in the
  /// partner view so SumaraiJack sees "this came from her tomato + onion
  /// pattern" instead of an opaque AI hallucination.
  final List<String> sourceIngredients;
  final DateTime?    suggestedFor;
  final DateTime     createdAt;

  factory WeeklyPlannerEntry.fromRow(Map<String, dynamic> r) {
    List<String> stringList(dynamic raw) {
      if (raw is List) {
        return raw.map((e) => e.toString()).toList();
      }
      return const [];
    }

    return WeeklyPlannerEntry(
      id:                r['id']          as String,
      userId:            r['user_id']     as String,
      mealSlot:          MealSlotX.fromWire(r['meal_slot'] as String?)
                            ?? MealSlot.supper,
      title:             r['title']       as String,
      summary:           r['summary']     as String?,
      ingredients:       stringList(r['ingredients']),
      instructions:      stringList(r['instructions']),
      sourceIngredients: stringList(r['source_ingredients']),
      suggestedFor:      r['suggested_for'] == null
          ? null
          : DateTime.parse(r['suggested_for'] as String),
      createdAt:         DateTime.parse(r['created_at'] as String),
    );
  }
}
