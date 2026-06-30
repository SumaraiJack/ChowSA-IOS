// lib/views/shopping_list_screen.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'pantry_screen.dart' show shoppingListsUpdateNotifier;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import '../models/shopping_list.dart';
import '../utils/mzansi_lexicon.dart';
// SharedAssetsService and SocialService were the old indirection layers for
// the Share-List action — they're gone now that _sendToUser does the
// profiles .ilike() lookup + shopping_list_shares upsert inline. The
// services still exist for other call-sites (Kitchen Circle, Braai planner).
import '../services/entitlement_service.dart';
import '../services/friends_service.dart';
import '../services/price_estimate_service.dart';
import '../services/inbox_share_service.dart';
import '../widgets/animated_emoji.dart';

// =============================================================================
// Design tokens
// =============================================================================

const _kForest = Color(0xFF0C351E);
const _kOrange = Color(0xFFE59B27);
const _kCream  = Color(0xFFF4F1EA);
const _kMuted  = Color(0xFF55534E);

/// In-memory, session-scoped flag for the "Tips for better Estimates" hint
/// banner inside an active shopping list. Set to true when the user taps the
/// ✕ on the banner — stays true until the Dart isolate is killed (i.e. a
/// full app cold start). NOT persisted to disk by design.
bool _estimateHintDismissedThisSession = false;

// =============================================================================
// ShoppingListScreen — owns the list of ShoppingList objects
// =============================================================================

class ShoppingListScreen extends StatefulWidget {
  const ShoppingListScreen({
    super.key,
    required this.pendingItems,
    this.pendingListName,
    required this.onPendingConsumed,
    this.onShareToUser,
  });

  /// Items pushed here from the recipe workspace "Add to Shopping List" action.
  /// Screen creates a new list from them and clears via [onPendingConsumed].
  final List<ShoppingItem>                         pendingItems;
  /// Optional name carried alongside [pendingItems] when a list is being
  /// imported from the Inbox — keeps the original sender's title (e.g.
  /// "Bolognaise List") instead of the generic "New List" fallback.
  final String?                                    pendingListName;
  final VoidCallback                               onPendingConsumed;
  /// Called when the user shares a list to another handle.
  /// Args: (recipientHandle, ShoppingList) — async so errors surface in UI.
  final Future<void> Function(String handle, ShoppingList)? onShareToUser;

  @override
  State<ShoppingListScreen> createState() => _ShoppingListScreenState();
}

class _ShoppingListScreenState extends State<ShoppingListScreen> {
  static const _prefKey         = 'shopping_lists_v1';

  List<ShoppingList> _lists = [];
  bool               _loaded = false;

  // Which list is currently open (null = showing overview grid).
  ShoppingList? _activeList;

  @override
  void initState() {
    super.initState();
    _loadFromPrefs();
    // Reload from prefs whenever the pantry-side writer bumps the version.
    // This screen sits in an IndexedStack so initState only fires once —
    // without this listener, pantry-scan additions stay invisible until
    // the app is killed and relaunched.
    shoppingListsUpdateNotifier.addListener(_onExternalUpdate);
  }

  @override
  void dispose() {
    shoppingListsUpdateNotifier.removeListener(_onExternalUpdate);
    super.dispose();
  }

  void _onExternalUpdate() {
    // Re-read prefs. The pantry path wrote new items into the same key
    // we just deserialised in initState, so a plain reload picks them up.
    _loadFromPrefs();
  }

  @override
  void didUpdateWidget(ShoppingListScreen old) {
    super.didUpdateWidget(old);
    // Consume any items injected from another screen.
    if (widget.pendingItems.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _importPending());
    }
  }

  // ── Persistence ─────────────────────────────────────────────────────────────

  Future<void> _loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final raw   = prefs.getString(_prefKey);
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw) as List<dynamic>;
        final loaded  = decoded.map((e) => ShoppingList.fromJson(e as Map<String, dynamic>)).toList();
        if (mounted) {
          setState(() {
            _lists  = loaded;
            _loaded = true;
            // If the active list still exists in the freshly-loaded data,
            // re-bind to that instance so any new pantry-side items
            // appear inside the open list view; otherwise drop the
            // selection so the user lands on the overview grid.
            final id = _activeList?.id;
            _activeList = id == null
                ? null
                : loaded.where((l) => l.id == id).firstOrNull;
          });
        }
        return;
      } catch (_) { /* fallthrough */ }
    }
    if (mounted) setState(() => _loaded = true);
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, jsonEncode(_lists.map((l) => l.toJson()).toList()));
  }

  // ── List management ──────────────────────────────────────────────────────────

  void _importPending() {
    if (widget.pendingItems.isEmpty) return;
    final newList = ShoppingList(
      id:    DateTime.now().millisecondsSinceEpoch.toString(),
      // Keep the original sender's title when present (Inbox shared
      // imports), fall back to the generic copy for unnamed grabs.
      name:  (widget.pendingListName?.trim().isNotEmpty ?? false)
          ? widget.pendingListName!.trim()
          : 'New List',
      items: List.from(widget.pendingItems),
    );
    setState(() {
      _lists = [newList, ..._lists];
      _activeList = newList;
    });
    _save();
    widget.onPendingConsumed();
  }

  /// Hard cap for the free tier — three local lists. Pro is unlimited
  /// and additionally gets cloud-sync + in-app family sharing.
  static const int _kFreeShoppingListLimit = 3;

  void _createNewList() {
    if (!EntitlementService.instance.isPro &&
        _lists.length >= _kFreeShoppingListLimit) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          "Free tier keeps up to $_kFreeShoppingListLimit local lists. "
          'Delete one to free a slot, or upgrade to ChowSA Pro for '
          'unlimited cloud-synced lists.',
        ),
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }
    final newList = ShoppingList(
      id:   DateTime.now().millisecondsSinceEpoch.toString(),
      name: 'New List',
    );
    setState(() {
      _lists = [newList, ..._lists];
      _activeList = newList;
    });
    _save();
  }

  void _deleteList(ShoppingList list) {
    setState(() {
      _lists      = _lists.where((l) => l.id != list.id).toList();
      _activeList = null;
    });
    _save();
  }

  void _renameList(ShoppingList list, String newName) {
    setState(() {
      list.name = newName;
    });
    _save();
  }

  void _toggleItem(ShoppingList list, ShoppingItem item) {
    final willBeChecked = !item.checked;
    setState(() {
      final idx = list.items.indexWhere((i) => i.id == item.id);
      if (idx != -1) {
        list.items[idx] = item.copyWith(checked: willBeChecked);
      }
    });
    _save();
    // WS2: when an item gets ticked off, surface the optional "paid R__"
    // capture. It's a tiny bottom sheet — Skip leaves the row in price_points
    // untouched, so the core check-off flow is never blocked.
    if (willBeChecked && mounted) {
      _promptPaidPrice(item);
    }
  }

  // ── Budget (WS2) ────────────────────────────────────────────────────────────

  void _setBudget(ShoppingList list, double? budget) {
    setState(() => list.budgetZar = budget);
    _save();
  }

  // ── Paid R__ capture (WS2) ──────────────────────────────────────────────────
  //
  // Optional crowd-price log fired the moment a user ticks an item. Skippable,
  // dismissible, never blocks the check-off. Inserts into `price_points` with
  // the user's id (RLS-enforced). A failed insert is silently swallowed —
  // crowd data is a nice-to-have, not a blocker for the shopping flow.

  Future<void> _promptPaidPrice(ShoppingItem item) async {
    // Skip the prompt when there's no auth session — RLS would reject the
    // insert anyway and there's no point pestering the user.
    if (Supabase.instance.client.auth.currentSession == null) return;

    final priceCtrl = TextEditingController();
    final storeCtrl = TextEditingController();

    final captured = await showModalBottomSheet<bool>(
      context:            context,
      isScrollControlled: true,
      backgroundColor:    Colors.transparent,
      builder: (sheetCtx) {
        final tt = Theme.of(sheetCtx).textTheme;
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(sheetCtx).viewInsets.bottom,
          ),
          child: Container(
            decoration: const BoxDecoration(
              color: Color(0xFFF8F6F1),
              borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
            ),
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 36, height: 4,
                    decoration: BoxDecoration(
                      color:        const Color(0xFFD8D3C8),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  'Paid for "${item.name}"?',
                  style: tt.titleMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                    color:      _kForest,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Optional — helps Aunty Chow learn real SA prices.',
                  style: tt.bodySmall?.copyWith(color: _kMuted),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: priceCtrl,
                  autofocus:  true,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    prefixText: 'R ',
                    hintText:   'e.g. 18.50',
                    filled:     true,
                    fillColor:  Colors.white,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.all(Radius.circular(12)),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: storeCtrl,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    hintText:  'Store (optional) — Checkers, PnP…',
                    filled:    true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.all(Radius.circular(12)),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(sheetCtx, false),
                        child: const Text('Skip'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: _kOrange,
                        ),
                        onPressed: () => Navigator.pop(sheetCtx, true),
                        child: const Text('Save'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );

    if (captured != true) {
      priceCtrl.dispose();
      storeCtrl.dispose();
      return;
    }

    final price = double.tryParse(priceCtrl.text.trim().replaceAll(',', '.'));
    final store = storeCtrl.text.trim();
    priceCtrl.dispose();
    storeCtrl.dispose();
    if (price == null || price <= 0) return;

    final normalized = item.name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (normalized.isEmpty) return;

    try {
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId == null) return;
      await Supabase.instance.client.from('price_points').insert({
        'raw_name':        item.name,
        'normalized_name': normalized,
        'price_zar':       double.parse(price.toStringAsFixed(2)),
        if (store.isNotEmpty) 'store': store,
        'user_id':         userId,
      });
      // TODO(WS2): once enough rows accumulate, an aggregate RPC will surface
      // the median for this normalized_name into price_cache as source='crowd'
      // so estimates self-improve. Tracked under WS6 specials follow-on.
    } catch (_) {
      // Best-effort — crowd capture must never break the shopping flow.
    }
  }

  void _addItemToList(ShoppingList list, String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;

    // Run the typed string through the comprehensive MzansiLexicon (250+
    // SA brands and culinary terms) BEFORE assigning category state.
    // Returns null when no SA brand/term matches — the ShoppingItem
    // constructor then falls through to the generic keyword categoriser.
    final mzansiCategory = MzansiLexicon.tryLookupCategory(trimmed);

    final item = ShoppingItem(
      id:       '${list.id}_${DateTime.now().millisecondsSinceEpoch}',
      name:     trimmed,
      category: mzansiCategory,  // null → ShoppingItem auto-fallback to
                                 //         categoriseIngredient()
    );
    setState(() => list.items.add(item));
    _save();
  }

  void _deleteItem(ShoppingList list, ShoppingItem item) {
    setState(() => list.items.removeWhere((i) => i.id == item.id));
    _save();
  }

  void _clearChecked(ShoppingList list) {
    setState(() => list.items.removeWhere((i) => i.checked));
    _save();
  }

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return Scaffold(
        backgroundColor: Theme.of(context).colorScheme.surface,
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_activeList != null) {
      // The Shopping tab swaps between the lists overview and the detail
      // view INSIDE this same Scaffold (no nested Navigator), so the
      // hardware back / swipe gesture would otherwise bubble up to the
      // root Navigator and either pop the whole bottom-nav shell or close
      // the app. PopScope intercepts the system back, swallows the pop,
      // and routes it to our existing `onBack` callback so the user
      // returns to the lists overview instead — matching the in-screen
      // back arrow.
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          if (_activeList != null) {
            setState(() => _activeList = null);
          }
        },
        child: _ListDetailView(
          list:         _activeList!,
          onBack:       () { if (_activeList != null) setState(() => _activeList = null); },
          onRename:     (n) => _renameList(_activeList!, n),
          onDelete:     () => _deleteList(_activeList!),
          onToggle:     (item) => _toggleItem(_activeList!, item),
          onAdd:        (name) => _addItemToList(_activeList!, name),
          onDeleteItem: (item) => _deleteItem(_activeList!, item),
          onClearDone:  () => _clearChecked(_activeList!),
          onSetBudget:  (v) => _setBudget(_activeList!, v),
          onShareToUser: widget.onShareToUser != null
              ? (handle) async => widget.onShareToUser!(handle, _activeList!)
              : null,
        ),
      );
    }

    return _ListsOverview(
      lists:    _lists,
      onCreate: _createNewList,
      onOpen:   (l) => setState(() => _activeList = l),
      onDelete: _deleteList,
    );
  }
}

// =============================================================================
// Overview — grid of all saved shopping lists
// =============================================================================

class _ListsOverview extends StatelessWidget {
  const _ListsOverview({
    required this.lists,
    required this.onCreate,
    required this.onOpen,
    required this.onDelete,
  });

  final List<ShoppingList> lists;
  final VoidCallback        onCreate;
  final ValueChanged<ShoppingList> onOpen;
  final ValueChanged<ShoppingList> onDelete;

  @override
  Widget build(BuildContext context) {
    final tt  = Theme.of(context).textTheme;
    final cs  = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: cs.surface,
      floatingActionButton: FloatingActionButton.extended(
        onPressed:    onCreate,
        backgroundColor: _kOrange,
        foregroundColor: Colors.white,
        icon:  const Icon(Icons.add_rounded),
        label: const Text('New List', style: TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            // Header — wrapped in the same cream-card silhouette used by
            // the Chow Home hero and the Smart Pantry header so all three
            // primary surfaces share one design language.
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 28, 20, 20),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned(
                      top: 8, left: 8, right: -2, bottom: -2,
                      child: Container(
                        decoration: BoxDecoration(
                          color:        _kForest.withAlpha(20),
                          borderRadius: BorderRadius.circular(24),
                        ),
                      ),
                    ),
                    Container(
                      // Force the cream card to fill the outer Stack's full
                      // width. Without this, Stack.loose lets the Container
                      // shrink to its child's intrinsic width and the
                      // shadow Positioned above bleeds past the right
                      // edge of the visible card.
                      width:   double.infinity,
                      padding: const EdgeInsets.fromLTRB(20, 20, 20, 22),
                      decoration: BoxDecoration(
                        color:        const Color(0xFFF8F6F1),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                          color: const Color(0xFFE6E2D8),
                          width: 1,
                        ),
                      ),
                      // SizedBox forces the inner Stack to fill the cream
                      // card's content area; otherwise the Stack shrinks
                      // to the Column and the trolley docks next to the
                      // text instead of the right edge of the card.
                      child: SizedBox(
                        width: double.infinity,
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  width: 56, height: 56,
                                  decoration: BoxDecoration(
                                    color:        _kForest,
                                    borderRadius: BorderRadius.circular(18),
                                    boxShadow: const [
                                      BoxShadow(
                                          color: Color(0x3C1E4D2B),
                                          blurRadius: 20,
                                          offset: Offset(0, 6)),
                                    ],
                                  ),
                                  child: const Icon(Icons.shopping_cart_rounded,
                                      color: Colors.white, size: 28),
                                ),
                                const SizedBox(height: 20),
                                Text(
                                  'Shopping List',
                                  style: tt.displaySmall?.copyWith(
                                    fontWeight: FontWeight.w900,
                                    color:      _kForest,
                                    height:     1.0,
                                    letterSpacing: -1,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '${lists.length} saved '
                                  '${lists.length == 1 ? 'list' : 'lists'}',
                                  style: tt.bodyMedium?.copyWith(color: null),
                                ),
                              ],
                            ),
                            const Positioned(
                              right: 0,
                              top:   4,
                              child: AnimatedEmoji(
                                emoji: '🛒',
                                anim:  EmojiAnim.bounce,
                                size:  56,
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

            // Empty state
            if (lists.isEmpty)
              SliverFillRemaining(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 100),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.shopping_basket_outlined, size: 64,
                          color: const Color(0xFFBDB9B2)),
                      const SizedBox(height: 16),
                      Text('No shopping lists yet',
                          style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 6),
                      Text(
                        'Tap "+ New List" or add ingredients\nfrom a recipe to get started.',
                        textAlign: TextAlign.center,
                        style: tt.bodyMedium?.copyWith(color: null, height: 1.5),
                      ),
                    ],
                  ),
                ),
              ),

            // List grid
            if (lists.isNotEmpty)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 120),
                sliver: SliverGrid.builder(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount:    2,
                    mainAxisSpacing:   12,
                    crossAxisSpacing:  12,
                    childAspectRatio:  1.1,
                  ),
                  itemCount:   lists.length,
                  itemBuilder: (ctx, i) {
                    final list = lists[i];
                    return Dismissible(
                      key:       ValueKey(list.id),
                      // Swipe LEFT to delete — doesn't conflict with scroll
                      direction: DismissDirection.endToStart,
                      background: Container(
                        decoration: BoxDecoration(
                          color:        Colors.red.shade400,
                          borderRadius: BorderRadius.circular(24),
                        ),
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 24),
                        child: const Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.delete_outline_rounded,
                                color: Colors.white, size: 28),
                            SizedBox(height: 4),
                            Text('Delete',
                              style: TextStyle(color: Colors.white,
                                  fontWeight: FontWeight.w700, fontSize: 12)),
                          ],
                        ),
                      ),
                      confirmDismiss: (_) async {
                        return await showDialog<bool>(
                          context: ctx,
                          builder: (d) => AlertDialog(
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(20)),
                            title: const Text('Delete list?'),
                            content: Text(
                                'Delete "${list.name}"? This cannot be undone.'),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(d, false),
                                child: const Text('Cancel'),
                              ),
                              FilledButton(
                                style: FilledButton.styleFrom(
                                    backgroundColor: Colors.red),
                                onPressed: () => Navigator.pop(d, true),
                                child: const Text('Delete'),
                              ),
                            ],
                          ),
                        ) ?? false;
                      },
                      onDismissed: (_) => onDelete(list),
                      // Long-press also shows delete dialog as a backup
                      child: GestureDetector(
                        onLongPress: () async {
                          final confirm = await showDialog<bool>(
                            context: ctx,
                            builder: (d) => AlertDialog(
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(20)),
                              title: const Text('Delete list?'),
                              content: Text(
                                  'Delete "${list.name}"? This cannot be undone.'),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(d, false),
                                  child: const Text('Cancel'),
                                ),
                                FilledButton(
                                  style: FilledButton.styleFrom(
                                      backgroundColor: Colors.red),
                                  onPressed: () => Navigator.pop(d, true),
                                  child: const Text('Delete'),
                                ),
                              ],
                            ),
                          );
                          if (confirm == true) onDelete(list);
                        },
                        child: _ListCard(
                            list: list, onTap: () => onOpen(list)),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ListCard extends StatelessWidget {
  const _ListCard({required this.list, required this.onTap});

  final ShoppingList list;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tt       = Theme.of(context).textTheme;
    final progress = list.totalCount == 0 ? 0.0 : list.checkedCount / list.totalCount;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding:    const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color:        Colors.white,
          borderRadius: BorderRadius.circular(24),
          boxShadow: const [
            BoxShadow(color: Color(0x0A000000), blurRadius: 8, offset: Offset(0, 3)),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Icon
            Container(
              width: 38, height: 38,
              decoration: BoxDecoration(
                color:        _kForest.withAlpha(20),
                borderRadius: BorderRadius.circular(11),
              ),
              child: const Icon(Icons.checklist_rounded, color: _kForest, size: 20),
            ),
            const Spacer(),
            Text(
              list.name,
              maxLines:  2,
              overflow:  TextOverflow.ellipsis,
              style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w800, height: 1.2),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: LinearProgressIndicator(
                    value:           progress,
                    backgroundColor: const Color(0xFFEDE9E4),
                    color:           _kForest,
                    minHeight:       4,
                    borderRadius:    BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${list.checkedCount}/${list.totalCount}',
                  style: tt.bodySmall?.copyWith(color: null, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Detail view — shows one list with grouped categories
// =============================================================================

class _ListDetailView extends StatefulWidget {
  const _ListDetailView({
    required this.list,
    required this.onBack,
    required this.onRename,
    required this.onDelete,
    required this.onToggle,
    required this.onAdd,
    required this.onDeleteItem,
    required this.onClearDone,
    required this.onSetBudget,
    this.onShareToUser,
  });

  final ShoppingList               list;
  final VoidCallback               onBack;
  final ValueChanged<String>       onRename;
  final VoidCallback               onDelete;
  final ValueChanged<ShoppingItem> onToggle;
  final ValueChanged<String>       onAdd;
  final ValueChanged<ShoppingItem> onDeleteItem;
  final VoidCallback               onClearDone;
  /// WS2: writes the user-entered budget (or null to clear) back to the
  /// parent state which owns shared_preferences persistence.
  final ValueChanged<double?>      onSetBudget;
  /// Null when Pro sharing is unavailable (no auth / free tier).
  final Future<void> Function(String handle)? onShareToUser;

  @override
  State<_ListDetailView> createState() => _ListDetailViewState();
}

class _ListDetailViewState extends State<_ListDetailView> {
  final _addController = TextEditingController();
  final _addFocus      = FocusNode();

  // ── Estimate Total state ──────────────────────────────────────────────
  // Populated by tapping the "R Estimate" header CTA. The map is keyed by
  // each item's name (matching the AI's `original_name`) and lets the
  // tile render an inline "Est. Avg: R{n}" under the title. Grand total
  // drives the sticky summary card pinned to the bottom of the screen.
  bool                _estimating       = false;
  Map<String, double>? _itemEstimates   = null;
  /// True once an estimate run has populated [_itemEstimates] — used by
  /// the sticky basket-total card to know it should render. The grand
  /// total itself is computed on the fly via [_currentGrandTotalZar] so
  /// it updates instantly when an item flips its `checked` state.
  bool                _hasEstimate      = false;

  /// WS6: active retailer specials keyed by normalised item name. Loaded
  /// once on detail-view open from the `specials` table — best-effort,
  /// failure is silent and the badge simply doesn't render. The cache is
  /// refreshed weekly server-side, so a stale snapshot per open is fine.
  Map<String, SpecialMatch> _specials = const {};

  /// Estimate-accuracy hint banner visibility — once-per-session only.
  /// Backed by the top-level in-memory flag [_estimateHintDismissedThisSession]
  /// so dismissing the banner hides it for the rest of this app lifecycle
  /// but it returns on the next cold start. No SharedPreferences, no disk.
  bool _showEstimateHint = !_estimateHintDismissedThisSession;

  /// Live grand total — sums estimates for items the user hasn't checked
  /// off yet. Recomputed every build, so moving an item to the "Done"
  /// section drops it out of the basket card on the same frame.
  double get _currentGrandTotalZar {
    final est = _itemEstimates;
    if (est == null) return 0;
    var t = 0.0;
    for (final i in widget.list.items) {
      if (i.checked) continue;
      final qty = i.displayQuantity.trim();
      final key = qty.isEmpty ? i.name : '$qty ${i.name}';
      final v   = est[key] ?? 0;
      if (v > 0) t += v;
    }
    return t;
  }

  @override
  void initState() {
    super.initState();
    // Kick off the specials fetch on detail-view open. Off the critical
    // path — first paint never waits for it.
    unawaited(_refreshSpecials());
  }

  Future<void> _refreshSpecials() async {
    final svc = PriceEstimateService.instance;
    final names = widget.list.items
        .map((i) => svc.normalizeForSpecials(i.name))
        .where((n) => n.isNotEmpty)
        .toSet();
    if (names.isEmpty) return;
    final hits = await svc.fetchActiveSpecials(names);
    if (!mounted) return;
    setState(() => _specials = hits);
  }

  void _dismissEstimateHint() {
    setState(() => _showEstimateHint = false);
    // In-memory flag only — resets on next cold start so the banner
    // reappears for first-entry visibility. Intentionally no disk write.
    _estimateHintDismissedThisSession = true;
  }

  @override
  void dispose() {
    _addController.dispose();
    _addFocus.dispose();
    super.dispose();
  }

  void _submit() {
    widget.onAdd(_addController.text);
    _addController.clear();
    _addFocus.requestFocus();
  }

  /// Sends every active (unchecked) line item to Gemini via
  /// [PriceEstimateService] and stores the result in local state so the
  /// per-tile subtitle + the sticky basket-total card both refresh on
  /// the same frame.
  Future<void> _runEstimate() async {
    if (_estimating) return;

    // Build the input list — title + qty if present so "2L" / "500g"
    // flavour the AI's price grounding.
    final items = widget.list.items.map((i) {
      final qty = i.displayQuantity.trim();
      return qty.isEmpty ? i.name : '$qty ${i.name}';
    }).toList(growable: false);

    if (items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Add some items first — nothing to price up.'),
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }

    setState(() => _estimating = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await PriceEstimateService.instance.estimate(items);
      if (!mounted) return;

      // The AI keyed entries against the formatted string we sent
      // ("2L Full Cream Milk"). The tile widget has access to the
      // ShoppingItem and rebuilds the same formatted name for lookup —
      // we copy the map straight through.
      setState(() {
        _itemEstimates  = result.byOriginalName;
        _hasEstimate    = true;
        _estimating     = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _estimating = false);
      messenger.showSnackBar(const SnackBar(
        content:  Text(
            'Could not fetch price estimates. Check your connection.'),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  /// Reformat helper used by both the input builder and the tile so the
  /// lookup key into [_itemEstimates] stays in sync.
  static String _formatItemKey(ShoppingItem i) {
    final qty = i.displayQuantity.trim();
    return qty.isEmpty ? i.name : '$qty ${i.name}';
  }

  /// "R34.50" — fixed-2 ZAR formatter, no thousands separator (the basket
  /// total never reaches a comma-worthy figure in practice).
  static String _formatZar(double v) => 'R${v.toStringAsFixed(2)}';

  // ── Share ────────────────────────────────────────────────────────────────────

  void _showShareSheet() {
    showModalBottomSheet<void>(
      context:            context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ShareListSheet(
        list:          widget.list,
        onShareToUser: widget.onShareToUser,
      ),
    );
  }

  void _confirmDelete() {
    showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this list?'),
        content: const Text('This action cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);   // close dialog
              widget.onDelete();    // delete first (while _activeList is still set)
              widget.onBack();      // then navigate back
            },
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  /// WS2: settable basket budget. Submitting an empty field clears the
  /// budget (back to "no target"). The numeric parser accepts both "120"
  /// and "120.50"; we trim a leading "R" so paste-from-clipboard works.
  Future<void> _promptBudget() async {
    final current = widget.list.budgetZar;
    final ctrl = TextEditingController(
      text: current == null ? '' : current.toStringAsFixed(2),
    );
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        scrollable:   true,
        title: const Text('Basket budget'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('What can you spend on this list?'),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus:  true,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                prefixText: 'R ',
                hintText:   'e.g. 500.00',
                border:     OutlineInputBorder(),
              ),
              onSubmitted: (v) => Navigator.pop(ctx, v),
            ),
          ],
        ),
        actions: [
          if (current != null)
            TextButton(
              onPressed: () => Navigator.pop(ctx, ''),
              child: const Text('Clear'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result == null) return;
    final cleaned = result.replaceAll('R', '').trim().replaceAll(',', '.');
    if (cleaned.isEmpty) {
      widget.onSetBudget(null);
      return;
    }
    final value = double.tryParse(cleaned);
    if (value != null && value > 0) {
      widget.onSetBudget(value);
    }
  }

  void _promptRename() async {
    final ctrl = TextEditingController(text: widget.list.name);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        // AlertDialog already lifts itself above viewInsets via its own
        // internal Padding wrapper. Adding viewInsets.bottom here stacked
        // a SECOND keyboard-height push, shoving the modal off the top of
        // the screen on smaller devices (44311 / 44330). Use a fixed
        // insetPadding and let the framework anchor it in the safe area.
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        scrollable:   true,
        title: const Text('Rename list'),
        content: TextField(
          controller: ctrl,
          autofocus:  true,
          decoration: const InputDecoration(hintText: 'List name'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    if (result != null && result.trim().isNotEmpty) {
      widget.onRename(result.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    final tt      = Theme.of(context).textTheme;
    final cs      = Theme.of(context).colorScheme;
    final items   = widget.list.items;
    final checked = items.where((i) => i.checked).length;

    // Group unchecked items by category.
    final unchecked = items.where((i) => !i.checked).toList();
    final grouped   = <GroceryCategory, List<ShoppingItem>>{};
    for (final item in unchecked) {
      grouped.putIfAbsent(item.category, () => []).add(item);
    }
    // Sort categories in aisle order.
    final sortedCats = GroceryCategory.values.where((c) => grouped.containsKey(c)).toList();

    return Scaffold(
      backgroundColor: cs.surface,
      body: SafeArea(
        child: Column(
          children: [
            // ── Header ─────────────────────────────────────────────────────
            Container(
              decoration: const BoxDecoration(
                color: _kForest,
                borderRadius: BorderRadius.vertical(bottom: Radius.circular(28)),
              ),
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Back + actions row.
                  // Share / Rename / Delete moved into a 3-dot overflow
                  // menu so the row fits inside the device width once the
                  // WS2 budget icon + Estimate basket pill share the bar.
                  // Compact IconButton constraints (no default 48dp hit
                  // box) keep the remaining icons + pill on one row.
                  Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 20),
                        onPressed: widget.onBack,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                      const Spacer(),
                      // ── Budget target (WS2) ───────────────────────────
                      // Tap to set / edit / clear the basket budget.
                      IconButton(
                        icon: Icon(
                          widget.list.budgetZar == null
                              ? Icons.savings_outlined
                              : Icons.savings_rounded,
                          color: Colors.white,
                          size:  20,
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        constraints: const BoxConstraints(),
                        onPressed: _promptBudget,
                        tooltip:   widget.list.budgetZar == null
                            ? 'Set budget'
                            : 'Budget: ${_formatZar(widget.list.budgetZar!)}',
                      ),
                      if (checked > 0)
                        IconButton(
                          icon: const Icon(Icons.cleaning_services_outlined, color: Colors.white, size: 20),
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          constraints: const BoxConstraints(),
                          onPressed: widget.onClearDone,
                          tooltip: 'Clear checked',
                        ),
                      // 3-dot overflow — Share / Rename / Delete
                      PopupMenuButton<String>(
                        icon: const Icon(Icons.more_vert_rounded,
                            color: Colors.white, size: 20),
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        tooltip: 'List actions',
                        onSelected: (value) {
                          switch (value) {
                            case 'share':  _showShareSheet();  break;
                            case 'rename': _promptRename();    break;
                            case 'delete': _confirmDelete();   break;
                          }
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                            value: 'share',
                            child: ListTile(
                              dense: true,
                              leading: Icon(Icons.ios_share_rounded),
                              title: Text('Share list'),
                            ),
                          ),
                          PopupMenuItem(
                            value: 'rename',
                            child: ListTile(
                              dense: true,
                              leading: Icon(Icons.edit_outlined),
                              title: Text('Rename'),
                            ),
                          ),
                          PopupMenuItem(
                            value: 'delete',
                            child: ListTile(
                              dense: true,
                              leading: Icon(Icons.delete_outline_rounded,
                                  color: Colors.red),
                              title: Text('Delete list',
                                  style: TextStyle(color: Colors.red)),
                            ),
                          ),
                        ],
                      ),
                      // ── R Estimate — AI-powered price baseline ─────────
                      const SizedBox(width: 4),
                      Tooltip(
                        message: 'Estimate basket total (AI)',
                        child: InkWell(
                          onTap: _estimating ? null : _runEstimate,
                          borderRadius: BorderRadius.circular(20),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: _estimating
                                  ? Colors.white.withValues(alpha: 0.18)
                                  : _kOrange,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (_estimating)
                                  const SizedBox(
                                    width: 14, height: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                else
                                  const Text(
                                    'R',
                                    style: TextStyle(
                                      color:      Colors.white,
                                      fontWeight: FontWeight.w900,
                                      fontSize:   13,
                                    ),
                                  ),
                                const SizedBox(width: 6),
                                const Text(
                                  'Estimate basket',
                                  style: TextStyle(
                                    color:      Colors.white,
                                    fontSize:   12,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    widget.list.name,
                    style: tt.titleLarge?.copyWith(
                      color: Colors.white, fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$checked of ${items.length} items checked',
                    style: const TextStyle(color: Color(0xFF6FCF97), fontSize: 13),
                  ),
                  // ── Inline progress bar while AI estimate is running ─
                  if (_estimating) ...[
                    const SizedBox(height: 12),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: const LinearProgressIndicator(
                        minHeight:       4,
                        backgroundColor: Color(0x33FFFFFF),
                        color:           _kOrange,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Aunty Chow is checking SA shelf prices…',
                      style: TextStyle(
                        color:    Color(0xFFFFD7A8),
                        fontSize: 11.5,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ],
                ],
              ),
            ),

            // ── Estimate-accuracy hint banner ───────────────────────────────
            // Sits between the dark header and the Add-item field. Dismissed
            // state persists via SharedPreferences so it doesn't pester
            // returning users. AnimatedSize lets the field below glide up
            // smoothly when the user taps the close icon.
            AnimatedSize(
              duration: const Duration(milliseconds: 260),
              curve:    Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: _showEstimateHint
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                        decoration: BoxDecoration(
                          color:        const Color(0xFFFFF6E2),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: _kOrange.withAlpha(60),
                          ),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('💡', style: TextStyle(fontSize: 16)),
                            const SizedBox(width: 10),
                            const Expanded(
                              child: Text.rich(
                                TextSpan(
                                  children: [
                                    TextSpan(
                                      text: 'Tips for better Estimates: ',
                                      style: TextStyle(
                                        color:      _kForest,
                                        fontWeight: FontWeight.w900,
                                        fontSize:   12.5,
                                      ),
                                    ),
                                    TextSpan(
                                      text: 'Be specific! Type ',
                                      style: TextStyle(
                                        color:      _kForest,
                                        fontWeight: FontWeight.w600,
                                        fontSize:   12.5,
                                      ),
                                    ),
                                    TextSpan(
                                      text: "'1kg potatoes'",
                                      style: TextStyle(
                                        color:      _kForest,
                                        fontWeight: FontWeight.w900,
                                        fontSize:   12.5,
                                      ),
                                    ),
                                    TextSpan(
                                      text: " instead of just 'potatoes', or ",
                                      style: TextStyle(
                                        color:      _kForest,
                                        fontWeight: FontWeight.w600,
                                        fontSize:   12.5,
                                      ),
                                    ),
                                    TextSpan(
                                      text: "'White bread'",
                                      style: TextStyle(
                                        color:      _kForest,
                                        fontWeight: FontWeight.w900,
                                        fontSize:   12.5,
                                      ),
                                    ),
                                    TextSpan(
                                      text: " instead of just 'bread'.",
                                      style: TextStyle(
                                        color:      _kForest,
                                        fontWeight: FontWeight.w600,
                                        fontSize:   12.5,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            InkResponse(
                              onTap:   _dismissEstimateHint,
                              radius:  18,
                              child: const Padding(
                                padding: EdgeInsets.all(4),
                                child: Icon(
                                  Icons.close_rounded,
                                  size:  16,
                                  color: _kForest,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),

            // ── Add item row ────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller:   _addController,
                      focusNode:    _addFocus,
                      textInputAction: TextInputAction.done,
                      onSubmitted:  (_) => _submit(),
                      textCapitalization: TextCapitalization.sentences,
                      style: TextStyle(color: cs.onSurface),
                      decoration: InputDecoration(
                        hintText:     'Add an item…',
                        hintStyle:    TextStyle(color: cs.onSurfaceVariant),
                        filled:       true,
                        fillColor:    cs.surfaceContainerHighest,
                        contentPadding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _submit,
                    style: FilledButton.styleFrom(
                      backgroundColor: _kOrange,
                      padding:         const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      shape:           RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      minimumSize:     Size.zero,
                      tapTargetSize:   MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Icon(Icons.add_rounded, size: 22, color: Colors.white),
                  ),
                ],
              ),
            ),

            // ── Grouped items ────────────────────────────────────────────────
            Expanded(
              child: Stack(
                children: [
                  ListView(
                padding: EdgeInsets.fromLTRB(
                    16, 16, 16, _hasEstimate ? 96 : 24),
                children: [
                  for (final cat in sortedCats) ...[
                    _CategoryHeader(category: cat),
                    const SizedBox(height: 6),
                    Container(
                      decoration: BoxDecoration(
                        color:        Colors.white,
                        borderRadius: BorderRadius.circular(18),
                        boxShadow: const [
                          BoxShadow(color: Color(0x08000000), blurRadius: 6, offset: Offset(0, 2)),
                        ],
                      ),
                      child: Column(
                        children: [
                          for (int i = 0; i < grouped[cat]!.length; i++) ...[
                            _ShoppingItemTile(
                              item:     grouped[cat]![i],
                              onToggle: () => widget.onToggle(grouped[cat]![i]),
                              onDelete: () => widget.onDeleteItem(grouped[cat]![i]),
                              estimateZar:
                                  _itemEstimates?[_formatItemKey(grouped[cat]![i])],
                              special: _specials[
                                  PriceEstimateService.instance
                                      .normalizeForSpecials(grouped[cat]![i].name)],
                            ),
                            if (i < grouped[cat]!.length - 1)
                              const Divider(height: 1, indent: 52, endIndent: 16),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],

                  // Checked / done items at the bottom
                  if (checked > 0) ...[
                    _CategoryHeader(
                      label:   'Done ($checked)',
                      icon:    Icons.check_circle_outline_rounded,
                      fgColor: const Color(0xFFADADA7),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      decoration: BoxDecoration(
                        color:        Colors.white,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Column(
                        children: [
                          for (int i = 0; i < items.where((x) => x.checked).length; i++) ...[
                            _ShoppingItemTile(
                              item:     items.where((x) => x.checked).toList()[i],
                              onToggle: () => widget.onToggle(items.where((x) => x.checked).toList()[i]),
                              onDelete: () => widget.onDeleteItem(items.where((x) => x.checked).toList()[i]),
                              estimateZar: _itemEstimates?[_formatItemKey(
                                  items.where((x) => x.checked).toList()[i])],
                              // Checked rows hide the on-special badge inside the
                              // tile, but still pass it through for completeness.
                              special: _specials[
                                  PriceEstimateService.instance
                                      .normalizeForSpecials(
                                          items.where((x) => x.checked).toList()[i].name)],
                            ),
                            if (i < items.where((x) => x.checked).length - 1)
                              const Divider(height: 1, indent: 52, endIndent: 16),
                          ],
                        ],
                      ),
                    ),
                  ],
                ],
              ),
              // ── Sticky basket-total summary card ─────────────────────
              // Pinned to the bottom of the Expanded body so the grand
              // total stays visible while the user scrolls long lists.
              if (_hasEstimate)
                Positioned(
                  left:   16,
                  right:  16,
                  bottom: 12,
                  child: _BasketTotalCard(
                    // Live total — recomputed every build, so flipping
                    // an item's checked state instantly drops it from
                    // the basket sum (the "Done" pile no longer counts).
                    total:     _formatZar(_currentGrandTotalZar),
                    totalZar:  _currentGrandTotalZar,
                    // WS2: optional budget rendered as `Rxx left` /
                    // `Rxx over` next to the total. Null = no badge.
                    budgetZar: widget.list.budgetZar,
                    formatZar: _formatZar,
                    onClear:   () => setState(() {
                      _itemEstimates = null;
                      _hasEstimate   = false;
                    }),
                  ),
                ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Sticky bottom card that surfaces the AI-estimated basket total. The
/// close (✕) button discards the estimate so the user can run another
/// pass after editing the list.
class _BasketTotalCard extends StatelessWidget {
  const _BasketTotalCard({
    required this.total,
    required this.totalZar,
    required this.onClear,
    this.budgetZar,
    this.formatZar,
  });
  final String                 total;
  final double                 totalZar;
  final VoidCallback           onClear;
  /// Optional user-set basket budget. When non-null the card renders a
  /// `Rxx left` (green) or `Rxx over` (red) chip beside the total.
  final double?                budgetZar;
  /// Caller-supplied ZAR formatter so the chip matches the rest of the
  /// screen's "R12.34" convention without a duplicate static helper.
  final String Function(double)? formatZar;

  @override
  Widget build(BuildContext context) {
    final budget = budgetZar;
    final delta  = budget == null ? null : budget - totalZar;
    final overBudget = delta != null && delta < 0;
    final fmt = formatZar ?? (v) => 'R${v.toStringAsFixed(2)}';

    return Material(
      elevation:    8,
      borderRadius: BorderRadius.circular(20),
      color:        _kForest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 12, 14),
        child: Row(
          children: [
            Container(
              width: 38, height: 38,
              decoration: BoxDecoration(
                color: _kOrange,
                borderRadius: BorderRadius.circular(12),
              ),
              alignment: Alignment.center,
              child: const Text(
                'R',
                style: TextStyle(
                  color:      Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize:   18,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    budget == null
                        ? 'ESTIMATED BASKET TOTAL'
                        : 'BASKET · BUDGET ${fmt(budget)}',
                    style: const TextStyle(
                      color:         Color(0xFF9EC4AC),
                      fontSize:      10.5,
                      fontWeight:    FontWeight.w900,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Flexible(
                        child: Text(
                          total,
                          style: const TextStyle(
                            color:      Colors.white,
                            fontWeight: FontWeight.w900,
                            fontSize:   22,
                            letterSpacing: -0.3,
                          ),
                        ),
                      ),
                      if (delta != null) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: overBudget
                                ? const Color(0xFFE15A4C)
                                : const Color(0xFF6FCF97),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            overBudget
                                ? '${fmt(-delta)} over'
                                : '${fmt(delta)} left',
                            style: const TextStyle(
                              color:      Colors.white,
                              fontWeight: FontWeight.w900,
                              fontSize:   12,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close_rounded, color: Colors.white),
              tooltip: 'Clear estimate',
              onPressed: onClear,
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// _CategoryHeader
// =============================================================================

class _CategoryHeader extends StatelessWidget {
  const _CategoryHeader({
    this.category,
    this.label,
    this.icon,
    this.fgColor,
  });

  final GroceryCategory? category;
  final String?          label;
  final IconData?        icon;
  final Color?           fgColor;

  @override
  Widget build(BuildContext context) {
    final displayLabel = label    ?? '${category!.emoji}  ${category!.displayName}';
    final color        = fgColor  ?? _kForest;

    return Row(
      children: [
        if (icon != null) ...[
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 6),
        ],
        Text(
          displayLabel,
          style: TextStyle(
            fontSize:      12,
            fontWeight:    FontWeight.w700,
            color:         color,
            letterSpacing: 0.5,
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// _ShoppingItemTile
// =============================================================================

/// Path C — explains why the estimate sometimes looks high for a small
/// recipe portion. Returns null when no clarification is needed (the
/// estimate roughly matches the purchased pack-size already).
///
/// Two cases produce a hint:
///   1. Long-life pantry staples (oils, spices, vinegars, baking aids,
///      sauces) — the user buys a whole bottle/jar that lasts many meals.
///   2. Small-volume liquids — "30 ml" of oil etc. priced at full bottle.
String? _priceContextHint(ShoppingItem item) {
  final name = item.name.toLowerCase();
  const stapleHints = <String, String>{
    'oil':          'Pantry staple · lasts many meals',
    'olive oil':    'Pantry staple · lasts many meals',
    'sunflower oil':'Pantry staple · lasts many meals',
    'coconut oil':  'Pantry staple · lasts many meals',
    'vinegar':      'Pantry staple · lasts many meals',
    'soy sauce':    'Pantry staple · lasts many meals',
    'sugar':        'Pantry staple · lasts many meals',
    'flour':        'Pantry staple · lasts many meals',
    'salt':         'Pantry staple · lasts many meals',
    'baking powder':'Pantry staple · lasts many meals',
    'baking soda':  'Pantry staple · lasts many meals',
    'maizena':      'Pantry staple · lasts many meals',
    'cornflour':    'Pantry staple · lasts many meals',
    'vanilla':      'Pantry staple · lasts many meals',
    'cocoa':        'Pantry staple · lasts many meals',
    'curry powder': 'Pantry staple · lasts many meals',
    'masala':       'Pantry staple · lasts many meals',
    'paprika':      'Pantry staple · lasts many meals',
    'cumin':        'Pantry staple · lasts many meals',
    'turmeric':     'Pantry staple · lasts many meals',
    'cinnamon':     'Pantry staple · lasts many meals',
    'ginger powder':'Pantry staple · lasts many meals',
    'garlic powder':'Pantry staple · lasts many meals',
    'aromat':       'Pantry staple · lasts many meals',
    'braai spice':  'Pantry staple · lasts many meals',
    'chicken spice':'Pantry staple · lasts many meals',
    'stock':        'Pantry staple · lasts many meals',
    'knorrox':      'Pantry staple · lasts many meals',
    'royco':        'Pantry staple · lasts many meals',
    'jam':          'Pantry staple · lasts many meals',
    'honey':        'Pantry staple · lasts many meals',
    'marmite':      'Pantry staple · lasts many meals',
    'bovril':       'Pantry staple · lasts many meals',
    'peanut butter':'Pantry staple · lasts many meals',
    'tomato sauce': 'Pantry staple · lasts many meals',
    'chutney':      'Pantry staple · lasts many meals',
    'syrup':        'Pantry staple · lasts many meals',
    'mayo':         'Pantry staple · lasts many meals',
    'mayonnaise':   'Pantry staple · lasts many meals',
    'mustard':      'Pantry staple · lasts many meals',
  };

  for (final entry in stapleHints.entries) {
    if (name.contains(entry.key)) return entry.value;
  }

  // Small-volume liquid catch-all: 30 ml oil etc. priced at bottle rate.
  final qty  = item.quantity?.trim() ?? '';
  final unit = item.unit?.toLowerCase().trim() ?? '';
  final numeric = double.tryParse(qty.replaceAll(',', '.'));
  if (numeric != null && numeric > 0) {
    if (unit == 'ml' && numeric <= 250) {
      return 'Sold by the bottle · price is for the full pack';
    }
    if (unit == 'g' && numeric <= 100) {
      return 'Sold by the pack · price is for the full unit';
    }
    if (unit == 'tsp' || unit == 'tbsp') {
      return 'Sold in jars/bottles · price is for the full unit';
    }
  }
  return null;
}

class _ShoppingItemTile extends StatelessWidget {
  const _ShoppingItemTile({
    required this.item,
    required this.onToggle,
    required this.onDelete,
    this.estimateZar,
    this.special,
  });

  final ShoppingItem item;
  final VoidCallback onToggle;
  final VoidCallback onDelete;
  /// Per-row ZAR price baseline returned by the AI estimate run. Null
  /// when the user hasn't tapped "R Estimate" yet, OR when the AI
  /// couldn't price this specific line item.
  final double?      estimateZar;
  /// WS6: active retailer special for this item, or null when nothing
  /// matched the normalised name in the `specials` overlay table.
  final SpecialMatch? special;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;

    return Dismissible(
      key:        ValueKey(item.id),
      direction:  DismissDirection.endToStart,
      onDismissed: (_) => onDelete(),
      background: Container(
        alignment: Alignment.centerRight,
        padding:   const EdgeInsets.only(right: 20),
        decoration: const BoxDecoration(
          color:        Color(0xFFFFE5E5),
          borderRadius: BorderRadius.all(Radius.circular(18)),
        ),
        child: const Icon(Icons.delete_outline_rounded, color: Colors.red),
      ),
      child: InkWell(
        onTap:       onToggle,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          child: Row(
            children: [
              // Check indicator
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width:  24,
                height: 24,
                decoration: BoxDecoration(
                  shape:  BoxShape.circle,
                  color:  item.checked ? _kForest : Colors.transparent,
                  border: Border.all(
                    color: item.checked ? _kForest : const Color(0xFFBDB9B2),
                    width: 1.5,
                  ),
                ),
                child: item.checked
                    ? const Icon(Icons.check_rounded, size: 14, color: Colors.white)
                    : null,
              ),
              const SizedBox(width: 12),

              // Name + quantity
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.name,
                      style: tt.bodyMedium?.copyWith(
                        fontWeight:     FontWeight.w600,
                        // Explicit near-black for unchecked items so they are
                        // always readable on the cream/white card background.
                        color:          item.checked
                            ? const Color(0xFFADADA7)
                            : const Color(0xFF111111),
                        decoration:     item.checked ? TextDecoration.lineThrough : null,
                        decorationColor: const Color(0xFFADADA7),
                      ),
                    ),
                    if (item.displayQuantity.isNotEmpty)
                      Text(
                        item.displayQuantity,
                        style: tt.bodySmall?.copyWith(
                          color: item.checked
                              ? const Color(0xFFBDB9B2)
                              : const Color(0xFF55534E),
                        ),
                      ),
                    // ── AI price estimate (per-row) ──────────────────
                    // WS3: rendered as a ~range instead of a single
                    // figure so the number reads as an estimate, not a
                    // promise. We bracket the central estimate by ±8%
                    // and round to the nearest rand — tight enough that
                    // the basket-total math is still recognisable, loose
                    // enough that users don't feel cheated by ±R2.
                    if (estimateZar != null && estimateZar! > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          '~R${(estimateZar! * 0.92).round()}'
                          '–R${(estimateZar! * 1.08).round()}',
                          style: tt.bodySmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            color:     _kOrange,
                            fontSize:  11.5,
                          ),
                        ),
                      ),
                    // ── Price-context hint (Path C) ──────────────────
                    // Explains why a 30ml line item shows R55: the till
                    // charges for the full bottle / pack, not the pro-
                    // rated recipe portion. Lifts the user's confusion
                    // without overstating the basket cost. Pantry staples
                    // get a separate hint flagging "you probably already
                    // have this — keep an eye on the basket total".
                    if (estimateZar != null && estimateZar! > 0)
                      Builder(
                        builder: (_) {
                          final hint = _priceContextHint(item);
                          if (hint == null) return const SizedBox.shrink();
                          return Padding(
                            padding: const EdgeInsets.only(top: 1),
                            child: Text(
                              hint,
                              style: tt.bodySmall?.copyWith(
                                color:    _kMuted,
                                fontSize: 10.5,
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          );
                        },
                      ),
                    // ── WS6: on-special badge ────────────────────────
                    // Renders only when the weekly specials cron has a
                    // live match for this item's normalised name. Tiny
                    // emoji + store + price — never blocks the row.
                    if (special != null && !item.checked)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color:        const Color(0xFFFFE9D4),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: _kOrange.withAlpha(70)),
                          ),
                          child: Text(
                            '🔥 on special at ${special!.store} · '
                            'R${special!.priceZar.toStringAsFixed(2)}',
                            style: const TextStyle(
                              color:      _kForest,
                              fontWeight: FontWeight.w800,
                              fontSize:   11,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),

              // Category chip
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color:        item.checked
                      ? const Color(0xFFF0EDEA)
                      : _kForest.withAlpha(20),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  item.category.displayName,
                  style: TextStyle(
                    fontSize:   10,
                    fontWeight: FontWeight.w600,
                    color:      item.checked ? const Color(0xFFADADA7) : _kForest,
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
// _ShareListSheet — PDF export + share with ChowSA user
// =============================================================================

class _ShareListSheet extends StatefulWidget {
  const _ShareListSheet({
    required this.list,
    required this.onShareToUser,
  });

  final ShoppingList                            list;
  final Future<void> Function(String handle)?   onShareToUser;

  @override
  State<_ShareListSheet> createState() => _ShareListSheetState();
}

class _ShareListSheetState extends State<_ShareListSheet> {
  final _handleCtrl  = TextEditingController();
  bool  _showHandle  = false;
  bool  _sharing     = false;
  /// True for ~1.6s after a successful send — flips the FilledButton label
  /// into a green check icon as immediate positive feedback before the sheet
  /// auto-dismisses. Spec: "turning the button into a checkmark".
  bool  _sendSuccess = false;

  // Cached accepted-friend list — populated the first time the share-handle
  // input expands. Drives the Autocomplete<FriendProfile> dropdown.
  List<FriendProfile> _friendOptions = const [];

  /// Handle just tapped from the dropdown. While the field text still equals
  /// it, optionsBuilder returns nothing so the dropdown closes instead of
  /// re-showing the picked row (the "popup stays open" bug). Captured focus
  /// node lets onSelected drop focus to dismiss the overlay.
  String?    _justPickedHandle;
  FocusNode? _shareFocus;

  // Friend picked from the autocomplete dropdown. Holds their `id` so the
  // shareToKitchenCircle call can target them directly without a handle→id
  // lookup. Cleared when the user edits the text field after selection so
  // we never send to a stale id.
  FriendProfile? _selectedFriend;

  Future<void> _ensureFriendsLoaded() async {
    if (_friendOptions.isNotEmpty) return;
    final friendships = await FriendsService.instance.loadAcceptedFriends();
    if (!mounted) return;
    setState(() => _friendOptions =
        friendships.map((f) => f.other).toList());
  }

  @override
  void dispose() {
    _handleCtrl.dispose();
    super.dispose();
  }

  // ── Export as real PDF (pdf package) ──────────────────────────────────────
  Future<void> _exportAndShare() async {
    setState(() => _sharing = true);

    try {
      // Build PDF document
      final doc = pw.Document();

      // Group items by category
      final grouped = <GroceryCategory, List<ShoppingItem>>{};
      for (final item in widget.list.items) {
        grouped.putIfAbsent(item.category, () => []).add(item);
      }

      final forestGreen = PdfColor.fromHex('#1E4D2B');
      final cream       = PdfColor.fromHex('#F9F6F0');
      final muted       = PdfColor.fromHex('#6B6860');

      doc.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin:     const pw.EdgeInsets.all(36),
          header: (ctx) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Container(
                padding: const pw.EdgeInsets.all(16),
                decoration: pw.BoxDecoration(
                  color:        forestGreen,
                  borderRadius: const pw.BorderRadius.all(pw.Radius.circular(10)),
                ),
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text(
                          widget.list.name,
                          style: pw.TextStyle(
                            color:      PdfColors.white,
                            fontSize:   20,
                            fontWeight: pw.FontWeight.bold,
                          ),
                        ),
                        pw.SizedBox(height: 4),
                        pw.Text(
                          'ChowSA Shopping List',
                          style: pw.TextStyle(
                            color:    PdfColors.white,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                    pw.Text(
                      '${widget.list.items.length} items',
                      style: pw.TextStyle(
                        color:    PdfColors.white,
                        fontSize: 13,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              pw.SizedBox(height: 16),
            ],
          ),
          footer: (ctx) => pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                'Generated by ChowSA  •  chowsa.app',
                style: pw.TextStyle(fontSize: 9, color: muted),
              ),
              pw.Text(
                'Page ${ctx.pageNumber} of ${ctx.pagesCount}',
                style: pw.TextStyle(fontSize: 9, color: muted),
              ),
            ],
          ),
          build: (ctx) {
            final widgets = <pw.Widget>[];

            for (final cat in GroceryCategory.values) {
              final items = grouped[cat];
              if (items == null || items.isEmpty) continue;

              // Category header
              widgets.add(
                pw.Container(
                  margin:  const pw.EdgeInsets.only(bottom: 8, top: 12),
                  padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: pw.BoxDecoration(
                    color:        cream,
                    borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
                  ),
                  child: pw.Text(
                    // No emoji in PDF — use text-only category name
                    cat.displayName.toUpperCase(),
                    style: pw.TextStyle(
                      fontSize:   10,
                      fontWeight: pw.FontWeight.bold,
                      color:      forestGreen,
                    ),
                  ),
                ),
              );

              // Items
              for (final item in items) {
                widgets.add(
                  pw.Container(
                    margin:  const pw.EdgeInsets.only(bottom: 4),
                    padding: const pw.EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    decoration: pw.BoxDecoration(
                      color:        item.checked
                          ? PdfColor.fromHex('#F5F5F5')
                          : PdfColors.white,
                      border:       pw.Border.all(
                        color: PdfColor.fromHex('#E5E5E3'),
                        width: 0.5,
                      ),
                      borderRadius:
                          const pw.BorderRadius.all(pw.Radius.circular(6)),
                    ),
                    child: pw.Row(
                      children: [
                        pw.Container(
                          width:  14,
                          height: 14,
                          decoration: pw.BoxDecoration(
                            shape: pw.BoxShape.rectangle,
                            border: pw.Border.all(
                              color: item.checked
                                  ? forestGreen
                                  : PdfColor.fromHex('#BDBDBD'),
                            ),
                            color: item.checked ? forestGreen : PdfColors.white,
                            borderRadius:
                                const pw.BorderRadius.all(pw.Radius.circular(3)),
                          ),
                          child: item.checked
                              ? pw.Center(
                                  child: pw.Text(
                                    '✓',
                                    style: pw.TextStyle(
                                      color:    PdfColors.white,
                                      fontSize: 9,
                                      fontWeight: pw.FontWeight.bold,
                                    ),
                                  ),
                                )
                              : pw.SizedBox(),
                        ),
                        pw.SizedBox(width: 10),
                        pw.Expanded(
                          child: pw.Text(
                            item.name,
                            style: pw.TextStyle(
                              fontSize: 12,
                              color: item.checked
                                  ? PdfColor.fromHex('#AAAAAA')
                                  : PdfColors.black,
                              fontWeight: pw.FontWeight.bold,
                            ),
                          ),
                        ),
                        if (item.displayQuantity.isNotEmpty)
                          pw.Text(
                            item.displayQuantity,
                            style: pw.TextStyle(
                              fontSize: 11,
                              color:    muted,
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              }
            }

            return widgets;
          },
        ),
      );

      // Save to temp file and share
      final dir      = await getTemporaryDirectory();
      final safeList = widget.list.name.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
      final file     = File('${dir.path}/ChowSA_$safeList.pdf');
      await file.writeAsBytes(await doc.save());

      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'application/pdf')],
        subject: '${widget.list.name} — ChowSA Shopping List',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not export PDF: $e'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  // ── _sendToUser — spec-exact share pipeline ─────────────────────────────────
  //
  // The previous implementation chained through SocialService and
  // SharedAssetsService, which made the failure modes opaque ("tapping Send
  // does nothing"). This rewrite keeps every step of the pipeline visible
  // inside this one method so any silent failure shows up in the catch block:
  //
  //   1. Sanitise the typed username (replaceFirst('@', '').trim())
  //   2. Show a snackbar if the field is empty — NEVER silently bail
  //   3. Look up the target profile id via .ilike('username', cleanUsername)
  //      so capitalisation differences don't break the lookup
  //   4. Insert a (list_id, sender_id, receiver_id) row into the dedicated
  //      shopping_list_shares relation table (see migration
  //      supabase/migrations/20260531_shopping_list_shares.sql)
  //   5. Flip the Send button into a green checkmark for 1.6 s, then close
  //      the sheet with a confirmation snackbar.

  Future<void> _sendToUser() async {
    // Capture messenger BEFORE any awaits so snackbars survive the sheet pop.
    final messenger = ScaffoldMessenger.of(context);

    // ── 1. Sanitise the username ──────────────────────────────────────────
    final String cleanUsername =
        _handleCtrl.text.replaceFirst('@', '').trim();

    // ── 2. Empty-field feedback — fixes "Send does nothing" silent return ─
    if (cleanUsername.isEmpty) {
      messenger.showSnackBar(
        SnackBar(
          content: const Text(
            'Type a ChowSA username before tapping Send.',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          backgroundColor: Colors.red.shade700,
          behavior:        SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12)),
        ),
      );
      return;
    }

    setState(() => _sharing = true);

    try {
      // Single transactional path through InboxShareService — resolves
      // recipient via the find_user_by_handle RPC, inserts (or upserts
      // on the dedupe index hit) into inbox_messages, and re-reads via
      // .select().single() so a snackbar only fires when the server
      // confirms a row. No more "success in UI, nothing in recipient's
      // inbox" because nothing further runs in this try-block before the
      // server has acknowledged the row.
      final result = await InboxShareService.instance.shareShoppingList(
        list:            widget.list,
        recipientHandle: cleanUsername,
      );
      final receiverHandle = result.receiverHandle;

      // Legacy callback fan-out (dev hub mirrors etc.). Fire-and-forget.
      // ignore: discarded_futures
      widget.onShareToUser?.call(receiverHandle);

      // ── 5. Visual confirmation + dismiss ────────────────────────────────
      if (!mounted) return;
      setState(() {
        _sharing     = false;
        _sendSuccess = true;
      });

      // Hold the checkmark visible for a beat, then clear inputs, close
      // the sheet, and surface the spec-exact confirmation snackbar.
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      if (!mounted) return;
      _handleCtrl.clear();
      _selectedFriend = null;
      _showHandle     = false;
      Navigator.pop(context);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Shopping list shared successfully with @$receiverHandle!',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          backgroundColor: _kForest,
          behavior:        SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12)),
        ),
      );
    } catch (e, st) {
      // Single catch — InboxShareService throws typed InboxShareException
      // subclasses for the common shapes (unknown recipient, denied,
      // timeout). Anything else maps to a generic message. Full error +
      // stack always go to logcat for triage.
      debugPrint('[shareList] _sendToUser failed: $e\n$st');
      if (!mounted) return;
      setState(() => _sharing = false);
      String reason;
      if (e is InboxShareUnknownRecipient) {
        reason = 'Could not find @$cleanUsername on ChowSA.';
      } else if (e is InboxShareDeniedException) {
        reason = "You don't have permission to share this list.";
      } else if (e is InboxShareTimeoutException) {
        reason = 'Network timed out — please try again.';
      } else if (e is InboxShareException) {
        reason = 'Could not send list — please try again in a moment.';
      } else {
        reason = 'Could not send list — please try again in a moment.';
      }
      messenger.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 5),
          content: Text(
            reason,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          backgroundColor: Colors.red.shade700,
          behavior:        SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12)),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final tt     = Theme.of(context).textTheme;
    // Keyboard-aware shell:
    //   • Container.padding.bottom = viewInsets.bottom → the entire sheet
    //     lifts by the exact keyboard height, no hardcoded offsets.
    //   • Column wrapped in SingleChildScrollView so any leftover content
    //     scrolls smoothly on small devices instead of throwing the
    //     yellow/black "Bottom overflowed by N px" stripe.
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
    final safeBottom = MediaQuery.of(context).padding.bottom;

    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve:    Curves.easeOut,
      padding:  EdgeInsets.only(bottom: viewInsets),
      child: Container(
      padding: EdgeInsets.fromLTRB(24, 24, 24, safeBottom + 24),
      decoration: const BoxDecoration(
        color:        _kCream,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Handle bar
          Center(
            child: Container(
              width: 40, height: 4,
              margin:     const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color:        const Color(0xFFE6E2D8),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),

          // Title
          Row(
            children: [
              Container(
                width: 40, height: 40,
                decoration: BoxDecoration(
                  color:        _kForest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.ios_share_rounded,
                    color: Colors.white, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Share List',
                      style: tt.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                        color:      _kForest,
                      ),
                    ),
                    Text(
                      widget.list.name,
                      style: tt.bodySmall?.copyWith(color: _kMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 24),

          // ── Option 1: Export as PDF ────────────────────────────────────────
          _ShareOption(
            icon:     Icons.picture_as_pdf_rounded,
            iconBg:   _kOrange,
            title:    'Export as PDF',
            subtitle: 'Opens system share sheet — send via WhatsApp, '
                'Email, or any app',
            badge:    null,
            loading:  _sharing,
            onTap:    _exportAndShare,
          ),

          const SizedBox(height: 12),

          // ── Option 2: Share with ChowSA user ──────────────────────────────
          _ShareOption(
            icon:     Icons.person_search_rounded,
            iconBg:   _kForest,
            title:    'Share with ChowSA User',
            subtitle: 'Routes the list directly to another user\'s inbox',
            badge:    widget.onShareToUser == null ? 'Pro' : null,
            loading:  false,
            onTap:    widget.onShareToUser == null
                ? null
                : () {
                    setState(() => _showHandle = !_showHandle);
                    if (_showHandle) _ensureFriendsLoaded();
                  },
          ),

          // Expandable handle input
          AnimatedSize(
            duration: const Duration(milliseconds: 240),
            curve:    Curves.easeInOut,
            child: _showHandle
                ? Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Row(
                      children: [
                        Expanded(
                          // ── Autocomplete<FriendProfile> ────────────────────
                          // Filters the user's accepted-friend list by handle /
                          // display name. Falls back to free text when nothing
                          // matches so users can still type any handle.
                          child: Autocomplete<FriendProfile>(
                            displayStringForOption: (p) => p.handle,
                            optionsBuilder: (TextEditingValue value) {
                              final q = value.text.trim().toLowerCase();
                              // Suppress while the text equals the just-picked
                              // handle so the overlay closes after selection.
                              // Flutter sets the field to the bare handle on
                              // select, but the user may also type "@handle".
                              if (_justPickedHandle != null &&
                                  (q == _justPickedHandle!.toLowerCase() ||
                                   q == '@${_justPickedHandle!.toLowerCase()}')) {
                                return const Iterable<FriendProfile>.empty();
                              }
                              _justPickedHandle = null;
                              if (q.isEmpty) return _friendOptions;
                              return _friendOptions.where((p) {
                                return p.handle.toLowerCase().contains(q) ||
                                  (p.displayName?.toLowerCase().contains(q)
                                      ?? false);
                              });
                            },
                            onSelected: (FriendProfile p) {
                              // Capture the selected profile's UUID into
                              // _selectedFriend so the Send handler can
                              // skip the by-handle RPC and target the
                              // recipient by id. Render "@handle" in the
                              // input to confirm the focus selection.
                              setState(() {
                                _selectedFriend   = p;
                                _justPickedHandle = p.handle;
                                _handleCtrl.text  = '@${p.handle}';
                              });
                              _shareFocus?.unfocus();
                            },
                            fieldViewBuilder: (ctx, fieldCtrl, focus, onSubmit) {
                              _shareFocus = focus;
                              // Mirror the Autocomplete-managed controller into
                              // our own _handleCtrl so _sendToUser() reads the
                              // current text. Also drop the stale _selectedFriend
                              // when the user edits away from the picked handle —
                              // prevents sending to the wrong receiverId.
                              fieldCtrl.addListener(() {
                                if (_handleCtrl.text != fieldCtrl.text) {
                                  _handleCtrl.text = fieldCtrl.text;
                                }
                                if (_selectedFriend != null &&
                                    fieldCtrl.text.trim().toLowerCase() !=
                                        _selectedFriend!.handle.toLowerCase()) {
                                  _selectedFriend = null;
                                }
                              });
                              return TextField(
                                controller:       fieldCtrl,
                                focusNode:        focus,
                                autofocus:        true,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                                decoration: InputDecoration(
                                  // No '@' prefix — users type the raw
                                  // username only. _sendToUser() still strips
                                  // an accidental '@' before the DB query.
                                  hintText:  _friendOptions.isEmpty
                                      ? 'Friend username (e.g. Melrose)'
                                      : 'Pick a friend or type a username…',
                                  hintStyle: const TextStyle(
                                    color: Color(0xFFADADA7),
                                  ),
                                  filled:        true,
                                  fillColor:     Colors.white,
                                  contentPadding:
                                      const EdgeInsets.fromLTRB(12, 13, 12, 13),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(14),
                                    borderSide:   BorderSide.none,
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(14),
                                    borderSide: const BorderSide(
                                        color: _kForest, width: 1.5),
                                  ),
                                ),
                                onSubmitted: (_) => _sendToUser(),
                              );
                            },
                            optionsViewBuilder: (ctx, onSelect, options) {
                              return Align(
                                alignment: Alignment.topLeft,
                                child: Material(
                                  elevation: 6,
                                  borderRadius: BorderRadius.circular(14),
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(
                                        maxHeight: 220, maxWidth: 280),
                                    child: ListView.builder(
                                      shrinkWrap: true,
                                      padding:    EdgeInsets.zero,
                                      itemCount:  options.length,
                                      itemBuilder: (_, i) {
                                        final p = options.elementAt(i);
                                        return ListTile(
                                          dense: true,
                                          leading: CircleAvatar(
                                            backgroundColor: _kForest,
                                            radius: 16,
                                            child: Text(
                                              p.initials,
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 11,
                                                fontWeight: FontWeight.w900,
                                              ),
                                            ),
                                          ),
                                          title: Text('@${p.handle}',
                                              style: const TextStyle(
                                                  fontWeight: FontWeight.w700)),
                                          subtitle: p.displayName == null
                                              ? null
                                              : Text(p.displayName!,
                                                  style: const TextStyle(
                                                      fontSize: 11,
                                                      color: _kMuted)),
                                          onTap: () => onSelect(p),
                                        );
                                      },
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        // ── Send button — three visual states ─────────────
                        //   idle      → "Send" label
                        //   sharing   → small spinner (inflight)
                        //   success   → green check icon (~1.6s before pop)
                        FilledButton(
                          // Disable while the send is in flight or after
                          // success so a double-tap can't fire two sends.
                          onPressed: (_sharing || _sendSuccess)
                              ? null
                              : _sendToUser,
                          style: FilledButton.styleFrom(
                            backgroundColor: _sendSuccess
                                ? const Color(0xFF2E7D32)   // success green
                                : _kForest,
                            disabledBackgroundColor: _sendSuccess
                                ? const Color(0xFF2E7D32)
                                : _kForest.withAlpha(140),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 18, vertical: 14),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14)),
                            minimumSize:   Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 220),
                            transitionBuilder: (child, anim) =>
                                ScaleTransition(scale: anim, child: child),
                            child: _sendSuccess
                                ? const Icon(
                                    Icons.check_rounded,
                                    key:   ValueKey('sent'),
                                    color: Colors.white,
                                    size:  20,
                                  )
                                : _sharing
                                    ? const SizedBox(
                                        key: ValueKey('inflight'),
                                        width: 18, height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2.4,
                                          color:       Colors.white,
                                        ),
                                      )
                                    : const Text(
                                        'Send',
                                        key: ValueKey('idle'),
                                        style: TextStyle(
                                          fontWeight: FontWeight.w800,
                                          color: Colors.white,
                                        ),
                                      ),
                          ),
                        ),
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),

          const SizedBox(height: 8),
        ],
      ),
      ), // SingleChildScrollView
      ), // Container (sheet body)
    );
  }
}

// ── _ShareOption tile ──────────────────────────────────────────────────────────

class _ShareOption extends StatelessWidget {
  const _ShareOption({
    required this.icon,
    required this.iconBg,
    required this.title,
    required this.subtitle,
    required this.badge,
    required this.loading,
    required this.onTap,
  });

  final IconData   icon;
  final Color      iconBg;
  final String     title;
  final String     subtitle;
  final String?    badge;      // e.g. "Pro" lock badge — null = available
  final bool       loading;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tt      = Theme.of(context).textTheme;
    final locked  = onTap == null;

    return GestureDetector(
      onTap: locked ? null : onTap,
      child: AnimatedOpacity(
        opacity:  locked ? 0.55 : 1.0,
        duration: const Duration(milliseconds: 160),
        child: Container(
          padding:    const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color:        Colors.white,
            borderRadius: BorderRadius.circular(18),
            border:       Border.all(color: const Color(0xFFE6E2D8)),
          ),
          child: Row(
            children: [
              Container(
                width:  44,
                height: 44,
                decoration: BoxDecoration(
                  color:        iconBg,
                  borderRadius: BorderRadius.circular(13),
                ),
                child: loading
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: CircularProgressIndicator(
                            strokeWidth: 2.5, color: Colors.white),
                      )
                    : Icon(icon, color: Colors.white, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          title,
                          style: tt.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            color:      const Color(0xFF1A1A1A),
                          ),
                        ),
                        if (badge != null) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color:        _kOrange,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              badge!,
                              style: const TextStyle(
                                color:      Colors.white,
                                fontSize:   9,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: tt.bodySmall?.copyWith(color: _kMuted),
                    ),
                  ],
                ),
              ),
              Icon(
                locked
                    ? Icons.lock_outline_rounded
                    : Icons.chevron_right_rounded,
                color: const Color(0xFFCCCAC5),
                size:  20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

