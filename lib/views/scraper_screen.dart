// lib/views/scraper_screen.dart

import 'dart:async';
import 'dart:math' as math;   // sin() for the loadshedding card waveform
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/ingredient.dart';
import '../models/recipe.dart';
import '../utils/measurement_format.dart';
import '../models/shopping_list.dart';
import '../services/scraper_service.dart';
import '../services/ad_reward_service.dart';
import '../services/notification_center.dart';
import '../services/weather_service.dart';
import '../services/recipe_repository.dart';
import '../state/share_intent_inbox.dart';
import '../state/vegan_mode.dart';
import '../theme/app_theme.dart';
import 'community_feed_screen.dart';
import 'recipe_detail_screen.dart';
import 'meal_planner_screen.dart';
import 'my_recipes_screen.dart';
import '../widgets/smart_suggestions_card.dart';
import 'add_edit_recipe_screen.dart';

// Days used by the meal planner throughout the file.
const _kDays = [
  'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday',
];

// =============================================================================
// Screen — owns all state
// =============================================================================

class ScraperScreen extends StatefulWidget {
  const ScraperScreen({
    super.key,
    this.onAddToShoppingList,
    this.savedRecipes     = const [],
    this.onNavigateToTab,
    this.onOpenInbox,
  });

  final void Function(List<ShoppingItem>)? onAddToShoppingList;
  final List<SavedCommunityRecipe>          savedRecipes;
  final void Function(int tabIndex)?        onNavigateToTab;
  /// Opens the InboxScreen directly (not just switching to Profile tab)
  final VoidCallback?                       onOpenInbox;

  @override
  State<ScraperScreen> createState() => _ScraperScreenState();
}

class _ScraperScreenState extends State<ScraperScreen> {
  final _urlController     = TextEditingController();
  final _rawTextController = TextEditingController();
  final _service           = ScraperService();
  final _adService         = AdRewardService();
  final _picker            = ImagePicker();
  final _scrollController  = ScrollController();

  _ScreenState _state     = const _Idle();
  bool         _isRawMode = false;

  // Localised processing flags — drive the inline spinner anchored inside the
  // existing layout frame so the home page never collapses to a blank state
  // while a link is being scraped or a camera shot is being OCR'd.
  bool _isProcessingLink   = false;
  bool _isProcessingCamera = false;

  // Meal planner — maps each day name to a pinned recipe (null = empty).
  final Map<String, Recipe?> _mealPlan = {for (final d in _kDays) d: null};

  @override
  void initState() {
    super.initState();
    // Listen for URLs shared from Instagram / TikTok / YouTube / etc.
    // via the OS share sheet. When one arrives, drop it into the URL
    // controller and fire the same _submit() path the paste-and-scan
    // button uses — no separate UI flow.
    ShareIntentInbox.instance.pendingSharedUrl
        .addListener(_handleSharedUrl);
    // Cold-start case: a URL was already pending when this widget
    // mounted (app launched via Share). Schedule for next frame so we
    // don't trigger setState during build.
    WidgetsBinding.instance.addPostFrameCallback((_) => _handleSharedUrl());
  }

  void _handleSharedUrl() {
    if (!mounted) return;
    final url = ShareIntentInbox.instance.pendingSharedUrl.value;
    if (url == null || url.isEmpty) return;
    ShareIntentInbox.instance.consume();
    setState(() {
      _isRawMode = false;
      _urlController.text = url;
      _urlController.selection = TextSelection.fromPosition(
          TextPosition(offset: _urlController.text.length));
    });
    unawaited(_submit());
  }

  @override
  void dispose() {
    ShareIntentInbox.instance.pendingSharedUrl
        .removeListener(_handleSharedUrl);
    _urlController.dispose();
    _rawTextController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  // ── Input actions ──────────────────────────────────────────────────────────

  void _toggleMode() => setState(() {
        _isRawMode = !_isRawMode;
        _state = const _Idle();
        if (_isRawMode) _urlController.clear() ; else _rawTextController.clear();
      });

  Future<void> _pasteUrl() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null) {
      setState(() {
        _urlController.text = data!.text!;
        _urlController.selection =
            TextSelection.fromPosition(TextPosition(offset: _urlController.text.length));
      });
    }
  }

  Future<void> _pasteRawText() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null) {
      setState(() {
        _rawTextController.text = data!.text!;
        _rawTextController.selection =
            TextSelection.fromPosition(TextPosition(offset: _rawTextController.text.length));
      });
    }
  }

  // ── Scrape actions ─────────────────────────────────────────────────────────

  /// Validates a user-typed link before it hits the scraper. Accepts bare
  /// hosts ("tiktok.com/...") by prepending https:// for the parse — most
  /// users won't type the scheme. Rejects empty hosts, hosts without a dot,
  /// and anything that isn't http/https.
  bool _isValidUrl(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return false;
    if (s.contains(RegExp(r'\s'))) return false; // spaces → not a URL
    final candidate = s.startsWith(RegExp(r'https?://', caseSensitive: false))
        ? s
        : 'https://$s';
    final uri = Uri.tryParse(candidate);
    if (uri == null || !uri.isAbsolute) return false;
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return false;
    if (uri.host.isEmpty || !uri.host.contains('.')) return false;
    return true;
  }

  Future<void> _submit() async {
    // Early input validation — surface a snackbar and bail BEFORE flipping any
    // processing flags, so the home idle view stays fully interactive.
    if (_isRawMode) {
      if (_rawTextController.text.trim().isEmpty) {
        _showSnack('Paste some recipe text first.');
        return;
      }
    } else {
      final url = _urlController.text.trim();
      if (url.isEmpty || !_isValidUrl(url)) {
        _showSnack('Awe, grab a valid website link first! 🔍');
        return;
      }
    }

    // ── Ad gate ──────────────────────────────────────────────────────────────
    // Per-kind scan quota: 2 free recipe scrapes/day, +1 per rewarded ad
    // up to a hard cap of 4. Separate bucket from camera scans.
    final allowed = await _adService.requestScan(context, ScanKind.recipeScraper);
    if (!allowed) return;   // quota full, user dismissed ad prompt

    // ── Crash-safe processing flag ──────────────────────────────────────────
    // We ONLY flip _isProcessingLink. We deliberately DO NOT touch _state
    // here — keeping it at _Idle ensures _buildBody() keeps returning the
    // permanent home layout. The overlay glass spinner floats on top via
    // the Stack in build(), so the user always sees the cards + grid below.
    setState(() => _isProcessingLink = true);

    try {
      // requestScan above already records the consumed slot in the
      // recipe-scraper bucket — no recordGeneration() here, which would
      // pollute the legacy shared quota used by the pantry generator.
      final Recipe recipe;
      if (_isRawMode) {
        recipe = await _service.parseRawText(_rawTextController.text.trim());
      } else {
        // Normalise: bare hosts get https:// prepended so the scraper
        // doesn't get a non-absolute URI. Validation already passed.
        final raw = _urlController.text.trim();
        final url = raw.startsWith(RegExp(r'https?://', caseSensitive: false))
            ? raw
            : 'https://$raw';
        recipe = await _service.scrapeRecipeFromUrl(url);
      }
      if (mounted) {
        // Push straight to AddEditRecipeScreen — user can review, edit, save
        await _openRecipeEditor(recipe);
      }
    } on ScraperQuotaException catch (_) {
      // ── HTTP 402 — automated reader full ─────────────────────────────────
      // Clear the spinner overlay BEFORE awaiting the dialog so the modal
      // doesn't appear with a CircularProgressIndicator hovering behind it.
      // The dialog routes the user straight to the raw-paste or camera flow.
      // ScraperQuotaException is checked BEFORE the generic ScraperException
      // catch so the superclass branch never wins. Without this ordering the
      // user would just see the friendly-error snackbar.
      if (mounted) setState(() => _isProcessingLink = false);
      if (mounted) await _showReaderFullDialog();
    } on ScraperException catch (e) {
      // Error path: alert message, NO state mutation. Home layout stays
      // mounted underneath; user can immediately try another link.
      if (mounted) _showSnack(_friendlyScraperError(e.message));
    } catch (_) {
      if (mounted) _showSnack(
        "Ah snap, couldn't parse that recipe link, cham! Please try another one.",
      );
    } finally {
      // ALWAYS clear the processing flag, even if an exception slipped past
      // both catch blocks. Prevents the overlay from getting stuck forever.
      // The quota branch above already cleared it pre-dialog; calling setState
      // again here is a harmless no-op.
      if (mounted) setState(() => _isProcessingLink = false);
    }
  }

  // ── "Reader is full" dialog ─────────────────────────────────────────────────
  //
  // Pops when the scraping proxy returns HTTP 402. Two CTAs route the user
  // straight into a working alternative:
  //
  //   • "Paste recipe text"          → flips _isRawMode = true and clears the
  //                                    URL field so the user can immediately
  //                                    paste recipe body text
  //   • "Take a photo of the recipe" → fires the camera scan workflow without
  //                                    requiring an extra tap on the bento card
  Future<void> _showReaderFullDialog() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogCtx) => Dialog(
        backgroundColor: const Color(0xFFF4F1EA),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Illustration container ───────────────────────────────────
              Center(
                child: Container(
                  width:  72,
                  height: 72,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFFE8611A), Color(0xFFFF8F00)],
                      begin: Alignment.topLeft,
                      end:   Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(22),
                    boxShadow: const [
                      BoxShadow(
                        color:      Color(0x3DE8611A),
                        blurRadius: 18,
                        offset:     Offset(0, 6),
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.local_cafe_rounded,
                    color: Colors.white,
                    size:  36,
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // ── Title ─────────────────────────────────────────────────────
              const Text(
                'Aunty Chow is on a tea break ☕',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize:   18,
                  fontWeight: FontWeight.w900,
                  color:      Color(0xFF0C351E),
                ),
              ),
              const SizedBox(height: 10),

              // ── Body copy (spec-exact wording) ───────────────────────────
              const Text(
                'The automated web link reader is temporarily full.\n\n'
                'Please tap below to paste the recipe text directly or take '
                'a quick photo of the cooking instructions!',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize:   13.5,
                  color:      Color(0xFF55534E),
                  height:     1.55,
                ),
              ),
              const SizedBox(height: 24),

              // ── PRIMARY CTA — paste recipe text ──────────────────────────
              FilledButton.icon(
                onPressed: () {
                  Navigator.of(dialogCtx).pop();
                  _switchToRawTextMode();
                },
                icon:  const Icon(Icons.text_snippet_rounded, size: 18),
                label: const Text(
                  'Paste recipe text',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFE59B27),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
              ),
              const SizedBox(height: 10),

              // ── SECONDARY CTA — take a photo ─────────────────────────────
              OutlinedButton.icon(
                onPressed: () {
                  Navigator.of(dialogCtx).pop();
                  _scanWithCamera();
                },
                icon:  const Icon(Icons.photo_camera_rounded, size: 18),
                label: const Text(
                  'Take a photo of the recipe',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF0C351E),
                  side: const BorderSide(color: Color(0xFF0C351E), width: 1.4),
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
              ),
              const SizedBox(height: 4),

              // ── Tertiary — dismiss ───────────────────────────────────────
              TextButton(
                onPressed: () => Navigator.of(dialogCtx).pop(),
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF55534E),
                ),
                child: const Text(
                  'Not now',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Flips the input card into raw-text mode so the user can immediately paste
  /// a recipe body. Used as the dialog's primary CTA when the URL scraper is
  /// exhausted (HTTP 402).
  void _switchToRawTextMode() {
    if (!mounted) return;
    setState(() {
      _isRawMode = true;
      _state     = const _Idle();
      _urlController.clear();
    });
    // Defer to the next frame so the rebuild has wired up the raw text field
    // before we attempt to scroll it into view.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 320),
        curve:    Curves.easeOut,
      );
    });
  }

  // Centralised friendly-message mapper for ScraperException strings.
  String _friendlyScraperError(String raw) {
    final lower = raw.toLowerCase();
    if (lower.contains('quota') ||
        lower.contains('resource_exhausted') ||
        lower.contains('rate limit') ||
        lower.contains('exceeded')) {
      return '⚠️ AI quota reached. Try again in a few minutes.';
    }
    if (lower.contains('api key') ||
        lower.contains('invalid') ||
        lower.contains('unauthorized')) {
      return '⚠️ Invalid API key. Update kGeminiApiKey in env.config.dart.';
    }
    return raw.length > 180 ? '${raw.substring(0, 180)}…' : raw;
  }

  Future<void> _scanWithCamera() async {
    // Wrap pickImage in its own try-catch — a PlatformException is thrown here
    // (not inside the later try block) when camera permission is denied or the
    // device has no camera. Without this guard the exception propagates uncaught
    // and leaves the UI in a blank/broken state.
    XFile? photo;
    try {
      photo = await _picker.pickImage(
        source:       ImageSource.camera,
        imageQuality: 85,
        maxWidth:     1536,
        maxHeight:    1536,
      );
    } catch (e) {
      if (mounted) {
        _showSnack(
          'Camera unavailable — check permissions in your device settings.',
        );
      }
      return;
    }

    if (photo == null || !mounted) return;

    // Flip processing flag only — _state stays at _Idle so the home layout
    // stays mounted under the Stack overlay while OCR runs.
    setState(() => _isProcessingCamera = true);

    try {
      final Uint8List bytes = await photo.readAsBytes();
      final recipe = await _service.scrapeRecipeFromImage(bytes);
      if (mounted) {
        await _openRecipeEditor(recipe);
      }
    } on ScraperQuotaException catch (_) {
      // ── HTTP 402 — OCR proxy quota exhausted ─────────────────────────────
      // Surface the same elegant dialog so the user can pivot to raw paste.
      // (The "take a photo" CTA would lead back here, but the dialog still
      // lets them dismiss or switch to text — graceful degradation.)
      if (mounted) setState(() => _isProcessingCamera = false);
      if (mounted) await _showReaderFullDialog();
    } on ScraperException catch (e) {
      // Snackbar — home layout stays visible the whole time.
      if (mounted) _showSnack(_friendlyScraperError(e.message));
    } catch (_) {
      if (mounted) _showSnack(
        "Ah snap, couldn't read that photo, cham! Try better lighting or a clearer angle.",
      );
    } finally {
      // Always clear the camera flag — guarantees the spinner overlay vanishes
      // regardless of which path (success / known error / unknown error) ran.
      if (mounted) setState(() => _isProcessingCamera = false);
    }
  }

  // ── Reset ──────────────────────────────────────────────────────────────────

  void _reset() => setState(() {
        _state = const _Idle();
        _isRawMode = false;
        _urlController.clear();
        _rawTextController.clear();
      });

  // ── Meal planner ───────────────────────────────────────────────────────────

  void _showDayPicker(Recipe recipe) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => _DayPickerSheet(
        recipe: recipe,
        mealPlan: Map.unmodifiable(_mealPlan),
        onDaySelected: (day) {
          Navigator.pop(sheetCtx);
          setState(() => _mealPlan[day] = recipe);
          _showSnack('$day — pinned to your meal plan!');
        },
      ),
    );
  }

  void _removeMealPlan(String day) => setState(() => _mealPlan[day] = null);

  // ── Snackbar helper ────────────────────────────────────────────────────────

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  /// Pushes the parsed recipe into AddEditRecipeScreen so the user can
  /// review, tweak every field, and save — no more blank home screen.
  Future<void> _openRecipeEditor(Recipe recipe) async {
    if (!mounted) return;
    // Reset home screen back to idle immediately so it looks clean
    // if the user hits Back without saving.
    setState(() {
      _state            = const _Idle();
      _isProcessingLink = false;
    });
    final saved = await Navigator.push<Recipe?>(
      context,
      MaterialPageRoute<Recipe?>(
        fullscreenDialog: true,
        builder: (_) => AddEditRecipeScreen(recipe: recipe),
      ),
    );
    if (saved == null || !mounted) return;

    // ── Persist to Supabase ────────────────────────────────────────────────
    // AddEditRecipeScreen used to pop the Recipe back here without ever
    // hitting the database — the "Recipe saved!" snack lied. Now we run the
    // same RecipeRepository.insert() path used by My Recipes so the scraper
    // and OCR flows actually land a row in `recipes` (cloud) and bump the
    // updateNotifier so dashboards refresh in lockstep.
    try {
      await RecipeRepository.instance.insert(saved, source: 'scraper');
      if (mounted) _showSnack('Recipe saved to My Recipes! 🔥');
    } catch (e) {
      if (mounted) {
        _showSnack('Saved locally only — cloud insert failed ($e)');
      }
    }
  }

  void _showCookbookSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context:            context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _CookbookSheet(recipes: widget.savedRecipes),
    );
  }

  /// Opens the seasonal-dish detail as a full-screen modal sheet. Hosts the
  /// "Save to My Recipes" CTA which inserts a Recipe row into Supabase via
  /// RecipeRepository — same path used by the manual-create flow, so dish
  /// saves participate in the same realtime updateNotifier broadcast.
  void _showSeasonalDishSheet(BuildContext context, _SeasonalDish dish) {
    showModalBottomSheet<void>(
      context:            context,
      isScrollControlled: true,
      useSafeArea:        true,
      backgroundColor:    Colors.transparent,
      builder: (_) => _SeasonalDishDetailSheet(
        dish: dish,
        onSave: (imageUrl) async {
          // Capture the messenger BEFORE any await so we never reach into a
          // dead `context` after the user switches tabs or pops the sheet
          // mid-save. ScaffoldMessengerState survives the route change.
          final navMessenger = ScaffoldMessenger.of(context);

          // Guard the Recipe construction itself — a partially-populated
          // _SeasonalDish (e.g. a future season we haven't filled in yet)
          // would otherwise produce an empty-title row that crashes
          // _recipeFromRow's non-null `row['title']` cast on the next refresh.
          if (dish.name.trim().isEmpty) {
            navMessenger.showSnackBar(SnackBar(
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              content: const Text('This recipe is missing a title — '
                  'cannot save yet.'),
            ));
            return;
          }

          final recipe = Recipe(
            title:                  dish.name,
            ingredients: dish.ingredients
                .map((s) => Ingredient(name: s))
                .toList(growable: false),
            instructions:           List<String>.from(dish.instructions),
            isLoadsheddingFriendly: dish.isLoadsheddingFriendly,
            isBraaiReady:           dish.isBraaiReady,
            imageUrl:               imageUrl,
          );
          try {
            await RecipeRepository.instance
                .insert(recipe, source: 'seasonal-card');
            navMessenger.showSnackBar(SnackBar(
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              content: Text('${dish.name} saved to My Recipes 🔥'),
            ));
          } catch (e) {
            navMessenger.showSnackBar(SnackBar(
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              content: Text('Could not save — $e'),
            ));
          }
        },
      ),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final hasPlannedMeals = _mealPlan.values.any((r) => r != null);

    return Scaffold(
      // Use theme surface so the screen adapts to all 4 ChowSA themes
      // correctly instead of always forcing the Braai Night cream colour.
      backgroundColor: Theme.of(context).colorScheme.surface,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        // Stack: primary build hierarchy + optional inline processing overlay.
        // The scroll view always renders, so the layout never collapses to a
        // blank state — the overlay only sits on top while a flag is true.
        child: Stack(
          children: [
            SingleChildScrollView(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 36),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _HomeHeroCard(
                    savedRecipesCount: widget.savedRecipes.length,
                    onOpenCookbook:    () => _showCookbookSheet(context),
                    onOpenInbox:       widget.onOpenInbox,
                    inboxUnreadCount:  0,
                    // Tapping a seasonal-dish card now opens a full-screen
                    // modal sheet with the dish's ingredients, instructions
                    // and a primary "Save to My Recipes" CTA — replaces the
                    // previous behaviour of dumping the user into the
                    // Community tab (which was unrelated to the dish tapped).
                    onDishTap: (dish) => _showSeasonalDishSheet(context, dish),
                  ),
                  const SizedBox(height: 24),
                  // Show the full InputCard in result/error states (not during
                  // idle or loading — idle has its own embedded URL bar and
                  // loading keeps the idle view visible to avoid a blank screen).
                  if (_state is _Success) ...[
                    _InputCard(
                      urlController:     _urlController,
                      rawTextController: _rawTextController,
                      isRawMode:         _isRawMode,
                      enabled:           true,
                      onPaste:           _isRawMode ? _pasteRawText : _pasteUrl,
                      onSubmit:          _submit,
                      onToggleMode:      _toggleMode,
                      onScan:            _scanWithCamera,
                    ),
                    const SizedBox(height: 28),
                  ],
                  _buildBody(),
                  if (hasPlannedMeals) ...[
                    const SizedBox(height: 36),
                    _MealPlanSection(
                      mealPlan: _mealPlan,
                      onRemove: _removeMealPlan,
                    ),
                  ],
                ],
              ),
            ),

            // ── Layer 2: NON-DESTRUCTIVE LOADING OVERLAY ────────────────────
            // Floats above the permanent layout via the Stack. Never replaces,
            // never unmounts the home view. Catches taps so the user can't
            // double-submit while a request is in flight.
            if (_isProcessingLink || _isProcessingCamera)
              Positioned.fill(
                child: Container(
                  color: Colors.black.withValues(alpha: 0.3),
                  child: Center(
                    child: Card(
                      margin: const EdgeInsets.symmetric(horizontal: 32),
                      elevation: 8,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18)),
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const CircularProgressIndicator(
                              valueColor: AlwaysStoppedAnimation<Color>(
                                  Color(0xFFE59B27)), // ChowSA orange-deep
                            ),
                            const SizedBox(height: 16),
                            Text(
                              _isProcessingCamera
                                  ? 'Aunty Chow is reading your photo…'
                                  : 'Aunty Chow is scraping the recipe detail…',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                color:      Color(0xFF0C351E),
                                fontSize:   14,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // Helper so we don't repeat the HomeIdleView constructor in two branches.
  Widget get _homeIdleView => _HomeIdleView(
        savedRecipes:    widget.savedRecipes,
        onNavigateToTab: widget.onNavigateToTab,
        // "My Recipes" bento tile → full CRUD personal recipe screen.
        // Community saved recipes remain accessible via the header cookbook icon.
        onOpenCookbook:  () => Navigator.push<void>(
          context,
          MaterialPageRoute<void>(
            builder: (_) => const MyRecipesScreen(),
          ),
        ),
        onScanCookbook:  _scanWithCamera,
        onRecipeTap:     (r) => _showRecipeDetail(context, r),
        urlController:   _urlController,
        onPasteUrl:      _pasteUrl,
        onSubmitUrl:     _submit,
        onGenerateByName: _generateRecipeByName,
      );

  // Called from the home "Generate any recipe" card. Hands the typed
  // recipe name to ScraperService and pushes the resulting Recipe into
  // the same review/save flow the URL scraper uses.
  Future<void> _generateRecipeByName(String name) async {
    final allowed = await _adService.requestScan(context, ScanKind.recipeScraper);
    if (!allowed) return;
    setState(() => _isProcessingLink = true);
    try {
      final recipe = await _service.generateRecipeFromName(name);
      if (!mounted) return;
      await _openRecipeEditor(recipe);
    } on ScraperException catch (e) {
      if (mounted) _showSnack(_friendlyScraperError(e.message));
    } catch (_) {
      if (mounted) {
        _showSnack("Couldn't generate that one — try a different recipe name.");
      }
    } finally {
      if (mounted) setState(() => _isProcessingLink = false);
    }
  }

  // ── CRASH-SAFE BODY ROUTER ──────────────────────────────────────────────────
  // The home idle view is the DEFAULT for every non-Success state. _Loading and
  // _Errored both fall through to it so the layout (cards, input box, grid)
  // can never collapse to blank under it. Loading state is communicated via
  // the Stack overlay in build(); errors are communicated via snackbars.
  // Only _Success(recipe) intentionally unmounts the home view — that's the
  // camera-scan flow swapping to the interactive recipe workspace.
  Widget _buildBody() {
    return switch (_state) {
      _Success(:final recipe) => _InteractiveRecipeView(
          recipe:              recipe,
          onReset:             _reset,
          onSchedule:          _showDayPicker,
          onAddToShoppingList: widget.onAddToShoppingList,
        ),
      _ => _homeIdleView,   // _Idle, _Loading, _Errored all share the safe view
    };
  }

  void _showRecipeDetail(BuildContext context, SavedCommunityRecipe recipe) {
    showDialog<void>(
      context: context,
      useRootNavigator: true,
      builder: (_) => _SavedRecipeDetailSheet(recipe: recipe),
    );
  }
}

// =============================================================================
// Screen state — sealed hierarchy
// =============================================================================

sealed class _ScreenState {
  const _ScreenState();
}

final class _Idle extends _ScreenState {
  const _Idle();
}

final class _Success extends _ScreenState {
  final Recipe recipe;
  const _Success(this.recipe);
}

// =============================================================================
// Header — eyebrow (DAY · CITY · TEMP) + animated wave + split headline
// =============================================================================

// =============================================================================
// _HomeHeroCard — new v3.0 hero (replaces _Header)
//
// Asymmetric, layered cream card. Top row keeps the day · time · live-temperature
// metadata strip + inbox bell (proven utility kept intact). Below that, a
// time-of-day adaptive greeting + a soft seasonal-dish chip in the top-right
// corner of the card. Directly below the card sits a full-width horizontal
// carousel of Seasonal SA Dishes — winter potjies → summer chows depending
// on the current month. One featured dish carries a pulsing mango "NEW" badge
// to instantly catch the eye, per the design spec.
//
// Wiring kept from the old _Header:
//   • Timer.periodic(1 minute) live clock — _currentDateTime
//   • StreamBuilder<WeatherReading> bound to WeatherService.instance.stream
//
// Wiring dropped:
//   • The 👋 wave-animation controller — replaced with a static emoji that
//     reads as part of the greeting copy (no extra ticker dependency).
// =============================================================================

class _HomeHeroCard extends StatefulWidget {
  const _HomeHeroCard({
    this.savedRecipesCount = 0,
    this.onOpenCookbook,
    this.onOpenInbox,
    this.inboxUnreadCount = 0,
    this.onDishTap,
  });

  final int                          savedRecipesCount;
  final VoidCallback?                onOpenCookbook;
  final VoidCallback?                onOpenInbox;
  final int                          inboxUnreadCount;
  /// Tapping a seasonal-dish card forwards the dish here so the parent can
  /// route to the community feed, pantry, or a dedicated recipe view.
  final void Function(_SeasonalDish)? onDishTap;

  @override
  State<_HomeHeroCard> createState() => _HomeHeroCardState();
}

class _HomeHeroCardState extends State<_HomeHeroCard> {

  // ── Live clock state ──────────────────────────────────────────────────────
  // Timer.periodic(1 minute) keeps _currentDateTime in lock-step with the
  // device's wall clock — formattedDay flips at midnight, formattedTime
  // refreshes every minute.
  Timer?   _clockTimer;
  DateTime _currentDateTime = DateTime.now();

  // ── Live temperature ──────────────────────────────────────────────────────
  // Temperature is rendered via a StreamBuilder<WeatherReading> bound to
  // WeatherService.instance.stream — the service refreshes every 30 minutes,
  // resolves the user's profile.city → coords, and falls back gracefully
  // through GPS → Cape Town. See lib/services/weather_service.dart.
  //
  // No local state needed here anymore; the StreamBuilder reads
  // WeatherService.instance.latest as its initial frame so there's no
  // '--°C' flash on hot reload once the cache is warm.

  // ── intl-style formatters (no extra dependency) ───────────────────────────
  // DateFormat('EEEE').format(dt).toUpperCase()
  String get formattedDay {
    const days = [
      'MONDAY', 'TUESDAY', 'WEDNESDAY', 'THURSDAY',
      'FRIDAY', 'SATURDAY', 'SUNDAY',
    ];
    return days[_currentDateTime.weekday - 1];
  }

  // DateFormat('HH:mm').format(dt) — 24-hour with zero-padded components
  String get formattedTime =>
      '${_currentDateTime.hour.toString().padLeft(2, '0')}:'
      '${_currentDateTime.minute.toString().padLeft(2, '0')}';

  // ── Time-of-day adaptive greeting (four-bracket spec) ────────────────────
  // 06:00–11:59 → morning  (🍳)
  // 12:00–17:59 → afternoon (🍔)
  // 18:00–23:59 → tonight   (🍲)
  // 00:00–05:59 → early morning (☕)
  //
  // Re-evaluated every minute via the live clock so the greeting flips at
  // each bracket boundary without any extra plumbing.
  ({String copy, String emoji}) get _greetingForHour {
    final h = _currentDateTime.hour;
    if (h >= 6  && h < 12) return (copy: "What's cooking this morning?",   emoji: '🍳');
    if (h >= 12 && h < 18) return (copy: "What's cooking this afternoon?", emoji: '🍔');
    if (h >= 18 && h < 24) return (copy: "What's cooking tonight?",        emoji: '🍲');
    return (copy: "What's cooking this morning?", emoji: '☕');
  }

  String get _greetingCopy  => _greetingForHour.copy;
  String get _greetingEmoji => _greetingForHour.emoji;

  @override
  void initState() {
    super.initState();
    // Live system-clock listener — every 1 min the build re-reads
    // _currentDateTime so the greeting, day string, and time string all
    // flip at the right moments without any extra plumbing.
    _clockTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (!mounted) return;
      setState(() => _currentDateTime = DateTime.now());
    });
    // Temperature is owned by WeatherService — subscribed lazily in build()
    // via StreamBuilder which triggers the first fetch + arms the 30-min
    // refresh timer the first time a subscriber listens.
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text   = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    final season = _SeasonalDish.forMonth(_currentDateTime.month);
    final dishes = _SeasonalDish.rotatingDishesForToday(
      season, _currentDateTime,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [

        // ── Metadata strip (day · time + inbox bell) — page chrome above ──
        // the hero card itself, not card content. Preserves the proven
        // live-clock + WeatherService wiring from the previous _Header.
        _MetadataStrip(
          formattedDay:     formattedDay,
          formattedTime:    formattedTime,
          inboxUnreadCount: widget.inboxUnreadCount,
          onOpenInbox:      widget.onOpenInbox,
        ),

        const SizedBox(height: 18),

        // ══ HERO CARD — asymmetric layered cream surface ══════════════════
        //
        // Two stacked layers:
        //   • Back layer: subtle avocado-green tinted panel offset 8px down +
        //     right — produces the layered-paper depth without a drop shadow.
        //   • Front layer: cream surface (#F8F6F1) with hairline border, the
        //     greeting copy + live temperature line on the left, and a soft
        //     seasonal-emoji square + pulsing mango "NEW" badge on the right.
        Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              top: 8, left: 8, right: -2, bottom: -2,
              child: Container(
                decoration: BoxDecoration(
                  color: colors.primary.withAlpha(20),
                  borderRadius: BorderRadius.circular(22),
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(20, 20, 16, 20),
              decoration: BoxDecoration(
                color:        AppTheme.kAlabaster,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(
                  color: colors.outlineVariant.withAlpha(120),
                  width: 1,
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // WS3: the hero now leads with the spine — cook +
                        // budget — instead of a time-of-day greeting. The
                        // time-of-day copy is demoted to the secondary line
                        // below alongside weather/season so personality stays
                        // intact without burying the promise.
                        Text(
                          'PLAN · COOK · BUDGET',
                          style: text.labelSmall?.copyWith(
                            color:         colors.primary,
                            fontWeight:    FontWeight.w800,
                            letterSpacing: 1.4,
                            fontSize:      10.5,
                          ),
                        ),
                        const SizedBox(height: 8),
                        RichText(
                          text: TextSpan(
                            style: text.displaySmall?.copyWith(
                              fontWeight:    FontWeight.w900,
                              color:         colors.onSurface,
                              height:        1.05,
                              letterSpacing: -0.8,
                              fontSize:      28,
                            ),
                            children: [
                              const TextSpan(
                                text: 'Plan the week. Know the cost '
                                      'before you shop.',
                              ),
                              TextSpan(
                                text:  '  $_greetingEmoji',
                                style: const TextStyle(fontSize: 24),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        // Secondary line — greeting + weather + seasonal blurb.
                        // Keeps the Mzansi voice and the live WeatherService
                        // signal while the headline above carries the spine.
                        StreamBuilder<WeatherReading>(
                          stream:      WeatherService.instance.stream,
                          initialData: WeatherService.instance.latest,
                          builder: (_, snap) {
                            final reading = snap.data;
                            final tail = reading == null
                                ? '${season.shortBlurb}.'
                                : '${season.shortBlurb} · '
                                  '${reading.locationLabel} ${reading.formatted}';
                            return Text(
                              '$_greetingCopy  ·  $tail',
                              style: text.bodySmall?.copyWith(
                                color:  colors.onSurfaceVariant,
                                height: 1.5,
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      // Animated waving-hand greeting — restores the classic
                      // 👋 wave that used to ride alongside the greeting copy.
                      // Containerized in the cream-on-green illustrative style
                      // used across the app so the icon feels native to the
                      // Mzansi Organic Luxury palette.
                      const _WavingHand(size: 52),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),

        const SizedBox(height: 14),

        // ── Weekly Meal Planner — primary green hero ─────────────────────
        // Promoted right under the welcome card so "Plan the week" is the
        // single most visible action on Home. The old Weekly Budget card
        // that lived here was removed (it was decorative — never wired
        // into anything else); per-list budgets cover that need today.
        _MealPlannerBanner(),

        const SizedBox(height: 14),

        // ── Vegan-mode toggle ─────────────────────────────────────────────
        // Compact pill, full-width-friendly. When ON every scraped /
        // generated recipe automatically swaps out meat / dairy / eggs
        // for SA-available vegan alternatives. Lives on the home hero
        // so it's always one tap away (not buried in settings).
        const _VeganModePill(),

        const SizedBox(height: 22),

        // ══ SEASONAL DISH CAROUSEL ════════════════════════════════════════
        Row(
          children: [
            Text(
              'Seasonal in SA right now',
              style: text.titleSmall?.copyWith(
                fontWeight: FontWeight.w800,
                color:      colors.onSurface,
              ),
            ),
            const SizedBox(width: 6),
            Text(season.emoji, style: const TextStyle(fontSize: 14)),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          // Bumped from 152 → 168 to accommodate the power-status chip row
          // added under the tag line. The previous height clipped the chip
          // by ~5 px and tripped the RenderFlex overflow stripe.
          height: 168,
          child: ListView.separated(
            scrollDirection:  Axis.horizontal,
            physics:          const BouncingScrollPhysics(),
            padding:          const EdgeInsets.symmetric(horizontal: 2),
            itemCount:        dishes.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder:      (_, i) => _SeasonalDishCard(
              dish:     dishes[i],
              featured: i == 0,
              onTap:    () => widget.onDishTap?.call(dishes[i]),
            ),
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// _WavingHand — containerized illustrative 👋 with a gentle shake animation
// =============================================================================
//
// Wraps the waving-hand emoji in the same cream-on-green tile silhouette used
// for the other illustrative icons across ChowSA. The hand rocks between
// -18°…+18° on an ease-in-out tween, pauses briefly, then loops — the same
// physical motion of an actual wave hello.
//
// Animation budget sits at 1500ms one full wave cycle (4 swings × 250ms each
// + 500ms rest) so the motion stays cheerful without becoming distracting.

class _WavingHand extends StatefulWidget {
  const _WavingHand({this.size = 52});

  final double size;

  @override
  State<_WavingHand> createState() => _WavingHandState();
}

class _WavingHandState extends State<_WavingHand>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync:    this,
    duration: const Duration(milliseconds: 1500),
  )..repeat();

  late final Animation<double> _angle = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 0.0,   end:  0.32), weight: 1),
    TweenSequenceItem(tween: Tween(begin: 0.32,  end: -0.32), weight: 1),
    TweenSequenceItem(tween: Tween(begin: -0.32, end:  0.32), weight: 1),
    TweenSequenceItem(tween: Tween(begin: 0.32,  end:  0.0 ), weight: 1),
    // Pause at rest for a beat so the wave reads as a discrete greeting.
    TweenSequenceItem(tween: ConstantTween(0.0),              weight: 2),
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
        animation: _angle,
        builder: (_, __) => Transform.rotate(
          angle: _angle.value,
          // Pivot from the wrist so the wave reads naturally.
          alignment: Alignment.bottomCenter,
          child: const Text('👋', style: TextStyle(fontSize: 28)),
        ),
      ),
    );
  }
}

// =============================================================================
// _MetadataStrip — page-chrome day/time + inbox bell sitting ABOVE the hero
// =============================================================================

class _MetadataStrip extends StatelessWidget {
  const _MetadataStrip({
    required this.formattedDay,
    required this.formattedTime,
    required this.inboxUnreadCount,
    this.onOpenInbox,
  });

  final String        formattedDay;
  final String        formattedTime;
  final int           inboxUnreadCount;
  final VoidCallback? onOpenInbox;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Row(
            children: [
              Text(
                formattedDay,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize:   13,
                  color:      colors.onSurface,
                  letterSpacing: 0.8,
                ),
              ),
              Text(
                '  ·  ',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize:   13,
                  color:      colors.onSurfaceVariant.withAlpha(120),
                ),
              ),
              Text(
                formattedTime,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize:   13,
                  color:      colors.onSurface,
                ),
              ),
            ],
          ),
        ),
        // Home Screen inbox icon — observes the SAME notifier as the
        // Profile Screen bell so the dual-location badge sync is
        // automatic. The markAllRead() flip lives in
        // InboxScreen.initState (lifecycle-driven) so it triggers
        // regardless of which icon opened the inbox; this icon just
        // navigates. Both badges clear in the same frame because they
        // both listen to the same ValueNotifier.
        AnimatedBuilder(
          // NotificationCenter and NotificationsFeedService are both
          // facades pointing at the SAME underlying
          // InboxController.unreadCount — summing them double-counted
          // every unread row (1 unread rendered as "2"). Listen once,
          // read once, same pattern as the Profile bell.
          animation: NotificationCenter.instance.unreadCount,
          builder: (_, __) {
            final unread =
                NotificationCenter.instance.unreadCount.value;
            return Stack(
            clipBehavior: Clip.none,
            children: [
              GestureDetector(
                onTap: () => onOpenInbox?.call(),
                child: Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color:        colors.surfaceContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.mail_outline_rounded,
                    color: colors.primary,
                    size:  20,
                  ),
                ),
              ),
              if (unread > 0)
                Positioned(
                  right: -4, top: -4,
                  child: Container(
                    constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: colors.secondary,
                      shape: unread < 10 ? BoxShape.circle : BoxShape.rectangle,
                      borderRadius: unread < 10
                          ? null
                          : BorderRadius.circular(8),
                      border: Border.all(
                        color: Theme.of(context).scaffoldBackgroundColor,
                        width: 1.5,
                      ),
                    ),
                    child: Text(
                      '$unread',
                      style: TextStyle(
                        color:      colors.onSecondary,
                        fontSize:   9,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ),
            ],
          );
          },
        ),
      ],
    );
  }
}

// =============================================================================
// _SeasonalDish — SA-season data + month helper
// =============================================================================

enum _Season { summer, autumn, winter, spring }

extension _SeasonExt on _Season {
  // Was the hero eyebrow pre-WS3; kept for the seasonal-dish detail sheet.
  // ignore: unused_element
  String get eyebrow => switch (this) {
        _Season.summer => 'Summer in Mzansi',
        _Season.autumn => 'Autumn comfort',
        _Season.winter => 'Winter warmers',
        _Season.spring => 'Spring flavours',
      };
  String get emoji => switch (this) {
        _Season.summer => '🌞',
        _Season.autumn => '🍂',
        _Season.winter => '🔥',
        _Season.spring => '🌿',
      };
  String get shortBlurb => switch (this) {
        _Season.summer => 'Fresh, cold and braai-ready',
        _Season.autumn => 'Warm spice, slow cooking',
        _Season.winter => 'Slow-cooked, deeply warming',
        _Season.spring => 'Light, herbed, fragrant',
      };
}

class _SeasonalDish {
  const _SeasonalDish({
    required this.emoji,
    required this.name,
    required this.tag,
    required this.gradientStart,
    required this.gradientEnd,
    this.ingredients = const <String>[],
    this.instructions = const <String>[],
    this.isBraaiReady = false,
    this.isLoadsheddingFriendly = false,
    this.needsElectricity = false,
    this.blurb,
  });

  final String emoji;
  final String name;
  final String tag;
  final Color  gradientStart;
  final Color  gradientEnd;

  // Optional recipe metadata used by the detail bottom sheet's "Save to My
  // Recipes" button. Empty by default so any season we haven't fully filled
  // in yet still renders the metadata-only card; saving from those defaults
  // to a sensible "TODO: fill in" stub the user can edit afterwards.
  final List<String> ingredients;
  final List<String> instructions;
  /// True when the dish can be cooked over coals / a braai grid.
  final bool         isBraaiReady;
  /// True when the dish works on a gas hob (or otherwise survives a
  /// loadshedding window without grid power). Independent of isBraaiReady
  /// — a potjie is BOTH braai-ready AND loadshedding-friendly.
  final bool         isLoadsheddingFriendly;
  /// True when the dish strictly requires grid electricity (oven, electric
  /// stove only, microwave). Mutually exclusive with the two above — if
  /// this is true, the power-status badge will render as "Needs Electricity".
  final bool         needsElectricity;
  final String?      blurb;

  /// Single resolved power-status badge per dish, in priority order:
  ///   1. Braai-ready  → 🔥 "Braai/Gas Ready"
  ///   2. Loadshedding → ⚡ "Load-Shedding Friendly"
  ///   3. Electricity  → 🔌 "Needs Electricity"
  /// Returns null when nothing's flagged so the card stays clean.
  _PowerBadge? get powerBadge {
    if (isBraaiReady)           return _PowerBadge.braai;
    if (isLoadsheddingFriendly) return _PowerBadge.loadshedding;
    if (needsElectricity)       return _PowerBadge.electricity;
    return null;
  }

  /// SA season by month — southern hemisphere.
  static _Season forMonth(int month) {
    if (month >= 12 || month <= 2) return _Season.summer;
    if (month >= 3 && month <= 5)  return _Season.autumn;
    if (month >= 6 && month <= 8)  return _Season.winter;
    return _Season.spring;
  }

  /// Carousel rotation — picks 5 dishes from the season's pool, deterministic
  /// by (day-of-year ÷ 3), so the same 5 dishes show for 3 days at a time
  /// and then swap to a fresh subset on day 4.
  static List<_SeasonalDish> rotatingDishesForToday(
    _Season s, DateTime now,
  ) {
    final pool = dishesForSeason(s);
    if (pool.length <= 5) return pool;
    // 3-HOUR ROTATION — same 3-hour block across the entire app on a given
    // date+block boundary (00:00–02:59, 03:00–05:59, … 21:00–23:59). Drives
    // a fresh feel without thrashing the user — eight rotations per day.
    final block = now.hour ~/ 3;
    final seed = int.parse(
      '${now.year}'
      '${now.month.toString().padLeft(2, '0')}'
      '${now.day.toString().padLeft(2, '0')}'
      '$block',
    );
    final copy = List<_SeasonalDish>.from(pool)
      ..shuffle(math.Random(seed));
    return copy.take(5).toList(growable: false);
  }

  static List<_SeasonalDish> dishesForSeason(_Season s) {
    switch (s) {
      case _Season.summer:
        return const [
          _SeasonalDish(emoji: '🍉', name: 'Watermelon Feta Salad',
            tag: 'cold · 10 min',
            gradientStart: Color(0xFFFFD2D6), gradientEnd: Color(0xFFFF8A95)),
          _SeasonalDish(emoji: '🍢', name: 'Lamb Sosaties',
            tag: 'braai · marinated',
            gradientStart: Color(0xFFFFCC99), gradientEnd: Color(0xFFD27D38)),
          _SeasonalDish(emoji: '🌽', name: 'Mealie Pap & Chakalaka',
            tag: 'spicy · feeds 4',
            gradientStart: Color(0xFFFFE08A), gradientEnd: Color(0xFFE89A1A)),
          _SeasonalDish(emoji: '🥪', name: 'Braai Broodjies',
            tag: 'classic · 15 min',
            gradientStart: Color(0xFFFFE2B8), gradientEnd: Color(0xFFD68A35)),
          _SeasonalDish(emoji: '🥗', name: 'Avo & Biltong Bowl',
            tag: 'no cook · protein',
            gradientStart: Color(0xFFCDE2C6), gradientEnd: Color(0xFF5B8E5C)),
          // ── Vegan rotation entries ─────────────────────────────────
          _SeasonalDish(
            emoji: '🥑', name: 'Vegan Avo-Lime Bowl',
            tag: 'vegan · no cook · 10 min',
            gradientStart: Color(0xFFDDF1CF), gradientEnd: Color(0xFF6C9C53),
            isLoadsheddingFriendly: true,
            blurb: 'Cold protein bowl built on chickpeas, ripe avo, lime '
                   'juice and a hit of fresh coriander. Zero stove time.',
            ingredients: [
              '2 ripe avocados, cubed',
              '1 tin chickpeas, drained and rinsed',
              '1 cup cherry tomatoes, halved',
              '1 cup cooked brown rice (cold)',
              '½ cup cucumber, diced',
              '¼ cup red onion, finely sliced',
              '2 tbsp lime juice (or lemon)',
              '2 tbsp olive oil',
              '1 small bunch coriander, chopped',
              'Salt and black pepper to taste',
            ],
            instructions: [
              'Toss the cooked rice with olive oil, lime juice, salt and pepper.',
              'Layer rice in two bowls.',
              'Top with chickpeas, avo, tomatoes, cucumber and red onion.',
              'Scatter coriander; squeeze over extra lime; serve cold.',
            ],
          ),
          _SeasonalDish(
            emoji: '🍉', name: 'Watermelon-Mint Granita',
            tag: 'vegan · cold · 5 min prep',
            gradientStart: Color(0xFFFFC8CE), gradientEnd: Color(0xFFD05A6E),
            isLoadsheddingFriendly: true,
            blurb: 'Three-ingredient summer pudding. Freeze 3 hours, '
                   'scrape into icy flakes, serve in glasses with mint.',
            ingredients: [
              '6 cups watermelon, deseeded and cubed',
              '2 tbsp lime juice',
              '2 tbsp maple syrup (or agave)',
              '10 fresh mint leaves',
              'Pinch of sea salt',
            ],
            instructions: [
              'Blend watermelon, lime juice, maple syrup, mint and salt smooth.',
              'Pour into a shallow tray (about 2 cm deep).',
              'Freeze 1 hour, then fork-scrape; repeat every 45 min for 3 hours.',
              'Serve in chilled glasses with extra mint and a lime wedge.',
            ],
          ),
        ];
      case _Season.autumn:
        return const [
          _SeasonalDish(emoji: '🍛', name: 'Cape Malay Curry',
            tag: 'warm spice · 45 min',
            gradientStart: Color(0xFFFFD0A8), gradientEnd: Color(0xFFB35A1F)),
          _SeasonalDish(emoji: '🥧', name: 'Bobotie',
            tag: 'baked · 60 min',
            gradientStart: Color(0xFFFFD89A), gradientEnd: Color(0xFFA76327)),
          _SeasonalDish(emoji: '🍖', name: 'Peri-Peri Chicken',
            tag: 'fiery · 35 min',
            gradientStart: Color(0xFFFFB8A0), gradientEnd: Color(0xFFC8543A)),
          _SeasonalDish(emoji: '🌽', name: 'Samp & Beans',
            tag: 'umngqusho · slow',
            gradientStart: Color(0xFFE8DCC0), gradientEnd: Color(0xFF8A7B5A)),
          _SeasonalDish(emoji: '🍞', name: 'Roosterkoek',
            tag: 'braai-grilled bread',
            gradientStart: Color(0xFFF3D9B0), gradientEnd: Color(0xFFB4854A)),
          // ── Vegan rotation entries ─────────────────────────────────
          _SeasonalDish(
            emoji: '🌱', name: 'Vegan Lentil Bobotie',
            tag: 'vegan · baked · 50 min',
            gradientStart: Color(0xFFE5D7AC), gradientEnd: Color(0xFF8C7234),
            blurb: 'Plant-based take on the SA classic. Brown lentils carry '
                   'the spice, oat-milk + chickpea-flour custard sets golden.',
            ingredients: [
              '2 cups cooked brown lentils',
              '1 onion, finely chopped',
              '2 garlic cloves, crushed',
              '1 tbsp Cape Malay curry powder',
              '1 tsp ground turmeric',
              '1 tsp ground cumin',
              '2 slices bread soaked in ½ cup oat milk',
              '2 tbsp chutney (Mrs Ball\'s)',
              '2 tbsp raisins',
              '2 tbsp olive oil',
              '½ cup oat milk + 2 tbsp chickpea flour (custard)',
              '2 bay leaves',
              'Salt and pepper to taste',
            ],
            instructions: [
              'Preheat oven to 180 °C.',
              'Soften onion and garlic in olive oil over medium heat (6 min).',
              'Toast curry powder, turmeric and cumin in the pan for 30 sec.',
              'Mash in the soaked bread, lentils, chutney and raisins; season.',
              'Spoon into a greased baking dish; top with bay leaves.',
              'Whisk oat milk + chickpea flour smooth; pour over the lentils.',
              'Bake 30 min until the custard sets golden brown.',
              'Serve with yellow rice and sambals.',
            ],
          ),
          _SeasonalDish(
            emoji: '🍛', name: 'Chickpea Cape Curry',
            tag: 'vegan · 35 min',
            gradientStart: Color(0xFFFFD4A8), gradientEnd: Color(0xFFAC6826),
            isLoadsheddingFriendly: true,
            blurb: 'Silky stovetop curry — chickpeas finished in oat-milk + '
                   'mild Robertsons masala. Serve with rice or fresh roti.',
            ingredients: [
              '2 tins chickpeas, drained',
              '1 onion, sliced',
              '3 garlic cloves, crushed',
              '1 thumb ginger, grated',
              '2 tbsp Robertsons mild curry powder',
              '1 tsp ground cumin',
              '1 tin chopped tomatoes',
              '1 cup oat milk',
              '2 tbsp sunflower oil',
              'Fresh coriander, to finish',
              'Salt to taste',
            ],
            instructions: [
              'Heat oil in a pot; sauté onion, garlic and ginger until soft.',
              'Toast curry powder and cumin for 30 sec — keep stirring.',
              'Add chopped tomatoes; simmer 5 min until the colour deepens.',
              'Tip in chickpeas; stir to coat in the masala.',
              'Pour in oat milk; simmer gently for 15 min until silky.',
              'Season; top with coriander; serve with rice or roti.',
            ],
          ),
        ];
      case _Season.winter:
        // ── SA WINTER (June) ROTATION ───────────────────────────────────────
        // Hardcoded comfort-food set: stews, potjies, soups, bakes. Each
        // dish ships with a real ingredient + instruction template so the
        // "Save to My Recipes" button in the detail sheet inserts something
        // useful instead of an empty stub. Every dish carries an explicit
        // power-status flag (braai / loadshedding-friendly / electricity)
        // so the card can render the right badge.
        return const [
          _SeasonalDish(
            emoji: '🍲', name: 'Lamb Potjie',
            tag: 'slow-cooked · 4 hrs',
            gradientStart: Color(0xFFD4C0A0), gradientEnd: Color(0xFF6B5235),
            isBraaiReady: true,
            isLoadsheddingFriendly: true,
            blurb: 'Three-legged pot, slow-cooked over coals. The classic '
                   'winter braai-side that doesn\'t need stirring.',
            ingredients: [
              '1.5 kg lamb knuckles',
              '2 onions, sliced',
              '4 carrots, chunked',
              '6 baby potatoes, halved',
              '2 cups beef stock (Knorrox)',
              '2 tbsp tomato paste',
              '2 tsp potjie spice',
              'Salt, pepper, fresh thyme',
            ],
            instructions: [
              'Brown the lamb in the potjie over hot coals.',
              'Layer onions, carrots, then potatoes on top — do not stir.',
              'Pour stock and tomato paste over the top.',
              'Cover and simmer over low coals for 3 to 4 hours, untouched.',
              'Season at the end with salt, pepper and fresh thyme.',
            ],
          ),
          _SeasonalDish(
            emoji: '🥘', name: 'Oxtail Stew',
            tag: 'rich · 3 hrs',
            gradientStart: Color(0xFFCFA88A), gradientEnd: Color(0xFF6B3924),
            isLoadsheddingFriendly: true,
            blurb: 'Rich, falling-off-the-bone oxtail in a deep red wine '
                   'gravy. Cook on a gas hob if the grid drops. Serve with '
                   'samp or buttery mash.',
            ingredients: [
              '1.5 kg oxtail, jointed',
              '2 onions, finely chopped',
              '3 garlic cloves, crushed',
              '1 cup red wine',
              '2 cups beef stock',
              '1 tin (410 g) chopped tomatoes',
              '2 bay leaves',
              'Cake flour for dusting, oil, salt, pepper',
            ],
            instructions: [
              'Dust the oxtail in seasoned cake flour.',
              'Brown in batches in a heavy pot, then set aside.',
              'Soften onions and garlic in the same pot.',
              'Deglaze with red wine, scraping the brown bits.',
              'Add tomatoes, stock and bay leaves; return the oxtail.',
              'Simmer covered for 2.5 to 3 hours until the meat slides off.',
            ],
          ),
          _SeasonalDish(
            emoji: '🍞', name: 'Soup & Vetkoek',
            tag: 'cosy · 40 min',
            gradientStart: Color(0xFFF0CFA0), gradientEnd: Color(0xFFB57D2E),
            isLoadsheddingFriendly: true,
            blurb: 'Thick vegetable soup paired with fluffy, deep-fried '
                   'vetkoek — the ultimate Mzansi winter combo. Gas hob '
                   'friendly when the lights go out.',
            ingredients: [
              '2 cups cake flour',
              '1 sachet instant yeast',
              '1 tsp sugar, 1 tsp salt',
              '1 cup warm water',
              '500 g mixed soup pack (carrots, celery, leeks)',
              '1 onion, diced',
              '6 cups stock',
              '½ cup split peas',
              'Oil for frying',
            ],
            instructions: [
              'Mix flour, yeast, sugar, salt with warm water; knead and prove 30 min.',
              'For the soup, soften onion in a pot; add chopped veg.',
              'Pour in stock and split peas; simmer 30 min until peas are soft.',
              'Blend half the soup smooth for body, keep the rest chunky.',
              'Shape proven dough into balls; deep-fry until golden.',
              'Serve vetkoek hot with soup ladled over.',
            ],
          ),
          _SeasonalDish(
            emoji: '🫘', name: 'Hearty Bean Soup',
            tag: 'cosy · 90 min',
            gradientStart: Color(0xFFE2C49B), gradientEnd: Color(0xFF7A4B22),
            isLoadsheddingFriendly: true,
            blurb: 'A thick, smoky bean soup with carrots and barley. '
                   'Simmers happily on a gas hob through any loadshedding '
                   'slot — set it and forget it.',
            ingredients: [
              '2 cups dried sugar beans (soaked overnight)',
              '1 onion, diced',
              '2 carrots, diced',
              '2 celery stalks, sliced',
              '½ cup pearl barley',
              '6 cups beef or vegetable stock',
              '1 tin (410 g) chopped tomatoes',
              '2 tsp smoked paprika, salt, pepper',
            ],
            instructions: [
              'Drain soaked beans; rinse and set aside.',
              'Soften onion, carrots and celery in a heavy pot.',
              'Add beans, barley, stock, tomatoes and smoked paprika.',
              'Simmer covered for 75 to 90 min until beans are soft.',
              'Season generously; serve with crusty bread.',
            ],
          ),
          _SeasonalDish(
            emoji: '🍮', name: 'Malva Pudding',
            tag: 'sticky · oven · 45 min',
            gradientStart: Color(0xFFF8C481), gradientEnd: Color(0xFFB07028),
            needsElectricity: true,
            blurb: 'Cape Dutch classic — caramel-soaked sponge drowned in '
                   'a hot cream sauce. Strictly an oven bake; pair with '
                   'custard or vanilla ice cream.',
            ingredients: [
              '1 cup cake flour',
              '¾ cup white sugar',
              '1 tsp bicarb',
              '1 egg, 1 tbsp apricot jam',
              '1 tbsp butter, 1 tsp vinegar',
              '½ cup milk',
              'Sauce: 1 cup cream, ½ cup butter, ¾ cup sugar, ½ cup hot water',
            ],
            instructions: [
              'Preheat oven to 180 °C.',
              'Whisk egg and sugar; beat in jam, melted butter, vinegar.',
              'Sift in flour and bicarb; fold in milk to a smooth batter.',
              'Pour into a greased baking dish; bake 30 to 35 min.',
              'Heat sauce ingredients in a pot until smooth.',
              'Pour hot sauce over the pudding straight from the oven.',
            ],
          ),
          _SeasonalDish(
            emoji: '🍛', name: 'Cape Malay Curry',
            tag: 'fragrant · 45 min',
            gradientStart: Color(0xFFFFD0A8), gradientEnd: Color(0xFFB35A1F),
            isLoadsheddingFriendly: true,
            blurb: 'Sweet, fragrant chicken curry with raisins and a hint '
                   'of cinnamon. Gas-hob friendly — perfect winter weeknight.',
            ingredients: [
              '700 g chicken thighs',
              '2 onions, 3 garlic, thumb of ginger',
              '2 tbsp Cape Malay curry powder',
              '1 tin coconut milk, 1 tin tomatoes',
              '½ cup raisins, 1 cinnamon stick',
            ],
            instructions: [
              'Soften onions, garlic and ginger in a pot.',
              'Add curry powder and cinnamon; toast 1 min.',
              'Brown chicken; add tomatoes, coconut milk and raisins.',
              'Simmer 30 min; serve with yellow rice.',
            ],
          ),
          _SeasonalDish(
            emoji: '🥧', name: 'Bobotie',
            tag: 'baked · 60 min',
            gradientStart: Color(0xFFFFD89A), gradientEnd: Color(0xFFA76327),
            needsElectricity: true,
            blurb: 'Spiced mince bake with a custard top, sweet and savoury, '
                   'served with yellow rice and chutney.',
            ingredients: [
              '700 g beef mince',
              '1 onion, 2 garlic cloves',
              '2 tbsp curry powder, 1 tsp turmeric',
              '2 slices bread soaked in 1 cup milk',
              '¼ cup chutney, ¼ cup raisins',
              '2 eggs, bay leaves',
            ],
            instructions: [
              'Soften onion and garlic; toast spices.',
              'Brown mince; stir in chutney, raisins and soaked bread.',
              'Tip into a dish; whisked egg + bay leaves go on top.',
              'Bake at 180 °C for 30 min until golden.',
            ],
          ),
          _SeasonalDish(
            emoji: '🌽', name: 'Samp & Beans',
            tag: 'umngqusho · slow',
            gradientStart: Color(0xFFE8DCC0), gradientEnd: Color(0xFF8A7B5A),
            isLoadsheddingFriendly: true,
            blurb: 'Slow-simmered samp and sugar beans — humble, hearty, '
                   'and a Mandela favourite. Set and forget on the gas hob.',
            ingredients: [
              '2 cups samp (soaked overnight)',
              '1 cup sugar beans (soaked overnight)',
              '1 onion, diced',
              '2 tbsp butter',
              '6 cups stock',
              'Salt and pepper',
            ],
            instructions: [
              'Drain and rinse samp and beans.',
              'Soften onion in butter; add samp, beans and stock.',
              'Simmer covered 1.5 hours until soft, topping up water as needed.',
              'Season generously; serve hot.',
            ],
          ),
          _SeasonalDish(
            emoji: '🐔', name: 'Roast Lemon Chicken',
            tag: 'oven · 75 min',
            gradientStart: Color(0xFFF6D87F), gradientEnd: Color(0xFFA67A1E),
            needsElectricity: true,
            blurb: 'One-pan whole roast chicken with lemon, garlic and '
                   'rosemary potatoes — Sunday-lunch comfort food.',
            ingredients: [
              '1 whole chicken (1.5 kg)',
              '1 lemon, halved',
              '6 garlic cloves',
              '4 large potatoes, chunked',
              '2 sprigs rosemary, olive oil',
              'Salt and pepper',
            ],
            instructions: [
              'Preheat oven to 200 °C.',
              'Stuff chicken cavity with lemon and 3 garlic cloves.',
              'Toss potatoes with oil, remaining garlic, rosemary, salt.',
              'Roast chicken on potatoes 65–75 min until juices run clear.',
            ],
          ),
          _SeasonalDish(
            emoji: '🥩', name: 'Beef Curry',
            tag: 'mild · 90 min',
            gradientStart: Color(0xFFE3B188), gradientEnd: Color(0xFF7A3E1A),
            isLoadsheddingFriendly: true,
            blurb: 'Mild Durban-style beef curry with potatoes. Gentle '
                   'spice, deep flavour — ideal for the whole family.',
            ingredients: [
              '800 g stewing beef, cubed',
              '2 onions, 4 garlic cloves',
              '2 tbsp Durban masala',
              '1 tin tomatoes',
              '3 potatoes, chunked',
              'Fresh coriander to finish',
            ],
            instructions: [
              'Brown beef; set aside.',
              'Soften onions and garlic; toast masala.',
              'Return beef with tomatoes and potatoes.',
              'Simmer 1.5 hours until beef is fork-tender; finish with coriander.',
            ],
          ),
          // ── CAPE TOWN AUTHENTIC — winter additions ─────────────────────
          // Heritage Cape Malay + Cape coast dishes layered into the winter
          // pool so the 3-hour rotation regularly surfaces local classics
          // (snoek, waterblommetjies, bredies, koesisters etc.) alongside
          // the broader SA staples above.
          _SeasonalDish(
            emoji: '🐟', name: 'Snoek Braai with Apricot Glaze',
            tag: 'braai · 25 min',
            gradientStart: Color(0xFFE2C49B), gradientEnd: Color(0xFF8A5A2A),
            isBraaiReady: true,
            isLoadsheddingFriendly: true,
            blurb: 'Cape coast classic — whole butterflied snoek over the '
                   'coals, basted with apricot jam, butter, lemon and garlic. '
                   'Tannie Sarie\'s Sunday lunch.',
            ingredients: [
              '1 whole snoek, butterflied (about 1.5 kg)',
              '½ cup smooth apricot jam',
              '½ cup melted butter',
              'Juice of 2 lemons',
              '4 garlic cloves, crushed',
              '1 tsp coarse salt, black pepper',
            ],
            instructions: [
              'Mix apricot jam, melted butter, lemon juice, garlic.',
              'Lay the snoek skin-side-down on a hinged braai grid.',
              'Brush generously with the glaze.',
              'Braai over moderate coals 15–20 min, basting often.',
              'Flip once at the end for 2 min just to crisp the skin.',
            ],
          ),
          _SeasonalDish(
            emoji: '🌸', name: 'Waterblommetjie Bredie',
            tag: 'cape winter · 2 hrs',
            gradientStart: Color(0xFFD8C295), gradientEnd: Color(0xFF7A6235),
            isLoadsheddingFriendly: true,
            blurb: 'Peak Cape winter — lamb stewed with waterblommetjies '
                   '(Cape pondweed flowers), potato and a squeeze of lemon. '
                   'Found only in the Western Cape between June and September.',
            ingredients: [
              '1 kg lamb knuckles or neck',
              '500 g fresh waterblommetjies, rinsed',
              '2 onions, sliced',
              '4 potatoes, quartered',
              '2 cups lamb or beef stock',
              'Juice of 1 lemon',
              '1 tsp salt, black pepper, sprig of thyme',
            ],
            instructions: [
              'Brown lamb in a heavy pot with a little oil.',
              'Add onions; soften until translucent.',
              'Pour in stock; simmer covered 60 min.',
              'Add potatoes and waterblommetjies; simmer another 45 min.',
              'Finish with lemon juice, salt, pepper, thyme.',
            ],
          ),
          _SeasonalDish(
            emoji: '🍲', name: 'Tomato Bredie',
            tag: 'cape malay · 90 min',
            gradientStart: Color(0xFFE6A77A), gradientEnd: Color(0xFF8B3A1A),
            isLoadsheddingFriendly: true,
            blurb: 'Cape Malay lamb-and-tomato stew, slow-cooked until the '
                   'tomatoes melt into a rich gravy. Serve with white rice '
                   'and a spoon of chutney.',
            ingredients: [
              '1 kg lamb shoulder, cubed',
              '4 ripe tomatoes, grated (or 1 tin chopped)',
              '2 onions, sliced',
              '3 garlic cloves, crushed',
              '1 tbsp brown sugar',
              '1 tsp ground cinnamon, 1 tsp ground cumin',
              '4 potatoes, quartered',
            ],
            instructions: [
              'Brown lamb in a heavy-based pot.',
              'Add onions and garlic; soften 5 min.',
              'Stir in spices and brown sugar; cook 1 min.',
              'Add grated tomatoes; simmer covered 60 min.',
              'Add potatoes; cook another 30 min until lamb is tender.',
            ],
          ),
          _SeasonalDish(
            emoji: '🍤', name: 'Smoorsnoek',
            tag: 'cape malay · 30 min',
            gradientStart: Color(0xFFE2BB8A), gradientEnd: Color(0xFF7E5526),
            isLoadsheddingFriendly: true,
            blurb: 'Flaked smoked snoek smothered with onion, tomato and '
                   'potato — Bo-Kaap home cooking. Eat on fresh white bread '
                   'with butter, the proper Cape way.',
            ingredients: [
              '500 g smoked snoek, flaked',
              '2 onions, finely sliced',
              '2 tomatoes, grated',
              '2 potatoes, diced small',
              '2 tbsp oil',
              '1 green chilli, chopped (optional)',
              'Salt and pepper',
            ],
            instructions: [
              'Soften onions in oil until lightly golden.',
              'Add potatoes; cook covered 10 min.',
              'Stir in grated tomato and chilli; cook 5 min.',
              'Fold in flaked snoek; warm through, season carefully.',
              'Serve on thick slices of fresh white bread.',
            ],
          ),
          _SeasonalDish(
            emoji: '🍛', name: 'Denningvleis',
            tag: 'cape malay · 2 hrs',
            gradientStart: Color(0xFFD8A064), gradientEnd: Color(0xFF6E3914),
            isLoadsheddingFriendly: true,
            blurb: 'Sweet-and-sour Cape Malay lamb — tamarind, cloves, all '
                   'spice, bay and a touch of brown sugar. Heritage dish from '
                   'the Bo-Kaap kitchens.',
            ingredients: [
              '1 kg lamb shoulder, cubed',
              '2 onions, sliced',
              '3 garlic cloves',
              '2 tbsp tamarind paste',
              '2 tbsp brown sugar',
              '6 allspice berries, 4 cloves, 2 bay leaves',
              '1 cup stock',
            ],
            instructions: [
              'Brown lamb in a pot; set aside.',
              'Soften onions and garlic; add spices.',
              'Return lamb; add tamarind, sugar, stock.',
              'Simmer covered 90 min until tender.',
              'Adjust sweet/sour balance; serve with yellow rice.',
            ],
          ),
          _SeasonalDish(
            emoji: '🥖', name: 'Gatsby (Cape Town Sub)',
            tag: 'iconic · 20 min',
            gradientStart: Color(0xFFF0BC72), gradientEnd: Color(0xFFA66424),
            isLoadsheddingFriendly: true,
            blurb: 'Cape Town\'s legendary foot-long sandwich. Crusty roll '
                   'loaded with masala steak, slap chips, peri-peri sauce, '
                   'lettuce and tomato. Cut into four — share with the laaities.',
            ingredients: [
              '1 long Portuguese / French loaf',
              '500 g rump steak, sliced thin',
              '2 tbsp masala spice (Rajah)',
              '3 large potatoes, cut into chips',
              '1 onion, sliced',
              'Lettuce, tomato, peri-peri or chutney',
              'Oil for frying',
            ],
            instructions: [
              'Fry chips in hot oil until golden; drain, salt.',
              'Sear steak strips with masala until just cooked.',
              'Soften onions in the same pan briefly.',
              'Split the loaf lengthways; layer steak, chips, onion, sauce.',
              'Top with lettuce and tomato; press, slice into four.',
            ],
          ),
          _SeasonalDish(
            emoji: '🥟', name: 'Daltjies (Cape Chilli Bites)',
            tag: 'cape malay · 25 min',
            gradientStart: Color(0xFFE9B57A), gradientEnd: Color(0xFFA15C1B),
            isLoadsheddingFriendly: true,
            blurb: 'Cape Malay chilli bites — gram-flour fritters with '
                   'spinach, dhania and green chilli. Crispy outside, soft '
                   'inside. Serve with mint chutney.',
            ingredients: [
              '2 cups gram (chickpea) flour',
              '1 cup chopped spinach',
              '½ cup fresh coriander (dhania), chopped',
              '2 green chillies, chopped',
              '1 tsp turmeric, 1 tsp cumin, salt',
              '¾ cup cold water',
              'Oil for deep-frying',
            ],
            instructions: [
              'Mix gram flour with spices, dhania, chilli and spinach.',
              'Add cold water; mix to a thick batter.',
              'Heat oil; drop tablespoons into the oil.',
              'Fry 3–4 min, turning, until deep golden.',
              'Drain on kitchen paper; eat hot with chutney.',
            ],
          ),
          _SeasonalDish(
            emoji: '🍵', name: 'Boeber',
            tag: 'cape malay · 25 min',
            gradientStart: Color(0xFFF6D6A1), gradientEnd: Color(0xFFB57C2A),
            isLoadsheddingFriendly: true,
            blurb: 'Warm, milky Cape Malay dessert — fine vermicelli, sago, '
                   'almonds, cardamom and rose water. Traditional treat on '
                   'the 15th night of Ramadan, beautiful any winter evening.',
            ingredients: [
              '1.5 L full-cream milk',
              '½ cup vermicelli',
              '3 tbsp sago (soaked 10 min)',
              '½ cup sugar',
              '4 cardamom pods, crushed',
              '¼ cup raisins, 2 tbsp slivered almonds',
              '1 tsp rose water',
            ],
            instructions: [
              'Heat milk in a heavy pot with cardamom.',
              'Add vermicelli and drained sago; simmer 10 min.',
              'Stir in sugar, raisins, almonds; cook 5 min.',
              'Finish with rose water; serve warm in cups.',
            ],
          ),
          _SeasonalDish(
            emoji: '🐠', name: 'Pickled Fish',
            tag: 'cape easter · overnight',
            gradientStart: Color(0xFFE8C387), gradientEnd: Color(0xFF8F5A1A),
            isLoadsheddingFriendly: true,
            blurb: 'Cape Malay pickled fish — yellowtail or hake in a turmeric-'
                   'curry-vinegar bath with onions. Eaten cold on fresh '
                   'bread, the Cape Easter tradition.',
            ingredients: [
              '1 kg firm white fish (hake, yellowtail), cut in portions',
              '4 onions, sliced',
              '2 cups white vinegar',
              '½ cup water, ½ cup sugar',
              '2 tbsp mild curry powder',
              '1 tsp turmeric, 1 tbsp ground coriander',
              '6 bay leaves, 1 tsp peppercorns',
              'Cake flour, oil for frying',
            ],
            instructions: [
              'Dust fish in seasoned flour; fry till just cooked. Cool.',
              'Soften onions; add spices and toast 1 min.',
              'Pour in vinegar, water and sugar; simmer 10 min.',
              'Layer fish and pickling liquid in a glass dish.',
              'Cover; refrigerate at least 24 hrs before eating.',
            ],
          ),
          _SeasonalDish(
            emoji: '🎃', name: 'Pampoenkoekies',
            tag: 'pumpkin fritters · 20 min',
            gradientStart: Color(0xFFF6BB6B), gradientEnd: Color(0xFFB36B1F),
            isLoadsheddingFriendly: true,
            blurb: 'Sweet pumpkin fritters — Sunday-lunch side or pudding. '
                   'Crispy edges, soft middle, dusted with cinnamon sugar.',
            ingredients: [
              '500 g cooked, mashed pumpkin (cooled)',
              '2 eggs, beaten',
              '½ cup cake flour',
              '1 tsp baking powder, pinch of salt',
              'Oil for shallow-frying',
              'Cinnamon sugar to dust',
            ],
            instructions: [
              'Mix pumpkin, eggs, flour, baking powder, salt.',
              'Heat oil in a pan; drop heaped spoonfuls.',
              'Fry 2 min each side until golden.',
              'Drain; dust generously with cinnamon sugar.',
            ],
          ),
          _SeasonalDish(
            emoji: '🥧', name: 'Hoenderpastei (Chicken Pie)',
            tag: 'sunday lunch · 75 min',
            gradientStart: Color(0xFFF3CE92), gradientEnd: Color(0xFFAD7026),
            needsElectricity: true,
            blurb: 'Old Cape farmhouse chicken pie — creamy filling with '
                   'mushrooms, peas and a hint of lemon, baked under '
                   'flaky puff pastry. Sunday-lunch classic.',
            ingredients: [
              '6 chicken thighs, cooked and shredded',
              '2 tbsp butter, 2 tbsp flour',
              '1 cup chicken stock, 1 cup milk',
              '200 g mushrooms, sliced',
              '½ cup frozen peas',
              'Juice of ½ lemon, salt and pepper',
              '1 roll puff pastry, 1 egg beaten',
            ],
            instructions: [
              'Melt butter; whisk in flour to form a roux.',
              'Slowly add stock and milk, whisking to a smooth sauce.',
              'Fold in chicken, mushrooms, peas, lemon juice; season.',
              'Tip into a pie dish; cover with puff pastry, crimp edges.',
              'Brush with egg; bake 200 °C for 30 min until golden.',
            ],
          ),
          _SeasonalDish(
            emoji: '🍯', name: 'Koesisters (Cape Malay)',
            tag: 'sunday treat · 60 min',
            gradientStart: Color(0xFFE8A45F), gradientEnd: Color(0xFF8E4818),
            needsElectricity: true,
            blurb: 'NOT the syrup-soaked Afrikaans koeksister — these are '
                   'the Cape Malay variety: spiced doughnut, fried, rolled '
                   'in coconut and syrup. Sunday-morning Bo-Kaap special.',
            ingredients: [
              '4 cups cake flour',
              '1 sachet instant yeast, 2 tsp sugar',
              '1 tsp ground cinnamon, 1 tsp ground naartjie peel',
              '½ tsp ground aniseed, ½ tsp ground cardamom',
              '1¼ cups warm milk, 1 egg, 2 tbsp butter',
              'Oil for frying',
              'Syrup: 1 cup sugar + 1 cup water + cinnamon stick',
              'Desiccated coconut to roll',
            ],
            instructions: [
              'Mix dry ingredients; rub in butter.',
              'Add milk, egg; knead, prove 60 min until doubled.',
              'Shape into ovals; prove a further 30 min.',
              'Deep-fry in moderate oil until deep golden.',
              'Boil syrup; dip hot koesisters then roll in coconut.',
            ],
          ),
          _SeasonalDish(
            emoji: '🥮', name: 'Melktert (Milk Tart)',
            tag: 'cape classic · 45 min',
            gradientStart: Color(0xFFF6E2B0), gradientEnd: Color(0xFFB9883D),
            needsElectricity: true,
            blurb: 'Cape Dutch heritage classic — silky milk custard set in '
                   'a sweet pastry shell, dusted with cinnamon. Tannie\'s '
                   'tea-time staple, served cold or just warm.',
            ingredients: [
              'Crust:',
              '125 g butter, softened',
              '½ cup white sugar',
              '1 egg',
              '1¾ cups cake flour',
              '2 tsp baking powder, pinch of salt',
              'Filling:',
              '4 cups full-cream milk',
              '1 cinnamon stick',
              '2 tbsp butter',
              '3 eggs, separated',
              '½ cup white sugar',
              '3 tbsp cake flour, 3 tbsp Maizena (corn starch)',
              '1 tsp vanilla essence',
              'Ground cinnamon to dust',
            ],
            instructions: [
              'Cream butter and sugar; beat in egg.',
              'Sift in flour, baking powder, salt; mix to soft dough.',
              'Press into a greased 24 cm pie dish; chill 15 min.',
              'Bake blind at 180 °C for 12 min until pale golden; cool.',
              'Warm milk with cinnamon stick; remove stick.',
              'Whisk yolks, sugar, flour, Maizena, vanilla to a smooth paste.',
              'Pour warm milk slowly over the paste, whisking, then return to pot.',
              'Stir over low heat until thickened — about 5 min.',
              'Whisk egg whites stiff; fold gently into the hot custard.',
              'Pour into the crust; dust generously with ground cinnamon.',
              'Cool to room temperature; chill before slicing.',
            ],
          ),
          // ── Vegan winter rotation entries ──────────────────────────
          _SeasonalDish(emoji: '🥕', name: 'Butternut & Bean Potjie',
            tag: 'vegan · slow · 2 hrs',
            gradientStart: Color(0xFFFFD79B), gradientEnd: Color(0xFFB76A1F),
            isBraaiReady: true,
            isLoadsheddingFriendly: true,
            blurb: 'Plant-based potjie layered with butternut, kidney beans, '
                   'mealie, lentils and rooibos broth. Slow-cooked over coals.',
            ingredients: [
              '500 g butternut, cubed',
              '1 tin red kidney beans, drained',
              '1 tin lentils (or 1 cup dry, pre-soaked)',
              '1 onion, sliced',
              '3 cloves garlic, crushed',
              '2 carrots, chunked',
              '1 cup frozen mealie kernels',
              '2 cups vegetable stock (Knorr veg cube)',
              '1 tbsp tomato paste',
              '1 tsp ground cumin',
              '1 tsp smoked paprika',
              '2 bay leaves',
              'Salt and pepper to taste',
            ],
            instructions: [
              'Heat oil in the potjie over coals; sweat onions and garlic.',
              'Add carrots, butternut, cumin and paprika; toss to coat.',
              'Layer in beans, lentils and mealie. Do NOT stir.',
              'Pour over stock + tomato paste; tuck in bay leaves.',
              'Cover and cook over low coals for 1.5–2 hrs without lifting the lid.',
              'Season; serve with pap or roosterkoek (use Flora Plant butter).',
            ],
          ),
          _SeasonalDish(
            emoji: '🍲', name: 'Vegan Tomato Bredie',
            tag: 'vegan · stovetop · 45 min',
            gradientStart: Color(0xFFFFB89A), gradientEnd: Color(0xFFB94C2C),
            isLoadsheddingFriendly: true,
            blurb: 'Slow-cooked tomato stew on a gas hob. Soy mince and '
                   'butter beans give it the body lamb usually carries.',
            ingredients: [
              '2 onions, sliced',
              '3 garlic cloves, crushed',
              '500 g Fry\'s Soy Mince (frozen)',
              '1 tin butter beans, drained',
              '1 tin chopped tomatoes',
              '2 tbsp tomato paste',
              '2 cups vegetable stock (Knorr veg cube)',
              '1 tbsp smoked paprika',
              '1 tsp ground cumin',
              '1 tsp dried mixed herbs',
              '2 bay leaves',
              '2 tbsp olive oil',
              '1 tsp brown sugar',
              'Salt and black pepper to taste',
            ],
            instructions: [
              'Heat olive oil; sweat onions and garlic over medium heat (8 min).',
              'Add soy mince; brown for 4 min, stirring to break up clumps.',
              'Stir in paprika, cumin and herbs; toast for 30 sec.',
              'Add tomato paste, chopped tomatoes, stock and bay leaves.',
              'Tip in butter beans and brown sugar; season.',
              'Cover and simmer 30 min, stirring occasionally.',
              'Uncover for the last 5 min to thicken.',
              'Serve over rice, samp or with a hunk of roosterkoek.',
            ],
          ),
        ];
      case _Season.spring:
        return const [
          _SeasonalDish(emoji: '🐔', name: 'Spring Roast Chicken',
            tag: 'herbed · oven',
            gradientStart: Color(0xFFE5D9A0), gradientEnd: Color(0xFF8A7A2E)),
          _SeasonalDish(emoji: '🥬', name: 'Spinach & Feta Phyllo',
            tag: 'crispy · 30 min',
            gradientStart: Color(0xFFCEE0B6), gradientEnd: Color(0xFF4E6F3A)),
          _SeasonalDish(emoji: '🌶', name: 'Peri-Peri Prawns',
            tag: 'fiery · 20 min',
            gradientStart: Color(0xFFFFB89A), gradientEnd: Color(0xFFB94C2C)),
          _SeasonalDish(emoji: '🥗', name: 'Mediterranean Salad',
            tag: 'fresh · 15 min',
            gradientStart: Color(0xFFC9DDC0), gradientEnd: Color(0xFF4F7B4C)),
          _SeasonalDish(
            emoji: '🌱', name: 'Vegan Spring Pesto Pasta',
            tag: 'vegan · 20 min',
            gradientStart: Color(0xFFCEE5B2), gradientEnd: Color(0xFF4F823E),
            blurb: 'Bright spring pesto built on basil, rocket and toasted '
                   'cashews. Tossed with spaghetti, peas and lemon zest.',
            ingredients: [
              '400 g spaghetti',
              '2 cups fresh basil leaves',
              '1 cup rocket',
              '½ cup raw cashews, toasted',
              '2 garlic cloves',
              '½ cup olive oil',
              '2 tbsp nutritional yeast (or omit)',
              '2 tbsp lemon juice + zest of 1 lemon',
              '1 cup frozen peas',
              'Salt and black pepper to taste',
            ],
            instructions: [
              'Boil spaghetti in salted water per pack; reserve ½ cup pasta water.',
              'Add frozen peas to the pot for the last 2 min; drain.',
              'Blend basil, rocket, cashews, garlic, olive oil, yeast, lemon '
                  'juice, salt and pepper into a coarse pesto.',
              'Toss hot pasta with pesto; loosen with pasta water as needed.',
              'Finish with lemon zest and extra rocket on top.',
            ],
          ),
          _SeasonalDish(
            emoji: '🥬', name: 'Tofu-Feta Spinach Phyllo',
            tag: 'vegan · crispy · 35 min',
            gradientStart: Color(0xFFDFE9C5), gradientEnd: Color(0xFF6B8B4E),
            blurb: 'Crisp phyllo parcels filled with herby spinach and '
                   'tangy tofu "feta". Bakes golden in 25 min.',
            ingredients: [
              '300 g firm tofu, crumbled',
              '2 tbsp lemon juice',
              '2 tbsp white miso (or 1 tsp salt)',
              '500 g fresh spinach, wilted and drained',
              '1 onion, finely chopped',
              '2 garlic cloves, crushed',
              '2 tbsp fresh dill, chopped',
              '1 tsp dried oregano',
              '1 packet phyllo pastry',
              '½ cup olive oil (for brushing)',
              'Salt and black pepper to taste',
            ],
            instructions: [
              'Preheat oven to 200 °C.',
              'Mix crumbled tofu with lemon juice, miso, salt and pepper — '
                  'this is the vegan "feta". Rest 10 min.',
              'Soften onion and garlic in 2 tbsp oil; stir in wilted spinach.',
              'Off the heat, fold in tofu-feta, dill and oregano.',
              'Stack 3 phyllo sheets, brushing oil between each; cut into strips.',
              'Spoon filling on one end of each strip; fold flag-style into '
                  'triangles.',
              'Brush with olive oil; bake 20-25 min until deep golden.',
            ],
          ),
          _SeasonalDish(emoji: '🍋', name: 'Lemon Herb Snoek',
            tag: 'braai · Cape',
            gradientStart: Color(0xFFE8E1A8), gradientEnd: Color(0xFF9A8A28)),
        ];
    }
  }
}

// =============================================================================
// _PowerBadge — single-state power-status label rendered on each card
// =============================================================================
//
// Three mutually-exclusive states matching the spec:
//   • braai        → 🔥  "Braai/Gas Ready"           (cooked over coals)
//   • loadshedding → ⚡  "Load-Shedding Friendly"   (gas-hob survivable)
//   • electricity  → 🔌  "Needs Electricity"         (oven / electric only)

enum _PowerBadge {
  braai(
    icon:  Icons.local_fire_department_rounded,
    label: 'Braai/Gas Ready',
    fg:    Color(0xFFBF360C),
    bg:    Color(0xFFFFE5D6),
  ),
  loadshedding(
    icon:  Icons.bolt_rounded,
    // Wording simplified per spec — "Load-Shedding Friendly" was too
    // South-Africa-context-loaded for the badge surface. Same flag,
    // same logic, friendlier label.
    label: 'Gas / Braai Ready',
    fg:    Color(0xFF0C351E),
    bg:    Color(0xFFD8ECDD),
  ),
  electricity(
    icon:  Icons.power_rounded,
    label: 'Needs Electricity',
    fg:    Color(0xFF1565C0),
    bg:    Color(0xFFDCE9F7),
  );

  const _PowerBadge({
    required this.icon,
    required this.label,
    required this.fg,
    required this.bg,
  });
  final IconData icon;
  final String   label;
  final Color    fg;
  final Color    bg;
}

class _PowerStatusChip extends StatelessWidget {
  const _PowerStatusChip({required this.badge});
  final _PowerBadge badge;

  @override
  Widget build(BuildContext context) {
    // Hidden per user request — see pantry_screen._LoadsheddingBadge.
    return const SizedBox.shrink();
    // ignore: dead_code
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 3, 7, 3),
      decoration: BoxDecoration(
        color:        badge.bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(badge.icon, size: 11, color: badge.fg),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              badge.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color:         badge.fg,
                fontSize:      9.5,
                fontWeight:    FontWeight.w800,
                letterSpacing: 0.2,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// _SeasonalDishCard — horizontal carousel item
// =============================================================================

class _SeasonalDishCard extends StatefulWidget {
  const _SeasonalDishCard({
    required this.dish,
    required this.featured,
    required this.onTap,
  });

  final _SeasonalDish dish;
  final bool          featured;
  final VoidCallback  onTap;

  @override
  State<_SeasonalDishCard> createState() => _SeasonalDishCardState();
}

Widget _dishGradientHeader(_SeasonalDish d) => Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [d.gradientStart, d.gradientEnd],
          begin: Alignment.topLeft,
          end:   Alignment.bottomRight,
        ),
      ),
      alignment: Alignment.center,
      child: Text(d.emoji, style: const TextStyle(fontSize: 36)),
    );

/// Detail-sheet hero variant — same gradient + emoji, sized larger so
/// it matches the photo it falls back from.
Widget _seasonalGradientHero(_SeasonalDish d) => Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [d.gradientStart, d.gradientEnd],
          begin: Alignment.topLeft,
          end:   Alignment.bottomRight,
        ),
      ),
      alignment: Alignment.center,
      child: Text(d.emoji, style: const TextStyle(fontSize: 56)),
    );

class _SeasonalDishCardState extends State<_SeasonalDishCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final text   = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;

    return GestureDetector(
      onTapDown:   (_) => setState(() => _pressed = true),
      onTapUp:     (_) => setState(() => _pressed = false),
      onTapCancel: ()  => setState(() => _pressed = false),
      onTap:       widget.onTap,
      child: AnimatedScale(
        scale:    _pressed ? 0.96 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve:    Curves.easeOut,
        child: SizedBox(
          width: 136,
          child: Container(
            decoration: BoxDecoration(
              color:        colors.surfaceContainer,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: colors.outlineVariant.withAlpha(120),
                width: 1,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      height: 76,
                      width:  double.infinity,
                      child: _dishGradientHeader(widget.dish),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.dish.name,
                            style: text.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                              color:      colors.onSurface,
                              fontSize:   12.5,
                              height:     1.2,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            widget.dish.tag,
                            style: text.labelSmall?.copyWith(
                              color:    colors.onSurfaceVariant,
                              fontSize: 10,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (widget.dish.powerBadge != null) ...[
                            const SizedBox(height: 4),
                            _PowerStatusChip(badge: widget.dish.powerBadge!),
                          ],
                        ],
                      ),
                    ),
                  ],
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
// _SeasonalDishDetailSheet — full-screen modal with Save to My Recipes CTA
// =============================================================================

class _SeasonalDishDetailSheet extends StatefulWidget {
  const _SeasonalDishDetailSheet({
    required this.dish,
    required this.onSave,
  });

  final _SeasonalDish    dish;
  /// Receives the resolved hero photo URL (or null when none was found)
  /// so the saved Recipe carries the same image the sheet displayed.
  final Future<void> Function(String? imageUrl) onSave;

  @override
  State<_SeasonalDishDetailSheet> createState() =>
      _SeasonalDishDetailSheetState();
}

class _SeasonalDishDetailSheetState
    extends State<_SeasonalDishDetailSheet> {
  bool    _saving  = false;
  bool    _saved   = false;

  @override
  void initState() {
    super.initState();
    _refreshSavedFlag();
    // Re-check whenever My Recipes changes so a delete elsewhere in
    // the app re-enables the Save button on this open sheet without
    // having to close + re-open it.
    RecipeRepository.instance.updateNotifier
        .addListener(_refreshSavedFlag);
  }

  @override
  void dispose() {
    RecipeRepository.instance.updateNotifier
        .removeListener(_refreshSavedFlag);
    super.dispose();
  }

  /// Checks the user's My Recipes library for an existing entry with the
  /// same title (case-insensitive, trimmed). When found, locks the Save
  /// button into its "Saved" state so the user can't double-save the
  /// same seasonal dish. Cheap — RecipeRepository.loadAll is cached
  /// locally and just hits the in-memory list on warm reads.
  Future<void> _refreshSavedFlag() async {
    try {
      final mine    = await RecipeRepository.instance.loadAll();
      final target  = widget.dish.name.trim().toLowerCase();
      final already = mine.any(
        (r) => r.title.trim().toLowerCase() == target,
      );
      if (!mounted) return;
      if (already != _saved) setState(() => _saved = already);
    } catch (_) {
      // Offline / signed-out — leave the button in its current state.
    }
  }

  Future<void> _handleSave() async {
    if (_saving || _saved) return;
    setState(() => _saving = true);

    // ── 1. Persist ───────────────────────────────────────────────────────────
    // Repository call lives in its own try so a DB / network failure can't
    // halt the UI thread or leave the spinner stuck.
    try {
      await widget.onSave(null);
    } catch (_) {
      if (mounted) setState(() => _saving = false);
      return;
    }

    // ── 2. Confirm + auto-dismiss ────────────────────────────────────────────
    // Separate guard around the post-save UI so a delay or popped-sheet race
    // can't propagate up the tree. Navigator.pop is wrapped because the user
    // (or a sibling route change) may have already dismissed the sheet during
    // the 800ms confirmation hold.
    if (mounted) setState(() { _saving = false; _saved = true; });
    try {
      await Future<void>.delayed(const Duration(milliseconds: 800));
      if (!mounted) return;
      final navigator = Navigator.of(context);
      if (navigator.canPop()) navigator.pop();
    } catch (_) {
      // Swallow — the save itself already succeeded; closing the sheet is
      // best-effort.
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs   = Theme.of(context).colorScheme;
    final tt   = Theme.of(context).textTheme;
    final dish = widget.dish;

    // Defensive guard — if a dish ever arrives with an empty title or no
    // gradient colours (e.g. mid-rebuild from a stale notifier tick), render
    // a small loader sheet instead of attempting the full layout. This keeps
    // the tree alive rather than throwing during paint.
    if (dish.name.trim().isEmpty) {
      return DraggableScrollableSheet(
        initialChildSize: 0.4,
        minChildSize:     0.2,
        maxChildSize:     0.6,
        builder: (_, controller) => Container(
          decoration: BoxDecoration(
            color:        cs.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          ),
          alignment: Alignment.center,
          child: const Padding(
            padding: EdgeInsets.all(24),
            child: CircularProgressIndicator(),
          ),
        ),
      );
    }

    return DraggableScrollableSheet(
      initialChildSize: 0.92,
      minChildSize:     0.5,
      maxChildSize:     0.95,
      builder: (_, controller) => Container(
        decoration: BoxDecoration(
          color:        cs.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Column(
          children: [
            // ── Drag handle ───────────────────────────────────────────────
            const SizedBox(height: 12),
            Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color:        cs.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 4),

            // ── Scrollable content ────────────────────────────────────────
            Expanded(
              child: ListView(
                controller: controller,
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 120),
                children: [

                  // Hero — gradient + emoji (photo-lookup ripped 2026-06-23).
                  ClipRRect(
                    borderRadius: BorderRadius.circular(22),
                    child: SizedBox(
                      height: 160,
                      width:  double.infinity,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          _seasonalGradientHero(dish),
                          Positioned(
                            left: 0, right: 0, bottom: 10,
                            child: Center(
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.45),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Text(
                                  dish.tag,
                                  style: const TextStyle(
                                    color:      Colors.white,
                                    fontSize:   11,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Title + badges
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          dish.name,
                          style: tt.headlineSmall?.copyWith(
                            fontWeight:    FontWeight.w900,
                            letterSpacing: -0.3,
                          ),
                        ),
                      ),
                    ],
                  ),

                  // Blurb
                  if (dish.blurb != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      dish.blurb!,
                      style: tt.bodyMedium?.copyWith(
                        color:  cs.onSurfaceVariant,
                        height: 1.55,
                      ),
                    ),
                  ],

                  // Ingredients
                  if (dish.ingredients.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    Text('Ingredients',
                        style: tt.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800)),
                    const SizedBox(height: 12),
                    ...dish.ingredients.map((ing) => Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                width: 6, height: 6,
                                margin: const EdgeInsets.only(
                                    top: 6, right: 10),
                                decoration: BoxDecoration(
                                  color: cs.primary,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              Expanded(
                                child: Text(ing,
                                    style: tt.bodyMedium),
                              ),
                            ],
                          ),
                        )),
                  ],

                  // Instructions
                  if (dish.instructions.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    Text('Method',
                        style: tt.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800)),
                    const SizedBox(height: 12),
                    ...dish.instructions.asMap().entries.map((e) =>
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                width:  26, height: 26,
                                margin: const EdgeInsets.only(right: 12),
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: cs.primaryContainer,
                                  shape: BoxShape.circle,
                                ),
                                child: Text(
                                  '${e.key + 1}',
                                  style: TextStyle(
                                    color:      cs.onPrimaryContainer,
                                    fontWeight: FontWeight.w800,
                                    fontSize:   12,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Text(e.value,
                                    style: tt.bodyMedium?.copyWith(
                                        height: 1.5)),
                              ),
                            ],
                          ),
                        )),
                  ],
                ],
              ),
            ),

            // ── Sticky Save CTA ────────────────────────────────────────────
            Container(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              decoration: BoxDecoration(
                color: cs.surface,
                border: Border(
                  top: BorderSide(
                    color: cs.outlineVariant.withValues(alpha: 0.5),
                  ),
                ),
              ),
              child: SafeArea(
                top: false,
                child: SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: FilledButton.icon(
                    onPressed: (_saving || _saved) ? null : _handleSave,
                    icon: _saving
                        ? const SizedBox(
                            width: 18, height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : Icon(
                            _saved
                                ? Icons.check_circle_rounded
                                : Icons.bookmark_add_rounded,
                          ),
                    label: Text(
                      _saved
                          ? 'Saved to My Recipes!'
                          : 'Save to My Recipes',
                      style: const TextStyle(
                        color:      Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize:   15,
                      ),
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: _saved
                          ? const Color(0xFF2E7D32)
                          : cs.primary,
                      foregroundColor: Colors.white,
                      disabledForegroundColor: Colors.white.withValues(alpha: 0.85),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                    ),
                  ),
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
// =============================================================================
// Input card — URL / raw-text / camera scan modes
// =============================================================================

class _InputCard extends StatelessWidget {
  const _InputCard({
    required this.urlController,
    required this.rawTextController,
    required this.isRawMode,
    required this.enabled,
    required this.onPaste,
    required this.onSubmit,
    required this.onToggleMode,
    required this.onScan,
  });

  final TextEditingController urlController;
  final TextEditingController rawTextController;
  final bool isRawMode;
  final bool enabled;
  final VoidCallback onPaste;
  final VoidCallback onSubmit;
  final VoidCallback onToggleMode;
  final VoidCallback onScan;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text   = Theme.of(context).textTheme;

    return Container(
      decoration: BoxDecoration(
        color:        Colors.white,
        borderRadius: BorderRadius.circular(24),
        border:       Border.all(color: const Color(0xFFE6E2D8)),
        boxShadow: const [
          BoxShadow(
            color:      Color(0x08000000),
            blurRadius: 8,
            offset:     Offset(0, 2),
          ),
        ],
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Label ─────────────────────────────────────────────────────────
          Text(
            isRawMode ? 'Paste raw recipe text' : 'Paste any recipe link',
            style: text.labelLarge?.copyWith(
              color: colors.onSurfaceVariant,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(height: 10),

          // ── URL field ─────────────────────────────────────────────────────
          if (!isRawMode)
            TextField(
              controller: urlController,
              enabled: enabled,
              keyboardType: TextInputType.url,
              autocorrect: false,
              textInputAction: TextInputAction.go,
              onSubmitted: (_) => onSubmit(),
              style: text.bodyMedium,
              decoration: InputDecoration(
                hintText: 'https://www.cafedelites.com/...',
                hintStyle: const TextStyle(color: Color(0xFFADADA7)),
                filled:    true,
                fillColor: const Color(0xFFF0EDE8),
                contentPadding: const EdgeInsets.fromLTRB(16, 14, 4, 14),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
                suffixIcon: IconButton(
                  icon: Icon(Icons.content_paste_rounded, color: colors.primary),
                  tooltip: 'Paste from clipboard',
                  onPressed: enabled ? onPaste : null,
                ),
              ),
            ),

          // ── Raw text field ────────────────────────────────────────────────
          if (isRawMode)
            TextField(
              controller: rawTextController,
              enabled: enabled,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              maxLines: 8,
              minLines: 4,
              autocorrect: false,
              style: text.bodyMedium,
              decoration: InputDecoration(
                hintText:
                    'Paste recipe text here — ingredients, steps, anything copied '
                    'from a Facebook post, X thread, WhatsApp message, or any website…',
                hintStyle: const TextStyle(
                  color:  Color(0xFFADADA7),
                  height: 1.5,
                ),
                filled:    true,
                fillColor: const Color(0xFFF0EDE8),
                contentPadding: const EdgeInsets.fromLTRB(16, 14, 4, 14),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
                suffixIcon: Align(
                  alignment: Alignment.topRight,
                  widthFactor: 1,
                  heightFactor: 1,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: IconButton(
                      icon: Icon(Icons.content_paste_rounded, color: colors.primary),
                      tooltip: 'Paste from clipboard',
                      onPressed: enabled ? onPaste : null,
                    ),
                  ),
                ),
              ),
            ),

          // ── Bento action cards ─────────────────────────────────────────────
          const SizedBox(height: 14),
          Row(
            children: [
              // Dominant card — forest green camera scanner
              Expanded(
                flex: 3,
                child: _BentoCameraCard(enabled: enabled, onTap: onScan),
              ),
              const SizedBox(width: 10),
              // Secondary card — mode toggle
              Expanded(
                flex: 2,
                child: _BentoModeCard(
                  isRawMode: isRawMode,
                  enabled:   enabled,
                  onTap:     onToggleMode,
                ),
              ),
            ],
          ),

          const SizedBox(height: 14),

          // ── Animated gradient submit ───────────────────────────────────────
          _AnimatedChowButton(
            onPressed: enabled ? onSubmit : null,
            loading:   !enabled,
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Animated "Chow Time!" button
//
// Idle    → clean left-to-right orange gradient with elevation shadow.
// Pressed → scales down slightly (0.975×) and shadow deepens for tactile feel.
// Loading → gradient sweeps back-and-forth via AnimationController + reverse,
//           icon swaps to a spinner, label fades to "Asking the kitchen…".
// =============================================================================

class _AnimatedChowButton extends StatefulWidget {
  const _AnimatedChowButton({required this.onPressed, required this.loading});

  final VoidCallback? onPressed;
  final bool          loading;

  @override
  State<_AnimatedChowButton> createState() => _AnimatedChowButtonState();
}

class _AnimatedChowButtonState extends State<_AnimatedChowButton>
    with SingleTickerProviderStateMixin {
  // 0.0 → 1.0 → 0.0 (reversed) while loading — drives the gradient sweep.
  late final AnimationController _shimmer = AnimationController(
    vsync:    this,
    duration: const Duration(milliseconds: 1300),
  )..addListener(() => setState(() {}));

  bool _pressed = false;

  @override
  void didUpdateWidget(_AnimatedChowButton old) {
    super.didUpdateWidget(old);
    if (widget.loading && !old.loading) {
      _shimmer.repeat(reverse: true);
    } else if (!widget.loading && old.loading) {
      _shimmer.animateTo(0, duration: const Duration(milliseconds: 400));
    }
  }

  @override
  void dispose() {
    _shimmer.dispose();
    super.dispose();
  }

  LinearGradient get _gradient {
    final t = _shimmer.value;
    if (widget.loading) {
      // Gradient begin/end alignment oscillates, creating a sweeping light bar.
      return LinearGradient(
        begin:  Alignment(-1.0 + t, -0.4 + t * 0.25),
        end:    Alignment(t,          0.4 - t * 0.25),
        colors: const [Color(0xFFBF360C), Color(0xFFFF8F00), Color(0xFFE8611A)],
      );
    }
    return const LinearGradient(
      begin:  Alignment.centerLeft,
      end:    Alignment.centerRight,
      colors: [Color(0xFFE8611A), Color(0xFFFF8F00)],
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown:   (_) => setState(() => _pressed = true),
      onTapUp:     (_) => setState(() => _pressed = false),
      onTapCancel: ()  => setState(() => _pressed = false),
      onTap:       widget.loading ? null : widget.onPressed,
      child: AnimatedScale(
        scale:    _pressed ? 0.975 : 1.0,
        duration: const Duration(milliseconds: 100),
        curve:    Curves.easeOut,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          height: 56,
          decoration: BoxDecoration(
            gradient:     _gradient,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color:        _pressed
                    ? const Color(0x5CE8611A)
                    : const Color(0x3DE8611A),
                blurRadius:   _pressed ? 28 : 16,
                spreadRadius: _pressed ? 2 : 0,
                offset:       Offset(0, _pressed ? 8 : 4),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Icon ↔ spinner transition
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 240),
                transitionBuilder: (child, anim) =>
                    ScaleTransition(scale: anim, child: child),
                child: widget.loading
                    ? const SizedBox(
                        key:    ValueKey('spin'),
                        width:  20,
                        height: 20,
                        child:  CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color:       Colors.white,
                        ),
                      )
                    : const Icon(
                        Icons.bolt_rounded,
                        key:   ValueKey('bolt'),
                        color: Colors.white,
                        size:  22,
                      ),
              ),
              const SizedBox(width: 10),
              // Label fade-cross transition
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: Text(
                  widget.loading ? 'Asking the kitchen…' : 'Chow Time!',
                  key: ValueKey(widget.loading),
                  style: const TextStyle(
                    color:         Colors.white,
                    fontSize:      16,
                    fontWeight:    FontWeight.w800,
                    letterSpacing: 0.3,
                  ),
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
// Bento action cards — Camera (forest-green, dominant) + Mode toggle (secondary)
// =============================================================================

class _BentoCameraCard extends StatefulWidget {
  const _BentoCameraCard({required this.enabled, required this.onTap});

  final bool         enabled;
  final VoidCallback onTap;

  @override
  State<_BentoCameraCard> createState() => _BentoCameraCardState();
}

class _BentoCameraCardState extends State<_BentoCameraCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown:   (_) => setState(() => _pressed = true),
      onTapUp:     (_) => setState(() => _pressed = false),
      onTapCancel: ()  => setState(() => _pressed = false),
      onTap:       widget.enabled ? widget.onTap : null,
      child: AnimatedScale(
        scale:    _pressed ? 0.96 : 1.0,
        duration: const Duration(milliseconds: 100),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          constraints: const BoxConstraints(minHeight: 106),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            // Deep forest green — distinct from every other card on the screen.
            color:        _pressed ? const Color(0xFF22493A) : const Color(0xFF1A3A2A),
            borderRadius: BorderRadius.circular(24),
            boxShadow: _pressed
                ? const [
                    BoxShadow(
                      color:      Color(0x3C000000),
                      blurRadius: 18,
                      offset:     Offset(0, 8),
                    )
                  ]
                : [],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Icon container
              Container(
                width:  38,
                height: 38,
                decoration: const BoxDecoration(
                  color:        Color(0x2E6FCF97), // 6FCF97 @ 18% opacity
                  borderRadius: BorderRadius.all(Radius.circular(11)),
                ),
                child: const Icon(
                  Icons.photo_camera_rounded,
                  color: Color(0xFF6FCF97),
                  size:  20,
                ),
              ),
              const Spacer(),
              const Text(
                'Scan Photo',
                style: TextStyle(
                  color:         Colors.white,
                  fontWeight:    FontWeight.w700,
                  fontSize:      14,
                  letterSpacing: 0.1,
                ),
              ),
              const SizedBox(height: 2),
              const Text(
                'OCR your recipe',
                style: TextStyle(
                  color:    Color(0xFF6FCF97),
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────

class _BentoModeCard extends StatefulWidget {
  const _BentoModeCard({
    required this.isRawMode,
    required this.enabled,
    required this.onTap,
  });

  final bool         isRawMode;
  final bool         enabled;
  final VoidCallback onTap;

  @override
  State<_BentoModeCard> createState() => _BentoModeCardState();
}

class _BentoModeCardState extends State<_BentoModeCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return GestureDetector(
      onTapDown:   (_) => setState(() => _pressed = true),
      onTapUp:     (_) => setState(() => _pressed = false),
      onTapCancel: ()  => setState(() => _pressed = false),
      onTap:       widget.enabled ? widget.onTap : null,
      child: AnimatedScale(
        scale:    _pressed ? 0.96 : 1.0,
        duration: const Duration(milliseconds: 100),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          constraints: const BoxConstraints(minHeight: 106),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color:        _pressed
                ? cs.secondaryContainer.withAlpha(200)
                : cs.secondaryContainer,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Icon container — mirrors camera card structure
              Container(
                width:  38,
                height: 38,
                decoration: BoxDecoration(
                  color:        cs.onSecondaryContainer.withAlpha(28),
                  borderRadius: const BorderRadius.all(Radius.circular(11)),
                ),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  child: Icon(
                    widget.isRawMode
                        ? Icons.link_rounded
                        : Icons.text_snippet_outlined,
                    key:   ValueKey(widget.isRawMode),
                    color: cs.onSecondaryContainer,
                    size:  20,
                  ),
                ),
              ),
              const Spacer(),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child: Text(
                  widget.isRawMode ? 'Use Link' : 'Paste Text',
                  key: ValueKey(widget.isRawMode),
                  style: TextStyle(
                    color:         cs.onSecondaryContainer,
                    fontWeight:    FontWeight.w700,
                    fontSize:      14,
                    letterSpacing: 0.1,
                  ),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                widget.isRawMode ? 'Back to URL mode' : 'Raw text mode',
                style: TextStyle(
                  color:    cs.onSecondaryContainer.withAlpha(179),
                  fontSize: 11,
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
// Interactive recipe workspace — stateful, with ingredient/step check-off,
// chef's notes persistence, and "Add to Shopping List" export
// =============================================================================

class _InteractiveRecipeView extends StatefulWidget {
  const _InteractiveRecipeView({
    required this.recipe,
    required this.onReset,
    required this.onSchedule,
    this.onAddToShoppingList,
  });

  final Recipe recipe;
  final VoidCallback onReset;
  final ValueChanged<Recipe> onSchedule;
  final void Function(List<ShoppingItem>)? onAddToShoppingList;

  @override
  State<_InteractiveRecipeView> createState() => _InteractiveRecipeViewState();
}

class _InteractiveRecipeViewState extends State<_InteractiveRecipeView> {
  final Set<int> _doneIngredients = {};
  final Set<int> _doneSteps       = {};
  final TextEditingController _notes = TextEditingController();
  SharedPreferences? _prefs;

  String get _notesKey =>
      'chef_notes_${widget.recipe.title.hashCode}';

  @override
  void initState() {
    super.initState();
    _loadNotes();
  }

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  Future<void> _loadNotes() async {
    _prefs = await SharedPreferences.getInstance();
    final saved = _prefs?.getString(_notesKey);
    if (saved != null && mounted) {
      setState(() => _notes.text = saved);
    }
  }

  Future<void> _saveNotes() async {
    await _prefs?.setString(_notesKey, _notes.text);
  }

  void _toggleIngredient(int index) =>
      setState(() => _doneIngredients.contains(index)
          ? _doneIngredients.remove(index)
          : _doneIngredients.add(index));

  void _toggleStep(int index) =>
      setState(() => _doneSteps.contains(index)
          ? _doneSteps.remove(index)
          : _doneSteps.add(index));

  void _addUncheckedToShoppingList() {
    final items = <ShoppingItem>[];
    for (var i = 0; i < widget.recipe.ingredients.length; i++) {
      if (_doneIngredients.contains(i)) continue;
      final ing = widget.recipe.ingredients[i];
      // Show metric on the shopping list. The util returns e.g. "250 g"
      // or "" — split on the last space so the ShoppingItem keeps qty
      // and unit separate (the cart UI renders them with a no-break
      // space between them).
      final metric = formatIngredientMeasure(ing);
      final lastSpace = metric.lastIndexOf(' ');
      final qty  = lastSpace < 0 ? metric : metric.substring(0, lastSpace);
      final unit = lastSpace < 0 ? null    : metric.substring(lastSpace + 1);
      items.add(ShoppingItem(
        id:       '${DateTime.now().microsecondsSinceEpoch}_$i',
        name:     ing.name,
        quantity: qty.isEmpty ? null : qty,
        unit:     unit,
      ));
    }
    if (items.isEmpty) return;
    widget.onAddToShoppingList?.call(items);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text   = Theme.of(context).textTheme;
    final recipe = widget.recipe;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Title + loadshedding badge — tap title to open full detail view ──
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: GestureDetector(
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => RecipeDetailScreen(
                      recipe:              recipe,
                      onAddToShoppingList: widget.onAddToShoppingList,
                    ),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      recipe.title,
                      style: text.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                        color:      const Color(0xFF0C351E),
                        height:     1.2,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        const Icon(Icons.open_in_full_rounded,
                            size: 11, color: Color(0xFF55534E)),
                        const SizedBox(width: 4),
                        Text(
                          'Open full view  •  Cooking & Edit modes',
                          style: text.bodySmall?.copyWith(
                              color: const Color(0xFF55534E)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (recipe.isBraaiReady) ...[
                  const _BraaiReadyBadge(),
                  const SizedBox(height: 4),
                ],
                _LoadsheddingBadge(friendly: recipe.isLoadsheddingFriendly),
              ],
            ),
          ],
        ),

        // ── Source URL ────────────────────────────────────────────────────
        if (recipe.sourceUrl != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Icons.link_rounded, size: 13, color: colors.onSurfaceVariant),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  recipe.sourceUrl!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ],

        const SizedBox(height: 28),

        // ── Ingredients ───────────────────────────────────────────────────
        _SectionHeading(
          icon:  Icons.egg_alt_outlined,
          label: 'Ingredients',
          count: recipe.ingredients.length,
        ),
        const SizedBox(height: 10),

        ...List.generate(recipe.ingredients.length, (i) {
          final ing  = recipe.ingredients[i];
          final done = _doneIngredients.contains(i);
          return _CheckableIngredientRow(
            ingredient: ing,
            done:       done,
            onTap:      () => _toggleIngredient(i),
          );
        }),

        const SizedBox(height: 16),

        // ── Add to shopping list button ───────────────────────────────────
        if (widget.onAddToShoppingList != null)
          OutlinedButton.icon(
            onPressed: _addUncheckedToShoppingList,
            icon:  const Icon(Icons.shopping_cart_outlined, size: 18),
            label: const Text(
              'Add to Shopping List',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF0C351E),
              side:            const BorderSide(color: Color(0xFF0C351E)),
              padding:         const EdgeInsets.symmetric(vertical: 13),
              shape:           RoundedRectangleBorder(
                                 borderRadius: BorderRadius.circular(14)),
            ),
          ),

        const SizedBox(height: 28),
        Divider(color: colors.outlineVariant, height: 1),
        const SizedBox(height: 28),

        // ── Instructions ──────────────────────────────────────────────────
        _SectionHeading(
          icon:  Icons.menu_book_outlined,
          label: 'Instructions',
          count: recipe.instructions.length,
        ),
        const SizedBox(height: 10),

        ...List.generate(recipe.instructions.length, (i) {
          final done = _doneSteps.contains(i);
          return _CheckableStepRow(
            index: i,
            text:  recipe.instructions[i],
            done:  done,
            onTap: () => _toggleStep(i),
          );
        }),

        const SizedBox(height: 28),
        Divider(color: colors.outlineVariant, height: 1),
        const SizedBox(height: 20),

        // ── Chef's Notes ──────────────────────────────────────────────────
        Row(
          children: [
            const Icon(Icons.edit_note_rounded, size: 18, color: Color(0xFF0C351E)),
            const SizedBox(width: 8),
            Text(
              "Chef's Notes",
              style: text.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color:      const Color(0xFF0C351E),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        TextField(
          controller:   _notes,
          maxLines:     null,
          minLines:     3,
          onChanged:    (_) => _saveNotes(),
          style:        text.bodyMedium,
          decoration: InputDecoration(
            hintText:    'Jot down tweaks, substitutions, or reminders…',
            hintStyle:   TextStyle(color: colors.onSurfaceVariant.withAlpha(128)),
            filled:      true,
            fillColor:   Colors.white,
            contentPadding: const EdgeInsets.all(16),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide:   BorderSide(color: colors.outlineVariant),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide:   BorderSide(color: colors.outlineVariant),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide:   const BorderSide(color: Color(0xFF0C351E), width: 1.5),
            ),
          ),
        ),

        const SizedBox(height: 32),

        // ── Action buttons ────────────────────────────────────────────────
        FilledButton.icon(
          onPressed: () => widget.onSchedule(recipe),
          icon:  const Icon(Icons.calendar_month_rounded, size: 18),
          label: const Text(
            'Schedule Meal',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFFE59B27),
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape:   RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: widget.onReset,
          icon:  const Icon(Icons.refresh_rounded, size: 18),
          label: const Text('Try another recipe'),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape:   RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
      ],
    );
  }
}

// Helper: format ingredient quantity + unit for display in the
// workspace. Delegates to the SA-metric formatter so cups/tsp/tbsp
// render as ml/g — see lib/utils/measurement_format.dart.
String _ingredientQtyLabel(Ingredient ing) => formatIngredientMeasure(ing);

// =============================================================================
// Checkable ingredient row
// =============================================================================

class _CheckableIngredientRow extends StatelessWidget {
  const _CheckableIngredientRow({
    required this.ingredient,
    required this.done,
    required this.onTap,
  });

  final Ingredient  ingredient;
  final bool        done;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return InkWell(
      onTap:        onTap,
      borderRadius: BorderRadius.circular(10),
      child: AnimatedOpacity(
        opacity:  done ? 0.38 : 1.0,
        duration: const Duration(milliseconds: 200),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Animated check circle
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width:    22,
                height:   22,
                margin:   const EdgeInsets.only(top: 1),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: done
                      ? const Color(0xFF0C351E)
                      : Colors.transparent,
                  border: Border.all(
                    color: done
                        ? const Color(0xFF0C351E)
                        : const Color(0xFFE6E2D8),
                    width: 1.5,
                  ),
                ),
                child: done
                    ? const Icon(Icons.check_rounded,
                        color: Colors.white, size: 14)
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      ingredient.name,
                      style: text.bodyMedium?.copyWith(
                        fontWeight:     FontWeight.w600,
                        decoration:     done
                            ? TextDecoration.lineThrough
                            : TextDecoration.none,
                        decorationColor: const Color(0xFF0C351E),
                      ),
                    ),
                    if (ingredient.quantity != null || ingredient.unit != null)
                      Text(
                        _ingredientQtyLabel(ingredient),
                        style: text.bodySmall?.copyWith(
                          color:      const Color(0xFF55534E),
                          decoration: done
                              ? TextDecoration.lineThrough
                              : TextDecoration.none,
                        ),
                      ),
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
// Checkable step row
// =============================================================================

class _CheckableStepRow extends StatelessWidget {
  const _CheckableStepRow({
    required this.index,
    required this.text,
    required this.done,
    required this.onTap,
  });

  final int          index;
  final String       text;
  final bool         done;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext ctx) {
    final tt     = Theme.of(ctx).textTheme;
    final colors = Theme.of(ctx).colorScheme;

    return InkWell(
      onTap:        onTap,
      borderRadius: BorderRadius.circular(10),
      child: AnimatedOpacity(
        opacity:  done ? 0.38 : 1.0,
        duration: const Duration(milliseconds: 200),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Step number / check
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width:    28,
                height:   28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: done
                      ? const Color(0xFF0C351E)
                      : colors.surfaceContainerHighest,
                ),
                child: done
                    ? const Icon(Icons.check_rounded,
                        color: Colors.white, size: 14)
                    : Text(
                        '${index + 1}',
                        style: TextStyle(
                          fontSize:   12,
                          fontWeight: FontWeight.w800,
                          color:      colors.onSurface,
                        ),
                      ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  text,
                  style: tt.bodyMedium?.copyWith(
                    height:     1.55,
                    decoration: done
                        ? TextDecoration.lineThrough
                        : TextDecoration.none,
                    decorationColor: const Color(0xFF0C351E),
                    color: done ? colors.onSurfaceVariant : null,
                  ),
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
    // Hidden per user request — see pantry_screen._LoadsheddingBadge.
    return const SizedBox.shrink();
    // ignore: dead_code
    final bg    = friendly ? _greenBg : _greyBg;
    final fg    = friendly ? _greenFg : _greyFg;
    // power_off = "no mains power needed" (works for raw/cold AND braai-adapted titles).
    final icon  = friendly ? Icons.power_off_rounded : Icons.bolt_rounded;
    final label = friendly ? 'Gas/Braai/No Power Ready' : 'Needs Power';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(22)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: fg, size: 15),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: fg,
              letterSpacing: 0.4,
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
    // Hidden per user request alongside the loadshedding badge.
    return const SizedBox.shrink();
    // ignore: dead_code
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        color:        const Color(0xFFBF360C),
        borderRadius: BorderRadius.circular(22),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.outdoor_grill_rounded, color: Colors.white, size: 14),
          SizedBox(width: 5),
          Text(
            'Braai Ready',
            style: TextStyle(
              fontSize:      11,
              fontWeight:    FontWeight.w700,
              color:         Colors.white,
              letterSpacing: 0.4,
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Ingredients list + row
// =============================================================================

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({
    required this.icon,
    required this.label,
    required this.count,
  });

  final IconData icon;
  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text   = Theme.of(context).textTheme;

    return Row(
      children: [
        Icon(icon, size: 20, color: colors.primary),
        const SizedBox(width: 8),
        Text(label, style: text.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: colors.primaryContainer,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            '$count',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: colors.onPrimaryContainer,
            ),
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// Day picker bottom sheet
// =============================================================================

class _DayPickerSheet extends StatelessWidget {
  const _DayPickerSheet({
    required this.recipe,
    required this.mealPlan,
    required this.onDaySelected,
  });

  final Recipe recipe;
  final Map<String, Recipe?> mealPlan;
  final ValueChanged<String> onDaySelected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text   = Theme.of(context).textTheme;

    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Drag handle
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: colors.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 20),

          // Header
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: colors.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.calendar_month_rounded, color: colors.primary, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Pin to a day',
                      style: text.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    Text(
                      recipe.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // Day list
          ...List.generate(_kDays.length, (i) {
            final day      = _kDays[i];
            final pinned   = mealPlan[day];
            final isSelf   = pinned?.title == recipe.title;
            final hasOther = pinned != null && !isSelf;

            return _DayTile(
              day: day,
              pinnedTitle: pinned?.title,
              isSelf: isSelf,
              hasOther: hasOther,
              onTap: () => onDaySelected(day),
            );
          }),
        ],
      ),
    );
  }
}

class _DayTile extends StatelessWidget {
  const _DayTile({
    required this.day,
    required this.pinnedTitle,
    required this.isSelf,
    required this.hasOther,
    required this.onTap,
  });

  final String  day;
  final String? pinnedTitle;
  final bool    isSelf;
  final bool    hasOther;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text   = Theme.of(context).textTheme;

    Color bgColor = Colors.transparent;
    if (isSelf)   bgColor = colors.primaryContainer.withValues(alpha: 0.6);
    if (hasOther) bgColor = colors.surfaceContainerHighest;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(14),
          border: isSelf
              ? Border.all(color: colors.primary.withValues(alpha: 0.4))
              : null,
        ),
        child: Row(
          children: [
            // Day name
            SizedBox(
              width: 100,
              child: Text(
                day,
                style: text.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: isSelf ? colors.primary : colors.onSurface,
                ),
              ),
            ),
            // Status
            Expanded(
              child: Text(
                isSelf
                    ? '✓ Already pinned'
                    : hasOther
                        ? 'Replace "${pinnedTitle!}"'
                        : 'Free',
                style: text.bodySmall?.copyWith(
                  color: isSelf
                      ? colors.primary
                      : hasOther
                          ? colors.onSurfaceVariant
                          : colors.onSurfaceVariant.withValues(alpha: 0.5),
                  fontStyle: hasOther ? FontStyle.italic : FontStyle.normal,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(
              isSelf ? Icons.check_circle_rounded : Icons.chevron_right_rounded,
              color: isSelf ? colors.primary : colors.onSurfaceVariant.withValues(alpha: 0.4),
              size: 18,
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Meal plan section
// =============================================================================

class _MealPlanSection extends StatelessWidget {
  const _MealPlanSection({
    required this.mealPlan,
    required this.onRemove,
  });

  final Map<String, Recipe?> mealPlan;
  final ValueChanged<String> onRemove;

  @override
  Widget build(BuildContext context) {
    final colors    = Theme.of(context).colorScheme;
    final text      = Theme.of(context).textTheme;
    final scheduled = _kDays.where((d) => mealPlan[d] != null).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Section header ─────────────────────────────────────────────────
        Row(
          children: [
            Icon(Icons.calendar_month_rounded, size: 20, color: colors.primary),
            const SizedBox(width: 8),
            Text(
              'This Week\'s Plan',
              style: text.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: colors.primaryContainer,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                '${scheduled.length}',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: colors.onPrimaryContainer,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),

        // ── Horizontal scroll of day cards ─────────────────────────────────
        SizedBox(
          height: 122,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: scheduled.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (context, i) {
              final day    = scheduled[i];
              final recipe = mealPlan[day]!;
              return _MealPlanCard(
                day: day,
                recipe: recipe,
                onRemove: () => onRemove(day),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _MealPlanCard extends StatelessWidget {
  const _MealPlanCard({
    required this.day,
    required this.recipe,
    required this.onRemove,
  });

  final String day;
  final Recipe recipe;
  final VoidCallback onRemove;

  // 3-letter day abbreviation shown on the card header.
  String get _abbr => day.substring(0, 3).toUpperCase();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text   = Theme.of(context).textTheme;

    return Container(
      width: 148,
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: colors.primary.withValues(alpha: 0.25)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Day chip + remove button ───────────────────────────────────
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: colors.primaryContainer,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  _abbr,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: colors.onPrimaryContainer,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
              const Spacer(),
              GestureDetector(
                onTap: onRemove,
                child: Icon(Icons.close_rounded, size: 16, color: colors.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // ── Recipe title ───────────────────────────────────────────────
          Expanded(
            child: Text(
              recipe.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: text.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: colors.onSurface,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}


// =============================================================================
// _HomeIdleView — bento home layout shown on Chow Home tab when idle
// Mirrors the master mockup: loadshedding hero → scan/paste row → quick-nav grid
// =============================================================================

class _HomeIdleView extends StatelessWidget {
  const _HomeIdleView({
    required this.savedRecipes,
    this.onNavigateToTab,
    this.onOpenCookbook,
    this.onScanCookbook,
    this.onRecipeTap,
    this.urlController,
    this.onPasteUrl,
    this.onSubmitUrl,
    this.onGenerateByName,
  });

  final List<SavedCommunityRecipe> savedRecipes;
  final void Function(int)?        onNavigateToTab;
  final VoidCallback?              onOpenCookbook;
  final VoidCallback?              onScanCookbook;
  final void Function(SavedCommunityRecipe)? onRecipeTap;
  final TextEditingController?     urlController;
  final VoidCallback?              onPasteUrl;
  final VoidCallback?              onSubmitUrl;
  /// Hooked to ScraperService.generateRecipeFromName via the parent
  /// state. Drives the "Generate any recipe" home card.
  final Future<void> Function(String name)? onGenerateByName;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // WS3: the loadshedding "POWER ON / Fire Up the Grid" surface is no
        // longer the home headline. The full _LoadsheddingSignatureCard
        // widget, service, and badges remain intact — WS5 relocates this
        // card into Community where it stays a useful playful extra (the
        // Load-Shedding Friendly recipe filter is unaffected).

        // ── Generate any recipe by name ──────────────────────────────────
        // Promoted to the top of this idle feed (was below the Link
        // Scanner) so the green-hero family — Meal Planner above ·
        // Generate Recipe here — leads the screen together.
        if (onGenerateByName != null) ...[
          _RecipeNameGeneratorCard(onGenerate: onGenerateByName!),
          const SizedBox(height: 16),
        ],

        // ── LINK SCANNER — HERO CARD ───────────────────────────────────────
        _LinkScannerHero(
          urlController: urlController,
          onPasteUrl:    onPasteUrl,
          onScanCookbook: onScanCookbook,
          onSubmitUrl:   onSubmitUrl,
        ),
        const SizedBox(height: 16),

        // ── My Recipes — single restyled pastel tile ─────────────────────
        // The Shopping/Pantry/Community tiles were redundant with the
        // bottom-nav destinations, so the 2×2 grid is gone. My Recipes
        // stays because the Profile-tab cookbook isn't visible from here.
        ValueListenableBuilder<int>(
          valueListenable: RecipeRepository.instance.updateNotifier,
          builder: (_, __, ___) => FutureBuilder<int>(
            initialData: savedRecipes.length,
            future:      RecipeRepository.instance.countAll(),
            builder: (_, snap) {
              final n = snap.data ?? 0;
              return _MyRecipesPastelTile(
                count:  n,
                onTap:  onOpenCookbook ?? () {},
              );
            },
          ),
        ),
        const SizedBox(height: 18),

        // ── SMART SUGGESTIONS — feature-flagged AI meal-idea card ─────────
        // Self-gates on `profiles.feature_flags->>'smart_suggestions'`.
        const SmartSuggestionsCard(),
        const SizedBox(height: 16),

        // ── SA daily tip ───────────────────────────────────────────────────
        const _DailyTipCard(),
      ],
    );
  }
}

// =============================================================================
// _MyRecipesPastelTile — single My Recipes shortcut for the home feed
// =============================================================================
//
// Replaces the My Recipes slot from the old 2×2 bento grid. Pastel mango
// surface with a mango accent so it sits in the same palette family as
// the dish carousel without competing with the green hero stack above.

class _MyRecipesPastelTile extends StatelessWidget {
  const _MyRecipesPastelTile({required this.count, required this.onTap});

  final int          count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Material(
      color:        Colors.transparent,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(18, 14, 16, 14),
          decoration: BoxDecoration(
            color:        const Color(0xFFFFF1D6),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: const Color(0xFFE59B27).withAlpha(70),
            ),
            boxShadow: const [
              BoxShadow(
                color:      Color(0x14E59B27),
                blurRadius: 14,
                offset:     Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 44, height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color:        const Color(0xFFE59B27),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: const Icon(
                  Icons.menu_book_rounded,
                  color: Colors.white,
                  size:  22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'My Recipes',
                      style: tt.titleMedium?.copyWith(
                        color:      const Color(0xFF6B3A07),
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      count == 0
                          ? 'Start saving recipes you love.'
                          : '$count saved · tap to open your cookbook',
                      style: tt.bodySmall?.copyWith(
                        color: const Color(0xFFB14A2A),
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded,
                  color: Color(0xFFB14A2A), size: 22),
            ],
          ),
        ),
      ),
    );
  }
}


// =============================================================================
// _MealPlannerBanner — full-width tap-to-open entry point for MealPlannerScreen
// Sits directly below the 2×2 quick-nav grid, above the daily tip card.
// =============================================================================

// =============================================================================
// _LinkScannerHero — full-width hero card for the recipe link scanner
// =============================================================================
//
// Premium gradient backdrop, oversized accent icon, headline + subhead,
// inline URL pill with paste/camera tools, and a "Scan Now →" action
// chip. Designed to anchor the top of the dashboard feed and dominate
// visual hierarchy over the slim Meal Planner banner further down.

class _LinkScannerHero extends StatelessWidget {
  const _LinkScannerHero({
    required this.urlController,
    required this.onPasteUrl,
    required this.onScanCookbook,
    required this.onSubmitUrl,
  });

  final TextEditingController? urlController;
  final VoidCallback?          onPasteUrl;
  final VoidCallback?          onScanCookbook;
  final VoidCallback?          onSubmitUrl;

  static const _gradStart = Color(0xFF0F3E2B);  // deep forest
  static const _gradMid   = Color(0xFF205B4A);  // mid forest
  static const _accent    = Color(0xFFE59B27);  // mango

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin:  Alignment.topLeft,
          end:    Alignment.bottomRight,
          colors: [_gradStart, _gradMid],
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color:        Colors.black.withValues(alpha: 0.18),
            blurRadius:   18,
            offset:       const Offset(0, 6),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header row: icon + label + headline ─────────────────────────
          Row(
            children: [
              Container(
                width:  46, height: 46,
                decoration: BoxDecoration(
                  color:        _accent,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color:        _accent.withValues(alpha: 0.45),
                      blurRadius:   14,
                      spreadRadius: 1,
                    ),
                  ],
                ),
                alignment: Alignment.center,
                child: const Icon(
                  Icons.document_scanner_rounded,
                  color: Colors.white,
                  size:  24,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize:       MainAxisSize.min,
                  children: [
                    const Text(
                      'LINK SCANNER',
                      style: TextStyle(
                        color:         _accent,
                        fontSize:      10.5,
                        fontWeight:    FontWeight.w900,
                        letterSpacing: 1.6,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Scan any recipe',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color:         Colors.white,
                        fontWeight:    FontWeight.w900,
                        letterSpacing: -0.3,
                        height:        1.1,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Paste a link, snap a photo, or pull from your clipboard — '
            'we extract the ingredients and steps instantly.',
            style: TextStyle(
              color:    Colors.white.withValues(alpha: 0.78),
              fontSize: 12.5,
              height:   1.4,
            ),
          ),
          const SizedBox(height: 14),

          // ── White input pill (URL + paste + camera) ──────────────────────
          Container(
            decoration: BoxDecoration(
              color:        Colors.white,
              borderRadius: BorderRadius.circular(14),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                const Icon(Icons.link_rounded,
                    size: 18, color: Color(0xFF55534E)),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller:      urlController,
                    keyboardType:    TextInputType.url,
                    autocorrect:     false,
                    textInputAction: TextInputAction.go,
                    onSubmitted:     (_) => onSubmitUrl?.call(),
                    style: const TextStyle(fontSize: 13.5),
                    decoration: const InputDecoration(
                      hintText:        'TikTok, Instagram, blog…',
                      hintStyle:       TextStyle(
                          color: Color(0xFFADADA7), fontSize: 13),
                      border:          InputBorder.none,
                      isDense:         true,
                      contentPadding:  EdgeInsets.symmetric(vertical: 8),
                    ),
                  ),
                ),
                _PillIconButton(
                  icon:    Icons.content_paste_rounded,
                  tooltip: 'Paste from clipboard',
                  onTap:   onPasteUrl,
                ),
                const SizedBox(width: 4),
                _PillIconButton(
                  icon:    Icons.photo_camera_outlined,
                  tooltip: 'Scan a photo',
                  onTap:   onScanCookbook,
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // ── Action chip ───────────────────────────────────────────────────
          Align(
            alignment: Alignment.centerRight,
            child: Material(
              color:        Colors.transparent,
              borderRadius: BorderRadius.circular(22),
              child: InkWell(
                onTap:        onSubmitUrl,
                borderRadius: BorderRadius.circular(22),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(16, 9, 14, 9),
                  decoration: BoxDecoration(
                    color:        _accent,
                    borderRadius: BorderRadius.circular(22),
                    boxShadow: [
                      BoxShadow(
                        color:      _accent.withValues(alpha: 0.45),
                        blurRadius: 12,
                        offset:     const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Scan Now',
                        style: TextStyle(
                          color:         Colors.white,
                          fontWeight:    FontWeight.w900,
                          fontSize:      13,
                          letterSpacing: 0.3,
                        ),
                      ),
                      SizedBox(width: 6),
                      Icon(Icons.arrow_forward_rounded,
                          color: Colors.white, size: 16),
                    ],
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

class _PillIconButton extends StatelessWidget {
  const _PillIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });
  final IconData       icon;
  final String         tooltip;
  final VoidCallback?  onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap:  onTap,
        radius: 22,
        child: Container(
          padding: const EdgeInsets.all(7),
          decoration: BoxDecoration(
            color:        const Color(0xFFFFF3E0),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Icon(
            Icons.content_paste_rounded, // overridden below
            size: 16,
          ).copyWithIcon(icon),
        ),
      ),
    );
  }
}

extension on Icon {
  Icon copyWithIcon(IconData newIcon) => Icon(
        newIcon,
        size:   size,
        color:  color ?? const Color(0xFFE59B27),
      );
}

class _MealPlannerBanner extends StatelessWidget {
  const _MealPlannerBanner();

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;

    return Material(
      color:        Colors.transparent,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => const MealPlannerScreen(),
          ),
        ),
        child: Container(
          padding: const EdgeInsets.fromLTRB(18, 16, 16, 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end:   Alignment.bottomRight,
              colors: [Color(0xFF0C351E), Color(0xFF205B4A)],
            ),
            boxShadow: const [
              BoxShadow(
                  color: Color(0x33000000),
                  blurRadius: 14,
                  offset: Offset(0, 6)),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 48, height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color:        const Color(0xFFE59B27),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(
                  Icons.calendar_month_rounded,
                  color: Colors.white,
                  size:  24,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'WEEKLY MEAL PLANNER',
                      style: tt.labelSmall?.copyWith(
                        color:         const Color(0xFFFFD7A8),
                        letterSpacing: 1.4,
                        fontWeight:    FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Plan the week',
                      style: tt.headlineSmall?.copyWith(
                        color:      Colors.white,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.3,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Map out your Mzansi meals · auto-shopping list.',
                      style: tt.bodySmall?.copyWith(
                        color: const Color(0xFFA8D2BB),
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded,
                  color: Colors.white70, size: 24),
            ],
          ),
        ),
      ),
    );
  }
}

// WS5: the LoadsheddingSignatureCard widget + its private helpers
// (_LsStatusPill, _DottedWaveformPainter) were extracted to
// lib/widgets/loadshedding_signature_card.dart as a public widget so
// CommunityHubScreen can mount the same card. Behaviour is unchanged.


// =============================================================================
// _DailyTipCard — 30 SA loadshedding-friendly recipes, cycles every 3 hours
// Each slot is shown in order; after all 30 it wraps back to slot 0.
// Manual refresh taps forward one slot immediately.
// =============================================================================

class _DailyTipCard extends StatefulWidget {
  const _DailyTipCard();
  @override
  State<_DailyTipCard> createState() => _DailyTipCardState();
}

class _DailyTipCardState extends State<_DailyTipCard> {
  // ── 30 SA recipes covering White, Coloured & Black SA food culture ─────────
  // All are braai/gas-friendly — zero electric appliances needed.
  static const _recipes = [
    // ── Braai / White SA ───────────────────────────────────────────────────
    ('🥩', 'Boerewors on the Braai',
        'Coil fresh boerewors on the grid over medium coals. Turn once after 5 min. '
        'Serve with pap, chakalaka and Mrs Balls chutney. Don\'t prick the wors — ever.'),
    ('🔥', 'Braai Chops & Boontjieslaai',
        'Marinate lamb chops in garlic, rosemary and olive oil for 1 hour. '
        'Braai 4 min per side. Serve with cold three-bean salad and fresh bread rolls.'),
    ('🌽', 'Mielies op die Braai',
        'Peel back husks, butter generously, add salt and braai spice. Re-wrap in husks '
        'and roast on coals for 20 min, turning often. Smoky, sweet, pure SA summer.'),
    ('🐟', 'Snoek Braai with Apricot Jam',
        'Butterfly a fresh snoek. Mix apricot jam, butter, garlic and dried chilli. '
        'Braai flesh-side down 8 min, flip, baste generously, cook 5 more min. '
        'Serve with white bread and more jam.'),
    ('🥩', 'Sosaties (Skewer Kebabs)',
        'Marinate cubed leg of lamb overnight in apricot jam, curry powder, sliced onion '
        'and bay leaves. Thread onto skewers, braai 3–4 min per side. '
        'The marinade is the magic — don\'t skip it.'),
    ('🍗', 'Peri-Peri Braai Chicken',
        'Halve a whole chicken (spatchcock). Rub with peri-peri paste, lemon juice and '
        'oil. Braai over indirect coals for 35–40 min, skin-side last 10 min for crispy '
        'colour. Rest 5 min before carving.'),
    ('🥓', 'Braaibroodjie (Braai Toastie)',
        'Layer white bread with mature cheddar, sliced tomato, onion rings and chutney. '
        'Butter outside of both slices. Toast in a jaffle iron over coals '
        '3–4 min per side until golden and gooey. SA\'s best braai side.'),

    // ── Potjie / Dutch-oven ────────────────────────────────────────────────
    ('🍲', 'Classic Oxtail Potjie',
        'Brown oxtail in a No. 3 potjie. Layer carrots, potatoes and celery on top. '
        'Add 500ml red wine and beef stock. Close the lid and simmer on low coals '
        '3–4 hours — do not stir. Serve with pap or rice.'),
    ('🍗', 'Chicken Potjie with Mushrooms',
        'Brown chicken portions in oil. Add whole button mushrooms, onions and a tin of '
        'tomatoes. Season with garlic, thyme and chicken spice. Cook covered over '
        'medium coals 1.5 hours. Rich, earthy, deeply South African.'),

    // ── Cape Malay / Coloured SA ───────────────────────────────────────────
    ('🍛', 'Kerrie en Rys (Curry & Rice)',
        'Fry onion until golden, add 2 tbsp Cape Malay curry powder, ginger and garlic. '
        'Add mutton pieces and cook 5 min. Add tinned tomatoes, stock and a cinnamon stick. '
        'Simmer on gas 45 min. Serve with yellow rice cooked with turmeric and raisins.'),
    ('🥟', 'Samoosas (Triangle Pastries)',
        'Fry mince with onion, peas, curry powder and coriander until cooked and dry. '
        'Wrap spoonfuls in samosa pastry strips into triangles. '
        'Deep-fry in hot oil on gas until golden. Serve with tamarind dipping sauce.'),
    ('🍞', 'Vetkoek met Mince',
        'Mix 2 cups flour, 1 tsp instant yeast, salt and water to a soft dough. '
        'Rest 30 min. Fry golf-ball-sized pieces in hot oil on gas until puffed and golden. '
        'Fill with spiced mince curry. Absolute crowd-pleaser.'),
    ('🍮', 'Koeksisters (Twisted Syrup Doughnuts)',
        'Make a simple dough, cut into long strips, braid two together and deep-fry. '
        'Immediately dip into cold sticky syrup (sugar, water, ginger, naartjie peel). '
        'The syrup crunch on the outside and soft inside is pure Cape Malay magic.'),
    ('🐠', 'Pickled Fish',
        'Fry yellowtail fillets until cooked. Simmer onion rings in vinegar, sugar, '
        'curry powder and bay leaves to make the pickle. Layer fish and onions in a dish. '
        'Pour hot pickle over. Rest 24 hours — tastes better on day two.'),

    // ── Township / Black SA ────────────────────────────────────────────────
    ('🌽', 'Pap en Sous (Stiff Pap & Tomato Relish)',
        'Bring salted water to boil in a cast iron pot. Add mealie meal slowly, '
        'stirring well. Cover and cook on low flame 20–25 min stirring every 5 min. '
        'Serve with fried onion and tomato relish spiked with chilli. Feeds a family for R20.'),
    ('🫘', 'Umngqusho (Samp & Beans)',
        'Soak samp and sugar beans overnight. Cook together in salted water on low gas '
        '2–3 hours until very soft. Season with butter, salt and pepper. '
        'Add a tin of pilchards for protein. Under R30 for a family of four.'),
    ('🐔', 'Walkie Talkies (Peri-Peri Chicken Feet)',
        'Clean chicken feet, remove nails. Boil in salted water 45 min until tender. '
        'Drain and fry in peri-peri sauce on gas until sticky and caramelised. '
        'R15 a bag — finger-licking street food gold.'),
    ('🥩', 'Mogodu (Tripe & Trotters)',
        'Clean tripe and trotters thoroughly. Boil with onion, bay leaves and salt '
        'for 2–3 hours on gas until very tender. Season with garlic, chilli and mixed herbs. '
        'Serve with stiff pap. A true township staple.'),
    ('🌽', 'Umvubo (Sour Milk & Pap)',
        'Cook stiff white maize pap on gas. Allow to cool and crumble. '
        'Mix with amasi (sour milk / maas) in a bowl. '
        'Season with a pinch of salt. Simple, cooling, nourishing — pure Zulu comfort food.'),
    ('🫘', 'Chakalaka (Spicy Vegetable Relish)',
        'Fry onion, garlic and curry powder in oil on gas. Add grated carrots, '
        'sliced peppers and a tin of baked beans. Season with chilli and mixed herbs. '
        'Simmer 10 min. Goes with everything — pap, bread, braai meat.'),
    ('🍗', 'Kota (Quarter Loaf Bunny Chow)',
        'Cut a quarter loaf, hollow out the middle. Fill with hot mutton or bean curry. '
        'Place the bread lid on top. A Soweto street food icon that needs no cutlery '
        '— just two hands and a big appetite.'),
    ('🌿', 'Isijingi (Butternut & Pap)',
        'Peel and cube butternut. Cook in water with salt until very soft. '
        'Add mealie meal slowly and stir together until a thick, sweet porridge forms. '
        'Cook on low gas 15 min. Add a spoon of butter. '
        'Warm, orange and absolutely delicious.'),

    // ── Mixed / cross-cultural SA ──────────────────────────────────────────
    ('🌭', 'Gatsby (Cape Town Sub)',
        'Fill a whole Vienna loaf with thick-cut chips, fried polony or steak strips, '
        'atchar, lettuce and a river of tomato sauce. Cut into quarters and share. '
        'A Cape Town institution — nothing hits harder at R50 for four people.'),
    ('🍱', 'Bunny Chow (Durban)',
        'Cook a spicy Durban mutton or chicken curry with lots of onion, tomato and '
        'masala. Hollow out a half loaf of white bread. Pack the hot curry inside. '
        'Use the bread "lid" to scoop. No plate needed.'),
    ('🥙', 'Braai Wrap with Chakalaka',
        'Warm flour tortillas on the braai grid. Fill with sliced boerewors, '
        'chakalaka, grated cheese and a drizzle of chutney. Roll and eat immediately. '
        'Simple, fast, satisfying — a modern SA braai shortcut.'),
    ('🍳', 'Scrambled Eggs on Braai Toast',
        'While coals are dying down, scramble eggs with butter in a cast iron pan '
        'on the grid. Toast thick-cut white bread on the grid. '
        'Pile eggs on toast, season well, add sliced tomato. Loadshedding breakfast sorted.'),
    ('🥔', 'Potato Bake in the Potjie',
        'Layer sliced potatoes, onion rings, bacon and cream in a potjie. '
        'Season each layer with garlic, salt and pepper. '
        'Cover and cook on low coals 45 min. Cheesy, creamy, no oven needed.'),
    ('🐟', 'Braai Fish Cakes',
        'Mash tinned tuna with mashed potato, spring onion, egg and mixed herbs. '
        'Shape into patties. Fry in a cast iron pan on gas until golden, 3 min per side. '
        'Serve with lemon and tartar sauce. Quick, cheap, delicious.'),
    ('🌰', 'Roosterkoek (Grid Bread)',
        'Mix 3 cups flour, 1 packet yeast, salt, sugar and water into a soft dough. '
        'Rest 1 hour. Divide into balls, flatten slightly, braai on grid over coals '
        '10–12 min per side. The ultimate braai bread — hollow and hot inside.'),
    ('☕', 'Rooibos Malva Sauce Pudding (Gas)',
        'Mix flour, sugar, apricot jam and egg into a batter. Add a cup of strong '
        'rooibos tea. Pour into a greased pot. Cook covered on very low gas flame '
        '30–35 min. Pour hot butter-cream sauce over immediately. SA dessert gold.'),
  ];

  // ── 3-hour cycle spanning 30 days ────────────────────────────────────────
  // 30 recipes × 8 slots-per-day = 240 unique 3-hour slots = 30-day full cycle.
  // Each recipe appears exactly ONCE every 30 days — same slot for all users
  // (no server needed — pure time math).  Manual skip taps ahead one slot.
  static const _kTotalSlots = 240; // 30 days × 8 slots
  int _manualOffset = 0;

  int get _index {
    // Which 3-hour slot are we in since Unix epoch?
    final slot = (DateTime.now().millisecondsSinceEpoch ~/ (1000 * 60 * 60 * 3)
                  + _manualOffset) % _kTotalSlots;
    // Map 240 slots evenly onto 30 recipes — each recipe gets exactly 8 slots
    // but they are spread across the cycle so no two consecutive slots are the same recipe.
    // We use a simple stride: recipe index = slot mod 30.
    // This means recipe 0 shows at slots 0,30,60,... and recipe 1 at slots 1,31,61,...
    // So within any 30-slot window (3.75 days) all 30 recipes appear exactly once.
    return slot % _recipes.length;
  }

  void _refresh() => setState(() => _manualOffset++);

  @override
  Widget build(BuildContext context) {
    final recipe = _recipes[_index];
    final slotNum = _index + 1;

    return Container(
      padding:    const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF0D2117), Color(0xFF0C351E)],
          begin:  Alignment.topLeft,
          end:    Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(recipe.$1, style: const TextStyle(fontSize: 28)),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        recipe.$2,
                        style: const TextStyle(
                          color:         Color(0xFF6FCF97),
                          fontSize:      10,
                          fontWeight:    FontWeight.w800,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ),
                    // Slot counter
                    Text(
                      '$slotNum/${_recipes.length}',
                      style: const TextStyle(
                        color:      Color(0x996FCF97),
                        fontSize:   10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 6),
                    // Manual refresh button
                    GestureDetector(
                      onTap: _refresh,
                      child: Container(
                        padding: const EdgeInsets.all(5),
                        decoration: BoxDecoration(
                          color:        Colors.white.withAlpha(18),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(Icons.skip_next_rounded,
                            color: Color(0xFF6FCF97), size: 14),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  recipe.$3,
                  style: const TextStyle(
                    color:    Color(0xCCFFFFFF),
                    height:   1.55,
                    fontSize: 13,
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

class _SavedRecipeDetailSheet extends StatelessWidget {
  const _SavedRecipeDetailSheet({required this.recipe});
  final SavedCommunityRecipe recipe;

  @override
  Widget build(BuildContext context) {
    final tt     = Theme.of(context).textTheme;
    final bottom = MediaQuery.of(context).padding.bottom;
    final savedOn = '${recipe.savedAt.day}/${recipe.savedAt.month}/${recipe.savedAt.year}';

    return Dialog(
      backgroundColor: const Color(0xFFF4F1EA),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 28),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.82,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
                color: const Color(0xFF0C351E),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            recipe.recipeTitle,
                            style: tt.titleLarge?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w900,
                              height: 1.2,
                            ),
                          ),
                        ),
                        GestureDetector(
                          onTap: () => Navigator.pop(context),
                          child: Container(
                            padding: const EdgeInsets.all(5),
                            decoration: BoxDecoration(
                              color: Colors.white.withAlpha(30),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Icon(Icons.close_rounded,
                                color: Colors.white, size: 18),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'by ${recipe.username}  •  Saved $savedOn',
                      style: TextStyle(
                          color: Colors.white.withAlpha(180), fontSize: 11),
                    ),
                    if (recipe.tags.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 5,
                        runSpacing: 4,
                        children: recipe.tags.take(3).map((t) => Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: Colors.white.withAlpha(20),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(t,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600)),
                        )).toList(),
                      ),
                    ],
                  ],
                ),
              ),
              // Body
              Flexible(
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(18, 18, 18, bottom + 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('About this recipe',
                                style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 13,
                                    color: Color(0xFF0C351E))),
                            const SizedBox(height: 8),
                            Text(
                              'This recipe was saved from the ChowSA community feed. '
                              'Find the original post by ${recipe.username} in the '
                              'Community tab to see the full ingredients and method.',
                              style: const TextStyle(
                                  fontSize: 13, height: 1.6,
                                  color: Color(0xFF444444)),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.groups_rounded, size: 16),
                          label: const Text('View in Community feed'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFF0C351E),
                            side: const BorderSide(color: Color(0xFF0C351E)),
                            padding: const EdgeInsets.symmetric(vertical: 13),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                      ),
                    ],
                  ),
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
// _CookbookSheet — bottom sheet listing saved community recipes
// =============================================================================

class _CookbookSheet extends StatelessWidget {
  const _CookbookSheet({required this.recipes});

  final List<SavedCommunityRecipe> recipes;

  @override
  Widget build(BuildContext context) {
    final tt     = Theme.of(context).textTheme;
    final bottom = MediaQuery.of(context).padding.bottom;

    return Container(
      decoration: const BoxDecoration(
        color:        Color(0xFFF4F1EA),
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.82,
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

          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
            child: Row(
              children: [
                const Icon(Icons.menu_book_rounded,
                    color: Color(0xFF0C351E), size: 22),
                const SizedBox(width: 10),
                Text(
                  'My Recipes',
                  style: tt.titleLarge?.copyWith(
                    fontWeight: FontWeight.w900,
                    color:      const Color(0xFF0C351E),
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color:        const Color(0xFF0C351E).withAlpha(15),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '${recipes.length} recipes',
                    style: const TextStyle(
                      color:      Color(0xFF0C351E),
                      fontSize:   12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),
          const Divider(color: Color(0xFFE6E2D8), height: 1),

          // List or empty state
          Expanded(
            child: recipes.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.bookmark_add_outlined,
                            size: 48, color: Color(0xFFBDB9B2)),
                        const SizedBox(height: 12),
                        Text('No saved recipes yet',
                            style: tt.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700)),
                        const SizedBox(height: 6),
                        Text(
                          'Tap the bookmark icon on any\nCommunity post to save it here.',
                          textAlign: TextAlign.center,
                          style: tt.bodySmall?.copyWith(
                              color: const Color(0xFF55534E), height: 1.5),
                        ),
                      ],
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                    itemCount:        recipes.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (ctx, i) {
                      final r = recipes[i];
                      return GestureDetector(
                        onTap: () => showDialog<void>(
                          context: ctx,
                          useRootNavigator: true,
                          builder: (_) => _SavedRecipeDetailSheet(recipe: r),
                        ),
                        child: Container(
                        padding:    const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color:        Colors.white,
                          borderRadius: BorderRadius.circular(18),
                          boxShadow: const [
                            BoxShadow(
                              color:      Color(0x08000000),
                              blurRadius: 6,
                              offset:     Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            Container(
                              width:  44,
                              height: 44,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color:        const Color(0xFF0C351E).withAlpha(15),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Icon(
                                Icons.restaurant_menu_rounded,
                                color: Color(0xFF0C351E),
                                size:  22,
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    r.recipeTitle,
                                    style: tt.titleSmall?.copyWith(
                                      fontWeight: FontWeight.w800,
                                      color:      const Color(0xFF111111),
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    'by ${r.username}',
                                    style: tt.bodySmall?.copyWith(
                                        color: const Color(0xFF55534E)),
                                  ),
                                  if (r.tags.isNotEmpty) ...[
                                    const SizedBox(height: 6),
                                    Wrap(
                                      spacing: 4,
                                      children: r.tags.take(2).map((t) =>
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 7, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFF0C351E)
                                                .withAlpha(12),
                                            borderRadius:
                                                BorderRadius.circular(10),
                                          ),
                                          child: Text(
                                            t,
                                            style: const TextStyle(
                                              fontSize:   10,
                                              fontWeight: FontWeight.w600,
                                              color:      Color(0xFF0C351E),
                                            ),
                                          ),
                                        ),
                                      ).toList(),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),   // Container
                      );   // GestureDetector
                    },
                  ),
          ),

          SizedBox(height: bottom + 8),
        ],
      ),
    );
  }
}

// =============================================================================
// _RecipeNameGeneratorCard — type a recipe name → AI generates the whole thing
// =============================================================================
//
// Lives on the home idle view between the Link Scanner hero and the
// quick-nav grid. Hands the typed name to ScraperService.generateRecipeFromName
// via the parent screen so the result threads into the same review/save
// flow URL-scraped recipes use.

class _RecipeNameGeneratorCard extends StatefulWidget {
  const _RecipeNameGeneratorCard({required this.onGenerate});

  final Future<void> Function(String name) onGenerate;

  @override
  State<_RecipeNameGeneratorCard> createState() =>
      _RecipeNameGeneratorCardState();
}

class _RecipeNameGeneratorCardState extends State<_RecipeNameGeneratorCard> {
  final _ctrl    = TextEditingController();
  bool _running  = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _go() async {
    final name = _ctrl.text.trim();
    if (name.isEmpty || _running) return;
    setState(() => _running = true);
    try {
      await widget.onGenerate(name);
      if (mounted) _ctrl.clear();
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 16, 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end:   Alignment.bottomRight,
          colors: [Color(0xFF0C351E), Color(0xFF205B4A)],
        ),
        boxShadow: const [
          BoxShadow(
              color: Color(0x33000000),
              blurRadius: 14,
              offset: Offset(0, 6)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 48, height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color:        const Color(0xFFE59B27),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(Icons.auto_awesome_rounded,
                    color: Colors.white, size: 24),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'GENERATE ANY RECIPE',
                      style: tt.labelSmall?.copyWith(
                        color:         const Color(0xFFFFD7A8),
                        letterSpacing: 1.4,
                        fontWeight:    FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Cook anything',
                      style: tt.headlineSmall?.copyWith(
                        color:      Colors.white,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.3,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Type a dish, get a full SA recipe.',
                      style: tt.bodySmall?.copyWith(
                        color: const Color(0xFFA8D2BB),
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _ctrl,
                  enabled:    !_running,
                  textInputAction: TextInputAction.go,
                  onSubmitted: (_) => _go(),
                  textCapitalization: TextCapitalization.sentences,
                  style: const TextStyle(color: Color(0xFF0C351E)),
                  decoration: InputDecoration(
                    hintText:  'e.g. Chicken curry, Bobotie, Tomato bredie…',
                    hintStyle: const TextStyle(color: Color(0xFF8FA89B)),
                    filled:    true,
                    fillColor: Colors.white,
                    contentPadding:
                        const EdgeInsets.fromLTRB(14, 12, 12, 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide:   BorderSide.none,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _running ? null : _go,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFE59B27),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                child: _running
                    ? const SizedBox(
                        width: 16, height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.2, color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.bolt_rounded,
                        size: 18, color: Colors.white),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// _VeganModePill — global vegan-mode switch on the home hero
// =============================================================================

class _VeganModePill extends StatelessWidget {
  const _VeganModePill();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ValueListenableBuilder<bool>(
      valueListenable: VeganMode.enabled,
      builder: (_, on, __) {
        return GestureDetector(
          onTap: () => VeganMode.set(!on),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: on
                  ? AppTheme.kBottleGreen.withAlpha(28)
                  : AppTheme.kCreamSand,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: on
                    ? AppTheme.kBottleGreen.withAlpha(120)
                    : colors.outlineVariant.withAlpha(120),
                width: 1,
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 32, height: 32,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: on
                        ? AppTheme.kBottleGreen
                        : colors.outlineVariant.withAlpha(60),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Text('🌱', style: TextStyle(fontSize: 18)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        on ? 'Vegan mode is ON' : 'Vegan mode',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize:   13.5,
                          color:      on
                              ? AppTheme.kBottleGreen
                              : colors.onSurface,
                        ),
                      ),
                      Text(
                        on
                            ? 'Recipes auto-swap to vegan alternatives.'
                            : 'Tap to swap meat / dairy / eggs for vegan options.',
                        style: TextStyle(
                          fontSize: 11,
                          color:    colors.onSurfaceVariant,
                          height:   1.3,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch.adaptive(
                  value:    on,
                  activeThumbColor: AppTheme.kBottleGreen,
                  onChanged: (v) => VeganMode.set(v),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// =============================================================================
// _SavedRecipesSection — appears on Home screen below input card
// =============================================================================

