// lib/views/pantry_screen.dart

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/ingredient.dart';
import '../models/recipe.dart';
import '../models/shopping_list.dart';
import '../utils/measurement_format.dart';
import '../services/pantry_service.dart';
import '../services/recipe_repository.dart';
import '../services/ad_reward_service.dart';
import '../services/entitlement_service.dart';
import '../services/image_compression_service.dart';
import 'recipe_to_shopping_sheet.dart' show showRecipeToShoppingSheet;

// =============================================================================
// Screen — owns all state
// =============================================================================

class PantryScreen extends StatefulWidget {
  const PantryScreen({
    super.key,
    this.onAddToShoppingList,
  });

  final void Function(List<ShoppingItem>)? onAddToShoppingList;

  @override
  State<PantryScreen> createState() => _PantryScreenState();
}

class _PantryScreenState extends State<PantryScreen> {
  final _controller = TextEditingController();
  final _focusNode  = FocusNode();
  final _service    = PantryService();
  final _adService  = AdRewardService();
  final _compressor = ImageCompressionService.instance;

  final List<String> _pantryItems = [];
  _ScreenState       _state       = const _Idle();

  // ── Hyper-local context flags ────────────────────────────────────────────────
  bool   _isEmergencyMode = false;   // No-Power Mode  — gas/braai only
  bool   _isBudgetMode    = false;   // Budget Stretch — cap AI to cheap staples
  bool   _isDataSaver     = false;   // Data Saver     — compress images, strip decorative assets
  double _budgetCeiling   = 100;     // Default ceiling when Budget Mode activates

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  // ── Pantry management ──────────────────────────────────────────────────────

  void _addIngredient() {
    final raw = _controller.text.trim();
    if (raw.isEmpty) return;

    // Capitalise first letter, keep the rest as typed.
    final item = raw[0].toUpperCase() + raw.substring(1);

    if (_pantryItems.any((i) => i.toLowerCase() == raw.toLowerCase())) {
      _showSnack('"$item" is already in your pantry.');
      _controller.clear();
      return;
    }

    setState(() => _pantryItems.add(item));
    _controller.clear();
    _focusNode.requestFocus(); // keep focus for rapid-fire entry
  }

  void _removeIngredient(String item) => setState(() => _pantryItems.remove(item));

  void _clearPantry() => setState(() {
        _pantryItems.clear();
        _state = const _Idle();
      });

  // ── Fridge scan — camera ───────────────────────────────────────────────────

  Future<void> _scanFridge() async {
    // Per-kind scan quota: 2 free camera scans/day, +1 per rewarded ad
    // up to a hard cap of 4. Separate bucket from the recipe scraper.
    final ok = await _adService.requestScan(context, ScanKind.cameraScanner);
    if (!ok || !mounted) return;
    // All Gemini Vision uploads now route through ImageCompressionService —
    // it caps the longest edge at 512 px and re-encodes at JPEG quality 75
    // before the bytes ever leave the platform layer. Data-Saver mode
    // tightens further (256 px / q60) for ultra-low-bandwidth users on
    // capped mobile data; everyone else gets the spec-default contract
    // which already slashes per-call image tokens by ~10×.
    final CompressedImage? photo = await _compressor.pickAndCompress(
      source:            ImageSource.camera,
      overrideMaxEdgePx: _isDataSaver ? 256 : null,
      overrideQuality:   _isDataSaver ? 60  : null,
    );
    if (photo == null || !mounted) return;

    setState(() => _state = const _Scanning());

    try {
      final PantryScanResult scan =
          await _service.detectIngredientsFromImage(photo.bytes);
      // Camera path is the fridge scanner — recipe title is informational
      // only, no Save-to-My-Recipes flow here.
      final List<String> detected = scan.ingredients;

      if (!mounted) return;
      setState(() => _state = const _Idle());

      // AI confirmation dialog — user can add/remove items before continuing.
      // Returns the FRESH user-edited list, not the raw scan payload.
      final result = await showDialog<ScanConfirmResult>(
        context: context,
        builder: (_) => _ScanConfirmDialog(scannedResults: detected),
      );

      if (!mounted || result == null) return;

      // Persist the user-edited collection into the pantry (not `detected`).
      setState(() {
        for (final i in result.items) {
          if (!_pantryItems.contains(i)) _pantryItems.add(i);
        }
      });

      if (result.action == '__generate__') {
        await _generate();
      } else {
        _showSnack('${result.items.length} ingredients added to your pantry!');
      }
    } on PantryException catch (e) {
      if (mounted) { setState(() => _state = const _Idle()); _showSnack(e.message); }
    } catch (_) {
      if (mounted) { setState(() => _state = const _Idle()); _showSnack('Could not scan the photo. Please try again.'); }
    }
  }

  // ── Gallery scan ────────────────────────────────────────────────────────────

  Future<void> _scanGallery() async {
    // Shares the camera-scanner bucket with _scanFridge: 2 free scans/day,
    // +1 per rewarded ad, hard cap 4. Gallery upload is the same AI
    // pipeline so it counts against the same daily allowance.
    final ok = await _adService.requestScan(context, ScanKind.cameraScanner);
    if (!ok || !mounted) return;
    // Same 512px / q75 compression contract as the camera path — see
    // ImageCompressionService for the rationale. Data-Saver mode tightens
    // further on top of the default contract.
    final CompressedImage? photo = await _compressor.pickAndCompress(
      source:            ImageSource.gallery,
      overrideMaxEdgePx: _isDataSaver ? 256 : null,
      overrideQuality:   _isDataSaver ? 60  : null,
    );
    if (photo == null || !mounted) return;

    setState(() => _state = const _Scanning());

    try {
      final PantryScanResult scan =
          await _service.detectIngredientsFromImage(photo.bytes);

      if (!mounted) return;
      setState(() => _state = const _Idle());

      // Show the full scan result sheet — user can deselect chips before saving
      final chosen = await showModalBottomSheet<List<String>?>(
        context:            context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (ctx) => _ScanResultSheet(
          recipeTitle:         scan.recipeTitle,
          detectedIngredients: scan.ingredients,
          existingItems:       List.from(_pantryItems),
        ),
      );

      if (!mounted || chosen == null) return;

      final action = chosen.first;
      final items  = chosen.sublist(1);

      // ── Save-to-My-Recipes branch — fires when the sheet's new
      // "Save to My Recipes" CTA is tapped. Routes through the recipe
      // repository so the row lands in Supabase `recipes` (RLS enforces
      // user_id = auth.uid()) and the My Recipes list refreshes via the
      // existing updateNotifier broadcast.
      // ── Save-to-Shopping-List branch — fires from the new pill above
      // "Generate a Recipe". Wraps the picked chips in a transient Recipe
      // (title-only) and pushes them through the same recipe→shopping
      // bottom sheet used in recipe detail. That sheet handles append-vs-
      // create and bumps shoppingListsUpdateNotifier on save, so the
      // Shopping Hub refreshes live.
      if (action == '__save_to_shopping__') {
        if (items.isEmpty) return;
        final synthTitle = (scan.recipeTitle?.trim().isNotEmpty ?? false)
            ? scan.recipeTitle!.trim()
            : 'Scanned ingredients';
        await showRecipeToShoppingSheet(
          context: context,
          recipe:  Recipe(
            title:        synthTitle,
            ingredients:  items.map((n) => Ingredient(name: n)).toList(),
            instructions: const [],
            isLoadsheddingFriendly: false,
          ),
        );
        return;
      }

      if (action == '__save_recipe__') {
        final title = scan.recipeTitle?.trim();
        if (title == null || title.isEmpty) {
          _showSnack('No recipe title detected — try the gallery scan '
              'with a clearer recipe-card photo.');
          return;
        }
        try {
          await RecipeRepository.instance.insert(
            Recipe(
              title:        title,
              ingredients:  items.map((n) => Ingredient(name: n)).toList(),
              instructions: const [],
              isLoadsheddingFriendly: false,
            ),
            source: 'pantry-scan',
          );
          if (mounted) _showSnack('$title saved to My Recipes 🔥');
        } catch (e) {
          if (mounted) _showSnack('Could not save: $e');
        }
        return;
      }

      setState(() {
        for (final i in items) {
          if (!_pantryItems.contains(i)) _pantryItems.add(i);
        }
      });

      if (action == '__generate__') await _generate();
      else _showSnack('${items.length} ingredients added to your pantry!');

    } on PantryException catch (e) {
      if (mounted) { setState(() => _state = const _Idle()); _showSnack(e.message); }
    } catch (_) {
      if (mounted) { setState(() => _state = const _Idle()); _showSnack('Could not process the photo. Please try again.'); }
    }
  }

  // ── Generate ───────────────────────────────────────────────────────────────

  Future<void> _generate() async {
    FocusScope.of(context).unfocus();

    // ── Ad gate ──────────────────────────────────────────────────────────────
    final allowed = await _adService.requestGeneration(context);
    if (!allowed) return;   // quota full, user dismissed ad prompt

    // Capture the currently-displayed titles BEFORE flipping into Loading.
    // Re-tapping "Regenerate" while a result is on screen passes these
    // back into the prompt as an explicit exclusion list — Gemini then
    // has to swap proteins / methods / culinary directions on each retry
    // instead of recycling the same three dishes.
    final priorTitles = switch (_state) {
      _Success(:final recipes) =>
        recipes.map((r) => r.title).toList(growable: false),
      _ => const <String>[],
    };

    setState(() => _state = const _Loading());

    try {
      await _adService.recordGeneration();
      final recipes = await _service.generateFromPantry(
        List.unmodifiable(_pantryItems),
        isEmergencyMode: _isEmergencyMode,
        isBudgetMode:    _isBudgetMode,
        budgetCeiling:   _isBudgetMode ? _budgetCeiling : null,
        excludeTitles:   priorTitles,
      );
      if (mounted) setState(() => _state = _Success(recipes));
    } on PantryException catch (e, stack) {
      debugPrint('[pantry] PantryException: ${e.message}\n$stack');
      _handleAiFailure(e.message);
    } catch (e, stack) {
      debugPrint('[pantry] Generate error: $e\n$stack');
      _handleAiFailure(e.toString());
    }
  }

  /// Restores the screen to its idle layout (no dark error block) and
  /// surfaces the failure as a brand-toned snackbar. Keeps the user on
  /// their pantry list so they can immediately retry.
  void _handleAiFailure(String raw) {
    if (!mounted) return;
    setState(() => _state = const _Idle());
    _showSnack(_friendlyError(raw));
  }

  /// Maps any raw Gemini / network error string to a clean, brand-toned
  /// user-facing message. Branches on the user's subscription tier so
  /// Pro members get a premium-polite tone while free users see a
  /// patience-or-upgrade nudge. Never lets a raw 4xx/5xx JSON dump
  /// reach the UI — that goes to `adb logcat` via the caller's
  /// `debugPrint`.
  String _friendlyError(String raw) {
    final low   = raw.toLowerCase();
    final isPro = EntitlementService.instance.isPro;

    // Single helper — covers any HTTP code >= 400 we can sniff in the
    // raw error string (503, 500, 502, 504, 429, plus the named SDK
    // variants Gemini reports: UNAVAILABLE / RESOURCE_EXHAUSTED / etc).
    bool matchesAny(List<String> needles) =>
        needles.any(low.contains);

    final isOverloaded = matchesAny(const [
      '503', '500', '502', '504',
      'unavailable', 'overloaded', 'internal',
    ]);
    final isRateLimit = matchesAny(const [
      '429', 'quota', 'resource_exhausted',
      'rate limit', 'exceeded',
    ]);
    final isNetwork = matchesAny(const [
      'timeout', 'timed out', 'socket', 'failed host lookup',
      'handshake', 'connection',
    ]);
    final isAuth = matchesAny(const ['401', '403', 'unauthorized', 'api key']);

    if (isRateLimit) {
      return isPro
          // Pro users theoretically don't hit rate limits, but if they
          // do (cross-region failover, quota anomaly) keep the tone
          // premium and apologetic.
          ? 'Eish! Our heavy-duty scanner is experiencing a temporary '
            'hitch. Please try scanning again in a few seconds!'
          : 'The scanner is busy right now. Want instant scanning? '
            'Upgrade to ChowSA Pro, or try again shortly!';
    }
    if (isOverloaded) {
      return isPro
          ? 'Eish! Our heavy-duty scanner is experiencing a temporary '
            'hitch. Please try scanning again in a few seconds!'
          : 'The scanner is busy right now. Want instant scanning? '
            'Upgrade to ChowSA Pro, or try again shortly!';
    }
    if (isNetwork) {
      return "Looks like a connection wobble! Check your signal and let's "
             'try scanning that fridge again. 📱';
    }
    if (isAuth) {
      return 'Hmm — looks like your session expired. Sign out and back in '
             'to get cooking again.';
    }
    return isPro
        ? 'Eish! Our heavy-duty scanner is experiencing a temporary hitch. '
          'Please try scanning again in a few seconds!'
        : "Something went skew on our side. Catch your breath and let's "
          'try that scan again in a moment. 🍳';
  }

  // ── Context flag toggles ────────────────────────────────────────────────────

  void _toggleEmergencyMode() =>
      setState(() => _isEmergencyMode = !_isEmergencyMode);

  void _toggleDataSaver() =>
      setState(() => _isDataSaver = !_isDataSaver);

  /// Activating Budget Mode shows a ceiling dialog; deactivating just clears.
  Future<void> _toggleBudgetMode() async {
    if (_isBudgetMode) {
      setState(() => _isBudgetMode = false);
      return;
    }
    // Show the budget ceiling input
    final result = await showDialog<double>(
      context: context,
      builder: (ctx) => _BudgetDialog(initialCeiling: _budgetCeiling),
    );
    if (!mounted) return;
    setState(() {
      _isBudgetMode  = true;
      _budgetCeiling = result ?? _budgetCeiling;
    });
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final loading  = _state is _Loading;
    final scanning = _state is _Scanning;
    final canGen   = _pantryItems.isNotEmpty && !loading && !scanning;

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      resizeToAvoidBottomInset: true,
      // ── Persistent generate button — lifts above the soft keyboard ──────
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
              24, 8, 24, 12 + MediaQuery.of(context).viewInsets.bottom),
          child: FilledButton.icon(
            onPressed: canGen ? _generate : null,
            icon: loading
                ? const SizedBox(
                    width:  18,
                    height: 18,
                    child:  CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                  )
                : Icon(
                    _isEmergencyMode
                        ? Icons.local_fire_department_rounded
                        : Icons.restaurant_menu_rounded,
                    size: 20,
                  ),
            label: Text(
              _isEmergencyMode
                  ? '🔌 Generate Gas/Braai/Skottel Recipes'
                  : 'Generate Recipes From My Pantry',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
            style: FilledButton.styleFrom(
              backgroundColor: _isEmergencyMode
                  ? const Color(0xFFE65100)   // deep amber-orange for no-power mode
                  : const Color(0xFFE59B27),
              minimumSize: const Size.fromHeight(52),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            ),
          ),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 36),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _Header(),
              const SizedBox(height: 16),

              // ── Hyper-local context chip row ─────────────────────────────
              _ContextChipRow(
                isEmergencyMode: _isEmergencyMode,
                isBudgetMode:    _isBudgetMode,
                isDataSaver:     _isDataSaver,
                budgetCeiling:   _budgetCeiling,
                onToggleEmergency: _toggleEmergencyMode,
                onToggleBudget:    _toggleBudgetMode,
                onToggleDataSaver: _toggleDataSaver,
              ),

              // ── Combined-mode survival banner ─────────────────────────────
              // Slides in only when BOTH emergency and budget are active,
              // giving clear feedback that the combined constraint is live.
              AnimatedSize(
                duration: const Duration(milliseconds: 260),
                curve:    Curves.easeOut,
                child: (_isEmergencyMode && _isBudgetMode)
                    ? Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: _CombinedModeBanner(
                            budgetCeiling: _budgetCeiling),
                      )
                    : const SizedBox.shrink(),
              ),

              const SizedBox(height: 16),
              _InputCard(
                controller:   _controller,
                focusNode:    _focusNode,
                pantryItems:  _pantryItems,
                enabled:      !loading && !scanning,
                onAdd:        _addIngredient,
                onRemove:     _removeIngredient,
                onClear:      _pantryItems.length > 1 ? _clearPantry : null,
                onScanFridge: _scanFridge,
                onScanGallery: _scanGallery,
              ),
              const SizedBox(height: 28),
              _buildBody(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() => switch (_state) {
        _Idle()                  => _pantryItems.isEmpty
            ? const _EmptyHint()
            : const SizedBox.shrink(),
        _Scanning()              => const _ScanningView(),
        _Loading()               => const _LoadingView(),
        _Errored(:final message) => _ErrorView(message: message),
        _Success(:final recipes) => _ResultsView(
          recipes:             recipes,
          onRegenerate:        _generate,
          onAddToShoppingList: widget.onAddToShoppingList,
        ),
      };
}

// =============================================================================
// Screen state — sealed hierarchy
// =============================================================================

sealed class _ScreenState { const _ScreenState(); }
final class _Idle     extends _ScreenState { const _Idle(); }
final class _Scanning extends _ScreenState { const _Scanning(); }
final class _Loading  extends _ScreenState { const _Loading(); }

final class _Errored extends _ScreenState {
  final String message;
  const _Errored(this.message);
}

final class _Success extends _ScreenState {
  final List<Recipe> recipes;
  const _Success(this.recipes);
}

// =============================================================================
// Header
// =============================================================================

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;

    // Mirrors the Chow Home hero card: cream surface + hairline border +
    // soft avocado shadow layer behind, giving the title block the same
    // "premium card on glass" silhouette used elsewhere in the app.
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          top: 8, left: 8, right: -2, bottom: -2,
          child: Container(
            decoration: BoxDecoration(
              color:        cs.primary.withAlpha(20),
              borderRadius: BorderRadius.circular(24),
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(20, 20, 16, 22),
          decoration: BoxDecoration(
            color:        const Color(0xFFF8F6F1),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: cs.outlineVariant.withAlpha(120),
              width: 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
        // ── Icon row: green kitchen tile on the left, animated pot card
        // on the right. Mirrors the floating waving-hand card layout on
        // the Home screen so the two surfaces feel like one family.
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width:  56,
              height: 56,
              decoration: BoxDecoration(
                color:        cs.primary,
                borderRadius: BorderRadius.circular(18),
                boxShadow: [
                  BoxShadow(
                    color:      cs.primary.withAlpha(60),
                    blurRadius: 18,
                    offset:     const Offset(0, 6),
                  ),
                ],
              ),
              child: Icon(Icons.kitchen_rounded,
                  color: cs.onPrimary, size: 30),
            ),
            const Spacer(),
            const _BubblingPot(size: 56),
          ],
        ),
        const SizedBox(height: 18),
        RichText(
          text: TextSpan(
            // cs.onSurface is charcoal (#222) in light mode and
            // near-white (#E8EDE9) in dark mode — guaranteed contrast.
            style: tt.displaySmall?.copyWith(
              fontWeight: FontWeight.w900,
              color:      cs.onSurface,
              height:     1.1,
            ),
            children: const [
              TextSpan(text: 'Smart '),
              TextSpan(
                text:  'Pantry',
                style: TextStyle(fontStyle: FontStyle.italic),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Text(
          "What's in the fridge? Let's cook!",
          style: tt.titleMedium?.copyWith(
            // Inherit theme body color — onSurfaceVariant is correctly
            // set to graphite in light and a light grey in dark.
            color:      cs.onSurfaceVariant,
            fontWeight: FontWeight.w400,
          ),
        ),
            ],
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// _BubblingPot — header accent card for Smart Pantry
// =============================================================================
//
// Mirrors the exact container tokens (cream-tinted primary surface, 16-radius
// hairline border, 56-size) and motion budget of the Home screen's
// `_WavingHand` so the two header cards feel like one design family.
// The 🍲 pot gently bobs up + down on an easeInOut tween, suggesting a
// simmering boil. ~1500 ms loop with a short pause at the bottom so the
// motion stays subtle and premium rather than busy.

class _BubblingPot extends StatefulWidget {
  const _BubblingPot({this.size = 52});
  final double size;

  @override
  State<_BubblingPot> createState() => _BubblingPotState();
}

class _BubblingPotState extends State<_BubblingPot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync:    this,
    duration: const Duration(milliseconds: 1500),
  )..repeat();

  // -4..+2 px bob — same vertical budget the Home wave uses for its arc.
  late final Animation<double> _dy = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin:  0.0, end: -4.0), weight: 1),
    TweenSequenceItem(tween: Tween(begin: -4.0, end:  2.0), weight: 1),
    TweenSequenceItem(tween: Tween(begin:  2.0, end:  0.0), weight: 1),
    TweenSequenceItem(tween: ConstantTween(0.0),            weight: 1),
  ]).chain(CurveTween(curve: Curves.easeInOut)).animate(_c);

  // Gentle ±0.04 rad rotation in sync with the bob — adds the "lid lift"
  // micro-tilt that reads as steam escaping.
  late final Animation<double> _angle = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin:  0.0,  end:  0.04), weight: 1),
    TweenSequenceItem(tween: Tween(begin:  0.04, end: -0.04), weight: 1),
    TweenSequenceItem(tween: Tween(begin: -0.04, end:  0.0),  weight: 1),
    TweenSequenceItem(tween: ConstantTween(0.0),               weight: 1),
  ]).chain(CurveTween(curve: Curves.easeInOut)).animate(_c);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width:  widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color:        colors.primary.withAlpha(20),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: colors.primary.withAlpha(40),
          width: 1,
        ),
      ),
      alignment: Alignment.center,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) => Transform.translate(
          offset: Offset(0, _dy.value),
          child: Transform.rotate(
            angle:     _angle.value,
            alignment: Alignment.bottomCenter,
            child: const Text('🍲', style: TextStyle(fontSize: 28)),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Input card — text field + wrap of pantry chips
// =============================================================================

class _InputCard extends StatelessWidget {
  const _InputCard({
    required this.controller,
    required this.focusNode,
    required this.pantryItems,
    required this.enabled,
    required this.onAdd,
    required this.onRemove,
    required this.onClear,
    required this.onScanFridge,
    required this.onScanGallery,
  });

  final TextEditingController controller;
  final FocusNode             focusNode;
  final List<String>          pantryItems;
  final bool                  enabled;
  final VoidCallback          onAdd;
  final void Function(String) onRemove;
  final VoidCallback?         onClear;
  final VoidCallback          onScanFridge;
  final VoidCallback          onScanGallery;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Container(
      decoration: BoxDecoration(
        color:        cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(24),
        border:       Border.all(color: cs.outlineVariant),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Section label ──────────────────────────────────────────────────
          Row(
            children: [
              Icon(Icons.egg_alt_outlined, size: 16, color: cs.onSurfaceVariant),
              const SizedBox(width: 6),
              Text(
                'My Pantry Ingredients',
                style: tt.labelLarge?.copyWith(
                  color:        cs.onSurfaceVariant,
                  letterSpacing: 0.2,
                ),
              ),
              if (pantryItems.isNotEmpty) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color:        cs.primaryContainer,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '${pantryItems.length}',
                    style: TextStyle(
                      fontSize:   11,
                      fontWeight: FontWeight.w700,
                      color:      cs.onPrimaryContainer,
                    ),
                  ),
                ),
                const Spacer(),
                if (onClear != null)
                  TextButton(
                    onPressed: enabled ? onClear : null,
                    style: TextButton.styleFrom(
                      foregroundColor: cs.error,
                      textStyle:       tt.labelSmall,
                      padding:         const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      tapTargetSize:   MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('Clear all'),
                  ),
              ],
            ],
          ),

          const SizedBox(height: 12),

          // ── Twin bento tiles — Scan Fridge + Upload from Gallery ───────
          // Equal-width tiles render side-by-side so the two primary "where
          // does my ingredient list come from?" entry points share the same
          // visual weight. Mirrors the bento grid style on Chow Home.
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _PantryActionTile(
                    icon:        Icons.camera_alt_rounded,
                    title:       'Scan Fridge',
                    subtitle:    'AI detects ingredients',
                    accent:      const Color(0xFF0C351E),
                    enabled:     enabled,
                    onTap:       onScanFridge,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _PantryActionTile(
                    icon:        Icons.photo_library_rounded,
                    title:       'From Gallery',
                    subtitle:    'Use an existing photo',
                    accent:      const Color(0xFFE59B27),
                    enabled:     enabled,
                    onTap:       onScanGallery,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 14),

          // ── Manual entry divider ───────────────────────────────────────
          Row(
            children: [
              Expanded(child: Divider(color: cs.outlineVariant.withAlpha(140))),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text(
                  'or type it in',
                  style: tt.labelSmall?.copyWith(
                    color:         cs.onSurfaceVariant,
                    fontWeight:    FontWeight.w700,
                    letterSpacing: 0.6,
                  ),
                ),
              ),
              Expanded(child: Divider(color: cs.outlineVariant.withAlpha(140))),
            ],
          ),

          const SizedBox(height: 10),

          // ── Text input row ─────────────────────────────────────────────────
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller:      controller,
                  focusNode:       focusNode,
                  enabled:         enabled,
                  textCapitalization: TextCapitalization.sentences,
                  textInputAction: TextInputAction.done,
                  onSubmitted:     (_) => onAdd(),
                  style:           tt.bodyMedium,
                  decoration: InputDecoration(
                    hintText: 'e.g. chicken, baby marrow, Maizena…',
                    hintStyle: TextStyle(
                      color: cs.onSurfaceVariant.withAlpha(128),
                    ),
                    filled:      true,
                    fillColor:   cs.surfaceContainerHighest,
                    contentPadding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide:   BorderSide.none,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonal(
                onPressed: enabled ? onAdd : null,
                style: FilledButton.styleFrom(
                  padding:       const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  shape:         RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  minimumSize:   Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Icon(Icons.add_rounded, size: 22),
              ),
            ],
          ),

          // ── Chip wrap ──────────────────────────────────────────────────────
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve:    Curves.easeInOut,
            child: pantryItems.isEmpty
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: Wrap(
                      spacing:    8,
                      runSpacing: 8,
                      children: pantryItems.map((item) => _PantryChip(
                        label:    item,
                        enabled:  enabled,
                        onDelete: () => onRemove(item),
                      )).toList(),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// _PantryActionTile — bento-style entry-point tile used by Scan / Gallery
// =============================================================================
//
// Equal-height card with an accent-coloured icon block, two-line label,
// and a chevron. Two of these sit side-by-side in the InputCard so the
// Smart Pantry "where does my ingredient list come from?" surface reads as
// one uniform deck instead of a stacked pair of mismatched buttons.

class _PantryActionTile extends StatelessWidget {
  const _PantryActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.accent,
    required this.enabled,
    required this.onTap,
  });

  final IconData     icon;
  final String       title;
  final String       subtitle;
  final Color        accent;
  final bool         enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final disabled = !enabled;
    return Opacity(
      opacity: disabled ? 0.6 : 1.0,
      child: Material(
        color:        Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap:        disabled ? null : onTap,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
            decoration: BoxDecoration(
              color:        accent.withAlpha(14),
              borderRadius: BorderRadius.circular(16),
              border:       Border.all(color: accent.withAlpha(60)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 38, height: 38,
                  decoration: BoxDecoration(
                    color:        accent,
                    borderRadius: BorderRadius.circular(11),
                  ),
                  alignment: Alignment.center,
                  child: Icon(icon, color: Colors.white, size: 20),
                ),
                const SizedBox(height: 10),
                Text(
                  title,
                  style: TextStyle(
                    color:      accent,
                    fontSize:   13.5,
                    fontWeight: FontWeight.w900,
                    height:     1.2,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color:    accent.withAlpha(180),
                    fontSize: 11.5,
                    height:   1.3,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Pantry chip
// =============================================================================

class _PantryChip extends StatelessWidget {
  const _PantryChip({
    required this.label,
    required this.enabled,
    required this.onDelete,
  });

  final String     label;
  final bool       enabled;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return InputChip(
      label:           Text(label),
      onDeleted:       enabled ? onDelete : null,
      deleteIcon:      const Icon(Icons.close_rounded, size: 16),
      backgroundColor: const Color(0xFFFFEDE6),   // soft sunset-orange tint
      labelStyle: const TextStyle(
        color:      Color(0xFFE59B27),
        fontWeight: FontWeight.w600,
        fontSize:   13,
      ),
      deleteIconColor: const Color(0xFFE59B27).withAlpha(180),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      side:  const BorderSide(color: Color(0xFFE59B27), width: 0.8),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
    );
  }
}

// =============================================================================
// Empty hint — shown when pantry is empty
// =============================================================================

class _EmptyHint extends StatelessWidget {
  const _EmptyHint();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 36),
      child: Column(
        children: [
          Container(
            width:  80,
            height: 80,
            decoration: BoxDecoration(
              color:        cs.surfaceContainerLow,
              shape:        BoxShape.circle,
              border:       Border.all(color: cs.outlineVariant),
            ),
            child: Icon(Icons.shopping_basket_outlined, size: 36, color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 18),
          Text(
            'Your pantry is empty',
            style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            'Add ingredients you have at home\nand we\'ll find the best recipes for you.',
            textAlign: TextAlign.center,
            style: tt.bodyMedium?.copyWith(
              color:  cs.onSurfaceVariant,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Loading view
// =============================================================================

class _LoadingView extends StatelessWidget {
  const _LoadingView();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        children: [
          SizedBox(
            width:  48,
            height: 48,
            child: CircularProgressIndicator(
              color:      cs.primary,
              strokeWidth: 3,
              strokeCap:  StrokeCap.round,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'Raiding the pantry…',
            style: tt.titleSmall?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          Text(
            'Finding 3 recipes you can make right now',
            style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant.withAlpha(153)),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Error view
// =============================================================================

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Container(
      padding:    const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color:        cs.errorContainer,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(Icons.warning_amber_rounded, color: cs.onErrorContainer, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 200),
                  child: SingleChildScrollView(
                    child: Text(
                      message,
                      style: tt.bodyMedium?.copyWith(color: cs.onErrorContainer, height: 1.5),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: () {
              Clipboard.setData(ClipboardData(text: message));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: const Text('Error copied to clipboard'),
                  behavior: SnackBarBehavior.floating,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              );
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.copy_rounded, size: 14, color: cs.onErrorContainer.withAlpha(180)),
                const SizedBox(width: 5),
                Text(
                  'Copy error',
                  style: tt.bodySmall?.copyWith(
                    color: cs.onErrorContainer.withAlpha(180),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Results view — 3 expandable recipe cards
// =============================================================================

class _ResultsView extends StatelessWidget {
  const _ResultsView({
    required this.recipes,
    required this.onRegenerate,
    this.onAddToShoppingList,
  });

  final List<Recipe>  recipes;
  final VoidCallback  onRegenerate;
  /// Passed straight to each recipe card so the "Add to Shopping List"
  /// CTA can dispatch the recipe's ingredients up to the screen's owner.
  final void Function(List<ShoppingItem>)? onAddToShoppingList;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Results header ─────────────────────────────────────────────────
        Row(
          children: [
            Icon(Icons.auto_awesome_rounded, size: 18, color: cs.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '3 Recipes From Your Pantry',
                style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
            TextButton.icon(
              onPressed: onRegenerate,
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('Regenerate'),
              style: TextButton.styleFrom(
                textStyle: tt.labelMedium,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Tap a recipe to see the full details.',
          style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 16),

        // ── Recipe cards ───────────────────────────────────────────────────
        for (int i = 0; i < recipes.length; i++) ...[
          _PantryRecipeCard(
            number:              i + 1,
            recipe:              recipes[i],
            onAddToShoppingList: onAddToShoppingList,
          ),
          if (i < recipes.length - 1) const SizedBox(height: 12),
        ],
      ],
    );
  }
}

// =============================================================================
// Expandable pantry recipe card
// =============================================================================

class _PantryRecipeCard extends StatefulWidget {
  const _PantryRecipeCard({
    required this.number,
    required this.recipe,
    this.onAddToShoppingList,
  });

  final int    number;
  final Recipe recipe;
  final void Function(List<ShoppingItem>)? onAddToShoppingList;

  @override
  State<_PantryRecipeCard> createState() => _PantryRecipeCardState();
}

class _PantryRecipeCardState extends State<_PantryRecipeCard> {
  bool _expanded = false;
  bool _saving   = false;
  bool _saved    = false;

  /// Pretty date used to seed the shopping-list default name.
  /// e.g. "Pantry List - 14 Jun 2026".
  String _todayLabel() {
    final now = DateTime.now();
    const months = [
      'Jan','Feb','Mar','Apr','May','Jun',
      'Jul','Aug','Sep','Oct','Nov','Dec',
    ];
    return '${now.day} ${months[now.month - 1]} ${now.year}';
  }

  Future<void> _saveRecipe() async {
    if (_saving || _saved) return;

    final chosenName = await _showNamingDialog(
      context:     context,
      isRecipe:    true,
      defaultName: widget.recipe.title,
    );
    if (chosenName == null || !mounted) return;

    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      // Routes through RecipeRepository.saveGeneratedRecipe → writes to
      // the EXISTING `recipes` table (the one My Recipes already reads
      // via updateNotifier). No separate "saved_recipes" table.
      await RecipeRepository.instance.saveGeneratedRecipe(
        chosenName,
        widget.recipe,
      );
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saved  = true;
      });
      messenger.showSnackBar(const SnackBar(
        content:  Text('Recipe successfully saved!'),
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

  Future<void> _addToShoppingList() async {
    final chosenName = await _showNamingDialog(
      context:     context,
      isRecipe:    false,
      defaultName: 'Pantry List - ${_todayLabel()}',
    );
    if (chosenName == null || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      // Creates the parent shopping_lists row then bulk-inserts the
      // line items into shopping_list_items. Best-effort orphan cleanup
      // inside the repository handles partial failures.
      await RecipeRepository.instance.createShoppingListFromIngredients(
        chosenName,
        widget.recipe.ingredients,
      );
      if (!mounted) return;
      messenger.showSnackBar(const SnackBar(
        content:  Text('Added to shopping list!'),
        behavior: SnackBarBehavior.floating,
      ));

      // Also bubble up to the in-memory shopping cart so the Shopping
      // tab reflects the additions instantly — the persisted rows are
      // the source of truth, this is just instant-feedback.
      final cb = widget.onAddToShoppingList;
      if (cb != null) {
        cb([
          for (final ing in widget.recipe.ingredients)
            (() {
              final metric    = formatIngredientMeasure(ing);
              final lastSpace = metric.lastIndexOf(' ');
              final q         = lastSpace < 0
                  ? metric
                  : metric.substring(0, lastSpace);
              final u         = lastSpace < 0
                  ? null
                  : metric.substring(lastSpace + 1);
              return ShoppingItem(
                id:       'pantry_${chosenName.hashCode}_${ing.name.hashCode}_${DateTime.now().microsecondsSinceEpoch}',
                name:     ing.displayName,
                quantity: q.isEmpty ? null : q,
                unit:     u,
              );
            })(),
        ]);
      }
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        content:  Text('Could not save list: $e'),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return GestureDetector(
      onTap: () => setState(() => _expanded = !_expanded),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          color:        cs.surfaceContainerLow,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: _expanded
                ? cs.primary.withAlpha(80)
                : cs.outlineVariant,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Card header (always visible) ─────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Recipe number circle
                  Container(
                    width:  34,
                    height: 34,
                    decoration: BoxDecoration(
                      color:  _expanded ? cs.primary : cs.primaryContainer,
                      shape:  BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '${widget.number}',
                      style: TextStyle(
                        fontSize:   14,
                        fontWeight: FontWeight.w800,
                        color:      _expanded ? cs.onPrimary : cs.onPrimaryContainer,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),

                  // Title
                  Expanded(
                    child: Text(
                      widget.recipe.title,
                      style: tt.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color:      cs.onSurface,
                        height:     1.3,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),

                  // Badges + chevron
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      // Braai badge only when the recipe uses a braai/potjie/fire
                      if (widget.recipe.isBraaiReady) ...[
                        const _BraaiReadyBadge(),
                        const SizedBox(height: 4),
                      ],
                      _LoadsheddingBadge(friendly: widget.recipe.isLoadsheddingFriendly),
                      const SizedBox(height: 6),
                      AnimatedRotation(
                        turns:    _expanded ? 0.5 : 0.0,
                        duration: const Duration(milliseconds: 200),
                        child: Icon(
                          Icons.keyboard_arrow_down_rounded,
                          color: cs.onSurfaceVariant,
                          size: 20,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // ── Expanded recipe body ─────────────────────────────────────
            AnimatedSize(
              duration: const Duration(milliseconds: 280),
              curve:    Curves.easeInOut,
              child: _expanded
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Divider(color: cs.outlineVariant, height: 1),
                          const SizedBox(height: 20),

                          _SectionHeading(
                            icon:  Icons.egg_alt_outlined,
                            label: 'Ingredients',
                            count: widget.recipe.ingredients.length,
                          ),
                          const SizedBox(height: 12),
                          _IngredientsList(ingredients: widget.recipe.ingredients),

                          const SizedBox(height: 24),
                          Divider(color: cs.outlineVariant, height: 1),
                          const SizedBox(height: 24),

                          _SectionHeading(
                            icon:  Icons.menu_book_outlined,
                            label: 'Instructions',
                            count: widget.recipe.instructions.length,
                          ),
                          const SizedBox(height: 12),
                          _InstructionsList(steps: widget.recipe.instructions),

                          // ── Persistent action bar ─────────────────────
                          // Two evenly-split CTAs at the bottom of the
                          // expanded body: primary "Save Recipe" (mango
                          // fill) + outlined "Add to Shopping List". Both
                          // are Expanded so they split the row width
                          // cleanly regardless of label length.
                          const SizedBox(height: 24),
                          Divider(color: cs.outlineVariant, height: 1),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              Expanded(
                                child: FilledButton.icon(
                                  onPressed: (_saving || _saved)
                                      ? null
                                      : _saveRecipe,
                                  icon: _saving
                                      ? const SizedBox(
                                          width: 16, height: 16,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2.2,
                                            color: Colors.white,
                                          ),
                                        )
                                      : Icon(
                                          _saved
                                              ? Icons.check_circle_rounded
                                              : Icons.bookmark_add_outlined,
                                          size: 18,
                                        ),
                                  label: Text(
                                    _saved ? 'Saved' : 'Save Recipe',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w800,
                                        fontSize:   13.5),
                                  ),
                                  style: FilledButton.styleFrom(
                                    backgroundColor: _saved
                                        ? const Color(0xFF2E7D32)
                                        : const Color(0xFFE59B27),
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 12),
                                    shape: RoundedRectangleBorder(
                                      borderRadius:
                                          BorderRadius.circular(14),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: widget.onAddToShoppingList == null
                                      ? null
                                      : _addToShoppingList,
                                  icon: const Icon(
                                      Icons.add_shopping_cart_rounded,
                                      size: 18),
                                  label: const Text(
                                    'Shopping List',
                                    style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                        fontSize:   13),
                                  ),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor:
                                        const Color(0xFF0C351E),
                                    side: const BorderSide(
                                        color: Color(0xFF0C351E),
                                        width: 1.2),
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 12),
                                    shape: RoundedRectangleBorder(
                                      borderRadius:
                                          BorderRadius.circular(14),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Loadshedding badge
// =============================================================================

class _LoadsheddingBadge extends StatelessWidget {
  const _LoadsheddingBadge({required this.friendly});

  final bool friendly;

  static const _greenBg = Color(0xFF0C351E);
  static const _greenFg = Color(0xFF6FCF97);
  static const _greyBg  = Color(0xFF2C2C2E);
  static const _greyFg  = Color(0xFF98989F);

  @override
  Widget build(BuildContext context) {
    final bg    = friendly ? _greenBg : _greyBg;
    final fg    = friendly ? _greenFg : _greyFg;
    // No-Power OK: battery_0_bar shows "zero mains power needed" — works for both
    // raw/cold recipes and explicitly braai/gas-adapted ones.
    final icon  = friendly ? Icons.power_off_rounded : Icons.bolt_rounded;
    final label = friendly ? 'Gas/Braai/No Power Ready' : 'Needs Power';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(22)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: fg, size: 13),
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

// =============================================================================
// Braai Ready badge — shown only when recipe.isBraaiReady is true
// =============================================================================

class _BraaiReadyBadge extends StatelessWidget {
  const _BraaiReadyBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color:        const Color(0xFFBF360C),
        borderRadius: BorderRadius.circular(22),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.outdoor_grill_rounded, color: Colors.white, size: 12),
          SizedBox(width: 4),
          Text(
            'Braai Ready',
            style: TextStyle(
              fontSize:      10,
              fontWeight:    FontWeight.w700,
              color:         Colors.white,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Section heading
// =============================================================================

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({
    required this.icon,
    required this.label,
    required this.count,
  });

  final IconData icon;
  final String   label;
  final int      count;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Row(
      children: [
        Icon(icon, size: 18, color: cs.primary),
        const SizedBox(width: 7),
        Text(label, style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
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
      ],
    );
  }
}

// =============================================================================
// Ingredients list + row
// =============================================================================

class _IngredientsList extends StatelessWidget {
  const _IngredientsList({required this.ingredients});

  final List<Ingredient> ingredients;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color:        cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          for (int i = 0; i < ingredients.length; i++) ...[
            _IngredientRow(ingredient: ingredients[i]),
            if (i < ingredients.length - 1)
              Divider(
                height:     1,
                indent:     16,
                endIndent:  16,
                color:      cs.outlineVariant.withAlpha(128),
              ),
          ],
        ],
      ),
    );
  }
}

class _IngredientRow extends StatelessWidget {
  const _IngredientRow({required this.ingredient});

  final Ingredient ingredient;

  // SA-metric label — cups/tsp/tbsp render as ml/g via the shared
  // formatter so the in-pantry recipe row matches the recipe-detail
  // and shopping-list rendering. _abbreviateUnit is no longer needed
  // because the formatter already emits short labels (g, ml, etc.).
  String get _measure => formatIngredientMeasure(ingredient);

  bool get _isLocalized =>
      ingredient.localizedName != null &&
      ingredient.localizedName!.toLowerCase() != ingredient.name.toLowerCase();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // ── Leading measure ───────────────────────────────────────────
          // ConstrainedBox + IntrinsicWidth grows the column to fit the
          // longest measure string in a row, capped at 96 pt so a freak
          // long unit doesn't crowd out the ingredient name. softWrap:
          // false + ellipsis is the belt-and-braces guarantee against
          // "tablespoon" splitting into "tablespoon s" mid-word.
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 56, maxWidth: 96),
            child: IntrinsicWidth(
              child: Text(
                _measure,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: tt.bodySmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color:      cs.primary,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          // ── Ingredient name (takes the remainder cleanly) ─────────────
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ingredient.displayName,
                  style: tt.bodySmall?.copyWith(fontWeight: FontWeight.w500),
                ),
                if (_isLocalized)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Row(
                      children: [
                        Icon(Icons.swap_horiz_rounded, size: 11, color: cs.tertiary),
                        const SizedBox(width: 3),
                        Flexible(
                          child: Text(
                            'also known as "${ingredient.name}"',
                            style: tt.bodySmall?.copyWith(
                              fontSize:   11,
                              color:      cs.tertiary,
                              fontStyle:  FontStyle.italic,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Instructions list + step
// =============================================================================

class _InstructionsList extends StatelessWidget {
  const _InstructionsList({required this.steps});

  final List<String> steps;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          for (int i = 0; i < steps.length; i++)
            _InstructionStep(
              number: i + 1,
              text:   steps[i],
              isLast: i == steps.length - 1,
            ),
        ],
      );
}

class _InstructionStep extends StatelessWidget {
  const _InstructionStep({
    required this.number,
    required this.text,
    required this.isLast,
  });

  final int    number;
  final String text;
  final bool   isLast;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 38,
            child: Column(
              children: [
                Container(
                  width:  28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: cs.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '$number',
                    style: TextStyle(
                      fontSize:   12,
                      fontWeight: FontWeight.w800,
                      color:      cs.onPrimaryContainer,
                    ),
                  ),
                ),
                if (!isLast)
                  Expanded(
                    child: Container(
                      width:  2,
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      decoration: BoxDecoration(
                        color:        cs.outlineVariant,
                        borderRadius: BorderRadius.circular(1),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : 18, top: 4),
              child: Text(
                text,
                style: tt.bodySmall?.copyWith(height: 1.55),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// _ScanningView — shown while Gemini Vision analyses the photo
// =============================================================================

class _ScanningView extends StatelessWidget {
  const _ScanningView();

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Column(
        children: [
          Container(
            width:  72,
            height: 72,
            decoration: BoxDecoration(
              color:        const Color(0xFF0C351E).withAlpha(15),
              borderRadius: BorderRadius.circular(22),
              border:       Border.all(color: const Color(0xFF0C351E).withAlpha(40)),
            ),
            child: const Icon(Icons.camera_alt_rounded,
                color: Color(0xFF0C351E), size: 34),
          ),
          const SizedBox(height: 20),
          Text(
            'Analyzing ingredients…',
            style: tt.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
              color:      const Color(0xFF0C351E),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'AI is identifying your ingredients',
            style: tt.bodySmall?.copyWith(color: null),
          ),
          const SizedBox(height: 24),
          const CircularProgressIndicator(
            color:       Color(0xFF0C351E),
            strokeWidth: 2.5,
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// _ScanConfirmDialog — post-scan review modal with editable ingredient chips
// =============================================================================
//
// Returns a {action, items} record via Navigator.pop:
//   action  → '__generate__' | '__save__'   (which button the user tapped)
//   items   → the FINAL user-edited list (may differ from the raw scan results)
//
// Returns null when the user dismisses without choosing.

typedef ScanConfirmResult = ({String action, List<String> items});

class _ScanConfirmDialog extends StatelessWidget {
  const _ScanConfirmDialog({required this.scannedResults});

  // Raw scan output handed in by the caller — copied immutably here.
  final List<String> scannedResults;

  static const _kForest = Color(0xFF0C351E);
  static const _kOrange = Color(0xFFE59B27);
  static const _kCream  = Color(0xFFF4F1EA);
  static const _kMuted  = Color(0xFF55534E);

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;

    // Mutable working copy — every chip removal and quick-add appends/removes
    // here, then the buttons return THIS list (not the original scan payload).
    final List<String> editableIngredients = List.from(scannedResults);
    final newItemCtrl = TextEditingController();

    return StatefulBuilder(
      builder: (context, setModalState) {

        // Local helpers — bound to this dialog's setModalState so chip edits
        // trigger immediate localised rebuilds.
        void removeItem(String item) {
          setModalState(() => editableIngredients.remove(item));
        }

        void addItem(String raw) {
          final trimmed = raw.trim();
          if (trimmed.isEmpty) return;
          // Case-insensitive duplicate guard so the user can't accidentally
          // add "Tomato" when "tomato" already exists.
          final lower = trimmed.toLowerCase();
          if (editableIngredients.any((e) => e.toLowerCase() == lower)) {
            newItemCtrl.clear();
            return;
          }
          setModalState(() {
            editableIngredients.add(trimmed);
            newItemCtrl.clear();
          });
        }

        // Keyboard-aware: Dialog normally injects MediaQuery.viewInsets into
        // its insetPadding so it floats above the keyboard, but the hardcoded
        // const value below was stripping that — the cause of the overflow
        // when the "Add item" field summoned the keyboard. Re-add the bottom
        // inset AND shrink the maxHeight by the same amount so the chip list +
        // buttons stay fully on-screen and scrollable.
        final kbInset = MediaQuery.of(context).viewInsets.bottom;
        return Dialog(
          backgroundColor: _kCream,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(28)),
          insetPadding: EdgeInsets.only(
              left: 22, right: 22, top: 28, bottom: 28 + kbInset),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight:
                  (MediaQuery.of(context).size.height - kbInset) * 0.85,
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 22, 22, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [

                  // ── Header ────────────────────────────────────────────
                  Container(
                    width:  60,
                    height: 60,
                    decoration: BoxDecoration(
                      color:        _kForest.withAlpha(20),
                      borderRadius: BorderRadius.circular(18),
                      border:       Border.all(color: _kForest.withAlpha(50)),
                    ),
                    child: const Icon(Icons.camera_alt_rounded,
                        color: _kForest, size: 30),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'Fridge scanned! 🎉',
                    style: tt.titleMedium?.copyWith(
                      fontWeight: FontWeight.w900,
                      color:      _kForest,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    editableIngredients.isEmpty
                        ? 'Add some items below before continuing'
                        : '${editableIngredients.length} '
                          'ingredient${editableIngredients.length == 1 ? '' : 's'} '
                          '— tap × to remove, long-press to save to a shopping list',
                    textAlign: TextAlign.center,
                    style: tt.bodySmall?.copyWith(
                        color: _kMuted, height: 1.4),
                  ),
                  const SizedBox(height: 14),

                  // ── Editable chip list (scrollable when long) ─────────
                  Flexible(
                    child: SingleChildScrollView(
                      child: Wrap(
                        spacing:    8,
                        runSpacing: 6,
                        alignment:  WrapAlignment.center,
                        children: [
                          for (final item in editableIngredients)
                            GestureDetector(
                              // Long-press a chip → save just THAT ingredient
                              // to one of the user's shopping lists.
                              onLongPress: () =>
                                  _addItemsToShoppingList(context, [item]),
                              child: InputChip(
                                key:   ValueKey('chip_$item'),
                                label: Text(
                                  item,
                                  style: const TextStyle(
                                    fontSize:   12,
                                    fontWeight: FontWeight.w600,
                                    color:      _kForest,
                                  ),
                                ),
                                backgroundColor: _kForest.withAlpha(12),
                                side: BorderSide(color: _kForest.withAlpha(40)),
                                deleteIcon: const Icon(
                                  Icons.cancel_rounded,
                                  size:  16,
                                  color: Colors.grey,
                                ),
                                onDeleted: () => removeItem(item),
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                                visualDensity: VisualDensity.compact,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 4, vertical: 0),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 14),

                  // ── Quick-insert input row ─────────────────────────────
                  // Inline TextField + green "+" tile. Submitting via the
                  // keyboard return key OR tapping the tile both append.
                  Container(
                    decoration: BoxDecoration(
                      color:        Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: const Color(0xFFE6E2D8)),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller:         newItemCtrl,
                            textCapitalization: TextCapitalization.sentences,
                            textInputAction:    TextInputAction.done,
                            onSubmitted:        addItem,
                            style: const TextStyle(fontSize: 13),
                            decoration: const InputDecoration(
                              hintText:  '+ Add item (e.g. eggs, butter)',
                              hintStyle: TextStyle(
                                  color: Color(0xFFADADA7), fontSize: 13),
                              border:          InputBorder.none,
                              isDense:         true,
                              contentPadding:
                                  EdgeInsets.symmetric(
                                      horizontal: 14, vertical: 12),
                            ),
                          ),
                        ),
                        GestureDetector(
                          onTap: () => addItem(newItemCtrl.text),
                          child: Container(
                            margin:  const EdgeInsets.all(5),
                            width:   38,
                            height:  36,
                            decoration: BoxDecoration(
                              color:        _kForest,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(Icons.add_rounded,
                                color: Colors.white, size: 18),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 18),

                  // ── Action buttons ─────────────────────────────────────
                  // Both buttons return the FRESH editableIngredients list
                  // (not the original scannedResults) so manual edits flow
                  // into the recipe prompt and the pantry storage.
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: editableIngredients.isEmpty
                          ? null
                          : () => Navigator.pop<ScanConfirmResult>(
                                context,
                                (
                                  action: '__generate__',
                                  items:  List<String>.from(editableIngredients),
                                ),
                              ),
                      icon:  const Icon(Icons.auto_awesome_rounded, size: 18),
                      label: const Text(
                        'Generate Recipe Now!',
                        style: TextStyle(
                            fontWeight: FontWeight.w800, fontSize: 15),
                      ),
                      style: FilledButton.styleFrom(
                        backgroundColor: _kOrange,
                        disabledBackgroundColor:
                            _kOrange.withAlpha(120),
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: editableIngredients.isEmpty
                          ? null
                          : () => Navigator.pop<ScanConfirmResult>(
                                context,
                                (
                                  action: '__save__',
                                  items:  List<String>.from(editableIngredients),
                                ),
                              ),
                      icon: const Icon(Icons.kitchen_rounded,
                          size: 18, color: _kForest),
                      label: const Text(
                        'Add to Pantry',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize:   15,
                          color:      _kForest,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 11),
                        side:    const BorderSide(color: _kForest),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: editableIngredients.isEmpty
                          ? null
                          : () => _addItemsToShoppingList(
                                context,
                                List<String>.from(editableIngredients),
                              ),
                      icon: const Icon(Icons.shopping_basket_rounded,
                          size: 18, color: _kForest),
                      label: const Text(
                        'Add all to Shopping List',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize:   15,
                          color:      _kForest,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 11),
                        side:    const BorderSide(color: _kForest),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

// =============================================================================
// _addItemsToShoppingList — shared picker used by the fridge-scan dialog
// =============================================================================
//
// Opens a bottom sheet listing the user's existing shopping lists. Tapping
// one appends [items] to that list; "Create new list" prompts for a name
// and prepends a fresh list.
//
// Storage: SharedPreferences (`shopping_lists_v1`) — the SAME key the
// ShoppingListScreen reads from. The earlier implementation wrote to the
// `shopping_lists` / `shopping_list_items` Supabase tables, but the
// in-app Shopping tab is SharedPreferences-backed, so those writes were
// invisible to the user (the "items fail to save" symptom in pic 3).
const String _kShoppingListsPrefKey = 'shopping_lists_v1';

/// Bumped by [_writeCachedShoppingLists] on every successful write so that
/// any open ShoppingListScreen — which lives in the hub's IndexedStack and
/// keeps its State alive across tab switches — reloads from SharedPreferences
/// instead of showing the stale snapshot it captured in initState.
///
/// Lives at top-level so the pantry sheet AND the shopping screen can both
/// import the same instance without a circular import.
final ValueNotifier<int> shoppingListsUpdateNotifier = ValueNotifier<int>(0);

Future<List<ShoppingList>> _readCachedShoppingLists() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw   = prefs.getString(_kShoppingListsPrefKey);
    if (raw == null) return <ShoppingList>[];
    final decoded = jsonDecode(raw) as List<dynamic>;
    return decoded
        .map((e) => ShoppingList.fromJson(e as Map<String, dynamic>))
        .toList();
  } catch (_) {
    return <ShoppingList>[];
  }
}

Future<void> _writeCachedShoppingLists(List<ShoppingList> lists) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
    _kShoppingListsPrefKey,
    jsonEncode(lists.map((l) => l.toJson()).toList()),
  );
  // Wake the Shopping tab so it reloads from prefs on the next frame. The
  // shopping screen's State stays alive across tab switches (IndexedStack)
  // so initState's one-shot _loadFromPrefs() never re-fires — without this
  // notifier the user has to kill the app to see the new list.
  shoppingListsUpdateNotifier.value++;
}

Future<void> _addItemsToShoppingList(
  BuildContext context,
  List<String> items,
) async {
  if (items.isEmpty) return;
  final messenger = ScaffoldMessenger.of(context);

  final lists = await _readCachedShoppingLists();
  if (!context.mounted) return;

  final choice = await showModalBottomSheet<_ShoppingListChoice>(
    context: context,
    backgroundColor: const Color(0xFFF4F1EA),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (sheetCtx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 6),
              child: Text(
                'Add to a shopping list',
                style: TextStyle(
                  color:      Color(0xFF0C351E),
                  fontWeight: FontWeight.w900,
                  fontSize:   16,
                ),
              ),
            ),
            const SizedBox(height: 4),
            if (lists.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  'No lists yet — create one to drop these items in.',
                  style: TextStyle(color: Color(0xFF55534E), fontSize: 13),
                ),
              )
            else
              ...lists.map((l) => ListTile(
                    leading: const Icon(Icons.shopping_basket_rounded,
                        color: Color(0xFF0C351E)),
                    title: Text(
                      l.name,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(
                      '${l.items.length} item${l.items.length == 1 ? '' : 's'}',
                      style: const TextStyle(fontSize: 12),
                    ),
                    onTap: () => Navigator.pop(
                      sheetCtx,
                      _ShoppingListChoice.existing(l.id, l.name),
                    ),
                  )),
            const Divider(height: 18),
            ListTile(
              leading: const Icon(Icons.add_circle_outline_rounded,
                  color: Color(0xFFE59B27)),
              title: const Text(
                'Create new list…',
                style: TextStyle(
                  color:      Color(0xFFE59B27),
                  fontWeight: FontWeight.w800,
                ),
              ),
              onTap: () => Navigator.pop(sheetCtx, _ShoppingListChoice.create()),
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    ),
  );
  if (choice == null || !context.mounted) return;

  try {
    String listName;
    // Build ShoppingItem entries up-front — the SA categoriser inside
    // ShoppingItem assigns aisle groups so the Shopping tab can render
    // them under the right "Fruit & Veggies" / "Meat & Fish" / etc.
    final newItems = <ShoppingItem>[
      for (final s in items)
        ShoppingItem(
          id:   'scan_${DateTime.now().microsecondsSinceEpoch}_'
                '${s.hashCode}',
          name: s,
        ),
    ];

    if (choice.kind == _ShoppingListChoiceKind.existing) {
      final current = await _readCachedShoppingLists();
      final idx = current.indexWhere((l) => l.id == choice.listId);
      if (idx < 0) {
        // Fell out of cache between picker open and apply — recreate.
        current.insert(0, ShoppingList(
          id:    choice.listId ?? DateTime.now().millisecondsSinceEpoch.toString(),
          name:  choice.listName ?? 'List',
          items: newItems,
        ));
      } else {
        current[idx].items.addAll(newItems);
      }
      await _writeCachedShoppingLists(current);
      listName = choice.listName!;
    } else {
      // Bottom-sheet prompt (NOT AlertDialog) — the dialog version was
      // getting pinned to the top of the screen by the keyboard inset on
      // tall devices. A bottom sheet rides smoothly up from the bottom
      // edge via AnimatedPadding(viewInsets.bottom), staying visually
      // anchored and never crushing against the status bar.
      final name = await showModalBottomSheet<String>(
        context:              context,
        isScrollControlled:   true,
        backgroundColor:      Colors.transparent,
        builder: (dCtx) {
          final ctrl = TextEditingController();
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
                      'Name your list',
                      style: TextStyle(
                        fontSize:   17,
                        fontWeight: FontWeight.w900,
                        color:      Color(0xFF0C351E),
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller:        ctrl,
                      autofocus:         true,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                        hintText: 'e.g. Weekly braai shop',
                        border:   OutlineInputBorder(),
                      ),
                      onSubmitted: (v) => Navigator.pop(dCtx, v.trim()),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.pop(dCtx, null),
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
                          onPressed: () =>
                              Navigator.pop(dCtx, ctrl.text.trim()),
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF0C351E),
                            foregroundColor: Colors.white,
                            minimumSize:     const Size(72, 44),
                          ),
                          child: const Text(
                            'Create',
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
      if (name == null || name.isEmpty || !context.mounted) return;
      final current = await _readCachedShoppingLists();
      current.insert(0, ShoppingList(
        id:    DateTime.now().millisecondsSinceEpoch.toString(),
        name:  name,
        items: newItems,
      ));
      await _writeCachedShoppingLists(current);
      listName = name;
    }
    messenger.showSnackBar(SnackBar(
      content: Text(items.length == 1
          ? 'Added "${items.first}" to $listName 🛒'
          : 'Added ${items.length} items to $listName 🛒'),
      behavior: SnackBarBehavior.floating,
    ));
  } catch (e) {
    messenger.showSnackBar(SnackBar(
      content:  Text('Could not save to list: $e'),
      behavior: SnackBarBehavior.floating,
    ));
  }
}

enum _ShoppingListChoiceKind { existing, create }

class _ShoppingListChoice {
  final _ShoppingListChoiceKind kind;
  final String? listId;
  final String? listName;
  const _ShoppingListChoice._(this.kind, this.listId, this.listName);
  factory _ShoppingListChoice.existing(String id, String name) =>
      _ShoppingListChoice._(_ShoppingListChoiceKind.existing, id, name);
  factory _ShoppingListChoice.create() =>
      const _ShoppingListChoice._(_ShoppingListChoiceKind.create, null, null);
}

// =============================================================================
// _ScanResultSheet — shows detected ingredients + action choice
// =============================================================================

class _ScanResultSheet extends StatefulWidget {
  const _ScanResultSheet({
    required this.detectedIngredients,
    required this.existingItems,
    this.recipeTitle,
  });

  final List<String> detectedIngredients;
  final List<String> existingItems;

  /// Populated when the scanned image was a labelled recipe card. Null for
  /// a plain fridge / shelf photo. When non-null we render it as the
  /// sheet's primary header and expose a "Save to My Recipes" CTA.
  final String?      recipeTitle;

  @override
  State<_ScanResultSheet> createState() => _ScanResultSheetState();
}

class _ScanResultSheetState extends State<_ScanResultSheet> {

  late final List<bool> _selected;

  @override
  void initState() {
    super.initState();
    // Pre-deselect items already in the pantry; everything else is selected.
    _selected = widget.detectedIngredients
        .map((i) => !widget.existingItems
            .map((e) => e.toLowerCase())
            .contains(i.toLowerCase()))
        .toList();
  }

  List<String> get _chosenItems => [
    for (int i = 0; i < widget.detectedIngredients.length; i++)
      if (_selected[i]) widget.detectedIngredients[i],
  ];

  @override
  Widget build(BuildContext context) {
    final tt     = Theme.of(context).textTheme;
    final bottom = MediaQuery.of(context).padding.bottom;
    final chosen = _chosenItems;
    // Keyboard inset reserved so the scroll content can shrink and the
    // sheet's max height drops by the keyboard height when the soft
    // keyboard appears for any nested input. Without this, the
    // 82% height cap was computed against the full screen and pushed
    // the bottom action row past the keyboard's top edge.
    final kbInset = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      decoration: const BoxDecoration(
        color:        Color(0xFFF4F1EA),
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      constraints: BoxConstraints(
        maxHeight:
            (MediaQuery.of(context).size.height - kbInset) * 0.82,
      ),
      child: Column(
        children: [
          // Drag handle
          Center(
            child: Container(
              margin:     const EdgeInsets.only(top: 12),
              width:      40,
              height:     4,
              decoration: BoxDecoration(
                color:        const Color(0xFFE6E2D8),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),

          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Recipe title (when the scan returned one) ─────────────
                // Renders prominently above the ingredients-found line so
                // the user sees "Chocolate Cake" instead of the generic
                // "Generated from: text" placeholder.
                if (widget.recipeTitle != null &&
                    widget.recipeTitle!.trim().isNotEmpty) ...[
                  Row(
                    children: [
                      const Icon(Icons.menu_book_rounded,
                          color: Color(0xFFE59B27), size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          widget.recipeTitle!.trim(),
                          style: tt.titleLarge?.copyWith(
                            fontWeight: FontWeight.w900,
                            color:      const Color(0xFF0C351E),
                            height:     1.15,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                ],
                Row(
                  children: [
                    const Icon(Icons.check_circle_rounded,
                        color: Color(0xFF0C351E), size: 20),
                    const SizedBox(width: 8),
                    Text(
                      '${widget.detectedIngredients.length} ingredients found',
                      style: tt.titleMedium?.copyWith(
                        fontWeight: FontWeight.w900,
                        color:      const Color(0xFF0C351E),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Select the ones you want, then choose what to do.',
                  style: tt.bodySmall?.copyWith(color: null),
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),
          const Divider(color: Color(0xFFE6E2D8), height: 1),

          // Selectable chip grid
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Wrap(
                spacing:    10,
                runSpacing: 10,
                children: [
                  for (int i = 0; i < widget.detectedIngredients.length; i++)
                    FilterChip(
                      label:    Text(widget.detectedIngredients[i]),
                      selected: _selected[i],
                      onSelected: (v) => setState(() => _selected[i] = v),
                      selectedColor:  const Color(0xFFFFEDE6),
                      checkmarkColor: const Color(0xFFE59B27),
                      labelStyle: TextStyle(
                        color:      _selected[i]
                            ? const Color(0xFFE59B27)
                            : const Color(0xFF55534E),
                        fontWeight: FontWeight.w600,
                        fontSize:   13,
                      ),
                      side: BorderSide(
                        color: _selected[i]
                            ? const Color(0xFFE59B27)
                            : const Color(0xFFE6E2D8),
                        width: 0.8,
                      ),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20)),
                    ),
                ],
              ),
            ),
          ),

          // Action buttons
          Padding(
            padding: EdgeInsets.fromLTRB(20, 8, 20, bottom + 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── Save to Shopping List ───────────────────────────────
                // Sits above "Generate a Recipe" per spec. Routes the picked
                // chips into the same recipe→shopping bottom sheet used by
                // the recipe detail view, so the user can append to an
                // existing list or spin up a brand-new one. The sheet's
                // _saveLists() bumps shoppingListsUpdateNotifier, so the
                // main Shopping Hub re-reads prefs and surfaces the change
                // instantly — no restart, no stale cache.
                FilledButton.icon(
                  onPressed: chosen.isEmpty
                      ? null
                      : () => Navigator.pop(
                            context, ['__save_to_shopping__', ...chosen]),
                  icon:  const Icon(Icons.add_shopping_cart_rounded, size: 20),
                  label: const Text(
                    'Save to Shopping List',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF0C351E),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape:   RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  '${chosen.length} item${chosen.length == 1 ? '' : 's'} selected',
                  style: tt.bodySmall?.copyWith(
                    color: null,
                    fontWeight: FontWeight.w600,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 10),
                // Primary: generate recipe immediately
                FilledButton.icon(
                  onPressed: chosen.isEmpty
                      ? null
                      : () => Navigator.pop(
                            context, ['__generate__', ...chosen]),
                  icon:  const Icon(Icons.restaurant_menu_rounded, size: 20),
                  label: const Text(
                    'Generate a Recipe',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFE59B27),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape:   RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                  ),
                ),
                // ── Save to My Recipes (only when a title was detected) ──
                // Routes the picked ingredients + the AI-extracted title
                // into the Supabase `recipes` table via RecipeRepository,
                // so the scanned card lands in the user's cookbook with
                // exactly one tap.
                if (widget.recipeTitle != null &&
                    widget.recipeTitle!.trim().isNotEmpty) ...[
                  const SizedBox(height: 10),
                  FilledButton.icon(
                    onPressed: chosen.isEmpty
                        ? null
                        : () => Navigator.pop(
                              context, ['__save_recipe__', ...chosen]),
                    icon:  const Icon(Icons.bookmark_add_rounded, size: 20),
                    label: const Text(
                      'Save to My Recipes',
                      style: TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 15),
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF0C351E),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                // Secondary: just add to pantry for later
                OutlinedButton.icon(
                  onPressed: chosen.isEmpty
                      ? null
                      : () =>
                          Navigator.pop(context, ['__save__', ...chosen]),
                  icon:  const Icon(Icons.kitchen_rounded, size: 18),
                  label: const Text(
                    'Save to Pantry',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF0C351E),
                    side:  const BorderSide(color: Color(0xFF0C351E)),
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// _CombinedModeBanner — shown when Emergency + Budget are both active
// =============================================================================

class _CombinedModeBanner extends StatelessWidget {
  const _CombinedModeBanner({required this.budgetCeiling});

  final double budgetCeiling;

  @override
  Widget build(BuildContext context) {
    final cap = 'R${budgetCeiling.toStringAsFixed(0)}';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFE65100), Color(0xFF2E7D32)],
          begin:  Alignment.centerLeft,
          end:    Alignment.centerRight,
        ),
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [
          BoxShadow(
            color:      Color(0x33000000),
            blurRadius: 8,
            offset:     Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        children: [
          const Text('🔥', style: TextStyle(fontSize: 16)),
          const SizedBox(width: 10),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: const TextStyle(
                    color: Colors.white, fontSize: 12.5, height: 1.4),
                children: [
                  const TextSpan(
                    text:  'Survival Mode active  ',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  TextSpan(
                    text: 'Gas/braai only  •  $cap budget',
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color:        Colors.white.withAlpha(35),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Text(
              'BOTH ON',
              style: TextStyle(
                color:      Colors.white,
                fontSize:   10,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// _ContextChipRow — horizontally scrollable filter chips for hyper-local modes
// =============================================================================

class _ContextChipRow extends StatelessWidget {
  const _ContextChipRow({
    required this.isEmergencyMode,
    required this.isBudgetMode,
    required this.isDataSaver,
    required this.budgetCeiling,
    required this.onToggleEmergency,
    required this.onToggleBudget,
    required this.onToggleDataSaver,
  });

  final bool             isEmergencyMode;
  final bool             isBudgetMode;
  final bool             isDataSaver;
  final double           budgetCeiling;
  final VoidCallback     onToggleEmergency;
  final VoidCallback     onToggleBudget;    // async-safe: caller owns dialog
  final VoidCallback     onToggleDataSaver;

  // ── Palette ─────────────────────────────────────────────────────────────────
  static const _kAmberBg     = Color(0xFFFF8F00);
  static const _kAmberSoft   = Color(0xFFFFF3E0);
  static const _kAmberBorder = Color(0xFFFFB300);
  static const _kGreenBg     = Color(0xFF2E7D32);
  static const _kGreenSoft   = Color(0xFFE8F5E9);
  static const _kGreenBorder = Color(0xFF4CAF50);
  static const _kBlueBg      = Color(0xFF0277BD);
  static const _kBlueSoft    = Color(0xFFE1F5FE);
  static const _kBlueBorder  = Color(0xFF29B6F6);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection:            Axis.horizontal,
        padding:                    EdgeInsets.zero,
        physics: const BouncingScrollPhysics(),
        children: [
          _ContextChip(
            emoji:       '🔌',
            label:       isEmergencyMode
                ? 'No-Power ON ✅'
                : 'No Electricity? No Problem!',
            active:      isEmergencyMode,
            activeBg:    _kAmberBg,
            inactiveBg:  _kAmberSoft,
            activeFg:    Colors.white,
            inactiveFg:  const Color(0xFF6D4C00),
            borderColor: _kAmberBorder,
            onTap:       onToggleEmergency,
            tipId:       'no_power',
            tipTitle:    'NO-POWER MODE',
            tipOneLiner: 'Loadshedding? Aunty Chow only cooks on gas, braai or candle-light, my friend. 🔥',
            tipDetails:
                'Switches our recipe AI into off-grid mode — no oven, no microwave, '
                'no air-fryer. Only gas hobs, braai grills, paraffin cookers and no-cook '
                'options stay on the menu. Perfect for Stage 4 surprises, weekend braais '
                'or load-shedding-proof meal planning.',
          ),
          const SizedBox(width: 8),
          _ContextChip(
            emoji:       '🇿🇦',
            label:       isBudgetMode
                ? 'Budget: R${budgetCeiling.toStringAsFixed(0)}'
                : 'Budget Stretch',
            active:      isBudgetMode,
            activeBg:    _kGreenBg,
            inactiveBg:  _kGreenSoft,
            activeFg:    Colors.white,
            inactiveFg:  const Color(0xFF1B5E20),
            borderColor: _kGreenBorder,
            onTap:       onToggleBudget,
            tipId:       'budget_stretch',
            tipTitle:    'BUDGET STRETCH',
            tipOneLiner: 'Bills bly bills — stretch every rand into a full pot. 💰',
            tipDetails:
                'Caps Aunty Chow at your weekly Rand ceiling and biases recipes toward '
                'cheap pantry staples — samp, mielie meal, lentils, soup bones, '
                'in-season veg from Boxer or Shoprite. Tap the chip to set your own '
                'ceiling (R50–R200). Great for end-of-month, big families, or saving '
                'for that braai weekend.',
          ),
          const SizedBox(width: 8),
          _ContextChip(
            emoji:       '📉',
            label:       isDataSaver ? 'Data-Saver ON' : 'Data-Saver',
            active:      isDataSaver,
            activeBg:    _kBlueBg,
            inactiveBg:  _kBlueSoft,
            activeFg:    Colors.white,
            inactiveFg:  const Color(0xFF01579B),
            borderColor: _kBlueBorder,
            onTap:       onToggleDataSaver,
            tipId:       'data_saver',
            tipTitle:    'DATA-SAVER',
            tipOneLiner: 'Last 200 MB on the SIM? We squeeze every byte for you. 📶',
            tipDetails:
                'Trims image uploads, skips decorative hero pictures, and routes our '
                'AI calls through the slimmest payload possible. Made for prepaid '
                'lines, slow Wi-Fi, and that one corner of the house where the signal '
                'just refuses. Cooking ideas still flow — just way lighter on the cap.',
          ),
        ],
      ),
    );
  }
}

/// Session-scoped flags marking which context-chip tooltips have already
/// been shown this app lifecycle. Cleared on full process restart only —
/// no SharedPreferences persistence by design (per spec: "to see the tip
/// again, they must restart the app").
final Set<String> _contextChipTipShown = <String>{};

class _ContextChip extends StatefulWidget {
  const _ContextChip({
    required this.emoji,
    required this.label,
    required this.active,
    required this.activeBg,
    required this.inactiveBg,
    required this.activeFg,
    required this.inactiveFg,
    required this.borderColor,
    required this.onTap,
    required this.tipId,
    required this.tipTitle,
    required this.tipOneLiner,
    required this.tipDetails,
  });

  final String       emoji;
  final String       label;
  final bool         active;
  final Color        activeBg;
  final Color        inactiveBg;
  final Color        activeFg;
  final Color        inactiveFg;
  final Color        borderColor;
  final VoidCallback onTap;

  /// Stable per-pill key into [_contextChipTipShown] — must NOT change with
  /// active state, otherwise toggling the chip would reset the once-per-
  /// session guard.
  final String tipId;
  final String tipTitle;
  final String tipOneLiner;
  final String tipDetails;

  @override
  State<_ContextChip> createState() => _ContextChipState();
}

class _ContextChipState extends State<_ContextChip> {
  final GlobalKey   _chipKey = GlobalKey();
  OverlayEntry?     _bubble;
  Timer?            _bubbleTimer;

  @override
  void dispose() {
    _bubbleTimer?.cancel();
    _bubble?.remove();
    _bubble = null;
    super.dispose();
  }

  void _handleTap() {
    if (!_contextChipTipShown.contains(widget.tipId)) {
      _contextChipTipShown.add(widget.tipId);
      _showBubble();
      // Per spec: first tap shows the tip only — the underlying toggle is
      // deferred to subsequent taps so the user can read the hint before
      // committing.
      return;
    }
    widget.onTap();
  }

  void _showBubble() {
    final ctx = _chipKey.currentContext;
    if (ctx == null) return;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return;
    final origin = box.localToGlobal(Offset.zero);
    final size   = box.size;
    final screenW = MediaQuery.of(context).size.width;

    _bubble?.remove();
    _bubble = OverlayEntry(
      builder: (_) => _ChipTipBubble(
        anchorLeft:   origin.dx,
        anchorTop:    origin.dy,
        anchorWidth:  size.width,
        screenWidth:  screenW,
        title:        widget.tipTitle,
        oneLiner:     widget.tipOneLiner,
        details:      widget.tipDetails,
        accent:       widget.borderColor,
        onExpand: () {
          _bubbleTimer?.cancel();
          _dismissBubble();
          _showExpandedDialog();
        },
        onDismiss:    _dismissBubble,
      ),
    );
    Overlay.of(context, rootOverlay: true).insert(_bubble!);
    _bubbleTimer?.cancel();
    _bubbleTimer = Timer(const Duration(seconds: 3), _dismissBubble);
  }

  void _dismissBubble() {
    _bubbleTimer?.cancel();
    _bubbleTimer = null;
    _bubble?.remove();
    _bubble = null;
  }

  void _showExpandedDialog() {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => _ChipTipDialog(
        title:    widget.tipTitle,
        oneLiner: widget.tipOneLiner,
        details:  widget.tipDetails,
        accent:   widget.borderColor,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bg = widget.active ? widget.activeBg : widget.inactiveBg;
    final fg = widget.active ? widget.activeFg : widget.inactiveFg;
    final active      = widget.active;
    final activeBg    = widget.activeBg;
    final borderColor = widget.borderColor;

    return GestureDetector(
      key:   _chipKey,
      onTap: _handleTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color:        bg,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: active ? activeBg : borderColor.withAlpha(100),
            width: active ? 0 : 1,
          ),
          boxShadow: active
              ? [BoxShadow(color: activeBg.withAlpha(80), blurRadius: 8, offset: const Offset(0, 3))]
              : [],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.emoji, style: const TextStyle(fontSize: 14)),
            const SizedBox(width: 6),
            Text(
              widget.label,
              style: TextStyle(
                fontSize:   13,
                fontWeight: FontWeight.w700,
                color:      fg,
              ),
            ),
            if (active) ...[
              const SizedBox(width: 6),
              Icon(Icons.check_rounded, size: 14, color: fg),
            ],
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// _ChipTipBubble — temporary floating tooltip above a tapped context chip
// =============================================================================

class _ChipTipBubble extends StatefulWidget {
  const _ChipTipBubble({
    required this.anchorLeft,
    required this.anchorTop,
    required this.anchorWidth,
    required this.screenWidth,
    required this.title,
    required this.oneLiner,
    required this.details,
    required this.accent,
    required this.onExpand,
    required this.onDismiss,
  });

  final double       anchorLeft;
  final double       anchorTop;
  final double       anchorWidth;
  final double       screenWidth;
  final String       title;
  final String       oneLiner;
  final String       details;
  final Color        accent;
  final VoidCallback onExpand;
  final VoidCallback onDismiss;

  @override
  State<_ChipTipBubble> createState() => _ChipTipBubbleState();
}

class _ChipTipBubbleState extends State<_ChipTipBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double>   _fade;
  late final Animation<double>   _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _fade  = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _scale = Tween(begin: 0.92, end: 1.0)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutBack));
    _ctrl.forward();
    // Soft fade-out near the end of the 3 s lifespan so the disappearance
    // looks animated rather than instant. The overlay removal itself is
    // owned by the parent _ContextChipState timer.
    Future.delayed(const Duration(milliseconds: 2700), () {
      if (mounted) _ctrl.reverse();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const bubbleW = 240.0;
    final media   = MediaQuery.of(context);
    // Centre over the chip, then clamp to the safe horizontal margin.
    final rawLeft = widget.anchorLeft + widget.anchorWidth / 2 - bubbleW / 2;
    final left    = rawLeft.clamp(12.0, widget.screenWidth - bubbleW - 12.0);
    // Float ~6 px above the chip.
    final top     = widget.anchorTop - 86 - media.padding.top;

    return Positioned(
      left: left,
      top:  top.clamp(media.padding.top + 8, double.infinity),
      child: FadeTransition(
        opacity: _fade,
        child: ScaleTransition(
          scale: _scale,
          alignment: Alignment.bottomCenter,
          child: Material(
            color:        Colors.transparent,
            elevation:    0,
            child: GestureDetector(
              onTap: widget.onExpand,
              child: Container(
                width: bubbleW,
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                decoration: BoxDecoration(
                  color:        const Color(0xFF0C351E),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: widget.accent, width: 1.2),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x55000000),
                      blurRadius: 14,
                      offset: Offset(0, 6),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 6, height: 6,
                          decoration: BoxDecoration(
                            color: widget.accent,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          widget.title,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w900,
                            fontSize: 11.5,
                            letterSpacing: 0.4,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      widget.oneLiner,
                      style: const TextStyle(
                        color: Color(0xFFF4F1EA),
                        fontWeight: FontWeight.w600,
                        fontSize: 12.5,
                        height: 1.3,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Tap to read more',
                      style: TextStyle(
                        color: widget.accent,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// _ChipTipDialog — expanded variant of the bubble, manually dismissed
// =============================================================================

class _ChipTipDialog extends StatelessWidget {
  const _ChipTipDialog({
    required this.title,
    required this.oneLiner,
    required this.details,
    required this.accent,
  });

  final String title;
  final String oneLiner;
  final String details;
  final Color  accent;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF0C351E),
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
      shape: RoundedRectangleBorder(
        side: BorderSide(color: accent, width: 1.4),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 12, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 8, height: 8,
                  decoration: BoxDecoration(
                    color: accent,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                      fontSize: 14,
                      letterSpacing: 0.4,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded, color: Colors.white),
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                oneLiner,
                style: const TextStyle(
                  color: Color(0xFFF4F1EA),
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                  height: 1.35,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                details,
                style: const TextStyle(
                  color: Color(0xFFD9D3C5),
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// _BudgetDialog — shown when user activates Budget Stretch to set the R ceiling
// =============================================================================

class _BudgetDialog extends StatefulWidget {
  const _BudgetDialog({required this.initialCeiling});

  final double initialCeiling;

  @override
  State<_BudgetDialog> createState() => _BudgetDialogState();
}

class _BudgetDialogState extends State<_BudgetDialog> {
  late final TextEditingController _ctrl;

  static const _kForest = Color(0xFF0C351E);
  static const _kCream  = Color(0xFFF4F1EA);
  static const _kGreen  = Color(0xFF2E7D32);

  static const _kPresets = [50.0, 80.0, 100.0, 150.0, 200.0];

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(
      text: widget.initialCeiling.toStringAsFixed(0),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _confirm() {
    final val = double.tryParse(_ctrl.text.trim());
    Navigator.pop(context, val != null && val > 0 ? val : widget.initialCeiling);
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;

    return Dialog(
      backgroundColor: _kCream,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                Container(
                  width: 46, height: 46,
                  decoration: BoxDecoration(
                    color:        _kGreen,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Center(
                    child: Text('🇿🇦', style: TextStyle(fontSize: 22)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Budget Stretch',
                        style: tt.titleMedium?.copyWith(
                          fontWeight: FontWeight.w900,
                          color:      _kForest,
                        ),
                      ),
                      Text(
                        'Set your grocery ceiling',
                        style: tt.bodySmall?.copyWith(
                          color: const Color(0xFF55534E),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),

            const SizedBox(height: 20),

            // Quick-select preset buttons
            Text(
              'Quick select',
              style: tt.labelSmall?.copyWith(
                color:        const Color(0xFF55534E),
                letterSpacing: 0.8,
                fontWeight:   FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8, runSpacing: 8,
              children: _kPresets.map((p) {
                return GestureDetector(
                  onTap: () => setState(() => _ctrl.text = p.toStringAsFixed(0)),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: _kGreen.withAlpha(15),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: _kGreen.withAlpha(60)),
                    ),
                    child: Text(
                      'R${p.toStringAsFixed(0)}',
                      style: const TextStyle(
                        fontSize:   13,
                        fontWeight: FontWeight.w700,
                        color:      _kGreen,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),

            const SizedBox(height: 16),

            // Manual input
            Text(
              'Or enter your own',
              style: tt.labelSmall?.copyWith(
                color:        const Color(0xFF55534E),
                letterSpacing: 0.8,
                fontWeight:   FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller:    _ctrl,
              keyboardType:  const TextInputType.numberWithOptions(decimal: false),
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onSubmitted: (_) => _confirm(),
              decoration: InputDecoration(
                prefixText:     'R ',
                hintText:       '100',
                filled:         true,
                fillColor:      Colors.white,
                contentPadding: const EdgeInsets.fromLTRB(12, 14, 12, 14),
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
                  borderSide:   const BorderSide(color: _kGreen, width: 1.5),
                ),
              ),
            ),

            const SizedBox(height: 24),

            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _confirm,
                style: FilledButton.styleFrom(
                  backgroundColor: _kGreen,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape:   RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                ),
                child: const Text(
                  'Set Budget & Activate',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
//   _showNamingDialog — reusable name-prompt for Save Recipe & Shopping List
// =============================================================================
//
// Opens a clean AlertDialog with a single TextFormField and an inline
// validator. Returns the user's confirmed name (trimmed) on confirm, or
// null on cancel.
//
// Variants:
//   • isRecipe: true  → title "Name Your Recipe",
//                       hint  "e.g., My AI Leftover Potjie",
//                       seed  = the AI's generated title.
//   • isRecipe: false → title "Name Shopping List",
//                       hint  "e.g., Weekend Braai Run",
//                       seed  = "Pantry List - <DD MMM YYYY>" (caller-built).
//
// Validation:
//   • Empty / whitespace-only input  → form invalid, Confirm disabled,
//                                      "Give it a name first" error shown.
//   • Anything else                  → Confirm enabled, returns trimmed
//                                      value on tap.
//
// Lifecycle:
//   The dialog lives in its own StatefulWidget — controller is created in
//   initState() and disposed in dispose(). useRootNavigator: true anchors
//   the dialog to the root Navigator so the _dependents.isEmpty assert
//   that bit us in the chat-edit flow can't recur here.

Future<String?> _showNamingDialog({
  required BuildContext context,
  required bool         isRecipe,
  required String       defaultName,
}) {
  return showDialog<String>(
    context:          context,
    useRootNavigator: true,
    builder:          (_) => _NamingDialog(
      isRecipe:    isRecipe,
      defaultName: defaultName,
    ),
  );
}

class _NamingDialog extends StatefulWidget {
  const _NamingDialog({
    required this.isRecipe,
    required this.defaultName,
  });

  final bool   isRecipe;
  final String defaultName;

  @override
  State<_NamingDialog> createState() => _NamingDialogState();
}

class _NamingDialogState extends State<_NamingDialog> {
  late final TextEditingController _controller;
  final _formKey = GlobalKey<FormState>();

  /// Live validity flag — drives the Confirm button's enabled state.
  /// Updated on every text change so the button reflects the field
  /// without waiting for an explicit Form.validate() pass.
  bool _isValid = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.defaultName);
    _isValid    = widget.defaultName.trim().isNotEmpty;
    _controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    final nowValid = _controller.text.trim().isNotEmpty;
    if (nowValid != _isValid) setState(() => _isValid = nowValid);
  }

  void _confirm() {
    // Final belt-and-braces Form.validate() in case the inline validator
    // catches anything the simple trim check missed.
    if (_formKey.currentState?.validate() != true) return;
    Navigator.of(context).pop(_controller.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.isRecipe ? 'Name Your Recipe'   : 'Name Shopping List';
    final hint  = widget.isRecipe
        ? 'e.g., My AI Leftover Potjie'
        : 'e.g., Weekend Braai Run';
    final label = widget.isRecipe ? 'Recipe name'        : 'List name';
    final cta   = widget.isRecipe ? 'Save Recipe'        : 'Create List';

    return AlertDialog(
      // AlertDialog handles viewInsets internally via its own Padding
      // wrapper. Adding viewInsets.bottom here double-stacked the lift,
      // pushing the modal off the top of the screen when the keyboard
      // opened (44311 / 44330). Use a static insetPadding and let the
      // framework keep the dialog inside the safe area.
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      scrollable:   true,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Text(
        title,
        style: const TextStyle(fontWeight: FontWeight.w800),
      ),
      content: Form(
        key:              _formKey,
        autovalidateMode: AutovalidateMode.onUserInteraction,
        child: TextFormField(
          controller:      _controller,
          autofocus:       true,
          textInputAction: TextInputAction.done,
          onFieldSubmitted: (_) => _isValid ? _confirm() : null,
          decoration: InputDecoration(
            labelText: label,
            hintText:  hint,
            border:    OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          validator: (v) {
            if (v == null || v.trim().isEmpty) {
              return 'Give it a name first.';
            }
            return null;
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          // Disabled when the field is empty — disables the tap target
          // AND visually dims the button so users see why nothing's
          // happening.
          onPressed: _isValid ? _confirm : null,
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFFE59B27),
            disabledBackgroundColor:
                const Color(0xFFE59B27).withValues(alpha: 0.45),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: Text(
            cta,
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
      ],
    );
  }
}
