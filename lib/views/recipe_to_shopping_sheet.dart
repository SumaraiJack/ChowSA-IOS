// lib/views/recipe_to_shopping_sheet.dart
//
// Cross-feature bridge between Recipe Detail and Shopping Lists.
//
// Two public entry points:
//   • showRecipeToShoppingSheet(...) — universal bulk sheet that lets the user
//     pick multiple ingredients and a target list (or create a new list).
//   • showSingleIngredientPopup(...)  — small overlay launched from a missing-
//     ingredient inline icon to send ONE item to any chosen list.
//
// Persistence: reads/writes shopping lists from the same SharedPreferences key
// as ShoppingListScreen ('shopping_lists_v1') so additions appear instantly the
// next time the user opens that screen.

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/recipe.dart';
import '../models/ingredient.dart';
import '../models/shopping_list.dart';
import '../utils/measurement_format.dart';
import 'pantry_screen.dart' show shoppingListsUpdateNotifier;

// =============================================================================
// Design tokens
// =============================================================================

const _kForest  = Color(0xFF0C351E);
const _kOrange  = Color(0xFFE59B27);
const _kCream   = Color(0xFFF4F1EA);
const _kMuted   = Color(0xFF55534E);
const _kAmber   = Color(0xFFB45309);
const _kAmberBg = Color(0xFFFFF7ED);

const _kListsPrefKey = 'shopping_lists_v1';

// =============================================================================
// Persistence helpers
// =============================================================================

Future<List<ShoppingList>> _loadLists() async {
  final prefs = await SharedPreferences.getInstance();
  final raw   = prefs.getString(_kListsPrefKey);
  if (raw == null) return [];
  try {
    final decoded = jsonDecode(raw) as List<dynamic>;
    return decoded
        .map((e) => ShoppingList.fromJson(e as Map<String, dynamic>))
        .toList();
  } catch (_) {
    return [];
  }
}

Future<void> _saveLists(List<ShoppingList> lists) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
    _kListsPrefKey,
    jsonEncode(lists.map((l) => l.toJson()).toList()),
  );
  // Broadcast the change so the main Shopping Hub (ShoppingListScreen) and
  // any other listener re-read prefs and surface the new list / items
  // instantly — without this, the Hub stays on its cached snapshot and
  // shows "0 saved lists" until the app is restarted.
  shoppingListsUpdateNotifier.value++;
}

ShoppingItem _itemFromIngredient(Ingredient ing) {
  // SA-metric label (cups/tsp/tbsp → ml/g). Splits on the last space
  // so the ShoppingItem stores qty and unit separately.
  final metric    = formatIngredientMeasure(ing);
  final lastSpace = metric.lastIndexOf(' ');
  final qty       = lastSpace < 0 ? metric : metric.substring(0, lastSpace);
  final unit      = lastSpace < 0 ? null    : metric.substring(lastSpace + 1);
  return ShoppingItem(
    id:       '${DateTime.now().microsecondsSinceEpoch}_${ing.name.hashCode}',
    name:     ing.name,
    quantity: qty.isEmpty ? null : qty,
    unit:     unit,
  );
}

// =============================================================================
// Public entry — universal bulk sheet
// =============================================================================

Future<void> showRecipeToShoppingSheet({
  required BuildContext context,
  required Recipe       recipe,
}) async {
  await showModalBottomSheet<void>(
    context:            context,
    isScrollControlled: true,
    backgroundColor:    Colors.transparent,
    builder: (_) => _BulkAddSheet(recipe: recipe),
  );
}

// =============================================================================
// Public entry — single-ingredient quick popup
// =============================================================================

Future<void> showSingleIngredientPopup({
  required BuildContext context,
  required Ingredient   ingredient,
}) async {
  await showDialog<void>(
    context: context,
    builder: (_) => _SingleIngredientDialog(ingredient: ingredient),
  );
}

// =============================================================================
// _BulkAddSheet — multi-select checklist + list picker + create-new field
// =============================================================================

class _BulkAddSheet extends StatefulWidget {
  const _BulkAddSheet({required this.recipe});
  final Recipe recipe;

  @override
  State<_BulkAddSheet> createState() => _BulkAddSheetState();
}

class _BulkAddSheetState extends State<_BulkAddSheet> {
  late final List<bool>   _selected;
  List<ShoppingList>      _lists      = [];
  String?                 _targetId;   // null = create new
  final _newListCtrl      = TextEditingController();
  bool                    _loaded     = false;
  bool                    _saving     = false;

  @override
  void initState() {
    super.initState();
    _selected = List<bool>.filled(widget.recipe.ingredients.length, true);
    _loadLists().then((lists) {
      if (!mounted) return;
      setState(() {
        _lists    = lists;
        _targetId = lists.isNotEmpty ? lists.first.id : null;
        _loaded   = true;
      });
    });
  }

  @override
  void dispose() {
    _newListCtrl.dispose();
    super.dispose();
  }

  // ── Selection helpers ───────────────────────────────────────────────────────

  int get _selectedCount => _selected.where((v) => v).length;

  void _toggleAll(bool value) =>
      setState(() {
        for (int i = 0; i < _selected.length; i++) {
          _selected[i] = value;
        }
      });

  // ── Confirm ─────────────────────────────────────────────────────────────────

  Future<void> _confirm() async {
    if (_selectedCount == 0) return;
    setState(() => _saving = true);

    // Build the items to add
    final items = <ShoppingItem>[];
    for (int i = 0; i < widget.recipe.ingredients.length; i++) {
      if (_selected[i]) {
        items.add(_itemFromIngredient(widget.recipe.ingredients[i]));
      }
    }

    // Determine target list — existing or freshly created
    ShoppingList target;
    String       targetName;

    if (_targetId == null) {
      // Create new list using the inline text field's value, or a smart default
      final typed = _newListCtrl.text.trim();
      targetName  = typed.isNotEmpty
          ? typed
          : '${widget.recipe.title} groceries';
      target = ShoppingList(
        id:    'list_${DateTime.now().microsecondsSinceEpoch}',
        name:  targetName,
        items: items,
      );
      _lists.insert(0, target);
    } else {
      target = _lists.firstWhere((l) => l.id == _targetId);
      target.items.addAll(items);
      targetName = target.name;
    }

    await _saveLists(_lists);

    if (!mounted) return;
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${items.length} ingredient${items.length == 1 ? '' : 's'} '
          'added to "$targetName" 🛒',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        backgroundColor: _kForest,
        behavior:        SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final tt     = Theme.of(context).textTheme;
    final bottom = MediaQuery.of(context).viewInsets.bottom +
        MediaQuery.of(context).padding.bottom;

    return Container(
      decoration: const BoxDecoration(
        color:        _kCream,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.86,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Drag handle ─────────────────────────────────────────────────────
          Container(
            width:  40, height: 4,
            margin: const EdgeInsets.only(top: 12, bottom: 16),
            decoration: BoxDecoration(
              color:        const Color(0xFFE6E2D8),
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // ── Header ──────────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 22),
            child: Row(
              children: [
                Container(
                  width: 44, height: 44,
                  decoration: BoxDecoration(
                    color:        _kForest,
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: const Icon(Icons.shopping_cart_rounded,
                      color: Colors.white, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Add to Shopping List',
                        style: tt.titleMedium?.copyWith(
                          fontWeight: FontWeight.w900,
                          color:      _kForest,
                        ),
                      ),
                      Text(
                        'From "${widget.recipe.title}"',
                        style: tt.bodySmall?.copyWith(color: _kMuted),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 18),

          // ── List picker section ─────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 0, 22, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'TARGET LIST',
                  style: tt.labelSmall?.copyWith(
                    color:        _kMuted,
                    letterSpacing: 1.1,
                    fontWeight:   FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  decoration: BoxDecoration(
                    color:        Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    border:       Border.all(color: const Color(0xFFE6E2D8)),
                  ),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 4),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String?>(
                      value:    _targetId,
                      isExpanded: true,
                      icon:     const Icon(
                          Icons.keyboard_arrow_down_rounded,
                          color: _kForest),
                      style: tt.bodyMedium?.copyWith(
                        color:      const Color(0xFF111111),
                        fontWeight: FontWeight.w600,
                      ),
                      onChanged: !_loaded
                          ? null
                          : (v) => setState(() => _targetId = v),
                      items: [
                        for (final list in _lists)
                          DropdownMenuItem<String?>(
                            value: list.id,
                            child: Row(
                              children: [
                                const Icon(
                                    Icons.shopping_basket_rounded,
                                    size: 16, color: _kForest),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    list.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                Text(
                                  '${list.totalCount} items',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color:    _kMuted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        const DropdownMenuItem<String?>(
                          value: null,
                          child: Row(
                            children: [
                              Icon(Icons.add_rounded,
                                  size: 16, color: _kOrange),
                              SizedBox(width: 8),
                              Text(
                                'Create new shopping list…',
                                style: TextStyle(
                                  color:      _kOrange,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // ── Inline new-list field (only when "Create new" is chosen) ──
                AnimatedSize(
                  duration: const Duration(milliseconds: 240),
                  curve:    Curves.easeOut,
                  child: _targetId == null
                      ? Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: TextFormField(
                            controller:         _newListCtrl,
                            textCapitalization: TextCapitalization.words,
                            style: tt.bodyMedium,
                            decoration: InputDecoration(
                              hintText:  '+ Create New Shopping List',
                              hintStyle: const TextStyle(
                                  color: Color(0xFFADADA7)),
                              filled:    true,
                              fillColor: Colors.white,
                              prefixIcon: const Icon(
                                  Icons.edit_outlined,
                                  size: 18, color: _kMuted),
                              contentPadding:
                                  const EdgeInsets.fromLTRB(0, 13, 14, 13),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide:   const BorderSide(
                                    color: Color(0xFFE6E2D8)),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide:   const BorderSide(
                                    color: Color(0xFFE6E2D8)),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide:   const BorderSide(
                                    color: _kForest, width: 1.5),
                              ),
                            ),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),

          const SizedBox(height: 18),

          // ── Multi-select ingredient checklist ───────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 22),
            child: Row(
              children: [
                Text(
                  'INGREDIENTS',
                  style: tt.labelSmall?.copyWith(
                    color:        _kMuted,
                    letterSpacing: 1.1,
                    fontWeight:   FontWeight.w800,
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: _selectedCount == _selected.length
                      ? () => _toggleAll(false)
                      : () => _toggleAll(true),
                  style: TextButton.styleFrom(
                    foregroundColor: _kForest,
                    textStyle: tt.labelMedium?.copyWith(
                      fontWeight: FontWeight.w700),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(
                    _selectedCount == _selected.length
                        ? 'Deselect all'
                        : 'Select all',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),

          Flexible(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
              itemCount:   widget.recipe.ingredients.length,
              itemBuilder: (_, i) {
                final ing = widget.recipe.ingredients[i];
                final on  = _selected[i];
                return InkWell(
                  onTap: () => setState(() => _selected[i] = !on),
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 6),
                    child: Row(
                      children: [
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          width: 22, height: 22,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: on ? _kForest : Colors.transparent,
                            border: Border.all(
                              color: on ? _kForest : const Color(0xFFCFCAC2),
                              width: 1.5,
                            ),
                          ),
                          child: on
                              ? const Icon(Icons.check_rounded,
                                  color: Colors.white, size: 13)
                              : null,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            formatIngredientLine(ing),
                            style: tt.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: on ? const Color(0xFF111111) : _kMuted,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),

          // ── Confirm button ─────────────────────────────────────────────────
          Padding(
            padding: EdgeInsets.fromLTRB(22, 8, 22, bottom + 16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _selectedCount == 0 || _saving ? null : _confirm,
                icon: _saving
                    ? const SizedBox(
                        width: 18, height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5, color: Colors.white),
                      )
                    : const Icon(Icons.shopping_cart_checkout_rounded, size: 18),
                label: Text(
                  _selectedCount == 0
                      ? 'Select at least one ingredient'
                      : 'Add to List ($_selectedCount)',
                  style: const TextStyle(
                    fontWeight: FontWeight.w800, fontSize: 15),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: _kOrange,
                  disabledBackgroundColor: const Color(0xFFE6E2D8),
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
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
// _SingleIngredientDialog — quick "send to one list" popup for one ingredient
// =============================================================================

class _SingleIngredientDialog extends StatefulWidget {
  const _SingleIngredientDialog({required this.ingredient});
  final Ingredient ingredient;

  @override
  State<_SingleIngredientDialog> createState() =>
      _SingleIngredientDialogState();
}

class _SingleIngredientDialogState extends State<_SingleIngredientDialog> {
  List<ShoppingList> _lists  = [];
  String?            _target;
  final _newCtrl            = TextEditingController();
  bool               _loaded = false;
  bool               _saving = false;

  @override
  void initState() {
    super.initState();
    _loadLists().then((lists) {
      if (!mounted) return;
      setState(() {
        _lists  = lists;
        _target = lists.isNotEmpty ? lists.first.id : null;
        _loaded = true;
      });
    });
  }

  @override
  void dispose() {
    _newCtrl.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() => _saving = true);
    final item = _itemFromIngredient(widget.ingredient);

    ShoppingList target;
    String       name;

    if (_target == null) {
      final typed = _newCtrl.text.trim();
      name = typed.isNotEmpty ? typed : 'Missing ingredients';
      target = ShoppingList(
        id:    'list_${DateTime.now().microsecondsSinceEpoch}',
        name:  name,
        items: [item],
      );
      _lists.insert(0, target);
    } else {
      target = _lists.firstWhere((l) => l.id == _target);
      target.items.add(item);
      name = target.name;
    }

    await _saveLists(_lists);

    if (!mounted) return;
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '"${widget.ingredient.name}" sent to "$name" 🛒',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        backgroundColor: _kForest,
        behavior:        SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;

    return Dialog(
      backgroundColor: _kCream,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 42, height: 42,
                  decoration: BoxDecoration(
                    color:        _kAmberBg,
                    borderRadius: BorderRadius.circular(12),
                    border:       Border.all(color: _kAmber.withAlpha(80)),
                  ),
                  child: const Icon(Icons.add_shopping_cart_rounded,
                      color: _kAmber, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Missing — add to list',
                        style: tt.titleSmall?.copyWith(
                          fontWeight: FontWeight.w900,
                          color:      _kForest,
                        ),
                      ),
                      Text(
                        formatIngredientLine(widget.ingredient),
                        style: tt.bodySmall?.copyWith(
                          color: _kMuted, fontStyle: FontStyle.italic),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Text(
              'Choose a list',
              style: tt.labelMedium?.copyWith(
                fontWeight: FontWeight.w700, color: _kForest),
            ),
            const SizedBox(height: 6),
            Container(
              decoration: BoxDecoration(
                color:        Colors.white,
                borderRadius: BorderRadius.circular(12),
                border:       Border.all(color: const Color(0xFFE6E2D8)),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String?>(
                  value:      _target,
                  isExpanded: true,
                  onChanged: !_loaded ? null : (v) => setState(() => _target = v),
                  items: [
                    for (final list in _lists)
                      DropdownMenuItem<String?>(
                        value: list.id,
                        child: Text(list.name,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text(
                        '+ Create new list',
                        style: TextStyle(
                            color: _kOrange, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              child: _target == null
                  ? Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: TextField(
                        controller: _newCtrl,
                        textCapitalization: TextCapitalization.words,
                        decoration: InputDecoration(
                          hintText:  'New list name',
                          filled:    true,
                          fillColor: Colors.white,
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 12),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide:   const BorderSide(
                                color: Color(0xFFE6E2D8)),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide:   const BorderSide(
                                color: Color(0xFFE6E2D8)),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide:   const BorderSide(
                                color: _kForest, width: 1.5),
                          ),
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _kMuted,
                      side:    const BorderSide(color: Color(0xFFE6E2D8)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                    onPressed: _saving ? null : _send,
                    icon: _saving
                        ? const SizedBox(
                            width: 16, height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5, color: Colors.white),
                          )
                        : const Icon(Icons.send_rounded, size: 16),
                    label: const Text('Send',
                        style: TextStyle(fontWeight: FontWeight.w800)),
                    style: FilledButton.styleFrom(
                      backgroundColor: _kForest,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
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
