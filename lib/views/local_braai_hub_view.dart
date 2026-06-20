// lib/views/local_braai_hub_view.dart
//
// LocalBraaiHubView — hybrid hero + chat destination.
//
// Layout:
//   ┌────────────────────────────────────────────────────────â”
//   │  AppBar (Deep Forest Green)                            │
//   ├────────────────────────────────────────────────────────┤
//   │  Daily Braai Recipe of the Day  (fixed, ~36% height)   │
//   │  • hero image gradient + emoji                          │
//   │  • recipe title + cook-time tag                         │
//   │  • power-status flags (braai / loadshedding / power)    │
//   ├────────────────────────────────────────────────────────┤
//   │  Local Braai Banter section header                     │
//   ├────────────────────────────────────────────────────────┤
//   │  Live chat feed   (Expanded, scrolls)                  │
//   │  • realtime StreamBuilder on community_channels message │
//   │  • text-only bubbles, oldest → newest                   │
//   │  • composer pinned at bottom (text + send)              │
//   └────────────────────────────────────────────────────────┘
//
// Channel resolution:
//   1. Try the user's active suburb + cooking category.
//   2. Fall back to any cooking channel (GLOBAL or otherwise).
//
// Recipe-of-the-day:
//   Deterministic by calendar date — `_dayKey()` is year * 1000 + day-of-year,
//   so every device sees the same recipe on the same day without any backend
//   coordination. New random pick at midnight local.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:flutter/services.dart';
import '../models/ingredient.dart';
import '../models/recipe.dart';
import '../services/community_hub_service.dart';
import '../services/media_quota_service.dart';
import '../services/moderation_service.dart';
import '../services/recipe_repository.dart';
import '../services/social_service.dart';
import 'channel_chat_screen.dart' show ChatMessageBubble;
import 'chat_reaction_overlay.dart';
import '../theme/app_theme.dart';
import '../widgets/mention_suggestion_field.dart';

// =============================================================================
//   Braai Recipe data
// =============================================================================

class _BraaiRecipe {
  const _BraaiRecipe({
    required this.emoji,
    required this.title,
    required this.tag,
    required this.gradientStart,
    required this.gradientEnd,
    required this.blurb,
    this.ingredients          = const <String>[],
    this.instructions         = const <String>[],
    this.isBraaiReady         = true,
    this.isLoadsheddingFriendly = false,
  });

  final String       emoji;
  final String       title;
  final String       tag;
  final Color        gradientStart;
  final Color        gradientEnd;
  final String       blurb;
  final List<String> ingredients;
  final List<String> instructions;
  final bool         isBraaiReady;
  final bool         isLoadsheddingFriendly;
  final bool         needsElectricity = false;
}

const List<_BraaiRecipe> _kBraaiRecipes = <_BraaiRecipe>[
  _BraaiRecipe(
    emoji: '🥩', title: 'Boerewors on the Coals',
    tag: '20 min · serves 4',
    gradientStart: Color(0xFFBF360C), gradientEnd: Color(0xFFD27D38),
    blurb: 'Coiled fresh wors over medium coals. Turn once after five '
           'minutes, never prick it. Serve with pap, chakalaka and Mrs Balls.',
    isBraaiReady: true, isLoadsheddingFriendly: true,
    ingredients: [
      '1 kg fresh boerewors (coiled)',
      'Braai spice / coarse salt',
      'Mrs Balls chutney',
      'Stiff pap',
      'Tin of chakalaka',
    ],
    instructions: [
      'Light coals and let them burn down to white-hot embers.',
      'Coil the boerewors flat and skewer with two crossed sticks so it stays whole on the grid.',
      'Place over medium coals, lid open. Five minutes on the first side.',
      'Flip ONCE only — never prick — and braai another five minutes.',
      'Rest two minutes before slicing. Serve with pap and chakalaka.',
    ],
  ),
  _BraaiRecipe(
    emoji: '🍢', title: 'Lamb Sosaties',
    tag: 'marinated overnight · 25 min',
    gradientStart: Color(0xFFFFCC99), gradientEnd: Color(0xFFB35A1F),
    blurb: 'Cubed leg of lamb marinated in apricot jam, curry powder, '
           'onion and bay leaves. Skewered with the marinade onions; '
           'three minutes a side over hot coals.',
    isBraaiReady: true, isLoadsheddingFriendly: true,
    ingredients: [
      '800 g leg of lamb, cubed',
      '2 onions, quartered',
      '3 tbsp apricot jam',
      '2 tbsp mild curry powder',
      '1 tbsp white vinegar',
      '2 cloves garlic, crushed',
      '6 bay leaves',
      'Sosatie skewers',
    ],
    instructions: [
      'Mix jam, curry powder, vinegar, garlic into a marinade.',
      'Toss cubed lamb and onion in the marinade; refrigerate overnight.',
      'Thread lamb, onion and a bay leaf alternately onto skewers.',
      'Braai over hot coals, three minutes a side, basting with leftover marinade.',
      'Rest two minutes; serve with yellow rice.',
    ],
  ),
  _BraaiRecipe(
    emoji: '🍗', title: 'Peri-Peri Spatchcock Chicken',
    tag: 'butterfly · 40 min',
    gradientStart: Color(0xFFFFB8A0), gradientEnd: Color(0xFFC8543A),
    blurb: 'Halve a whole chicken open. Rub with peri-peri, lemon and '
           'oil. Indirect coals for 35 to 40 min, skin-side last for that '
           'crispy gold finish.',
    isBraaiReady: true, isLoadsheddingFriendly: true,
    ingredients: [
      '1 whole chicken (1.5 kg)',
      '3 tbsp peri-peri sauce',
      '1 lemon (juice + zest)',
      '3 tbsp olive oil',
      '3 cloves garlic, crushed',
      'Salt, pepper',
    ],
    instructions: [
      'Spatchcock the chicken: cut down either side of the spine and flatten.',
      'Mix peri-peri, lemon, oil, garlic into a paste; rub all over (under skin too).',
      'Set up indirect coals — bank them to one side of the braai.',
      'Place chicken bone-side down on the cool side, lid on, 30 min.',
      'Move skin-side down over direct coals for the final 8 to 10 min, basting.',
      'Rest five minutes before carving.',
    ],
  ),
  _BraaiRecipe(
    emoji: '🐟', title: 'Snoek with Apricot Glaze',
    tag: 'flesh-side first · 15 min',
    gradientStart: Color(0xFFB7DCE3), gradientEnd: Color(0xFF35637B),
    blurb: 'Butterflied fresh snoek basted with apricot jam, butter, '
           'garlic and dried chilli. Eight minutes flesh-down, flip, '
           'baste, five more. White bread and more jam on the side.',
    isBraaiReady: true, isLoadsheddingFriendly: true,
    ingredients: [
      '1 fresh snoek, butterflied',
      '4 tbsp apricot jam',
      '50 g butter, melted',
      '2 cloves garlic, crushed',
      '1 tsp dried chilli flakes',
      'Lemon wedges',
    ],
    instructions: [
      'Whisk jam, butter, garlic and chilli into a glaze.',
      'Place snoek flesh-side down on a grid over medium coals.',
      'Eight minutes flesh-down, basting twice.',
      'Flip skin-side down; baste generously and braai another five minutes.',
      'Serve with white bread, lemon wedges and extra glaze on the side.',
    ],
  ),
  _BraaiRecipe(
    emoji: '🥓', title: 'Braaibroodjie',
    tag: 'jaffle iron · 8 min',
    gradientStart: Color(0xFFFFE2B8), gradientEnd: Color(0xFFD68A35),
    blurb: 'Mature cheddar, sliced tomato, onion rings and chutney '
           'between buttered white bread. Press in the jaffle iron over '
           'medium coals. SA\'s greatest braai side.',
    isBraaiReady: true, isLoadsheddingFriendly: true,
    ingredients: [
      '8 slices white bread',
      '200 g mature cheddar, sliced',
      '2 tomatoes, sliced',
      '1 red onion, thinly sliced',
      'Mrs Balls chutney',
      'Butter (softened)',
    ],
    instructions: [
      'Butter the outside of every slice.',
      'Layer cheddar, tomato, onion and chutney between two slices, butter facing out.',
      'Clamp into a jaffle iron, two at a time.',
      'Press over medium coals, four minutes per side, until golden.',
      'Cut diagonal and serve immediately.',
    ],
  ),
  _BraaiRecipe(
    emoji: '🥩', title: 'Lamb Chops & Boontjieslaai',
    tag: 'rosemary marinade · 12 min',
    gradientStart: Color(0xFFD9B89A), gradientEnd: Color(0xFF7E4E2D),
    blurb: 'Garlic-rosemary-olive-oil marinade for one hour. Four '
           'minutes a side over medium coals. Pair with cold three-bean '
           'salad and fresh rolls.',
    isBraaiReady: true, isLoadsheddingFriendly: true,
    ingredients: [
      '8 lamb chops',
      '4 cloves garlic, crushed',
      '2 sprigs rosemary, chopped',
      '4 tbsp olive oil',
      'Lemon zest, salt, pepper',
      '1 tin three-bean salad',
      'Fresh white rolls',
    ],
    instructions: [
      'Mix garlic, rosemary, olive oil, lemon zest into a marinade.',
      'Coat the chops; rest at room temperature for one hour.',
      'Pat dry; season with salt and pepper.',
      'Braai over medium coals, four minutes per side for medium.',
      'Rest two minutes; serve with cold three-bean salad and rolls.',
    ],
  ),
  _BraaiRecipe(
    emoji: '🌽', title: 'Mielies op die Braai',
    tag: 'roasted · 20 min',
    gradientStart: Color(0xFFFFE08A), gradientEnd: Color(0xFFE89A1A),
    blurb: 'Peel back husks, butter generously, salt and braai spice, '
           're-wrap. Roast on coals turning often. Smoky-sweet pure '
           'summer side.',
    isBraaiReady: true, isLoadsheddingFriendly: true,
    ingredients: [
      '4 fresh mielies (cobs), with husks',
      '60 g butter, softened',
      'Braai spice / Aromat',
      'Salt to taste',
    ],
    instructions: [
      'Peel husks back without removing them; pull off the silk.',
      'Smear each mielie generously with butter and dust with braai spice.',
      'Re-wrap the husks around the mielies and tie the ends with husk strips.',
      'Roast over medium coals, turning every 4 minutes, for 18 to 20 min.',
      'Peel back husks at the table; finish with extra salt.',
    ],
  ),
];

/// Deterministic recipe-of-the-day picker. Same recipe across the whole user
/// base on any given calendar day, rolls over at midnight device-local.
_BraaiRecipe _braaiRecipeOfTheDay([DateTime? now]) {
  final today  = now ?? DateTime.now();
  final dayKey = today.year * 1000
      + DateTime(today.year, today.month, today.day)
        .difference(DateTime(today.year))
        .inDays;
  return _kBraaiRecipes[dayKey % _kBraaiRecipes.length];
}

// =============================================================================
//   LocalBraaiHubView
// =============================================================================

class LocalBraaiHubView extends StatefulWidget {
  const LocalBraaiHubView({super.key});

  @override
  State<LocalBraaiHubView> createState() => _LocalBraaiHubViewState();
}

class _LocalBraaiHubViewState extends State<LocalBraaiHubView> {
  /// Resolved chat channel. Null while still loading.
  CommunityChannel? _channel;
  bool _channelLoading = true;
  Object? _channelError;

  // ── Category-scoped search (mirrors channel_chat_screen) ────────────
  bool _searchActive = false;
  String _searchQuery = '';
  final TextEditingController _searchCtrl  = TextEditingController();
  final FocusNode             _searchFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _resolveChannel();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _toggleSearch() {
    setState(() {
      _searchActive = !_searchActive;
      if (!_searchActive) {
        _searchCtrl.clear();
        _searchQuery = '';
        _searchFocus.unfocus();
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _searchFocus.requestFocus();
        });
      }
    });
  }

  /// Resolves a chat channel to use for the banter feed:
  ///   1. The user's active-suburb cooking channel (most local).
  ///   2. Any cooking channel anywhere (GLOBAL fallback).
  Future<void> _resolveChannel() async {
    try {
      final svc    = CommunityHubService.instance;
      final suburb = await svc.resolveActiveSuburb();
      final localChannels = await svc.fetchChannelsForSuburb(suburb);
      // The Braai Hub now writes to its own dedicated channel category so
      // posts here never leak into the What's Cooking thread.
      //
      // Resolution order — must mirror the Community Hub so posts written
      // from this screen land in the SAME channel the user sees when they
      // reach the Braai card via the hub. The cross-suburb fallback now
      // skips GLOBAL so we don't write into #GLOBAL-Braai when the user
      // actually belongs to Table View.
      var channel = localChannels
          .where((c) => c.category == ChannelCategory.braai)
          .cast<CommunityChannel?>()
          .firstOrNull;
      channel ??= await svc.findChannelForSuburbAndCategory(
          suburb, ChannelCategory.braai);
      channel ??= await svc.findAnyChannelForCategory(ChannelCategory.braai);
      if (!mounted) return;
      setState(() {
        _channel        = channel;
        _channelLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _channelError   = e;
        _channelLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs     = Theme.of(context).colorScheme;
    final recipe = _braaiRecipeOfTheDay();

    return Scaffold(
      backgroundColor: cs.surface,
      resizeToAvoidBottomInset: true,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(96),
        child: AppBar(
          backgroundColor: AppTheme.kBottleGreen,
          foregroundColor: Colors.white,
          elevation: 0,
          titleSpacing: 0,
          title: _searchActive
              ? _BraaiSearchField(
                  controller: _searchCtrl,
                  focusNode:  _searchFocus,
                  onChanged:  (v) => setState(() => _searchQuery = v),
                )
              : const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize:       MainAxisSize.min,
                  children: [
                    Text(
                      'Local Braai Hub',
                      style: TextStyle(fontWeight: FontWeight.w900),
                    ),
                  ],
                ),
          actions: [
            IconButton(
              icon: Icon(
                _searchActive ? Icons.close_rounded : Icons.search_rounded,
              ),
              tooltip: _searchActive
                  ? 'Close search'
                  : 'Search Braai Recipes',
              onPressed: _toggleSearch,
            ),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(40),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(10, 6, 12, 6),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.18),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(ChannelCategory.braai.emoji,
                        style: const TextStyle(fontSize: 14)),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        ChannelCategory.braai.flavourLine,
                        style: TextStyle(
                          color:      Colors.white.withValues(alpha: 0.92),
                          fontSize:   11.5,
                          fontWeight: FontWeight.w600,
                          height:     1.3,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
      // Intrinsically scrollable layout — no keyboard detection, no
      // visibility toggles. Light-mode tokens only (kAlabaster /
      // kBottleGreen).
      //
      //   • Scaffold(resizeToAvoidBottomInset: true) shrinks the body the
      //     moment the IME opens so the composer always anchors above it.
      //   • The compact hero card + banter header live inside a
      //     SingleChildScrollView at the top of a Column, so any height
      //     pressure (keyboard mid-animation, small device, font-scale
      //     up) is absorbed by the scroll viewport — overflow becomes
      //     mathematically impossible.
      //   • Chat region uses Expanded so it always takes 100% of the
      //     remaining viewport; its own ListView handles message scroll.
      body: SafeArea(
        top: false,
        bottom: false,
        child: Column(
          children: [
            SingleChildScrollView(
              physics: const ClampingScrollPhysics(),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    child: _BraaiRecipeOfTheDayCard(recipe: recipe),
                  ),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(20, 2, 20, 4),
                    child: Row(
                      children: [
                        Icon(Icons.local_fire_department_rounded,
                            size: 14, color: AppTheme.kBottleGreen),
                        SizedBox(width: 6),
                        Text(
                          'LOCAL BRAAI BANTER',
                          style: TextStyle(
                            color:         AppTheme.kBottleGreen,
                            fontSize:      10.5,
                            fontWeight:    FontWeight.w900,
                            letterSpacing: 1.2,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _channelLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _channel == null
                      ? _ChatUnavailable(error: _channelError)
                      : _BraaiHubChatBody(
                          channel:     _channel!,
                          searchQuery: _searchQuery,
                        ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
//   _BraaiRecipeOfTheDayCard — compact dashboard tile (tap = full sheet)
// =============================================================================

class _BraaiRecipeOfTheDayCard extends StatefulWidget {
  const _BraaiRecipeOfTheDayCard({required this.recipe});
  final _BraaiRecipe recipe;

  @override
  State<_BraaiRecipeOfTheDayCard> createState() =>
      _BraaiRecipeOfTheDayCardState();
}

class _BraaiRecipeOfTheDayCardState extends State<_BraaiRecipeOfTheDayCard> {
  bool _saving = false;
  bool _saved  = false;

  Future<void> _saveToMyRecipes() async {
    if (_saving || _saved) return;
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      // Build a real Recipe with the FULL hero content — title, ingredient
      // list and instructions — so My Recipes renders an actual recipe
      // instead of an empty stub. Title is the hero's title, NOT whatever
      // the chat banter happens to mention.
      await RecipeRepository.instance.insert(
        Recipe(
          title:        widget.recipe.title,
          ingredients:  widget.recipe.ingredients
              .map((s) => Ingredient(name: s))
              .toList(growable: false),
          instructions: List<String>.from(widget.recipe.instructions),
          isLoadsheddingFriendly: widget.recipe.isLoadsheddingFriendly,
          isBraaiReady:           widget.recipe.isBraaiReady,
        ),
        source: 'braai-hub-daily',
      );
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saved  = true;
      });
      messenger.showSnackBar(SnackBar(
        content:  Text('${widget.recipe.title} saved to My Recipes 🔥'),
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

  @override
  Widget build(BuildContext context) {
    final cs     = Theme.of(context).colorScheme;
    final tt     = Theme.of(context).textTheme;
    final recipe = widget.recipe;

    return Material(
      color:        AppTheme.kAlabaster,
      borderRadius: BorderRadius.circular(22),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap:        () => _openRecipeSheet(context),
        child: Container(
      decoration: BoxDecoration(
        color:        AppTheme.kAlabaster,
        borderRadius: BorderRadius.circular(22),
        border:       Border.all(
          color: cs.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Compact horizontal layout — small gradient thumb on the left,
          // title + blurb on the right. ~40-50% shorter than the legacy
          // hero so it reads as a dashboard tile, not a full takeover.
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 12, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Gradient thumb (was 112-tall full-width hero → 56×56 chip)
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      width:  56,
                      height: 56,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [recipe.gradientStart, recipe.gradientEnd],
                          begin:  Alignment.topLeft,
                          end:    Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      alignment: Alignment.center,
                      child: Text(recipe.emoji,
                          style: const TextStyle(fontSize: 28)),
                    ),
                  ],
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize:       MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'BRAAI RECIPE OF THE DAY',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color:         AppTheme.kProteaGold,
                                fontSize:      9.5,
                                fontWeight:    FontWeight.w900,
                                letterSpacing: 1.3,
                              ),
                            ),
                          ),
                          Text(
                            recipe.tag,
                            style: const TextStyle(
                              color:      AppTheme.kEarthGrey,
                              fontSize:   9.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        recipe.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: tt.titleSmall?.copyWith(
                          fontWeight:    FontWeight.w900,
                          color:         AppTheme.kMidnight,
                          letterSpacing: -0.2,
                          height:        1.1,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        recipe.blurb,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: tt.bodySmall?.copyWith(
                          color:  AppTheme.kEarthGrey,
                          height: 1.2,
                          fontSize: 11.5,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // Inline bookmark — replaces the floating corner button.
                Material(
                  color:        AppTheme.kAlabaster,
                  shape:        const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap:        (_saving || _saved) ? null : _saveToMyRecipes,
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: _saving
                          ? const SizedBox(
                              width: 14, height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: AppTheme.kProteaGold,
                              ),
                            )
                          : Icon(
                              _saved
                                  ? Icons.bookmark_rounded
                                  : Icons.bookmark_add_outlined,
                              color: AppTheme.kProteaGold,
                              size:  18,
                            ),
                    ),
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

  void _openRecipeSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context:            context,
      isScrollControlled: true,
      backgroundColor:    Colors.transparent,
      useRootNavigator:   true,
      builder: (_) => _DailyRecipeSheet(
        recipe: widget.recipe,
        onSave: (_saving || _saved) ? null : _saveToMyRecipes,
        saved:  _saved,
      ),
    );
  }
}

// ── _DailyRecipeSheet — full daily-recipe detail with ingredients + steps ─

class _DailyRecipeSheet extends StatelessWidget {
  const _DailyRecipeSheet({
    required this.recipe,
    required this.onSave,
    required this.saved,
  });

  final _BraaiRecipe   recipe;
  final VoidCallback?  onSave;
  final bool           saved;

  @override
  Widget build(BuildContext context) {
    final tt     = Theme.of(context).textTheme;
    final bottom = MediaQuery.of(context).padding.bottom;
    return Container(
      decoration: const BoxDecoration(
        color: AppTheme.kAlabaster,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.92,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 10),
          Container(
            width: 40, height: 4,
            decoration: BoxDecoration(
              color:        const Color(0xFFE6E2D8),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Hero gradient
                  Container(
                    height: 130,
                    width:  double.infinity,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [recipe.gradientStart, recipe.gradientEnd],
                        begin:  Alignment.topLeft,
                        end:    Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(22),
                    ),
                    alignment: Alignment.center,
                    child: Text(recipe.emoji,
                        style: const TextStyle(fontSize: 64)),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'BRAAI RECIPE OF THE DAY',
                    style: TextStyle(
                      color:         AppTheme.kProteaGold,
                      fontSize:      10,
                      fontWeight:    FontWeight.w900,
                      letterSpacing: 1.4,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    recipe.title,
                    style: tt.headlineSmall?.copyWith(
                      fontWeight:    FontWeight.w900,
                      color:         AppTheme.kMidnight,
                      letterSpacing: -0.3,
                      height:        1.15,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    recipe.blurb,
                    style: tt.bodyMedium?.copyWith(
                      color:  AppTheme.kEarthGrey,
                      height: 1.4,
                    ),
                  ),
                  if (recipe.ingredients.isNotEmpty) ...[
                    const SizedBox(height: 22),
                    Text('Ingredients',
                        style: tt.titleMedium?.copyWith(
                            fontWeight: FontWeight.w900)),
                    const SizedBox(height: 8),
                    for (final ing in recipe.ingredients)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text('• $ing',
                            style: const TextStyle(
                                fontSize: 14, height: 1.4)),
                      ),
                  ],
                  if (recipe.instructions.isNotEmpty) ...[
                    const SizedBox(height: 22),
                    Text('Method',
                        style: tt.titleMedium?.copyWith(
                            fontWeight: FontWeight.w900)),
                    const SizedBox(height: 8),
                    for (var i = 0; i < recipe.instructions.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          '${i + 1}. ${recipe.instructions[i]}',
                          style: const TextStyle(fontSize: 14, height: 1.45),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
          // Sticky Save CTA
          Padding(
            padding: EdgeInsets.fromLTRB(20, 12, 20, bottom + 14),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: onSave == null
                    ? null
                    : () {
                        Navigator.of(context).pop();
                        onSave!();
                      },
                icon: Icon(saved
                    ? Icons.check_circle_rounded
                    : Icons.bookmark_add_rounded, size: 18),
                label: Text(
                  saved ? 'Saved to My Recipes' : 'Save to My Recipes',
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: saved
                      ? const Color(0xFF2E7D32)
                      : AppTheme.kProteaGold,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
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
//   _BraaiHubChatBody — live banter feed + composer
// =============================================================================

class _BraaiHubChatBody extends StatefulWidget {
  const _BraaiHubChatBody({
    required this.channel,
    required this.searchQuery,
  });
  final CommunityChannel channel;
  /// Case-insensitive filter pushed down from the screen's AppBar
  /// search. Empty string = no filter, render the full feed.
  final String           searchQuery;

  @override
  State<_BraaiHubChatBody> createState() => _BraaiHubChatBodyState();
}

/// Per-bubble target for the floating reaction strip + action menu. The
/// overlay portal reads this on each rebuild — null means "nothing
/// active", non-null means "show the overlay anchored to [rect]".
class _BraaiReactionTarget {
  const _BraaiReactionTarget({required this.message, required this.rect});
  final ChannelMessage message;
  final Rect           rect;
}

class _BraaiHubChatBodyState extends State<_BraaiHubChatBody> {
  final _composer       = TextEditingController();
  final _scrollCtrl     = ScrollController();
  bool  _sending        = false;
  final Set<String> _deletedIds = {};

  /// One GlobalKey per visible message so we can read its render
  /// rectangle off the chosen tile when long-pressed, and hand that
  /// rect to ChatReactionOverlay so the emoji strip and action menu
  /// can anchor relative to the bubble.
  final Map<String, GlobalKey> _bubbleKeys = {};
  final OverlayPortalController _reactionPortal = OverlayPortalController();
  _BraaiReactionTarget? _reactionTarget;

  /// uid → handle cache backing the search filter's username branch.
  /// Hydrated lazily via `get_public_profile` for any user_ids the
  /// realtime stream emits without a join (which is every row, because
  /// the stream API can't embed `profiles`).
  final Map<String, String> _userHandleCache = {};

  Future<void> _hydrateMissingHandles(Iterable<String?> uids) async {
    final missing = uids
        .whereType<String>()
        .where((u) => !_userHandleCache.containsKey(u))
        .toSet();
    if (missing.isEmpty) return;
    final db = Supabase.instance.client;
    for (final uid in missing) {
      try {
        final res = await db
            .rpc('get_public_profile', params: {'uid': uid});
        Map<String, dynamic>? row;
        if (res is List && res.isNotEmpty) {
          row = Map<String, dynamic>.from(res.first as Map);
        } else if (res is Map) {
          row = Map<String, dynamic>.from(res);
        }
        final h = (row?['handle']   as String?)
               ?? (row?['username'] as String?);
        if (h != null && mounted) {
          setState(() => _userHandleCache[uid] = h);
        }
      } catch (_) {/* swallow */}
    }
  }

  // Optional photo attachment — picked from camera/gallery via image_picker
  // and uploaded to the `whats-cooking-pics` bucket on send. Mirrors the
  // composer in channel_chat_screen so the Braai Hub gets the same image
  // support as What's Cooking.
  XFile? _draftImage;
  bool   _uploadingImage = false;

  @override
  void dispose() {
    _composer.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  // ── Delete own message ───────────────────────────────────────────────
  //
  // Mirrors channel_chat_screen.dart exactly:
  //   • Overlay-driven delete → _runDelete (no second confirmation, since
  //     the overlay's "Delete message — This cannot be undone." IS the
  //     confirmation).
  //   • Swipe-driven delete  → AlertDialog via _confirmDeleteDialog, then
  //     _runDelete on confirm.
  //
  // The old _confirmDelete() bottom sheet (Delete / Cancel) is gone — it
  // was rendering as a double-confirmation on top of the overlay and
  // making the Braai chat feel inconsistent with the other 4 categories.

  Future<bool> _confirmDeleteDialog() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title:   const Text('Delete message?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child:     const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style:     TextButton.styleFrom(foregroundColor: Colors.red),
            child:     const Text('Delete'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _runDelete(ChannelMessage msg) async {
    if (!mounted) return;
    setState(() => _deletedIds.add(msg.id));
    try {
      await CommunityHubService.instance.deleteChannelMessage(msg);
    } catch (e) {
      if (!mounted) return;
      setState(() => _deletedIds.remove(msg.id));
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content:  Text('Could not delete: $e'),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  // ── Reaction overlay wiring ─────────────────────────────────────────
  //
  // Mirrors the channel_chat_screen flow so a long-press in Braai Hub
  // surfaces the same emoji strip + Copy / Report / Block sheet as
  // Spotted / Gatherings / The Pantry / What's Cooking. Each bubble
  // owns a GlobalKey so we can find its rect on demand.

  void _openReactionMenu(ChannelMessage msg) {
    final key = _bubbleKeys[msg.id];
    final ctx = key?.currentContext;
    if (ctx == null) return;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return;
    final origin = box.localToGlobal(Offset.zero);
    setState(() {
      _reactionTarget = _BraaiReactionTarget(
        message: msg,
        rect:    origin & box.size,
      );
    });
    _reactionPortal.show();
  }

  void _closeReactionMenu() {
    if (_reactionPortal.isShowing) _reactionPortal.hide();
    if (_reactionTarget != null) {
      setState(() => _reactionTarget = null);
    }
  }

  Future<void> _applyReaction(ChannelMessage msg, String emoji) async {
    _closeReactionMenu();
    await SocialService().toggleChannelMessageReaction(msg.id, emoji);
  }

  void _dispatchReactionMenuAction(String action) {
    final target = _reactionTarget;
    if (target == null) return;
    final msg = target.message;
    _closeReactionMenu();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      switch (action) {
        case 'copy':
          await _copyMessageText(msg);
        case 'delete':
          await _runDelete(msg);
        case 'report':
          await _reportMessage(msg);
        case 'block':
          await _blockMessageAuthor(msg);
      }
    });
  }

  Future<void> _copyMessageText(ChannelMessage msg) async {
    await Clipboard.setData(ClipboardData(text: msg.messageText));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content:  Text('Copied to clipboard.'),
      behavior: SnackBarBehavior.floating,
    ));
  }

  Future<void> _reportMessage(ChannelMessage msg) async {
    try {
      await ModerationService.instance.reportChannelMessage(msg.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content:  Text('Message reported — our team will review it.'),
        behavior: SnackBarBehavior.floating,
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content:  Text('Could not report: $e'),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  Future<void> _blockMessageAuthor(ChannelMessage msg) async {
    final uid = msg.userId;
    if (uid == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title:   const Text('Block user?'),
        content: const Text(
          "You won't see this user's messages or posts anywhere in ChowSA. "
          'You can undo this from Settings → Privacy → Blocked users.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child:     const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style:     TextButton.styleFrom(foregroundColor: Colors.red),
            child:     const Text('Block'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ModerationService.instance.blockUser(uid);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content:  Text('User blocked.'),
        behavior: SnackBarBehavior.floating,
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content:  Text('Could not block: $e'),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  void _scrollToBottom({bool force = false}) {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollCtrl.hasClients) return;
      final pos = _scrollCtrl.position;
      // Default behavior: only stay locked at bottom if the user is
      // already close to it. `force: true` (used after _send) ignores
      // the distance so a fresh post always pulls the view down.
      if (force || pos.maxScrollExtent - pos.pixels < 200) {
        _scrollCtrl.animateTo(
          pos.maxScrollExtent,
          duration: const Duration(milliseconds: 220),
          curve:    Curves.easeOut,
        );
      }
    });
  }

  Future<void> _pickImage() async {
    // Same freemium quota as the main channel chat composer.
    final ok = await MediaQuotaService.instance
        .requestUse(context, MediaKind.photo);
    if (!ok || !mounted) return;
    final source = await showModalBottomSheet<ImageSource>(
      context:         context,
      backgroundColor: AppTheme.kAlabaster,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Text('📷', style: TextStyle(fontSize: 22)),
              title:   const Text('Take a photo'),
              onTap:   () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_rounded, size: 24, color: AppTheme.kBottleGreen),
              title:   const Text('Choose from gallery'),
              onTap:   () => Navigator.pop(ctx, ImageSource.gallery),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;
    try {
      final picked = await ImagePicker().pickImage(
        source:       source,
        imageQuality: 80,
        maxWidth:     1920,
      );
      if (picked == null || !mounted) return;
      setState(() => _draftImage = picked);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content:  Text('Could not open picker: $e'),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  Future<void> _send() async {
    final text  = _composer.text.trim();
    final image = _draftImage;
    if (_sending) return;
    if (text.isEmpty && image == null) return;

    final messenger = ScaffoldMessenger.of(context);
    _composer.clear();
    setState(() {
      _sending        = true;
      _draftImage     = null;
      _uploadingImage = image != null;
    });
    try {
      String? imageUrl;
      if (image != null) {
        final bytes = await image.readAsBytes();
        imageUrl = await CommunityHubService.instance.uploadWhatsCookingImage(
          bytes,
          filename:    image.name,
          contentType: image.mimeType,
        );
      }
      await CommunityHubService.instance.postMessage(
        channelId: widget.channel.id,
        text:      text.isEmpty ? '📷' : text,
        imageUrl:  imageUrl,
      );
      // Pull the chat down to the newly-posted message regardless of the
      // user's current scroll position — the realtime stream will land
      // the row in the next frame and the post-frame scroll catches it.
      _scrollToBottom(force: true);
    } catch (e) {
      messenger.showSnackBar(SnackBar(
        content:  Text('Could not send: $e'),
        behavior: SnackBarBehavior.floating,
      ));
    } finally {
      if (mounted) {
        setState(() {
          _sending        = false;
          _uploadingImage = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Wrap the entire body in OverlayPortal so the floating emoji
    // strip + action menu can paint above the chat (including the
    // composer) when a long-press fires. Mirrors the exact same
    // pattern used in channel_chat_screen so the UX is identical
    // across Spotted / Gatherings / Pantry / What's Cooking / Braai.
    return OverlayPortal(
      controller: _reactionPortal,
      overlayChildBuilder: (_) {
        final target = _reactionTarget;
        if (target == null) return const SizedBox.shrink();
        final me   = Supabase.instance.client.auth.currentUser?.id;
        final mine = me != null && target.message.userId == me;
        return ChatReactionOverlay(
          bubbleRect:  target.rect,
          onReact:     (e) => _applyReaction(target.message, e),
          onAction:    _dispatchReactionMenuAction,
          onDismiss:   _closeReactionMenu,
          canEdit:     false,
          canDelete:   mine,
          canPin:      false,
          // Report + Block surface only on OTHER users' messages —
          // matches Play UGC policy + the rest of the hub.
          canModerate: !mine,
          isPinned:    false,
        );
      },
      child: Column(
      children: [
        Expanded(
          child: StreamBuilder<List<ChannelMessage>>(
            stream: CommunityHubService.instance.watchMessages(widget.channel.id),
            builder: (context, snap) {
              final raw = snap.data ?? const <ChannelMessage>[];
              // Dedupe by id. The realtime stream can briefly surface the
              // same row twice (initial fetch + insert event race) which
              // showed up as a "double post that disappears" in the chat.
              final seen = <String>{};
              final deduped = raw
                  .where((m) =>
                      !_deletedIds.contains(m.id) && seen.add(m.id))
                  .toList();

              // Hydrate handles for any new user_ids the cache doesn't
              // know about (search's username branch needs them).
              if (deduped.any((m) =>
                  m.userId != null &&
                  !_userHandleCache.containsKey(m.userId))) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) {
                    unawaited(
                        _hydrateMissingHandles(deduped.map((m) => m.userId)));
                  }
                });
              }

              // Apply category-scoped search filter. The query matches
              // case-insensitively against the message body, the
              // location-name string, OR the post author's resolved
              // handle (cached above).
              final q = widget.searchQuery.trim().toLowerCase();
              final filtering = q.isNotEmpty;
              final msgs = filtering
                  ? deduped.where((m) {
                      if (m.messageText.toLowerCase().contains(q)) return true;
                      final loc = (m.locationName ?? '').toLowerCase();
                      if (loc.contains(q)) return true;
                      final h = (m.authorHandle
                              ?? _userHandleCache[m.userId])
                          ?.toLowerCase();
                      return h != null && h.contains(q);
                    }).toList()
                  : deduped;

              // Chronological sort — realtime INSERTs arrive in their own
              // order and the dedup loop preserves emission order, which
              // let new posts land out of place above older ones. Sorting
              // by createdAt here guarantees the feed is always
              // ascending, oldest-first.
              msgs.sort((a, b) => a.createdAt.compareTo(b.createdAt));

              if (snap.connectionState == ConnectionState.waiting && msgs.isEmpty) {
                return const Center(child: CircularProgressIndicator());
              }
              if (msgs.isEmpty) {
                return filtering
                    ? _BraaiNoMatches(query: widget.searchQuery.trim())
                    : const _EmptyBanter();
              }
              _scrollToBottom();
              final me = Supabase.instance.client.auth.currentUser;
              return ListView.separated(
                controller:       _scrollCtrl,
                padding:          const EdgeInsets.fromLTRB(14, 8, 14, 8),
                itemCount:        msgs.length,
                separatorBuilder: (_, __) => const SizedBox(height: 6),
                itemBuilder: (_, i) {
                  final m    = msgs[i];
                  final isMe = me != null && m.userId == me.id;
                  // Unified bubble. Long-press now always opens the
                  // shared ChatReactionOverlay — emoji strip + action
                  // sheet (Copy, Report, Block for others; Copy,
                  // Delete for own). Matches Spotted / Gatherings /
                  // Pantry / What's Cooking exactly.
                  final maxBubbleW =
                      MediaQuery.of(context).size.width * 0.78;
                  final bubbleKey =
                      _bubbleKeys.putIfAbsent(m.id, () => GlobalKey());
                  Widget bubble = ChatMessageBubble(
                    message:       m,
                    isPinned:      false,
                    isAdmin:       false,
                    isOwn:         isMe,
                    isHighlighted: false,
                    onLongPress:   () => _openReactionMenu(m),
                  );
                  bubble = Align(
                    alignment: isMe
                        ? Alignment.centerRight
                        : Alignment.centerLeft,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: maxBubbleW),
                      child: KeyedSubtree(key: bubbleKey, child: bubble),
                    ),
                  );
                  if (!isMe) return bubble;
                  // Swipe-left to delete own messages — same confirm sheet
                  // as long-press. Dismissible returns false so the list
                  // state is managed by _deletedIds.
                  return Dismissible(
                    key:       ValueKey('braai_${m.id}'),
                    direction: DismissDirection.endToStart,
                    background: Container(
                      margin:  const EdgeInsets.symmetric(vertical: 2),
                      padding: const EdgeInsets.only(right: 20),
                      decoration: BoxDecoration(
                        color:        Colors.red.shade700,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      alignment: Alignment.centerRight,
                      child: const Icon(Icons.delete,
                          color: Colors.white, size: 24),
                    ),
                    confirmDismiss: (_) => _confirmDeleteDialog(),
                    onDismissed:    (_) => _runDelete(m),
                    child: bubble,
                  );
                },
              );
            },
          ),
        ),
        _Composer(
          controller:      _composer,
          sending:         _sending,
          onSend:          _send,
          draftImage:      _draftImage,
          uploadingImage:  _uploadingImage,
          onAttachImage:   _pickImage,
          onClearImage:    () => setState(() => _draftImage = null),
        ),
      ],
      ),
    );
  }
}

/// AppBar-embedded text field rendered when the user taps the Braai
/// search icon. Mirrors the in-place chat search field on the other
/// community categories so the search affordance feels uniform.
class _BraaiSearchField extends StatelessWidget {
  const _BraaiSearchField({
    required this.controller,
    required this.focusNode,
    required this.onChanged,
  });
  final TextEditingController controller;
  final FocusNode             focusNode;
  final ValueChanged<String>  onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Row(
        children: [
          Icon(Icons.search_rounded,
              color: Colors.white.withValues(alpha: 0.85), size: 18),
          const SizedBox(width: 6),
          Expanded(
            child: TextField(
              controller:      controller,
              focusNode:       focusNode,
              onChanged:       onChanged,
              textInputAction: TextInputAction.search,
              cursorColor:     Colors.white,
              style: const TextStyle(
                color:      Colors.white,
                fontSize:   14,
                fontWeight: FontWeight.w600,
              ),
              decoration: InputDecoration(
                isDense:        true,
                hintText:       'Search braai posts — name or ingredient',
                hintStyle: TextStyle(
                  color: Colors.white.withValues(alpha: 0.55),
                  fontSize: 12.5,
                ),
                border:         InputBorder.none,
                enabledBorder:  InputBorder.none,
                focusedBorder:  InputBorder.none,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
          if (controller.text.isNotEmpty)
            GestureDetector(
              onTap: () { controller.clear(); onChanged(''); },
              child: Icon(Icons.cancel_rounded,
                  color: Colors.white.withValues(alpha: 0.75), size: 18),
            ),
        ],
      ),
    );
  }
}

/// Filter-empty state for the Braai Hub feed. Replaces [_EmptyBanter]
/// so the user knows they're looking at a filtered view, not an empty
/// channel.
class _BraaiNoMatches extends StatelessWidget {
  const _BraaiNoMatches({required this.query});
  final String query;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('🔍', style: TextStyle(fontSize: 40)),
            const SizedBox(height: 10),
            Text(
              'No braai posts match "$query"',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color:      AppTheme.kMidnight,
                fontWeight: FontWeight.w800,
                fontSize:   14,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Try a different name or ingredient.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppTheme.kEarthGrey,
                fontSize: 12.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyBanter extends StatelessWidget {
  const _EmptyBanter();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('🔥', style: TextStyle(fontSize: 44)),
                  SizedBox(height: 10),
                  Text(
                    'No braai banter yet. Drop the first take!',
                    style: TextStyle(
                      color:      AppTheme.kEarthGrey,
                      fontSize:   14,
                      fontWeight: FontWeight.w700,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}


class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.sending,
    required this.onSend,
    required this.draftImage,
    required this.uploadingImage,
    required this.onAttachImage,
    required this.onClearImage,
  });
  final TextEditingController controller;
  final bool                  sending;
  final VoidCallback          onSend;
  final XFile?                draftImage;
  final bool                  uploadingImage;
  final VoidCallback          onAttachImage;
  final VoidCallback          onClearImage;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final busy = sending || uploadingImage;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        decoration: BoxDecoration(
          color: cs.surface,
          border: Border(
            top: BorderSide(
              color: cs.outlineVariant.withValues(alpha: 0.6),
              width: 0.6,
            ),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (draftImage != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Container(
                      width: 48, height: 48,
                      decoration: BoxDecoration(
                        color: cs.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: AppTheme.kProteaGold.withValues(alpha: 0.5),
                        ),
                      ),
                      alignment: Alignment.center,
                      child: const Icon(Icons.image_rounded,
                          color: AppTheme.kBottleGreen, size: 22),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        draftImage!.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize:   12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: busy ? null : onClearImage,
                      icon: const Icon(Icons.close_rounded, size: 18),
                      tooltip: 'Remove photo',
                    ),
                  ],
                ),
              ),
            Row(
              children: [
                IconButton(
                  onPressed: busy ? null : onAttachImage,
                  icon: const Icon(Icons.add_photo_alternate_rounded),
                  color: AppTheme.kBottleGreen,
                  tooltip: 'Attach a photo',
                ),
                Expanded(
                  child: MentionSuggestionField(
                    controller:      controller,
                    minLines:        1,
                    maxLines:        4,
                    textInputAction: TextInputAction.send,
                    onSubmitted:     (_) => onSend(),
                    suggestionsAbove: true,
                    decoration: const InputDecoration(
                      hintText: 'Drop a braai tip or photo plan… use @ to tag someone',
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                InkWell(
                  onTap: busy ? null : onSend,
                  borderRadius: BorderRadius.circular(28),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: const BoxDecoration(
                      color: AppTheme.kProteaGold,
                      shape: BoxShape.circle,
                    ),
                    child: busy
                        ? const SizedBox(
                            width: 18, height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.2,
                              color: AppTheme.kMidnight,
                            ),
                          )
                        : const Icon(Icons.send_rounded,
                            size: 20, color: AppTheme.kMidnight),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatUnavailable extends StatelessWidget {
  const _ChatUnavailable({this.error});
  final Object? error;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.cell_tower_rounded,
              color: AppTheme.kBottleGreen, size: 36),
          const SizedBox(height: 12),
          const Text(
            'Banter room offline',
            style: TextStyle(
              color:      AppTheme.kMidnight,
              fontSize:   16,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            error != null
                ? "Couldn't load the chat room: $error"
                : "We couldn't find a braai banter room for your suburb. "
                  "Try again in a moment.",
            textAlign: TextAlign.center,
            style: const TextStyle(
              color:    AppTheme.kEarthGrey,
              fontSize: 13,
              height:   1.4,
            ),
          ),
        ],
      ),
    );
  }
}
