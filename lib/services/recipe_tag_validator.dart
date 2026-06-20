// lib/services/recipe_tag_validator.dart
//
// Logical validation for the three energy/cooking-method tags every
// ChowSA recipe carries:
//
//   • isLoadsheddingFriendly  (rendered as "No-Power OK")
//   • isBraaiReady            (rendered as "Braai / Fire Ready")
//   • needsElectricity        (legacy seasonal seed; equivalent to NOT
//                              isLoadsheddingFriendly + electric-only verbs)
//
// The validator scans the recipe's instructions for keywords that
// contradict the selected tag and returns a list of [TagConflict] objects.
// The UI surfaces these as a red banner before saving; the AI-generation
// prompt enforces the same rules so Gemini's JSON output can't ship with
// internally-contradictory tags either.
//
// Single source of truth — both client edit/save and the AI prompt
// reference the same keyword lists below, so a change in one place
// updates both paths.

class TagConflict {
  const TagConflict({
    required this.tag,
    required this.offendingTerm,
    required this.message,
  });
  final String tag;
  final String offendingTerm;
  final String message;
}

class RecipeTagValidator {
  RecipeTagValidator._();

  // ── Keyword pools ──────────────────────────────────────────────────────────
  //
  // Lowercase, word-boundary matched. Designed to be conservative — false
  // positives are corrected by editing the instruction line; false NEGATIVES
  // ship a contradiction. We bias toward false positives.

  /// Verbs / appliances that REQUIRE mains electricity. A recipe tagged
  /// "No-Power OK" containing any of these is a contradiction.
  static const List<String> electricOnly = [
    'microwave', 'microwaved', 'microwaving',
    'oven', 'oven-baked', 'preheat',
    'bake ', 'baked ', 'baking ',
    'air fry', 'air-fry', 'air fryer', 'airfryer',
    'electric stove', 'electric hob', 'electric plate',
    'deep fry', 'deep-fry', 'deep fryer',
    'food processor', 'blender ', 'blitz',
    'slow cooker', 'slow-cooker', 'pressure cooker', 'instant pot',
    'toaster', 'kettle ', 'rice cooker', 'waffle iron',
    'stand mixer', 'hand mixer', 'electric whisk',
    'induction', 'induction hob',
  ];

  /// Verbs that signal stove-top cooking — fine for gas OR electric. Listed
  /// so the validator can distinguish between "frying needs a stove" (true)
  /// and "frying needs electricity" (false — gas works).
  static const List<String> stoveTopGeneric = [
    'fry', 'fried', 'frying', 'pan-fry', 'pan-fried', 'shallow fry',
    'sear', 'seared', 'searing',
    'sauté', 'saute', 'sautéed', 'sauteed',
    'boil', 'boiled', 'boiling', 'simmer', 'simmered', 'simmering',
    'poach', 'poached', 'poaching',
    'steam', 'steamed', 'steaming',
    'reduce', 'reduced sauce',
  ];

  /// Verbs / equipment that imply cooking over real fire / coals / wood.
  /// A recipe tagged "Braai Ready" without any of these is suspicious.
  static const List<String> openFire = [
    'braai', 'coals', 'coal', 'open fire', 'open-fire',
    'fire pit', 'wood fire', 'wood-fire', 'wood-fired',
    'grid', 'grill over', 'grilled over', 'grilling over',
    'potjie', 'three-legged pot', 'cast iron pot over',
    'sosatie', 'spit', 'spit-roast', 'rotisserie over coals',
    'kettle braai', 'weber',
  ];

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Returns every conflict between the recipe's selected tags and its
  /// instructions. Empty list = the recipe is internally consistent.
  ///
  /// [instructions] should be the joined free-text of every step, lowercased
  /// internally — callers can pass the original casing.
  static List<TagConflict> validate({
    required List<String> instructions,
    bool isLoadsheddingFriendly = false,
    bool isBraaiReady           = false,
    bool needsElectricity       = false,
  }) {
    final body = instructions.join(' \n ').toLowerCase();
    final out  = <TagConflict>[];

    // ── No-Power OK ──────────────────────────────────────────────────────
    if (isLoadsheddingFriendly) {
      for (final kw in electricOnly) {
        if (_hit(body, kw)) {
          out.add(TagConflict(
            tag:           'No-Power OK',
            offendingTerm: kw.trim(),
            message:
                '"No-Power OK" can\'t coexist with "$kw" — it needs mains '
                'electricity. Remove the tag or rewrite the step (e.g. use '
                'a gas hob, coals, or no cooking).',
          ));
        }
      }
    }

    // ── Braai / Fire Ready ───────────────────────────────────────────────
    if (isBraaiReady) {
      final hasFire = openFire.any((kw) => _hit(body, kw));
      if (!hasFire) {
        out.add(TagConflict(
          tag:           'Braai Ready',
          offendingTerm: '(no fire/coals reference)',
          message:
              '"Braai Ready" requires explicit cooking over coals, wood, '
              'or open flame in the instructions (braai, coals, potjie, '
              'grid, fire pit, etc.). Either remove the tag or add a '
              'fire-based step.',
        ));
      }
    }

    // ── needsElectricity ──────────────────────────────────────────────────
    // If a recipe explicitly says it needs electricity but every cooking
    // verb is fire-based, the tag is wrong.
    if (needsElectricity) {
      final hasElectric = electricOnly.any((kw) => _hit(body, kw));
      final hasFire     = openFire.any((kw) => _hit(body, kw));
      if (!hasElectric && hasFire) {
        out.add(const TagConflict(
          tag:           'Needs Electricity',
          offendingTerm: '(only fire-based steps)',
          message:
              '"Needs Electricity" is set but the instructions only use '
              'coals/fire. Drop the tag or replace fire-based steps with '
              'electric ones (oven, hob, microwave).',
        ));
      }
    }

    // ── Cross-tag contradictions ─────────────────────────────────────────
    if (isLoadsheddingFriendly && needsElectricity) {
      out.add(const TagConflict(
        tag:           'No-Power OK + Needs Electricity',
        offendingTerm: '(both tags set)',
        message:
            'A recipe cannot be both "No-Power OK" and "Needs Electricity" '
            '— pick one.',
      ));
    }

    return out;
  }

  /// Whole-word-ish keyword match. We append a trailing space to multi-word
  /// terms to avoid clobbering substrings (e.g. "fry" should not hit
  /// "frydays"), but allow start-of-string + punctuation boundaries.
  static bool _hit(String body, String kw) {
    // Pad both sides so word boundaries cleanly match against newlines and
    // punctuation that the joined body already contains.
    final padded = ' $body ';
    final term   = kw.toLowerCase();
    // Single-token verbs need real word boundaries; multi-word phrases can
    // match anywhere because their own spaces enforce the boundary.
    if (term.contains(' ') || term.contains('-')) {
      return padded.contains(term);
    }
    // Single token — flank with non-letter to avoid substring false hits.
    final re = RegExp('(?<![a-z])${RegExp.escape(term)}(?![a-z])',
        caseSensitive: false);
    return re.hasMatch(padded);
  }

  /// Convenience: human-readable summary line for a single conflict, ready
  /// to drop into a SnackBar / banner.
  static String formatBanner(List<TagConflict> conflicts) {
    if (conflicts.isEmpty) return '';
    if (conflicts.length == 1) return conflicts.first.message;
    return '${conflicts.length} tag conflicts:\n'
        '${conflicts.map((c) => "• ${c.message}").join("\n")}';
  }
}
