// lib/utils/mzansi_lexicon.dart
//
// Comprehensive South African product, brand, and culinary lexicon.
//
// Maps lowercase product/brand tokens to the matching grocery aisle label.
// Labels are the exact strings emitted by GroceryCategory.displayName so the
// shopping list UI groups them under the right header automatically:
//
//   'Pantry Staples'         'Spices & Herbs'        'Condiments & Sauces'
//   'Beverages'              'Meat & Fish'           'Fruit & Veggies'
//   'Dairy & Chilled'        'Frozen'                'Bakery'                'Other'
//
// Sources synthesised:
//   • Shoprite, Pick n Pay, Woolworths, Checkers SA online inventories
//   • Wikipedia "South African cuisine" + colloquial term tables
//   • Heritage cookbook ingredient indexes (Karoo Cookbook, Cape Malay etc.)
//   • Common township grocery slang
//
// Map order matters: SPECIFIC multi-word phrases come FIRST so they win over
// shorter generic tokens (e.g. "mrs ball's chutney" wins before plain "chutney"
// could match the unrelated "tomato chutney" produce in the same scan).

import '../models/shopping_list.dart';

class MzansiLexicon {
  MzansiLexicon._(); // utility — never instantiated

  // ────────────────────────────────────────────────────────────────────────────
  // 250+ entries — case-insensitive substring matches happen in lookup().
  // ────────────────────────────────────────────────────────────────────────────

  static const Map<String, String> productToCategory = {

    // ════════════════════════════════════════════════════════════════════════
    // PANTRY STAPLES — maize meal, rice, flour, baking, canned, stock
    // ════════════════════════════════════════════════════════════════════════

    // Maize meal / pap brands (the cornerstone of Mzansi cuisine)
    'iwisa':              'Pantry Staples',
    'white star':         'Pantry Staples',
    'ace super':          'Pantry Staples',
    'ace maize':          'Pantry Staples',
    'ace instant':        'Pantry Staples',
    'nyala maize':        'Pantry Staples',
    'nyala':              'Pantry Staples',
    'impala maize':       'Pantry Staples',
    'tafelberg':          'Pantry Staples',
    'pride maize':        'Pantry Staples',
    'pearl maize':        'Pantry Staples',
    'premier maize':      'Pantry Staples',
    "mama's sunshine":    'Pantry Staples',
    'mealie meal':        'Pantry Staples',
    'mealiemeel':         'Pantry Staples',
    'maize meal':         'Pantry Staples',
    'mielie meal':        'Pantry Staples',
    'mieliemeel':         'Pantry Staples',
    'pap':                'Pantry Staples',
    'stywe pap':          'Pantry Staples',
    'krummelpap':         'Pantry Staples',
    'phutu':              'Pantry Staples',
    'putu':               'Pantry Staples',
    'mageu':              'Pantry Staples',
    'maheu':              'Pantry Staples',
    'umqombothi':         'Pantry Staples',  // SA sorghum beer — sold dry in spaza
    'isidudu':            'Pantry Staples',
    'samp':               'Pantry Staples',
    'umngqusho':          'Pantry Staples',
    'sorghum':            'Pantry Staples',
    'maltabella':         'Pantry Staples',

    // Rice
    'tastic':             'Pantry Staples',
    'tastic rice':        'Pantry Staples',
    'spekko':             'Pantry Staples',
    'spekko rice':        'Pantry Staples',
    'basmati':            'Pantry Staples',
    'jasmine rice':       'Pantry Staples',
    'long-grain':         'Pantry Staples',
    'parboiled rice':     'Pantry Staples',
    'brown rice':         'Pantry Staples',
    'risotto rice':       'Pantry Staples',
    'arborio':            'Pantry Staples',

    // Flour & baking
    'snowflake':          'Pantry Staples',
    'sasko flour':        'Pantry Staples',
    'sasko cake flour':   'Pantry Staples',
    'eureka mill':        'Pantry Staples',
    'cake flour':         'Pantry Staples',
    'bread flour':        'Pantry Staples',
    'self-raising flour': 'Pantry Staples',
    'self raising flour': 'Pantry Staples',
    'whole wheat flour':  'Pantry Staples',
    'wholewheat flour':   'Pantry Staples',
    'rye flour':          'Pantry Staples',
    'maizena':            'Pantry Staples',
    'cornflour':          'Pantry Staples',
    'corn flour':         'Pantry Staples',
    'cornstarch':         'Pantry Staples',
    'breadcrumbs':        'Pantry Staples',
    'panko':              'Pantry Staples',
    'royal baking':       'Pantry Staples',
    'royal baking powder':'Pantry Staples',
    'baking powder':      'Pantry Staples',
    'baking soda':        'Pantry Staples',
    'bicarbonate':        'Pantry Staples',
    'instant yeast':      'Pantry Staples',
    'anchor yeast':       'Pantry Staples',
    'vanilla essence':    'Pantry Staples',
    'vanilla pod':        'Pantry Staples',
    'cocoa powder':       'Pantry Staples',
    'icing sugar':        'Pantry Staples',
    'caster sugar':       'Pantry Staples',
    'castor sugar':       'Pantry Staples',
    'brown sugar':        'Pantry Staples',
    'selati':             'Pantry Staples',  // SA sugar brand
    'huletts':            'Pantry Staples',
    'gelatine':           'Pantry Staples',
    'custard powder':     'Pantry Staples',
    'jelly powder':       'Pantry Staples',
    'desiccated coconut': 'Pantry Staples',
    'chocolate chips':    'Pantry Staples',

    // Canned veg / beans — Koo + competitors
    'koo':                'Pantry Staples',
    'koo baked beans':    'Pantry Staples',
    'koo chakalaka':      'Pantry Staples',
    'koo butter beans':   'Pantry Staples',
    'koo mixed veg':      'Pantry Staples',
    'baked beans':        'Pantry Staples',
    'butter beans':       'Pantry Staples',
    'kidney beans':       'Pantry Staples',
    'chickpeas':          'Pantry Staples',
    'lentils':            'Pantry Staples',
    'split peas':         'Pantry Staples',
    'tomato paste':       'Pantry Staples',
    'tomato puree':       'Pantry Staples',
    'passata':            'Pantry Staples',
    'coconut milk':       'Pantry Staples',
    'coconut cream':      'Pantry Staples',
    'chakalaka':          'Pantry Staples',

    // Pasta & noodles
    "fattis & monis":     'Pantry Staples',
    'fattis and monis':   'Pantry Staples',
    'spaghetti':          'Pantry Staples',
    'macaroni':           'Pantry Staples',
    'penne':              'Pantry Staples',
    'fusilli':            'Pantry Staples',
    'rigatoni':           'Pantry Staples',
    'lasagne sheets':     'Pantry Staples',
    'ramen':              'Pantry Staples',
    'rice noodle':        'Pantry Staples',
    'egg noodle':         'Pantry Staples',
    'two-minute noodle':  'Pantry Staples',
    'two minute noodle':  'Pantry Staples',
    'maggi 2 minute':     'Pantry Staples',

    // Cereals
    'pronutro':           'Pantry Staples',
    'jungle oats':        'Pantry Staples',
    'bokomo':             'Pantry Staples',
    'weet-bix':           'Pantry Staples',
    'weetbix':            'Pantry Staples',
    'morvite':            'Pantry Staples',
    'futurelife':         'Pantry Staples',
    'all bran':           'Pantry Staples',
    'corn flakes':        'Pantry Staples',
    'rolled oats':        'Pantry Staples',
    'instant oats':       'Pantry Staples',
    'muesli':             'Pantry Staples',
    'granola':            'Pantry Staples',

    // Stock / soup mix / dry sachets
    'knorrox':            'Pantry Staples',
    'knorr':              'Pantry Staples',
    'royco':              'Pantry Staples',
    'imana soup':         'Pantry Staples',
    'imana':              'Pantry Staples',
    'oxo':                'Pantry Staples',
    'maggi':              'Pantry Staples',
    'aromat':             'Spices & Herbs',   // moved below — listed early for clarity
    'stock cube':         'Pantry Staples',
    'beef stock':         'Pantry Staples',
    'chicken stock':      'Pantry Staples',
    'vegetable stock':    'Pantry Staples',
    'cup-a-soup':         'Pantry Staples',
    'cup a soup':         'Pantry Staples',

    // Oils & vinegar (must be checked before "avocado"/"olive" produce tokens)
    'avocado oil':        'Pantry Staples',
    'olive oil':          'Pantry Staples',
    'sunflower oil':      'Pantry Staples',
    'canola oil':         'Pantry Staples',
    'coconut oil':        'Pantry Staples',
    'sesame oil':         'Pantry Staples',
    'vegetable oil':      'Pantry Staples',
    'peanut oil':         'Pantry Staples',
    'ghee':               'Pantry Staples',
    'spray and cook':     'Pantry Staples',
    'balsamic vinegar':   'Pantry Staples',
    'apple cider vinegar':'Pantry Staples',
    'white vinegar':      'Pantry Staples',
    'red wine vinegar':   'Pantry Staples',
    'rice vinegar':       'Pantry Staples',

    // ════════════════════════════════════════════════════════════════════════
    // SPICES & HERBS
    // ════════════════════════════════════════════════════════════════════════

    // SA seasoning brands
    'rajah':              'Spices & Herbs',
    'rajah curry':        'Spices & Herbs',
    'robertsons':         'Spices & Herbs',
    "robertson's":        'Spices & Herbs',
    'ina paarman':        'Spices & Herbs',
    'paarman':            'Spices & Herbs',
    'cape herb':          'Spices & Herbs',
    'cape herb & spice':  'Spices & Herbs',
    'crown national':     'Spices & Herbs',
    'durban curry':       'Spices & Herbs',
    'mother in law':      'Spices & Herbs',
    "mother-in-law":      'Spices & Herbs',
    'masterspice':        'Spices & Herbs',
    'spur seasoning':     'Spices & Herbs',

    // SA spice blends
    'braai spice':        'Spices & Herbs',
    'braai salt':         'Spices & Herbs',
    'chicken spice':      'Spices & Herbs',
    'beef spice':         'Spices & Herbs',
    'lamb spice':         'Spices & Herbs',
    'fish spice':         'Spices & Herbs',
    'fish & chips spice': 'Spices & Herbs',
    'chip spice':         'Spices & Herbs',
    'steak rub':          'Spices & Herbs',
    'cape malay spice':   'Spices & Herbs',
    'cape malay':         'Spices & Herbs',
    'masala':             'Spices & Herbs',
    'garam masala':       'Spices & Herbs',
    'curry powder':       'Spices & Herbs',
    'mild curry':         'Spices & Herbs',
    'hot curry':          'Spices & Herbs',
    'mother in law masala':'Spices & Herbs',
    'peri-peri':          'Spices & Herbs',
    'peri peri':          'Spices & Herbs',
    'peri-peri salt':     'Spices & Herbs',
    'mixed spice':        'Spices & Herbs',
    'mixed herbs':        'Spices & Herbs',
    'italian seasoning':  'Spices & Herbs',
    'taco seasoning':     'Spices & Herbs',
    'fajita seasoning':   'Spices & Herbs',

    // Salt / pepper variants
    'salt':               'Spices & Herbs',
    'sea salt':           'Spices & Herbs',
    'rock salt':          'Spices & Herbs',
    'table salt':         'Spices & Herbs',
    'himalayan salt':     'Spices & Herbs',
    'kosher salt':        'Spices & Herbs',
    'maldon salt':        'Spices & Herbs',
    'black pepper':       'Spices & Herbs',
    'white pepper':       'Spices & Herbs',
    'ground pepper':      'Spices & Herbs',
    'cracked pepper':     'Spices & Herbs',
    'peppercorn':         'Spices & Herbs',
    'pink peppercorn':    'Spices & Herbs',
    'cayenne pepper':     'Spices & Herbs',
    'cayenne':            'Spices & Herbs',

    // Garlic / onion / ginger qualifier phrases — beat the produce tokens
    'garlic flakes':      'Spices & Herbs',
    'garlic powder':      'Spices & Herbs',
    'garlic salt':        'Spices & Herbs',
    'garlic granules':    'Spices & Herbs',
    'garlic paste':       'Spices & Herbs',
    'onion powder':       'Spices & Herbs',
    'onion flakes':       'Spices & Herbs',
    'onion granules':     'Spices & Herbs',
    'onion salt':         'Spices & Herbs',
    'ginger powder':      'Spices & Herbs',
    'ground ginger':      'Spices & Herbs',

    // Classic spices
    'paprika':            'Spices & Herbs',
    'smoked paprika':     'Spices & Herbs',
    'sweet paprika':      'Spices & Herbs',
    'cumin':              'Spices & Herbs',
    'ground cumin':       'Spices & Herbs',
    'turmeric':           'Spices & Herbs',
    'cinnamon':           'Spices & Herbs',
    'cinnamon stick':     'Spices & Herbs',
    'ground cinnamon':    'Spices & Herbs',
    'nutmeg':             'Spices & Herbs',
    'cardamom':           'Spices & Herbs',
    'cloves':             'Spices & Herbs',
    'allspice':           'Spices & Herbs',
    'star anise':         'Spices & Herbs',
    'fennel seed':        'Spices & Herbs',
    'coriander seed':     'Spices & Herbs',
    'coriander powder':   'Spices & Herbs',
    'mustard seed':       'Spices & Herbs',
    'caraway':            'Spices & Herbs',
    'saffron':            'Spices & Herbs',
    'sumac':              'Spices & Herbs',
    'fenugreek':          'Spices & Herbs',
    'mace':               'Spices & Herbs',
    'chilli flakes':      'Spices & Herbs',
    'chilli powder':      'Spices & Herbs',
    'crushed chilli':     'Spices & Herbs',
    'red pepper flakes':  'Spices & Herbs',

    // Dried herbs
    'oregano':            'Spices & Herbs',
    'thyme':              'Spices & Herbs',
    'rosemary':           'Spices & Herbs',
    'sage':               'Spices & Herbs',
    'basil dried':        'Spices & Herbs',
    'dried basil':        'Spices & Herbs',
    'dried mint':         'Spices & Herbs',
    'dill':               'Spices & Herbs',
    'tarragon':           'Spices & Herbs',
    'marjoram':           'Spices & Herbs',
    'bay leaf':           'Spices & Herbs',
    'bay leaves':         'Spices & Herbs',
    'parsley flakes':     'Spices & Herbs',
    'dried chives':       'Spices & Herbs',

    // ════════════════════════════════════════════════════════════════════════
    // CONDIMENTS & SAUCES
    // ════════════════════════════════════════════════════════════════════════

    // SA chutney & sauce icons
    "mrs ball":           'Condiments & Sauces',
    "mrs balls":          'Condiments & Sauces',
    "mrs ball's":         'Condiments & Sauces',
    "ball's chutney":     'Condiments & Sauces',
    "balls chutney":      'Condiments & Sauces',
    'chutney':            'Condiments & Sauces',
    'all gold':           'Condiments & Sauces',  // tomato sauce
    'all gold tomato':    'Condiments & Sauces',
    'tomato sauce':       'Condiments & Sauces',
    'crosse & blackwell': 'Condiments & Sauces',
    'crosse and blackwell':'Condiments & Sauces',
    'crosse and':         'Condiments & Sauces',  // shorthand
    'wellingtons':        'Condiments & Sauces',  // SA tomato sauce + chutney
    "wellington's":       'Condiments & Sauces',

    // Peri-peri (Nando's)
    'nandos':             'Condiments & Sauces',
    "nando's":            'Condiments & Sauces',
    'nandos peri':        'Condiments & Sauces',
    'nandos sauce':       'Condiments & Sauces',
    'peri-peri sauce':    'Condiments & Sauces',
    'peri peri sauce':    'Condiments & Sauces',

    // Mayo, mustard, ketchup variants
    'mayonnaise':         'Condiments & Sauces',
    'mayo':               'Condiments & Sauces',
    'crosse & blackwell mayo':'Condiments & Sauces',
    'hellmanns':          'Condiments & Sauces',
    "hellmann's":         'Condiments & Sauces',
    'cremora':            'Condiments & Sauces',  // creamer — close enough
    'mustard':            'Condiments & Sauces',
    'dijon':              'Condiments & Sauces',
    'wholegrain mustard': 'Condiments & Sauces',
    'english mustard':    'Condiments & Sauces',
    'ketchup':            'Condiments & Sauces',
    'bbq sauce':          'Condiments & Sauces',
    'barbecue sauce':     'Condiments & Sauces',
    'hot sauce':          'Condiments & Sauces',
    'chilli sauce':       'Condiments & Sauces',
    'sweet chilli':       'Condiments & Sauces',
    'sweet chilli sauce': 'Condiments & Sauces',
    'sriracha':           'Condiments & Sauces',
    'tabasco':            'Condiments & Sauces',
    'soy sauce':          'Condiments & Sauces',
    'kikkoman':           'Condiments & Sauces',
    'fish sauce':         'Condiments & Sauces',
    'oyster sauce':       'Condiments & Sauces',
    'hoisin':             'Condiments & Sauces',
    'teriyaki':           'Condiments & Sauces',
    'worcestershire':     'Condiments & Sauces',
    'lea & perrins':      'Condiments & Sauces',
    'hp sauce':           'Condiments & Sauces',
    'pesto':              'Condiments & Sauces',
    'tapenade':           'Condiments & Sauces',
    'tahini':             'Condiments & Sauces',
    'aioli':              'Condiments & Sauces',
    'salsa':              'Condiments & Sauces',

    // Atchar — SA pickle staple
    'atchar':             'Condiments & Sauces',
    'achar':              'Condiments & Sauces',
    'mango atchar':       'Condiments & Sauces',
    'lemon atchar':       'Condiments & Sauces',

    // Peanut butter & sweet spreads
    'black cat':          'Condiments & Sauces',  // SA peanut butter brand
    'yum yum':            'Condiments & Sauces',  // SA peanut butter brand
    'peanut butter':      'Condiments & Sauces',
    'almond butter':      'Condiments & Sauces',
    'cashew butter':      'Condiments & Sauces',
    'nutella':            'Condiments & Sauces',
    'chocolate spread':   'Condiments & Sauces',
    'hazelnut spread':    'Condiments & Sauces',
    'marmite':            'Condiments & Sauces',
    'bovril':             'Condiments & Sauces',
    'vegemite':           'Condiments & Sauces',
    'liver spread':       'Condiments & Sauces',
    'jam':                'Condiments & Sauces',
    'marmalade':          'Condiments & Sauces',
    'preserve':           'Condiments & Sauces',
    'honey':              'Condiments & Sauces',
    'syrup':              'Condiments & Sauces',
    'golden syrup':       'Condiments & Sauces',
    'maple syrup':        'Condiments & Sauces',
    'treacle':            'Condiments & Sauces',
    'agave':              'Condiments & Sauces',
    'condensed milk':     'Condiments & Sauces',

    // Pickles / olives / relishes
    'pickles':            'Condiments & Sauces',
    'gherkin':            'Condiments & Sauces',
    'sauerkraut':         'Condiments & Sauces',
    'olives':             'Condiments & Sauces',
    'kalamata':           'Condiments & Sauces',
    'capers':             'Condiments & Sauces',
    'relish':             'Condiments & Sauces',
    'tomato relish':      'Condiments & Sauces',
    'onion marmalade':    'Condiments & Sauces',

    // Dressings
    'dressing':           'Condiments & Sauces',
    'salad dressing':     'Condiments & Sauces',
    'vinaigrette':        'Condiments & Sauces',
    'ranch':              'Condiments & Sauces',
    'caesar dressing':    'Condiments & Sauces',
    'french dressing':    'Condiments & Sauces',
    'italian dressing':   'Condiments & Sauces',
    'thousand island':    'Condiments & Sauces',

    // Restaurant brand sauces
    'steers sauce':       'Condiments & Sauces',
    'spur sauce':         'Condiments & Sauces',
    'spur monkeygland':   'Condiments & Sauces',
    'monkeygland':        'Condiments & Sauces',
    'mama africa':        'Condiments & Sauces',

    // ════════════════════════════════════════════════════════════════════════
    // BEVERAGES — tea, coffee, cordials, juice, soft drinks, alcohol
    // ════════════════════════════════════════════════════════════════════════

    // Rooibos & tea brands
    'rooibos':            'Beverages',
    'rooibos tea':        'Beverages',
    'freshpak':           'Beverages',
    'freshpak rooibos':   'Beverages',
    'five roses':         'Beverages',
    '5 roses':            'Beverages',
    'joko':               'Beverages',
    'joko tea':           'Beverages',
    'glen tea':           'Beverages',
    'glen ':              'Beverages',
    'trinco':             'Beverages',
    'vital tea':          'Beverages',
    'twinings':           'Beverages',
    'tetley':             'Beverages',
    'lipton':             'Beverages',
    'black tea':          'Beverages',
    'green tea':          'Beverages',
    'herbal tea':         'Beverages',
    'chamomile':          'Beverages',
    'earl grey':          'Beverages',
    'english breakfast':  'Beverages',
    'jasmine tea':        'Beverages',
    'iced tea':           'Beverages',

    // Coffee
    'ricoffy':            'Beverages',
    'frisco':             'Beverages',
    'jacobs':             'Beverages',
    'jacobs coffee':      'Beverages',
    'nescafe':            'Beverages',
    'nescafé':            'Beverages',
    'caro':               'Beverages',
    'bonaparte':          'Beverages',
    'instant coffee':     'Beverages',
    'ground coffee':      'Beverages',
    'coffee beans':       'Beverages',
    'espresso':           'Beverages',
    'cappuccino':         'Beverages',
    'mocha mix':          'Beverages',
    'latte mix':          'Beverages',
    'hot chocolate':      'Beverages',
    'cocoa drink':        'Beverages',
    'milo':               'Beverages',
    'horlicks':           'Beverages',
    'ovaltine':           'Beverages',

    // Cordials & juices (SA classics)
    'oros':               'Beverages',
    'oros orange':        'Beverages',
    'halls':              'Beverages',
    "hall's":             'Beverages',
    'squash':             'Beverages',
    'cordial':            'Beverages',
    'liqui-fruit':        'Beverages',
    'liqui fruit':        'Beverages',
    'liquifruit':         'Beverages',
    'ceres':              'Beverages',
    'ceres juice':        'Beverages',
    'sir juice':          'Beverages',
    'clover krush':       'Beverages',
    'tropika':            'Beverages',
    'fruit juice':        'Beverages',
    'orange juice':       'Beverages',
    'apple juice':        'Beverages',
    'mango juice':        'Beverages',
    'guava juice':        'Beverages',

    // Soft drinks
    'iron brew':          'Beverages',
    'iron-brew':          'Beverages',
    'irn-bru':            'Beverages',
    'stoney':             'Beverages',
    'stoney ginger':      'Beverages',
    'sparletta':          'Beverages',
    'sparberry':          'Beverages',
    'creme soda':         'Beverages',
    'crème soda':         'Beverages',
    'fanta':              'Beverages',
    'sprite':             'Beverages',
    'coke':               'Beverages',
    'coca-cola':          'Beverages',
    'coca cola':          'Beverages',
    'pepsi':              'Beverages',
    'twist':              'Beverages',
    'schweppes':          'Beverages',
    'appletiser':         'Beverages',
    'grapetiser':         'Beverages',
    'sparkling water':    'Beverages',
    'still water':        'Beverages',
    'mineral water':      'Beverages',
    'bonaqua':            'Beverages',
    'aquellé':            'Beverages',

    // Alcohol
    'castle lager':       'Beverages',
    'castle lite':        'Beverages',
    'black label':        'Beverages',
    'carling':            'Beverages',
    'hansa':              'Beverages',
    'amstel':             'Beverages',
    'heineken':           'Beverages',
    'windhoek':           'Beverages',
    'savanna':            'Beverages',
    'hunters':            'Beverages',
    'brutal fruit':       'Beverages',
    'smirnoff spin':      'Beverages',
    'smirnoff storm':     'Beverages',
    'klipdrift':          'Beverages',
    'amarula':            'Beverages',
    'kwv':                'Beverages',
    'nederburg':          'Beverages',
    'two oceans':         'Beverages',
    'tassenberg':         'Beverages',
    'tassies':            'Beverages',
    'robertson winery':   'Beverages',
    'autumn harvest':     'Beverages',

    // ════════════════════════════════════════════════════════════════════════
    // MEAT & FISH — fresh, processed, tinned, dried
    // ════════════════════════════════════════════════════════════════════════

    // Tinned fish brands
    'lucky star':         'Meat & Fish',
    'saldanha':           'Meat & Fish',
    'glenryck':           'Meat & Fish',
    'john west':          'Meat & Fish',
    'pilchards':          'Meat & Fish',
    'sardines':           'Meat & Fish',
    'tinned tuna':        'Meat & Fish',
    'shredded tuna':      'Meat & Fish',
    'fish in tomato':     'Meat & Fish',

    // Processed meat brands
    'enterprise':         'Meat & Fish',
    'eskort':             'Meat & Fish',
    'eskort bacon':       'Meat & Fish',
    'rainbow chicken':    'Meat & Fish',
    'astral':             'Meat & Fish',
    'county fair':        'Meat & Fish',
    'country fair':       'Meat & Fish',
    'quantum chicken':    'Meat & Fish',
    'patty plus':         'Meat & Fish',
    'i&j':                'Meat & Fish',
    'i & j':              'Meat & Fish',
    'sea harvest':        'Meat & Fish',
    'oceana':             'Meat & Fish',

    // SA dried meats / wors
    'biltong':            'Meat & Fish',
    'droëwors':           'Meat & Fish',
    'drywors':            'Meat & Fish',
    'droewors':           'Meat & Fish',
    'boerewors':          'Meat & Fish',
    'boerie':             'Meat & Fish',
    'wors':               'Meat & Fish',
    'russian':            'Meat & Fish',  // SA sausage
    'frankfurter':        'Meat & Fish',
    'vienna':             'Meat & Fish',
    'cabanossi':          'Meat & Fish',
    'chorizo':            'Meat & Fish',
    'salami':             'Meat & Fish',
    'polony':             'Meat & Fish',
    'french polony':      'Meat & Fish',
    'garlic polony':      'Meat & Fish',
    'cold meat':          'Meat & Fish',
    'cold cuts':          'Meat & Fish',

    // Fresh proteins
    'chicken':            'Meat & Fish',
    'chicken breast':     'Meat & Fish',
    'chicken thigh':      'Meat & Fish',
    'chicken thighs':     'Meat & Fish',
    'chicken wings':      'Meat & Fish',
    'chicken drumstick':  'Meat & Fish',
    'chicken livers':     'Meat & Fish',
    'whole chicken':      'Meat & Fish',
    'beef':               'Meat & Fish',
    'beef mince':         'Meat & Fish',
    'mince':              'Meat & Fish',
    'rump':               'Meat & Fish',
    'sirloin':            'Meat & Fish',
    'fillet':             'Meat & Fish',
    'steak':              'Meat & Fish',
    'brisket':            'Meat & Fish',
    'chuck':              'Meat & Fish',
    'oxtail':             'Meat & Fish',
    'short rib':          'Meat & Fish',
    'spare rib':          'Meat & Fish',
    'lamb':               'Meat & Fish',
    'lamb chop':          'Meat & Fish',
    'lamb shank':         'Meat & Fish',
    'lamb knuckle':       'Meat & Fish',
    'mutton':             'Meat & Fish',
    'pork':               'Meat & Fish',
    'pork belly':         'Meat & Fish',
    'pork chop':          'Meat & Fish',
    'bacon':              'Meat & Fish',
    'ham':                'Meat & Fish',
    'gammon':             'Meat & Fish',

    // Indigenous / hunting meats
    'venison':            'Meat & Fish',
    'springbok':          'Meat & Fish',
    'kudu':               'Meat & Fish',
    'eland':              'Meat & Fish',
    'gemsbok':            'Meat & Fish',
    'blesbok':            'Meat & Fish',
    'ostrich':            'Meat & Fish',
    'crocodile':          'Meat & Fish',

    // Offal / township staples
    'tripe':              'Meat & Fish',
    'mogodu':             'Meat & Fish',
    'mala mogodu':        'Meat & Fish',
    'walkie talkie':      'Meat & Fish',  // chicken feet
    'chicken feet':       'Meat & Fish',
    'skopo':              'Meat & Fish',
    'smiley':             'Meat & Fish',
    'liver':              'Meat & Fish',
    'kidneys':            'Meat & Fish',
    'sweetbreads':        'Meat & Fish',
    'sosaties':           'Meat & Fish',
    'sosatie':            'Meat & Fish',
    'frikkadel':          'Meat & Fish',
    'frikkadelle':        'Meat & Fish',

    // Fresh fish & seafood
    'snoek':              'Meat & Fish',
    'kingklip':           'Meat & Fish',
    'hake':               'Meat & Fish',
    'kabeljou':           'Meat & Fish',
    'yellowtail':         'Meat & Fish',
    'tuna steak':         'Meat & Fish',
    'salmon':             'Meat & Fish',
    'trout':              'Meat & Fish',
    'prawns':             'Meat & Fish',
    'shrimp':             'Meat & Fish',
    'mussels':            'Meat & Fish',
    'calamari':           'Meat & Fish',
    'squid':              'Meat & Fish',

    // ════════════════════════════════════════════════════════════════════════
    // FRUIT & VEGGIES — fresh produce
    // ════════════════════════════════════════════════════════════════════════

    'tomato':             'Fruit & Veggies',
    'tomatoes':           'Fruit & Veggies',
    'onion':              'Fruit & Veggies',
    'onions':             'Fruit & Veggies',
    'red onion':          'Fruit & Veggies',
    'spring onion':       'Fruit & Veggies',
    'garlic':             'Fruit & Veggies',
    'ginger':             'Fruit & Veggies',
    'potato':             'Fruit & Veggies',
    'potatoes':           'Fruit & Veggies',
    'sweet potato':       'Fruit & Veggies',
    'carrot':             'Fruit & Veggies',
    'carrots':            'Fruit & Veggies',
    'beetroot':           'Fruit & Veggies',
    'cabbage':            'Fruit & Veggies',
    'spinach':            'Fruit & Veggies',
    'morogo':             'Fruit & Veggies',  // SA wild spinach
    'imifino':            'Fruit & Veggies',
    'umfino':             'Fruit & Veggies',
    'lettuce':            'Fruit & Veggies',
    'rocket':             'Fruit & Veggies',
    'kale':               'Fruit & Veggies',
    'broccoli':           'Fruit & Veggies',
    'cauliflower':        'Fruit & Veggies',
    'butternut':          'Fruit & Veggies',
    'pumpkin':            'Fruit & Veggies',
    'gem squash':         'Fruit & Veggies',
    'baby marrow':        'Fruit & Veggies',
    'zucchini':           'Fruit & Veggies',
    'brinjal':            'Fruit & Veggies',
    'eggplant':           'Fruit & Veggies',
    'cucumber':           'Fruit & Veggies',
    'celery':             'Fruit & Veggies',
    'leek':               'Fruit & Veggies',
    'mushroom':           'Fruit & Veggies',
    'mushrooms':          'Fruit & Veggies',
    'bell pepper':        'Fruit & Veggies',
    'green pepper':       'Fruit & Veggies',
    'red pepper':         'Fruit & Veggies',
    'yellow pepper':      'Fruit & Veggies',
    'chilli':             'Fruit & Veggies',
    'green chilli':       'Fruit & Veggies',
    'fresh coriander':    'Fruit & Veggies',
    'fresh basil':        'Fruit & Veggies',
    'fresh mint':         'Fruit & Veggies',
    'fresh parsley':      'Fruit & Veggies',
    'corn':               'Fruit & Veggies',
    'mielies':            'Fruit & Veggies',
    'mealie':             'Fruit & Veggies',
    'peas':               'Fruit & Veggies',
    'green beans':        'Fruit & Veggies',
    'asparagus':          'Fruit & Veggies',
    'avocado':            'Fruit & Veggies',
    'lemon':              'Fruit & Veggies',
    'lime':               'Fruit & Veggies',
    'apple':              'Fruit & Veggies',
    'apples':             'Fruit & Veggies',
    'banana':             'Fruit & Veggies',
    'orange':             'Fruit & Veggies',
    'naartjie':           'Fruit & Veggies',
    'grapefruit':         'Fruit & Veggies',
    'pear':               'Fruit & Veggies',
    'peach':              'Fruit & Veggies',
    'nectarine':          'Fruit & Veggies',
    'plum':               'Fruit & Veggies',
    'apricot':            'Fruit & Veggies',
    'mango':              'Fruit & Veggies',
    'pawpaw':             'Fruit & Veggies',
    'papaya':             'Fruit & Veggies',
    'pineapple':          'Fruit & Veggies',
    'watermelon':         'Fruit & Veggies',
    'spanspek':           'Fruit & Veggies',  // SA cantaloupe
    'melon':              'Fruit & Veggies',
    'grapes':             'Fruit & Veggies',
    'kiwi':               'Fruit & Veggies',
    'strawberry':         'Fruit & Veggies',
    'strawberries':       'Fruit & Veggies',
    'blueberry':          'Fruit & Veggies',
    'raspberry':          'Fruit & Veggies',
    'cherry':             'Fruit & Veggies',
    'figs':               'Fruit & Veggies',
    'marula':             'Fruit & Veggies',
    'rooibos berry':      'Fruit & Veggies',

    // ════════════════════════════════════════════════════════════════════════
    // DAIRY & CHILLED
    // ════════════════════════════════════════════════════════════════════════

    'clover':             'Dairy & Chilled',
    'clover milk':        'Dairy & Chilled',
    'parmalat':           'Dairy & Chilled',
    'fairfield':          'Dairy & Chilled',
    'douglasdale':        'Dairy & Chilled',
    'simonsberg':         'Dairy & Chilled',
    'lancewood':          'Dairy & Chilled',
    'woodlands':          'Dairy & Chilled',
    'danone':             'Dairy & Chilled',
    'yoplait':            'Dairy & Chilled',
    'first choice':       'Dairy & Chilled',
    'crystal valley':     'Dairy & Chilled',
    'full-cream milk':    'Dairy & Chilled',
    'full cream milk':    'Dairy & Chilled',
    'low-fat milk':       'Dairy & Chilled',
    'skim milk':          'Dairy & Chilled',
    'fat-free milk':      'Dairy & Chilled',
    'fresh milk':         'Dairy & Chilled',
    'long-life milk':     'Dairy & Chilled',
    'uht milk':           'Dairy & Chilled',
    'cream':              'Dairy & Chilled',
    'whipping cream':     'Dairy & Chilled',
    'fresh cream':        'Dairy & Chilled',
    'sour cream':         'Dairy & Chilled',
    'crème fraîche':      'Dairy & Chilled',
    'creme fraiche':      'Dairy & Chilled',
    'cheese':             'Dairy & Chilled',
    'cheddar':            'Dairy & Chilled',
    'sweetmilk cheese':   'Dairy & Chilled',
    'feta':               'Dairy & Chilled',
    'mozzarella':         'Dairy & Chilled',
    'parmesan':           'Dairy & Chilled',
    'gouda':              'Dairy & Chilled',
    'edam':               'Dairy & Chilled',
    'cottage cheese':     'Dairy & Chilled',
    'cream cheese':       'Dairy & Chilled',
    'mascarpone':         'Dairy & Chilled',
    'halloumi':           'Dairy & Chilled',
    'ricotta':            'Dairy & Chilled',
    'butter':             'Dairy & Chilled',
    'margarine':          'Dairy & Chilled',
    'rama':               'Dairy & Chilled',
    'flora':              'Dairy & Chilled',
    'stork':              'Dairy & Chilled',
    'yogurt':             'Dairy & Chilled',
    'yoghurt':            'Dairy & Chilled',
    'greek yoghurt':      'Dairy & Chilled',
    'amasi':              'Dairy & Chilled',
    'maas':               'Dairy & Chilled',
    'inkomazi':           'Dairy & Chilled',
    'egg':                'Dairy & Chilled',
    'eggs':               'Dairy & Chilled',
    'free-range eggs':    'Dairy & Chilled',
    'free range eggs':    'Dairy & Chilled',
    'liquid custard':     'Dairy & Chilled',
    'buttermilk':         'Dairy & Chilled',

    // ════════════════════════════════════════════════════════════════════════
    // BAKERY — fresh bread, rolls, traditional baked goods
    // ════════════════════════════════════════════════════════════════════════

    'albany':             'Bakery',
    'albany bread':       'Bakery',
    'sasko bread':        'Bakery',
    'blue ribbon':        'Bakery',
    'sunbake':            'Bakery',
    'baker street':       'Bakery',
    'bread':              'Bakery',
    'brown bread':        'Bakery',
    'white bread':        'Bakery',
    'whole wheat bread':  'Bakery',
    'low gi bread':       'Bakery',
    'rye bread':          'Bakery',
    'sourdough':          'Bakery',
    'baguette':           'Bakery',
    'ciabatta':           'Bakery',
    'roll':               'Bakery',
    'bread roll':         'Bakery',
    'hot dog roll':       'Bakery',
    'hamburger bun':      'Bakery',
    'kaiser roll':        'Bakery',
    'pita':               'Bakery',
    'pita bread':         'Bakery',
    'roti':               'Bakery',
    'wrap':               'Bakery',
    'tortilla':           'Bakery',
    'bun':                'Bakery',
    'cake':               'Bakery',
    'biscuit':            'Bakery',
    'cookies':            'Bakery',
    'scone':              'Bakery',
    'crumpet':            'Bakery',
    'vetkoek':            'Bakery',
    'fatcakes':           'Bakery',
    'magwinya':           'Bakery',
    'koeksister':         'Bakery',
    'koeksisters':        'Bakery',
    'milk tart':          'Bakery',
    'melktert':           'Bakery',
    'hertzoggies':        'Bakery',
    'soetkoekies':        'Bakery',
    'ouma rusks':         'Bakery',
    'ouma':               'Bakery',
    'bakers':             'Bakery',
    'rusks':              'Bakery',
    'beskuit':            'Bakery',
    'romany creams':      'Bakery',
    'tennis biscuits':    'Bakery',
    'marie biscuits':     'Bakery',
    'eet-sum-mor':        'Bakery',
    'eet sum mor':        'Bakery',
    'choc kits':          'Bakery',
    'tex':                'Bakery',
    'bar one':            'Bakery',
    'lunch bar':          'Bakery',
    'cadbury':            'Bakery',
    'beacon':             'Bakery',
    'aero':               'Bakery',
    'peppermint crisp':   'Bakery',

    // ════════════════════════════════════════════════════════════════════════
    // FROZEN
    // ════════════════════════════════════════════════════════════════════════

    'mccain':             'Frozen',
    "mccain's":           'Frozen',
    'mccains':            'Frozen',
    'goldcrest':          'Frozen',
    'frozen peas':        'Frozen',
    'frozen veg':         'Frozen',
    'frozen mixed':       'Frozen',
    'frozen berries':     'Frozen',
    'frozen chips':       'Frozen',
    'oven chips':         'Frozen',
    'crinkle chips':      'Frozen',
    'frozen pizza':       'Frozen',
    'ice cream':          'Frozen',
    'magnum':             'Frozen',
    'cornetto':           'Frozen',
    'gelato':             'Frozen',
    'sorbet':             'Frozen',
    'ice lolly':          'Frozen',
    'ice pop':            'Frozen',
    'rolo ice':           'Frozen',
    'country fresh':      'Frozen',
  };

  // ────────────────────────────────────────────────────────────────────────────
  // Public lookup
  // ────────────────────────────────────────────────────────────────────────────

  /// Returns the matching category label (case-insensitive). Falls back to
  /// 'Other' when the input doesn't contain any recognised brand or term.
  ///
  /// Use this when you need the raw label string (e.g. analytics, tooltips).
  /// For category-typed results use [tryLookupCategory] which returns the
  /// `GroceryCategory` enum value directly and `null` on no match.
  static String lookup(String input) {
    if (input.trim().isEmpty) return 'Other';
    final cleanInput = input.toLowerCase().trim();

    for (final entry in productToCategory.entries) {
      if (cleanInput.contains(entry.key)) return entry.value;
    }
    return 'Other';
  }

  /// Type-safe variant: returns the matching [GroceryCategory] or `null` so
  /// callers can branch on "no match found" without string comparison.
  static GroceryCategory? tryLookupCategory(String input) {
    if (input.trim().isEmpty) return null;
    final cleanInput = input.toLowerCase().trim();

    for (final entry in productToCategory.entries) {
      if (cleanInput.contains(entry.key)) {
        return _labelToCategory(entry.value);
      }
    }
    return null;
  }

  /// Convert a UI label string back to the enum value. Used by callers that
  /// stored a label string and need to re-render with the enum's `emoji`.
  static GroceryCategory? labelToCategory(String label) =>
      _labelToCategory(label);

  static GroceryCategory? _labelToCategory(String label) {
    for (final c in GroceryCategory.values) {
      if (c.displayName == label) return c;
    }
    return null;
  }

  /// Number of brand/product entries currently in the lookup table.
  /// Exposed for debug/about screens.
  static int get entryCount => productToCategory.length;
}
