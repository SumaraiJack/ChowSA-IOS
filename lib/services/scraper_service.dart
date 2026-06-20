import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:google_generative_ai/google_generative_ai.dart';
import '../models/recipe.dart';
import '../models/ingredient.dart';
import '../config/env.config.dart';

// ─────────────────────────────────────────────────────────────────────────────
// API KEY — resolved at startup.
//   • Local dev  : set kGeminiApiKey in lib/config/env.config.dart (gitignored)
//   • CI / CD    : pass --dart-define=GEMINI_API_KEY=<key> at build time
//   • No key     : service returns built-in mock SA recipes so every UI flow
//                  remains fully testable without a live key.
// ─────────────────────────────────────────────────────────────────────────────
const _dartDefineKey = String.fromEnvironment('GEMINI_API_KEY', defaultValue: '');
final String _apiKey  = kGeminiApiKey.isNotEmpty ? kGeminiApiKey : _dartDefineKey;

class ScraperService {
  // gemini-2.5-flash-lite for text tasks — 6x cheaper, same quality for
  // structured JSON extraction from recipe webpages and raw text.
  late final GenerativeModel _model = GenerativeModel(
    model: 'gemini-2.5-flash-lite',
    apiKey: _apiKey,
    systemInstruction: Content.system(systemPrompt),
    generationConfig: GenerationConfig(
      responseMimeType: 'application/json',
      temperature: 0.1,
    ),
  );

  // ── Public API ──────────────────────────────────────────────────────────────

  /// Scrapes the recipe at [url] — fetches the page, strips HTML to plain
  /// text, then sends it to Gemini for structured extraction.
  Future<Recipe> scrapeRecipeFromUrl(String url) async {
    _validateUrl(url);
    if (_apiKey.isEmpty) return _mockScrapedRecipe(url);

    final trimmedUrl = url.trim();
    final host = Uri.parse(trimmedUrl).host.toLowerCase();

    // ── Special handling for sites that block HTTP scrapers ──────────────
    // YouTube, Instagram, Facebook, TikTok don't serve recipe HTML to bots.
    // For these we send the URL directly to Gemini — it knows these platforms
    // and can extract recipes from video titles/descriptions it was trained on.
    // For unknown content it will return { "error": "No recipe found" }.
    final bool isVideoSite = host.contains('youtube.com') ||
        host.contains('youtu.be') ||
        host.contains('tiktok.com') ||
        host.contains('instagram.com') ||
        host.contains('facebook.com') ||
        host.contains('fb.com') ||
        host.contains('reels') ||
        host.contains('twitter.com') ||
        host.contains('x.com');

    String pageText;

    if (isVideoSite) {
      // For social/video sites send the URL + context to Gemini directly.
      // Gemini 2.5-flash-lite has training data from these platforms and can
      // often extract recipe content from the URL alone.
      pageText = 'Social media / video URL: $trimmedUrl\n\n'
          'Extract any recipe content associated with this URL. '
          'If this is a video, extract ingredients and steps from the '
          'title, description, or any pinned comments you know about. '
          'If no recipe can be determined, return { "error": "No recipe found at this URL." }';
    } else {
      // ── Standard sites: fetch the HTML ourselves ──────────────────────
      try {
        final uri = Uri.parse(trimmedUrl);
        final response = await http.get(uri, headers: {
          'User-Agent': 'Mozilla/5.0 (Linux; Android 10; Mobile) '
              'AppleWebKit/537.36 (KHTML, like Gecko) '
              'Chrome/120.0.0.0 Mobile Safari/537.36',
          'Accept':          'text/html,application/xhtml+xml,*/*',
          'Accept-Language': 'en-ZA,en;q=0.9',
          'Accept-Encoding': 'identity',
          'Cache-Control':   'no-cache',
        }).timeout(const Duration(seconds: 20));

        if (response.statusCode == 403 ||
            response.statusCode == 401 ||
            response.statusCode == 402) {
          // Site blocked the fetch (auth wall, paywall, or generic bot
          // block). 402 here is the SOURCE WEBSITE saying "payment required",
          // NOT our AI quota — so we fall back to handing the bare URL to
          // Gemini exactly like the 401/403 path. The genuine
          // AI-quota-exhausted case is detected from the Gemini response in
          // _callGemini, which throws ScraperQuotaException there.
          pageText = 'Recipe URL (page could not be fetched — site blocked the request): '
              '$trimmedUrl\n\nExtract the recipe if you have knowledge of this page.';
        } else if (response.statusCode != 200) {
          throw ScraperException(
            'Could not load that page (HTTP ${response.statusCode}).\n\n'
            'Try:\n• Copying and pasting the recipe text directly\n'
            '• Taking a photo of the recipe instead',
          );
        } else {
          pageText = _stripHtml(response.body);
          if (pageText.length > 14000) pageText = pageText.substring(0, 14000);
        }
      } catch (e) {
        if (e is ScraperException) rethrow;
        // Network error — try sending URL to Gemini as fallback
        pageText = 'Recipe URL (network error — could not fetch page): $trimmedUrl\n\n'
            'Extract the recipe if you have knowledge of this page.';
      }
    }

    final rawJson = await _callGemini(
      'Extract the recipe from the following source and return it in the '
      'required JSON format with all South African localization rules applied.\n\n'
      '$pageText',
    );
    return _parseRecipe(rawJson, sourceUrl: trimmedUrl);
  }

  /// Strips HTML tags and collapses whitespace to get readable plain text.
  String _stripHtml(String html) {
    // Remove script and style blocks entirely
    var text = html
        .replaceAll(RegExp(r'<script[^>]*>[\s\S]*?</script>', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'<style[^>]*>[\s\S]*?</style>',  caseSensitive: false), ' ')
        // Replace block elements with newlines
        .replaceAll(RegExp(r'<(br|p|div|li|h[1-6]|tr)[^>]*>', caseSensitive: false), '\n')
        // Strip all remaining tags
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        // Decode common HTML entities
        .replaceAll('&amp;',  '&')
        .replaceAll('&lt;',   '<')
        .replaceAll('&gt;',   '>')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&#39;',  "'")
        .replaceAll('&quot;', '"')
        // Collapse whitespace
        .replaceAll(RegExp(r'[ \t]{2,}'), ' ')
        .replaceAll(RegExp(r'\n{3,}'),    '\n\n')
        .trim();
    return text;
  }

  Future<Recipe> parseRawText(String text) async {
    if (text.trim().isEmpty) throw const ScraperException('Please paste some recipe text first.');
    if (_apiKey.isEmpty) return _mockParsedRecipe;
    final rawJson = await _callGemini(
      'Extract the recipe from this raw text and apply all South African localization rules:\n\n$text',
    );
    return _parseRecipe(rawJson, sourceUrl: null);
  }

  /// Extracts a recipe from [bytes] — a photo of a cookbook page, handwritten
  /// note, or printed recipe card taken with the device camera.
  ///
  /// Gemini performs OCR on the image then applies the same SA localization
  /// rules as the URL and text scrapers.
  ///
  /// Platform setup required before this will work:
  ///   iOS  — add NSCameraUsageDescription to ios/Runner/Info.plist
  ///   Android — add <uses-permission android:name="android.permission.CAMERA"/>
  ///             to android/app/src/main/AndroidManifest.xml
  Future<Recipe> scrapeRecipeFromImage(
    Uint8List bytes, {
    String mimeType = 'image/jpeg',
  }) async {
    if (bytes.isEmpty) throw const ScraperException('No image data received.');
    if (_apiKey.isEmpty) return _mockScrapedRecipe(null);
    // Surface errors so the user sees what went wrong
    final rawJson = await _callGeminiWithImage(bytes, mimeType: mimeType);
    return _parseRecipe(rawJson, sourceUrl: null);
  }

  // ── System prompt ───────────────────────────────────────────────────────────

  static const String systemPrompt = '''
You are ChowSA, an expert South African recipe assistant.

Your job is to read a recipe from a social media post, video, raw text, or recipe
photo and return it as a clean, structured JSON object. Follow every rule below precisely.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
RULE 1 — OUTPUT FORMAT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Return ONLY a single raw JSON object. No markdown, no code fences, no explanation.
The schema must be exactly:

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

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
RULE 2 — INGREDIENTS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
- Split every ingredient into quantity, unit, and name.
  Example: "2 cups flour" → quantity: 2, unit: "cups", name: "flour"
- If no quantity exists (e.g. "salt to taste"), set quantity and unit to null.
- Use decimal numbers for fractions: ½ → 0.5, ¼ → 0.25.
- "name" must always be the ORIGINAL term used in the source content.
- "localizedName" must be the standard South African equivalent if it differs.
  Leave localizedName as null if the term is already commonly used in South Africa.

South African localization reference (not exhaustive — use your knowledge):
  Cilantro           → Coriander
  Eggplant           → Brinjal
  Zucchini           → Baby marrow
  Ground beef        → Mince
  Heavy cream        → Cream / Whipping cream
  Half-and-half      → Full-cream milk or light cream
  Arugula            → Rocket
  Biscuits (US)      → Scones
  Chips (UK/AU)      → Slap chips
  Candy              → Sweets
  Jello              → Jelly
  Ladyfinger cookies → Boudoir biscuits
  Cornstarch         → Maizena
  All-purpose flour  → Cake flour (note: SA cake flour is slightly different)
  Whole milk         → Full-cream milk

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
MZANSI GROCERY LEXICON — BRAND RESOLUTION
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
You are an expert on South African grocery products. When parsing recipe text
that mentions local brand names, resolve them to their generic ingredient and
keep both the brand and the generic in the output (brand in "name", generic in
"localizedName" if it differs). Use this lookup:

  Pantry Staples (Maize Meal):
    White Star, Iwisa, Ace, Nyala, Impala, Tafelberg → maize meal / mealie meal
    "Pap" → cooked maize meal porridge
  Pantry Staples (Rice & Grains):
    Tastic, Spekko → long-grain rice; samp + umngqusho → dried hominy.
  Pantry Staples (Baking):
    Snowflake, Sasko → flour; Maizena → corn starch.
  Pantry Staples (Stock):
    Royco, Knorrox, Knorr, Imana → stock cubes / soup mix.
  Meat & Fish (Tinned Fish):
    Lucky Star, Saldanha, Glenryck → pilchards / tinned fish.
  Condiments & Sauces:
    All Gold → tomato sauce. Mrs. Ball's / Ball's Chutney → chutney.
    Crosse & Blackwell → mayonnaise. Nando's → peri-peri sauce.
    Black Cat / Yum Yum → peanut butter.
  Spices & Herbs:
    Aromat → universal seasoning. Rajah, Robertsons → curry powders / spices.
    Ina Paarman, Cape Herb & Spice → spice blends.
  Beverages:
    Rooibos, Freshpak, Joko, Five Roses → tea.
    Oros, Halls → cordial / squash.
    Ricoffy, Frisco, Caro → instant coffee / coffee substitute.
    Milo, Horlicks → malted drinks.
    Liqui-Fruit, Ceres → fruit juice.

When the source recipe says "2 tbsp Aromat" or "1 can Lucky Star pilchards in
tomato sauce", keep the brand intact in "name" and only set "localizedName" if
the term is the foreign equivalent that needs translating. Brand names ARE the
South African localised term — they should pass through unchanged.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
RULE 3 — INSTRUCTIONS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
- Each step must be a single, actionable sentence or short paragraph.
- Number the steps implicitly via the array order — do NOT include "Step 1:", "1.", etc.
- Write in plain, friendly South African English.
- If the source is a video with no text, infer the steps from what is visually shown.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
RULE 4 — LOADSHEDDING FLAG (STRICT)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
"isLoadsheddingFriendly" is a STRICT flag. Apply these rules WITHOUT EXCEPTION:

Set to TRUE only in ONE of these two cases:
  CASE 1 — RAW/COLD ONLY: Every single step is cold preparation. Zero heat of any
           kind is required (e.g., fruit salad, cold slaw, amasi bowl, no-cook dip).
  CASE 2 — EXPLICITLY ADAPTED: The recipe TITLE explicitly names an alternative heat
           source such as "Braai-Grid …", "Gas-Hob …", "Potjie …", or "Open-Fire …".
           The alternative source MUST appear in the recipe title itself.

Set to FALSE in ALL other cases:
  ✗ Gas stove / hob cooking — unless the title explicitly says "Gas-Hob" (Case 2).
  ✗ ANY thermal cooking (frying, boiling, simmering, baking, steaming, toasting)
    that does not meet Case 2.
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
RULE 5 — BRAAI READY FLAG
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Set "isBraaiReady" to true ONLY if the cooking method explicitly uses one of:
  ✓ Outdoor braai / kettle braai
  ✓ Potjie pot on coals
  ✓ Open fire or open coals

Set it to false for all other methods, including:
  ✗ Gas hob / gas stove
  ✗ Electric or gas oven
  ✗ Stovetop (pan, wok, skillet)
  ✗ No-cook / raw recipes
  ✗ Microwave

When isBraaiReady is true, isLoadsheddingFriendly must also be true (it qualifies
as Case 2 — the braai method is an explicit alternative heat source).

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
RULE 6 — EDGE CASES
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
- If the URL does not contain a recipe, return:
  { "error": "No recipe found at this URL." }
- If the content is in another language, translate everything to English first,
  then apply the localization rules above.
- Do not invent ingredients or steps. Only use what is present in the source.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
RULE 7 — IMAGE / OCR INPUT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
You may receive an image file instead of a URL or text. When this happens:
- Perform OCR to extract every word visible in the image.
- Handle handwritten notes, printed cookbook pages, and recipe cards equally.
- If part of the image is blurry or cut off, extract what is legible and set
  any unreadable quantities to null rather than guessing.
- Apply all localization and formatting rules to the extracted content exactly
  as you would for any other input source.
''';

  // ── Gemini call ─────────────────────────────────────────────────────────────

  Future<String> _callGemini(String userPrompt) async {
    if (_apiKey.isEmpty) {
      throw const ScraperException(
        'Gemini API key not configured.\n\n'
        'Build with:\n  flutter run --dart-define=GEMINI_API_KEY=YOUR_KEY\n\n'
        'Get a free key at https://aistudio.google.com/app/apikey',
      );
    }

    late final GenerateContentResponse response;

    try {
      response = await _model.generateContent([Content.text(userPrompt)]);
    } on GenerativeAIException catch (e) {
      // Genuine AI-quota / rate-limit exhaustion → surface the dedicated
      // "Aunty Chow is on a tea break" dialog. Everything else stays a
      // plain ScraperException and shows the standard snackbar.
      if (_isQuotaError(e.message)) {
        throw ScraperQuotaException(
          'The automated web link reader is temporarily full.',
        );
      }
      throw ScraperException('Gemini API error: ${e.message}');
    } catch (e) {
      throw ScraperException('Could not reach the AI. Check your connection and API key.\n\n$e');
    }

    final text = response.text;
    if (text == null || text.trim().isEmpty) {
      throw const ScraperException('Gemini returned an empty response.');
    }

    // responseMimeType: 'application/json' should prevent fences, but strip
    // them defensively in case an older model version ignores the config.
    return _stripJsonFences(text);
  }

  Future<String> _callGeminiWithImage(Uint8List bytes, {required String mimeType}) async {
    late final GenerateContentResponse response;

    try {
      response = await _model.generateContent([
        Content.multi([
          DataPart(mimeType, bytes),
          TextPart(
            'This is a photo of a recipe — it may be a cookbook page, handwritten note, '
            'or a printed recipe card. Perform OCR to extract all visible text, then '
            'format it into the required JSON schema. Apply all South African '
            'localization rules as instructed.',
          ),
        ]),
      ]);
    } on GenerativeAIException catch (e) {
      if (_isQuotaError(e.message)) {
        throw ScraperQuotaException(
          'The automated web link reader is temporarily full.',
        );
      }
      throw ScraperException('Gemini API error: ${e.message}');
    } catch (e) {
      throw ScraperException('Could not process the image. Please try again.\n\n$e');
    }

    final text = response.text;
    if (text == null || text.trim().isEmpty) {
      throw const ScraperException(
        'Gemini could not read a recipe from this photo. '
        'Try again with better lighting or a clearer angle.',
      );
    }
    return _stripJsonFences(text);
  }

  /// Heuristic match for Gemini's quota / rate-limit error strings. Matches
  /// `RESOURCE_EXHAUSTED`, 429 status mentions, and human-readable variants
  /// ("quota", "rate limit", "exceeded") so we can route them to the dedicated
  /// "tea break" dialog instead of the generic error snackbar.
  bool _isQuotaError(String? msg) {
    if (msg == null) return false;
    final lower = msg.toLowerCase();
    return lower.contains('resource_exhausted') ||
        lower.contains('quota') ||
        lower.contains('rate limit') ||
        lower.contains('rate-limit') ||
        lower.contains('exceeded') ||
        lower.contains(' 429');
  }

  // Removes ```json ... ``` or ``` ... ``` wrappers if the model adds them.
  String _stripJsonFences(String raw) {
    final trimmed = raw.trim();
    final fencePattern = RegExp(r'^```(?:json)?\s*([\s\S]*?)\s*```$');
    final match = fencePattern.firstMatch(trimmed);
    return match != null ? match.group(1)! : trimmed;
  }

  // ── Parsing ─────────────────────────────────────────────────────────────────

  Recipe _parseRecipe(String rawJson, {required String? sourceUrl}) {
    late final Map<String, dynamic> data;

    try {
      data = jsonDecode(rawJson) as Map<String, dynamic>;
    } catch (_) {
      throw ScraperException(
        'The AI returned an unexpected response. Please try again.\n\nRaw: '
        '${rawJson.length > 200 ? rawJson.substring(0, 200) : rawJson}',
      );
    }

    if (data.containsKey('error')) {
      throw ScraperException(data['error'] as String);
    }

    try {
      final recipe = Recipe.fromJson({...data, 'sourceUrl': sourceUrl});

      // Guard: if Gemini returned a recipe with no ingredients AND no
      // instructions, treat it as a failure so we show an error instead
      // of a blank recipe card.
      if (recipe.ingredients.isEmpty && recipe.instructions.isEmpty) {
        throw const ScraperException(
          'No recipe content was found at that link.\n\n'
          'Tips:\n'
          '• Make sure the link points directly to a recipe page\n'
          '• Try copying the recipe text and pasting it instead\n'
          '• For videos, try taking a photo of the recipe on screen',
        );
      }
      return recipe;
    } catch (e) {
      if (e is ScraperException) rethrow;
      throw ScraperException(
        'Could not read the recipe data. Please try again.\n\nDetails: $e',
      );
    }
  }

  // ── Mock mode ────────────────────────────────────────────────────────────────
  // Returned when kGeminiApiKey is empty OR when any live API call fails.
  // Provides fully-interactive SA recipe data so every UI flow can be tested
  // without a live Gemini key.

  static Recipe _mockScrapedRecipe(String? url) => Recipe(
    title:                 'Peri-Peri Chicken Braai  🔥  (Demo)',
    isLoadsheddingFriendly: true,
    isBraaiReady:           true,   // explicit braai / open-fire method
    sourceUrl:             url,
    ingredients: [
      const Ingredient(quantity: 1.0,   unit: 'kg',   name: 'chicken pieces'),
      const Ingredient(quantity: 4.0,   unit: 'tbsp', name: 'peri-peri sauce'),
      const Ingredient(quantity: 3.0,                 name: 'garlic cloves'),
      const Ingredient(quantity: 1.0,   unit: 'tsp',  name: 'smoked paprika'),
      const Ingredient(quantity: 2.0,   unit: 'tbsp', name: 'olive oil'),
      const Ingredient(quantity: 1.0,   unit: 'tsp',  name: 'dried oregano'),
      const Ingredient(                               name: 'salt and pepper to taste'),
      const Ingredient(quantity: 1.0,                 name: 'lemon, halved'),
    ],
    instructions: const [
      'Mix peri-peri sauce, crushed garlic, paprika, olive oil, oregano, salt and pepper in a bowl.',
      'Score the chicken pieces deeply and rub the marinade in well.',
      'Cover and refrigerate for at least 2 hours — overnight is best.',
      'Heat the braai or a cast-iron pan over medium-high heat.',
      'Cook chicken for 12–15 min per side until cooked through with a good char.',
      'Baste generously with extra peri-peri sauce in the last 5 minutes.',
      'Rest for 5 minutes, squeeze fresh lemon over, and serve with slap chips.',
    ],
  );

  static const Recipe _mockParsedRecipe = Recipe(
    title:                 'Cape Malay Chicken Curry  🍛  (Demo)',
    isLoadsheddingFriendly: true,
    isBraaiReady:           false,  // stovetop pot — not a braai
    sourceUrl:             null,
    ingredients: [
      Ingredient(quantity: 1.0,   unit: 'kg',  name: 'chicken thighs'),
      Ingredient(quantity: 2.0,                name: 'onions, sliced'),
      Ingredient(quantity: 3.0,                name: 'garlic cloves, minced'),
      Ingredient(quantity: 1.5,  unit: 'tbsp', name: 'Cape Malay curry powder'),
      Ingredient(quantity: 1.0,  unit: 'tsp',  name: 'turmeric'),
      Ingredient(quantity: 400.0, unit: 'ml',  name: 'coconut milk'),
      Ingredient(quantity: 2.0,                name: 'tomatoes, diced'),
      Ingredient(quantity: 2.0,  unit: 'tbsp', name: 'sunflower oil'),
      Ingredient(                              name: 'salt to taste'),
    ],
    instructions: [
      'Heat oil in a heavy-based pot over medium heat.',
      'Sauté onions until golden — about 8 minutes.',
      'Add garlic, curry powder and turmeric; fry for 1 minute until fragrant.',
      'Add chicken pieces and brown on all sides.',
      'Stir in diced tomatoes and coconut milk.',
      'Cover and simmer on low heat for 35 minutes.',
      'Season with salt and serve with roti, yellow rice, or fresh bread rolls.',
    ],
  );

  // ── URL validation ──────────────────────────────────────────────────────────

  void _validateUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || uri.host.isEmpty) {
      throw ScraperException('Invalid URL: "$url"');
    }
    // Allow any http/https URL — Gemini will attempt to extract a recipe from
    // any web page, social post, or recipe site. No whitelist needed.
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw const ScraperException(
        'Please paste a full web link starting with http:// or https://',
      );
    }
  }
}

// ── Exceptions ──────────────────────────────────────────────────────────────

class ScraperException implements Exception {
  final String message;
  const ScraperException(this.message);

  @override
  String toString() => 'ScraperException: $message';
}

/// Thrown when the scraping proxy / parser API returns HTTP 402 Payment
/// Required — i.e. the free-tier quota has been exhausted.
///
/// Subclasses [ScraperException] so existing `if (e is ScraperException)`
/// guards still rethrow it, but UI layers can branch on this specific type
/// FIRST (`if (e is ScraperQuotaException)`) to surface the dedicated
/// "reader is full" dialog with manual-paste + photo-scan CTAs.
class ScraperQuotaException extends ScraperException {
  const ScraperQuotaException(super.message);

  @override
  String toString() => 'ScraperQuotaException: $message';
}
