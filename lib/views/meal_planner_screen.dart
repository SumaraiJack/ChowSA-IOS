// lib/views/meal_planner_screen.dart
//
// Hybrid weekly meal planner:
//   • 7-day list overview (collapsed cards showing meal-count summary)
//   • Per-day expansion revealing Breakfast / Lunch / Dinner slots
//   • Empty slots → dashed-border "assign" tile (opens recipe picker)
//   • Filled slots → compact recipe row with avatar + title + clear button
//
// Persistence: SharedPreferences (key: meal_plan_v2)
// Saved-recipe source: SharedPreferences (key: saved_community_recipes_v1)

import 'dart:convert';
import 'dart:math' as math show Random, min;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';
import 'package:table_calendar/table_calendar.dart';

import '../services/inbox_share_service.dart';
import '../widgets/user_handle_autocomplete.dart';
import 'recipe_detail_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/ingredient.dart';
import '../models/meal_plan.dart';
import '../models/recipe.dart';
import '../services/recipe_repository.dart';
import '../services/shared_assets_service.dart';
import '../state/meal_plan_controller.dart';

// =============================================================================
// Design tokens
// =============================================================================

const _kForest = Color(0xFF0C351E);
const _kOrange = Color(0xFFE59B27);
const _kCream  = Color(0xFFF4F1EA);
const _kMuted  = Color(0xFF55534E);

// Avatar colour palette — assigned deterministically by recipe title hash.
const _kAvatarPalette = [
  Color(0xFF0C351E),
  Color(0xFFE59B27),
  Color(0xFF1565C0),
  Color(0xFF6A1B9A),
  Color(0xFF00838F),
  Color(0xFFF57F17),
  Color(0xFFC62828),
  Color(0xFF37474F),
];

Color _avatarColor(String title) =>
    _kAvatarPalette[title.hashCode.abs() % _kAvatarPalette.length];

String _initials(String title) {
  final words = title.trim().split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return '?';
  if (words.length == 1) {
    return words.first.substring(0, math.min(2, words.first.length)).toUpperCase();
  }
  return '${words[0][0]}${words[1][0]}'.toUpperCase();
}

// =============================================================================
// Persistence helpers
// =============================================================================

// v3: list-per-slot schema. Older v2 data (string-per-slot) is read once
// during migration in _loadAll() so existing users don't lose their plans.
const _kPlanKey    = 'meal_plan_v3';
const _kLegacyPlanKey = 'meal_plan_v2';
const _kSavedKey   = 'saved_community_recipes_v1';

// =============================================================================
// MealPlannerScreen
// =============================================================================

class MealPlannerScreen extends StatefulWidget {
  const MealPlannerScreen({
    super.key,
    this.incomingShare,
  });

  /// When the screen is opened from a "shared menu" notification, the
  /// caller passes the asset's payload here. _loadAll merges the shared
  /// `days` map into the user's local plan so the screen never lands on a
  /// blank week — that was the root cause of the "blank screen on open"
  /// report. Null for normal navigation.
  final Map<String, dynamic>? incomingShare;

  // ── Cross-screen reactive bus ──────────────────────────────────────────────
  // Total recipe options planned across the whole week is now owned by
  // MealPlanController.instance.totalPlanned — this getter forwards there
  // so legacy `ValueListenableBuilder<int>(valueListenable:
  // MealPlannerScreen.totalPlannedNotifier, ...)` callers still work and
  // get reactive updates from ANY surface that mutates the plan (Clear
  // Week, slot add/remove, shared-menu import, etc).
  static ValueNotifier<int> get totalPlannedNotifier =>
      MealPlanController.instance.totalPlanned;

  /// Forces a fresh totalPlanned recount from the controller. Kept for
  /// compat with route-return callbacks that previously refreshed from
  /// SharedPreferences directly.
  static Future<int> refreshTotalPlannedCount() =>
      MealPlanController.instance.refreshTotalPlannedCount();

  @override
  State<MealPlannerScreen> createState() => _MealPlannerScreenState();
}

class _MealPlannerScreenState extends State<MealPlannerScreen> {
  /// Plans keyed by ISO date ('YYYY-MM-DD'). Replaces the old per-
  /// weekday list — that schema made every Friday in the month share
  /// one row, which was the cause of the "edit Friday the 12th and it
  /// fills every Friday" bug.
  final Map<String, MealPlan> _plansByDate = <String, MealPlan>{};

  // Saved community recipe titles loaded from SharedPreferences.
  List<_QuickRecipe> _savedRecipes = [];
  bool _loaded = false;
  // Calendar view toggle — when on, a TableCalendar pins above the day
  // list. Tapping a date opens that day's plan in a bottom sheet. Dots
  // appear on dates whose day-of-week has any planned meals.
  bool _showCalendar = true; // start in calendar view per spec
  DateTime _focusedDay  = DateTime.now();
  DateTime _selectedDay = DateTime.now();
  /// First day of the visible week in list-view (Mon by default; flipped
  /// to Sun on devices whose locale uses Sun-start). Recomputed when a
  /// calendar date is tapped so the list focuses that week.
  late DateTime _visibleWeekStart = _startOfWeek(DateTime.now());

  /// ScrollController + per-day GlobalKeys so a tap on the calendar can
  /// auto-scroll the list view to the exact weekday card the user
  /// chose, instead of dropping them at the top of the week.
  final ScrollController _listCtrl = ScrollController();
  final List<GlobalKey>  _dayKeys  = List.generate(7, (_) => GlobalKey());
  int? _pendingScrollDayIndex;

  // ── Date helpers ────────────────────────────────────────────────────────

  static String _isoDate(DateTime d) {
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$y-$m-$day';
  }

  // The meal planner is locked to Monday-first for every user — both
  // Google Calendar and Samsung Calendar ship with Monday-as-week-start
  // by default and users expect the planner to mirror that. We
  // deliberately ignore [MaterialLocalizations.firstDayOfWeekIndex]
  // (which flips to Sunday on en-ZA / en-US locales) because there's no
  // clean way to read the user's actual calendar-app preference from
  // Flutter.

  DateTime _startOfWeek(DateTime d, {BuildContext? ctx}) {
    const firstWd = DateTime.monday;
    var offset = d.weekday - firstWd;
    if (offset < 0) offset += 7;
    return DateTime(d.year, d.month, d.day)
        .subtract(Duration(days: offset));
  }

  /// Ensures a plan row exists for the given ISO date and returns it.
  /// MUTATING — use only from add/remove/clear paths. Calendar dot
  /// rendering must use [_lookupPlan] to avoid bloating _plansByDate
  /// with phantom empty rows for every cell the calendar paints.
  MealPlan _planFor(String iso) =>
      _plansByDate.putIfAbsent(iso, () => MealPlan(date: iso));

  /// Pure read — returns null when no plan is bound to that exact ISO
  /// date. The calendar marker uses this so a dot can ONLY render when
  /// there's an explicit row keyed to that calendar cell's date string.
  /// No more "every Friday lights up because the cell builder mutated
  /// the map" leak.
  MealPlan? _lookupPlan(String iso) => _plansByDate[iso];

  /// Once-only flag — flipped on the first didChangeDependencies tick
  /// so we can re-anchor [_visibleWeekStart] to the locale-aware week
  /// start (Sun-first vs Mon-first). Without this re-anchor, "Clear
  /// week" clears Mon→Sun even when the calendar UI shows Sun→Sat,
  /// leaving the Sunday plan untouched. After the first run the user's
  /// own week navigation owns [_visibleWeekStart].
  bool _weekStartAnchored = false;

  /// Re-loads the picker list whenever the user adds/edits/deletes a
  /// recipe in My Recipes elsewhere in the app, so the next time they
  /// open the meal-planner picker the new recipe is already there.
  void _onMyRecipesChanged() {
    if (!mounted) return;
    _reloadPickerSources();
  }

  @override
  void initState() {
    super.initState();
    _loadAll();
    RecipeRepository.instance.updateNotifier.addListener(_onMyRecipesChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_weekStartAnchored) return;
    _weekStartAnchored = true;
    final anchored = _startOfWeek(DateTime.now(), ctx: context);
    if (anchored != _visibleWeekStart) {
      setState(() => _visibleWeekStart = anchored);
    }
  }

  @override
  void dispose() {
    RecipeRepository.instance.updateNotifier
        .removeListener(_onMyRecipesChanged);
    _listCtrl.dispose();
    super.dispose();
  }

  // ── Persistence ─────────────────────────────────────────────────────────────

  /// Decodes a single planned-slot entry from the persisted JSON. The
  /// schema evolves over time so we accept multiple shapes:
  ///   • bare title string                    (v4 and earlier)
  ///   • { 'title':..., 'sourceId':..., 'sourceType':... }   (v5+)
  /// Returns null when the entry is empty or malformed.
  Recipe? _decodePlannedEntry(dynamic raw) {
    if (raw is String) {
      final t = raw.trim();
      return t.isEmpty ? null : _stubRecipe(t);
    }
    if (raw is Map) {
      final t = (raw['title'] as String? ?? '').trim();
      if (t.isEmpty) return null;
      return _stubRecipe(
        t,
        sourceId:   raw['sourceId']   as String?,
        sourceType: raw['sourceType'] as String?,
      );
    }
    return null;
  }

  /// Rebuilds the picker list from BOTH sources:
  ///   1. The user's own saved recipes (My Recipes — Supabase, with
  ///      offline cache fallback inside the repository).
  ///   2. Community recipes the user bookmarked from the Community tab
  ///      (SharedPreferences — saved_community_recipes_v1).
  ///
  /// Earlier the picker only showed (2), so users with full My Recipes
  /// libraries still saw "No saved recipes yet" — confusing and made
  /// the planner feel disconnected from the rest of the app.
  Future<void> _reloadPickerSources({SharedPreferences? prefs}) async {
    final p = prefs ?? await SharedPreferences.getInstance();
    final picker     = <_QuickRecipe>[];
    final seenTitles = <String>{};

    try {
      final mine = await RecipeRepository.instance.loadAll();
      for (final r in mine) {
        final t = r.title.trim();
        if (t.isEmpty) continue;
        if (seenTitles.add(t.toLowerCase())) {
          picker.add(_QuickRecipe(
            title:    t,
            username: '',
            source:   _QuickRecipeSource.mine,
            sourceId: r.sourceId,
          ));
        }
      }
    } catch (_) {/* offline / signed-out — still show community list below */}

    final savedRaw = p.getString(_kSavedKey);
    if (savedRaw != null) {
      try {
        final list = jsonDecode(savedRaw) as List<dynamic>;
        for (final e in list) {
          final m = e as Map<String, dynamic>;
          final t = (m['recipeTitle'] as String? ?? '').trim();
          if (t.isEmpty) continue;
          if (!seenTitles.add(t.toLowerCase())) continue;
          picker.add(_QuickRecipe(
            title:    t,
            username: m['username'] as String? ?? '',
            source:   _QuickRecipeSource.community,
            sourceId: m['recipeId'] as String?,
          ));
        }
      } catch (_) {}
    }

    if (!mounted) return;
    setState(() => _savedRecipes = picker);
  }

  Future<void> _loadAll() async {
    final prefs = await SharedPreferences.getInstance();

    // ── Load meal plan (v3 list schema, fall back to legacy v2 single-string) ─
    final planRaw = prefs.getString(_kPlanKey)
        ?? prefs.getString(_kLegacyPlanKey);
    if (planRaw != null) {
      try {
        final map = jsonDecode(planRaw) as Map<String, dynamic>;
        // v4 (date-keyed) detection: keys look like 'YYYY-MM-DD'.
        // v2/v3 (weekday-keyed) keys are 'Monday'..'Sunday' — migrate
        // them onto THIS week's dates so existing users don't lose data.
        final isDateKeyed = map.keys.any((k) =>
            RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(k));
        if (isDateKeyed) {
          map.forEach((iso, dayData) {
            if (dayData is! Map) return;
            final plan = _planFor(iso);
            for (final slot in MealSlot.values) {
              final raw = dayData[slot.name];
              if (raw is List) {
                for (final entry in raw) {
                  final r = _decodePlannedEntry(entry);
                  if (r != null) plan.addToSlot(slot, r);
                }
              }
            }
          });
        } else {
          // Weekday-keyed (v2/v3): drop into THIS week's dates so the
          // existing entries surface immediately instead of going dark.
          final weekStart = _startOfWeek(DateTime.now());
          for (var i = 0; i < 7; i++) {
            final d   = weekStart.add(Duration(days: i));
            final iso = _isoDate(d);
            final dayName = const ['Monday','Tuesday','Wednesday','Thursday',
                                   'Friday','Saturday','Sunday'][d.weekday - 1];
            final dayData = map[dayName];
            if (dayData is! Map) continue;
            final plan = _planFor(iso);
            for (final slot in MealSlot.values) {
              final raw = dayData[slot.name];
              if (raw is List) {
                for (final entry in raw) {
                  final r = _decodePlannedEntry(entry);
                  if (r != null) plan.addToSlot(slot, r);
                }
              } else {
                final r = _decodePlannedEntry(raw);
                if (r != null) plan.addToSlot(slot, r);
              }
            }
          }
        }
      } catch (_) {}
    }

    // Picker sources (My Recipes + saved community recipes) — extracted
    // into [_reloadPickerSources] so the My-Recipes update notifier can
    // refresh them without re-running the full plan-load path.
    await _reloadPickerSources(prefs: prefs);

    // Merge an incoming shared menu (Issue A: blank screen on open). The
    // payload shape mirrors SharedAssetsService.sendMenu:
    //   { 'title': 'Week Plan', 'sender_handle': '@foo',
    //     'days': { 'Monday': { 'breakfast': ['Pap'], ... }, ... } }
    final incoming = widget.incomingShare;
    if (incoming != null) {
      final days = incoming['days'];
      if (days is Map) {
        // Incoming shares are still weekday-keyed (sender's UI). Land
        // them on THIS week's dates on the recipient side.
        final weekStart = _startOfWeek(DateTime.now());
        for (var i = 0; i < 7; i++) {
          final d   = weekStart.add(Duration(days: i));
          final iso = _isoDate(d);
          final dayName = const ['Monday','Tuesday','Wednesday','Thursday',
                                 'Friday','Saturday','Sunday'][d.weekday - 1];
          final dayData = days[dayName];
          if (dayData is! Map) continue;
          final plan = _planFor(iso);
          for (final slot in MealSlot.values) {
            final raw = dayData[slot.name];
            if (raw is List) {
              for (final entry in raw) {
                final r = _decodePlannedEntry(entry);
                if (r != null) plan.addToSlot(slot, r);
              }
            } else {
              final r = _decodePlannedEntry(raw);
              if (r != null) plan.addToSlot(slot, r);
            }
          }
        }
        await _savePlan();
      }
    }

    setState(() => _loaded = true);
    // Seed the cross-screen notifier with the freshly-loaded total.
    MealPlannerScreen.totalPlannedNotifier.value = _totalMeals;
  }

  Future<void> _savePlan() async {
    final prefs = await SharedPreferences.getInstance();
    // v5 (date-keyed + source-aware) schema — one row per ISO date.
    // Each slot holds a list of maps:
    //   { 'title': 'Boeber', 'sourceId': '<uuid>', 'sourceType': 'mine' }
    // Older v4 (list of bare title strings) is still readable by
    // [_loadAll] so existing users don't lose data. Empty days are
    // pruned to keep the JSON tight.
    final map = <String, dynamic>{};
    _plansByDate.forEach((iso, plan) {
      if (plan.isEmpty) return;
      map[iso] = {
        for (final s in MealSlot.values)
          s.name: plan.getSlot(s).map((r) => {
                'title':      r.title,
                if (r.sourceId   != null) 'sourceId':   r.sourceId,
                if (r.sourceType != null) 'sourceType': r.sourceType,
              }).toList(),
      };
    });
    await prefs.setString(_kPlanKey, jsonEncode(map));
    MealPlannerScreen.totalPlannedNotifier.value = _totalMeals;
  }

  // ── Slot actions (date-scoped) ──────────────────────────────────────

  Future<void> _addToSlotByDate(String iso, MealSlot slot) async {
    final plan = _planFor(iso);
    final picked = await showModalBottomSheet<Recipe>(
      context:            context,
      isScrollControlled: true,
      backgroundColor:    Colors.transparent,
      builder: (_) => _RecipePickerSheet(
        saved:                _savedRecipes,
        dayName:              plan.dayOfWeek,
        slot:                 slot,
        lastPlannedByTitle:   _lastPlannedByTitle(),
        currentWeekIsoDates:  _currentVisibleWeekIsoSet(),
      ),
    );
    if (!mounted || picked == null) return;
    setState(() => plan.addToSlot(slot, picked));
    _savePlan();
  }

  /// title (lower-cased) → most recent ISO date the user has planned
  /// it on. Used by the picker to show a "Last cooked Wed" / "Used
  /// this week" badge so favourites bubble up visually.
  Map<String, String> _lastPlannedByTitle() {
    final result = <String, String>{};
    for (final entry in _plansByDate.entries) {
      final iso  = entry.key;
      final plan = entry.value;
      for (final slot in MealSlot.values) {
        for (final r in plan.getSlot(slot)) {
          final key = r.title.toLowerCase();
          final prev = result[key];
          if (prev == null || iso.compareTo(prev) > 0) {
            result[key] = iso;
          }
        }
      }
    }
    return result;
  }

  Set<String> _currentVisibleWeekIsoSet() => {
        for (var i = 0; i < 7; i++)
          _isoDate(_visibleWeekStart.add(Duration(days: i))),
      };

  void _removeFromSlotByDate(String iso, MealSlot slot, int optionIndex) {
    setState(() => _planFor(iso).removeFromSlot(slot, optionIndex));
    _savePlan();
  }

  /// Clears ONLY the exact ISO date. Other instances of the same
  /// weekday across the month stay untouched.
  void _clearDayByDate(String iso) {
    setState(() => _plansByDate.remove(iso));
    _savePlan();
  }

  /// Clears every plan inside the currently visible week ONLY — the
  /// seven ISO dates between _visibleWeekStart and +6 days. Plans on
  /// Opens the recipe detail screen for a planned-meal tile when we
  /// have a sourceId to hydrate against. Custom-typed meals (no id)
  /// fall back to a SnackBar nudge instead of pushing a half-empty
  /// detail screen — the user typed the name themselves, the planner
  /// has nothing to add.
  Future<void> _openPlannedRecipe(Recipe r) async {
    if (r.sourceId == null || r.sourceType != 'mine') {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Custom meal — no full recipe to open. Add "${r.title}" to '
            'My Recipes from the picker or My Recipes tab.',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    final full = await RecipeRepository.instance.getById(r.sourceId!);
    if (!mounted) return;
    if (full == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('That recipe was removed from My Recipes.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RecipeDetailScreen(recipe: full),
      ),
    );
  }

  /// other weeks remain intact.
  void _clearAll() {
    showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title:   const Text('Clear this week?'),
        content: const Text('Only the 7 days of the current week '
                            'will be emptied — other weeks stay safe.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child:     const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Clear week'),
          ),
        ],
      ),
    ).then((ok) {
      if (ok == true && mounted) {
        setState(() {
          for (var i = 0; i < 7; i++) {
            _plansByDate.remove(
                _isoDate(_visibleWeekStart.add(Duration(days: i))));
          }
        });
        _savePlan();
      }
    });
  }

  int get _totalMeals => _plansByDate.values.fold(0, (s, p) => s + p.mealCount);

  /// The 7 plans currently shown in list view — derived on the fly from
  /// _visibleWeekStart so any tap-from-calendar lands the user on the
  /// week containing that date.
  List<MealPlan> get _visibleWeekPlans => [
        for (var i = 0; i < 7; i++)
          _planFor(_isoDate(_visibleWeekStart.add(Duration(days: i)))),
      ];

  // ── Share helpers ───────────────────────────────────────────────────────────

  /// Pretty-printed text block for the whole week, used by share_plus.
  // ── Calendar view ──────────────────────────────────────────────────────
  /// Two-tier marker: 2 = fully planned (green), 1 = partial (blue),
  /// no marker for unplanned dates. STRICTLY date-keyed: the lookup is
  /// pure (no putIfAbsent), and the marker only renders when there's an
  /// explicit `_plansByDate` entry for THAT exact ISO date string.
  List<int> _eventsForDate(DateTime d) {
    final p = _lookupPlan(_isoDate(d));
    if (p == null || p.isEmpty) return const [];
    return [p.isFullyPlanned ? 2 : 1];
  }

  Widget _buildCalendarView() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 24),
      children: [
        Material(
          elevation:   1,
          color:        _kCream,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: TableCalendar<int>(
              firstDay:  DateTime.utc(2024, 1, 1),
              lastDay:   DateTime.utc(2030, 12, 31),
              focusedDay: _focusedDay,
              // Locked to Monday-first so the meal planner mirrors
              // Google Calendar / Samsung Calendar defaults — see
              // _firstWeekdayFromLocale for the rationale.
              startingDayOfWeek: StartingDayOfWeek.monday,
              selectedDayPredicate: (d) => isSameDay(d, _selectedDay),
              eventLoader: _eventsForDate,
              calendarStyle: const CalendarStyle(
                todayDecoration:    BoxDecoration(
                    color: Color(0xFFFFE0B2), shape: BoxShape.circle),
                todayTextStyle:     TextStyle(
                    color: _kForest, fontWeight: FontWeight.w900),
                selectedDecoration: BoxDecoration(
                    color: _kForest, shape: BoxShape.circle),
              ),
              calendarBuilders: CalendarBuilders<int>(
                // Two-tier gesture per spec: SINGLE tap silently moves
                // the selection highlight, DOUBLE tap jumps to the
                // 7-day list view for that week. Long-press is wired
                // separately as an a11y-friendly alias for the jump.
                defaultBuilder: (ctx, day, focused) =>
                    _CalendarCell(
                      day:        day,
                      isToday:    isSameDay(day, DateTime.now()),
                      isSelected: isSameDay(day, _selectedDay),
                      isFaded:    day.month != focused.month,
                      onTap:      () => setState(() {
                        _selectedDay = day;
                        _focusedDay  = focused;
                      }),
                      onDoubleTap: () => _jumpToWeekListFor(day, focused),
                    ),
                selectedBuilder: (ctx, day, focused) => _CalendarCell(
                  day: day, isToday: false, isSelected: true, isFaded: false,
                  onTap:       () {},
                  onDoubleTap: () => _jumpToWeekListFor(day, focused),
                ),
                todayBuilder: (ctx, day, focused) => _CalendarCell(
                  day: day, isToday: true,
                  isSelected: isSameDay(day, _selectedDay), isFaded: false,
                  onTap:       () => setState(() {
                    _selectedDay = day;
                    _focusedDay  = focused;
                  }),
                  onDoubleTap: () => _jumpToWeekListFor(day, focused),
                ),
                // STRICT date-keyed marker. `events` here came from
                // _eventsForDate, which uses _lookupPlan (pure read,
                // no putIfAbsent), so an empty list means there is NO
                // plan bound to that exact cell date and no dot is
                // drawn — Friday the 12th's data can never bleed onto
                // the 5th / 19th / 26th anymore.
                markerBuilder: (ctx, day, events) {
                  if (events.isEmpty) return const SizedBox.shrink();
                  final isFull = events.first == 2;
                  return Padding(
                    padding: const EdgeInsets.only(top: 28),
                    child: Container(
                      width: 6, height: 6,
                      decoration: BoxDecoration(
                        color: isFull
                            ? const Color(0xFF4CAF50) // green — full day
                            : const Color(0xFF2196F3), // blue — incomplete
                        shape: BoxShape.circle,
                      ),
                    ),
                  );
                },
              ),
              headerStyle: const HeaderStyle(
                formatButtonVisible: false,
                titleCentered:       true,
                titleTextStyle: TextStyle(
                    fontWeight: FontWeight.w900, color: _kForest),
              ),
              // SINGLE tap → silently move the selection highlight to
              // the tapped date. No route change, no scroll. Lets the
              // user pick a day, then quick-add via the Inspo cards.
              onDaySelected: (selected, focused) {
                setState(() {
                  _selectedDay = selected;
                  _focusedDay  = focused;
                });
              },
              // DOUBLE tap (no native double-tap hook on TableCalendar
              // — long-press doubles as the intentful "jump" gesture
              // alongside the dayBuilder GestureDetector below).
              onDayLongPressed: (selected, focused) =>
                  _jumpToWeekListFor(selected, focused),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "Double tap any date to view or edit the meals planned for "
                "that day's slot. Blue dots indicate incomplete days; "
                'Green dots indicate a full day planned.',
                style: TextStyle(
                  fontSize: 12,
                  color:    Colors.grey.shade700,
                  height:   1.4,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: const [
                  _LegendDot(color: Color(0xFF2196F3), label: 'Incomplete day'),
                  SizedBox(width: 16),
                  _LegendDot(color: Color(0xFF4CAF50), label: 'Full day planned'),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 22),
        // ── Quick Weekly Inspo carousel ────────────────────────────────
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'Quick Weekly Inspo 💡',
            style: TextStyle(
              fontSize:   18,
              fontWeight: FontWeight.w900,
              color:      _kForest,
            ),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 170,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: _hourlyInspoPicks().length,
            itemBuilder: (_, i) {
              final card = _hourlyInspoPicks()[i];
              return _InspoCard(
                title:    card.title,
                subtitle: card.subtitle,
                icon:     card.icon,
                accent:   card.accent,
                onAdd:    () => _quickAddInspoToSelectedDay(card.title),
                onTapBody: () => _openInspoDetail(card),
              );
            },
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  /// Shared "double-tap / long-press" handler — snaps the visible week
  /// to [d], queues the auto-scroll, and flips to the list view.
  void _jumpToWeekListFor(DateTime selected, DateTime focused) {
    final weekStart = _startOfWeek(selected, ctx: context);
    final dayOffset = selected.difference(weekStart).inDays.clamp(0, 6);
    setState(() {
      _selectedDay           = selected;
      _focusedDay            = focused;
      _visibleWeekStart      = weekStart;
      _pendingScrollDayIndex = dayOffset;
      _showCalendar          = false;
    });
  }

  // ── Quick Weekly Inspo: data pool + hourly rotation ──────────────────
  //
  // 30+ SA-flavoured "inspo" recipes — Soweto street, Karoo comfort,
  // West Coast seafood, township staples, Cape Malay sweets,
  // load-shedding survival, and a few wild-card chef plays. Curated so
  // it does NOT duplicate the Home "Seasonal in SA" carousel
  // (Bobotie, Cape Malay Curry, Malva Pudding, Roosterkoek, Snoek with
  // Apricot Glaze, Sosaties, etc.) — the planner inspo is its own
  // distinct rotation, not a copy of what the user already sees on
  // Home. The visible 4 cards are picked deterministically from this
  // pool by a time-seeded shuffle whose seed changes every 3 hours
  // — endless visual variety without any DB reads.
  static const List<_InspoSeed> _kInspoPool = [
    _InspoSeed(
      title: 'Soweto Kota', subtitle: 'Loaded quarter-loaf',
      icon: '🥪', accent: Color(0xFF6A1B9A),
      ingredients: [
        '1 white loaf, quartered, soft middle scooped',
        '4 Russian sausages, halved',
        '4 slices polony, 4 slices cheese',
        '4 fried eggs, chips, atchar',
        'Tomato sauce, chilli sauce',
      ],
      instructions: [
        'Toast the bread quarter shells lightly.',
        'Fry Russians, polony and eggs on a hot pan.',
        'Layer chips, Russians, polony, cheese, egg and atchar inside.',
        'Top with both sauces and close with the bread lid.',
      ],
    ),
    _InspoSeed(
      title: 'Winter Mince Pot', subtitle: 'Slow-cooked comfort',
      icon: '🍲', accent: Color(0xFF1565C0),
      ingredients: [
        '500 g beef mince',
        '1 onion, 2 garlic cloves',
        '1 tin chopped tomatoes',
        '2 carrots and 2 potatoes, diced',
        '1 cup beef stock, 1 tbsp Worcestershire',
      ],
      instructions: [
        'Brown the mince in a heavy pot; drain excess fat.',
        'Soften onion and garlic, then return mince to the pot.',
        'Add tomatoes, veg, stock and Worcestershire.',
        'Simmer covered 45 min until veg are tender; season and serve on rice.',
      ],
    ),
    _InspoSeed(
      title: 'Loadshedding Wraps', subtitle: '15-min flame-free',
      icon: '⚡', accent: Color(0xFF2E7D32),
      ingredients: [
        '4 wraps, 1 tin tuna or chickpeas',
        '1 avo, sliced',
        '1 cup grated cheddar',
        '½ cup mayo, 1 tbsp lemon juice',
        'Lettuce, tomato',
      ],
      instructions: [
        'Mix tuna or chickpeas with mayo and lemon juice.',
        'Lay lettuce on the wrap, then tuna mix, avo, tomato and cheese.',
        'Roll tight, slice in half on the diagonal.',
        'No-cook — perfect when the power is off.',
      ],
    ),
    _InspoSeed(
      title: 'Karoo Lamb Roast', subtitle: 'Sunday roast feels',
      icon: '🐑', accent: Color(0xFF8E2D2D),
      ingredients: [
        '1.5 kg lamb leg',
        '4 garlic cloves, slivered',
        '2 tbsp olive oil, 2 sprigs rosemary',
        '1 cup red wine, 1 cup stock',
        'Salt, black pepper',
      ],
      instructions: [
        'Preheat oven to 200 °C.',
        'Pierce the lamb and stud with garlic; rub with oil, rosemary, salt.',
        'Roast 20 min, drop to 160 °C, pour wine and stock in the pan.',
        'Roast 1.5–2 hours basting every 30 min; rest 15 min before carving.',
      ],
    ),
    _InspoSeed(
      title: 'Durban Bunny Chow', subtitle: 'KZN classic',
      icon: '🍞', accent: Color(0xFFE65100),
      ingredients: [
        '1 white loaf, halved and hollowed',
        '500 g lamb or chicken, cubed',
        '2 onions, 3 garlic cloves',
        '2 tbsp Durban masala, 2 potatoes',
        '1 tin tomatoes, fresh coriander',
      ],
      instructions: [
        'Brown the meat; set aside.',
        'Soften onions and garlic, add masala, toast briefly.',
        'Return meat with potatoes and tomatoes; simmer 45 min.',
        'Spoon curry into the hollowed bread, top with coriander.',
      ],
    ),
    _InspoSeed(
      title: 'West Coast Prawns', subtitle: 'Garlic & lemon',
      icon: '🦐', accent: Color(0xFF00838F),
      ingredients: [
        '500 g prawns, peeled',
        '4 garlic cloves, crushed',
        '50 g butter, juice of 1 lemon',
        '¼ cup white wine',
        'Parsley, salt, chilli flakes',
      ],
      instructions: [
        'Melt butter, soften garlic and chilli 30 seconds.',
        'Add prawns; toss 2 min until pink.',
        'Deglaze with wine and lemon juice.',
        'Stir in parsley; serve with crusty bread.',
      ],
    ),
    _InspoSeed(
      title: 'Boerie Rolls', subtitle: 'Stadium-day quick eats',
      icon: '🌭', accent: Color(0xFFEF6C00),
      ingredients: [
        '4 boerewors lengths',
        '4 hotdog rolls',
        '2 onions, sliced',
        'Tomato chutney, mustard',
        'Oil, salt',
      ],
      instructions: [
        'Braai or pan-fry boerewors over medium heat 12 min, turning.',
        'Caramelise onions in a pan with a pinch of salt.',
        'Toast rolls cut-side down.',
        'Slot wors in, top with onions, chutney and mustard.',
      ],
    ),
    _InspoSeed(
      title: 'Pap & Wors', subtitle: 'Pap, sous & wors',
      icon: '🌽', accent: Color(0xFFFBC02D),
      ingredients: [
        '2 cups maize meal',
        '4 cups water, 1 tsp salt',
        '500 g boerewors',
        '4 tomatoes, 1 onion (for sous)',
        '1 chilli, 2 tbsp oil',
      ],
      instructions: [
        'Boil salted water; rain in maize meal, stir, cover, cook 30 min.',
        'Fry onion and chilli; add chopped tomato and simmer 15 min for sous.',
        'Braai or pan-fry boerewors 12 min, turning.',
        'Plate pap, slice wors over the top, ladle tomato sous beside.',
      ],
    ),
    _InspoSeed(
      title: 'Springbok Steaks', subtitle: 'Wild & smoky',
      icon: '🦌', accent: Color(0xFF4E342E),
      ingredients: [
        '4 springbok loin steaks',
        '2 tbsp olive oil, 2 sprigs thyme',
        '4 garlic cloves, smashed',
        '50 g butter',
        'Salt, coarse black pepper',
      ],
      instructions: [
        'Rub steaks with oil, salt and pepper; rest 20 min.',
        'Sear over hot coals or in a cast-iron pan 2 min each side.',
        'Add butter, garlic and thyme; baste 1 min more.',
        'Rest 5 min; slice across the grain.',
      ],
    ),
    _InspoSeed(
      title: 'Sunday Potjie', subtitle: 'Three-leg slow magic',
      icon: '🫕', accent: Color(0xFF6D4C41),
      ingredients: [
        '1 kg stewing beef',
        '2 onions, 4 carrots',
        '4 potatoes, 1 cup green beans',
        '2 cups beef stock, 1 tbsp tomato paste',
        '2 tsp potjie spice, bay leaves',
      ],
      instructions: [
        'Brown the meat in the potjie over hot coals.',
        'Layer onions, carrots, potatoes, beans — do not stir.',
        'Pour stock and tomato paste over the top with bay leaves and spice.',
        'Cover and simmer 3 hours over low coals; season at the end.',
      ],
    ),
    _InspoSeed(
      title: 'Joburg Brunch', subtitle: 'Eggs, pap & avo',
      icon: '🍳', accent: Color(0xFFF57C00),
      ingredients: [
        '4 eggs, 1 cup leftover pap',
        '1 avo, 2 tomatoes',
        '4 rashers bacon',
        'Butter, salt, pepper',
      ],
      instructions: [
        'Pan-fry bacon until crisp; set aside.',
        'Cut pap into slabs and pan-fry in bacon fat until golden.',
        'Fry eggs to your liking; warm tomatoes in the pan.',
        'Plate pap slabs, top with egg, bacon, sliced avo and tomato.',
      ],
    ),
    _InspoSeed(
      title: 'Karoo Veggie Bake', subtitle: 'Roasted & rustic',
      icon: '🥕', accent: Color(0xFFAD1457),
      ingredients: [
        '2 sweet potatoes, 2 carrots',
        '1 butternut, 1 red onion',
        '4 garlic cloves, 2 tbsp olive oil',
        '1 tbsp honey, 1 tsp paprika',
        'Feta, fresh rosemary',
      ],
      instructions: [
        'Preheat oven to 200 °C; chop veg into bite-sized chunks.',
        'Toss with oil, honey, paprika, rosemary, garlic, salt.',
        'Roast 35–40 min, tossing once, until edges caramelise.',
        'Scatter crumbled feta over the top to serve.',
      ],
    ),
    _InspoSeed(
      title: 'Braai Salad', subtitle: 'Fresh side hero',
      icon: '🥗', accent: Color(0xFF558B2F),
      ingredients: [
        '4 cups mixed leaves',
        '2 tomatoes, 1 cucumber',
        '½ red onion, ½ cup feta',
        '¼ cup olive oil, 2 tbsp lemon juice',
        '1 tsp honey, salt, pepper',
      ],
      instructions: [
        'Tear leaves into a big bowl.',
        'Chop tomato, cucumber and onion; scatter over leaves.',
        'Whisk oil, lemon, honey, salt and pepper for the dressing.',
        'Toss the salad with dressing and crumbled feta.',
      ],
    ),
    _InspoSeed(
      title: 'Springbokkie Dessert', subtitle: 'Mint + Amarula treat',
      icon: '🍮', accent: Color(0xFF7B1FA2),
      ingredients: [
        '4 scoops vanilla ice cream',
        '¼ cup peppermint liqueur',
        '¼ cup Amarula',
        'Chocolate shavings',
      ],
      instructions: [
        'Scoop ice cream into 4 short glasses.',
        'Pour 1 tbsp peppermint liqueur over each scoop.',
        'Top with 1 tbsp Amarula — let it sit on top.',
        'Garnish with chocolate shavings and serve immediately.',
      ],
    ),
    _InspoSeed(
      title: 'Cheesy Pap Tert', subtitle: 'Smoky cheese pap bake',
      icon: '🧀', accent: Color(0xFFF9A825),
      ingredients: [
        '3 cups cooked stiff pap',
        '2 cups grated cheddar',
        '1 cup cream',
        '2 eggs, 1 tsp smoked paprika',
        'Salt, pepper',
      ],
      instructions: [
        'Preheat oven to 180 °C; grease a dish.',
        'Whisk eggs, cream, paprika, salt and pepper.',
        'Layer pap and cheese in the dish; pour egg mixture over.',
        'Bake 30 min until set and golden on top.',
      ],
    ),
    _InspoSeed(
      title: 'Chuck Steak Stew', subtitle: 'Old-school slow simmer',
      icon: '🍖', accent: Color(0xFF5D4037),
      ingredients: [
        '800 g chuck steak, cubed',
        '2 onions, 3 garlic cloves',
        '2 tbsp flour, 2 cups beef stock',
        '1 cup red wine',
        '3 carrots, 2 sprigs thyme, bay leaves',
      ],
      instructions: [
        'Dust steak in flour; brown in a heavy pot.',
        'Soften onions and garlic in the same pot.',
        'Deglaze with wine; add stock, carrots, thyme and bay.',
        'Simmer covered 2 hours until the meat is fork-tender.',
      ],
    ),

    // ── New batch — distinctly local, no overlap with Home Seasonal ──
    _InspoSeed(
      title: 'Vetkoek & Mince', subtitle: 'Golden fried bread + curry mince',
      icon: '🥯', accent: Color(0xFFD2691E),
      ingredients: [
        '4 cups cake flour, 1 sachet yeast',
        '1 tbsp sugar, 1 tsp salt, 2 cups warm water',
        'Oil for deep-frying',
        '500 g beef mince, 1 onion',
        '2 tbsp mild curry powder, 1 tin tomatoes',
      ],
      instructions: [
        'Mix flour, yeast, sugar, salt and water; prove 1 hour.',
        'Form 8 dough balls; deep-fry 3–4 min per side until golden.',
        'Soften onion, add curry powder, then mince and tomatoes.',
        'Split each vetkoek and spoon the mince inside.',
      ],
    ),
    _InspoSeed(
      title: 'Chicken Livers Peri-Peri',
      subtitle: 'Portuguese SA, 15 min flat',
      icon: '🌶', accent: Color(0xFFC62828),
      ingredients: [
        '500 g chicken livers, trimmed',
        '4 garlic cloves, 1 onion',
        '2 tbsp peri-peri sauce',
        '1 tin chopped tomatoes',
        '50 g butter, fresh bread to serve',
      ],
      instructions: [
        'Soften onion and garlic in butter.',
        'Add livers, sear 2 min, add peri-peri and tomatoes.',
        'Simmer 6–8 min until livers are just cooked.',
        'Serve hot in a sizzling pan with bread for mopping.',
      ],
    ),
    _InspoSeed(
      title: 'Trinchado', subtitle: 'Garlicky Portuguese-SA beef',
      icon: '🥩', accent: Color(0xFF5D4037),
      ingredients: [
        '600 g rump or fillet, cubed',
        '6 garlic cloves, minced',
        '2 tbsp paprika, 1 tsp chilli flakes',
        '1 cup red wine, 1 tbsp tomato paste',
        '50 g butter, parsley',
      ],
      instructions: [
        'Sear beef hot and hard in butter; remove to a plate.',
        'Soften garlic, paprika and chilli in the pan.',
        'Deglaze with wine; stir in tomato paste; reduce 5 min.',
        'Return beef, simmer 3 min; finish with parsley.',
      ],
    ),
    _InspoSeed(
      title: 'Frikkadelle', subtitle: 'Ouma-style meatballs',
      icon: '🍝', accent: Color(0xFFA1887F),
      ingredients: [
        '500 g beef mince',
        '1 onion, finely chopped',
        '1 slice bread soaked in ¼ cup milk',
        '1 egg, ½ tsp ground coriander, ¼ tsp nutmeg',
        '2 tbsp oil, salt and pepper',
      ],
      instructions: [
        'Mix mince, onion, soaked bread, egg, spices, salt and pepper.',
        'Roll into 12 balls; rest 10 min for the flavours to settle.',
        'Brown in oil 2 min per side, then cover and steam-fry 8 min.',
        'Serve with mash and tomato bredie sauce.',
      ],
    ),
    _InspoSeed(
      title: 'Yellow Rice & Raisins', subtitle: 'Geelrys met rosyne',
      icon: '🍚', accent: Color(0xFFFBC02D),
      ingredients: [
        '2 cups basmati rice',
        '1 tsp turmeric, 1 stick cinnamon',
        '½ cup raisins, 1 tbsp sugar',
        '3 cups water, 1 tsp salt, 1 tbsp butter',
      ],
      instructions: [
        'Rinse rice until water runs clear.',
        'Bring water, turmeric, cinnamon, sugar, salt and butter to a boil.',
        'Add rice and raisins; cover and simmer 18 min on low.',
        'Off heat, rest covered 5 min, then fluff with a fork.',
      ],
    ),
    _InspoSeed(
      title: 'Tomato & Onion Smoor',
      subtitle: 'Cape kitchen go-to side',
      icon: '🍅', accent: Color(0xFFE53935),
      ingredients: [
        '6 ripe tomatoes, chopped',
        '2 onions, sliced',
        '2 tbsp oil, 1 chilli (optional)',
        '1 tsp sugar, 1 tsp salt, black pepper',
      ],
      instructions: [
        'Soften onions in oil 6 min until translucent.',
        'Add tomatoes, sugar, salt, pepper and chilli.',
        'Simmer 20 min until thick and jammy.',
        'Serve over pap, rice, eggs or with grilled chops.',
      ],
    ),
    _InspoSeed(
      title: 'Mealie Bread', subtitle: 'Steamed sweetcorn loaf',
      icon: '🌽', accent: Color(0xFFFFA000),
      ingredients: [
        '2 cups fresh sweetcorn kernels',
        '1 cup self-raising flour',
        '2 eggs, ½ cup milk',
        '2 tbsp melted butter, 1 tsp salt, 1 tbsp sugar',
      ],
      instructions: [
        'Pulse corn briefly in a blender — keep it chunky.',
        'Fold in flour, eggs, milk, butter, sugar and salt.',
        'Pour into a greased loaf tin; cover tightly with foil.',
        'Steam over simmering water 1 hr 15 min until set.',
      ],
    ),
    _InspoSeed(
      title: 'Boerie Pasta', subtitle: 'Wors + cream + pap-style pasta',
      icon: '🍝', accent: Color(0xFFFF7043),
      ingredients: [
        '400 g penne or fusilli',
        '500 g boerewors, casings off',
        '1 onion, 3 garlic cloves',
        '1 cup cream, ½ cup chutney',
        '1 tsp smoked paprika, fresh basil',
      ],
      instructions: [
        'Boil pasta until al dente; reserve ½ cup water.',
        'Brown wors meat in chunks; soften onion and garlic.',
        'Stir in cream, chutney and paprika; loosen with pasta water.',
        'Toss with pasta; finish with torn basil.',
      ],
    ),
    _InspoSeed(
      title: 'Knysna Mussel Pot',
      subtitle: 'Garlic, wine and warm bread',
      icon: '🦪', accent: Color(0xFF00838F),
      ingredients: [
        '1 kg fresh mussels, scrubbed',
        '4 garlic cloves, 1 shallot',
        '1 cup white wine',
        '50 g butter, parsley',
        'Crusty bread, lemon wedges',
      ],
      instructions: [
        'Discard any mussels that stay open before cooking.',
        'Soften shallot and garlic in butter 2 min.',
        'Add wine; tip in mussels; cover and steam 4–5 min.',
        'Discard any unopened mussels; scatter parsley; serve with bread.',
      ],
    ),
    _InspoSeed(
      title: 'Skilpadjies', subtitle: 'Caul-wrapped lamb liver',
      icon: '🔥', accent: Color(0xFF8E2D2D),
      ingredients: [
        '400 g lamb liver, diced',
        '200 g caul fat (netvet), rinsed',
        '1 onion, 2 tbsp Worcestershire',
        '1 tsp salt, black pepper, pinch nutmeg',
      ],
      instructions: [
        'Mix liver, onion, Worcestershire, salt, pepper and nutmeg.',
        'Cut caul fat into 10 cm squares.',
        'Spoon liver mix onto each square; wrap into parcels.',
        'Braai over medium coals 6–8 min per side until just set.',
      ],
    ),
    _InspoSeed(
      title: 'Boerewors Burger', subtitle: 'Stadium-night stack',
      icon: '🍔', accent: Color(0xFFEF6C00),
      ingredients: [
        '500 g boerewors, casings off',
        '4 brioche buns',
        '1 onion, sliced; 4 cheddar slices',
        'Tomato chutney, mustard, gherkins',
        'Lettuce, tomato',
      ],
      instructions: [
        'Form wors meat into 4 thick patties; rest 10 min.',
        'Sear 3 min per side; melt cheese on top in the last minute.',
        'Toast bun cut-side down; caramelise onions in pan juices.',
        'Stack lettuce, patty, onion, gherkin, chutney and mustard.',
      ],
    ),
    _InspoSeed(
      title: 'Rooibos Marinated Chicken',
      subtitle: 'SA-pantry weeknight roast',
      icon: '🫖', accent: Color(0xFFBF360C),
      ingredients: [
        '4 chicken thighs',
        '2 strong rooibos teabags brewed in ½ cup hot water',
        '2 tbsp honey, 2 tbsp soy sauce',
        '2 garlic cloves, 1 tsp ginger',
        '1 tbsp oil',
      ],
      instructions: [
        'Whisk rooibos brew, honey, soy, garlic, ginger and oil.',
        'Marinate chicken at least 1 hour, ideally overnight.',
        'Sear thighs skin-side down 5 min until crisp.',
        'Roast 200 °C for 20 min, basting with the marinade once.',
      ],
    ),
    _InspoSeed(
      title: 'Atchar Bowl', subtitle: 'Mango atchar, beans & rice',
      icon: '🥭', accent: Color(0xFFFFB300),
      ingredients: [
        '2 cups cooked basmati rice',
        '1 tin sugar beans, drained',
        '½ cup mango atchar',
        '1 tomato, 1 cucumber, 2 spring onions',
        'Plain yoghurt, fresh coriander',
      ],
      instructions: [
        'Warm beans in a pan with a splash of water and salt.',
        'Dice tomato, cucumber and spring onions.',
        'Plate rice; top with beans, atchar and the chopped salad.',
        'Drizzle yoghurt and scatter coriander to finish.',
      ],
    ),
    _InspoSeed(
      title: 'Amarula Dom Pedro',
      subtitle: 'After-dinner SA classic',
      icon: '🥃', accent: Color(0xFF6D4C41),
      ingredients: [
        '4 scoops vanilla ice cream',
        '½ cup Amarula cream',
        '¼ cup whisky (optional)',
        '¼ cup milk',
        'Chocolate shavings',
      ],
      instructions: [
        'Blend ice cream, Amarula, whisky and milk until thick.',
        'Pour into two short tumblers.',
        'Top with chocolate shavings.',
        'Serve immediately — straw and spoon both.',
      ],
    ),
    _InspoSeed(
      title: 'Rooibos Crème Brûlée',
      subtitle: 'Local twist on a French classic',
      icon: '🍮', accent: Color(0xFFD84315),
      ingredients: [
        '500 ml cream',
        '3 rooibos teabags',
        '5 egg yolks, ½ cup sugar (plus extra for the top)',
        '1 tsp vanilla extract',
      ],
      instructions: [
        'Heat cream with rooibos teabags 5 min; remove bags.',
        'Whisk yolks, sugar and vanilla; temper with the cream.',
        'Pour into ramekins; bake in a water bath 160 °C for 35 min.',
        'Chill, dust with sugar, and torch until crackly.',
      ],
    ),
    _InspoSeed(
      title: 'Cape Curried Eggs',
      subtitle: '20-min Cape Malay snack',
      icon: '🥚', accent: Color(0xFFEF6C00),
      ingredients: [
        '6 hard-boiled eggs, halved',
        '1 onion, 1 garlic clove',
        '1 tbsp Cape Malay curry powder',
        '½ cup mayo, 2 tbsp chutney',
        'Fresh coriander',
      ],
      instructions: [
        'Soften onion and garlic; toast curry powder 1 min.',
        'Cool, then fold into mayo and chutney.',
        'Pipe or spoon the curry mayo onto each egg half.',
        'Top with coriander; serve as a starter or in sarmies.',
      ],
    ),
    _InspoSeed(
      title: 'Pap Pizza', subtitle: 'Crispy pap base, braai toppings',
      icon: '🍕', accent: Color(0xFFF9A825),
      ingredients: [
        '3 cups cooked stiff pap',
        '1 cup grated mozzarella',
        '½ cup tomato passata',
        'Leftover braai meat, sliced',
        'Red onion, fresh basil, olive oil',
      ],
      instructions: [
        'Press pap into a flat round on a hot oiled pan.',
        'Fry 4 min until crisp; flip and fry 3 min more.',
        'Spread passata, top with cheese, meat and onion.',
        'Slide into a hot oven 5 min until cheese bubbles; finish with basil.',
      ],
    ),
    _InspoSeed(
      title: 'Hertzoggies', subtitle: 'Jam-and-coconut tartlets',
      icon: '🥥', accent: Color(0xFFE91E63),
      ingredients: [
        '1 cup cake flour, 100 g butter, ¼ cup sugar',
        '1 egg yolk, 2 tbsp cold water',
        'Apricot jam',
        '2 egg whites, ½ cup sugar, 1 cup desiccated coconut',
      ],
      instructions: [
        'Rub flour, butter and sugar; bind with yolk and water.',
        'Press into a mini muffin tin; spoon a tsp jam into each.',
        'Whisk whites and sugar to soft peaks; fold in coconut.',
        'Top each tart; bake 180 °C for 15 min until golden.',
      ],
    ),
    _InspoSeed(
      title: 'Coconut Milk Tert',
      subtitle: 'Tropical twist on melktert',
      icon: '🥧', accent: Color(0xFFE65100),
      ingredients: [
        '1 cooked tart shell',
        '500 ml coconut milk, 250 ml milk',
        '¼ cup cornflour, ½ cup sugar',
        '2 egg yolks, 1 tsp vanilla',
        'Cinnamon for dusting',
      ],
      instructions: [
        'Whisk yolks, sugar, cornflour with a splash of milk.',
        'Heat both milks until steaming; whisk in the slurry.',
        'Cook 5 min stirring until thick; add vanilla.',
        'Pour into the shell, chill 3 hrs, dust with cinnamon.',
      ],
    ),
    _InspoSeed(
      title: 'Morogo & Mash',
      subtitle: 'Wild spinach over creamy mash',
      icon: '🥬', accent: Color(0xFF388E3C),
      ingredients: [
        '4 cups fresh morogo (or spinach), chopped',
        '1 onion, 1 tomato',
        '1 tbsp oil, 1 tsp salt',
        '4 potatoes, ½ cup milk, 2 tbsp butter',
      ],
      instructions: [
        'Boil potatoes 18 min; mash with milk, butter and salt.',
        'Soften onion in oil; add tomato and morogo.',
        'Cover and steam 8 min until greens are tender.',
        'Spoon morogo over a mound of mash.',
      ],
    ),
  ];

  /// 3-hour-rotated subset of 4 cards. Seed = (epoch ÷ 3 hours) so the
  /// permutation stays stable for the whole 3-hour bucket across the
  /// app, then flips to a fresh set of 4 ideas. Eight refreshes per
  /// day keeps the panel feeling alive without churning the cards so
  /// fast that the user loses something they wanted to come back to.
  List<_InspoSeed> _hourlyInspoPicks() {
    final epochHours = DateTime.now().millisecondsSinceEpoch ~/ 3600000;
    final bucket     = epochHours ~/ 3;
    final rng        = math.Random(bucket);
    final pool       = List<_InspoSeed>.from(_kInspoPool)..shuffle(rng);
    return pool.take(4).toList(growable: false);
  }

  /// Pushes the full recipe detail (with Save-to-My-Recipes built in)
  /// using the seed's real ingredient + instruction lists. The
  /// RecipeDetailScreen save action persists into the user's library so
  /// inspo cards become real recipes, not stubs.
  void _openInspoDetail(_InspoSeed seed) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RecipeDetailScreen(
          recipe: Recipe(
            title:        seed.title,
            ingredients:  seed.ingredients
                .map((line) => Ingredient(name: line))
                .toList(growable: false),
            instructions: List<String>.from(seed.instructions),
            isLoadsheddingFriendly: false,
          ),
        ),
      ),
    );
  }

  /// Quick-add an inspo entry to the dinner slot of the currently
  /// selected calendar date. Drives the satisfying "tap → dot lights
  /// up" loop in the new Quick Weekly Inspo carousel.
  void _quickAddInspoToSelectedDay(String title) {
    final iso  = _isoDate(_selectedDay);
    final plan = _planFor(iso);
    setState(() {
      plan.addToSlot(MealSlot.dinner, _stubRecipe(title));
    });
    _savePlan();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content:  Text("Added '$title' to ${_selectedDay.day}/${_selectedDay.month}'s dinner."),
      behavior: SnackBarBehavior.floating,
      backgroundColor: _kForest,
    ));
  }

  // _openDailyPlanSheet removed — calendar taps now swap to list view
  // pinned on the chosen date's week (per spec change in Ref 43914.jpg).

  String _buildWholeWeekText() {
    final buf = StringBuffer()
      ..writeln('🔥 ChowSA — Weekly Menu')
      ..writeln();
    for (final p in _visibleWeekPlans) {
      if (p.isEmpty) continue;
      buf.writeln('${p.dayOfWeek}:');
      for (final slot in MealSlot.values) {
        final items = p.getSlot(slot);
        if (items.isEmpty) continue;
        buf.writeln('  ${slot.emoji} ${slot.label} — '
            '${items.map((r) => r.title).join(", ")}');
      }
      buf.writeln();
    }
    buf.writeln('Shared via ChowSA 🇿🇦  •  chowsa.app');
    return buf.toString();
  }

  String _buildSingleDayText(MealPlan p) {
    final buf = StringBuffer()
      ..writeln('🔥 ChowSA — ${p.dayOfWeek}')
      ..writeln();
    for (final slot in MealSlot.values) {
      final items = p.getSlot(slot);
      if (items.isEmpty) continue;
      buf.writeln('${slot.emoji} ${slot.label} — '
          '${items.map((r) => r.title).join(", ")}');
    }
    buf.writeln();
    buf.writeln('Shared via ChowSA 🇿🇦  •  chowsa.app');
    return buf.toString();
  }

  /// Structured payload — used by the internal "Share with a ChowSA Friend"
  /// path so the receiver can import the menu directly into their own planner.
  Map<String, dynamic> _buildWholeWeekPayload() => {
    'days': {
      for (final p in _visibleWeekPlans)
        p.dayOfWeek: {
          for (final s in MealSlot.values)
            s.name: p.getSlot(s).map((r) => r.title).toList(),
        },
    },
  };

  Map<String, dynamic> _buildSingleDayPayload(MealPlan p) => {
    'days': {
      p.dayOfWeek: {
        for (final s in MealSlot.values)
          s.name: p.getSlot(s).map((r) => r.title).toList(),
      },
    },
  };

  /// Opens the share-target picker (Friend / External). On the Friend path it
  /// chains into a handle-entry sheet; on the External path it calls
  /// share_plus with the formatted text.
  Future<void> _openShareDialog({
    required String              title,
    required String              menuText,
    required Map<String, dynamic> payload,
  }) async {
    final choice = await showModalBottomSheet<_ShareTarget>(
      context:         context,
      backgroundColor: Colors.transparent,
      builder: (_) => const _ShareTargetSheet(),
    );
    if (!mounted || choice == null) return;

    if (choice == _ShareTarget.external) {
      await Share.share(menuText, subject: title);
      return;
    }

    // ── Internal — ChowSA friend ──────────────────────────────────────────
    // Bottom sheet (not dialog) so the keyboard slides up cleanly under
    // the input + Send button instead of crushing the dialog upward.
    final handle = await showModalBottomSheet<String>(
      context:            context,
      isScrollControlled: true,
      backgroundColor:    Colors.transparent,
      builder:            (_) => const _FriendHandleDialog(),
    );
    if (!mounted || handle == null || handle.trim().isEmpty) return;

    final senderHandle = Supabase.instance.client.auth.currentUser
            ?.userMetadata?['handle'] as String? ??
        Supabase.instance.client.auth.currentUser?.email?.split('@').first ??
        'Someone';

    try {
      // Dual write — kept in lock-step so the recipient gets BOTH:
      //   • a live MaterialBanner via shared_assets realtime stream, AND
      //   • a persistent inbox_messages row that survives a missed
      //     banner so they can re-open it from the Inbox screen later.
      await SharedAssetsService.instance.sendMenu(
        receiverHandle: handle,
        title:          title,
        days:           payload['days'] as Map<String, dynamic>,
        senderHandle:   senderHandle,
      ).timeout(const Duration(seconds: 12));
      try {
        await InboxShareService.instance.shareMealPlan(
          title:           title,
          days:            payload['days'] as Map<String, dynamic>,
          recipientHandle: handle,
        );
      } catch (e) {
        // Non-fatal — the live banner path already succeeded, so the
        // recipient still sees it in real time. We just lost the
        // persistent inbox row; logged for diagnosis.
        debugPrint('[mealPlanShare] inbox persist failed: $e');
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Menu sent over safely! 📅',
              style: TextStyle(fontWeight: FontWeight.w700)),
          backgroundColor: _kForest,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            e.toString().contains('No ChowSA user')
                ? 'No ChowSA user found with handle @$handle.'
                : "Couldn't send menu — try again in a moment.",
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          backgroundColor: const Color(0xFFC62828),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
    }
  }

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: const Color(0xFFFAF8F5),
      appBar: AppBar(
        backgroundColor: _kForest,
        foregroundColor: Colors.white,
        elevation:       0,
        titleSpacing:    0,
        title: Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Weekly Menu Planner',
                style: tt.titleMedium?.copyWith(
                  color:      Colors.white,
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (_loaded && _totalMeals > 0)
                Text(
                  '$_totalMeals meal${_totalMeals == 1 ? '' : 's'} '
                  'planned this week',
                  style: const TextStyle(
                    fontSize: 11,
                    color:    Colors.white70,
                  ),
                ),
            ],
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(_showCalendar
                ? Icons.view_agenda_rounded
                : Icons.calendar_month_rounded),
            tooltip: _showCalendar ? 'List view' : 'Month view',
            onPressed: () => setState(() => _showCalendar = !_showCalendar),
          ),
          // ── Share whole week ────────────────────────────────────────────
          // Loops every day Monday → Sunday via _buildWholeWeekText, which
          // skips empty days so the message stays compact even if only a
          // couple of days are planned. Per-day sharing lives on each day's
          // own row card; this top-bar button is the "share the entire
          // weekly plan" action.
          if (_loaded && _totalMeals > 0)
            IconButton(
              icon:    const Icon(Icons.ios_share_rounded),
              tooltip: 'Share weekly menu',
              onPressed: () {
                _openShareDialog(
                  title:    'Weekly Menu',
                  menuText: _buildWholeWeekText(),
                  payload:  _buildWholeWeekPayload(),
                );
              },
            ),
          if (_loaded && _totalMeals > 0)
            TextButton(
              onPressed: _clearAll,
              child: const Text(
                'Clear week',
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),
        ],
      ),
      body: Stack(
        children: [
          // Subtle SA kitchen pattern wash — fixed in place behind the
          // calendar / list content. 0.05-ish opacity so it whispers
          // rather than competes with the UI.
          const Positioned.fill(child: IgnorePointer(child: _KitchenPatternWash())),
          !_loaded
          ? const Center(
              child: CircularProgressIndicator(color: _kForest),
            )
          : _showCalendar
              ? _buildCalendarView()
              : Builder(builder: (context) {
                  final week = _visibleWeekPlans;
                  // Pending auto-scroll (set by the calendar tap) —
                  // executes after first frame so the day cards are
                  // laid out and have positions to scroll to.
                  if (_pendingScrollDayIndex != null) {
                    final i = _pendingScrollDayIndex!;
                    _pendingScrollDayIndex = null;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      final ctx = _dayKeys[i].currentContext;
                      if (ctx != null) {
                        Scrollable.ensureVisible(
                          ctx,
                          duration: const Duration(milliseconds: 350),
                          curve:    Curves.easeOutCubic,
                          alignment: 0.05,
                        );
                      }
                    });
                  }
                  return ListView.builder(
                    controller: _listCtrl,
                    padding: const EdgeInsets.fromLTRB(16, 20, 16, 40),
                    itemCount: week.length + 1,
                    itemBuilder: (_, idx) {
                      if (idx == 0) {
                        // Week header with prev/next nav.
                        final endOfWeek =
                            _visibleWeekStart.add(const Duration(days: 6));
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Row(
                            children: [
                              IconButton(
                                icon: const Icon(Icons.chevron_left_rounded),
                                onPressed: () => setState(() {
                                  _visibleWeekStart = _visibleWeekStart
                                      .subtract(const Duration(days: 7));
                                }),
                              ),
                              Expanded(
                                child: Center(
                                  child: Text(
                                    '${_visibleWeekStart.day}/${_visibleWeekStart.month}'
                                    ' — '
                                    '${endOfWeek.day}/${endOfWeek.month}/${endOfWeek.year}',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w900,
                                      color:      _kForest,
                                    ),
                                  ),
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.chevron_right_rounded),
                                onPressed: () => setState(() {
                                  _visibleWeekStart = _visibleWeekStart
                                      .add(const Duration(days: 7));
                                }),
                              ),
                            ],
                          ),
                        );
                      }
                      final i    = idx - 1;
                      final plan = week[i];
                      final iso  = plan.date;
                      return Padding(
                        key:     _dayKeys[i],
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _DayCard(
                          plan:       plan,
                          dayIndex:   i,
                          onAdd:      (slot) => _addToSlotByDate(iso, slot),
                          onRemove:   (slot, optionIdx) =>
                              _removeFromSlotByDate(iso, slot, optionIdx),
                          onOpenRecipe: (recipe) =>
                              _openPlannedRecipe(recipe),
                          onClearDay: () => _clearDayByDate(iso),
                          onShareDay: plan.isEmpty ? null : () {
                            _openShareDialog(
                              title:    '${plan.dayOfWeek} Menu',
                              menuText: _buildSingleDayText(plan),
                              payload:  _buildSingleDayPayload(plan),
                            );
                          },
                        ),
                      );
                    },
                  );
                }),
        ],
      ),
    );
  }
}

// =============================================================================
// Lightweight recipe record used by the picker (no full Recipe required)
// =============================================================================

/// Where a picker entry came from. Drives the badge ("From My Recipes"
/// vs. "Saved from @handle"), the section header in the picker, and
/// lets us sort My-Recipes entries above community ones — your own
/// saved cooking is usually what you want to plan with first.
enum _QuickRecipeSource { mine, community }

class _QuickRecipe {
  final String              title;
  /// Empty for [mine]; the community uploader's handle for [community].
  final String              username;
  final _QuickRecipeSource  source;
  /// Reference id back to the canonical record. Used by the planner
  /// tile's tap handler to deep-link into the recipe detail screen.
  /// Null when the user typed a custom meal that doesn't exist in
  /// either source library.
  final String?             sourceId;
  const _QuickRecipe({
    required this.title,
    required this.username,
    required this.source,
    this.sourceId,
  });

  String get sourceTag => switch (source) {
        _QuickRecipeSource.mine      => 'mine',
        _QuickRecipeSource.community => 'community',
      };
}

// Build a stub Recipe from a title string. Optionally carries a
// sourceId/sourceType so the tile can deep-link back to the canonical
// record (My Recipes / community feed) when the user taps it.
Recipe _stubRecipe(String title, {String? sourceId, String? sourceType}) =>
    Recipe(
      title:                 title,
      ingredients:           const [],
      instructions:          const [],
      isLoadsheddingFriendly: false,
      sourceId:              sourceId,
      sourceType:            sourceType,
    );

// =============================================================================
// _DayCard — expandable tile for one weekday
// =============================================================================

class _DayCard extends StatefulWidget {
  const _DayCard({
    required this.plan,
    required this.dayIndex,
    required this.onAdd,
    required this.onRemove,
    required this.onOpenRecipe,
    required this.onClearDay,
    this.onShareDay,
  });

  final MealPlan                                  plan;
  final int                                       dayIndex;
  // Append a new recipe option to the given slot.
  final void Function(MealSlot)                   onAdd;
  // Remove a single recipe option (index within that slot's list).
  final void Function(MealSlot slot, int optIdx)  onRemove;
  // Tapping a planned-meal tile fires this with the underlying recipe
  // so the parent can deep-link to My Recipes detail when sourceId is set.
  final void Function(Recipe)                     onOpenRecipe;
  final VoidCallback                              onClearDay;
  // Tapping the three-dot menu's "Share day" action fires this. Null when
  // the day is empty — the menu hides itself in that case.
  final VoidCallback?                             onShareDay;

  @override
  State<_DayCard> createState() => _DayCardState();
}

class _DayCardState extends State<_DayCard> {
  bool _expanded = false;

  static const _kWeekends = {'Saturday', 'Sunday'};

  bool get _isWeekend => _kWeekends.contains(widget.plan.dayOfWeek);
  bool get _hasMeals  => !widget.plan.isEmpty;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      decoration: BoxDecoration(
        color:        _hasMeals
            ? (_isWeekend
                ? const Color(0xFFE8F5E9)
                : Colors.white)
            : cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: _expanded
              ? _kForest.withAlpha(100)
              : (_hasMeals
                  ? _kForest.withAlpha(45)
                  : cs.outlineVariant.withAlpha(180)),
          width: _expanded ? 1.5 : 1.0,
        ),
        boxShadow: _hasMeals
            ? [BoxShadow(
                color:      _kForest.withAlpha(14),
                blurRadius: 10,
                offset:     const Offset(0, 3),
              )]
            : [],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Collapsed header (always visible) ────────────────────────────
          _buildHeader(tt, cs),

          // ── Expanded meal slots ──────────────────────────────────────────
          AnimatedSize(
            duration: const Duration(milliseconds: 280),
            curve:    Curves.easeInOut,
            child: _expanded
                ? _buildSlots(tt, cs)
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(TextTheme tt, ColorScheme cs) {
    final dayAbbr = widget.plan.dayOfWeek.substring(0, 3);

    return InkWell(
      borderRadius: BorderRadius.vertical(
        top:    const Radius.circular(18),
        bottom: Radius.circular(_expanded ? 0 : 18),
      ),
      onTap: () => setState(() => _expanded = !_expanded),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
        child: Row(
          children: [
            // ── Day badge ──────────────────────────────────────────────────
            Container(
              width:  48,
              height: 48,
              decoration: BoxDecoration(
                color: _hasMeals
                    ? (_isWeekend ? _kForest : _kOrange)
                    : cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(13),
              ),
              alignment: Alignment.center,
              child: Text(
                dayAbbr.toUpperCase(),
                style: TextStyle(
                  color:      _hasMeals ? Colors.white : _kMuted,
                  fontSize:   12,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.5,
                ),
              ),
            ),
            const SizedBox(width: 14),

            // ── Day name + summary ─────────────────────────────────────────
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.plan.dayOfWeek,
                    style: tt.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color:      _hasMeals ? _kForest : const Color(0xFF333333),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    widget.plan.summary,
                    style: tt.bodySmall?.copyWith(
                      color:     _hasMeals ? const Color(0xFF2E7D32) : _kMuted,
                      fontWeight: _hasMeals ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                ],
              ),
            ),

            // ── Meal slot mini-previews ────────────────────────────────────
            if (_hasMeals && !_expanded) ...[
              _MiniDotRow(plan: widget.plan),
              const SizedBox(width: 4),
            ],

            // ── Per-day three-dot menu (only when there's something to share)
            if (widget.onShareDay != null)
              SizedBox(
                width: 32,
                child: PopupMenuButton<String>(
                  tooltip:    'More',
                  icon:       Icon(Icons.more_horiz_rounded,
                      color: _hasMeals ? _kForest : _kMuted, size: 20),
                  padding:    EdgeInsets.zero,
                  position:   PopupMenuPosition.under,
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'share',
                      child: Row(children: [
                        Icon(Icons.ios_share_rounded, size: 18, color: _kForest),
                        SizedBox(width: 10),
                        Text('Share this day'),
                      ]),
                    ),
                  ],
                  onSelected: (v) {
                    if (v == 'share') widget.onShareDay?.call();
                  },
                ),
              ),

            // ── Chevron ───────────────────────────────────────────────────
            AnimatedRotation(
              turns:    _expanded ? 0.5 : 0,
              duration: const Duration(milliseconds: 220),
              child: Icon(
                Icons.keyboard_arrow_down_rounded,
                color: _hasMeals ? _kForest : _kMuted,
                size:  22,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSlots(TextTheme tt, ColorScheme cs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Divider(
          height:    1,
          indent:    16,
          endIndent: 16,
          color:     _kForest.withAlpha(40),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
          child: Column(
            children: [
              for (final slot in MealSlot.values) ...[
                _MealSlotTile(
                  slot:    slot,
                  recipes: widget.plan.getSlot(slot),
                  onAdd:   () => widget.onAdd(slot),
                  onRemove:  (idx) => widget.onRemove(slot, idx),
                  onOpenRecipe: widget.onOpenRecipe,
                ),
                if (slot != MealSlot.dinner) const SizedBox(height: 14),
              ],
            ],
          ),
        ),

        // ── Clear day shortcut ─────────────────────────────────────────────
        if (_hasMeals)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
            child: TextButton.icon(
              onPressed: widget.onClearDay,
              icon:  const Icon(Icons.delete_outline_rounded, size: 15),
              label: const Text('Clear day'),
              style: TextButton.styleFrom(
                foregroundColor: cs.error,
                textStyle:       const TextStyle(fontSize: 12),
                padding:         const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 6),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          )
        else
          const SizedBox(height: 14),
      ],
    );
  }
}

// =============================================================================
// _MiniDotRow — three dots showing which slots are filled (collapsed preview)
// =============================================================================

class _MiniDotRow extends StatelessWidget {
  const _MiniDotRow({required this.plan});
  final MealPlan plan;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: MealSlot.values.map((s) {
        final filled = plan.getSlot(s).isNotEmpty;
        return Container(
          width:  7,
          height: 7,
          margin: const EdgeInsets.only(left: 3),
          decoration: BoxDecoration(
            color:  filled ? _kForest : _kForest.withAlpha(40),
            shape:  BoxShape.circle,
          ),
        );
      }).toList(),
    );
  }
}

// =============================================================================
// _MealSlotTile — single meal slot row (empty or filled)
// =============================================================================

class _MealSlotTile extends StatelessWidget {
  const _MealSlotTile({
    required this.slot,
    required this.recipes,
    required this.onAdd,
    required this.onRemove,
    required this.onOpenRecipe,
  });

  final MealSlot          slot;
  final List<Recipe>      recipes;
  final VoidCallback      onAdd;
  /// Removes the option at [index] from this slot.
  final void Function(int index) onRemove;
  /// Tapping the row (not the × button) opens the underlying recipe
  /// detail when a sourceId is present.
  final void Function(Recipe)    onOpenRecipe;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Slot label row ───────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            children: [
              Text(slot.emoji, style: const TextStyle(fontSize: 13)),
              const SizedBox(width: 6),
              Text(
                slot.label,
                style: tt.labelMedium?.copyWith(
                  fontWeight:    FontWeight.w700,
                  color:         _kForest,
                  letterSpacing: 0.2,
                ),
              ),
              if (recipes.isNotEmpty) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 7, vertical: 1),
                  decoration: BoxDecoration(
                    color:        _kForest.withAlpha(20),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '${recipes.length} option${recipes.length == 1 ? '' : 's'}',
                    style: const TextStyle(
                      fontSize:      10,
                      fontWeight:    FontWeight.w800,
                      color:         _kForest,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),

        // ── Existing recipe rows ─────────────────────────────────────────────
        // Each option renders as a compact horizontal row with its own
        // trailing × button — removing one leaves the rest of the slot intact.
        for (int i = 0; i < recipes.length; i++) ...[
          _CompactRecipeTile(
            recipe:   recipes[i],
            onRemove: () => onRemove(i),
            onOpen:   () => onOpenRecipe(recipes[i]),
          ),
          const SizedBox(height: 6),
        ],

        // ── Persistent Add Option button (always visible) ────────────────────
        // Sits BELOW the listed options so users can keep stacking more.
        _AddOptionButton(
          label:  recipes.isEmpty ? slot.addText : '+ Add another option',
          onTap:  onAdd,
        ),
      ],
    );
  }
}

// =============================================================================
// _CompactRecipeTile — single recipe option row inside a meal slot
// =============================================================================

class _CompactRecipeTile extends StatelessWidget {
  const _CompactRecipeTile({
    required this.recipe,
    required this.onRemove,
    required this.onOpen,
  });

  final Recipe       recipe;
  final VoidCallback onRemove;
  /// Fired when the user taps the avatar/title area (not the × button).
  /// The parent decides what to do — usually push the recipe detail
  /// screen when [recipe.sourceId] is set.
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final tt    = Theme.of(context).textTheme;
    final cs    = Theme.of(context).colorScheme;
    final color = _avatarColor(recipe.title);

    return Container(
      decoration: BoxDecoration(
        color:        color.withAlpha(14),
        borderRadius: BorderRadius.circular(12),
        border:       Border.all(color: color.withAlpha(55)),
      ),
      child: Row(
        children: [
          // Tappable avatar+title region — opens recipe detail when
          // sourceId is set; SnackBar nudge for custom-typed entries.
          Expanded(
            child: InkWell(
              onTap: onOpen,
              borderRadius: const BorderRadius.horizontal(
                left: Radius.circular(11),
              ),
              child: Row(children: [
          // Recipe avatar
          Container(
            width:  44,
            height: 44,
            decoration: BoxDecoration(
              color:        color,
              borderRadius: const BorderRadius.horizontal(
                left: Radius.circular(11),
              ),
            ),
            alignment: Alignment.center,
            child: Text(
              _initials(recipe.title),
              style: const TextStyle(
                color:      Colors.white,
                fontSize:   13,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),

          // Title + braai badge
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment:  MainAxisAlignment.center,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          recipe.title,
                          style: tt.bodySmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            color:      const Color(0xFF111111),
                            height:     1.2,
                            fontSize:   13,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (recipe.sourceId != null &&
                          recipe.sourceType == 'mine') ...[
                        const SizedBox(width: 4),
                        Icon(Icons.open_in_new_rounded,
                            size:  12,
                            color: _kForest.withAlpha(160)),
                      ],
                    ],
                  ),
                  if (recipe.isBraaiReady) ...[
                    const SizedBox(height: 3),
                    Text(
                      '🔥 Braai Ready',
                      style: TextStyle(
                        fontSize:   9,
                        fontWeight: FontWeight.w700,
                        color:      const Color(0xFFBF360C),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
              ]),
            ),
          ),

          // Per-option remove button (X for THIS recipe only)
          GestureDetector(
            onTap: onRemove,
            child: Container(
              width:     38,
              height:    44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(color: color.withAlpha(40)),
                ),
              ),
              child: Icon(
                Icons.close_rounded,
                size:  15,
                color: cs.error,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// _AddOptionButton — persistent "+" tile that adds another option to a slot
// =============================================================================

class _AddOptionButton extends StatelessWidget {
  const _AddOptionButton({required this.label, required this.onTap});

  final String       label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: CustomPaint(
        painter: _DashedBorderPainter(
          color:       _kForest.withAlpha(70),
          radius:      12,
          dashWidth:   5,
          dashSpace:   4,
          strokeWidth: 1.2,
        ),
        child: Container(
          width:   double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            color:        _kForest.withAlpha(8),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Container(
                width:  26,
                height: 26,
                decoration: BoxDecoration(
                  color:        _kForest.withAlpha(20),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.add_rounded,
                    color: _kForest, size: 16),
              ),
              const SizedBox(width: 11),
              Text(
                label,
                style: const TextStyle(
                  color:      _kForest,
                  fontWeight: FontWeight.w700,
                  fontSize:   13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// _DashedBorderPainter — CustomPainter for dashed rounded-rect outline
// =============================================================================

class _DashedBorderPainter extends CustomPainter {
  const _DashedBorderPainter({
    required this.color,
    this.dashWidth   = 6,
    this.dashSpace   = 4,
    this.radius      = 12,
    this.strokeWidth = 1.5,
  });

  final Color  color;
  final double dashWidth;
  final double dashSpace;
  final double radius;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color       = color
      ..strokeWidth = strokeWidth
      ..style       = PaintingStyle.stroke
      ..strokeCap   = StrokeCap.round;

    final rect = Rect.fromLTWH(
      strokeWidth / 2,
      strokeWidth / 2,
      size.width  - strokeWidth,
      size.height - strokeWidth,
    );
    final source = Path()
      ..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(radius)));

    final dashPath = Path();
    for (final metric in source.computeMetrics()) {
      double distance = 0;
      while (distance < metric.length) {
        dashPath.addPath(
          metric.extractPath(distance, distance + dashWidth),
          Offset.zero,
        );
        distance += dashWidth + dashSpace;
      }
    }
    canvas.drawPath(dashPath, paint);
  }

  @override
  bool shouldRepaint(_DashedBorderPainter old) =>
      old.color       != color       ||
      old.dashWidth   != dashWidth   ||
      old.dashSpace   != dashSpace   ||
      old.radius      != radius      ||
      old.strokeWidth != strokeWidth;
}

// =============================================================================
// _RecipePickerSheet — bottom sheet for assigning a recipe to a slot
// =============================================================================

// A single row in the picker list. Carries the avatar + title +
// source badge + an optional "Used this week" / "Last cooked DDD" chip
// so frequent favourites are visually distinct from never-planned
// entries — a small affordance that meaningfully speeds up planning.
class _PickerRow extends StatelessWidget {
  const _PickerRow({
    required this.entry,
    required this.lastPlannedIso,
    required this.inVisibleWeek,
    required this.tt,
    required this.onTap,
  });

  final _QuickRecipe  entry;
  final String?       lastPlannedIso;
  final bool          inVisibleWeek;
  final TextTheme     tt;
  final VoidCallback  onTap;

  String _relativeLabel() {
    if (lastPlannedIso == null) return '';
    if (inVisibleWeek) return 'Used this week';
    final d = DateTime.tryParse(lastPlannedIso!);
    if (d == null) return '';
    const names = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
    return 'Last cooked ${names[(d.weekday - 1).clamp(0, 6)]}';
  }

  @override
  Widget build(BuildContext context) {
    final color    = _avatarColor(entry.title);
    final lastLbl  = _relativeLabel();
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin:  const EdgeInsets.symmetric(horizontal: 24),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color:        Colors.white,
          borderRadius: BorderRadius.circular(14),
          border:       Border.all(color: const Color(0xFFEEEAE4)),
        ),
        child: Row(
          children: [
            Container(
              width:  40,
              height: 40,
              decoration: BoxDecoration(
                color:        color,
                borderRadius: BorderRadius.circular(10),
              ),
              alignment: Alignment.center,
              child: Text(
                _initials(entry.title),
                style: const TextStyle(
                  color:      Colors.white,
                  fontSize:   13,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          entry.title,
                          style: tt.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (lastLbl.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: inVisibleWeek
                                ? _kForest.withAlpha(28)
                                : const Color(0xFFEEEAE4),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            lastLbl,
                            style: TextStyle(
                              color: inVisibleWeek
                                  ? _kForest
                                  : _kMuted,
                              fontSize:   10,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  Text(
                    entry.source == _QuickRecipeSource.mine
                        ? 'From My Recipes'
                        : (entry.username.isNotEmpty
                            ? 'Saved · @${entry.username}'
                            : 'Saved from Community'),
                    style: tt.bodySmall?.copyWith(
                      color: entry.source == _QuickRecipeSource.mine
                          ? _kForest
                          : _kMuted,
                      fontWeight: entry.source == _QuickRecipeSource.mine
                          ? FontWeight.w700
                          : FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.add_circle_outline_rounded,
              color: _kForest.withAlpha(160),
              size:  20,
            ),
          ],
        ),
      ),
    );
  }
}

// Section header inside the picker — "From My Recipes" / "Saved from
// Community". Tight vertical rhythm so it doesn't dominate the rows.
class _PickerSectionHeader extends StatelessWidget {
  const _PickerSectionHeader({required this.label, required this.icon});
  final String   label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 14, 24, 6),
      child: Row(
        children: [
          Icon(icon, size: 14, color: _kForest),
          const SizedBox(width: 6),
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              color:       _kForest,
              fontWeight:  FontWeight.w900,
              fontSize:    11,
              letterSpacing: 0.7,
            ),
          ),
        ],
      ),
    );
  }
}

class _RecipePickerSheet extends StatefulWidget {
  const _RecipePickerSheet({
    required this.saved,
    required this.dayName,
    required this.slot,
    required this.lastPlannedByTitle,
    required this.currentWeekIsoDates,
  });

  final List<_QuickRecipe> saved;
  final String             dayName;
  final MealSlot           slot;

  /// title (lower-cased) → most recent ISO date the user has planned
  /// that recipe on. Drives the "Used this week" / "Last cooked Wed"
  /// chip on each picker row.
  final Map<String, String> lastPlannedByTitle;

  /// ISO dates that fall inside the planner's currently-visible week.
  /// Used to decide whether the recently-planned chip should say
  /// "Used this week" (lit) vs. "Last cooked DDD" (muted).
  final Set<String> currentWeekIsoDates;

  @override
  State<_RecipePickerSheet> createState() => _RecipePickerSheetState();
}

class _RecipePickerSheetState extends State<_RecipePickerSheet> {
  final _customCtrl = TextEditingController();
  String _filter    = '';

  @override
  void dispose() {
    _customCtrl.dispose();
    super.dispose();
  }

  /// True if [r] should be shown given the current text filter.
  bool _matches(_QuickRecipe r) {
    if (_filter.isEmpty) return true;
    return r.title.toLowerCase().contains(_filter.toLowerCase());
  }

  List<_QuickRecipe> _section(_QuickRecipeSource s) =>
      widget.saved.where((r) => r.source == s && _matches(r)).toList();

  /// Build a Recipe from an existing picker entry — preserves the
  /// sourceId + sourceType so the resulting planner tile can deep-link
  /// back into the recipe detail screen on tap.
  Recipe _recipeFor(_QuickRecipe entry) => _stubRecipe(
        entry.title,
        sourceId:   entry.sourceId,
        sourceType: entry.sourceTag,
      );

  void _pickCustom(String title) {
    final t = title.trim();
    if (t.isEmpty) return;
    // Custom-typed meal — see if a saved entry already matches the
    // typed string so we still attach the source id when possible.
    final match = widget.saved.firstWhere(
      (r) => r.title.toLowerCase() == t.toLowerCase(),
      orElse: () => const _QuickRecipe(
        title:    '',
        username: '',
        source:   _QuickRecipeSource.community,
      ),
    );
    Navigator.pop(
      context,
      match.title.isEmpty ? _stubRecipe(t) : _recipeFor(match),
    );
  }

  void _pickEntry(_QuickRecipe entry) =>
      Navigator.pop(context, _recipeFor(entry));

  /// Renders one section's rows. Pulled out of build() so both
  /// sections share identical layout — only the section header above
  /// them differs.
  List<Widget> _buildPickerRows(List<_QuickRecipe> entries) {
    final tt    = Theme.of(context).textTheme;
    return [
      for (final r in entries) ...[
        _PickerRow(
          entry:           r,
          lastPlannedIso:  widget.lastPlannedByTitle[r.title.toLowerCase()],
          inVisibleWeek:   widget.currentWeekIsoDates.contains(
              widget.lastPlannedByTitle[r.title.toLowerCase()] ?? ''),
          tt:              tt,
          onTap:           () => _pickEntry(r),
        ),
        const SizedBox(height: 8),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final tt        = Theme.of(context).textTheme;
    final keyboard  = MediaQuery.of(context).viewInsets.bottom;
    final safeBot   = MediaQuery.of(context).padding.bottom;
    final cs        = Theme.of(context).colorScheme;
    // Sheet inhabits at most 88% of the screen so it never wants more space
    // than the OS will give it. When the keyboard opens, the scroll view soaks
    // up the lost vertical space cleanly — no overflow stripes.
    final maxH      = MediaQuery.of(context).size.height * 0.88;

    return Container(
      decoration: const BoxDecoration(
        color:        _kCream,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      constraints: BoxConstraints(maxHeight: maxH),
      // Dynamic bottom padding: includes keyboard inset so the sheet content
      // is never hidden behind the soft keyboard.
      padding: EdgeInsets.only(bottom: keyboard),
      child: SingleChildScrollView(
        // Keyboard-aware scroll — focus jumps to the visible field.
        keyboardDismissBehavior:
            ScrollViewKeyboardDismissBehavior.onDrag,
        child: Padding(
          padding: EdgeInsets.only(bottom: safeBot),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
          // ── Handle + title ────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
            child: Column(
              children: [
                Center(
                  child: Container(
                    width:  40, height: 4,
                    margin:     const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color:        const Color(0xFFE6E2D8),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Row(
                  children: [
                    Container(
                      width:  40, height: 40,
                      decoration: BoxDecoration(
                        color:        _kForest,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Center(
                        child: Text(
                          widget.slot.emoji,
                          style: const TextStyle(fontSize: 20),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${widget.slot.label} — ${widget.dayName}',
                            style: tt.titleSmall?.copyWith(
                              fontWeight: FontWeight.w900,
                              color:      _kForest,
                            ),
                          ),
                          Text(
                            'Pick from My Recipes, your saved community recipes, or type a custom meal',
                            style: tt.bodySmall?.copyWith(color: _kMuted),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // ── Custom / search input ─────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller:         _customCtrl,
                    textCapitalization: TextCapitalization.sentences,
                    onChanged:          (v) => setState(() => _filter = v),
                    onSubmitted:        _pickCustom,
                    decoration: InputDecoration(
                      hintText:  'Type a meal name or search saved recipes…',
                      hintStyle: const TextStyle(
                        color: Color(0xFFADADA7), fontSize: 13),
                      filled:    true,
                      fillColor: Colors.white,
                      prefixIcon: Icon(Icons.search_rounded,
                          color: cs.onSurfaceVariant, size: 20),
                      contentPadding:
                          const EdgeInsets.fromLTRB(0, 13, 12, 13),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide:   const BorderSide(
                            color: Color(0xFFE6E2D8)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide:   const BorderSide(
                            color: Color(0xFFE6E2D8)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide:   const BorderSide(
                            color: _kForest, width: 1.5),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton(
                  onPressed: () => _pickCustom(_customCtrl.text),
                  style: FilledButton.styleFrom(
                    backgroundColor: _kOrange,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text(
                    'Add',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),
          Divider(height: 1, color: cs.outlineVariant),
          const SizedBox(height: 4),

          // ── Saved recipe list, split into source sections ─────────────────
          // SingleChildScrollView host means we can't use Expanded here.
          // Each section shrink-wraps to its content; the outer scroll
          // view handles overflow when the keyboard or many entries
          // push past the sheet limit.
          Builder(builder: (_) {
            final mine      = _section(_QuickRecipeSource.mine);
            final community = _section(_QuickRecipeSource.community);
            if (mine.isEmpty && community.isEmpty) {
              return Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.bookmark_add_outlined,
                        size:  48,
                        color: cs.onSurfaceVariant.withAlpha(100)),
                    const SizedBox(height: 14),
                    Text(
                      _filter.isEmpty
                          ? 'Nothing in your recipe library yet'
                          : 'No recipes match "$_filter"',
                      style: tt.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _filter.isEmpty
                          ? 'Add recipes in My Recipes or save them from the Community tab — or just type a meal name above and tap Add.'
                          : 'Try a different search term, or type and tap Add.',
                      style: tt.bodySmall?.copyWith(
                        color:  _kMuted,
                        height: 1.5,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (mine.isNotEmpty) ...[
                  const _PickerSectionHeader(
                    label: 'From My Recipes',
                    icon:  Icons.bookmark_rounded,
                  ),
                  ..._buildPickerRows(mine),
                ],
                if (community.isNotEmpty) ...[
                  const _PickerSectionHeader(
                    label: 'Saved from Community',
                    icon:  Icons.people_alt_rounded,
                  ),
                  ..._buildPickerRows(community),
                ],
                const SizedBox(height: 8),
              ],
            );
          }),
            ],          // Column children
          ),            // Column
        ),              // Padding
      ),                // SingleChildScrollView
    );                  // outer Container
  }
}

// =============================================================================
// _ShareTargetSheet — picker between "ChowSA Friend" and "External app"
// =============================================================================

enum _ShareTarget { friend, external }

class _ShareTargetSheet extends StatelessWidget {
  const _ShareTargetSheet();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color:        _kCream,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40, height: 4,
            margin: const EdgeInsets.only(bottom: 18),
            decoration: BoxDecoration(
              color:        const Color(0xFFE6E2D8),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text('Share your menu',
                style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color:      _kForest,
                    fontSize:   17)),
          ),
          ListTile(
            leading: const Icon(Icons.person_search_rounded,
                color: _kForest),
            title: const Text('Share with a ChowSA Friend',
                style: TextStyle(fontWeight: FontWeight.w700)),
            subtitle: const Text('Sends to their inbox inside the app'),
            onTap: () => Navigator.pop(context, _ShareTarget.friend),
          ),
          ListTile(
            leading: const Icon(Icons.ios_share_rounded, color: _kOrange),
            title: const Text('Share via External App',
                style: TextStyle(fontWeight: FontWeight.w700)),
            subtitle: const Text('WhatsApp, email, anywhere else'),
            onTap: () => Navigator.pop(context, _ShareTarget.external),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// _FriendHandleDialog — collects a ChowSA handle for the internal share
// =============================================================================

class _FriendHandleDialog extends StatefulWidget {
  const _FriendHandleDialog();

  @override
  State<_FriendHandleDialog> createState() => _FriendHandleDialogState();
}

class _FriendHandleDialogState extends State<_FriendHandleDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Bottom sheet shell. AnimatedPadding(viewInsets.bottom) slides the
    // whole card up by exactly the keyboard height so the input + Send
    // sit immediately above the keyboard, never centred at the top.
    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve:    Curves.easeOut,
      padding:  EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        padding: EdgeInsets.fromLTRB(
          20, 20, 20,
          20 + MediaQuery.of(context).padding.bottom,
        ),
        decoration: const BoxDecoration(
          color:        _kCream,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40, height: 4,
                  margin: const EdgeInsets.only(bottom: 14),
                  decoration: BoxDecoration(
                    color:        const Color(0xFFE6E2D8),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const Text(
                'Who is the lucky chef?',
                style: TextStyle(
                  fontSize:   17,
                  fontWeight: FontWeight.w900,
                  color:      _kForest,
                ),
              ),
              const SizedBox(height: 12),
              UserHandleAutocomplete(
                controller:  _ctrl,
                accentColor: _kForest,
                hintText:    'ChowSA handle',
                onSubmitted: () => Navigator.pop(context, _ctrl.text),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFFE59B27),
                      minimumSize:     const Size(64, 44),
                    ),
                    child: const Text(
                      'Cancel',
                      style: TextStyle(
                        color:      Color(0xFFE59B27),
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, _ctrl.text),
                    style: FilledButton.styleFrom(
                      backgroundColor: _kForest,
                      foregroundColor: Colors.white,
                      minimumSize:     const Size(72, 44),
                    ),
                    child: const Text(
                      'Send',
                      style: TextStyle(
                        color:      Colors.white,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// _LegendDot — small coloured circle + label pair for the calendar legend
// =============================================================================
class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.label});
  final Color  color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10, height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            color:    Colors.grey.shade800,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// _KitchenPatternWash — subtle SA-kitchen pattern wash behind the canvas
// =============================================================================
//
// A tiled grid of food/braai emoji rendered at ~0.05 opacity. Sits behind
// the calendar + list so the empty canvas reads as a kitchen "wash" rather
// than dead space. Pure paint — no images, no assets.

class _KitchenPatternWash extends StatelessWidget {
  const _KitchenPatternWash();

  static const _glyphs = ['🍳','🔥','🍲','🌶️','🥩','🥕','🌽','🍅','🥖','☕','🥘','🥚','🧂','🍋'];

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, c) {
      const cell = 64.0;
      final cols = (c.maxWidth  / cell).ceil();
      final rows = (c.maxHeight / cell).ceil();
      return Opacity(
        opacity: 0.05,
        child: GridView.builder(
          physics:       const NeverScrollableScrollPhysics(),
          padding:       EdgeInsets.zero,
          itemCount:     cols * rows,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            mainAxisExtent: cell,
          ),
          itemBuilder: (_, i) {
            final glyph = _glyphs[(i * 31 + (i ~/ cols) * 7) % _glyphs.length];
            return Center(
              child: Text(glyph, style: const TextStyle(fontSize: 22)),
            );
          },
        ),
      );
    });
  }
}

// =============================================================================
// _InspoCard — horizontal carousel card used by Quick Weekly Inspo
// =============================================================================
class _InspoCard extends StatelessWidget {
  const _InspoCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.accent,
    required this.onAdd,
    required this.onTapBody,
  });

  final String       title;
  final String       subtitle;
  final String       icon;
  final Color        accent;
  final VoidCallback onAdd;
  final VoidCallback onTapBody;

  @override
  Widget build(BuildContext context) {
    return Container(
      width:  180,
      margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color:        const Color(0xFFFFF8EE),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: accent.withValues(alpha: 0.22)),
        boxShadow: [
          BoxShadow(
            color:      Colors.black.withValues(alpha: 0.05),
            blurRadius: 6,
            offset:     const Offset(0, 2),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Tappable card BODY → preview the recipe detail. The Add
          // button sits outside the InkWell so its tap never bubbles.
          Expanded(
            child: InkWell(
              onTap: onTapBody,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(icon, style: const TextStyle(fontSize: 28)),
                    const SizedBox(height: 6),
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize:   13.5,
                        color:      _kForest,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color:    Colors.grey.shade700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            child: SizedBox(
              width: double.infinity,
              height: 32,
              child: FilledButton(
                onPressed: onAdd,
                style: FilledButton.styleFrom(
                  backgroundColor: accent,
                  foregroundColor: Colors.white,
                  padding:         EdgeInsets.zero,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text(
                  '+ Add to Plan',
                  style: TextStyle(
                    color:      Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize:   12,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// _InspoSeed / _CalendarCell — value records
// =============================================================================
class _InspoSeed {
  const _InspoSeed({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.accent,
    this.ingredients  = const <String>[],
    this.instructions = const <String>[],
  });
  final String       title;
  final String       subtitle;
  final String       icon;
  final Color        accent;
  /// Real SA ingredient list — fed straight into the Recipe model so the
  /// "Save to My Recipes" path inserts a usable entry, not a stub.
  final List<String> ingredients;
  /// Step-by-step method, same purpose as [ingredients].
  final List<String> instructions;
}

class _CalendarCell extends StatelessWidget {
  const _CalendarCell({
    required this.day,
    required this.isToday,
    required this.isSelected,
    required this.isFaded,
    required this.onTap,
    required this.onDoubleTap,
  });
  final DateTime     day;
  final bool         isToday;
  final bool         isSelected;
  final bool         isFaded;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;

  @override
  Widget build(BuildContext context) {
    final bg = isSelected
        ? _kForest
        : isToday
            ? const Color(0xFFFFE0B2)
            : null;
    final fg = isSelected
        ? Colors.white
        : isFaded
            ? Colors.grey.shade400
            : _kForest;
    return GestureDetector(
      behavior:    HitTestBehavior.opaque,
      onTap:       onTap,
      onDoubleTap: onDoubleTap,
      child: Center(
        child: Container(
          width:  34, height: 34,
          alignment: Alignment.center,
          decoration: bg == null
              ? null
              : BoxDecoration(color: bg, shape: BoxShape.circle),
          child: Text(
            '${day.day}',
            style: TextStyle(
              color:      fg,
              fontWeight: isSelected || isToday
                  ? FontWeight.w900
                  : FontWeight.w600,
              fontSize: 13,
            ),
          ),
        ),
      ),
    );
  }
}
