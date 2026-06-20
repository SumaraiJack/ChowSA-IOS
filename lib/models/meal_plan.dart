// lib/models/meal_plan.dart

import 'recipe.dart';

// =============================================================================
// MealSlot — the three meal positions within a single day
// =============================================================================

enum MealSlot {
  breakfast,
  lunch,
  dinner;

  String get emoji => switch (this) {
    MealSlot.breakfast => '🌅',
    MealSlot.lunch     => '☀️',
    MealSlot.dinner    => '🌙',
  };

  String get label => switch (this) {
    MealSlot.breakfast => 'Breakfast',
    MealSlot.lunch     => 'Lunch',
    MealSlot.dinner    => 'Dinner',
  };

  String get addText => 'Add ${label} Option';
}

// =============================================================================
// MealPlan — one entry per day of the week.
//
// Each slot now holds a LIST of recipes (multiple options per meal). Callers
// can append, remove individual entries, or clear the whole slot.
// =============================================================================

class MealPlan {
  /// ISO date string ('YYYY-MM-DD') this plan is bound to. The previous
  /// schema keyed on day-of-week names, which caused every Friday in the
  /// month to share the same row — explicit dates fix that.
  final String       date;
  final List<Recipe> breakfast;
  final List<Recipe> lunch;
  final List<Recipe> dinner;

  MealPlan({
    required this.date,
    List<Recipe>? breakfast,
    List<Recipe>? lunch,
    List<Recipe>? dinner,
  })  : breakfast = breakfast ?? <Recipe>[],
        lunch     = lunch     ?? <Recipe>[],
        dinner    = dinner    ?? <Recipe>[];

  /// Convenience: derives the day-of-week label from [date] so legacy
  /// call sites that still want "Monday"/"Tuesday"/etc. keep working.
  String get dayOfWeek {
    final d = DateTime.tryParse(date);
    if (d == null) return '';
    const names = ['Monday','Tuesday','Wednesday','Thursday',
                   'Friday','Saturday','Sunday'];
    return names[(d.weekday - 1).clamp(0, 6)];
  }

  // ── Slot accessors ──────────────────────────────────────────────────────────

  List<Recipe> getSlot(MealSlot slot) => switch (slot) {
    MealSlot.breakfast => breakfast,
    MealSlot.lunch     => lunch,
    MealSlot.dinner    => dinner,
  };

  /// Append a recipe to the named slot.
  void addToSlot(MealSlot slot, Recipe recipe) {
    getSlot(slot).add(recipe);
  }

  /// Remove a single entry by index. Safe against out-of-range.
  void removeFromSlot(MealSlot slot, int index) {
    final list = getSlot(slot);
    if (index >= 0 && index < list.length) {
      list.removeAt(index);
    }
  }

  /// Clear every recipe from a single slot.
  void clearSlot(MealSlot slot) {
    getSlot(slot).clear();
  }

  /// Clear every slot for this whole day.
  void clearDay() {
    breakfast.clear();
    lunch.clear();
    dinner.clear();
  }

  // ── Derived helpers ─────────────────────────────────────────────────────────

  /// Total number of recipes planned across all three slots for this day.
  int get mealCount =>
      breakfast.length + lunch.length + dinner.length;

  /// Number of distinct slots that contain at least one recipe (0..3).
  /// Useful for the collapsed header summary text.
  int get slotsFilled => [
        breakfast.isNotEmpty,
        lunch.isNotEmpty,
        dinner.isNotEmpty,
      ].where((b) => b).length;

  /// True when every primary slot (breakfast + lunch + dinner) carries
  /// at least one recipe — drives the green "fully planned" calendar
  /// dot. Partial fills (1–2 slots) drive the blue dot.
  bool get isFullyPlanned => slotsFilled == 3;

  String get summary {
    final n = slotsFilled;
    if (n == 0) return 'No meals planned yet';
    final total = mealCount;
    if (total == n) {
      // 1 recipe per filled slot → simple phrasing
      return '$n meal${n == 1 ? '' : 's'} mapped out';
    }
    // Multiple options in at least one slot → richer phrasing
    return '$total option${total == 1 ? '' : 's'} across '
        '$n slot${n == 1 ? '' : 's'}';
  }

  bool get isEmpty => mealCount == 0;
}
