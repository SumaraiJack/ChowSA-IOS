// lib/models/shopping_list.dart

import '../utils/mzansi_lexicon.dart';
import '../utils/south_african_product_matcher.dart';

// =============================================================================
// Grocery category — used for aisle grouping in ShoppingListScreen
// =============================================================================

enum GroceryCategory {
  fruitsAndVeggies,
  butcher,
  dairy,
  pantry,
  frozen,
  bakery,
  spicesAndHerbs,
  condimentsAndSauces,
  beverages,
  other;

  String get displayName => switch (this) {
        GroceryCategory.fruitsAndVeggies    => 'Fruit & Veggies',
        GroceryCategory.butcher             => 'Meat & Fish',
        GroceryCategory.dairy               => 'Dairy & Chilled',
        GroceryCategory.pantry              => 'Pantry Staples',
        GroceryCategory.frozen              => 'Frozen',
        GroceryCategory.bakery              => 'Bakery',
        GroceryCategory.spicesAndHerbs      => 'Spices & Herbs',
        GroceryCategory.condimentsAndSauces => 'Condiments & Sauces',
        GroceryCategory.beverages           => 'Beverages',
        GroceryCategory.other               => 'Other',
      };

  String get emoji => switch (this) {
        GroceryCategory.fruitsAndVeggies    => '🍎🥦',
        GroceryCategory.butcher             => '🥩',
        GroceryCategory.dairy               => '🥛',
        GroceryCategory.pantry              => '🫙',
        GroceryCategory.frozen              => '🧊',
        GroceryCategory.bakery              => '🍞',
        GroceryCategory.spicesAndHerbs      => '🌿',
        GroceryCategory.condimentsAndSauces => '🥫',
        GroceryCategory.beverages           => '🫖',
        GroceryCategory.other               => '🛒',
      };
}

// ─────────────────────────────────────────────────────────────────────────────
// Categoriser — checks SPECIFIC phrases BEFORE generic substrings so that
// "garlic flakes" and "avocado oil" don't get pulled into Fruit & Veggies by
// the bare "garlic"/"avocado" tokens. Match order is hierarchical:
//
//   1. Spices & Herbs        (phrase priority — wins over produce/pantry)
//   2. Condiments & Sauces   (phrase priority — wins over dairy "butter")
//   3. Frozen
//   4. Butcher
//   5. Bakery
//   6. Pantry Staples        (catches oils, tea, coffee, grains, baking)
//   7. Dairy                 (after condiments so "peanut butter" → condiments)
//   8. Produce               (catches plain "garlic", "avocado" with no qualifier)
//   9. Smart fallback        (tea/coffee/sauce/spread/powder/mix)
//   10. Other
// ─────────────────────────────────────────────────────────────────────────────

/// Keyword-based categoriser — maps an ingredient name to a grocery aisle.
GroceryCategory categoriseIngredient(String name) {
  // ── 0. MzansiLexicon — 250+ SA brands & culinary terms ───────────────────
  // The comprehensive lexicon is checked FIRST so "Mrs Ball's Chutney", "Iwisa",
  // "Oros", "All Gold", "Koo", "Lucky Star", "Ouma Rusks", "Rooibos", "Aromat"
  // and hundreds of other local terms route by brand recognition before any
  // generic keyword can claim them.
  final mzMatch = MzansiLexicon.tryLookupCategory(name);
  if (mzMatch != null) return mzMatch;

  // ── 0b. Legacy SA matcher — kept as fallback for entries not yet ported ───
  final saMatch = SouthAfricanProductMatcher.determineCategory(name);
  if (saMatch != null) return saMatch;

  final n = name.toLowerCase();

  // ── 1. Spices & Herbs ────────────────────────────────────────────────────
  // Specific spice/herb phrases first. Plain "garlic" / "onion" / "ginger" are
  // intentionally NOT here — those stay produce. Anything with a "powder /
  // flakes / granules / dried / ground" qualifier IS a spice.
  const spices = [
    // Specific qualifiers (must come before bare produce names)
    'garlic flakes', 'garlic powder', 'garlic salt', 'garlic granules', 'garlic paste',
    'onion powder', 'onion flakes', 'onion granules', 'onion salt',
    'ginger powder', 'ground ginger',
    // Salt + pepper variants (plain "pepper" stays produce for bell peppers)
    'salt', 'sea salt', 'rock salt', 'table salt', 'himalayan salt', 'kosher salt',
    'black pepper', 'white pepper', 'ground pepper', 'cracked pepper',
    'peppercorn', 'pink peppercorn', 'cayenne pepper', 'cayenne',
    // Classic spices
    'paprika', 'smoked paprika', 'cumin', 'turmeric', 'cinnamon',
    'nutmeg', 'cardamom', 'cloves', 'allspice', 'star anise', 'fennel seed',
    'coriander seed', 'coriander powder', 'mustard seed', 'caraway',
    'saffron', 'sumac', 'fenugreek', 'mace',
    // Dried herbs
    'oregano', 'thyme', 'rosemary', 'sage', 'basil', 'mint dried', 'dried mint',
    'dill', 'tarragon', 'marjoram', 'bay leaf', 'bay leaves', 'bay',
    'parsley flakes', 'chives dried',
    // SA / blends
    'aromat', 'braai spice', 'braai salt', 'chicken spice', 'beef spice',
    'lamb spice', 'fish spice', 'all-in-one', 'chip spice', 'steak rub',
    'cape malay', 'masala', 'garam masala', 'curry powder', 'mixed spice',
    'mixed herbs', 'italian seasoning', 'taco seasoning', 'fajita seasoning',
    'peri-peri seasoning', 'peri peri seasoning', 'chilli flakes', 'chilli powder',
    'crushed chilli', 'red pepper flakes',
  ];

  // ── 2. Condiments & Sauces ───────────────────────────────────────────────
  // Spreads, jams, sauces, dressings, anything in a squeeze bottle or jar.
  // "Peanut butter" lives here so the dairy check below doesn't grab it via
  // its "butter" substring.
  const condiments = [
    // Sauces
    'mayonnaise', 'mayo', 'mustard', 'dijon', 'ketchup', 'tomato sauce',
    'bbq sauce', 'barbecue sauce', 'hot sauce', 'chilli sauce',
    'sweet chilli', 'sweet chilli sauce', 'peri-peri sauce', 'peri peri sauce',
    'sriracha', 'tabasco', 'salsa', 'soy sauce', 'fish sauce',
    'oyster sauce', 'hoisin', 'teriyaki', 'worcestershire',
    'pesto', 'tapenade', 'tahini',
    // SA classics
    'chutney', "mrs ball", "mrs ball's chutney", 'all gold sauce',
    // Spreads / butters
    'peanut butter', 'almond butter', 'cashew butter',
    'nutella', 'chocolate spread', 'hazelnut spread',
    'marmite', 'bovril', 'vegemite', 'liver spread',
    // Sweet spreads
    'jam', 'marmalade', 'preserve', 'honey', 'syrup',
    'golden syrup', 'maple syrup', 'treacle', 'agave',
    'condensed milk',     // shelf-stable — moved out of dairy
    // Pickles / relishes
    'relish', 'pickle', 'pickles', 'gherkin', 'sauerkraut',
    'olives', 'olive tapenade', 'capers',
    // Dressings
    'dressing', 'salad dressing', 'vinaigrette', 'ranch', 'caesar dressing',
    'french dressing', 'italian dressing', 'thousand island',
    // Generic '... sauce'
    'pasta sauce', 'curry sauce', 'gravy sauce', 'cheese sauce',
  ];

  // ── 3. Frozen ────────────────────────────────────────────────────────────
  const frozen = [
    'frozen', 'ice cream', 'sorbet', 'gelato', 'ice lolly', 'ice pop',
    'frozen peas', 'frozen veg', 'frozen berries',
  ];

  // ── 4. Butcher / proteins ────────────────────────────────────────────────
  const butcher = [
    'chicken', 'beef', 'lamb', 'mince', 'pork', 'boerewors', 'steak',
    'fish', 'prawn', 'shrimp', 'bacon', 'ham', 'sausage', 'biltong',
    'droëwors', 'chop', 'fillet', 'thigh', 'breast', 'rib', 'mutton',
    'wors', 'venison', 'springbok', 'ostrich', 'tuna', 'salmon', 'hake',
    'meat', 'poultry', 'turkey', 'duck', 'liver', 'kidney', 'tripe',
    'oxtail', 'spare rib', 'wing', 'rump', 'sirloin', 'brisket',
    'chuck', 'meatball', 'burger patty', 'frankfurter', 'chorizo',
  ];

  // ── 5. Bakery ────────────────────────────────────────────────────────────
  const bakery = [
    'bread', 'roll', 'pita', 'roti', 'wrap', 'bun', 'cake', 'biscuit',
    'scone', 'crumpet', 'vetkoek', 'koeksister', 'panini', 'baguette',
    'ciabatta', 'sourdough', 'rusks', 'milk tart',
  ];

  // ── 6. Pantry Staples ────────────────────────────────────────────────────
  // Now actively claims oils, vinegars, tea, coffee, grains, baking aids,
  // canned goods, and dry mixes — the original SA pantry essentials.
  const pantry = [
    // Oils — must come BEFORE produce check so "avocado oil" wins over "avocado"
    'avocado oil', 'olive oil', 'sunflower oil', 'canola oil',
    'coconut oil', 'sesame oil', 'vegetable oil', 'peanut oil',
    'oil',          // generic catch-all after the specific oils above
    'ghee',
    // Vinegars
    'vinegar', 'balsamic', 'apple cider', 'cider vinegar',
    'rice vinegar', 'red wine vinegar', 'white wine vinegar',
    // (Beverages — tea, coffee, Rooibos, Oros — moved to dedicated category)
    // Grains / staples
    'rice', 'basmati', 'jasmine rice', 'brown rice', 'wild rice',
    'quinoa', 'couscous', 'bulgur', 'oats', 'oatmeal', 'porridge',
    'mealie meal', 'mealiemeal', 'maize meal', 'samp', 'semolina',
    'maizena', 'cornflour', 'breadcrumbs', 'panko',
    // Pasta / noodles
    'pasta', 'spaghetti', 'macaroni', 'penne', 'fusilli', 'rigatoni',
    'lasagne', 'noodle', 'noodles', 'ramen', 'rice noodle', 'egg noodle',
    // Baking
    'flour', 'cake flour', 'bread flour', 'self-raising', 'wholewheat flour',
    'sugar', 'brown sugar', 'icing sugar', 'caster sugar', 'castor sugar',
    'baking powder', 'baking soda', 'bicarbonate', 'yeast', 'vanilla',
    'vanilla essence', 'custard powder', 'jelly', 'gelatine', 'gelatin',
    'cocoa powder', 'chocolate chips', 'desiccated coconut', 'coconut',
    // Canned / tinned
    'tinned', 'tin of', 'canned', 'baked beans', 'kidney bean', 'butter bean',
    'chickpea', 'lentil', 'split pea', 'bean', 'tomato paste', 'tomato puree',
    'coconut milk', 'coconut cream', 'tomato passata',
    // Stock / soup
    'stock', 'stock cube', 'broth', 'knorrox', 'gravy', 'soup mix',
    'cup-a-soup', 'powdered soup',
  ];

  // ── 7. Dairy ─────────────────────────────────────────────────────────────
  // Checked AFTER condiments so "peanut butter" doesn't get pulled in by
  // "butter". Condensed milk also moved to condiments (shelf-stable).
  const dairy = [
    'milk', 'full-cream milk', 'low-fat milk', 'skim milk',
    'cream', 'whipping cream', 'fresh cream', 'sour cream', 'crème fraîche',
    'cheese', 'cheddar', 'feta', 'mozzarella', 'parmesan', 'gouda',
    'cottage cheese', 'cream cheese', 'mascarpone',
    'butter', 'margarine',
    'yogurt', 'yoghurt', 'greek yoghurt', 'amasi', 'maas',
    'egg', 'eggs', 'free-range eggs',
    'custard',           // ready-made; powder is in pantry
    'buttermilk',
  ];

  // ── 8. Produce — checked LAST among the keyword lists ────────────────────
  // Plain produce names only. "Garlic flakes" / "avocado oil" / "onion powder"
  // are already routed to spices/pantry above, so they never reach here.
  const produce = [
    'carrot', 'onion', 'tomato', 'potato', 'garlic', 'spinach', 'lettuce',
    'mushroom', 'pepper', 'bell pepper', 'baby marrow', 'brinjal',
    'cucumber', 'avocado', 'lemon', 'lime', 'apple', 'banana', 'orange',
    'chilli', 'coriander', 'parsley', 'spring onion', 'leek', 'celery',
    'zucchini', 'rocket', 'gem squash', 'butternut', 'pumpkin', 'cabbage',
    'broccoli', 'cauliflower', 'peas', 'corn', 'mango', 'pawpaw', 'papaya',
    'pineapple', 'ginger', 'strawberry', 'blueberry', 'raspberry',
    'grapes', 'pear', 'peach', 'plum', 'kiwi', 'watermelon', 'sweet potato',
    'kale', 'beetroot', 'turnip', 'radish', 'asparagus',
  ];

  // ── Beverages ────────────────────────────────────────────────────────────
  // Tea, coffee, cordials, juices — anything you sip rather than cook with.
  // SA staples: Rooibos, Oros, Milo, Five Roses, Joko.
  const beverages = [
    'rooibos', 'rooibos tea',
    'tea', 'black tea', 'green tea', 'herbal tea', 'chamomile',
    'earl grey', 'english breakfast', 'jasmine tea', 'iced tea',
    'coffee', 'instant coffee', 'ground coffee', 'coffee beans', 'espresso',
    'cappuccino', 'mocha mix', 'latte mix',
    'hot chocolate', 'cocoa drink', 'milo', 'horlicks', 'ovaltine',
    'oros', 'squash', 'cordial', 'concentrate',
    'fruit juice', 'orange juice', 'apple juice', 'mango juice',
    'fizzy drink', 'soda', 'sparkling water', 'still water', 'mineral water',
    'beer', 'wine', 'cider',
  ];

  // ── Ordered match ────────────────────────────────────────────────────────
  if (spices.any((k) => n.contains(k)))     return GroceryCategory.spicesAndHerbs;
  if (condiments.any((k) => n.contains(k))) return GroceryCategory.condimentsAndSauces;
  if (beverages.any((k) => n.contains(k))) return GroceryCategory.beverages;
  if (frozen.any((k) => n.contains(k)))     return GroceryCategory.frozen;
  if (butcher.any((k) => n.contains(k)))    return GroceryCategory.butcher;
  if (bakery.any((k) => n.contains(k)))     return GroceryCategory.bakery;
  if (pantry.any((k) => n.contains(k)))     return GroceryCategory.pantry;
  if (dairy.any((k) => n.contains(k)))      return GroceryCategory.dairy;
  if (produce.any((k) => n.contains(k)))    return GroceryCategory.fruitsAndVeggies;

  // ── 9. Smart fallback ───────────────────────────────────────────────────
  // Catches structural keywords for items not in any explicit list.
  if (n.contains('tea'))     return GroceryCategory.beverages;
  if (n.contains('coffee'))  return GroceryCategory.beverages;
  if (n.contains('juice'))   return GroceryCategory.beverages;
  if (n.contains('sauce'))   return GroceryCategory.condimentsAndSauces;
  if (n.contains('spread'))  return GroceryCategory.condimentsAndSauces;
  if (n.contains('powder'))  return GroceryCategory.spicesAndHerbs;
  if (n.contains(' mix'))    return GroceryCategory.pantry;
  if (n.endsWith(' mix'))    return GroceryCategory.pantry;
  if (n.contains('seasoning')) return GroceryCategory.spicesAndHerbs;

  // ── 10. Final fallback ──────────────────────────────────────────────────
  return GroceryCategory.other;
}

// =============================================================================
// ShoppingItem
// =============================================================================

class ShoppingItem {
  ShoppingItem({
    required this.id,
    required this.name,
    this.quantity,
    this.unit,
    this.checked  = false,
    GroceryCategory? category,
  }) : category = category ?? categoriseIngredient(name);

  final String    id;
  String          name;
  String?         quantity;
  String?         unit;
  bool            checked;
  GroceryCategory category;

  String get displayQuantity {
    final parts = <String>[];
    if (quantity != null && quantity!.isNotEmpty) parts.add(quantity!);
    if (unit     != null && unit!.isNotEmpty)     parts.add(unit!);
    return parts.join(' '); // narrow no-break space
  }

  ShoppingItem copyWith({
    String?         name,
    String?         quantity,
    String?         unit,
    bool?           checked,
    GroceryCategory? category,
  }) =>
      ShoppingItem(
        id:       id,
        name:     name     ?? this.name,
        quantity: quantity ?? this.quantity,
        unit:     unit     ?? this.unit,
        checked:  checked  ?? this.checked,
        category: category ?? this.category,
      );

  Map<String, dynamic> toJson() => {
        'id':       id,
        'name':     name,
        'quantity': quantity,
        'unit':     unit,
        'checked':  checked,
        'category': category.name,
      };

  factory ShoppingItem.fromJson(Map<String, dynamic> j) => ShoppingItem(
        id:       j['id']   as String,
        name:     j['name'] as String,
        quantity: j['quantity'] as String?,
        unit:     j['unit']     as String?,
        checked:  j['checked']  as bool? ?? false,
        category: GroceryCategory.values.firstWhere(
          (c) => c.name == j['category'] || 
                 // backwards-compat: old saved data used 'produce'
                 (j['category'] == 'produce' && c == GroceryCategory.fruitsAndVeggies),
          orElse: () => GroceryCategory.other,
        ),
      );
}

// =============================================================================
// ShoppingList
// =============================================================================

class ShoppingList {
  ShoppingList({
    required this.id,
    required this.name,
    List<ShoppingItem>? items,
    DateTime? createdAt,
  })  : items     = items ?? [],
        createdAt = createdAt ?? DateTime.now();

  final String             id;
  String                   name;
  final List<ShoppingItem> items;
  final DateTime           createdAt;

  int  get totalCount   => items.length;
  int  get checkedCount => items.where((i) => i.checked).length;
  bool get isEmpty      => items.isEmpty;

  Map<String, dynamic> toJson() => {
        'id':        id,
        'name':      name,
        'items':     items.map((i) => i.toJson()).toList(),
        'createdAt': createdAt.toIso8601String(),
      };

  factory ShoppingList.fromJson(Map<String, dynamic> j) => ShoppingList(
        id:        j['id']   as String,
        name:      j['name'] as String,
        items:     (j['items'] as List<dynamic>)
            .map((e) => ShoppingItem.fromJson(e as Map<String, dynamic>))
            .toList(),
        createdAt: DateTime.parse(j['createdAt'] as String),
      );
}
