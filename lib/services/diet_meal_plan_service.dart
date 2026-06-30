// lib/services/diet_meal_plan_service.dart
//
// "Plan my week" — one Gemini call that returns an N-day × M-slot grid
// of meal names tailored to the user's budget, days, diet, and meal
// slots. The output is intentionally just titles (no ingredients/steps)
// — those get generated on demand by ScraperService.generateRecipeFromName
// when the user taps a specific meal in the planner.
//
// Soft budget enforcement: the prompt asks the model to keep the
// estimated weekly grocery cost under the supplied budget by favouring
// affordable SA staples (pap, mealies, lentils, soy mince, in-season
// produce, PnP / Checkers / Shoprite house brands). No second-pass
// cost-estimate check in v1.

import 'dart:convert';

import 'package:google_generative_ai/google_generative_ai.dart';

import '../config/env.config.dart';
import '../config/servings_pref.dart';
import '../models/meal_plan.dart';

/// One diet-plan generation result: rows are days, each carrying the
/// generated meal title for whichever slots were requested.
class DietMealPlanResult {
  const DietMealPlanResult({
    required this.days,
    required this.estimatedTotalZar,
  });

  final List<DietPlannedDay> days;
  /// AI-reported guess of the total grocery cost for the whole plan,
  /// in ZAR. Soft signal — not a guarantee. Null when the model didn't
  /// return a number.
  final double? estimatedTotalZar;
}

class DietPlannedDay {
  const DietPlannedDay({
    required this.label,
    this.breakfast,
    this.lunch,
    this.dinner,
  });

  /// Display label only, e.g. "Day 1" / "Mon" — the date a meal lands on
  /// is decided by the caller (start-from-today index).
  final String  label;
  final String? breakfast;
  final String? lunch;
  final String? dinner;

  String? forSlot(MealSlot s) => switch (s) {
        MealSlot.breakfast => breakfast,
        MealSlot.lunch     => lunch,
        MealSlot.dinner    => dinner,
      };
}

class DietMealPlanException implements Exception {
  const DietMealPlanException(this.message);
  final String message;
  @override
  String toString() => 'DietMealPlanException: $message';
}

const _dartDefineKey =
    String.fromEnvironment('GEMINI_API_KEY', defaultValue: '');
final String _kDietPlanApiKey =
    kGeminiApiKey.isNotEmpty ? kGeminiApiKey : _dartDefineKey;

class DietMealPlanService {
  DietMealPlanService._();
  static final instance = DietMealPlanService._();

  late final GenerativeModel _model = GenerativeModel(
    model:             'gemini-2.5-flash-lite',
    apiKey:            _kDietPlanApiKey,
    systemInstruction: Content.system(_systemPrompt),
    generationConfig:  GenerationConfig(
      responseMimeType: 'application/json',
      temperature:      0.6,
    ),
  );

  static const _systemPrompt = '''
You are ChowSA's South African meal-planning assistant. The user gives you
a budget, a number of days, a diet, and which meal slots they want filled.
You return a JSON grid of MEAL NAMES ONLY — no ingredients, no steps.

OUTPUT SHAPE — strict JSON:
{
  "days": [
    { "label": "Day 1", "breakfast": "Oats with banana", "lunch": "...", "dinner": "..." },
    { "label": "Day 2", "breakfast": "...", "lunch": null, "dinner": "..." }
  ],
  "estimated_total_zar": 845.00
}

SERVING SIZE:
- The user supplies a per-meal serving count. SCALE your ZAR estimate
  for the whole plan to that serving count — a 4-person household eats
  twice the food (and pays twice the grocery bill) of a 2-person one.
- The serving count does NOT change which meals you propose, only the
  total cost line.

RULES:
- Return ONLY raw JSON. No markdown code fences. No prose.
- Slots that the user did NOT request must be set to null.
- "label" is the day order, e.g. "Day 1", "Day 2", … "Day N".
- "estimated_total_zar" is your honest best guess of total grocery cost
  for the whole plan in ZAR. Favour SA staples, in-season produce, and
  retailer house brands (PnP, Checkers, Shoprite, Boxer) to stay under
  the user's budget when one is supplied.
- Use SA dish names where possible (Pap & Wors, Bobotie, Cape Malay
  Curry, Chakalaka, Bunny Chow, Roosterkoek, Boere Mince, Samp & Beans).
- Vary across the week — never repeat the same meal name twice unless
  the user explicitly asked for it.
- When a diet is supplied, EVERY meal in the grid must satisfy it.
  Vegan = strictly plant-based. Anti-inflammatory = whole foods, omega-3
  rich, low refined sugar. Carnivore = meat / eggs / dairy only.
  Diabetic-friendly = low GI, no added sugar, balanced macros.
  Keto = high fat, very low carb. Mediterranean = veg, olive oil, fish.
  Gluten-free = no wheat / barley / rye. Halaal / Kosher follow the
  respective dietary laws.
- For "Custom: …" diets, treat the text after the colon as a strict
  filter and apply it as literally as you can.
''';

  /// Generates an [n]-day meal plan. [slots] decides which slots to fill;
  /// at least one must be supplied. [budgetZar] is optional — when null
  /// the cost line is decorative only. [diet] is the freeform string the
  /// UI passes (one of the curated chips, or "Custom: …").
  Future<DietMealPlanResult> generate({
    required int           days,
    required String        diet,
    required Set<MealSlot> slots,
    double?                budgetZar,
    int?                   servings,
  }) async {
    if (days < 1 || days > 14) {
      throw const DietMealPlanException('Pick between 1 and 14 days.');
    }
    if (slots.isEmpty) {
      throw const DietMealPlanException(
        'Pick at least one meal slot (breakfast / lunch / dinner).',
      );
    }
    // Honour the user's settings serving size unless the caller pinned
    // one. Two-person default matches kServingsDefault.
    final servingCount = servings ?? await readDefaultServings();
    if (_kDietPlanApiKey.isEmpty) {
      return _mockPlan(days: days, slots: slots);
    }

    final slotList = slots.map((s) => s.name).join(', ');
    final budgetLine = budgetZar != null && budgetZar > 0
        ? 'Budget: R${budgetZar.toStringAsFixed(2)} total for the whole '
          'plan, scaled to the serving size below. Aim to stay under '
          'this; if the cheapest realistic plan still goes over, that\'s '
          'OK — return your honest estimate, the app will surface the gap.'
        : 'Budget: unspecified — propose sensibly-priced everyday meals.';

    final prompt =
        'Generate a $days-day meal plan.\n'
        '$budgetLine\n'
        'Servings per meal: $servingCount\n'
        'Diet: $diet\n'
        'Fill these slots only: $slotList\n'
        'Other slots must be null.';

    late final GenerateContentResponse response;
    try {
      response = await _model.generateContent([Content.text(prompt)]);
    } on GenerativeAIException catch (e) {
      throw DietMealPlanException(e.message);
    } catch (e) {
      throw DietMealPlanException(e.toString());
    }

    final text = response.text?.trim();
    if (text == null || text.isEmpty) {
      throw const DietMealPlanException('Empty AI response.');
    }
    return _parse(text);
  }

  DietMealPlanResult _parse(String raw) {
    final unfenced = _stripFence(raw);
    Map<String, dynamic> data;
    try {
      data = jsonDecode(unfenced) as Map<String, dynamic>;
    } catch (e) {
      throw DietMealPlanException('Bad JSON from AI: $e');
    }
    final daysJson = (data['days'] as List<dynamic>?) ?? const [];
    final out = <DietPlannedDay>[];
    for (var i = 0; i < daysJson.length; i++) {
      final d = daysJson[i];
      if (d is! Map<String, dynamic>) continue;
      String? clean(String key) {
        final v = d[key];
        if (v == null) return null;
        if (v is String) {
          final t = v.trim();
          return t.isEmpty ? null : t;
        }
        return null;
      }
      out.add(DietPlannedDay(
        label:     (d['label'] as String?)?.trim() ?? 'Day ${i + 1}',
        breakfast: clean('breakfast'),
        lunch:     clean('lunch'),
        dinner:    clean('dinner'),
      ));
    }
    if (out.isEmpty) {
      throw const DietMealPlanException(
        'AI returned no meals. Try a different budget or diet.',
      );
    }
    final est = (data['estimated_total_zar'] as num?)?.toDouble();
    return DietMealPlanResult(days: out, estimatedTotalZar: est);
  }

  String _stripFence(String s) {
    final t = s.trim();
    final m = RegExp(r'^```(?:json)?\s*([\s\S]*?)\s*```$').firstMatch(t);
    return m != null ? m.group(1)! : t;
  }

  DietMealPlanResult _mockPlan({
    required int days,
    required Set<MealSlot> slots,
  }) {
    const fillerBreak = [
      'Oats with banana',
      'Vegan smoothie bowl',
      'Egg & avo on toast',
      'Mealie meal porridge',
      'Yoghurt & berries',
      'Peanut-butter toast',
      'Fruit & rooibos',
    ];
    const fillerLunch = [
      'Chickpea Cape curry',
      'Veg wrap with hummus',
      'Boere mince on rice',
      'Lentil soup & roosterkoek',
      'Tuna salad pita',
      'Vegan kota',
      'Roast veg & quinoa',
    ];
    const fillerDinner = [
      'Vegan lentil bobotie',
      'Soy-mince cottage pie',
      'Cape Malay curry & rice',
      'Butternut & bean potjie',
      'Grilled snoek & samp',
      'Veg lasagne',
      'Pap & chakalaka',
    ];
    final out = <DietPlannedDay>[];
    for (var i = 0; i < days; i++) {
      out.add(DietPlannedDay(
        label:     'Day ${i + 1}',
        breakfast: slots.contains(MealSlot.breakfast)
            ? fillerBreak[i % fillerBreak.length] : null,
        lunch:     slots.contains(MealSlot.lunch)
            ? fillerLunch[i % fillerLunch.length] : null,
        dinner:    slots.contains(MealSlot.dinner)
            ? fillerDinner[i % fillerDinner.length] : null,
      ));
    }
    return DietMealPlanResult(days: out, estimatedTotalZar: null);
  }
}
