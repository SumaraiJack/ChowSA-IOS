import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'package:google_generative_ai/google_generative_ai.dart';
import '../models/recipe.dart';
import '../models/ingredient.dart';
import '../config/env.config.dart';
import '../config/servings_pref.dart';
import '../state/vegan_mode.dart';
import 'recipe_tag_validator.dart';

// ─────────────────────────────────────────────────────────────────────────────
// API KEY — resolved at startup (same logic as scraper_service.dart).
// When both sources are empty, generateFromPantry() and detectIngredientsFromImage()
// return built-in mock data so all features remain testable without a live key.
// ─────────────────────────────────────────────────────────────────────────────
const _dartDefineKey = String.fromEnvironment('GEMINI_API_KEY', defaultValue: '');
final String _apiKey  = kGeminiApiKey.isNotEmpty ? kGeminiApiKey : _dartDefineKey;

class PantryService {
  // gemini-2.5-flash-lite for recipe generation (text only) — 6x cheaper,
  // perfectly capable for structured JSON recipe output.
  late final GenerativeModel _model = GenerativeModel(
    model: 'gemini-2.5-flash-lite',
    apiKey: _apiKey,
    systemInstruction: Content.system(systemPrompt),
    generationConfig: GenerationConfig(
      responseMimeType: 'application/json',
      // Higher temperature + nucleus sampling so back-to-back "Regenerate"
      // taps don't keep returning the same three dishes. Combined with the
      // explicit exclusion list (passed via `excludeTitles`), this makes
      // each regeneration meaningfully different.
      temperature: 0.95,
      topP:        0.95,
      topK:        50,
    ),
  );

  // ── Public API ──────────────────────────────────────────────────────────────

  /// Sends [ingredients] to Gemini and returns exactly 3 SA recipes.
  ///
  /// [isEmergencyMode] — when true, restricts all recipes to gas hob / braai /
  /// potjie methods with zero electric appliances.
  ///
  /// [isBudgetMode] + [budgetCeiling] — when active, constrains ingredient
  /// choices to cheap staples and explicitly tells the model the rand ceiling.
  ///
  /// Falls back to built-in mock SA recipes when the key is missing or the
  /// API fails.
  Future<List<Recipe>> generateFromPantry(
    List<String> ingredients, {
    bool         isEmergencyMode = false,
    bool         isBudgetMode    = false,
    double?      budgetCeiling,
    /// Titles already on screen — passed back into the prompt as an
    /// explicit exclusion list so "Regenerate" gives the user fresh
    /// ideas instead of cycling the same three dishes.
    List<String> excludeTitles = const <String>[],
  }) async {
    if (ingredients.isEmpty) {
      throw const PantryException('Add at least one ingredient to your pantry first.');
    }

    // ── Load the user's saved serving size from SharedPreferences ─────────
    // Defaults to kServingsDefault (2) when nothing is persisted yet, so the
    // very first generation after install still produces a sensible portion.
    final int defaultServingSize = await readDefaultServings();

    // Pass flags to mock so combined scenario returns the right fallback data.
    if (_apiKey.isEmpty) {
      return _mockRecipes(
        ingredients,
        isEmergencyMode: isEmergencyMode,
        isBudgetMode:    isBudgetMode,
      );
    }

    try {
      final bulletList   = ingredients.map((i) => '- $i').join('\n');
      final contextBlock = _buildContextBlock(
        isEmergencyMode: isEmergencyMode,
        isBudgetMode:    isBudgetMode,
        budgetCeiling:   budgetCeiling,
      );
      // Exclusion block — never empty when the user taps Regenerate from
      // a successful result state. Forces Gemini to swap cooking methods,
      // proteins, or culinary direction on each retry.
      final exclusionBlock = excludeTitles.isEmpty
          ? ''
          : 'EXCLUSION LIST — DO NOT REPEAT OR VARY:\n'
            'The user has just seen the following three recipes and is '
            'tapping Regenerate to get fresh, different ideas. You MUST '
            'NOT output any recipe whose title, primary cooking method, '
            'or main protein matches any of these:\n'
            '${excludeTitles.map((t) => '  • $t').join('\n')}\n'
            'If any of your generated recipes resembles the above list, '
            'replace it with a clearly different culinary direction '
            '(different protein, different heat method, or different '
            'meal type — e.g. swap a stir-fry for a braai, swap beef for '
            'pilchards or eggs, swap a hot dish for a fresh slaw or '
            'salad). Variety across the three recipes is mandatory: '
            'aim for one braai/potjie, one quick stovetop/gas-hob '
            'dish, and one fresh / no-cook side or assembly.';

      // Inject the serving size as a CRITICAL constraint. Restating it twice
      // (once at the top, once at the bottom) materially raises compliance
      // rates on Gemini for "you must scale" type instructions.
      final servingsBlock =
          'CRITICAL REQUIREMENT: You MUST scale all ingredient quantities and '
          'portion sizes for each recipe to yield EXACTLY $defaultServingSize '
          'servings. State the serving size clearly at the top of each '
          'recipe title (e.g., "Cape Malay Curry — serves $defaultServingSize"). '
          'Do NOT generate recipes for any other portion count.';

      final ingredientBlock =
          'Here are the ingredients currently available in my pantry:\n\n$bulletList\n\n'
          'Please generate 3 creative, distinct South African recipes using '
          'primarily these ingredients, scaled for $defaultServingSize servings.';

      final blocks = <String>[
        if (contextBlock.isNotEmpty)   contextBlock,
        if (exclusionBlock.isNotEmpty) exclusionBlock,
        servingsBlock,
        ingredientBlock,
        if (VeganMode.promptDirective.isNotEmpty)
          VeganMode.promptDirective.trim(),
      ];
      final prompt = blocks.join('\n\n');
      final rawJson = await _callGemini(prompt);
      // Auto image hydration ripped 2026-06-23 — Wikipedia/Pixabay
      // matches were unreliable; the pantry cards now use emoji/initials.
      return _parseRecipes(rawJson);
    } catch (_) {
      // On any network / quota / parse failure, return context-aware mock data
      // so the combined UI can be verified offline.
      return _mockRecipes(
        ingredients,
        isEmergencyMode: isEmergencyMode,
        isBudgetMode:    isBudgetMode,
      );
    }
  }

  // ── Context block builder ───────────────────────────────────────────────────
  //
  // Builds a structured constraint header prepended to every Gemini request.
  // Uses a Map so each active flag contributes exactly one named constraint entry,
  // and both can be combined freely without any flag overwriting the other.

  static String _buildContextBlock({
    required bool   isEmergencyMode,
    required bool   isBudgetMode,
    double?         budgetCeiling,
  }) {
    final constraints = <String, String>{};

    if (isEmergencyMode) {
      constraints['power'] =
          'CRITICAL: The user has NO ELECTRICITY — "No Electricity? No Problem!" mode '
          'is active. Generate ONLY recipes from these FOUR approved categories:\n'
          '  1. Completely raw/cold assembly — zero heat of any kind required '
          '(e.g. salads, kotas, no-cook dips, cold rolls).\n'
          '  2. Outdoor braai / potjie / open-fire — recipe TITLE must explicitly '
          'include "Braai-Grid", "Braai", "Potjie", or "Open-Fire".\n'
          '  3. Gas-hob cooking — recipe TITLE must explicitly include "Gas-Hob" '
          '(e.g. "Gas-Hob Chakalaka Pap", "Gas-Hob Boerewors Fry").\n'
          '  4. Skottel braai — recipe TITLE must explicitly include "Skottel" '
          '(e.g. "Skottel Chicken Stir-Fry", "Skottel Vetkoek").\n'
          'STRICTLY FORBIDDEN — do not use, mention, or imply ANY of these:\n'
          '  ✗ Electric oven or microwave\n'
          '  ✗ Electric kettle or toaster\n'
          '  ✗ Electric blender, food processor, or stand mixer\n'
          '  ✗ Electric stove plate or induction hob\n'
          '  ✗ Air fryer or any plug-in appliance\n'
          'Set isLoadsheddingFriendly to true for ALL 3 recipes.\n'
          'Set isBraaiReady to true for braai/potjie/open-fire/skottel recipes, '
          'false for gas-hob and raw preparations.\n'
          '\n'
          'RAW PROTEIN SAFETY (NON-NEGOTIABLE in no-power mode):\n'
          '  ✗ NEVER suggest a raw poultry / red meat / pork / fresh-fish dish '
          'as a cold/raw assembly (category 1). Raw meat in a salad, sandwich, '
          'wrap, bowl, or kota is a food-safety hazard — FORBIDDEN.\n'
          '  ✓ Raw proteins from the pantry may ONLY be used in categories 2, 3 '
          'or 4 (braai / potjie / open-fire / gas-hob / skottel) where the '
          'recipe TITLE explicitly names the heat source AND the instructions '
          'cook the protein to safe internal temperature.\n'
          '  ✓ Category 1 (raw/cold assembly) recipes may ONLY use cold-safe '
          'proteins: tinned fish (pilchards, tuna, sardines), biltong, '
          'droëwors, pre-cooked/leftover meat explicitly labelled "cooked X", '
          'cheese, amasi, yoghurt, hard-boiled eggs, or canned legumes.\n'
          '  ✓ If the pantry has raw chicken / mince / beef / pork / fresh '
          'fish AND the user has no braai/gas equipment implied, simply OMIT '
          'that protein from the recipe. Do not serve it raw.';
    }

    if (isBudgetMode) {
      final cap = budgetCeiling != null
          ? 'R${budgetCeiling.toStringAsFixed(0)}'
          : 'R100';
      constraints['budget'] =
          'CRITICAL: The user is on a strict $cap budget. Prioritise stretching '
          'basic local staples and avoid any premium or expensive ingredients. '
          'Rely on pap / mealie meal, Lucky Star pilchards, canned chakalaka, '
          'dried samp & beans, cabbage, potatoes, onions, and Knorrox cubes. '
          'Total ingredient cost for each recipe must stay well under $cap.';
    }

    if (constraints.isEmpty) return '';

    final lines = constraints.entries
        .map((e) => '[${e.key.toUpperCase()}] ${e.value}')
        .join('\n');

    return '=== AUNTY CHOW CONTEXT CONSTRAINTS ===\n$lines\n=======================================';
  }

  // ── System prompt ───────────────────────────────────────────────────────────

  static const String systemPrompt = '''
You are a Cape Town home chef with deep knowledge of South African cuisine — heavily leaning into authentic Cape and Cape Malay cooking from the Bo-Kaap, the Cape Flats, and the Cape coast, alongside broader SA classics (potjiekos, braais, township staples, Afrikaans farmhouse cooking).

You will be given a list of raw pantry ingredients. Generate exactly 3 creative, distinct South African recipes that heavily prioritise using ONLY those ingredients. You may supplement with universal pantry staples (salt, pepper, oil, water, basic spices) but must NOT introduce ingredients outside that list.

CAPE-FORWARD BIAS — When the ingredients fit, prefer authentic Cape and Cape Malay dishes over generic "South African" filler. Examples to draw on:
  ✓ Bredies (tomato bredie, waterblommetjie bredie, green bean bredie)
  ✓ Cape Malay curries (denningvleis, tamatie bredie, sweet-spiced lamb)
  ✓ Smoorsnoek, snoek pâté, snoek braai with apricot glaze
  ✓ Bokkoms, pickled fish, masala fish
  ✓ Gatsby (Cape sub), salomies (curry roti wraps)
  ✓ Daltjies (chilli bites), samoosas, pakoras with dhania
  ✓ Boeber, koesisters (Cape Malay), hertzoggies, brandy pudding
  ✓ Pampoenkoekies, hoenderpastei (chicken pie), boboties
  ✓ Bo-Kaap kos: warm spices (cinnamon, cardamom, naartjie peel, allspice)
  ✓ Cape coastline seafood: yellowtail, snoek, hake, mussels, crayfish

Reach for Cape ingredients/techniques first; fall back to broader SA dishes (braais, potjies, pap-and-vleis, chakalaka) only if the pantry doesn't support a Cape-leaning recipe.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
OUTPUT FORMAT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Return ONLY a single raw JSON object — no markdown, no code fences, no explanation.

{
  "recipes": [
    {
      "title": "string",
      "ingredients": [
        {
          "quantity": number | null,
          "unit": "string | null",
          "name": "string",
          "localizedName": "string | null"
        }
      ],
      "instructions": ["string", "string", ...],
      "isLoadsheddingFriendly": boolean,
      "isBraaiReady": boolean
    }
  ]
}

The array must contain exactly 3 recipe objects.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
INGREDIENTS RULES
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
- You are an AI culinary system optimized EXCLUSIVELY for the South African
  retail market (ChowSA). Every ingredient must be something a SA home cook
  would actually pick off a Checkers / Pick n Pay / Shoprite / Spar shelf.
- NEVER output pre-fabricated, combination, or Americanised "convenience"
  products that don't exist on SA shelves. Examples that MUST be rejected:
    ✗ "1 can of creamed spinach"   ✗ "canned cheese sauce"
    ✗ "1 jar Alfredo sauce"        ✗ "boxed mac and cheese"
    ✗ "Velveeta cheese"            ✗ "Hamburger Helper"
    ✗ "1 packet of taco seasoning mix" (use the individual spices instead)
    ✗ "1 can cream of mushroom soup" (use mushrooms + cream + stock)
- DECONSTRUCT every combined / pre-made item into its primary, separately-
  purchasable base ingredients. The user has to be able to tick each item
  off their pantry inventory. Examples of correct deconstruction:
    "creamed spinach"              → "spinach" + "fresh cream" + "onion" + "garlic"
    "creamed sweetcorn"            → "sweetcorn kernels" + "fresh cream"
    "cream of mushroom soup"       → "mushrooms" + "fresh cream" + "stock" + "butter"
    "Alfredo sauce"                → "fresh cream" + "butter" + "parmesan" + "garlic"
    "ranch dressing"               → "mayonnaise" + "buttermilk" + "garlic powder" + "herbs"
    "taco seasoning"               → "paprika" + "cumin" + "garlic powder" + "chilli powder"
    "pumpkin pie spice"            → "cinnamon" + "ginger" + "nutmeg" + "cloves"
- A real-world SA brand that maps to a single base ingredient is fine
  (e.g. "Koo baked beans", "Lucky Star pilchards", "All Gold tomato sauce")
  — only the multi-component composite goods above are forbidden.
- Split every ingredient into quantity, unit, and name.
  Example: "2 cups rice" → quantity: 2, unit: "cups", name: "rice"
- Set quantity and unit to null when no specific amount applies (e.g. "salt to taste").
- Use decimal numbers for fractions: ½ → 0.5, ¼ → 0.25.
- "name" must be the ORIGINAL term from the pantry list or closest natural form.
- "localizedName" must be the standard South African equivalent if it differs; null otherwise.

South African localization reference (not exhaustive):
  Cilantro → Coriander | Eggplant → Brinjal | Zucchini → Baby marrow
  Ground beef → Mince | Heavy cream → Whipping cream | Arugula → Rocket
  Cornstarch → Maizena | All-purpose flour → Cake flour | Whole milk → Full-cream milk
  Half-and-half → Light cream | Biscuits (US) → Scones | Candy → Sweets

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
MZANSI GROCERY LEXICON
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
You are an expert on South African grocery products. When processing text inputs
or recognising food from image tokens, accurately resolve local brand names to
their culinary categories — never categorise them generically:

  Pantry Staples (Maize Meal):
    White Star, Iwisa, Ace, Nyala, Impala, Tafelberg → maize meal / pap / mealie
    meal. Treat "pap", "stywe pap", "krummelpap" as cooked maize porridge.
  Pantry Staples (Rice & Grains):
    Tastic, Spekko → long-grain rice; samp + umngqusho → dried hominy.
  Pantry Staples (Baking):
    Snowflake, Sasko → flour; Maizena → corn starch; Royco / Knorrox → stock.
  Pantry Staples (Canned Veg / Beans):
    Koo → baked beans, chakalaka, canned vegetables.
  Meat & Fish (Tinned Fish):
    Lucky Star, Saldanha, Glenryck → pilchards or tinned fish.
    Boerewors / droëwors / biltong are SA dried meats.
  Condiments & Sauces:
    All Gold → tomato sauce. Mrs. Ball's / Ball's Chutney → chutney.
    Crosse & Blackwell → mayonnaise. Nando's → peri-peri sauce.
    Black Cat / Yum Yum → peanut butter.
  Spices & Herbs:
    Aromat → universal seasoning. Rajah, Robertsons → curry powders and spices.
    Ina Paarman, Cape Herb & Spice → spice blends. "Braai spice / chicken spice"
    are SA seasoning blends.
  Beverages:
    Rooibos, Freshpak, Joko, Five Roses → tea. Oros, Halls → cordial / squash.
    Ricoffy, Frisco, Caro → instant coffee or coffee substitute.
    Milo, Horlicks → malted drinks. Liqui-Fruit, Ceres → fruit juice.

When a pantry list contains any of these brand tokens, treat them as the
mapped category in your recipe planning. Do not invent "pancake mix from
Iwisa" — Iwisa is maize meal for pap, not a baking mix.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
MZANSI STYLE — "YOU KNOW MOS"
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Recipes must be practical, easy, and down-to-earth for the everyday South African home cook.

DO:
  ✓ Quick pan-fries, one-pot stews, braai meats, pap combinations, simple salads
  ✓ Recipes ready in under 45 minutes using common pantry staples
  ✓ Comfort food and township classics (chakalaka, pap, pilchards, boerewors, vetkoek)
  ✓ Honest, high-flavour combinations with minimal fuss
  ✓ Amasi or yoghurt bowls, fruit salads with honey-lemon, quick braai-side relishes

DO NOT:
  ✗ Complex baked desserts: crumbles, tarts, compotes, soufflés, baked puddings
  ✗ Multi-step restaurant techniques (fold egg whites, deglaze, temper chocolate)
  ✗ Gourmet fusion or dishes requiring specialist equipment
  ✗ When fruit (bananas, apples, oranges, mangoes) appears in the pantry, do NOT
    generate baked crumbles, pies, or dessert reductions — use them raw or in quick
    salads, salsas, or braai-side relishes instead.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
INSTRUCTIONS RULES
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
- Each step must be a single, actionable sentence or short paragraph.
- Do NOT include step numbers — the array order implies them.
- Write in plain, friendly South African English.
- Make the 3 recipes clearly distinct: vary cooking methods, flavour profiles, and meal types.
  Aim for: one braai or open-fire dish, one quick stovetop meal, one cold/raw no-cook dish.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
LOADSHEDDING FLAG — STRICT RULES
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
"isLoadsheddingFriendly" is a STRICT flag. Apply these rules WITHOUT EXCEPTION:

Set to TRUE only in ONE of these two cases:
  CASE 1 — RAW/COLD ONLY: Every step is cold preparation. Zero heat of any kind is
           required (e.g., fruit salad, cold slaw, amasi bowl, no-cook dip).
  CASE 2 — EXPLICITLY ADAPTED: The recipe TITLE explicitly names an alternative heat
           source: "Braai-Grid …", "Gas-Hob …", "Potjie …", or "Open-Fire …".
           The alternative source MUST appear in the recipe title itself.

Set to FALSE in ALL other cases:
  ✗ ANY thermal cooking that does not meet Case 2 — including gas-hob cooking whose
    title does not explicitly say "Gas-Hob".
  ✗ Frying, boiling, simmering, baking, steaming, toasting (unless Case 2).
  ✗ Recipes titled "Fried X", "Stir-Fried X", "Boiled X", "Baked X", "Steamed X".
  ✗ ALWAYS default to false when uncertain.

CRITICAL EXAMPLES (follow these exactly):
  "Fried Bananas with Apple Sauce"   → isLoadsheddingFriendly: false
  "Gas-Hob Fried Bananas"            → isLoadsheddingFriendly: true  (Case 2)
  "Citrus Fruit Salad"               → isLoadsheddingFriendly: true  (Case 1)
  "Cape Malay Curry"                 → isLoadsheddingFriendly: false
  "Braai-Grid Peri-Peri Chicken"     → isLoadsheddingFriendly: true  (Case 2)
  "One-Pot Potjie"                   → isLoadsheddingFriendly: true  (Case 2)
  "Banana & Peanut Butter Toast"     → isLoadsheddingFriendly: false

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
BRAAI READY FLAG
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Set "isBraaiReady" to true ONLY if the cooking method explicitly uses a braai grid,
kettle braai, potjie pot on coals, or open fire / coals.
Set it to false for gas hob, oven, stovetop, no-cook, and all other methods.
When isBraaiReady is true, isLoadsheddingFriendly must also be true (Case 2).

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
FINAL SELF-AUDIT — RUN BEFORE RETURNING JSON
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
For EACH of the 3 recipes, audit the tag/instruction pair against the
forbidden-keyword tables below. If a tag conflicts, either DROP the tag
(set to false) or REWRITE the offending step to remove the forbidden
verb. NEVER ship a contradiction.

If isLoadsheddingFriendly == true, instructions MUST NOT contain any of:
  microwave, microwaved, microwaving
  oven, oven-baked, preheat
  bake, baked, baking
  air fry, air-fry, air fryer, airfryer
  electric stove, electric hob, electric plate, induction, induction hob
  deep fry, deep-fry, deep fryer
  food processor, blender, blitz
  slow cooker, slow-cooker, pressure cooker, instant pot
  toaster, kettle, rice cooker, waffle iron, stand mixer, hand mixer, electric whisk
  (Gas-hob frying/searing is permitted — title MUST then say "Gas-Hob …".)

If isBraaiReady == true, instructions MUST include at least one of:
  braai, coals, coal, open fire, fire pit, wood fire,
  grid, grill over, potjie, three-legged pot, sosatie, kettle braai, weber

The validator on the client side enforces these rules a second time.
Any recipe that fails the audit gets its tag silently flipped to false,
which is a usability degradation. Audit BEFORE returning.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
RAW PROTEIN SAFETY RULES — NON-NEGOTIABLE
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
FOOD-SAFETY HARD RULES. Violating these can make a user sick.

DEFINITION — "Raw protein" means any of the following from the pantry, UNLESS the
ingredient is explicitly named with a cooked/cured/canned prefix
("cooked", "leftover", "tinned", "canned", "smoked", "cured", "biltong",
"droëwors", "pre-cooked", "rotisserie"):
  • Poultry: chicken, chicken breast, chicken thighs, chicken mince, turkey, duck
  • Red meat: beef, mince, steak, brisket, oxtail, lamb, mutton, chops, ribs
  • Pork: pork, bacon (raw), gammon (raw), pork chops, pork mince
  • Seafood: fresh fish, prawns, calamari, mussels (raw)
  • Sausage: boerewors (raw), sausage, wors
  • Eggs: raw egg whites/yolks used uncooked are NOT permitted in no-cook dishes

RULE A — If a recipe contains any raw protein, the instructions MUST cook that
         protein to safe internal temperature. Never describe a raw protein
         being eaten without cooking. Never put raw chicken / mince / pork /
         raw fish into a salad, sandwich, wrap, bowl, kota, or "assembly"
         dish. This is non-negotiable.

RULE B — A recipe whose ingredients include a raw protein can ONLY have
         "isLoadsheddingFriendly": true if its TITLE explicitly names a
         non-electric heat source: "Braai-Grid", "Braai", "Potjie", "Open-Fire",
         "Gas-Hob", or "Skottel" (i.e. Case 2 above). This is the ONLY way a
         raw-protein recipe is no-power friendly.

RULE C — A no-cook / cold-assembly recipe (Case 1: "isLoadsheddingFriendly":
         true with no heat source in the title) may ONLY contain proteins
         from this approved cold-protein list:
           ✓ Tinned fish (Lucky Star pilchards, tuna, sardines)
           ✓ Biltong, droëwors, salami, prosciutto, cured / smoked meats
           ✓ Pre-cooked / leftover proteins (explicitly labelled "cooked X")
           ✓ Cheese, amasi, yoghurt, hummus, eggs (only if separately hard-
             boiled or pickled)
           ✓ Beans / legumes from a can (chickpeas, kidney beans, baked beans)
         Any raw poultry / red meat / pork / fresh fish in the pantry must
         either be cooked in the recipe (failing Case 1) or excluded entirely.

RULE D — If the pantry list contains a raw protein with NO non-electric heat
         source available to use it (e.g. you're in no-power mode and the user
         hasn't named gas / braai equipment), you MUST simply NOT use that
         protein in this recipe. Build the recipe around the cold-safe items
         in the pantry instead. Better to skip the chicken than to serve it raw.

CRITICAL EXAMPLES — follow these exactly:
  "Chicken & Parsley Rice Salad"             → FORBIDDEN if chicken is raw.
                                                Either retitle to
                                                "Braai-Grid Chicken & Parsley
                                                Rice Salad" with a cooking
                                                step, or drop the chicken.
  "Raw Mince & Onion Wrap"                   → ALWAYS FORBIDDEN.
  "Cooked Chicken & Rice Salad"              → OK as Case 1 only when the
                                                pantry ingredient is
                                                explicitly "cooked chicken".
  "Pilchard, Tomato & Onion Salad"           → OK (tinned fish, cold-safe).
  "Braai-Grid Chicken Skewers with Rice"     → OK (Case 2 + cooks the raw
                                                chicken on the braai).
''';

  // ── Gemini call ─────────────────────────────────────────────────────────────

  // ── Ingredient detection from image ─────────────────────────────────────────

  /// Sends [imageBytes] to Gemini Vision and returns a [PantryScanResult]:
  /// the detected ingredient list AND, when the image is clearly a labelled
  /// recipe card (cookbook page, blog screenshot, hand-written card, etc.),
  /// the recipe's title — so the UI can render a "Save to My Recipes" entry
  /// with the right name instead of "Generated from: text".
  ///
  /// For a generic fridge / pantry shelf photo there is no title to extract,
  /// so `recipeTitle` is null in that case and the caller falls back to its
  /// existing "ingredients found" header copy.
  Future<PantryScanResult> detectIngredientsFromImage(Uint8List imageBytes) async {
    // Mock mode: simulate a successful fridge scan with common SA ingredients.
    // No title — the mock represents a fridge interior, not a recipe card.
    if (_apiKey.isEmpty) {
      await Future.delayed(const Duration(seconds: 2)); // simulate scan time
      return const PantryScanResult(
        recipeTitle: null,
        ingredients: [
          'chicken thighs', 'baby marrow', 'tomatoes', 'onions',
          'garlic', 'eggs', 'full-cream milk', 'cheddar cheese',
          'boerewors', 'mealie meal', 'butternut', 'sweet chilli sauce',
        ],
      );
    }

    // Keep gemini-2.5-flash for vision — better OCR accuracy on cluttered
    // fridge shelves AND on dense recipe-card typography.
    final visionModel = GenerativeModel(
      model:            'gemini-2.5-flash',
      apiKey:           _apiKey,
      generationConfig: GenerationConfig(temperature: 0.1),
    );

    late final GenerateContentResponse response;
    try {
      response = await _runWithRetry(
        label: 'visionModel.generateContent',
        call:  () => visionModel.generateContent([
        Content.multi([
          DataPart('image/jpeg', imageBytes),
          TextPart(
            'You are an AI culinary system optimized EXCLUSIVELY for the '
            'South African retail market (ChowSA). Look at this photo and '
            'extract every distinct food ingredient you can see or read — '
            'on shelves, in containers, loose produce, packaged goods, OR '
            'printed on a recipe card / cookbook page / blog screenshot.\n\n'
            'If the photo is clearly a labelled recipe (a title is visible '
            'on the page), also capture the recipe title verbatim.\n\n'
            'Rules:\n'
            '- Use South African names: brinjal, baby marrow, mince, '
            'Maizena, cake flour, full-cream milk, coriander, rocket.\n'
            '- Be specific but concise: "free-range eggs", "long-grain rice".\n'
            '- Ignore non-food items, containers, and appliances.\n'
            '- NEVER output pre-fabricated, combination, or Americanised '
            'convenience products that do not exist on SA shelves '
            '("creamed spinach", "canned cheese sauce", "Alfredo sauce", '
            '"Hamburger Helper", "Velveeta", "cream of mushroom soup", '
            '"taco seasoning mix", etc.).\n'
            '- DECONSTRUCT any combined / pre-made item into its primary, '
            'separately-purchasable base ingredients so the user can track '
            'each one in their pantry inventory. For example, parse '
            '"creamed spinach" strictly as separate entries for "spinach" '
            'and "fresh cream" (plus "onion" / "garlic" if visible); '
            '"cream of mushroom soup" → "mushrooms" + "fresh cream" + '
            '"stock"; "ranch dressing" → "mayonnaise" + "buttermilk" + '
            '"herbs". A real SA brand that maps to a single base item '
            '(Koo, Lucky Star, All Gold, Mrs Ball\'s, Aromat) is fine.\n'
            '- Between 1 and 30 ingredients.\n'
            '- Return ONLY a raw JSON object with no markdown and no code '
            'fences, matching this exact shape:\n'
            '{\n'
            '  "recipe_title": "Name of the dish (e.g., Chocolate Cake), '
            'or null if the photo is not a labelled recipe",\n'
            '  "ingredients": ["eggs", "milk", "chicken breast"]\n'
            '}',
          ),
        ]),
      ]),
      );
    } on GenerativeAIException catch (e) {
      throw PantryException('Gemini API error: ${e.message}');
    } catch (e) {
      throw PantryException('Could not analyse the photo. Try again.\n\n$e');
    }

    final text = response.text;
    if (text == null || text.trim().isEmpty) {
      throw const PantryException(
          'Could not identify any ingredients from this photo. '
          'Try with better lighting or a clearer angle.');
    }

    try {
      // Strip JSON fences defensively.
      final trimmed = text.trim();
      final fenced  = RegExp(r'^```(?:json)?\s*([\s\S]*?)\s*```$').firstMatch(trimmed);
      final clean   = fenced != null ? fenced.group(1)! : trimmed;
      final decoded = jsonDecode(clean);

      // Accept BOTH shapes for forward/backward compat:
      //   • new contract: {"recipe_title": "...", "ingredients": [...]}
      //   • legacy plain array: ["eggs", "milk", ...]
      if (decoded is List) {
        return PantryScanResult(
          recipeTitle: null,
          ingredients: decoded
              .map((e) => (e as String).trim())
              .where((s) => s.isNotEmpty)
              .toList(),
        );
      }
      if (decoded is Map<String, dynamic>) {
        final rawTitle = (decoded['recipe_title'] as String?)?.trim();
        final title    = (rawTitle != null && rawTitle.isNotEmpty && rawTitle.toLowerCase() != 'null')
            ? rawTitle
            : null;
        final ings = (decoded['ingredients'] as List?)
                ?.map((e) => (e as String).trim())
                .where((s) => s.isNotEmpty)
                .toList() ??
            const <String>[];
        return PantryScanResult(recipeTitle: title, ingredients: ings);
      }
      throw const FormatException('Unexpected scan response shape');
    } catch (_) {
      throw const PantryException(
          'Gemini returned an unexpected format. Please try again.');
    }
  }

  Future<String> _callGemini(String userPrompt) async {
    if (_apiKey.isEmpty) {
      throw const PantryException(
        'Gemini API key not configured.\n\n'
        'Build with:\n  flutter run --dart-define=GEMINI_API_KEY=YOUR_KEY\n\n'
        'Get a free key at https://aistudio.google.com/app/apikey',
      );
    }

    late final GenerateContentResponse response;

    try {
      response = await _runWithRetry(
        label: '_model.generateContent',
        call:  () => _model.generateContent([Content.text(userPrompt)]),
      );
    } on GenerativeAIException catch (e) {
      throw PantryException('Gemini API error: ${e.message}');
    } catch (e) {
      throw PantryException('Could not reach the AI. Check your connection and API key.\n\n$e');
    }

    final text = response.text;
    if (text == null || text.trim().isEmpty) {
      throw const PantryException('Gemini returned an empty response.');
    }

    return _stripJsonFences(text);
  }

  // ── Retry with exponential backoff ─────────────────────────────────────
  //
  // Wraps a Gemini call so transient infra hiccups (503 UNAVAILABLE, 504,
  // socket timeouts, brief network wobbles) don't surface as visible
  // errors. Behaviour:
  //   • Up to 3 attempts total (1 initial + 2 retries).
  //   • Delays: 1s, then 2s — small exponential backoff.
  //   • Only transient shapes retry — auth, malformed prompt, quota
  //     (RESOURCE_EXHAUSTED / 429) all throw on the first failure.
  //   • The caller's awaited Future stays open for the whole retry chain,
  //     so the UI's _Loading state keeps the scanning animation running
  //     smoothly until either a real result or a final failure lands.
  static const int _kMaxAttempts        = 3;
  static const List<Duration> _kBackoff = [
    Duration(seconds: 1),
    Duration(seconds: 2),
  ];

  Future<T> _runWithRetry<T>({
    required Future<T> Function() call,
    required String     label,
  }) async {
    Object? lastErr;
    for (var attempt = 0; attempt < _kMaxAttempts; attempt++) {
      try {
        return await call();
      } catch (e) {
        lastErr = e;
        if (!_isTransient(e) || attempt == _kMaxAttempts - 1) {
          rethrow;
        }
        final wait = _kBackoff[attempt];
        // ignore: avoid_print
        print('[$label] transient error (attempt ${attempt + 1}/$_kMaxAttempts): '
              '$e — retrying in ${wait.inSeconds}s');
        await Future<void>.delayed(wait);
      }
    }
    // Unreachable — the loop either returns or rethrows. The compiler
    // still needs a terminating throw because Dart can't prove that.
    throw lastErr!;
  }

  bool _isTransient(Object e) {
    final s = e.toString().toLowerCase();
    return s.contains('503') ||
           s.contains('500') ||
           s.contains('502') ||
           s.contains('504') ||
           s.contains('unavailable') ||
           s.contains('overloaded') ||
           s.contains('internal') ||
           s.contains('timeout') ||
           s.contains('timed out') ||
           s.contains('socket') ||
           s.contains('failed host lookup') ||
           s.contains('handshake') ||
           s.contains('connection reset') ||
           s.contains('connection closed');
  }

  String _stripJsonFences(String raw) {
    final trimmed = raw.trim();
    final fencePattern = RegExp(r'^```(?:json)?\s*([\s\S]*?)\s*```$');
    final match = fencePattern.firstMatch(trimmed);
    return match != null ? match.group(1)! : trimmed;
  }

  // ── Parsing ─────────────────────────────────────────────────────────────────

  List<Recipe> _parseRecipes(String rawJson) {
    late final Map<String, dynamic> data;

    try {
      data = jsonDecode(rawJson) as Map<String, dynamic>;
    } catch (_) {
      throw PantryException(
        'Gemini returned a response that is not valid JSON.\n\nRaw:\n$rawJson',
      );
    }

    if (data.containsKey('error')) {
      throw PantryException(data['error'] as String);
    }

    final recipeList = data['recipes'];
    if (recipeList is! List || recipeList.isEmpty) {
      throw const PantryException(
        'Gemini returned valid JSON but the "recipes" array is missing or empty.',
      );
    }

    try {
      return recipeList
          .map((e) => Recipe.fromJson({...(e as Map<String, dynamic>), 'sourceUrl': null}))
          .map(_sanitizeRawProteinFlag)
          .map(_sanitizeEnergyTags)
          .toList();
    } catch (e) {
      throw PantryException(
        'One or more recipes did not match the expected schema.\n\nDetails: $e',
      );
    }
  }

  // ── Energy-tag sanitizer (post-Gemini) ─────────────────────────────────────
  //
  // Defense-in-depth: even with the strict "FINAL SELF-AUDIT" rules in the
  // system prompt, Gemini occasionally ships a recipe whose
  // isLoadsheddingFriendly = true contradicts a "deep fry" / "oven" /
  // "microwave" step (the very contradiction reported on the Gatsby card).
  // We run the same keyword tables the client edit-save path uses, and
  // silently flip the tags when they don't survive scrutiny. Tag false is
  // always safe — it just means the badge doesn't appear; the recipe still
  // saves.
  Recipe _sanitizeEnergyTags(Recipe r) {
    final conflicts = RecipeTagValidator.validate(
      instructions:           r.instructions,
      isLoadsheddingFriendly: r.isLoadsheddingFriendly,
      isBraaiReady:           r.isBraaiReady,
    );
    if (conflicts.isEmpty) return r;
    var loadshed = r.isLoadsheddingFriendly;
    var braai    = r.isBraaiReady;
    for (final c in conflicts) {
      if (c.tag == 'No-Power OK')        loadshed = false;
      if (c.tag == 'Braai Ready')        braai    = false;
    }
    if (kDebugMode) {
      debugPrint('[PantryService] tag sanitizer flipped "${r.title}": '
          'loadshed=${r.isLoadsheddingFriendly}->$loadshed, '
          'braai=${r.isBraaiReady}->$braai');
    }
    return Recipe(
      title:                  r.title,
      ingredients:            r.ingredients,
      instructions:           r.instructions,
      isLoadsheddingFriendly: loadshed,
      isBraaiReady:           braai,
      sourceUrl:              r.sourceUrl,
    );
  }

  // ── Raw-protein safety sanitizer ──────────────────────────────────────────
  //
  // Defense-in-depth guard against the model occasionally violating the prompt
  // rules and tagging a recipe like "Chicken & Rice Salad" (raw chicken!) as
  // isLoadsheddingFriendly=true. This is a food-safety issue, not a styling
  // one — we never trust the flag for a raw-protein recipe.
  //
  // Algorithm:
  //   1. Scan ingredients for raw-protein keywords (poultry, red meat, pork,
  //      fresh fish, raw boerewors).
  //   2. If a raw protein is present AND the title does NOT name an explicit
  //      non-electric heat source (Braai / Potjie / Gas-Hob / Skottel /
  //      Open-Fire), the recipe CANNOT be "No-Power OK". Force
  //      isLoadsheddingFriendly = false.
  //   3. Detect "uncooked assembly" titles (Salad / Sandwich / Wrap / Bowl /
  //      Kota / Cold) that contain raw proteins and prefix the title with
  //      "Needs Cook — " so the UI surfaces the warning even if the model
  //      doubled down on a dangerous suggestion.
  //
  // Tokens that EXCLUDE a protein from the "raw" set: "cooked", "leftover",
  // "tinned", "canned", "smoked", "cured", "biltong", "droëwors",
  // "pre-cooked", "rotisserie", "pilchard", "tuna", "sardine".

  static const _kRawProteinTokens = <String>[
    'chicken', 'chicken breast', 'chicken thigh', 'chicken thighs',
    'chicken mince', 'turkey', 'duck',
    'beef', 'mince', 'ground beef', 'steak', 'brisket', 'oxtail',
    'lamb', 'mutton', 'lamb chop', 'mutton chop', 'ribs',
    'pork', 'pork chop', 'pork mince', 'gammon', 'bacon',
    'fresh fish', 'hake', 'kingklip', 'snoek', 'salmon fillet',
    'prawns', 'calamari', 'mussels',
    'boerewors', 'wors', 'sausage',
  ];

  static const _kCookedQualifiers = <String>[
    'cooked', 'leftover', 'tinned', 'canned', 'smoked', 'cured',
    'biltong', 'droëwors', 'droewors', 'pre-cooked', 'precooked',
    'rotisserie', 'pilchard', 'tuna', 'sardine', 'salami', 'prosciutto',
    'ham', 'hard-boiled', 'hardboiled',
  ];

  static const _kHeatSourceMarkers = <String>[
    'braai', 'braai-grid', 'braai grid', 'kettle braai',
    'potjie', 'potjiekos', 'open-fire', 'open fire', 'coals',
    'gas-hob', 'gas hob', 'skottel', 'skottelbraai',
  ];

  static const _kAssemblyTitleMarkers = <String>[
    'salad', 'sandwich', 'wrap', 'bowl', 'kota', 'roll',
    'cold ', 'no-cook', 'raw ',
  ];

  static Recipe _sanitizeRawProteinFlag(Recipe r) {
    final lowerTitle = r.title.toLowerCase();

    // Pre-flight: if the title already names a non-electric heat source, the
    // recipe is allowed to use raw proteins safely (Case 2 of the prompt).
    final hasHeatMarker =
        _kHeatSourceMarkers.any(lowerTitle.contains);

    // Detect a raw protein ingredient. Each ingredient name is checked
    // against the raw-protein vocabulary AFTER stripping any cooked/cured
    // qualifier (so "cooked chicken", "tinned tuna" → safe; "chicken" → raw).
    bool ingredientIsRawProtein(String name) {
      final n = name.toLowerCase();
      if (_kCookedQualifiers.any(n.contains)) return false;
      return _kRawProteinTokens.any((tok) {
        // Word-boundary-ish match: token must be a standalone word in the
        // ingredient name, not a substring (avoids e.g. "minced garlic" →
        // "mince" false positive).
        final pattern = RegExp(r'\b' + RegExp.escape(tok) + r'\b');
        return pattern.hasMatch(n);
      });
    }

    final hasRawProtein =
        r.ingredients.any((i) => ingredientIsRawProtein(i.name));

    if (!hasRawProtein) return r;

    // ── Raw protein present ────────────────────────────────────────────────
    // Coerce the no-power flag unless the title explicitly cooks the protein.
    final safeLoadshedding = hasHeatMarker && r.isLoadsheddingFriendly;

    // Detect a "cold assembly" title still claiming to use raw meat — flag it
    // loudly so the UI never reads as "No-Power OK Chicken Salad".
    final looksLikeAssembly =
        _kAssemblyTitleMarkers.any(lowerTitle.contains) && !hasHeatMarker;

    final patchedTitle = looksLikeAssembly && !r.title.startsWith('Needs Cook')
        ? 'Needs Cook — ${r.title}'
        : r.title;

    // If nothing actually needed changing, skip the allocation.
    if (patchedTitle == r.title &&
        safeLoadshedding == r.isLoadsheddingFriendly) {
      return r;
    }

    return Recipe(
      title:                  patchedTitle,
      ingredients:            r.ingredients,
      instructions:           r.instructions,
      isLoadsheddingFriendly: safeLoadshedding,
      // isBraaiReady can only stay true if isLoadsheddingFriendly is also
      // true (the model contract); coerce in lockstep.
      isBraaiReady:           safeLoadshedding && r.isBraaiReady,
      sourceUrl:              r.sourceUrl,
    );
  }

  // ── Mock mode ────────────────────────────────────────────────────────────────
  // Returned when kGeminiApiKey is empty OR when any live API call fails.
  // Routing:
  //   isEmergencyMode AND isBudgetMode → _emergencyBudgetMocks (combined survival layout)
  //   Otherwise                        → standard three-recipe SA fallback

  static List<Recipe> _mockRecipes(
    List<String> ingredients, {
    bool isEmergencyMode = false,
    bool isBudgetMode    = false,
  }) {
    if (isEmergencyMode && isBudgetMode) {
      return _emergencyBudgetMocks(ingredients);
    }

    final preview = ingredients.take(3).join(', ');
    return [
      Recipe(
        // Stovetop pot — electric stove required, so per the "No-Power OK"
        // strict definition this is "Needs Power". Previously this mock was
        // (incorrectly) flagged loadshedding-friendly, which is what made
        // dangerous test data leak into the UI.
        title:                 'Cape Malay Curry  🍛  ($preview…)',
        isLoadsheddingFriendly: false,
        isBraaiReady:           false,   // stovetop pot
        sourceUrl:             null,
        ingredients: [
          ...ingredients.map((n) => Ingredient(name: n)),
          const Ingredient(quantity: 400.0, unit: 'ml',   name: 'coconut milk'),
          const Ingredient(quantity: 2.0,   unit: 'tbsp', name: 'Cape Malay curry powder'),
          const Ingredient(quantity: 1.0,   unit: 'tsp',  name: 'turmeric'),
          const Ingredient(                               name: 'salt to taste'),
        ],
        instructions: const [
          'Heat 2 tbsp oil in a heavy-based pot over medium heat.',
          'Sauté sliced onion until golden — about 8 minutes.',
          'Add curry powder and turmeric; fry for 1 minute until fragrant.',
          'Add your protein and brown on all sides.',
          'Stir in remaining pantry vegetables and coconut milk.',
          'Cover and simmer on low heat for 30–35 minutes.',
          'Season and serve with roti, yellow rice, or fresh bread rolls.',
        ],
      ),
      Recipe(
        title:                 'One-Pot Potjie  🔥  ($preview…)',
        isLoadsheddingFriendly: true,
        isBraaiReady:           true,    // potjie on coals
        sourceUrl:             null,
        ingredients: [
          ...ingredients.map((n) => Ingredient(name: n)),
          const Ingredient(quantity: 500.0, unit: 'ml',   name: 'beef or vegetable stock'),
          const Ingredient(quantity: 2.0,   unit: 'tbsp', name: 'tomato paste'),
          const Ingredient(                               name: 'salt, pepper and braai spice'),
        ],
        instructions: const [
          'Heat oil in the potjie or heavy pot over high heat.',
          'Brown any meat pieces on all sides then set aside.',
          'Layer vegetables from densest at the bottom to softest at the top.',
          'Dissolve tomato paste in stock and pour over — just enough to cover halfway.',
          'Nestle the meat back on top, season well, and place the lid on.',
          'Cook on medium coals (or medium-low stove) for 45–60 minutes without stirring.',
          'Serve straight from the pot with pap or fresh bread.',
        ],
      ),
      Recipe(
        title:                 'Braai-Night Pap & Relish  🌽  ($preview…)',
        isLoadsheddingFriendly: true,
        isBraaiReady:           true,    // cooked over open fire
        sourceUrl:             null,
        ingredients: [
          const Ingredient(quantity: 2.0,  unit: 'cups', name: 'mealie meal', localizedName: 'mieliemeel'),
          const Ingredient(quantity: 4.0,  unit: 'cups', name: 'water'),
          const Ingredient(quantity: 1.0,  unit: 'tsp',  name: 'salt'),
          ...ingredients.map((n) => Ingredient(name: n)),
          const Ingredient(quantity: 1.0,  unit: 'can',  name: 'chakalaka (store-bought)'),
        ],
        instructions: const [
          'Bring salted water to a rolling boil in a cast-iron pot over the fire.',
          'Slowly pour in mealie meal while stirring continuously to avoid lumps.',
          'Reduce heat, cover and cook for 20–25 minutes — stir every 5 min.',
          'Meanwhile, warm the chakalaka in a separate pan with any extra veg.',
          'Sauté any remaining pantry items in garlic and butter as a side.',
          'Spoon stiff pap into bowls and top generously with the relish.',
          'Pairs perfectly with grilled boerewors or braaied chicken.',
        ],
      ),
    ];
  }

  // ── Emergency Budget mocks ────────────────────────────────────────────────────
  // Shown when BOTH isEmergencyMode AND isBudgetMode are true and the API is
  // unavailable (no key or quota exceeded). All three recipes:
  //   • Use only a gas hob, open fire, or no heat  → isLoadsheddingFriendly: true
  //   • Cost well under R100 using township staples

  static List<Recipe> _emergencyBudgetMocks(List<String> ingredients) {
    final extras = ingredients.isNotEmpty
        ? ingredients.take(3).map((n) => Ingredient(name: n)).toList()
        : <Ingredient>[];

    return [
      // ── 1. Gas-Hob Kota ────────────────────────────────────────────────────
      Recipe(
        title:                 '⚡🇿🇦  Gas-Hob Kota  (Emergency Budget Meal)',
        isLoadsheddingFriendly: true,
        isBraaiReady:           false,   // gas hob pan
        sourceUrl:             null,
        ingredients: [
          const Ingredient(quantity: 1.0,   unit: 'loaf',  name: 'Government loaf (white bread)'),
          const Ingredient(quantity: 1.0,   unit: 'can',   name: 'Lucky Star pilchards in tomato sauce'),
          const Ingredient(quantity: 2.0,                  name: 'medium potatoes, peeled and sliced thin'),
          const Ingredient(quantity: 1.0,                  name: 'onion, sliced'),
          const Ingredient(quantity: 1.0,   unit: 'tbsp',  name: 'sunflower oil'),
          const Ingredient(quantity: 1.0,   unit: 'tsp',   name: 'Aromat seasoning'),
          ...extras,
        ],
        instructions: const [
          'Heat oil in a pan on the gas hob over medium heat.',
          'Fry the sliced onion until soft and slightly golden — about 4 minutes.',
          'Add the potato slices, season with Aromat, and fry until golden and cooked through, flipping regularly — about 10 minutes.',
          'Pour the whole can of pilchards (sauce included) over the potatoes and warm through for 2 minutes.',
          'Cut the bread loaf in half lengthways and hollow out the soft centre.',
          'Load the pilchard-potato mixture generously into the hollow bread.',
          'Serve hot, straight from the gas hob — no electricity needed. Lekker!',
        ],
      ),

      // ── 2. Quick Chakalaka Pap ─────────────────────────────────────────────
      Recipe(
        title:                 '⚡🇿🇦  Quick Chakalaka Pap  (Emergency Budget Meal)',
        isLoadsheddingFriendly: true,
        isBraaiReady:           false,   // gas hob pot
        sourceUrl:             null,
        ingredients: [
          const Ingredient(quantity: 2.0,   unit: 'cups',  name: 'White Star super maize meal'),
          const Ingredient(quantity: 4.0,   unit: 'cups',  name: 'water'),
          const Ingredient(quantity: 1.0,   unit: 'tsp',   name: 'salt'),
          const Ingredient(quantity: 1.0,   unit: 'can',   name: 'chakalaka (mild or hot)'),
          const Ingredient(quantity: 1.0,   unit: 'can',   name: 'baked beans in tomato sauce'),
          const Ingredient(quantity: 1.0,                  name: 'onion, diced'),
          const Ingredient(quantity: 1.0,   unit: 'tbsp',  name: 'sunflower oil'),
          ...extras,
        ],
        instructions: const [
          'Bring salted water to a full boil in a cast-iron pot on the gas hob.',
          'Slowly whisk in the maize meal, pouring in a steady stream to prevent lumps.',
          'Reduce heat to low, cover and cook for 20 minutes, stirring every 5 minutes with a wooden spoon until stiff.',
          'In a separate pan, fry the onion in oil for 3 minutes until soft.',
          'Add the chakalaka and baked beans to the onion and stir together. Warm through for 3–4 minutes.',
          'Serve the stiff pap in a bowl, top generously with the chakalaka-bean relish.',
          'Total cost well under R30 — feeds a family of four. Sharp-sharp!',
        ],
      ),

      // ── 3. Two-Minute Braai Bread ──────────────────────────────────────────
      Recipe(
        title:                 '⚡🇿🇦  Spicy Braai Bread & Pilchards  (Emergency Budget Meal)',
        isLoadsheddingFriendly: true,
        isBraaiReady:           true,    // can use braai grid over coals
        sourceUrl:             null,
        ingredients: [
          const Ingredient(quantity: 4.0,   unit: 'slices', name: 'thick white bread'),
          const Ingredient(quantity: 1.0,   unit: 'can',    name: 'Lucky Star pilchards in chilli sauce'),
          const Ingredient(quantity: 2.0,   unit: 'tbsp',   name: 'margarine or butter'),
          const Ingredient(quantity: 1.0,   unit: 'tsp',    name: 'Aromat seasoning'),
          const Ingredient(                                  name: 'sliced tomato and onion to serve'),
          ...extras,
        ],
        instructions: const [
          'Butter both sides of each bread slice generously.',
          'Place directly onto a gas hob grid, a dry frying pan, or a braai grid over coals.',
          'Toast for 1–2 minutes per side until golden and crispy.',
          'Open the pilchard can and drain off excess sauce, leaving a light coating.',
          'Top each toast with pilchards, a sprinkle of Aromat, and sliced tomato and onion.',
          'Serve immediately — this is a proper Mzansi emergency meal, ready in under 10 minutes.',
          'Pairs perfectly with strong rooibos tea on the gas hob. 🔥',
        ],
      ),
    ];
  }

  // ── Smart Suggestions — single-meal idea generation ─────────────────────
  //
  // Hyper-focused single-recipe generator used by the Smart Suggestions
  // home card. Takes the user's top historical shopping ingredients and
  // a target meal slot (breakfast/lunch/supper), returns ONE SA-localized
  // recipe idea.
  //
  // Reuses the same Gemini configuration as the multi-recipe pantry flow —
  // no new model, no new API key.

  /// Generates ONE SA recipe idea biased toward the [topIngredients] for
  /// the given [mealType] ('breakfast' | 'lunch' | 'supper'). Returns a
  /// fully-formed [Recipe] the caller can present in a review modal and
  /// optionally persist via SmartSuggestionsService.addToWeeklyPlanner.
  Future<Recipe> generateMealIdea({
    required String       mealType,
    required List<String> topIngredients,
  }) async {
    if (_apiKey.isEmpty) {
      // Mock for builds without a key — pulls a sensible SA default so
      // the UI is testable end-to-end.
      await Future.delayed(const Duration(seconds: 1));
      return _mockMealIdea(mealType, topIngredients);
    }

    final ingredientList = topIngredients.take(10).join(', ');
    final prompt = '''
You are a South African home chef. Generate ONE original $mealType recipe idea that PROMINENTLY uses these ingredients the user buys frequently:

$ingredientList

Rules:
- You are an AI culinary system optimized EXCLUSIVELY for the South African retail market (ChowSA). Every ingredient must be something a SA home cook actually buys at Checkers / Pick n Pay / Shoprite / Spar.
- NEVER output pre-fabricated, combination, or Americanised convenience products ("creamed spinach", "canned cheese sauce", "Alfredo sauce", "Hamburger Helper", "Velveeta", "cream of mushroom soup", "taco seasoning mix"). DECONSTRUCT them into separate base ingredients (e.g. "creamed spinach" → "spinach" + "fresh cream"; "Alfredo sauce" → "fresh cream" + "parmesan" + "butter" + "garlic").
- Lean into SA staples and cooking styles: potjie, bredie, vetkoek, sosaties, chakalaka, pap, bobotie, breakfast oats with biltong, etc.
- The recipe must use AT LEAST THREE of the user's top ingredients above. Supplement only with universal pantry items (salt, pepper, oil, water, basic spices, onions, garlic).
- Use South African ingredient names: brinjal, baby marrow, mince, mealie meal, full-cream milk.
- ${mealType == 'breakfast' ? 'Breakfast: under 25 minutes, comfort + protein focus.'
   : mealType == 'lunch'   ? 'Lunch: practical, packable or shareable.'
                            : 'Supper: hearty Mzansi dinner, family-friendly.'}
- Return ONLY a raw JSON object with no markdown, no code fences, matching exactly:
{
  "title": "Name of the dish",
  "summary": "One-sentence tagline.",
  "ingredients": [
    {"quantity": 2, "unit": "tbsp", "name": "olive oil"},
    {"quantity": 500, "unit": "g", "name": "beef mince"}
  ],
  "instructions": ["Step 1...", "Step 2...", "Step 3..."]
}
- Quantity may be omitted ("name": "salt") for to-taste items.
- 4 to 8 ingredients, 4 to 7 instructions.
''';

    final raw = await _callGemini(prompt);
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final ingredientsJson = (data['ingredients'] as List?) ?? const [];
      final instructionsJson = (data['instructions'] as List?) ?? const [];
      return Recipe(
        title:        (data['title'] as String?)?.trim().isNotEmpty == true
                          ? data['title'] as String
                          : 'AI $mealType idea',
        ingredients:  ingredientsJson
            .whereType<Map>()
            .map((m) => Ingredient.fromJson(Map<String, dynamic>.from(m)))
            .toList(),
        instructions: instructionsJson.map((s) => s.toString()).toList(),
        isLoadsheddingFriendly: false,
        isBraaiReady:           false,
        sourceUrl:              null,
      );
    } catch (_) {
      throw const PantryException(
          'AI returned an unexpected format. Try again.');
    }
  }

  Recipe _mockMealIdea(String mealType, List<String> topIngredients) {
    final preview = topIngredients.take(3).join(', ');
    return Recipe(
      title: switch (mealType) {
        'breakfast' => 'Spicy Mince Vetkoek (mock)',
        'lunch'     => 'Chakalaka Pap Bowl (mock)',
        _           => 'Beef Bredie with Onions (mock)',
      },
      ingredients: [
        for (final n in topIngredients.take(4)) Ingredient(name: n),
      ],
      instructions: [
        'Mock instruction — wire a Gemini API key to see a real plan.',
        'Uses your top ingredients: $preview.',
      ],
      isLoadsheddingFriendly: false,
    );
  }
} // end PantryService

// ── Exception ────────────────────────────────────────────────────────────────

class PantryException implements Exception {
  final String message;
  const PantryException(this.message);

  @override
  String toString() => 'PantryException: $message';
}

/// Result of [PantryService.detectIngredientsFromImage].
///
/// [recipeTitle] is populated when the scanned image is clearly a labelled
/// recipe (cookbook page, blog screenshot, hand-written card) — null
/// otherwise so the UI can fall back to its generic "ingredients found"
/// header.
class PantryScanResult {
  const PantryScanResult({
    required this.recipeTitle,
    required this.ingredients,
  });

  final String?      recipeTitle;
  final List<String> ingredients;

  bool get hasRecipeTitle =>
      recipeTitle != null && recipeTitle!.trim().isNotEmpty;
}
