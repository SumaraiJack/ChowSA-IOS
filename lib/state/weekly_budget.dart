// lib/state/weekly_budget.dart
//
// Global "weekly food budget" — the user-set target the whole app reads
// from so Budget stops being a per-list afterthought and becomes a
// first-class theme on Chow Home. Persisted via shared_preferences; null
// means "no target set yet".

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _kWeeklyBudgetPref = 'chowsa_weekly_budget_zar';

class WeeklyBudget {
  WeeklyBudget._();

  /// Bind UI to this. Null until [load] runs.
  static final ValueNotifier<double?> value = ValueNotifier<double?>(null);

  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getDouble(_kWeeklyBudgetPref);
      value.value = (v != null && v > 0) ? v : null;
    } catch (_) {
      // Best-effort.
    }
  }

  static Future<void> set(double? amount) async {
    value.value = (amount != null && amount > 0) ? amount : null;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (value.value == null) {
        await prefs.remove(_kWeeklyBudgetPref);
      } else {
        await prefs.setDouble(_kWeeklyBudgetPref, value.value!);
      }
    } catch (_) {
      // Best-effort.
    }
  }
}
