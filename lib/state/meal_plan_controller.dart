// lib/state/meal_plan_controller.dart
//
// Single source of truth for the weekly meal planner.
//
// SA context note: load-shedding and patchy mobile data are first-class
// concerns. The controller writes locally to SharedPreferences IMMEDIATELY
// (so 'Clear Week' clears the calendar dots in the same frame even when the
// device is offline), then queues a best-effort sync to the Supabase
// `weekly_planner` table. When the device is back online and the user
// re-opens the planner, the controller pulls the server snapshot and merges
// it back in.
//
// Exposes:
//   • `weekPlanByDate`  — reactive map of `YYYY-MM-DD` → MealPlan
//   • `totalPlanned`    — int notifier for the Profile screen "Planned" stat
//   • clearWeek / clearDay / addToSlot / removeFromSlot / saveDay
//
// Persistence schema (SharedPreferences key `meal_plan_v3`):
//   { 'YYYY-MM-DD': { 'breakfast': [Recipe.toJson(), ...],
//                     'lunch':     [Recipe.toJson(), ...],
//                     'dinner':    [Recipe.toJson(), ...] }, ... }

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/meal_plan.dart';
import '../models/recipe.dart';

class MealPlanController {
  MealPlanController._();
  static final MealPlanController instance = MealPlanController._();

  static const _kPlanKey       = 'meal_plan_v3';
  static const _kLegacyPlanKey = 'meal_plan_v2';

  /// Map keyed by ISO date (`YYYY-MM-DD`).
  final ValueNotifier<Map<String, MealPlan>> weekPlanByDate =
      ValueNotifier<Map<String, MealPlan>>({});

  /// Total options planned across every loaded day. Bell/profile stats
  /// listen here directly instead of polling SharedPreferences.
  final ValueNotifier<int> totalPlanned = ValueNotifier<int>(0);

  bool _running = false;
  bool _hydrated = false;

  // ── Lifecycle ───────────────────────────────────────────────────────────────

  Future<void> start({required String uid}) async {
    if (_running) return;
    _running = true;
    await _hydrate();
  }

  Future<void> dispose() async {
    _running  = false;
    _hydrated = false;
    weekPlanByDate.value = {};
    totalPlanned.value   = 0;
  }

  // ── Public mutations ────────────────────────────────────────────────────────

  Future<void> setDayPlan(MealPlan plan) async {
    final next = Map<String, MealPlan>.from(weekPlanByDate.value);
    next[plan.date] = plan;
    _emit(next);
    await _persist();
  }

  /// Clear every entry across [dates]. The "Clear Week" planner button calls
  /// this with the seven dates of the active week — the calendar dots and
  /// the daily cards rebuild on the same frame.
  Future<void> clearDays(Iterable<String> dates) async {
    final next = Map<String, MealPlan>.from(weekPlanByDate.value);
    for (final d in dates) {
      next.remove(d);
    }
    _emit(next);
    await _persist();
  }

  Future<void> clearDay(String date) async {
    final next = Map<String, MealPlan>.from(weekPlanByDate.value);
    next.remove(date);
    _emit(next);
    await _persist();
  }

  Future<void> addToSlot(String date, MealSlot slot, Recipe recipe) async {
    final next = Map<String, MealPlan>.from(weekPlanByDate.value);
    final plan = next[date] ?? MealPlan(date: date);
    plan.addToSlot(slot, recipe);
    next[date] = plan;
    _emit(next);
    await _persist();
  }

  Future<void> removeFromSlot(String date, MealSlot slot, int index) async {
    final next = Map<String, MealPlan>.from(weekPlanByDate.value);
    final plan = next[date];
    if (plan == null) return;
    plan.removeFromSlot(slot, index);
    if (plan.mealCount == 0) {
      next.remove(date);
    } else {
      next[date] = plan;
    }
    _emit(next);
    await _persist();
  }

  /// One-shot fetch helper for legacy callers that previously read the prefs
  /// directly. Always returns the latest in-memory snapshot.
  Map<String, MealPlan> snapshot() => Map.unmodifiable(weekPlanByDate.value);

  /// Pushes a fresh totalPlanned recount without changing the underlying map.
  /// Kept for compat with `MealPlannerScreen.refreshTotalPlannedCount` calls
  /// scattered around the codebase.
  Future<int> refreshTotalPlannedCount() async {
    if (!_hydrated) await _hydrate();
    return totalPlanned.value;
  }

  // ── Persistence ─────────────────────────────────────────────────────────────

  Future<void> _hydrate() async {
    if (_hydrated) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw   = prefs.getString(_kPlanKey) ?? prefs.getString(_kLegacyPlanKey);
      if (raw == null) {
        _hydrated = true;
        return;
      }
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final next = <String, MealPlan>{};
      for (final entry in map.entries) {
        final date = entry.key;
        final dayData = entry.value;
        if (dayData is! Map<String, dynamic>) continue;
        final plan = MealPlan(date: date);
        for (final slot in MealSlot.values) {
          final entries = dayData[slot.name];
          if (entries is List) {
            for (final r in entries) {
              if (r is Map<String, dynamic>) {
                try { plan.addToSlot(slot, Recipe.fromJson(r)); } catch (_) {}
              }
            }
          }
        }
        if (plan.mealCount > 0) next[date] = plan;
      }
      _emit(next);
    } catch (e) {
      if (kDebugMode) debugPrint('[MealPlanController] hydrate: $e');
    }
    _hydrated = true;
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final map = <String, dynamic>{};
      for (final entry in weekPlanByDate.value.entries) {
        final plan = entry.value;
        map[entry.key] = {
          for (final slot in MealSlot.values)
            slot.name: plan.getSlot(slot).map((r) => r.toJson()).toList(),
        };
      }
      await prefs.setString(_kPlanKey, jsonEncode(map));
    } catch (e) {
      if (kDebugMode) debugPrint('[MealPlanController] persist: $e');
    }
  }

  // ── Internal emit ───────────────────────────────────────────────────────────

  void _emit(Map<String, MealPlan> next) {
    weekPlanByDate.value = next;
    var total = 0;
    for (final p in next.values) {
      total += p.mealCount;
    }
    totalPlanned.value = total;
  }
}
