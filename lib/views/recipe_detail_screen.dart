// lib/views/recipe_detail_screen.dart
//
// Dual-mode recipe viewer:
//   • Active Cooking Mode  — vertical timeline with tappable step checkboxes
//   • Blueprint Edit Mode  — every step becomes an editable TextField; steps
//     can be added, reordered (drag), and deleted; changes are persisted via
//     SharedPreferences so the user's custom version survives app restarts.
//
// Usage:
//   Navigator.push(
//     context,
//     MaterialPageRoute(
//       builder: (_) => RecipeDetailScreen(
//         recipe: myRecipe,
//         onAddToShoppingList: (items) { … },
//       ),
//     ),
//   );

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart' hide ShareResult;
import '../models/ingredient.dart';
import '../models/recipe.dart';
import '../utils/measurement_format.dart';
import '../models/shopping_list.dart';
import '../services/recipe_repository.dart';
import '../services/recipe_share_service.dart';
import 'recipe_to_shopping_sheet.dart';

// =============================================================================
// Design tokens — shared with the rest of ChowSA
// =============================================================================

const _kForest  = Color(0xFF0C351E);
const _kOrange  = Color(0xFFE59B27);
const _kCream   = Color(0xFFF4F1EA);
const _kMuted   = Color(0xFF55534E);
const _kDivider = Color(0xFFE6E2D8);

// =============================================================================
// RecipeDetailScreen
// =============================================================================

class RecipeDetailScreen extends StatefulWidget {
  const RecipeDetailScreen({
    super.key,
    required this.recipe,
    this.onAddToShoppingList,
    this.pantryItems   = const [],
    this.initiallySaved = false,
  });

  final Recipe recipe;
  final void Function(List<ShoppingItem>)? onAddToShoppingList;
  /// Set by callers that have already persisted [recipe] into My Recipes
  /// before pushing this screen (e.g. the inbox auto-save path). When
  /// true the in-screen "Save to My Recipes" CTA boots in the "Saved ✓"
  /// state so the user can't fire a duplicate insert.
  final bool initiallySaved;
  /// Current pantry contents — any recipe ingredient NOT matched here is
  /// classified as "missing" and gets an amber accent + inline add-to-list icon.
  final List<String> pantryItems;

  @override
  State<RecipeDetailScreen> createState() => _RecipeDetailScreenState();
}

enum _ViewMode { cooking, editing }

class _RecipeDetailScreenState extends State<RecipeDetailScreen>
    with SingleTickerProviderStateMixin {

  // ── Mode ────────────────────────────────────────────────────────────────────
  _ViewMode _mode = _ViewMode.cooking;

  // ── Cooking state ────────────────────────────────────────────────────────────
  final Set<int> _doneIngredients = {};
  final Set<int> _doneSteps       = {};

  // ── Edit state ───────────────────────────────────────────────────────────────
  // Working copy of instructions; starts as a clone of the recipe's list.
  // Initialised eagerly in initState so the first build() before the async
  // _loadPersistedData() completes can read .isNotEmpty / .length without
  // throwing a LateInitializationError (Crashlytics #1716237f).
  List<String> _editedSteps = const <String>[];
  // One controller per step row.
  final List<TextEditingController> _stepControllers = [];

  // ── Chef's notes ─────────────────────────────────────────────────────────────
  final TextEditingController _notes = TextEditingController();
  SharedPreferences? _prefs;

  // ── Mode-switch animation ────────────────────────────────────────────────────
  late final AnimationController _modeAnim;
  late final Animation<double>   _modeOpacity;

  // ── Persistence keys ─────────────────────────────────────────────────────────
  String get _notesKey => 'chef_notes_${widget.recipe.title.hashCode}';
  String get _stepsKey => 'edited_steps_${widget.recipe.title.hashCode}';

  // ── Unsaved-changes flag ──────────────────────────────────────────────────────
  bool _hasUnsaved = false;

  @override
  void initState() {
    super.initState();

    _modeAnim = AnimationController(
      vsync:    this,
      duration: const Duration(milliseconds: 260),
    );
    _modeOpacity = CurvedAnimation(parent: _modeAnim, curve: Curves.easeInOut);
    _modeAnim.value = 1.0;

    // Seed _editedSteps from the recipe synchronously so the first frame
    // — which runs before _loadPersistedData() resolves — has a populated
    // list to render.
    _editedSteps = List<String>.from(widget.recipe.instructions);
    _rebuildControllers();

    _loadPersistedData();
  }

  @override
  void dispose() {
    _modeAnim.dispose();
    _notes.dispose();
    for (final c in _stepControllers) {
      c.dispose();
    }
    super.dispose();
  }

  // ── Persistence ──────────────────────────────────────────────────────────────

  Future<void> _loadPersistedData() async {
    _prefs = await SharedPreferences.getInstance();

    // Chef's notes
    final savedNotes = _prefs?.getString(_notesKey);

    // Custom steps (stored as a JSON array of strings)
    final savedStepsJson = _prefs?.getString(_stepsKey);
    List<String> steps;
    if (savedStepsJson != null) {
      steps = List<String>.from(jsonDecode(savedStepsJson) as List);
    } else {
      steps = List<String>.from(widget.recipe.instructions);
    }

    if (mounted) {
      setState(() {
        if (savedNotes != null) _notes.text = savedNotes;
        _editedSteps = steps;
        _rebuildControllers();
      });
    }
  }

  Future<void> _saveNotes() async {
    await _prefs?.setString(_notesKey, _notes.text);
  }

  Future<void> _saveSteps() async {
    await _prefs?.setString(_stepsKey, jsonEncode(_editedSteps));
  }

  // Sync controller list to _editedSteps length.
  void _rebuildControllers() {
    for (final c in _stepControllers) {
      c.dispose();
    }
    _stepControllers
      ..clear()
      ..addAll(_editedSteps.map((s) => TextEditingController(text: s)));
  }

  // ── Save to My Recipes ───────────────────────────────────────────────────────

  late bool _savedToLibrary = widget.initiallySaved;
  bool _saving         = false;

  Future<void> _saveToMyRecipes() async {
    if (_saving || _savedToLibrary) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = true);
    try {
      await RecipeRepository.instance.insert(
        widget.recipe,
        source: 'detail-screen',
      );
      if (!mounted) return;
      setState(() {
        _saving         = false;
        _savedToLibrary = true;
      });
      messenger.showSnackBar(SnackBar(
        content:  Text('"${widget.recipe.title}" saved to My Recipes 📖'),
        behavior: SnackBarBehavior.floating,
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      messenger.showSnackBar(SnackBar(
        content:  Text('Could not save: $e'),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  // ── Mode switching ────────────────────────────────────────────────────────────

  Future<void> _enterEditMode() async {
    // Sync _editedSteps from any persisted changes so controllers are fresh.
    _rebuildControllers();
    await _modeAnim.reverse();
    if (mounted) setState(() => _mode = _ViewMode.editing);
    await _modeAnim.forward();
  }

  Future<void> _discardEdits() async {
    if (_hasUnsaved) {
      final confirmed = await _showDiscardDialog();
      if (!confirmed) return;
    }
    await _modeAnim.reverse();
    if (mounted) {
      setState(() {
        _mode       = _ViewMode.cooking;
        _hasUnsaved = false;
        // Reset to last persisted state
        _loadPersistedData();
      });
    }
    await _modeAnim.forward();
  }

  Future<bool> _showDiscardDialog() async {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: const Text(
              'Discard changes?',
              style: TextStyle(fontWeight: FontWeight.w800, color: _kForest),
            ),
            content: const Text(
              "Your edits haven't been saved yet. They'll be lost if you go back.",
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Keep editing'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: FilledButton.styleFrom(backgroundColor: _kOrange),
                child: const Text('Discard'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _saveChanges() async {
    FocusScope.of(context).unfocus();
    // Flush any in-progress controller text into the list.
    for (var i = 0; i < _stepControllers.length; i++) {
      _editedSteps[i] = _stepControllers[i].text.trim();
    }
    // Drop blank steps silently.
    _editedSteps.removeWhere((s) => s.isEmpty);
    await _saveSteps();

    await _modeAnim.reverse();
    if (mounted) {
      setState(() {
        _mode       = _ViewMode.cooking;
        _hasUnsaved = false;
        _rebuildControllers();
      });
    }
    await _modeAnim.forward();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Row(
            children: [
              Icon(Icons.check_circle_rounded, color: Colors.white, size: 18),
              SizedBox(width: 10),
              Text('Blueprint saved!', style: TextStyle(fontWeight: FontWeight.w700)),
            ],
          ),
          backgroundColor: _kForest,
          behavior:        SnackBarBehavior.floating,
          shape:           RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
    }
  }

  // ── Edit actions ─────────────────────────────────────────────────────────────

  void _addStep() {
    setState(() {
      _editedSteps.add('');
      _stepControllers.add(TextEditingController());
      _hasUnsaved = true;
    });
    // Scroll to bottom after frame to land on the new field.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 350),
          curve:    Curves.easeOut,
        );
      }
      // Auto-focus the new field.
      if (_stepControllers.isNotEmpty) {
        FocusScope.of(context).requestFocus(_stepFocusNodes.last);
      }
    });
  }

  void _removeStep(int index) {
    setState(() {
      _editedSteps.removeAt(index);
      _stepControllers[index].dispose();
      _stepControllers.removeAt(index);
      _stepFocusNodes[index].dispose();
      _stepFocusNodes.removeAt(index);
      _hasUnsaved = true;
    });
  }

  void _reorderStep(int oldIndex, int newIndex) {
    setState(() {
      if (newIndex > oldIndex) newIndex -= 1;
      final step       = _editedSteps.removeAt(oldIndex);
      final controller = _stepControllers.removeAt(oldIndex);
      final focus      = _stepFocusNodes.removeAt(oldIndex);
      _editedSteps.insert(newIndex, step);
      _stepControllers.insert(newIndex, controller);
      _stepFocusNodes.insert(newIndex, focus);
      _hasUnsaved = true;
    });
  }

  // ── Missing-ingredient classifier ──────────────────────────────────────────
  // An ingredient is "missing" if none of the user's pantry items contains its
  // name (case-insensitive substring match — handles "chicken thighs" vs
  // "chicken" in the pantry).

  bool _isMissing(Ingredient ing) {
    if (widget.pantryItems.isEmpty) return false;
    final needle = ing.name.toLowerCase().trim();
    if (needle.isEmpty) return false;
    return !widget.pantryItems.any((p) {
      final hay = p.toLowerCase().trim();
      return hay.contains(needle) || needle.contains(hay);
    });
  }

  // ── Cooking actions ───────────────────────────────────────────────────────────

  void _toggleIngredient(int i) => setState(() =>
      _doneIngredients.contains(i)
          ? _doneIngredients.remove(i)
          : _doneIngredients.add(i));

  void _toggleStep(int i) => setState(() =>
      _doneSteps.contains(i) ? _doneSteps.remove(i) : _doneSteps.add(i));


  // ── Scroll + focus management ─────────────────────────────────────────────────
  final _scrollController = ScrollController();
  // One focus node per step (created lazily via getter).
  final List<FocusNode> _stepFocusNodes = [];

  FocusNode _focusFor(int index) {
    while (_stepFocusNodes.length <= index) {
      _stepFocusNodes.add(FocusNode());
    }
    return _stepFocusNodes[index];
  }

  // ── "Fill the Gap" — copy missing ingredients to clipboard ───────────────────
  //
  // Compiles every recipe ingredient that is NOT already in the user's pantry
  // into a clean bulleted list and copies it to the device clipboard so they
  // can paste directly into Checkers Sixty60, Pick n Pay Asap, or any delivery
  // app. A contextual toast confirms the copy with the Sixty60/Asap CTA.

  /// Returns the list of ingredients the user still needs to buy.
  List<Ingredient> get _missingIngredients => [
    for (final ing in widget.recipe.ingredients)
      if (_isMissing(ing)) ing,
  ];

  void _copyMissingToClipboard() {
    final missing = _missingIngredients;
    if (missing.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            '🎉 You already have everything! No items to copy.',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          behavior:  SnackBarBehavior.floating,
          shape:     RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12)),
          duration:  const Duration(seconds: 3),
        ),
      );
      return;
    }

    // ── Build the bulleted text block ────────────────────────────────────────
    final buf = StringBuffer();
    buf.writeln('🛒 Missing ingredients for "${widget.recipe.title}":');
    buf.writeln();
    for (final ing in missing) {
      buf.writeln('• ${formatIngredientLine(ing)}');
    }
    buf.writeln();
    buf.writeln('— Copied via ChowSA 🇿🇦');

    Clipboard.setData(ClipboardData(text: buf.toString()));

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Text('🛒', style: TextStyle(fontSize: 18)),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                'Copied! Ready to paste into Sixty60 or PnP Asap! 💨',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize:   13,
                ),
              ),
            ),
          ],
        ),
        backgroundColor: _kForest,
        behavior:        SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  // ── Share menu ─────────────────────────────────────────────────────────────
  //
  // Two distinct routes:
  //
  //   Route A (External): hand the recipe text to the device's native share
  //     sheet via share_plus — WhatsApp, Email, Messages, etc.
  //
  //   Route B (Internal): insert a fully-formed copy of the recipe into the
  //     Supabase `whats_cooking_posts` table so it surfaces on the Community
  //     feed without leaving the app. RLS is expected to enforce user_id =
  //     auth.uid() on insert.
  //
  // The button in _TopBar now opens this chooser sheet instead of jumping
  // straight to the external share.

  Future<void> _openShareMenu() async {
    final action = await showModalBottomSheet<_ShareAction>(
      context: context,
      backgroundColor: _kCream,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => _ShareMenuSheet(recipeTitle: widget.recipe.title),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case _ShareAction.external:
        await _exportRecipe();
        break;
      case _ShareAction.community:
        await _publishToCommunity();
        break;
    }
  }

  // ── Route B: publish to the Community feed ─────────────────────────────────
  //
  // Inserts a single row into `whats_cooking_posts`. The payload carries:
  //
  //   • user_id        — auth.uid() (RLS gate)
  //   • recipe_title   — recipe title
  //   • caption        — first instruction step OR a default tagline
  //   • body           — full formatted recipe text (same shape as export)
  //   • ingredients    — jsonb array, parallel to recipes.ingredients
  //   • instructions   — jsonb array of step strings
  //   • source_url     — original scrape URL when present
  //   • is_loadshedding_friendly / is_braai_ready — copied flags
  //
  // The columns are best-effort: PostgREST silently ignores keys it doesn't
  // recognise as long as required columns are present, but if your schema
  // omits one of these you can prune the payload in one place.

  Future<void> _publishToCommunity() async {
    // Route through the canonical share service rather than a hand-rolled
    // insert. The previous inline write targeted a phantom
    // `whats_cooking_posts` table (PGRST205) and omitted the author
    // identity columns the feed card needs. The service owns the correct
    // write path: a public `shared_recipes` snapshot + the cooking-channel
    // message carrying the [shared_recipe:<id>] tap target.
    //
    // Carry any cooking-mode step edits/reorders into the shared copy by
    // rebuilding the Recipe with `_editedSteps` when present.
    final r     = widget.recipe;
    final steps = _editedSteps.isNotEmpty ? _editedSteps : r.instructions;
    final shareRecipe = Recipe(
      title:                  r.title,
      ingredients:            r.ingredients,
      instructions:           steps,
      isLoadsheddingFriendly: r.isLoadsheddingFriendly,
      isBraaiReady:           r.isBraaiReady,
      sourceUrl:              r.sourceUrl,
    );

    final result = await RecipeShareService.instance
        .shareToWhatsCooking(recipe: shareRecipe);
    if (!mounted) return;

    switch (result) {
      case ShareResult.communitySuccess:
        _showCommunitySnack('Posted to the community feed! 🔥');
      case ShareResult.notSignedIn:
        _showCommunitySnack(
          'Sign in to publish to the community feed.',
          isError: true,
        );
      case ShareResult.channelNotFound:
        _showCommunitySnack(
          "Couldn't find your local What's Cooking channel yet. Try again "
          'once your community hub has loaded.',
          isError: true,
        );
      case ShareResult.communityError:
        _showCommunitySnack(
          'Could not publish to the feed. Check your connection and retry.',
          isError: true,
        );
      case ShareResult.systemShareInvoked:
        // Not reachable from this route — shareToWhatsCooking never returns it.
        break;
    }
  }

  void _showCommunitySnack(String msg, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content:         Text(msg, style: const TextStyle(fontWeight: FontWeight.w700)),
        backgroundColor: isError ? const Color(0xFFC62828) : _kForest,
        behavior:        SnackBarBehavior.floating,
        shape:           RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  // Plain-text body shared with both the external share path and the
  // community feed insert — keeps the two routes formatting-identical.
  String _formatRecipeText(List<String> steps) {
    final r   = widget.recipe;
    final buf = StringBuffer();
    buf.writeln('🔥 ${r.title}');
    buf.writeln();
    if (r.ingredients.isNotEmpty) {
      buf.writeln('── INGREDIENTS ──────────────────────────');
      for (final ing in r.ingredients) {
        buf.writeln('• ${formatIngredientLine(ing)}');
      }
      buf.writeln();
    }
    if (steps.isNotEmpty) {
      buf.writeln('── METHOD ───────────────────────────────');
      for (var i = 0; i < steps.length; i++) {
        buf.writeln('${i + 1}. ${steps[i]}');
        buf.writeln();
      }
    }
    if (_notes.text.trim().isNotEmpty) {
      buf.writeln("── CHEF'S NOTES ──────────────────────────");
      buf.writeln(_notes.text.trim());
      buf.writeln();
    }
    buf.writeln('────────────────────────────────────────');
    buf.writeln('Shared via ChowSA 🇿🇦  •  chowsa.app');
    return buf.toString();
  }

  // ── Export / Share recipe as formatted text ───────────────────────────────

  Future<void> _exportRecipe() async {
    final steps = _editedSteps.isNotEmpty
        ? _editedSteps
        : widget.recipe.instructions;
    await Share.share(
      _formatRecipeText(steps),
      subject: '${widget.recipe.title} — ChowSA Recipe',
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final tt  = Theme.of(context).textTheme;
    final cs  = Theme.of(context).colorScheme;
    final top = MediaQuery.of(context).padding.top;

    return Scaffold(
      backgroundColor: _kCream,
      body: Column(
        children: [

          // ── Sticky top bar ──────────────────────────────────────────────────
          _TopBar(
            recipe:   widget.recipe,
            mode:     _mode,
            top:      top,
            hasUnsaved: _hasUnsaved,
            onBack:     () async {
              if (_mode == _ViewMode.editing) {
                await _discardEdits();
              } else {
                Navigator.of(context).pop();
              }
            },
            onEdit:     _mode == _ViewMode.cooking ? _enterEditMode : null,
            onSave:     _mode == _ViewMode.editing ? _saveChanges  : null,
            onDiscard:  _mode == _ViewMode.editing ? _discardEdits : null,
            onExport:   _mode == _ViewMode.cooking ? _openShareMenu : null,
            onSaveToLibrary:
                _mode == _ViewMode.cooking ? _saveToMyRecipes : null,
            savedToLibrary: _savedToLibrary,
            savingToLibrary: _saving,
          ),

          // ── Scrollable content ──────────────────────────────────────────────
          Expanded(
            child: FadeTransition(
              opacity: _modeOpacity,
              child: _mode == _ViewMode.cooking
                  ? _buildCookingBody(tt, cs)
                  : _buildEditBody(tt, cs),
            ),
          ),
        ],
      ),
    );
  }

  // ── Cooking body ──────────────────────────────────────────────────────────────

  Widget _buildCookingBody(TextTheme tt, ColorScheme cs) {
    // Use _editedSteps (user's saved custom version) for the cooking display.
    final steps = _editedSteps.isNotEmpty
        ? _editedSteps
        : widget.recipe.instructions;

    return ListView(
      controller: _scrollController,
      padding:    const EdgeInsets.fromLTRB(20, 24, 20, 48),
      children: [

        // ── Source link ───────────────────────────────────────────────────────
        if (widget.recipe.sourceUrl != null) ...[
          _SourceChip(url: widget.recipe.sourceUrl!),
          const SizedBox(height: 20),
        ],

        // ── Loadshedding badge ─────────────────────────────────────────────────
        _LoadsheddingBanner(friendly: widget.recipe.isLoadsheddingFriendly),
        const SizedBox(height: 28),

        // ── Ingredients section ───────────────────────────────────────────────
        _SectionHeader(
          icon:  Icons.egg_alt_outlined,
          label: 'Ingredients',
          count: widget.recipe.ingredients.length,
          trailing: _SmallChipButton(
            icon:  Icons.shopping_cart_outlined,
            label: 'Add to list',
            onTap: () => showRecipeToShoppingSheet(
              context: context,
              recipe:  widget.recipe,
            ),
          ),
        ),
        const SizedBox(height: 12),

        ...List.generate(widget.recipe.ingredients.length, (i) =>
            _CookingIngredientRow(
              ingredient: widget.recipe.ingredients[i],
              done:       _doneIngredients.contains(i),
              missing:    _isMissing(widget.recipe.ingredients[i]),
              onTap:      () => _toggleIngredient(i),
              onAddToList: () => showSingleIngredientPopup(
                context:    context,
                ingredient: widget.recipe.ingredients[i],
              ),
            )),

        // ── Fill the Gap button ───────────────────────────────────────────────
        // Shown only when there are missing ingredients so the button is always
        // contextually relevant — never visible when the pantry already covers
        // the full recipe.
        if (_missingIngredients.isNotEmpty) ...[
          const SizedBox(height: 16),
          _FillTheGapButton(
            missingCount: _missingIngredients.length,
            onTap:        _copyMissingToClipboard,
          ),
        ],

        const SizedBox(height: 32),
        const _Divider(),
        const SizedBox(height: 28),

        // ── Instructions timeline ─────────────────────────────────────────────
        _SectionHeader(
          icon:  Icons.menu_book_outlined,
          label: 'Instructions',
          count: steps.length,
          trailing: _doneSteps.isNotEmpty
              ? _SmallChipButton(
                  icon:  Icons.refresh_rounded,
                  label: 'Reset',
                  onTap: () => setState(() => _doneSteps.clear()),
                )
              : null,
        ),
        const SizedBox(height: 16),

        // Timeline
        ...List.generate(steps.length, (i) => _TimelineStepRow(
          index:    i,
          total:    steps.length,
          text:     steps[i],
          done:     _doneSteps.contains(i),
          onTap:    () => _toggleStep(i),
        )),

        const SizedBox(height: 32),
        const _Divider(),
        const SizedBox(height: 24),

        // ── Progress bar ──────────────────────────────────────────────────────
        _ProgressCard(
          doneSteps:  _doneSteps.length,
          totalSteps: steps.length,
        ),

        const SizedBox(height: 28),
        const _Divider(),
        const SizedBox(height: 24),

        // ── Chef's Notes ──────────────────────────────────────────────────────
        _SectionHeader(icon: Icons.edit_note_rounded, label: "Chef's Notes"),
        const SizedBox(height: 12),
        _NotesField(controller: _notes, onChanged: (_) => _saveNotes()),

        const SizedBox(height: 8),
      ],
    );
  }

  // ── Edit body ─────────────────────────────────────────────────────────────────

  Widget _buildEditBody(TextTheme tt, ColorScheme cs) {
    return Column(
      children: [
        // Edit-mode callout banner
        _EditBanner(stepCount: _editedSteps.length, hasUnsaved: _hasUnsaved),

        Expanded(
          child: ReorderableListView.builder(
            scrollController: _scrollController,
            padding:          const EdgeInsets.fromLTRB(20, 12, 20, 20),
            itemCount:        _editedSteps.length,
            onReorder:        _reorderStep,
            proxyDecorator:   _proxyDecorator,
            itemBuilder:      (ctx, i) => _EditStepRow(
              key:        ValueKey('step_$i\_${_editedSteps[i].hashCode}'),
              index:      i,
              controller: _stepControllers[i],
              focusNode:  _focusFor(i),
              onDelete:   _editedSteps.length > 1
                  ? () => _removeStep(i)
                  : null,
              onChanged:  (v) => setState(() {
                _editedSteps[i] = v;
                _hasUnsaved     = true;
              }),
            ),
            footer: Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 32),
              child: _AddStepButton(onTap: _addStep),
            ),
          ),
        ),
      ],
    );
  }

  // Floating drag proxy — slightly scaled + shadowed card.
  Widget _proxyDecorator(Widget child, int index, Animation<double> anim) {
    return AnimatedBuilder(
      animation: anim,
      builder: (ctx, _) {
        final elevation = Tween<double>(begin: 0, end: 8).evaluate(anim);
        return Material(
          elevation:    elevation,
          color: null,
          borderRadius: BorderRadius.circular(18),
          child:        child,
        );
      },
      child: child,
    );
  }
}

// =============================================================================
// _TopBar — sticky header with mode-aware action buttons
// =============================================================================

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.recipe,
    required this.mode,
    required this.top,
    required this.hasUnsaved,
    required this.onBack,
    required this.onEdit,
    required this.onSave,
    required this.onDiscard,
    this.onExport,
    this.onSaveToLibrary,
    this.savedToLibrary  = false,
    this.savingToLibrary = false,
  });

  final Recipe    recipe;
  final _ViewMode mode;
  final double    top;
  final bool      hasUnsaved;
  final VoidCallback                 onBack;
  final VoidCallback?                onEdit;
  final Future<void> Function()?    onSave;
  final Future<void> Function()?    onDiscard;
  final VoidCallback?                onExport;
  final VoidCallback?                onSaveToLibrary;
  final bool                         savedToLibrary;
  final bool                         savingToLibrary;

  @override
  Widget build(BuildContext context) {
    final isCooking = mode == _ViewMode.cooking;

    return Container(
      color: _kCream,
      padding: EdgeInsets.only(
        top:    top + 8,
        bottom: 12,
        left:   8,
        right:  16,
      ),
      child: Row(
        children: [

          // Back / Discard
          IconButton(
            icon: Icon(
              isCooking
                  ? Icons.arrow_back_ios_new_rounded
                  : Icons.close_rounded,
              size: 22,
            ),
            color:    _kForest,
            onPressed: onBack,
            tooltip:  isCooking ? 'Back' : 'Discard',
          ),

          const SizedBox(width: 4),

          // Title
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  recipe.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize:   17,
                    fontWeight: FontWeight.w800,
                    color:      _kForest,
                    height:     1.2,
                  ),
                ),
                const SizedBox(height: 2),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: isCooking
                      ? _ModeChip(
                          key:    const ValueKey('cook'),
                          label:  'Active Cooking Mode',
                          icon:   Icons.local_fire_department_rounded,
                          color:  _kOrange,
                        )
                      : _ModeChip(
                          key:    const ValueKey('edit'),
                          label:  'Blueprint Edit Mode',
                          icon:   Icons.edit_rounded,
                          color:  _kForest,
                        ),
                ),
              ],
            ),
          ),

          const SizedBox(width: 8),

          // Right-side action(s)
          // Share/export button — always visible in cooking mode
          if (isCooking && onExport != null)
            IconButton(
              icon: const Icon(Icons.ios_share_rounded, size: 20),
              color: _kForest,
              onPressed: onExport,
              tooltip: 'Share recipe',
            ),
          // Save-to-library — adds the recipe to My Recipes. Flips to a
          // green check + disabled state once persisted.
          if (isCooking && onSaveToLibrary != null) ...[
            IconButton(
              icon: savingToLibrary
                  ? const SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      savedToLibrary
                          ? Icons.bookmark_rounded
                          : Icons.bookmark_add_outlined,
                      size: 22,
                    ),
              color:   savedToLibrary ? const Color(0xFF1B7A3E) : _kForest,
              onPressed:
                  (savingToLibrary || savedToLibrary) ? null : onSaveToLibrary,
              tooltip: savedToLibrary ? 'Saved' : 'Save to My Recipes',
            ),
            const SizedBox(width: 4),
          ],
          if (isCooking && onEdit != null)
            _ActionButton(
              label:   'Edit',
              icon:    Icons.edit_rounded,
              onTap:   onEdit!,
              bgColor: _kForest,
            )
          else if (!isCooking) ...[
            if (hasUnsaved)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _UnsavedDot(),
              ),
            _ActionButton(
              label:   'Save',
              icon:    Icons.check_rounded,
              onTap:   onSave ?? () {},
              bgColor: _kOrange,
            ),
          ],
        ],
      ),
    );
  }
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({
    super.key,
    required this.label,
    required this.icon,
    required this.color,
  });

  final String  label;
  final IconData icon;
  final Color   color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 11, color: color),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            fontSize:      11,
            fontWeight:    FontWeight.w700,
            color:         color,
            letterSpacing: 0.2,
          ),
        ),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.icon,
    required this.onTap,
    required this.bgColor,
  });

  final String     label;
  final IconData   icon;
  final VoidCallback onTap;
  final Color      bgColor;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding:    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color:        bgColor,
          borderRadius: BorderRadius.circular(22),
          boxShadow: [
            BoxShadow(
              color:      bgColor.withAlpha(80),
              blurRadius: 12,
              offset:     const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 15),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(
                color:      Colors.white,
                fontWeight: FontWeight.w800,
                fontSize:   13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _UnsavedDot extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width:  8,
      height: 8,
      decoration: const BoxDecoration(
        color: _kOrange,
        shape: BoxShape.circle,
      ),
    );
  }
}

// =============================================================================
// _EditBanner — contextual hint shown at the top of edit mode
// =============================================================================

class _EditBanner extends StatelessWidget {
  const _EditBanner({required this.stepCount, required this.hasUnsaved});

  final int  stepCount;
  final bool hasUnsaved;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin:  const EdgeInsets.fromLTRB(20, 8, 20, 4),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color:        const Color(0xFF0C351E).withAlpha(12),
        borderRadius: BorderRadius.circular(16),
        border:       Border.all(color: _kForest.withAlpha(40)),
      ),
      child: Row(
        children: [
          const Icon(Icons.drag_indicator_rounded, size: 16, color: _kForest),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              hasUnsaved
                  ? 'Unsaved changes  •  $stepCount step${stepCount == 1 ? '' : 's'}'
                  : 'Drag to reorder  •  Tap text to edit  •  $stepCount step${stepCount == 1 ? '' : 's'}',
              style: const TextStyle(
                fontSize:   12,
                fontWeight: FontWeight.w600,
                color:      _kForest,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// _EditStepRow — one editable step inside ReorderableListView
// =============================================================================

class _EditStepRow extends StatefulWidget {
  const _EditStepRow({
    super.key,
    required this.index,
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onDelete,
  });

  final int                    index;
  final TextEditingController  controller;
  final FocusNode              focusNode;
  final ValueChanged<String>   onChanged;
  final VoidCallback?          onDelete;

  @override
  State<_EditStepRow> createState() => _EditStepRowState();
}

class _EditStepRowState extends State<_EditStepRow> {
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_onFocusChange);
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocusChange);
    super.dispose();
  }

  void _onFocusChange() =>
      setState(() => _focused = widget.focusNode.hasFocus);

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          color:        Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: _focused ? _kForest : _kDivider,
            width: _focused ? 1.5 : 1.0,
          ),
          boxShadow: [
            BoxShadow(
              color:      _focused
                  ? _kForest.withAlpha(20)
                  : Colors.black.withAlpha(6),
              blurRadius: _focused ? 12 : 4,
              offset:     const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [

            // Drag handle + step number
            Padding(
              padding: const EdgeInsets.only(top: 14, left: 14),
              child: Column(
                children: [
                  ReorderableDragStartListener(
                    index: widget.index,
                    child: const Icon(
                      Icons.drag_indicator_rounded,
                      color: _kMuted,
                      size:  20,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    width:  24,
                    height: 24,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color:        _focused ? _kForest : const Color(0xFFEDE9E3),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '${widget.index + 1}',
                      style: TextStyle(
                        fontSize:   11,
                        fontWeight: FontWeight.w800,
                        color:      _focused ? Colors.white : _kMuted,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(width: 12),

            // Editable text
            Expanded(
              child: TextField(
                controller:  widget.controller,
                focusNode:   widget.focusNode,
                onChanged:   widget.onChanged,
                maxLines:    null,
                minLines:    2,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                style: tt.bodyMedium?.copyWith(height: 1.55),
                decoration: const InputDecoration(
                  hintText:       'Describe this step…',
                  border:         InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(vertical: 16),
                ),
              ),
            ),

            // Delete button
            if (widget.onDelete != null)
              Padding(
                padding: const EdgeInsets.only(top: 8, right: 6),
                child: IconButton(
                  icon:    const Icon(Icons.delete_outline_rounded, size: 20),
                  color:   Colors.red.shade300,
                  tooltip: 'Remove step',
                  onPressed: widget.onDelete,
                  style: IconButton.styleFrom(
                    minimumSize:   const Size(36, 36),
                    padding:       EdgeInsets.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              )
            else
              const SizedBox(width: 16),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// _AddStepButton
// =============================================================================

class _AddStepButton extends StatelessWidget {
  const _AddStepButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding:    const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color:        Colors.white,
          borderRadius: BorderRadius.circular(18),
          border:       Border.all(
            color: _kOrange.withAlpha(100),
            width: 1.5,
            // Dashed borders aren't natively supported, so we use a solid
            // tinted line instead — consistent with the ChowSA palette.
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: const [
            Icon(Icons.add_circle_rounded, color: _kOrange, size: 20),
            SizedBox(width: 8),
            Text(
              '+ Add Step',
              style: TextStyle(
                color:      _kOrange,
                fontWeight: FontWeight.w800,
                fontSize:   14,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// _TimelineStepRow — cooking mode vertical timeline item
// =============================================================================

class _TimelineStepRow extends StatelessWidget {
  const _TimelineStepRow({
    required this.index,
    required this.total,
    required this.text,
    required this.done,
    required this.onTap,
  });

  final int    index;
  final int    total;
  final String text;
  final bool   done;
  final VoidCallback onTap;

  bool get _isLast => index == total - 1;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [

          // ── Timeline spine ─────────────────────────────────────────────────
          SizedBox(
            width: 42,
            child: Column(
              children: [
                // Circle node
                GestureDetector(
                  onTap: onTap,
                  child: AnimatedContainer(
                    // easeOutBack overshoots its end value as it animates,
                    // which is fine when checking a step (forward bounce)
                    // but on UNCHECK the same overshoot pushes the circle
                    // past its rest size and briefly distorts the row's
                    // IntrinsicHeight → produces the split-second downward
                    // "shoot" reported on 44390. easeOutCubic stays inside
                    // the [start,end] interval on both directions, so the
                    // reverse transition stays clean.
                    duration: const Duration(milliseconds: 250),
                    curve:    Curves.easeOutCubic,
                    width:    32,
                    height:   32,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: done ? _kForest : Colors.white,
                      border: Border.all(
                        color: done ? _kForest : _kDivider,
                        width: done ? 0 : 2,
                      ),
                      boxShadow: done
                          ? [
                              BoxShadow(
                                color:      _kForest.withAlpha(50),
                                blurRadius: 10,
                                offset:     const Offset(0, 3),
                              ),
                            ]
                          : [],
                    ),
                    child: Center(
                      child: done
                          ? const Icon(
                              Icons.check_rounded,
                              color: Colors.white,
                              size:  16,
                            )
                          : Text(
                              '${index + 1}',
                              style: const TextStyle(
                                fontSize:   12,
                                fontWeight: FontWeight.w800,
                                color:      _kMuted,
                              ),
                            ),
                    ),
                  ),
                ),
                // Connector line
                if (!_isLast)
                  Expanded(
                    child: Center(
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
                        width:    2,
                        color:    done ? _kForest.withAlpha(60) : _kDivider,
                      ),
                    ),
                  ),
              ],
            ),
          ),

          // ── Step text ──────────────────────────────────────────────────────
          Expanded(
            child: GestureDetector(
              onTap: onTap,
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: EdgeInsets.only(
                  left:   12,
                  bottom: _isLast ? 0 : 20,
                  top:    4,
                ),
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 220),
                  opacity:  done ? 0.38 : 1.0,
                  child: Text(
                    text,
                    style: tt.bodyMedium?.copyWith(
                      height:          1.6,
                      decoration:      done
                          ? TextDecoration.lineThrough
                          : TextDecoration.none,
                      decorationColor: _kForest,
                      decorationThickness: 1.5,
                    ),
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
// _CookingIngredientRow — tappable ingredient with check-off
// =============================================================================

class _CookingIngredientRow extends StatelessWidget {
  const _CookingIngredientRow({
    required this.ingredient,
    required this.done,
    required this.onTap,
    this.missing      = false,
    this.onAddToList,
  });

  final Ingredient    ingredient;
  final bool          done;
  final bool          missing;
  final VoidCallback  onTap;
  final VoidCallback? onAddToList;

  // Amber tokens (local — keep the row self-contained).
  static const _amberFg = Color(0xFFB45309);

  String get _qtyLabel => formatIngredientMeasure(ingredient);

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;

    return InkWell(
      onTap:        onTap,
      borderRadius: BorderRadius.circular(12),
      child: AnimatedOpacity(
        opacity:  done ? 0.38 : 1.0,
        duration: const Duration(milliseconds: 220),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          child: Row(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                width:    22,
                height:   22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color:  done ? _kForest : Colors.transparent,
                  border: Border.all(
                    color: done ? _kForest : _kDivider,
                    width: 1.5,
                  ),
                ),
                child: done
                    ? const Icon(Icons.check_rounded, color: Colors.white, size: 13)
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        ingredient.displayName,
                        style: tt.bodyMedium?.copyWith(
                          fontWeight:  FontWeight.w600,
                          // Missing items render in amber + italic for clear
                          // visual differentiation from pantry-matched items.
                          color:       missing && !done ? _amberFg : null,
                          fontStyle:   missing && !done
                              ? FontStyle.italic
                              : FontStyle.normal,
                          decoration: done
                              ? TextDecoration.lineThrough
                              : TextDecoration.none,
                          decorationColor: _kForest,
                        ),
                      ),
                    ),
                    if (_qtyLabel.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color:        done
                              ? const Color(0xFFEDE9E3)
                              : const Color(0xFFF0EDE7),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          _qtyLabel,
                          style: const TextStyle(
                            fontSize:   11,
                            fontWeight: FontWeight.w700,
                            color:      _kMuted,
                          ),
                        ),
                      ),
                    ],
                    // ── Inline "send this missing item to a list" icon ────
                    if (missing && !done && onAddToList != null) ...[
                      const SizedBox(width: 6),
                      InkResponse(
                        onTap:  onAddToList,
                        radius: 18,
                        child: Container(
                          padding: const EdgeInsets.all(5),
                          decoration: BoxDecoration(
                            color:        _amberFg.withAlpha(20),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Icon(
                            Icons.add_shopping_cart_rounded,
                            size:  18,
                            color: _amberFg,
                          ),
                        ),
                      ),
                    ],
                  ],
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
// _ProgressCard — cooking progress summary
// =============================================================================

class _ProgressCard extends StatelessWidget {
  const _ProgressCard({required this.doneSteps, required this.totalSteps});

  final int doneSteps;
  final int totalSteps;

  double get _progress =>
      totalSteps == 0 ? 0 : doneSteps / totalSteps;

  @override
  Widget build(BuildContext context) {
    final allDone = doneSteps == totalSteps && totalSteps > 0;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      curve:    Curves.easeOut,
      padding:  const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: allDone
            ? const LinearGradient(
                colors: [Color(0xFF0C351E), Color(0xFF2E7D4F)],
                begin:  Alignment.topLeft,
                end:    Alignment.bottomRight,
              )
            : null,
        color:        allDone ? null : Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color:      allDone
                ? _kForest.withAlpha(60)
                : Colors.black.withAlpha(8),
            blurRadius: allDone ? 20 : 8,
            offset:     const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                allDone
                    ? Icons.celebration_rounded
                    : Icons.local_fire_department_rounded,
                color: allDone ? const Color(0xFF6FCF97) : _kOrange,
                size:  20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  allDone
                      ? 'You crushed it! Dish is done 🎉'
                      : 'Cooking progress',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize:   14,
                    color:      allDone ? Colors.white : _kForest,
                  ),
                ),
              ),
              Text(
                '$doneSteps / $totalSteps',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize:   16,
                  color:      allDone ? Colors.white : _kForest,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value:            _progress,
              minHeight:        6,
              backgroundColor:  allDone
                  ? Colors.white.withAlpha(40)
                  : const Color(0xFFEDE9E3),
              valueColor: AlwaysStoppedAnimation<Color>(
                allDone ? const Color(0xFF6FCF97) : _kOrange,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// _NotesField — chef's notes text area
// =============================================================================

class _NotesField extends StatelessWidget {
  const _NotesField({
    required this.controller,
    required this.onChanged,
  });

  final TextEditingController controller;
  final ValueChanged<String>  onChanged;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;

    return TextField(
      controller:  controller,
      maxLines:    null,
      minLines:    3,
      onChanged:   onChanged,
      style:       tt.bodyMedium,
      decoration: InputDecoration(
        hintText:    'Jot down tweaks, substitutions, or reminders…',
        hintStyle:   TextStyle(color: cs.onSurfaceVariant.withAlpha(128)),
        filled:      true,
        fillColor:   Colors.white,
        contentPadding: const EdgeInsets.all(16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide:   BorderSide(color: cs.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide:   BorderSide(color: cs.outlineVariant),
        ),
        focusedBorder: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(16)),
          borderSide:   BorderSide(color: _kForest, width: 1.5),
        ),
      ),
    );
  }
}

// =============================================================================
// Small shared sub-widgets
// =============================================================================

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.icon,
    required this.label,
    this.count,
    this.trailing,
  });

  final IconData icon;
  final String   label;
  final int?     count;
  final Widget?  trailing;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;

    return Row(
      children: [
        Container(
          width:  34,
          height: 34,
          decoration: BoxDecoration(
            color:        _kForest,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: Colors.white, size: 16),
        ),
        const SizedBox(width: 10),
        Text(
          label,
          style: tt.titleSmall?.copyWith(
            fontWeight: FontWeight.w800,
            color:      _kForest,
          ),
        ),
        if (count != null) ...[
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color:        const Color(0xFFEDE9E3),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              '$count',
              style: const TextStyle(
                fontSize:   11,
                fontWeight: FontWeight.w700,
                color:      _kMuted,
              ),
            ),
          ),
        ],
        if (trailing != null) ...[
          const Spacer(),
          trailing!,
        ],
      ],
    );
  }
}

class _SmallChipButton extends StatelessWidget {
  const _SmallChipButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData     icon;
  final String       label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color:        _kOrange.withAlpha(20),
          borderRadius: BorderRadius.circular(20),
          border:       Border.all(color: _kOrange.withAlpha(60)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: _kOrange),
            const SizedBox(width: 5),
            Text(
              label,
              style: const TextStyle(
                fontSize:   11,
                fontWeight: FontWeight.w700,
                color:      _kOrange,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SourceChip extends StatelessWidget {
  const _SourceChip({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.link_rounded, size: 13, color: _kMuted),
        const SizedBox(width: 5),
        Expanded(
          child: Text(
            url,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: _kMuted),
          ),
        ),
      ],
    );
  }
}

class _LoadsheddingBanner extends StatelessWidget {
  const _LoadsheddingBanner({required this.friendly});

  final bool friendly;

  @override
  Widget build(BuildContext context) {
    final bg    = friendly ? _kForest                : const Color(0xFF2C2C2E);
    final fg    = friendly ? const Color(0xFF6FCF97) : const Color(0xFF98989F);
    final icon  = friendly ? Icons.local_fire_department_rounded : Icons.bolt_rounded;
    final label = friendly ? 'Braai-ready — no electricity needed' : 'Requires electricity';

    return Container(
      padding:    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(16)),
      child: Row(
        children: [
          Icon(icon, color: fg, size: 18),
          const SizedBox(width: 10),
          Text(
            label,
            style: TextStyle(
              color:      fg,
              fontWeight: FontWeight.w700,
              fontSize:   13,
            ),
          ),
        ],
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) {
    return const Divider(color: _kDivider, height: 1, thickness: 1);
  }
}

// =============================================================================
// _FillTheGapButton — copies missing ingredients to clipboard for Sixty60/Asap
// =============================================================================

class _FillTheGapButton extends StatelessWidget {
  const _FillTheGapButton({
    required this.missingCount,
    required this.onTap,
  });

  final int          missingCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        decoration: BoxDecoration(
          // Subtle green-tinted background signals "actionable / shop"
          color:        const Color(0xFF0C351E).withAlpha(10),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: const Color(0xFF0C351E).withAlpha(50),
            width: 1.2,
          ),
        ),
        child: Row(
          children: [
            // Cart icon in a green bubble
            Container(
              width:  40,
              height: 40,
              decoration: BoxDecoration(
                color:        const Color(0xFF0C351E),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.shopping_cart_checkout_rounded,
                color: Colors.white,
                size:  20,
              ),
            ),
            const SizedBox(width: 12),

            // Label block
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Fill the Gap 🛒',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize:   14,
                      color:      Color(0xFF0C351E),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$missingCount missing ingredient${missingCount == 1 ? '' : 's'} '
                    '— copied for Sixty60 or PnP Asap',
                    style: const TextStyle(
                      fontSize:  12,
                      color:     Color(0xFF55534E),
                    ),
                  ),
                ],
              ),
            ),

            // Copy icon
            const Icon(
              Icons.copy_rounded,
              size:  18,
              color: Color(0xFF0C351E),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Share menu — chooser sheet between native share and community-feed publish
// =============================================================================

enum _ShareAction { external, community }

class _ShareMenuSheet extends StatelessWidget {
  const _ShareMenuSheet({required this.recipeTitle});

  final String recipeTitle;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Drag handle
            Center(
              child: Container(
                width:  44,
                height: 4,
                decoration: BoxDecoration(
                  color:        _kDivider,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 18),

            const Text(
              'Share recipe',
              style: TextStyle(
                fontSize:   18,
                fontWeight: FontWeight.w800,
                color:      _kForest,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              recipeTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, color: _kMuted),
            ),
            const SizedBox(height: 18),

            // ── Route A: External share ─────────────────────────────────────
            _ShareOptionTile(
              icon:        Icons.ios_share_rounded,
              iconBg:      _kForest,
              title:       'Send to WhatsApp, Email, or…',
              subtitle:    "Open the system share sheet for any installed app.",
              onTap:       () => Navigator.pop(context, _ShareAction.external),
            ),
            const SizedBox(height: 10),

            // ── Route B: Community feed publish ─────────────────────────────
            _ShareOptionTile(
              icon:        Icons.public_rounded,
              iconBg:      _kOrange,
              title:       "Post to What's Cooking 🍳",
              subtitle:    'Publish this recipe to the ChowSA community feed.',
              onTap:       () => Navigator.pop(context, _ShareAction.community),
            ),
          ],
        ),
      ),
    );
  }
}

class _ShareOptionTile extends StatelessWidget {
  const _ShareOptionTile({
    required this.icon,
    required this.iconBg,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData     icon;
  final Color        iconBg;
  final String       title;
  final String       subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color:        Colors.white,
          borderRadius: BorderRadius.circular(18),
          border:       Border.all(color: _kDivider),
        ),
        child: Row(
          children: [
            Container(
              width:  44,
              height: 44,
              decoration: BoxDecoration(
                color:        iconBg,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: Colors.white, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize:   14,
                      fontWeight: FontWeight.w800,
                      color:      _kForest,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 12,
                      color:    _kMuted,
                      height:   1.4,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.chevron_right_rounded,
              color: _kMuted,
              size:  20,
            ),
          ],
        ),
      ),
    );
  }
}
