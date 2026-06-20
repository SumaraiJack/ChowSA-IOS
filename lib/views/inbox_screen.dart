// lib/views/inbox_screen.dart
//
// Application inbox — shows shared shopping lists from other ChowSA users.
// Each message card opens a detail sheet where the recipient can preview all
// items and import the list directly into their personal library.
//
// InboxScreen is a StatefulWidget that owns its own copy of the message list.
// Local mutations (mark-read, delete, import) update local state immediately
// for instant UI feedback, then call the parent callbacks for persistence.

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/inbox_message.dart';
import '../models/ingredient.dart';
import '../models/recipe.dart';
import '../models/shopping_list.dart';
import '../services/notifications_feed_service.dart';
import '../services/recipe_repository.dart';
import '../state/inbox_controller.dart';
import 'meal_planner_screen.dart';
import 'recipe_detail_screen.dart';

// =============================================================================
// Design tokens
// =============================================================================

const _kForest  = Color(0xFF0C351E);
const _kOrange  = Color(0xFFE59B27);
const _kCream   = Color(0xFFF4F1EA);
const _kMuted   = Color(0xFF55534E);
const _kDivider = Color(0xFFE6E2D8);

// =============================================================================
// InboxScreen — StatefulWidget, owns local message state
// =============================================================================

class InboxScreen extends StatefulWidget {
  const InboxScreen({
    super.key,
    required this.messages,
    required this.onMarkRead,
    required this.onImport,
    required this.onDeleteMessage,
  });

  final List<InboxMessage>          messages;
  final void Function(String id)    onMarkRead;
  final void Function(InboxMessage) onImport;
  final void Function(String id)    onDeleteMessage;

  @override
  State<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends State<InboxScreen> {

  // Local copy — mutations here give instant UI feedback without waiting for
  // the parent hub to rebuild and push updated props back down.
  late List<InboxMessage> _messages;

  @override
  void initState() {
    super.initState();
    // Deep-copy so we can mutate isRead / isImported locally.
    _messages = widget.messages
        .map((m) => InboxMessage.fromJson(m.toJson()))
        .toList();

    // Lifecycle-driven mark-all-read. The Home Screen inbox icon AND the
    // Profile Screen bell both route here, so attaching the bulk read
    // flip to this screen's initState guarantees the same dual-badge
    // sync regardless of which icon was tapped (or whether the screen
    // was reached via a deep-link / future push-notification path).
    //
    // Deferred via addPostFrameCallback so the read flip happens AFTER
    // the bell's last "with badge" frame paints — the user sees the
    // badge clear, instead of it vanishing before they notice the
    // transition.
    // NOTE: auto-mark-all-read on screen open is intentionally REMOVED.
    // Opening the inbox simply lets the user SEE what arrived — read
    // state is only flipped by the explicit per-item handlers below
    // (`_markRead` on tap and `markImported` on Tap-to-Import).

    // Reactive subscription: any incoming share / mark-read / delete in
    // ANY other surface re-emits InboxController.state and we rebuild
    // here instantly — no manual refresh, no back-out-and-reopen.
    InboxController.instance.state.addListener(_onControllerTick);
  }

  void _onControllerTick() {
    if (!mounted) return;
    final live = InboxController.instance.state.value.messages;
    setState(() {
      final existingIds = _messages.map((m) => m.id).toSet();
      final liveIds     = live.map((m) => m.id).toSet();
      // Drop anything the controller no longer has (deletes from other
      // surfaces — e.g. user cleared the bell on Profile).
      _messages.removeWhere((m) => !liveIds.contains(m.id));
      // Append any rows the controller has that we don't yet (incoming
      // shares while this screen is open).
      for (final m in live) {
        if (!existingIds.contains(m.id)) {
          _messages.insert(0, InboxMessage.fromJson(m.toJson()));
        }
      }
      // Sync read/imported state from controller authority for rows we
      // already have, so flips that happened elsewhere reflect here.
      for (final m in _messages) {
        final liveMatch = live.firstWhere(
          (l) => l.id == m.id,
          orElse: () => m,
        );
        m.isRead     = m.isRead     || liveMatch.isRead;
        m.isImported = m.isImported || liveMatch.isImported;
      }
    });
  }

  @override
  void dispose() {
    InboxController.instance.state.removeListener(_onControllerTick);
    super.dispose();
  }

  @override
  void didUpdateWidget(InboxScreen old) {
    super.didUpdateWidget(old);
    // When the hub delivers new messages (e.g. a share arrives while this
    // screen is still open), merge them in without clobbering local state.
    if (widget.messages.length != old.messages.length) {
      final existingIds = _messages.map((m) => m.id).toSet();
      final newMessages = widget.messages
          .where((m) => !existingIds.contains(m.id))
          .map((m) => InboxMessage.fromJson(m.toJson()))
          .toList();
      if (newMessages.isNotEmpty) {
        setState(() => _messages.insertAll(0, newMessages));
      }
    }
  }

  // ── Local mutations ─────────────────────────────────────────────────────────

  void _markRead(String id) {
    final idx = _messages.indexWhere((m) => m.id == id);
    if (idx == -1 || _messages[idx].isRead) return;
    setState(() => _messages[idx].isRead = true);
    widget.onMarkRead(id);                    // persist via hub
    // Drop the matching `notifications` row's unread flag too — this is
    // the source the envelope bell badge reads from. Per-item flip,
    // never bulk on screen open.
    NotificationsFeedService.instance.markRead(id);
  }

  void _deleteMessage(String id) {
    setState(() => _messages.removeWhere((m) => m.id == id));
    widget.onDeleteMessage(id);               // persist via hub
  }

  void _importMessage(InboxMessage msg) {
    final idx = _messages.indexWhere((m) => m.id == msg.id);
    if (idx != -1) {
      setState(() {
        _messages[idx].isImported = true;
        _messages[idx].isRead     = true;
      });
      // Also persist the read state
      widget.onMarkRead(msg.id);
    }
    widget.onImport(msg);                     // append items + persist via hub
  }

  // ── Computed ─────────────────────────────────────────────────────────────────

  int get _unreadCount => _messages.where((m) => !m.isRead).length;

  // ── Detail sheet ─────────────────────────────────────────────────────────────

  void _openDetail(BuildContext context, InboxMessage msg) {
    _markRead(msg.id);

    // Look up the live local copy so the sheet reflects current isImported state.
    final live = _messages.firstWhere(
      (m) => m.id == msg.id,
      orElse: () => msg,
    );

    // Recipe shares route directly to the recipe detail view — opening
    // the shopping-list sheet for them is the source of the "empty 0
    // items" report. The shopping-list sheet stays as-is for list shares.
    if (live.kind == InboxMessageKind.recipe) {
      _openSharedRecipe(context, live);
      return;
    }
    if (live.kind == InboxMessageKind.mealPlan) {
      _openSharedMealPlan(context, live);
      return;
    }

    showModalBottomSheet<void>(
      context:              context,
      isScrollControlled:   true,
      backgroundColor:      Colors.transparent,
      builder: (_) => _MessageDetailSheet(
        message:  live,
        onImport: () {
          _importMessage(live);
          Navigator.pop(context);
        },
      ),
    );
  }

  Future<void> _openSharedRecipe(BuildContext context, InboxMessage msg) async {
    // Build a Recipe from the shared payload and push the standard
    // RecipeDetailScreen — that gives the recipient the same view they'd
    // see for any of their own recipes, including the Save action which
    // persists it via RecipeRepository.
    final recipe = Recipe(
      title:        msg.listName, // reused field — carries the recipe title
      ingredients:  msg.recipeIngredients
          .map((s) => Ingredient(name: s))
          .toList(growable: false),
      instructions: List<String>.from(msg.recipeInstructions),
      isLoadsheddingFriendly: false,
    );
    // Best-effort persist into My Recipes immediately so the recipient
    // can re-open it later from their own library. Mark the inbox
    // message as imported either way so the chip flips green.
    //
    // Track success: only when this insert actually committed do we tell
    // the detail screen the recipe is already in My Recipes. Without
    // that flag the screen's own "Save to My Recipes" CTA fired a SECOND
    // insert when the user tapped it, producing the duplicate seen in
    // 44799 / 44801.
    var alreadySaved = false;
    try {
      await RecipeRepository.instance.insert(recipe, source: 'inbox-share');
      alreadySaved = true;
    } catch (_) {/* ignore — UI still opens the detail view below */}
    _importMessage(msg);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RecipeDetailScreen(
          recipe:         recipe,
          initiallySaved: alreadySaved,
        ),
      ),
    );
  }

  Future<void> _openSharedMealPlan(BuildContext context, InboxMessage msg) async {
    // Re-fetch the row to get the full `days` payload — the local
    // InboxMessage model deliberately keeps it lean and doesn't cache
    // multi-day maps in SharedPreferences.
    Map<String, dynamic>? payload;
    try {
      final row = await Supabase.instance.client
          .from('inbox_messages')
          .select('payload')
          .eq('id', msg.id)
          .maybeSingle();
      payload = (row?['payload'] as Map?)?.cast<String, dynamic>();
    } catch (_) {/* fall through with null — planner just opens empty */}
    _importMessage(msg);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MealPlannerScreen(incomingShare: payload),
      ),
    );
  }

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final tt  = Theme.of(context).textTheme;
    final top = MediaQuery.of(context).padding.top;

    return Scaffold(
      backgroundColor: _kCream,
      body: Column(
        children: [

          // ── Header ────────────────────────────────────────────────────────
          Container(
            color:   _kCream,
            padding: EdgeInsets.fromLTRB(8, top + 8, 20, 12),
            child: Row(
              children: [
                IconButton(
                  icon:  const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
                  color: _kForest,
                  onPressed: () => Navigator.of(context).pop(),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Row(
                    children: [
                      Text(
                        'Inbox',
                        style: tt.titleLarge?.copyWith(
                          fontWeight: FontWeight.w900,
                          color:      _kForest,
                        ),
                      ),
                      if (_unreadCount > 0) ...[
                        const SizedBox(width: 8),
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 250),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color:        _kOrange,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            '$_unreadCount new',
                            style: const TextStyle(
                              color:      Colors.white,
                              fontSize:   11,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                // Mark-all-read action
                if (_unreadCount > 0)
                  TextButton(
                    onPressed: () {
                      for (final m in _messages.where((m) => !m.isRead)) {
                        setState(() => m.isRead = true);
                        widget.onMarkRead(m.id);
                      }
                    },
                    child: const Text(
                      'Mark all read',
                      style: TextStyle(
                        color:      _kForest,
                        fontSize:   12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
            ),
          ),

          const Divider(color: _kDivider, height: 1),

          // ── Body ──────────────────────────────────────────────────────────
          Expanded(
            child: _messages.isEmpty
                ? const _EmptyInbox()
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                    itemCount:        _messages.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (ctx, i) {
                      final msg = _messages[i];
                      return _MessageCard(
                        key:      ValueKey(msg.id),
                        message:  msg,
                        onTap:    () => _openDetail(ctx, msg),
                        onDelete: () => _deleteMessage(msg.id),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// _MessageCard
// =============================================================================

class _MessageCard extends StatelessWidget {
  const _MessageCard({
    super.key,
    required this.message,
    required this.onTap,
    required this.onDelete,
  });

  final InboxMessage message;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  // Derive initials from handle "@SiphoK" → "SK"
  String get _initials {
    final clean = message.fromHandle.replaceAll('@', '');
    final upper = clean.isEmpty ? '?' : clean[0].toUpperCase() + clean.substring(1);
    final caps  = RegExp(r'[A-Z]').allMatches(upper);
    if (caps.length >= 2) {
      return '${caps.elementAt(0).group(0)}${caps.elementAt(1).group(0)}';
    }
    return upper.substring(0, upper.length.clamp(0, 2)).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final tt     = Theme.of(context).textTheme;
    final unread = !message.isRead;

    return Dismissible(
      key:       ValueKey(message.id),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => onDelete(),
      background: Container(
        alignment: Alignment.centerRight,
        padding:   const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          color:        Colors.red.shade100,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Icon(Icons.delete_outline_rounded, color: Colors.red.shade400),
      ),
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          padding:  const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: unread ? Colors.white : const Color(0xFFF5F3EF),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: unread ? _kOrange.withAlpha(80) : _kDivider,
              width: unread ? 1.5 : 1.0,
            ),
            boxShadow: unread
                ? [
                    BoxShadow(
                      color:      _kOrange.withAlpha(20),
                      blurRadius: 12,
                      offset:     const Offset(0, 3),
                    ),
                  ]
                : const [],
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [

              // Avatar
              Container(
                width:     46,
                height:    46,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF0C351E), Color(0xFF2E7D4F)],
                    begin:  Alignment.topLeft,
                    end:    Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  _initials,
                  style: const TextStyle(
                    color:      Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize:   15,
                  ),
                ),
              ),

              const SizedBox(width: 12),

              // Content
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            message.displaySender,
                            style: tt.titleSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                              color:      _kForest,
                            ),
                          ),
                        ),
                        Text(
                          message.timeAgo,
                          style: tt.bodySmall?.copyWith(color: _kMuted),
                        ),
                        if (unread) ...[
                          const SizedBox(width: 8),
                          Container(
                            width:  8,
                            height: 8,
                            decoration: const BoxDecoration(
                              color: _kOrange,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    RichText(
                      text: TextSpan(
                        style: tt.bodyMedium
                            ?.copyWith(color: _kMuted, height: 1.4),
                        children: [
                          TextSpan(
                            text: switch (message.kind) {
                              InboxMessageKind.recipe   => 'Shared a recipe: ',
                              InboxMessageKind.mealPlan => 'Shared a meal plan: ',
                              _                          => 'Shared a grocery list: ',
                            },
                          ),
                          TextSpan(
                            text:  '"${message.listName}"',
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              color:      _kForest,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),

                    // Item count chip + import status chip — recipe shares
                    // count ingredients instead of shopping-list items so
                    // the chip stays meaningful for either kind.
                    Row(
                      children: [
                        _Chip(
                          icon: switch (message.kind) {
                            InboxMessageKind.recipe   => Icons.restaurant_menu_rounded,
                            InboxMessageKind.mealPlan => Icons.calendar_month_rounded,
                            _                          => Icons.checklist_rounded,
                          },
                          label: switch (message.kind) {
                            InboxMessageKind.recipe   =>
                              '${message.recipeIngredients.length} ingredients',
                            InboxMessageKind.mealPlan => 'Weekly plan',
                            _                          =>
                              '${message.items.length} items',
                          },
                          bg:    const Color(0xFFEDE9E3),
                          fg:    _kMuted,
                        ),
                        const SizedBox(width: 6),
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 300),
                          child: message.isImported
                              ? _Chip(
                                  key:   const ValueKey('imported'),
                                  icon:  Icons.check_circle_rounded,
                                  label: 'Imported',
                                  bg:    _kForest.withAlpha(20),
                                  fg:    _kForest,
                                )
                              : _Chip(
                                  key:   const ValueKey('pending'),
                                  icon:  Icons.download_rounded,
                                  label: 'Tap to import',
                                  bg:    _kOrange.withAlpha(20),
                                  fg:    _kOrange,
                                ),
                        ),
                      ],
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
// _MessageDetailSheet — full item preview + import action (StatefulWidget)
// =============================================================================

class _MessageDetailSheet extends StatefulWidget {
  const _MessageDetailSheet({
    required this.message,
    required this.onImport,
  });

  final InboxMessage message;
  final VoidCallback onImport;

  @override
  State<_MessageDetailSheet> createState() => _MessageDetailSheetState();
}

class _MessageDetailSheetState extends State<_MessageDetailSheet> {

  // Local flag so the button flips instantly without waiting for the parent
  // StatefulWidget tree to rebuild.
  late bool _imported;

  @override
  void initState() {
    super.initState();
    _imported = widget.message.isImported;
  }

  void _handleImport() {
    setState(() => _imported = true);
    widget.onImport();               // fires _importMessage in InboxScreenState
  }

  @override
  Widget build(BuildContext context) {
    final tt     = Theme.of(context).textTheme;
    final bottom = MediaQuery.of(context).padding.bottom;

    // Group items by category
    final grouped = <GroceryCategory, List<ShoppingItem>>{};
    for (final item in widget.message.items) {
      grouped.putIfAbsent(item.category, () => []).add(item);
    }
    final cats = GroceryCategory.values
        .where((c) => grouped.containsKey(c))
        .toList();

    return Container(
      decoration: const BoxDecoration(
        color:        _kCream,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
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
                color:        _kDivider,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),

          // Sheet header
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color:        _kForest.withAlpha(15),
                        borderRadius: BorderRadius.circular(20),
                        border:       Border.all(color: _kForest.withAlpha(40)),
                      ),
                      child: Text(
                        widget.message.displaySender,
                        style: const TextStyle(
                          fontSize:   12,
                          fontWeight: FontWeight.w700,
                          color:      _kForest,
                        ),
                      ),
                    ),
                    const Spacer(),
                    Text(
                      widget.message.timeAgo,
                      style: tt.bodySmall?.copyWith(color: _kMuted),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  widget.message.listName,
                  style: tt.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w900,
                    color:      _kForest,
                    height:     1.1,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${widget.message.items.length} items across '
                  '${cats.length} ${cats.length == 1 ? 'aisle' : 'aisles'}',
                  style: tt.bodyMedium?.copyWith(color: _kMuted),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),
          const Divider(color: _kDivider, height: 1),

          // Items list
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
              children: [
                for (final cat in cats) ...[
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      '${cat.emoji}  ${cat.displayName}',
                      style: const TextStyle(
                        fontSize:      12,
                        fontWeight:    FontWeight.w700,
                        color:         _kForest,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ),
                  Container(
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color:        Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border:       Border.all(color: _kDivider),
                    ),
                    child: Column(
                      children: [
                        for (int i = 0; i < grouped[cat]!.length; i++) ...[
                          Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 11),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    grouped[cat]![i].name,
                                    style: tt.bodyMedium?.copyWith(
                                        fontWeight: FontWeight.w600),
                                  ),
                                ),
                                if (grouped[cat]![i]
                                    .displayQuantity
                                    .isNotEmpty)
                                  Text(
                                    grouped[cat]![i].displayQuantity,
                                    style: tt.bodySmall
                                        ?.copyWith(color: _kMuted),
                                  ),
                              ],
                            ),
                          ),
                          if (i < grouped[cat]!.length - 1)
                            const Divider(
                                height: 1, indent: 16, endIndent: 16),
                        ],
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),

          // ── Import button — flips instantly on press ─────────────────────
          Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, bottom + 20),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              transitionBuilder: (child, anim) =>
                  FadeTransition(opacity: anim, child: child),
              child: _imported
                  ? Container(
                      key:     const ValueKey('done'),
                      width:   double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      decoration: BoxDecoration(
                        color:        _kForest.withAlpha(15),
                        borderRadius: BorderRadius.circular(16),
                        border:
                            Border.all(color: _kForest.withAlpha(40)),
                      ),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.check_circle_rounded,
                              color: _kForest, size: 20),
                          SizedBox(width: 8),
                          Text(
                            'Already imported to your library',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color:      _kForest,
                              fontSize:   15,
                            ),
                          ),
                        ],
                      ),
                    )
                  : SizedBox(
                      key:   const ValueKey('import'),
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _handleImport,
                        icon:  const Icon(Icons.download_rounded, size: 20),
                        label: const Text(
                          'Import to My Library',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize:   15,
                          ),
                        ),
                        style: FilledButton.styleFrom(
                          backgroundColor: _kOrange,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16)),
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
// _EmptyInbox
// =============================================================================

class _EmptyInbox extends StatelessWidget {
  const _EmptyInbox();

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
                color:        _kForest.withAlpha(15),
                borderRadius: BorderRadius.circular(24),
                border:       Border.all(color: _kForest.withAlpha(40)),
              ),
              child: const Icon(
                Icons.mark_email_read_outlined,
                size:  38,
                color: _kForest,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Nothing cooking yet!',
              style: tt.titleLarge?.copyWith(
                fontWeight: FontWeight.w900,
                color:      _kForest,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'When anyone shares a recipe, list, or meal plan with '
              "you, it'll pop up right here ready for action.",
              textAlign: TextAlign.center,
              style: tt.bodyMedium?.copyWith(color: _kMuted, height: 1.55),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// _Chip — micro label widget
// =============================================================================

class _Chip extends StatelessWidget {
  const _Chip({
    super.key,
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
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color:        bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: fg),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize:   11,
              fontWeight: FontWeight.w700,
              color:      fg,
            ),
          ),
        ],
      ),
    );
  }
}
