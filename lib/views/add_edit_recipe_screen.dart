// lib/views/add_edit_recipe_screen.dart
//
// Shared screen for both Creating and Editing a personal Recipe.
//   • recipe == null  → "New Recipe" mode (all fields start empty)
//   • recipe != null  → "Edit Recipe" mode (fields pre-filled)
//
// Returns Recipe? via Navigator.pop:
//   null    → user cancelled / backed out
//   Recipe  → user saved; the caller is responsible for persisting it.

import 'package:flutter/material.dart';
import '../models/recipe.dart';
import '../models/ingredient.dart';
import '../services/recipe_tag_validator.dart';

// =============================================================================
// Design tokens
// =============================================================================

const _kForest = Color(0xFF0C351E);
const _kOrange = Color(0xFFE59B27);
const _kCream  = Color(0xFFF4F1EA);
const _kMuted  = Color(0xFF55534E);

// =============================================================================
// AddEditRecipeScreen
// =============================================================================

class AddEditRecipeScreen extends StatefulWidget {
  const AddEditRecipeScreen({super.key, this.recipe});

  /// Pre-fill form when editing. Null means create-new mode.
  final Recipe? recipe;

  @override
  State<AddEditRecipeScreen> createState() => _AddEditRecipeScreenState();
}

class _AddEditRecipeScreenState extends State<AddEditRecipeScreen> {
  final _formKey          = GlobalKey<FormState>();
  final _titleCtrl        = TextEditingController();
  final _instructionsCtrl = TextEditingController();
  final _ingredientCtrl   = TextEditingController();
  final _ingredientFocus  = FocusNode();

  // One TextEditingController per ingredient row — lets the user tweak the
  // quantity / wording of each saved ingredient inline. On save we read the
  // current text out of every controller, so edits sync straight through
  // _parseIngredient → Recipe.ingredients → Supabase `recipes.ingredients`.
  final List<TextEditingController> _ingredientCtrls = [];
  final List<FocusNode>              _ingredientFocusNodes = [];

  bool get _isEditing => widget.recipe != null;

  @override
  void initState() {
    super.initState();
    if (_isEditing) {
      final r = widget.recipe!;
      _titleCtrl.text        = r.title;
      // Pre-format the AI's raw instruction strings into numbered, scannable
      // steps before dumping them into the controller.
      _instructionsCtrl.text = _formatInstructions(r.instructions);
      // Seed an editable controller per ingredient so the user can tweak
      // quantity / wording inline without re-typing the whole row.
      for (final ing in r.ingredients) {
        _ingredientCtrls.add(TextEditingController(text: ing.toString().trim()));
        _ingredientFocusNodes.add(FocusNode());
      }
    }
  }

  // ── Instruction formatter ──────────────────────────────────────────────────
  //
  // The AI can return instructions in two messy shapes:
  //   A) Already-split list: ["Heat oil…", "Add onions…", "Season well…"]
  //   B) Unstructured paragraph blob in element [0]:
  //      "Heat oil in a pan over medium heat. Add the onions and fry until
  //       golden. Season well and serve hot."
  //
  // For (A) we just prefix each item with its step number.
  // For (B) we split by sentence-ending punctuation, prepend numbers, and
  // rebuild — so the user sees scannable steps in the text field instead of
  // one wall of text.
  String _formatInstructions(List<String> rawSteps) {
    if (rawSteps.isEmpty) return '';

    // Pre-clean: drop empties, collapse internal whitespace.
    final cleaned = rawSteps
        .map((s) => s.trim().replaceAll(RegExp(r'\s+'), ' '))
        .where((s) => s.isNotEmpty)
        .toList();

    if (cleaned.isEmpty) return '';

    // If the AI returned a single long paragraph (one element, > ~140 chars,
    // multiple sentences), split it into individual steps by sentence break.
    final List<String> steps;
    if (cleaned.length == 1 && cleaned.first.length > 140 &&
        RegExp(r'\.\s+[A-Z]').hasMatch(cleaned.first)) {
      // Split on ". ", "! ", "? " when followed by a capital letter — a
      // robust sentence boundary that won't split decimals like "1.5 cups".
      steps = cleaned.first
          .split(RegExp(r'(?<=[\.!?])\s+(?=[A-Z])'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
    } else {
      steps = cleaned;
    }

    // Strip any existing leading numbering / bullets ("1. ", "2)", "• ", "- ")
    // so we don't double-prefix when the AI sent its own numbered list.
    final stripped = steps.map((s) {
      return s.replaceFirst(
        RegExp(r'^(?:\d+[\.\)]\s*|[•\-\*]\s+)'),
        '',
      );
    }).toList();

    // Prepend "1. ", "2. ", … to each line.
    return [
      for (int i = 0; i < stripped.length; i++) '${i + 1}. ${stripped[i]}',
    ].join('\n');
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _instructionsCtrl.dispose();
    _ingredientCtrl.dispose();
    _ingredientFocus.dispose();
    for (final c in _ingredientCtrls) {
      c.dispose();
    }
    for (final f in _ingredientFocusNodes) {
      f.dispose();
    }
    super.dispose();
  }

  // ── Ingredient management ────────────────────────────────────────────────────

  void _addIngredient() {
    final text = _ingredientCtrl.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _ingredientCtrls.add(TextEditingController(text: text));
      _ingredientFocusNodes.add(FocusNode());
    });
    _ingredientCtrl.clear();
    _ingredientFocus.requestFocus();
  }

  void _removeIngredient(int index) {
    setState(() {
      _ingredientCtrls[index].dispose();
      _ingredientCtrls.removeAt(index);
      _ingredientFocusNodes[index].dispose();
      _ingredientFocusNodes.removeAt(index);
    });
  }

  // ── Save ────────────────────────────────────────────────────────────────────

  void _save() {
    if (!_formKey.currentState!.validate()) return;

    // Split lines, strip any "1. " / "• " / "- " prefixes the user (or our
    // own _formatInstructions) put there, then trim — so the persisted
    // Recipe.instructions array stays pristine and re-prefixes cleanly the
    // next time the form opens.
    final steps = _instructionsCtrl.text
        .split('\n')
        .map((s) => s.trim().replaceFirst(
              RegExp(r'^(?:\d+[\.\)]\s*|[•\-\*]\s+)'),
              '',
            ))
        .where((s) => s.isNotEmpty)
        .toList();

    if (steps.isEmpty) {
      _showSnack('Add at least one instruction step, chom.');
      return;
    }

    // Snapshot every editable ingredient row's current text. Blank rows are
    // dropped silently — they're just an editing artifact, never persisted.
    final ingredients = _ingredientCtrls
        .map((c) => c.text.trim())
        .where((s) => s.isNotEmpty)
        .map(_parseIngredient)
        .toList();

    final isLoadsheddingFriendly =
        widget.recipe?.isLoadsheddingFriendly ?? false;
    final isBraaiReady = widget.recipe?.isBraaiReady ?? false;

    // Logical-consistency gate — block save if any selected energy tag
    // contradicts the instructions (e.g. "No-Power OK" + "deep fry").
    final conflicts = RecipeTagValidator.validate(
      instructions:           steps,
      isLoadsheddingFriendly: isLoadsheddingFriendly,
      isBraaiReady:           isBraaiReady,
    );
    if (conflicts.isNotEmpty) {
      _showSnack(RecipeTagValidator.formatBanner(conflicts));
      return;
    }

    final recipe = Recipe(
      title:                  _titleCtrl.text.trim(),
      ingredients:            ingredients,
      instructions:           steps,
      isLoadsheddingFriendly: isLoadsheddingFriendly,
      isBraaiReady:           isBraaiReady,
      sourceUrl:              widget.recipe?.sourceUrl,
    );

    Navigator.pop(context, recipe);
  }

  /// Best-effort parse: if the user typed "2 cups flour", split it out.
  /// Otherwise just create an Ingredient with the full string as the name.
  Ingredient _parseIngredient(String raw) {
    // Pattern: optional "number[.number] [unit] name"
    final match = RegExp(
      r'^(\d+(?:\.\d+)?)\s+([a-zA-Z]+)\s+(.+)$',
    ).firstMatch(raw.trim());

    if (match != null) {
      return Ingredient(
        quantity: double.tryParse(match.group(1)!),
        unit:     match.group(2),
        name:     match.group(3)!,
      );
    }
    return Ingredient(name: raw.trim());
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: _kCream,
      appBar: AppBar(
        backgroundColor: _kForest,
        foregroundColor: Colors.white,
        elevation:       0,
        title: Text(
          _isEditing ? 'Edit Recipe' : 'New Recipe',
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: TextButton(
              onPressed: _save,
              child: const Text(
                'Save',
                style: TextStyle(
                  color:      Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize:   15,
                ),
              ),
            ),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
          children: [

            // ── Recipe Title ──────────────────────────────────────────────────
            _SectionLabel(label: 'Recipe Title'),
            const SizedBox(height: 8),
            TextFormField(
              controller:         _titleCtrl,
              textCapitalization: TextCapitalization.words,
              style:              tt.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
              decoration: _inputDecoration(
                hint: 'e.g. Braai-Grid Peri-Peri Chicken',
                icon: Icons.restaurant_menu_rounded,
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty)
                      ? 'Give your recipe a name, chom.'
                      : null,
            ),

            const SizedBox(height: 24),

            // ── Cooking Instructions ──────────────────────────────────────────
            _SectionLabel(label: 'Cooking Instructions'),
            const SizedBox(height: 6),
            Text(
              'One step per line — numbering is added automatically. '
              'Each line you type becomes its own step.',
              style: tt.bodySmall?.copyWith(color: _kMuted, height: 1.4),
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _instructionsCtrl,
              // Tall text block — gives the user real vertical breathing room
              // for scraped recipes that come back with 8–12 steps.
              maxLines:           12,
              minLines:           6,
              keyboardType:       TextInputType.multiline,
              textCapitalization: TextCapitalization.sentences,
              style:              tt.bodyMedium?.copyWith(height: 1.6),
              decoration: _inputDecoration(
                hint: '1. Heat oil in a pan over the fire…\n'
                    '2. Add onions and fry until golden…\n'
                    '3. Season well and serve hot.',
                icon: null,
              ),
            ),

            const SizedBox(height: 28),

            // ── Ingredients / Products ────────────────────────────────────────
            _SectionLabel(label: 'Ingredients / Products'),
            const SizedBox(height: 6),
            Text(
              'Tip: include quantity in the name (e.g., "2 cups flour", "1 tsp salt").',
              style: tt.bodySmall?.copyWith(color: _kMuted, height: 1.4),
            ),
            const SizedBox(height: 10),

            // Input row
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextFormField(
                    controller:         _ingredientCtrl,
                    focusNode:          _ingredientFocus,
                    textCapitalization: TextCapitalization.sentences,
                    textInputAction:    TextInputAction.done,
                    onFieldSubmitted:   (_) => _addIngredient(),
                    style:              tt.bodyMedium,
                    decoration: _inputDecoration(
                      hint: 'e.g. chicken thighs, mealie meal…',
                      icon: Icons.egg_alt_outlined,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton.icon(
                  onPressed: _addIngredient,
                  icon:  const Icon(Icons.add_rounded, size: 18),
                  label: const Text(
                    'Add Product',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: _kForest,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: _kForest.withValues(alpha: 0.55),
                    disabledForegroundColor: Colors.white.withValues(alpha: 0.85),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 16),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 14),

            // Ingredient editable list
            if (_ingredientCtrls.isEmpty)
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                  color:        cs.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(14),
                  border:       Border.all(color: cs.outlineVariant),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline_rounded,
                        size: 16, color: cs.onSurfaceVariant),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'No ingredients added yet.',
                        style: tt.bodySmall?.copyWith(color: _kMuted),
                      ),
                    ),
                  ],
                ),
              )
            else
              Column(
                children: [
                  for (int i = 0; i < _ingredientCtrls.length; i++)
                    _EditableIngredientRow(
                      key:       ValueKey('ing_$i'),
                      index:     i,
                      controller: _ingredientCtrls[i],
                      focusNode:  _ingredientFocusNodes[i],
                      onRemove:  () => _removeIngredient(i),
                      isLast:    i == _ingredientCtrls.length - 1,
                    ),
                ],
              ),

            const SizedBox(height: 36),

            // ── Save button ──────────────────────────────────────────────────
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _save,
                icon:  const Icon(Icons.check_rounded, size: 20),
                label: Text(
                  _isEditing ? 'Update Recipe' : 'Create Recipe',
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize:   16,
                  ),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: _kOrange,
                  minimumSize: const Size.fromHeight(54),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  InputDecoration _inputDecoration({
    required String  hint,
    required IconData? icon,
  }) {
    return InputDecoration(
      hintText:       hint,
      hintStyle:      const TextStyle(color: Color(0xFFADADA7), height: 1.5),
      filled:         true,
      fillColor:      Colors.white,
      prefixIcon:     icon != null
          ? Icon(icon, size: 18, color: _kMuted)
          : null,
      contentPadding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide:   const BorderSide(color: Color(0xFFE6E2D8)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide:   const BorderSide(color: Color(0xFFE6E2D8)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide:   const BorderSide(color: _kForest, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(
            color: Theme.of(context).colorScheme.error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(
            color: Theme.of(context).colorScheme.error, width: 1.5),
      ),
    );
  }
}

// =============================================================================
// _SectionLabel
// =============================================================================

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
        fontWeight:   FontWeight.w800,
        color:        _kForest,
        letterSpacing: 0.2,
      ),
    );
  }
}

// =============================================================================
// _EditableIngredientRow — TextFormField row with index badge + remove button
//
// Each row is a live TextFormField bound to its own TextEditingController, so
// edits update the in-memory list immediately. When the user taps "Update
// Recipe", _save() snapshots every controller's text → parses → returns the
// new Recipe up the Navigator stack. _RecipeDetailScreen then calls
// RecipeRepository.update(), which writes the new `ingredients` jsonb array
// to the Supabase `recipes` row.
// =============================================================================

class _EditableIngredientRow extends StatelessWidget {
  const _EditableIngredientRow({
    super.key,
    required this.index,
    required this.controller,
    required this.focusNode,
    required this.onRemove,
    required this.isLast,
  });

  final int                   index;
  final TextEditingController controller;
  final FocusNode             focusNode;
  final VoidCallback          onRemove;
  final bool                  isLast;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: isLast
              ? BorderSide.none
              : BorderSide(color: cs.outlineVariant.withAlpha(120)),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Index badge
            Container(
              width:  28,
              height: 28,
              decoration: BoxDecoration(
                color:        _kForest.withAlpha(18),
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: Text(
                '${index + 1}',
                style: const TextStyle(
                  color:      _kForest,
                  fontSize:   11,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(width: 12),

            // Editable text field
            Expanded(
              child: TextFormField(
                controller:         controller,
                focusNode:          focusNode,
                textCapitalization: TextCapitalization.sentences,
                textInputAction:    TextInputAction.next,
                style: tt.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                  height:     1.3,
                ),
                decoration: const InputDecoration(
                  isDense:        true,
                  border:         InputBorder.none,
                  enabledBorder:  InputBorder.none,
                  focusedBorder:  InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(vertical: 6),
                  hintText:       'e.g. 2 cups cake wheat flour',
                  hintStyle:      TextStyle(
                    color:    Color(0xFFADADA7),
                    fontSize: 14,
                  ),
                ),
              ),
            ),

            // Remove button
            GestureDetector(
              onTap: onRemove,
              child: Container(
                width:  30,
                height: 30,
                decoration: BoxDecoration(
                  color:        cs.errorContainer.withAlpha(180),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.close_rounded,
                  size:  15,
                  color: cs.onErrorContainer,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
