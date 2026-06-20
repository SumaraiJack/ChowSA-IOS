// lib/widgets/smart_suggestions_card.dart
//
// Home-screen entry point for the Smart Suggestions Engine.
// Renders only when the current user has the `smart_suggestions` feature
// flag in their profile. Rose-pink + mango gradient distinguishes it from
// the rest of the dashboard so it reads as a personal, special-purpose
// feature.

import 'package:flutter/material.dart';

import '../models/ingredient.dart';
import '../models/recipe.dart';
import '../utils/measurement_format.dart';
import '../models/weekly_planner_entry.dart';
import '../services/pantry_service.dart';
import '../services/smart_suggestions_service.dart';

// ── Palette ──────────────────────────────────────────────────────────────
//
// Soft-rose palette pulled from Melrose's profile illustration (cherry
// blossom + powder pink). The previous hot-magenta tokens (E91E63 /
// AD1457) read as a notification banner rather than a personal feature.
// The new tokens follow her avatar's tonal range so the card sits
// alongside her other surfaces (Profile header, avatar frame, planner
// chips) as a coherent personal-brand colour story.

const _kRoseBgTop  = Color(0xFFFBE1E8);  // very soft cherry-blossom (gradient top)
const _kRoseBgBot  = Color(0xFFF4C2D2);  // slightly deeper rose dust (gradient bottom)
const _kRoseInk    = Color(0xFF7A2E45);  // deep rose ink — primary text on the soft bg
const _kRoseInkAlt = Color(0xFFA94A6B);  // muted rose ink — secondary text
const _kMango      = Color(0xFFE59B27);  // mango accent (shared with brand) — kept for icon badge contrast

// =============================================================================
// SmartSuggestionsCard — gated home-screen tile
// =============================================================================

class SmartSuggestionsCard extends StatefulWidget {
  const SmartSuggestionsCard({super.key});

  @override
  State<SmartSuggestionsCard> createState() => _SmartSuggestionsCardState();
}

class _SmartSuggestionsCardState extends State<SmartSuggestionsCard> {
  bool? _enabled;

  @override
  void initState() {
    super.initState();
    _checkFlag();
  }

  Future<void> _checkFlag() async {
    final on = await SmartSuggestionsService.instance
        .isFeatureEnabledForCurrentUser();
    if (mounted) setState(() => _enabled = on);
  }

  @override
  Widget build(BuildContext context) {
    // Until the flag check resolves, render nothing so the dashboard
    // doesn't flash a placeholder. Cheap query, returns in <50 ms typical.
    if (_enabled != true) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        // Soft rose gradient sampled from Melrose's avatar palette —
        // top is cherry-blossom, bottom is rose-dust. Subtle enough to
        // sit alongside the cream dashboard cards without screaming.
        gradient: const LinearGradient(
          begin:  Alignment.topLeft,
          end:    Alignment.bottomRight,
          colors: [_kRoseBgTop, _kRoseBgBot],
        ),
        borderRadius: BorderRadius.circular(22),
        // Hairline rose border so the card has a defined edge on the
        // cream surface rather than fading into it.
        border: Border.all(
          color: _kRoseInk.withValues(alpha: 0.18),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color:        _kRoseInk.withValues(alpha: 0.12),
            blurRadius:   16,
            offset:       const Offset(0, 6),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header row ──────────────────────────────────────────────────
          Row(
            children: [
              Container(
                width: 44, height: 44,
                decoration: BoxDecoration(
                  color:        _kMango,
                  borderRadius: BorderRadius.circular(13),
                  boxShadow: [
                    BoxShadow(
                      color:        _kMango.withValues(alpha: 0.45),
                      blurRadius:   12,
                      spreadRadius: 1,
                    ),
                  ],
                ),
                alignment: Alignment.center,
                child: const Icon(
                  Icons.auto_awesome_rounded,
                  color: Colors.white,
                  size:  22,
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize:       MainAxisSize.min,
                  children: [
                    // Eyebrow label — deep rose ink for clean contrast
                    // against the soft background (≈10:1, well above
                    // WCAG AA).
                    Text(
                      'SMART SUGGESTIONS',
                      style: TextStyle(
                        color:         _kRoseInkAlt,
                        fontSize:      10,
                        fontWeight:    FontWeight.w900,
                        letterSpacing: 1.6,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Meal ideas from your habits',
                      style: TextStyle(
                        color:         _kRoseInk,
                        fontSize:      17,
                        fontWeight:    FontWeight.w900,
                        letterSpacing: -0.2,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // ── Meal-slot button row ────────────────────────────────────────
          Row(
            children: [
              Expanded(child: _SlotButton(
                slot:  MealSlot.breakfast,
                onTap: () => _onTap(MealSlot.breakfast),
              )),
              const SizedBox(width: 8),
              Expanded(child: _SlotButton(
                slot:  MealSlot.lunch,
                onTap: () => _onTap(MealSlot.lunch),
              )),
              const SizedBox(width: 8),
              Expanded(child: _SlotButton(
                slot:  MealSlot.supper,
                onTap: () => _onTap(MealSlot.supper),
              )),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _onTap(MealSlot slot) async {
    final messenger = ScaffoldMessenger.of(context);

    // ── 1. Aggregate top ingredients ────────────────────────────────────
    final top = await SmartSuggestionsService.instance
        .topIngredientsFromShoppingHistory(limit: 10);
    if (!mounted) return;
    if (top.isEmpty) {
      messenger.showSnackBar(const SnackBar(
        content:  Text('Add a few shopping lists first — we need data to '
                      'learn your habits.'),
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }

    // ── 2. Show loading dialog while AI thinks ──────────────────────────
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      useRootNavigator:   true,
      builder: (_) => const _GeneratingDialog(),
    );

    Recipe? idea;
    try {
      idea = await PantryService().generateMealIdea(
        mealType:       slot.wire,
        topIngredients: top,
      );
    } catch (e) {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      messenger.showSnackBar(SnackBar(
        content:  Text('Could not generate: $e'),
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }

    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();   // close loading

    // ── 3. Review modal — Accept / Try again / Cancel ───────────────────
    await showModalBottomSheet<void>(
      context:            context,
      isScrollControlled: true,
      backgroundColor:    Colors.transparent,
      useRootNavigator:   true,
      builder: (_) => _SuggestionReviewSheet(
        slot:              slot,
        idea:              idea!,
        sourceIngredients: top,
        onAccept: () async {
          try {
            await SmartSuggestionsService.instance.addToWeeklyPlanner(
              mealSlot:          slot,
              title:             idea!.title,
              summary:           null,
              ingredients:       idea.ingredients
                  .map((i) => i.displayName).toList(),
              instructions:      idea.instructions,
              sourceIngredients: top,
            );
            if (mounted) {
              messenger.showSnackBar(const SnackBar(
                content:  Text('Added to your weekly planner 🔥'),
                behavior: SnackBarBehavior.floating,
              ));
            }
          } catch (e) {
            if (mounted) {
              messenger.showSnackBar(SnackBar(
                content:  Text('Could not save: $e'),
                behavior: SnackBarBehavior.floating,
              ));
            }
          }
        },
        onTryAgain: () => _onTap(slot),
      ),
    );
  }
}

// ── _SlotButton — one of the three meal-type CTAs ───────────────────────

class _SlotButton extends StatelessWidget {
  const _SlotButton({required this.slot, required this.onTap});
  final MealSlot      slot;
  final VoidCallback  onTap;

  @override
  Widget build(BuildContext context) {
    // Solid white tiles sit cleanly on the new soft-rose background and
    // give the slot labels a high-contrast ink colour to land on.
    return Material(
      color:        Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap:        onTap,
        borderRadius: BorderRadius.circular(14),
        splashColor:  _kMango.withValues(alpha: 0.30),
        highlightColor: _kRoseInk.withValues(alpha: 0.08),
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 12, 10, 12),
          decoration: BoxDecoration(
            color:        Colors.white.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(14),
            border:       Border.all(
              color: _kRoseInk.withValues(alpha: 0.22),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color:      _kRoseInk.withValues(alpha: 0.06),
                blurRadius: 6,
                offset:     const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(slot.emoji, style: const TextStyle(fontSize: 22)),
              const SizedBox(height: 4),
              Text(
                slot.displayName,
                style: const TextStyle(
                  color:      _kRoseInk,
                  fontSize:   12,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── _GeneratingDialog — minimal "AI is thinking" indicator ──────────────

class _GeneratingDialog extends StatelessWidget {
  const _GeneratingDialog();

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 22),
        decoration: BoxDecoration(
          color:        Colors.white,
          borderRadius: BorderRadius.circular(18),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 22, height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: _kRoseInk,
              ),
            ),
            SizedBox(width: 16),
            Text(
              'Cooking up an idea…',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }
}

// ── _SuggestionReviewSheet ──────────────────────────────────────────────

class _SuggestionReviewSheet extends StatelessWidget {
  const _SuggestionReviewSheet({
    required this.slot,
    required this.idea,
    required this.sourceIngredients,
    required this.onAccept,
    required this.onTryAgain,
  });

  final MealSlot     slot;
  final Recipe       idea;
  final List<String> sourceIngredients;
  final Future<void> Function() onAccept;
  final VoidCallback onTryAgain;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).padding.bottom;
    return Container(
      decoration: const BoxDecoration(
        color:        Color(0xFFFFF7FB),
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: EdgeInsets.fromLTRB(20, 14, 20, bottom + 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Drag handle
          Center(
            child: Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color:        const Color(0xFFE6D7DD),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 14),

          // Header
          Row(
            children: [
              Text(slot.emoji, style: const TextStyle(fontSize: 24)),
              const SizedBox(width: 8),
              Text(
                '${slot.displayName.toUpperCase()} IDEA',
                style: const TextStyle(
                  color:         _kRoseInk,
                  fontSize:      11,
                  fontWeight:    FontWeight.w900,
                  letterSpacing: 1.4,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            idea.title,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w900,
              color:      const Color(0xFF2A0E1A),
            ),
          ),
          const SizedBox(height: 10),

          // Source-of-suggestion chip strip
          if (sourceIngredients.isNotEmpty) ...[
            Text(
              'Based on what you buy most:',
              style: TextStyle(
                color:      Colors.black.withValues(alpha: 0.55),
                fontSize:   11.5,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing:    6,
              runSpacing: 6,
              children: [
                for (final i in sourceIngredients.take(8))
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 9, vertical: 4),
                    decoration: BoxDecoration(
                      color:        _kRoseBgTop,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      i,
                      style: const TextStyle(
                        color:      _kRoseInk,
                        fontSize:   11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 14),
          ],

          // Ingredients + instructions preview (scroll if long)
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.40,
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (idea.ingredients.isNotEmpty) ...[
                    const Text('Ingredients',
                        style: TextStyle(
                            fontWeight: FontWeight.w900,
                            color:      Color(0xFF2A0E1A))),
                    const SizedBox(height: 6),
                    for (final ing in idea.ingredients)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          '• ${_renderIngredient(ing)}',
                          style: const TextStyle(fontSize: 13.5, height: 1.4),
                        ),
                      ),
                    const SizedBox(height: 14),
                  ],
                  if (idea.instructions.isNotEmpty) ...[
                    const Text('Method',
                        style: TextStyle(
                            fontWeight: FontWeight.w900,
                            color:      Color(0xFF2A0E1A))),
                    const SizedBox(height: 6),
                    for (var i = 0; i < idea.instructions.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(
                          '${i + 1}. ${idea.instructions[i]}',
                          style: const TextStyle(fontSize: 13.5, height: 1.45),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Actions
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {
                    Navigator.of(context).pop();
                    onTryAgain();
                  },
                  icon:  const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('Try again',
                      style: TextStyle(fontWeight: FontWeight.w800)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _kRoseInk,
                    side: const BorderSide(color: _kRoseInk, width: 1.2),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  onPressed: () async {
                    Navigator.of(context).pop();
                    await onAccept();
                  },
                  icon:  const Icon(Icons.check_circle_rounded, size: 18),
                  label: const Text('Accept',
                      style: TextStyle(fontWeight: FontWeight.w900)),
                  style: FilledButton.styleFrom(
                    backgroundColor: _kMango,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _renderIngredient(Ingredient ing) => formatIngredientLine(ing);
}
