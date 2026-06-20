// lib/views/my_recipes_screen.dart
//
// Full CRUD screen for the user's personal recipe collection.
//
// ├── MyRecipesScreen        — scrollable list + FAB (Create)
// └── _RecipeDetailScreen    — read/edit/delete a single recipe
//
// Persistence: SharedPreferences key 'user_recipes_v1'.
// Data format: JSON array using Recipe.toJson() / Recipe.fromJson().

import 'dart:math' show min;
import 'package:flutter/material.dart';
import '../services/inbox_share_service.dart';
import '../models/recipe.dart';
import '../models/ingredient.dart';
import '../services/recipe_repository.dart';
import '../services/recipe_share_service.dart';
import '../widgets/motion.dart';
import '../widgets/user_handle_autocomplete.dart';
import 'add_edit_recipe_screen.dart';
import 'recipe_to_shopping_sheet.dart';

// =============================================================================
// Design tokens
// =============================================================================

const _kForest = Color(0xFF0C351E);
const _kOrange = Color(0xFFE59B27);
const _kCream  = Color(0xFFF4F1EA);
const _kMuted  = Color(0xFF55534E);

const _kAvatarPalette = [
  Color(0xFF0C351E), Color(0xFFE59B27), Color(0xFF1565C0),
  Color(0xFF6A1B9A), Color(0xFF00838F), Color(0xFFF57F17),
  Color(0xFFC62828), Color(0xFF37474F),
];

Color _avatarColor(String title) =>
    _kAvatarPalette[title.hashCode.abs() % _kAvatarPalette.length];

String _initials(String title) {
  final words = title.trim().split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return '?';
  if (words.length == 1) {
    return words.first.substring(0, min(2, words.first.length)).toUpperCase();
  }
  return '${words[0][0]}${words[1][0]}'.toUpperCase();
}

// =============================================================================
// Sealed result types used by _RecipeDetailScreen → MyRecipesScreen
// =============================================================================

sealed class _DetailResult {}

class _DetailDeleted extends _DetailResult {
  _DetailDeleted();
}

class _DetailEdited extends _DetailResult {
  final Recipe recipe;
  _DetailEdited(this.recipe);
}

// =============================================================================
// MyRecipesScreen
// =============================================================================

class MyRecipesScreen extends StatefulWidget {
  const MyRecipesScreen({super.key, this.braaiOnly = false});

  /// When true, the list filters down to recipes with `isBraaiReady == true`
  /// and the AppBar title flips to "Braai Recipes". Used by the home screen's
  /// "Fire Up the Grid" CTA so the Browse Braai Recipes flow lands in a
  /// pre-filtered cookbook instead of the unrelated Community tab.
  final bool braaiOnly;

  @override
  State<MyRecipesScreen> createState() => _MyRecipesScreenState();
}

class _MyRecipesScreenState extends State<MyRecipesScreen> {
  // Repository is the single source of truth — it hits Supabase first and
  // falls back to its own SharedPreferences cache when offline / signed out.
  final _repo = RecipeRepository.instance;

  List<Recipe> _recipes = [];
  bool         _loaded  = false;
  // Snapshot of the notifier value we last re-fetched against. When the
  // repository broadcasts a higher number, we reload.
  int _lastNotifierValue = -1;

  @override
  void initState() {
    super.initState();
    _refresh();
    _repo.updateNotifier.addListener(_onRepoUpdate);
  }

  @override
  void dispose() {
    _repo.updateNotifier.removeListener(_onRepoUpdate);
    super.dispose();
  }

  void _onRepoUpdate() {
    if (_repo.updateNotifier.value != _lastNotifierValue) _refresh();
  }

  Future<void> _refresh() async {
    _lastNotifierValue = _repo.updateNotifier.value;
    final list = await _repo.loadAll();
    if (!mounted) return;
    setState(() {
      _recipes = list;
      _loaded  = true;
    });
  }

  void _showSnack(String msg, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontWeight: FontWeight.w600)),
        backgroundColor: isError ? const Color(0xFFC62828) : _kForest,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  // ── Share ─────────────────────────────────────────────────────────────────

  void _showShareSheet(BuildContext context, Recipe recipe) {
    showModalBottomSheet<void>(
      context:         context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _ShareSheet(
        recipe:   recipe,
        onResult: _handleShareResult,
      ),
    );
  }

  void _handleShareResult(ShareResult result) {
    switch (result) {
      case ShareResult.communitySuccess:
        _showSnack('Recipe shared to What\'s Cooking! 🔥');
      case ShareResult.notSignedIn:
        _showSnack('Sign in to share to the community feed.', isError: true);
      case ShareResult.channelNotFound:
        _showSnack(
          "No What's Cooking channel for your suburb yet.",
          isError: true,
        );
      case ShareResult.communityError:
        _showSnack('Could not post to the feed — try again.', isError: true);
      case ShareResult.systemShareInvoked:
        break; // OS sheet handles feedback
    }
  }

  // ── Navigation ───────────────────────────────────────────────────────────────

  Future<void> _openCreate() async {
    final draft = await Navigator.push<Recipe>(
      context,
      MaterialPageRoute<Recipe>(
        builder: (_) => const AddEditRecipeScreen(),
      ),
    );
    if (!mounted || draft == null) return;

    // ── Persist to Supabase ─────────────────────────────────────────────────
    // Repository handles auth check, payload mapping, cache refresh, and
    // notifier bump. Listener on updateNotifier triggers _refresh() so the
    // list re-pulls from the DB immediately — no blank view.
    try {
      await _repo.insert(draft);
      if (mounted) _showSnack('Recipe saved to the cloud. 🔥');
    } catch (e) {
      if (mounted) {
        _showSnack(
          'Could not save to cloud — saved locally only. ($e)',
          isError: true,
        );
      }
    }
  }

  Future<void> _openDetail(int index) async {
    final original = _recipes[index];
    final result = await Navigator.push<_DetailResult>(
      context,
      MaterialPageRoute<_DetailResult>(
        builder: (_) => _RecipeDetailScreen(recipe: original),
      ),
    );
    if (!mounted) return;
    if (result is _DetailDeleted) {
      try {
        await _repo.delete(original.sourceUrl ?? '');
        if (mounted) _showSnack('Recipe deleted.');
      } catch (e) {
        if (mounted) _showSnack('Could not delete: $e', isError: true);
      }
    } else if (result is _DetailEdited) {
      try {
        await _repo.update(original.sourceUrl ?? '', result.recipe);
        if (mounted) _showSnack('Recipe updated.');
      } catch (e) {
        if (mounted) _showSnack('Could not update: $e', isError: true);
      }
    }
  }

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Apply the optional braai filter to the displayed list. We never mutate
    // _recipes itself — the persisted dataset stays intact, only the rendered
    // view narrows.
    final visible = widget.braaiOnly
        ? _recipes.where((r) => r.isBraaiReady).toList(growable: false)
        : _recipes;
    final titleText = widget.braaiOnly ? 'Braai Recipes' : 'My Recipes';

    return Scaffold(
      backgroundColor: _kCream,
      appBar: AppBar(
        backgroundColor: _kForest,
        foregroundColor: Colors.white,
        elevation:       0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              titleText,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
            ),
            if (_loaded && visible.isNotEmpty)
              Text(
                '${visible.length} recipe${visible.length == 1 ? '' : 's'}',
                style: const TextStyle(fontSize: 11, color: Colors.white70),
              ),
          ],
        ),
      ),

      // FAB removed — primary creation flow is the centred "Create My First
      // Recipe" button inside _EmptyState, which avoids double-action
      // confusion (FAB + centre CTA fighting for the same tap intent).

      body: !_loaded
          ? const Center(child: CircularProgressIndicator(color: _kForest))
          : visible.isEmpty
              ? _EmptyState(onAdd: _openCreate, braaiOnly: widget.braaiOnly)
              : ListView.builder(
                  padding:     const EdgeInsets.fromLTRB(16, 20, 16, 100),
                  itemCount:   visible.length,
                  itemBuilder: (_, i) {
                    final recipe = visible[i];
                    final card = Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child:   _RecipeCard(
                        recipe:  recipe,
                        // Tapping a filtered card needs the source-list index,
                        // not the filtered index, so edit/delete still hit the
                        // right row.
                        onTap:   () => _openDetail(_recipes.indexOf(recipe)),
                        onShare: () => _showShareSheet(context, recipe),
                      ),
                    );
                    // Swipe left → confirm + delete the recipe. Uses the
                    // source-list index so a filtered view still removes the
                    // right row. Stable key by sourceUrl (or title fallback)
                    // so Dismissible doesn't re-attach to a sibling after the
                    // list re-sorts on refresh.
                    return Dismissible(
                      key: ValueKey(
                        'recipe_${recipe.sourceUrl ?? recipe.title}',
                      ),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        alignment: Alignment.centerRight,
                        padding:   const EdgeInsets.only(right: 24),
                        decoration: BoxDecoration(
                          color:        Colors.red.shade700,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Icon(
                          Icons.delete_rounded,
                          color: Colors.white,
                          size:  26,
                        ),
                      ),
                      confirmDismiss: (_) async {
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20),
                            ),
                            title: const Text(
                              'Delete recipe?',
                              style: TextStyle(fontWeight: FontWeight.w800),
                            ),
                            content: Text(
                              '"${recipe.title}" will be removed from your '
                              'recipes. This cannot be undone.',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, false),
                                child: const Text('Cancel'),
                              ),
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, true),
                                style: TextButton.styleFrom(
                                  foregroundColor: Colors.red.shade700,
                                ),
                                child: const Text('Delete'),
                              ),
                            ],
                          ),
                        );
                        if (ok != true) return false;
                        try {
                          await _repo.delete(recipe.sourceUrl ?? '');
                          if (mounted) _showSnack('Recipe deleted.');
                          return true;
                        } catch (e) {
                          if (mounted) {
                            _showSnack('Could not delete: $e', isError: true);
                          }
                          return false;
                        }
                      },
                      child: card,
                    );
                  },
                ),
    );
  }
}

// =============================================================================
// _EmptyState
// =============================================================================

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onAdd, this.braaiOnly = false});
  final VoidCallback onAdd;
  final bool         braaiOnly;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width:  80,
              height: 80,
              decoration: BoxDecoration(
                color:        _kForest.withAlpha(14),
                shape:        BoxShape.circle,
                border:       Border.all(color: _kForest.withAlpha(40)),
              ),
              child: const Icon(Icons.menu_book_outlined,
                  size: 36, color: _kForest),
            ),
            const SizedBox(height: 20),
            Text(
              braaiOnly ? 'No braai recipes yet' : 'No recipes yet',
              style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Text(
              braaiOnly
                  ? 'Save any recipe with the Braai Ready tag and it lands here.'
                  : 'Tap the + button to create your first personal recipe, chom.',
              textAlign: TextAlign.center,
              style:     tt.bodyMedium?.copyWith(
                color: _kMuted, height: 1.5),
            ),
            const SizedBox(height: 28),
            FilledButton.icon(
              onPressed: onAdd,
              icon:  const Icon(Icons.add_rounded, size: 20),
              label: const Text(
                'Create My First Recipe',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: _kOrange,
                padding: const EdgeInsets.symmetric(
                    horizontal: 22, vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// _RecipeCard — list item for MyRecipesScreen
// =============================================================================

class _RecipeCard extends StatelessWidget {
  const _RecipeCard({
    required this.recipe,
    required this.onTap,
    this.onShare,
  });

  final Recipe        recipe;
  final VoidCallback  onTap;
  final VoidCallback? onShare;

  @override
  Widget build(BuildContext context) {
    final tt    = Theme.of(context).textTheme;
    final cs    = Theme.of(context).colorScheme;
    final color = _avatarColor(recipe.title);

    // v4.0 themes: the card background, title text and footer-tag colours
    // all flow from the active ColorScheme so they re-contrast correctly
    // across Fresh (light cream), Karoo Twilight (dark graphite) and
    // Savanna Dusk (warm sand). No hard-coded white / charcoal anywhere.
    final isDark        = Theme.of(context).brightness == Brightness.dark;
    final cardBg        = cs.surfaceContainerLowest;
    final cardBorder    = cs.outlineVariant.withAlpha(160);
    final titleColor    = cs.onSurface;
    final tagBg         = cs.secondary.withAlpha(isDark ? 60 : 26);
    final tagText       = isDark ? cs.secondary : cs.onSurface;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color:        cardBg,
          borderRadius: BorderRadius.circular(18),
          border:       Border.all(color: cardBorder),
          boxShadow: [
            BoxShadow(
              color:      Colors.black.withAlpha(isDark ? 40 : 8),
              blurRadius: 8,
              offset:     const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            // Coloured avatar
            Container(
              width:  64,
              height: 64,
              decoration: BoxDecoration(
                color:        color,
                borderRadius: const BorderRadius.horizontal(
                  left: Radius.circular(17),
                ),
              ),
              alignment: Alignment.center,
              child: Text(
                _initials(recipe.title),
                style: const TextStyle(
                  color:      Colors.white,
                  fontSize:   20,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),

            // Details
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      recipe.title,
                      style: tt.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                        color:      titleColor,
                        height:     1.2,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (recipe.isBraaiReady) ...[
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color:        tagBg,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          '🔥 Braai Ready',
                          style: TextStyle(
                            fontSize:   10,
                            fontWeight: FontWeight.w700,
                            color:      tagText,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),

            // Share icon button
            if (onShare != null)
              IconButton(
                onPressed: onShare,
                icon:      const Icon(Icons.ios_share_rounded),
                iconSize:  20,
                color:     cs.onSurfaceVariant.withAlpha(160),
                tooltip:   'Share recipe',
                splashRadius: 20,
                constraints: const BoxConstraints(
                  minWidth:  36,
                  minHeight: 36,
                ),
                padding: const EdgeInsets.all(4),
              )
            else
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Icon(
                  Icons.chevron_right_rounded,
                  color: cs.onSurfaceVariant.withAlpha(120),
                  size:  22,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// (Former _MetaChip widget removed — recipe item counts no longer surfaced
//  on list cards. Counts are still visible inside the detail screen via
//  the _DetailSectionHeading badges where they belong.)

// =============================================================================
// _RecipeDetailScreen — read + edit + delete
// =============================================================================

class _RecipeDetailScreen extends StatefulWidget {
  const _RecipeDetailScreen({required this.recipe});
  final Recipe recipe;

  @override
  State<_RecipeDetailScreen> createState() => _RecipeDetailScreenState();
}

class _RecipeDetailScreenState extends State<_RecipeDetailScreen> {
  late Recipe _recipe;

  @override
  void initState() {
    super.initState();
    _recipe = widget.recipe;
  }

  // ── Share ────────────────────────────────────────────────────────────────────

  void _onShare() {
    showModalBottomSheet<void>(
      context:         context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _ShareSheet(
        recipe:   _recipe,
        onResult: _handleShareResult,
      ),
    );
  }

  void _handleShareResult(ShareResult result) {
    switch (result) {
      case ShareResult.communitySuccess:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Recipe shared to What\'s Cooking! 🔥',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            backgroundColor: _kForest,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
          ),
        );
      case ShareResult.notSignedIn:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Sign in to share to the community feed.',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            backgroundColor: Colors.red.shade700,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
          ),
        );
      case ShareResult.channelNotFound:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              "No What's Cooking channel for your suburb yet.",
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            backgroundColor: Colors.red.shade700,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
          ),
        );
      case ShareResult.communityError:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Could not post to the feed — try again.',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            backgroundColor: Colors.red.shade700,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
          ),
        );
      case ShareResult.systemShareInvoked:
        break; // OS handles feedback
    }
  }

  // ── Edit ────────────────────────────────────────────────────────────────────

  Future<void> _onEdit() async {
    final edited = await Navigator.push<Recipe>(
      context,
      MaterialPageRoute<Recipe>(
        builder: (_) => AddEditRecipeScreen(recipe: _recipe),
      ),
    );
    if (edited != null && mounted) {
      // Pop detail back to list with the updated recipe.
      Navigator.pop(context, _DetailEdited(edited));
    }
  }

  // ── Delete ──────────────────────────────────────────────────────────────────

  Future<void> _onDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          'Delete this recipe, chom?',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
        ),
        content: Text(
          '"${_recipe.title}" will be permanently removed from '
          'your collection. This cannot be undone.',
          style: const TextStyle(height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child:     const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon:  const Icon(Icons.delete_forever_rounded, size: 17),
            label: const Text(
              'Delete',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      Navigator.pop(context, _DetailDeleted());
    }
  }

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final tt    = Theme.of(context).textTheme;
    final color = _avatarColor(_recipe.title);

    return Scaffold(
      backgroundColor: _kCream,
      appBar: AppBar(
        backgroundColor: color,
        foregroundColor: Colors.white,
        elevation:       0,
        title: Text(
          _recipe.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontWeight: FontWeight.w800,
            fontSize:   16,
          ),
        ),
        actions: [
          // ── Share ────────────────────────────────────────────────────────────
          IconButton(
            onPressed: _onShare,
            icon:      const Icon(Icons.ios_share_rounded),
            tooltip:   'Share recipe',
          ),
          // ── Edit ────────────────────────────────────────────────────────────
          IconButton(
            onPressed: _onEdit,
            icon:      const Icon(Icons.edit_rounded),
            tooltip:   'Edit recipe',
          ),
          // ── Delete ──────────────────────────────────────────────────────────
          IconButton(
            onPressed: _onDelete,
            icon:      const Icon(Icons.delete_forever_rounded),
            tooltip:   'Delete recipe',
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          // ── Scrollable upper body ──────────────────────────────────────────
          Expanded(
            child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [

            // ── Hero badge row ────────────────────────────────────────────────
            Row(
              children: [
                Container(
                  width:  64,
                  height: 64,
                  decoration: BoxDecoration(
                    color:        color,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    _initials(_recipe.title),
                    style: const TextStyle(
                      color:      Colors.white,
                      fontSize:   22,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _recipe.title,
                        style: tt.titleLarge?.copyWith(
                          fontWeight: FontWeight.w900,
                          height:     1.2,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing:    6,
                        runSpacing: 4,
                        children: [
                          _DetailBadge(
                            icon:  Icons.power_off_rounded,
                            label: _recipe.isLoadsheddingFriendly
                                ? 'Gas/Braai/No Power Ready'
                                : 'Needs Power',
                            bg: _recipe.isLoadsheddingFriendly
                                ? _kForest
                                : const Color(0xFF2C2C2E),
                            fg: _recipe.isLoadsheddingFriendly
                                ? const Color(0xFF6FCF97)
                                : const Color(0xFF98989F),
                          ),
                          if (_recipe.isBraaiReady)
                            const _DetailBadge(
                              icon:  Icons.outdoor_grill_rounded,
                              label: 'Braai Ready',
                              bg:    Color(0xFFBF360C),
                              fg:    Colors.white,
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),

            const SizedBox(height: 28),

            // ── Ingredients ───────────────────────────────────────────────────
            if (_recipe.ingredients.isNotEmpty) ...[
              _DetailSectionHeading(
                icon:    Icons.egg_alt_outlined,
                label:   'Ingredients',
                count:   _recipe.ingredients.length,
                trailing: _AddToListPill(
                  onTap: () => _addAllToShoppingList(context),
                ),
              ),
              const SizedBox(height: 10),
              _IngredientBlock(ingredients: _recipe.ingredients),
              const SizedBox(height: 24),
            ],

            // ── Instructions ──────────────────────────────────────────────────
            if (_recipe.instructions.isNotEmpty) ...[
              _DetailSectionHeading(
                icon:  Icons.format_list_numbered_rounded,
                label: 'Instructions',
                count: _recipe.instructions.length,
              ),
              const SizedBox(height: 10),
              _InstructionBlock(steps: _recipe.instructions),
              const SizedBox(height: 24),
            ],

            if (_recipe.ingredients.isEmpty && _recipe.instructions.isEmpty)
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 40),
                  child: Text(
                    'This recipe has no details yet. Tap ✏️ to fill it in.',
                    textAlign: TextAlign.center,
                    style: tt.bodyMedium?.copyWith(color: _kMuted, height: 1.5),
                  ),
                ),
              ),
              const SizedBox(height: 24),
                ],
              ),
            ),
          ),

          // ── Anchored bottom action stack ───────────────────────────────────
          // Stays pinned at the base of the viewport while the upper body
          // scrolls behind it. Top border keeps the Share CTA visually
          // separated from the last instruction step.
          SafeArea(
            top: false,
            child: Container(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
              decoration: BoxDecoration(
                color: _kCream,
                border: Border(
                  top: BorderSide(
                    color: Theme.of(context).colorScheme.outlineVariant
                        .withAlpha(120),
                  ),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _onShare,
                      icon:  const Icon(Icons.ios_share_rounded,
                          size: 18, color: Colors.white),
                      label: const Text(
                        'Share Recipe',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize:   14,
                          color:      Colors.white,
                        ),
                      ),
                      style: FilledButton.styleFrom(
                        backgroundColor: _kForest,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _onEdit,
                          icon:  const Icon(Icons.edit_rounded, size: 18),
                          label: const Text(
                            'Edit',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: _kForest,
                            side:    const BorderSide(color: _kForest),
                            padding: const EdgeInsets.symmetric(vertical: 13),
                            shape:   RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _onDelete,
                          icon:  Icon(
                            Icons.delete_forever_rounded,
                            size:  18,
                            color: Theme.of(context).colorScheme.error,
                          ),
                          label: Text(
                            'Delete',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color:      Theme.of(context).colorScheme.error,
                            ),
                          ),
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(
                              color: Theme.of(context)
                                  .colorScheme
                                  .error
                                  .withAlpha(153),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 13),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Opens the existing recipe→shopping-list sheet so the user can add
  /// every ingredient straight onto an existing list (or a brand-new one).
  void _addAllToShoppingList(BuildContext context) {
    showRecipeToShoppingSheet(context: context, recipe: _recipe);
  }
}

// =============================================================================
// Detail sub-widgets
// =============================================================================

class _DetailSectionHeading extends StatelessWidget {
  const _DetailSectionHeading({
    required this.icon,
    required this.label,
    required this.count,
    this.trailing,
  });

  final IconData icon;
  final String   label;
  final int      count;
  /// Optional right-hand widget — used for the "Add to list" pill on
  /// the Ingredients heading. Pushed to the far right via Spacer.
  final Widget?  trailing;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;

    return Row(
      children: [
        Icon(icon, size: 17, color: _kForest),
        const SizedBox(width: 7),
        Text(
          label,
          style: tt.titleSmall?.copyWith(
            fontWeight: FontWeight.w800,
            color:      _kForest,
          ),
        ),
        const SizedBox(width: 7),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(
            color:        cs.primaryContainer,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            '$count',
            style: TextStyle(
              fontSize:   11,
              fontWeight: FontWeight.w700,
              color:      cs.onPrimaryContainer,
            ),
          ),
        ),
        if (trailing != null) ...[
          const Spacer(),
          trailing!,
        ],
      ],
    );
  }
}

/// "Add to list" pill — matches the meal-planner recipe detail's pill.
/// Mango-gold tint on cream, leading cart icon, semibold copy.
class _AddToListPill extends StatelessWidget {
  const _AddToListPill({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color:        const Color(0xFFFFF1DA),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFFE59B27).withAlpha(110)),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.shopping_cart_outlined,
                size: 14, color: Color(0xFFB66E0F)),
            SizedBox(width: 6),
            Text(
              'Add to list',
              style: TextStyle(
                color:      Color(0xFFB66E0F),
                fontSize:   12.5,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DetailBadge extends StatelessWidget {
  const _DetailBadge({
    required this.icon,
    required this.label,
    required this.bg,
    required this.fg,
  });

  final IconData icon;
  final String   label;
  final Color    bg;
  final Color    fg;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color:        bg,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: fg, size: 11),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize:   10,
              fontWeight: FontWeight.w700,
              color:      fg,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}

/// Interactive ingredient list — tap a row to toggle a checkbox so the
/// user can track what's already on the counter while cooking. Matches
/// the meal-planner recipe detail's tappable-checkbox pattern; state
/// lives in-memory only (resets when the screen closes).
class _IngredientBlock extends StatefulWidget {
  const _IngredientBlock({required this.ingredients});
  final List<Ingredient> ingredients;

  @override
  State<_IngredientBlock> createState() => _IngredientBlockState();
}

class _IngredientBlockState extends State<_IngredientBlock> {
  final Set<int> _checked = <int>{};

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Container(
      decoration: BoxDecoration(
        color:        cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          for (int i = 0; i < widget.ingredients.length; i++) ...[
            InkWell(
              onTap: () => setState(() {
                if (_checked.contains(i)) {
                  _checked.remove(i);
                } else {
                  _checked.add(i);
                }
              }),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 11),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      width: 20, height: 20,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _checked.contains(i)
                            ? _kForest
                            : Colors.transparent,
                        border: Border.all(
                          color: _checked.contains(i)
                              ? _kForest
                              : cs.outlineVariant,
                          width: 1.6,
                        ),
                      ),
                      alignment: Alignment.center,
                      child: _checked.contains(i)
                          ? const Icon(Icons.check_rounded,
                              color: Colors.white, size: 14)
                          : null,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        widget.ingredients[i].toString(),
                        style: tt.bodyMedium?.copyWith(
                          height:      1.4,
                          color: _checked.contains(i)
                              ? _kMuted.withAlpha(180)
                              : _kForest,
                          fontWeight: FontWeight.w600,
                          decoration: _checked.contains(i)
                              ? TextDecoration.lineThrough
                              : null,
                          decorationColor: _kMuted,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (i < widget.ingredients.length - 1)
              Divider(
                height:    1,
                indent:    14,
                endIndent: 14,
                color:     cs.outlineVariant.withAlpha(120),
              ),
          ],
        ],
      ),
    );
  }
}

/// Interactive instruction timeline — numbered circles connected by a
/// vertical guide line. Tap a step to mark it cooked: the circle fills
/// and the text strikes through. State is in-memory only.
class _InstructionBlock extends StatefulWidget {
  const _InstructionBlock({required this.steps});
  final List<String> steps;

  @override
  State<_InstructionBlock> createState() => _InstructionBlockState();
}

class _InstructionBlockState extends State<_InstructionBlock> {
  final Set<int> _done = <int>{};

  void _toggle(int i) => setState(() {
        if (_done.contains(i)) {
          _done.remove(i);
        } else {
          _done.add(i);
        }
      });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Column(
      children: [
        for (int i = 0; i < widget.steps.length; i++)
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── Number circle + vertical connector ─────────────────
                Column(
                  children: [
                    GestureDetector(
                      onTap: () => _toggle(i),
                      child: AnimatedContainer(
                        // Stay inside the [start,end] interval on both
                        // directions so unchecking a step doesn't overshoot
                        // and briefly distort the row layout.
                        duration: const Duration(milliseconds: 180),
                        curve:    Curves.easeOutCubic,
                        width:     30,
                        height:    30,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: _done.contains(i)
                              ? _kForest
                              : cs.primaryContainer,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: _done.contains(i)
                                ? _kForest
                                : cs.primaryContainer,
                            width: 2,
                          ),
                        ),
                        child: _done.contains(i)
                            ? const Icon(Icons.check_rounded,
                                color: Colors.white, size: 16)
                            : Text(
                                '${i + 1}',
                                style: TextStyle(
                                  fontSize:   12.5,
                                  fontWeight: FontWeight.w800,
                                  color:      cs.onPrimaryContainer,
                                ),
                              ),
                      ),
                    ),
                    if (i < widget.steps.length - 1)
                      Expanded(
                        child: Container(
                          width: 2,
                          margin: const EdgeInsets.symmetric(vertical: 2),
                          color: _done.contains(i)
                              ? _kForest.withAlpha(120)
                              : cs.outlineVariant.withAlpha(140),
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: 14),
                // ── Step body ──────────────────────────────────────────
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(
                      top:    4,
                      bottom: i < widget.steps.length - 1 ? 16 : 0,
                    ),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _toggle(i),
                      child: Text(
                        widget.steps[i],
                        style: tt.bodyMedium?.copyWith(
                          height:      1.5,
                          fontSize:    13.5,
                          color: _done.contains(i)
                              ? _kMuted.withAlpha(180)
                              : _kForest,
                          decoration: _done.contains(i)
                              ? TextDecoration.lineThrough
                              : null,
                          decorationColor: _kMuted,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        // ── Cooking progress card ──────────────────────────────────────
        // Ported from the Meal Planner / pre-populated recipe view so the
        // custom My Recipes detail screen has the same milestone feedback.
        // Reads the live length of [widget.steps] and the [_done] set, so
        // it animates as the user ticks / un-ticks rows above.
        if (widget.steps.isNotEmpty) ...[
          const SizedBox(height: 20),
          _MyRecipesProgressCard(
            doneSteps:  _done.length,
            totalSteps: widget.steps.length,
          ),
        ],
      ],
    );
  }
}

// =============================================================================
// _MyRecipesProgressCard — milestone progress widget for the custom recipe
// detail view. Mirrors the visual + animation language of the Meal Planner
// _ProgressCard so the two recipe surfaces have feature parity.
// =============================================================================

class _MyRecipesProgressCard extends StatelessWidget {
  const _MyRecipesProgressCard({
    required this.doneSteps,
    required this.totalSteps,
  });

  final int doneSteps;
  final int totalSteps;

  double get _progress => totalSteps == 0 ? 0 : doneSteps / totalSteps;

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
          // TweenAnimationBuilder gives the bar a smooth fill animation on
          // every tick / un-tick rather than snapping to the new value.
          TweenAnimationBuilder<double>(
            tween:    Tween(begin: 0, end: _progress),
            duration: const Duration(milliseconds: 400),
            curve:    Curves.easeOut,
            builder: (_, v, __) => ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value:            v,
                minHeight:        6,
                backgroundColor:  allDone
                    ? Colors.white.withAlpha(40)
                    : const Color(0xFFEDE9E3),
                valueColor: AlwaysStoppedAnimation<Color>(
                  allDone ? const Color(0xFF6FCF97) : _kOrange,
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
// _ShareSheet — two-option modal bottom sheet
// =============================================================================
//
// Option A  →  What's Cooking community feed INSERT
// Option B  →  Native OS system share sheet (share_plus)
//
// The sheet is kept stateful so it can show a loading spinner on Option A
// while the Supabase insert is in flight, preventing double-taps.

class _ShareSheet extends StatefulWidget {
  const _ShareSheet({
    required this.recipe,
    required this.onResult,
  });

  final Recipe                    recipe;
  final void Function(ShareResult) onResult;

  @override
  State<_ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends State<_ShareSheet> {
  bool _posting = false;

  Future<void> _shareToFeed() async {
    if (_posting) return;
    setState(() => _posting = true);

    final result = await RecipeShareService.instance.shareToWhatsCooking(
      recipe: widget.recipe,
    );

    if (!mounted) return;
    Navigator.pop(context);
    widget.onResult(result);
  }

  Future<void> _shareViaSystem() async {
    Navigator.pop(context);
    final result = await RecipeShareService.instance.shareViaSystem(
      recipe: widget.recipe,
    );
    widget.onResult(result);
  }

  /// Shares the recipe directly to another ChowSA user's inbox.
  /// Reuses [UserHandleAutocomplete] for the recipient picker so the
  /// dropdown UX matches the Shopping List + Meal Planner share sheets
  /// pixel-for-pixel, then writes a single `inbox_messages` row with
  /// message_type='shared_recipe' so the realtime listener on the
  /// recipient's device delivers it instantly.
  Future<void> _shareToUser() async {
    final ctrl = TextEditingController();
    // Use a bottom sheet (not an AlertDialog) so the keyboard inset
    // smoothly translates the card UP from the bottom edge instead of
    // crushing it against the top of the screen — that was the visible
    // jump when AlertDialog tried to fit title+field+actions in the
    // shrunken viewport. AnimatedPadding keyed to viewInsets.bottom
    // gives the slide a single, continuous transition.
    final handle = await showModalBottomSheet<String>(
      context:              context,
      isScrollControlled:   true,
      backgroundColor:      Colors.transparent,
      builder: (dCtx) {
        return AnimatedPadding(
          duration: const Duration(milliseconds: 180),
          curve:    Curves.easeOut,
          padding:  EdgeInsets.only(
              bottom: MediaQuery.of(dCtx).viewInsets.bottom),
          child: Container(
            padding: EdgeInsets.fromLTRB(
              20, 20, 20,
              20 + MediaQuery.of(dCtx).padding.bottom,
            ),
            decoration: const BoxDecoration(
              color:        Colors.white,
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
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color:        const Color(0xFFE6E2D8),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const Text(
                    'Share with ChowSA User',
                    style: TextStyle(
                      fontSize:   17,
                      fontWeight: FontWeight.w900,
                      color:      _kForest,
                    ),
                  ),
                  const SizedBox(height: 14),
                  UserHandleAutocomplete(
                    controller:  ctrl,
                    accentColor: _kForest,
                    hintText:    'ChowSA handle',
                    onSubmitted: () => Navigator.pop(dCtx, ctrl.text),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(dCtx, null),
                        style: TextButton.styleFrom(
                          foregroundColor: const Color(0xFFE59B27),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 18, vertical: 12),
                          minimumSize: const Size(64, 44),
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
                        onPressed: () => Navigator.pop(dCtx, ctrl.text),
                        style: FilledButton.styleFrom(
                          backgroundColor: _kForest,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 22, vertical: 12),
                          minimumSize: const Size(72, 44),
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
      },
    );
    if (handle == null) return;
    final clean = handle.replaceFirst('@', '').trim().toLowerCase();
    if (clean.isEmpty || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    Navigator.pop(context); // close the share sheet
    try {
      // Unified share path — see InboxShareService. Awaits the
      // .select().single() round-trip, so the "Recipe sent" snackbar
      // ONLY fires after Supabase confirms the row landed in
      // inbox_messages. No more false-positive success.
      final result = await InboxShareService.instance.shareRecipe(
        recipe:          widget.recipe,
        recipientHandle: clean,
      );
      messenger.showSnackBar(SnackBar(
        content:  Text('Recipe sent to @${result.receiverHandle} 🍽️'),
        behavior: SnackBarBehavior.floating,
      ));
    } on InboxShareUnknownRecipient {
      messenger.showSnackBar(SnackBar(
        content:  Text('Could not find @$clean on ChowSA.'),
        behavior: SnackBarBehavior.floating,
      ));
    } on InboxShareTimeoutException {
      messenger.showSnackBar(const SnackBar(
        content:  Text('Network timed out — please try again.'),
        behavior: SnackBarBehavior.floating,
      ));
    } on InboxShareException catch (e) {
      // Typed but unrecognised — surface the code/message so the user
      // (and the issue tracker) can tell an RLS reject from a dedupe
      // glitch instead of a blanket "try again".
      debugPrint('[shareRecipe] InboxShareException ${e.code}: ${e.message}');
      messenger.showSnackBar(SnackBar(
        duration: const Duration(seconds: 6),
        content:  Text('Could not send recipe: ${e.message}'),
        behavior: SnackBarBehavior.floating,
      ));
    } catch (e, st) {
      debugPrint('[shareRecipe] failed: $e\n$st');
      messenger.showSnackBar(SnackBar(
        duration: const Duration(seconds: 6),
        content:  Text('Could not send recipe: $e'),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color:        cs.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: EdgeInsets.fromLTRB(
        24, 14, 24,
        MediaQuery.of(context).padding.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [

          // ── Drag handle ────────────────────────────────────────────────────
          Center(
            child: Container(
              width:  44, height: 4,
              margin: const EdgeInsets.only(bottom: 18),
              decoration: BoxDecoration(
                color:        cs.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),

          // ── Header ─────────────────────────────────────────────────────────
          Row(
            children: [
              Container(
                width:  38, height: 38,
                decoration: BoxDecoration(
                  color:        _avatarColor(widget.recipe.title),
                  borderRadius: BorderRadius.circular(12),
                ),
                alignment: Alignment.center,
                child: Text(
                  _initials(widget.recipe.title),
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
                    Text(
                      'Share Recipe',
                      style: tt.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: cs.onSurface,
                      ),
                    ),
                    Text(
                      widget.recipe.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: tt.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 20),

          // ── Option A: What's Cooking ───────────────────────────────────────
          PressableScale(
            onTap: _posting ? null : _shareToFeed,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color:        _kForest,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  Container(
                    width:  40, height: 40,
                    decoration: BoxDecoration(
                      color:        Colors.white.withAlpha(25),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    alignment: Alignment.center,
                    child: _posting
                        ? const SizedBox(
                            width:  18, height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color:       Colors.white,
                            ),
                          )
                        : const Text('🍳', style: TextStyle(fontSize: 20)),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _posting
                              ? 'Posting to feed…'
                              : 'Share to What\'s Cooking',
                          style: const TextStyle(
                            color:      Colors.white,
                            fontSize:   14,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Publishes to your local community hub',
                          style: TextStyle(
                            color:    Colors.white.withAlpha(170),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (!_posting)
                    const Icon(
                      Icons.chevron_right_rounded,
                      color:  Colors.white70,
                      size:   20,
                    ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 10),

          // ── Option B: Share to a specific ChowSA user ─────────────────────
          // Uses the same UserHandleAutocomplete widget the Shopping List
          // and Meal Planner share flows use — dropdown styling and
          // real-time username suggestions are identical across surfaces.
          PressableScale(
            onTap: _shareToUser,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color:        cs.surfaceContainerLow,
                borderRadius: BorderRadius.circular(16),
                border:       Border.all(color: cs.outlineVariant),
              ),
              child: Row(
                children: [
                  Container(
                    width:  40, height: 40,
                    decoration: BoxDecoration(
                      color:        _kForest.withAlpha(22),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    alignment: Alignment.center,
                    child: const Icon(
                      Icons.person_search_rounded,
                      color: _kForest,
                      size:  20,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Share with CHOWSA User',
                          style: tt.titleSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                            color:      cs.onSurface,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          "Routes the recipe directly to another user's inbox",
                          style: tt.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: cs.onSurfaceVariant.withAlpha(120),
                    size:  20,
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 10),

          // ── Option C: System share ─────────────────────────────────────────
          PressableScale(
            onTap: _shareViaSystem,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color:        cs.surfaceContainerLow,
                borderRadius: BorderRadius.circular(16),
                border:       Border.all(color: cs.outlineVariant),
              ),
              child: Row(
                children: [
                  Container(
                    width:  40, height: 40,
                    decoration: BoxDecoration(
                      color:        _kOrange.withAlpha(22),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.ios_share_rounded,
                      color: _kOrange,
                      size:  20,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Share via Phone',
                          style: tt.titleSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                            color:      cs.onSurface,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'WhatsApp, Email, Messages and more',
                          style: tt.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: cs.onSurfaceVariant.withAlpha(120),
                    size:  20,
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 6),
        ],
      ),
    );
  }
}
