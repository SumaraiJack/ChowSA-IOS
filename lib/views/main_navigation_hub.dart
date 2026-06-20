// lib/views/main_navigation_hub.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/app_theme.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/user_profile.dart';
import '../models/user_rank.dart';
import '../models/shopping_list.dart';
import '../models/inbox_message.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:in_app_review/in_app_review.dart';
import 'auth_screen.dart';
import 'scraper_screen.dart';
import 'pantry_screen.dart';
import 'community_feed_screen.dart';
import 'community_hub_screen.dart';
import 'shopping_list_screen.dart';
import 'settings_screen.dart';
import 'privacy_settings_screen.dart';
import 'inbox_screen.dart';
import '../widgets/motion.dart';
import 'meal_planner_screen.dart';
import '../config/servings_pref.dart';
import 'dart:async';
import '../services/entitlement_service.dart';
import '../services/notification_center.dart';
import '../services/recipe_repository.dart';
import '../services/shared_assets_service.dart';
import '../services/friends_service.dart';
import '../services/location_permission_gate.dart';
import '../state/inbox_controller.dart';
import '../state/shared_assets_controller.dart';
import 'kitchen_circle_screen.dart';
import 'pro_avatar_picker_sheet.dart';
// =============================================================================
// MainNavigationHub — 4-tab root shell
//
// Owns authentication state so the Profile tab can gate between AuthScreen
// (logged out) and _ProfileView (logged in) without an outer wrapper widget.
// IndexedStack keeps every screen alive across tab switches so scroll positions
// and in-progress states are never lost.
// =============================================================================

class MainNavigationHub extends StatefulWidget {
  const MainNavigationHub({
    super.key,
    this.onChowThemeChanged,
    this.onFontChanged,
  });

  final void Function(ChowTheme)? onChowThemeChanged;
  final void Function(String)?    onFontChanged;

  @override
  State<MainNavigationHub> createState() => _MainNavigationHubState();
}

class _MainNavigationHubState extends State<MainNavigationHub> {
  int          _currentIndex = 0;
  UserProfile? _profile;

  /// Timestamp of the most recent system-back press while at the root.
  /// Drives the double-tap-to-exit pattern — see [build]'s PopScope.
  DateTime? _lastBackPress;
  static const _kBackExitWindow = Duration(seconds: 2);

  // Settings state — owned here and forwarded to SettingsScreen
  bool      _isMetric       = true;
  // Persisted to SharedPreferences under kServingsPrefKey so the choice
  // survives cold starts. Pantry recipe generation reads the same key.
  int       _defaultServings = kServingsDefault;
  ChowTheme _chowTheme      = ChowTheme.fresh;

  // Shopping list pending items — recipe workspace deposits here,
  // ShoppingListScreen consumes them via didUpdateWidget.
  List<ShoppingItem>  _pendingShoppingItems = [];
  /// Custom list title to apply when [_pendingShoppingItems] gets imported.
  /// Set by [_handleInboxImport] so a shared "Bolognaise List" doesn't
  /// land as the generic "New List" on the recipient's device.
  String?             _pendingListName;

  // Saved community recipes — lifted from CommunityFeedScreen so Profile
  // can show the real count and Home can show the saved list.
  static const _savedRecipesPrefKey = 'saved_community_recipes_v1';
  List<SavedCommunityRecipe> _savedRecipes = [];

  int get _savedRecipesCount => _savedRecipes.length;

  // Inbox state now lives in NotificationCenter — both the Home Screen
  // inbox icon and the Profile Screen bell observe a single
  // ValueNotifier<int> there, so marking a message read in either place
  // clears the badge on the other in the same frame (no pull-to-refresh,
  // no app restart). The hub keeps these getters as a thin compatibility
  // layer for surfaces that still read the list shape directly.
  List<InboxMessage>  get _inboxMessages    =>
      NotificationCenter.instance.messages.value;

  int                 get _unreadInboxCount =>
      NotificationCenter.instance.unreadCount.value;

  // Inbox + shared-assets realtime subscriptions now live in
  // SessionController + InboxController + SharedAssetsController. This
  // widget just LISTENS to their notifiers — no manual channels here.

  @override
  void initState() {
    super.initState();
    _loadSavedRecipes();
    _restoreSession();
    _loadDefaultServings();
    // Banner-on-incoming-share: piggy-back on the SharedAssetsController
    // notifier so we don't open a parallel subscription to the same
    // table. The controller already de-dups via announcedIds.
    SharedAssetsController.instance.unread.addListener(_onSharedAssetsTick);
    // First-frame GPS-hardware check. The runtime permission gate handles
    // the Android permission dialog; this catches the orthogonal case where
    // permission is granted but the device-level Location toggle is off —
    // previously failed silently until the user dropped a Spotted pin.
    // Latches per-session so users don't get re-prompted every tab switch.
    // Permission-first flow: ensureServicesOnPrompt runs the runtime
    // permission request, then ONLY if the user grants it AND GPS is off
    // does it show the ChowSA-branded "Turn on Location" modal. No
    // banner, single source of UI truth (custom modal).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        LocationPermissionGate.instance.ensureServicesOnPrompt(context);
      }
    });
  }

  void _onSharedAssetsTick() {
    if (!mounted) return;
    final unread = SharedAssetsController.instance.unread.value;
    if (unread.isEmpty) return;
    final announced = SharedAssetsController.instance.announcedIds;
    final fresh = unread.where((a) => !announced.contains(a.id)).toList();
    if (fresh.isEmpty) return;
    announced.addAll(fresh.map((a) => a.id));
    _showSharedAssetBanner(fresh.first);
  }

  void _showSharedAssetBanner(SharedAsset asset) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    final isList = asset.assetType == SharedAssetType.shoppingList;
    final label  = isList ? 'Shopping List' : 'Menu Plan';

    // MaterialBanner sits at the TOP of the Scaffold body — replaces the
    // old bottom SnackBar so the heads-up reads more like a system push
    // and never collides with the bottom nav.
    void clear() => messenger.hideCurrentMaterialBanner();
    messenger.showMaterialBanner(
      MaterialBanner(
        backgroundColor: const Color(0xFF0C351E),
        contentTextStyle: const TextStyle(
            color: Colors.white, fontWeight: FontWeight.w700),
        content: Text(
          'Chef ${asset.senderHandle} just shared a $label with you! '
          'Tap OPEN to import.',
        ),
        leading: const Icon(Icons.notifications_active_rounded,
            color: Color(0xFFFFB300)),
        actions: [
          TextButton(
            onPressed: clear,
            child: const Text('LATER',
                style: TextStyle(color: Colors.white70,
                    fontWeight: FontWeight.w800)),
          ),
          TextButton(
            onPressed: () {
              clear();
              if (isList) {
                setState(() => _currentIndex = 2);
              } else {
                // Forward the shared menu payload so MealPlannerScreen
                // can merge the sender's plan immediately.
                Navigator.push(context, MaterialPageRoute<void>(
                  builder: (_) => MealPlannerScreen(
                    incomingShare: asset.payload,
                  ),
                ));
              }
              // Mark BOTH notification stores so the inbox bell + Profile
              // badge clear cleanly — `shared_assets.is_read=true` stops
              // the banner re-firing next session, and the global
              // `notifications` row gets flipped via the type-scoped
              // mark-read so the bell badge drops on the same frame.
              SharedAssetsController.instance.markRead(asset.id);
              InboxController.instance
                  .markAllReadOfType(isList ? 'list_shared' : 'meal_plan');
            },
            child: const Text('OPEN',
                style: TextStyle(color: Color(0xFFFFB300),
                    fontWeight: FontWeight.w900)),
          ),
        ],
      ),
    );
    // Auto-dismiss after ~6s so it doesn't camp on screen if the user
    // ignores it; the row stays in the inbox/notifications feed either way.
    Future<void>.delayed(const Duration(seconds: 6), () {
      if (mounted) messenger.hideCurrentMaterialBanner();
    });
  }

  // ── Settings persistence — serving size ────────────────────────────────────
  Future<void> _loadDefaultServings() async {
    final saved = await readDefaultServings();
    if (mounted) setState(() => _defaultServings = saved);
  }

  // Inbox realtime subscription is owned by InboxController (started by
  // SessionController on sign-in). No per-widget channel here.

  @override
  void dispose() {
    SharedAssetsController.instance.unread.removeListener(_onSharedAssetsTick);
    super.dispose();
  }

  void _restoreSession() {
    final user = Supabase.instance.client.auth.currentUser;
    if (user != null) {
      final handle = user.userMetadata?['handle'] as String? ??
          user.email?.split('@').first ??
          'Chef';
      setState(() {
        _profile = UserProfile(
          id:     user.id,
          handle: handle,
          email:  user.email ?? '',
        );
      });
      // Realtime inbox stream + missed-message back-fill are owned by
      // InboxController. SessionController has already kicked them off
      // for this user; nothing to do here beyond surfacing the profile.
    }
  }

  // ── Saved recipes persistence ────────────────────────────────────────────

  Future<void> _loadSavedRecipes() async {
    final prefs = await SharedPreferences.getInstance();
    final raw   = prefs.getString(_savedRecipesPrefKey);
    if (raw != null && mounted) {
      try {
        final list = (jsonDecode(raw) as List<dynamic>).map((e) {
          final m = e as Map<String, dynamic>;
          return SavedCommunityRecipe(
            id:          m['id'] as String,
            recipeTitle: m['recipeTitle'] as String,
            username:    m['username'] as String,
            tags:        List<String>.from(m['tags'] as List),
            savedAt:     DateTime.parse(m['savedAt'] as String),
          );
        }).toList();
        setState(() => _savedRecipes = list);
      } catch (_) {}
    }
  }

  Future<void> _persistSavedRecipes() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _savedRecipesPrefKey,
      jsonEncode(_savedRecipes.map((r) => {
        'id':          r.id,
        'recipeTitle': r.recipeTitle,
        'username':    r.username,
        'tags':        r.tags,
        'savedAt':     r.savedAt.toIso8601String(),
      }).toList()),
    );
  }

  void _handleDeleteSavedRecipe(String id) {
    setState(() => _savedRecipes = _savedRecipes.where((r) => r.id != id).toList());
    _persistSavedRecipes();
  }

  // Legacy share-to-user hook — kept as a no-op so callers wired to
  // widget.onShareToUser still compile, but the actual `inbox_messages`
  // INSERT is now ONLY done by _ShareListSheet._sendToUser() in
  // shopping_list_screen.dart. Having both surfaces insert produced the
  // duplicate-inbox-row report.
  Future<void> _handleShareToUser(String handle, ShoppingList list) async {}

  void _handleInboxMarkRead(String id) {
    NotificationCenter.instance.markRead(id);
  }

  /// Bulk mark-read fired by either bell icon (Home Screen top-right OR
  void _handleInboxImport(InboxMessage msg) {
    // Duplicate the list into the user's personal library via pending
    // items. NotificationCenter.markImported also flips isRead so the
    // dual badge clears in lock-step.
    setState(() {
      _pendingShoppingItems = List.from(msg.items);
      // Carry the SENDER'S original list title across so the recipient
      // sees "Bolognaise List" instead of a generic "New List".
      _pendingListName      = msg.listName;
      _currentIndex         = 2;        // jump to Shopping tab
    });
    NotificationCenter.instance.markImported(msg.id);
  }

  void _handleInboxDelete(String id) {
    NotificationCenter.instance.remove(id);
  }

  // Called by AuthScreen when login/sign-up succeeds.
  void _onLoginSuccess(UserProfile profile) {
    setState(() {
      _profile      = profile;
      _currentIndex = 0; // jump to Chow Home so the user lands on content
    });
    // SessionController owns the realtime inbox + missed-message
    // back-fill; the auth.onAuthStateChange listener boots them as
    // soon as Supabase emits signedIn, so this widget needs no
    // per-login subscription kick.
  }

  // Called by _ProfileView "Sign Out" button.
  //
  // Full sign-out flow (Option B — root auth-state listener):
  //   1. Tear down Supabase auth so the access token is invalidated
  //      server-side and any subsequent .stream() calls reject.
  //   2. Drop the cached premium flag so the next signer-in re-runs the
  //      whitelist check fresh.
  //   3. Clear the in-memory profile — the root build() reads this and
  //      renders ONLY the AuthScreen when null, dropping the entire
  //      Scaffold + IndexedStack + bottom nav from the tree. No more
  //      back-door tab access for a signed-out user.
  //   4. Defensively reset the route stack to the AuthScreen so any
  //      pushed sub-routes (settings sheets, sub-detail screens, etc.)
  //      can't be navigated back into via the system back gesture.
  Future<void> _onSignOut() async {
    try {
      await Supabase.instance.client.auth.signOut();
    } catch (_) {
      // Server-side sign-out failed (offline / token already expired).
      // Local sign-out below still runs so the UI doesn't get stuck.
    }
    EntitlementService.instance.clearDatabasePremium();
    // Wipe the inbox so the next signed-in user doesn't inherit the
    // previous account's unread badges.
    NotificationCenter.instance.clear();
    if (!mounted) return;
    setState(() {
      _profile      = null;
      _currentIndex = 0; // reset so a later sign-in lands on Chow Home
    });
    // Wipe the entire route history. When the root rebuilds with
    // _profile == null it will render AuthScreen directly; this kills
    // any sub-routes (modal sheets, detail pages) that were sitting on
    // top of the hub so the back gesture can't re-enter them.
    if (mounted) {
      Navigator.of(context, rootNavigator: true)
          .popUntil((r) => r.isFirst);
    }
  }

  // Called by ScraperScreen / PantryScreen "Add to Shopping List".
  void _handleAddToShoppingList(List<ShoppingItem> items) {
    setState(() {
      _pendingShoppingItems = items;
      _currentIndex = 2; // jump to Shopping List tab
    });
  }

  void _onPendingConsumed() =>
      setState(() {
        _pendingShoppingItems = [];
        _pendingListName      = null;
      });

  void _navigateToTab(int index) => setState(() => _currentIndex = index);

  /// Opens InboxScreen directly from any tab (e.g. the home screen inbox icon)
  void _openInboxFromHome(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => InboxScreen(
          messages:        _inboxMessages,
          onMarkRead:      _handleInboxMarkRead,
          onImport:        _handleInboxImport,
          onDeleteMessage: _handleInboxDelete,
        ),
      ),
    );
  }

  void _handleChowThemeChanged(ChowTheme theme) {
    setState(() => _chowTheme = theme);
    widget.onChowThemeChanged?.call(theme);
  }

  /// Handles a system back press at the root hub.
  ///
  /// Rule 1 — Normal back navigation:
  ///   If the Navigator can pop (a sub-route is sitting on top of the
  ///   hub — a settings sheet, an inbox screen, a recipe detail, etc.),
  ///   pop it immediately. No dialog, no prompt.
  ///
  /// Rule 2 — Double-tap-to-exit at the root:
  ///   If there's nothing to pop (the user is at the hub's root with one
  ///   of the bottom-nav tabs active), show a brief floating SnackBar
  ///   prompting them to press back again. If they press back a second
  ///   time within [_kBackExitWindow], `SystemNavigator.pop()` closes
  ///   the app. Otherwise the timer resets on the next first-press.
  Future<void> _handleSystemBack() async {
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
      return;
    }

    final now  = DateTime.now();
    final last = _lastBackPress;
    if (last != null && now.difference(last) <= _kBackExitWindow) {
      // Second press inside the window — actually exit.
      await SystemNavigator.pop();
      return;
    }

    // First press (or stale). Stamp the timestamp and prompt the user.
    _lastBackPress = now;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content:  const Text(
          'Press back again to exit the app.',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        behavior:        SnackBarBehavior.floating,
        duration:        _kBackExitWindow,
        backgroundColor: const Color(0xFF0C351E),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      ),
    );
  }

  // SA exit phrases — retained in case a future settings menu wants an
  // explicit "Sign out and exit" confirmation. Currently unreferenced
  // by the back-press flow (replaced by _handleSystemBack above).
  // ignore: unused_field
  static const _exitPhrases = [
    ('Ag nee man, you leaving already?',   'Yebo, let me go', 'No ways, stay!'),
    ('Eish, sure you want to go?',         'Ja, I\'m done',   'Nope, staying'),
    ('Haibo! Leaving so soon?',            'Ja sure',         'Nah, I\'m lekker'),
    ('Sho\', you heading out now?',        'Yep, laters',     'Nope, chill here'),
    ('Aikona! Don\'t leave us hanging…',  'I\'m out',        'Stay, bru'),
  ];

  // ignore: unused_element
  Future<bool> _confirmExit(BuildContext context) async {
    final phrase = _exitPhrases[
        DateTime.now().millisecondsSinceEpoch % _exitPhrases.length];
    return await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(phrase.$1,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
        content: const Text(
          'Your recipes, pantry and lists will all be here when you get back. 🔥',
          style: TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(phrase.$3,
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFE59B27),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            child: Text(phrase.$2,
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    ) ?? false;
  }

  @override
  Widget build(BuildContext context) {
    // ── Root auth gate ────────────────────────────────────────────────────
    // When the user is signed out, render ONLY the AuthScreen. The full
    // navigation shell (Scaffold + IndexedStack + bottom nav) is dropped
    // entirely from the tree so a signed-out user can't tap into Home /
    // Pantry / Shopping / Community via the bottom bar — those Elements
    // don't exist. The moment _onLoginSuccess fires and _profile becomes
    // non-null, the shell remounts and the user lands on Chow Home.
    if (_profile == null) {
      return AuthScreen(onLoginSuccess: _onLoginSuccess);
    }

    return PopScope(
      // canPop: false here means the system back gesture is ALWAYS
      // intercepted at this root — we decide whether to pop a sub-route,
      // let the OS close the app, or show the double-tap-to-exit prompt.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _handleSystemBack();
      },
      child: Scaffold(
      // ── Content area — GestureDetector enables horizontal swipe navigation ─
      body: GestureDetector(
        onHorizontalDragEnd: (details) {
          // Require a meaningful velocity to avoid accidental swipes
          if (details.primaryVelocity == null) return;
          if (details.primaryVelocity! < -300) {
            // Swipe left → next tab
            if (_currentIndex < 4) setState(() => _currentIndex++);
          } else if (details.primaryVelocity! > 300) {
            // Swipe right → previous tab
            if (_currentIndex > 0) setState(() => _currentIndex--);
          }
        },
        behavior: HitTestBehavior.translucent,
        child: IndexedStack(
        index: _currentIndex,
        children: [
          // 0 — Chow Home
          ScraperScreen(
            onAddToShoppingList: _handleAddToShoppingList,
            savedRecipes:        _savedRecipes,
            onNavigateToTab:     _navigateToTab,
            onOpenInbox:         () => _openInboxFromHome(context),
          ),
          // 1 — My Pantry
          PantryScreen(onAddToShoppingList: _handleAddToShoppingList),
          // 2 — Shopping List
          ShoppingListScreen(
            pendingItems:      _pendingShoppingItems,
            pendingListName:   _pendingListName,
            onPendingConsumed: _onPendingConsumed,
            onShareToUser:     _handleShareToUser,
          ),
          // 3 — Community Hub (suburb-localized hub dashboard).
          // The legacy CommunityFeedScreen (recipe social feed) is still
          // reachable from the "What's Cooking" channel route inside the hub
          // and from Profile → Community Feed shortcut, but the top-level
          // Community tab now lands on the hub per the spec.
          const CommunityHubScreen(),
          // 4 — Profile / Auth  (switches internally based on _profile)
          _ProfileTabView(
            profile:                 _profile,
            onLoginSuccess:          _onLoginSuccess,
            onSignOut:               _onSignOut,
            inboxMessages:           _inboxMessages,
            unreadInboxCount:        _unreadInboxCount,
            savedRecipes:            _savedRecipes,
            savedRecipesCount:       _savedRecipesCount,
            onInboxMarkRead:         _handleInboxMarkRead,
            onInboxImport:           _handleInboxImport,
            onInboxDelete:           _handleInboxDelete,
            onDeleteSavedRecipe:     _handleDeleteSavedRecipe,
            onFontChanged:           widget.onFontChanged,
          ),
        ],
      ),   // IndexedStack
      ),   // GestureDetector

      // ── Bottom navigation ────────────────────────────────────────────────
      // NavigationBarTheme scoped here so it doesn't bleed into other screens.
      bottomNavigationBar: NavigationBarTheme(
        data: NavigationBarThemeData(
          // Lift the bar slightly off the page with a distinct tinted surface.
          backgroundColor:  Theme.of(context).colorScheme.surfaceContainerLow,
          // Orange-tinted pill indicator on the selected tab.
          indicatorColor:   Theme.of(context).colorScheme.primaryContainer,
          surfaceTintColor: Colors.transparent,
          elevation:        0,
          // Bold label when selected, regular when not.
          labelTextStyle: WidgetStateProperty.resolveWith(
            (states) => TextStyle(
              fontSize:   11,
              fontWeight: states.contains(WidgetState.selected)
                  ? FontWeight.w700
                  : FontWeight.w500,
              letterSpacing: 0.1,
            ),
          ),
        ),
        child: DecoratedBox(
          // Hairline top border separates the bar from the screen content.
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(
                color: Theme.of(context).colorScheme.outlineVariant.withAlpha(100),
                width: 0.5,
              ),
            ),
          ),
          child: NavigationBar(
            selectedIndex:         _currentIndex,
            onDestinationSelected: (i) => setState(() => _currentIndex = i),
            destinations: [
          const NavigationDestination(
            icon:         Icon(Icons.soup_kitchen_outlined),
            selectedIcon: Icon(Icons.soup_kitchen_rounded),
            label:        'Chow Home',
          ),
          const NavigationDestination(
            icon:         Icon(Icons.kitchen_outlined),
            selectedIcon: Icon(Icons.kitchen_rounded),
            label:        'My Pantry',
          ),
          const NavigationDestination(
            icon:         Icon(Icons.shopping_cart_outlined),
            selectedIcon: Icon(Icons.shopping_cart_rounded),
            label:        'Shopping',
          ),
          const NavigationDestination(
            icon:         Icon(Icons.groups_outlined),
            selectedIcon: Icon(Icons.groups_rounded),
            label:        'Community',
          ),
          // Profile tab shows a small badge dot when the user is NOT signed in,
          // prompting them to create an account.
          NavigationDestination(
            icon: _profile == null
                ? Badge(
                    smallSize: 7,
                    child: const Icon(Icons.account_circle_outlined),
                  )
                : const Icon(Icons.account_circle_outlined),
            selectedIcon: const Icon(Icons.account_circle_rounded),
            label: 'Profile',
          ),
        ],
          ),  // NavigationBar
        ),    // DecoratedBox
      ),      // NavigationBarTheme
    ),        // Scaffold
    );        // PopScope
  }
}

// =============================================================================
// Profile tab view — toggles between AuthScreen and _ProfileView
// =============================================================================

class _ProfileTabView extends StatelessWidget {
  const _ProfileTabView({
    required this.profile,
    required this.onLoginSuccess,
    required this.onSignOut,
    required this.inboxMessages,
    required this.unreadInboxCount,
    required this.savedRecipes,
    required this.savedRecipesCount,
    required this.onInboxMarkRead,
    required this.onInboxImport,
    required this.onInboxDelete,
    required this.onDeleteSavedRecipe,
    this.onFontChanged,
  });

  final UserProfile?                   profile;
  final void Function(UserProfile)     onLoginSuccess;
  final VoidCallback                   onSignOut;
  final List<InboxMessage>             inboxMessages;
  final int                            unreadInboxCount;
  final List<SavedCommunityRecipe>     savedRecipes;
  final int                            savedRecipesCount;
  final void Function(String)          onInboxMarkRead;
  final void Function(InboxMessage)    onInboxImport;
  final void Function(String)          onInboxDelete;
  final void Function(String)          onDeleteSavedRecipe;
  final void Function(String)?         onFontChanged;

  @override
  Widget build(BuildContext context) {
    if (profile == null) {
      return AuthScreen(onLoginSuccess: onLoginSuccess);
    }
    return _ProfileView(
      profile:              profile!,
      onSignOut:            onSignOut,
      inboxMessages:        inboxMessages,
      unreadInboxCount:     unreadInboxCount,
      savedRecipes:         savedRecipes,
      savedRecipesCount:    savedRecipesCount,
      onInboxMarkRead:      onInboxMarkRead,
      onInboxImport:        onInboxImport,
      onInboxDelete:        onInboxDelete,
      onDeleteSavedRecipe:  onDeleteSavedRecipe,
      onFontChanged:        onFontChanged,
    );
  }
}

// =============================================================================
// _ProfileView — shown when the user is authenticated
// =============================================================================

class _ProfileView extends StatefulWidget {
  const _ProfileView({
    required this.profile,
    required this.onSignOut,
    required this.inboxMessages,
    required this.unreadInboxCount,
    required this.savedRecipes,
    required this.savedRecipesCount,
    required this.onInboxMarkRead,
    required this.onInboxImport,
    required this.onInboxDelete,
    required this.onDeleteSavedRecipe,
    this.onFontChanged,
  });

  final UserProfile                  profile;
  final VoidCallback                 onSignOut;
  final List<InboxMessage>           inboxMessages;
  final int                          unreadInboxCount;
  final List<SavedCommunityRecipe>   savedRecipes;
  final int                          savedRecipesCount;
  final void Function(String)        onInboxMarkRead;
  final void Function(InboxMessage)  onInboxImport;
  final void Function(String)        onInboxDelete;
  final void Function(String)        onDeleteSavedRecipe;
  final void Function(String)?       onFontChanged;

  @override
  State<_ProfileView> createState() => _ProfileViewState();
}

class _ProfileViewState extends State<_ProfileView> {

  /// One realtime stream for the Kitchen Circle pending-invite badge,
  /// created ONCE per State. Never call streamPendingIncomingCount()
  /// inline inside build() — every rebuild (e.g. popping back from the
  /// Privacy route) would open a duplicate Supabase realtime channel on
  /// the same table+filter, and the second subscribe throws a state error
  /// that Flutter paints as the red ErrorWidget over the Activity section.
  /// `broadcast()` lets StreamBuilder re-listen safely across rebuilds.
  late final Stream<int> _pendingInvitesStream =
      FriendsService.instance.streamPendingIncomingCount().asBroadcastStream();

  /// Count of recipes this user has posted to the What's Cooking section.
  /// `shared_recipes.shared_by` is stamped on every successful share by
  /// RecipeShareService.shareToWhatsCooking — counting rows there gives the
  /// same total the user sees in the cooking channel.
  Future<int> _loadSharedChowsCount() async {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return 0;
    try {
      final res = await Supabase.instance.client
          .from('shared_recipes')
          .count(CountOption.exact)
          .eq('shared_by', uid);
      return res;
    } catch (_) {
      return 0;
    }
  }

  late Future<int> _sharedChowsCountFuture = _loadSharedChowsCount();

  @override
  void initState() {
    super.initState();
    // Cold-start hydration: read the persisted meal plan once so the Planned
    // bento card + Meal Plan Slots tile show the correct totals even when the
    // user lands on Profile before opening MealPlannerScreen this session.
    MealPlannerScreen.refreshTotalPlannedCount();
    _loadAvatarFromSupabase();
  }

  /// Persisted avatar asset path (e.g. 'assets/avatars/avatar_3.png').
  /// Null until loaded from Supabase; shows initials while null.
  String? _localAvatarPath;

  Future<void> _loadAvatarFromSupabase() async {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return;
    try {
      final row = await Supabase.instance.client
          .from('profiles')
          .select('avatar_url')
          .eq('id', uid)
          .maybeSingle();
      if (!mounted || row == null) return;
      final saved = row['avatar_url'] as String?;
      if (saved != null && saved.startsWith('assets/avatars/')) {
        setState(() => _localAvatarPath = saved);
      }
    } catch (_) {/* silently ignore — initials shown as fallback */}
  }

  Future<void> _pickAvatar(BuildContext context) async {
    final picked = await showProAvatarPickerSheet(context);
    if (picked == null || !mounted) return;
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid != null) {
      try {
        await Supabase.instance.client
            .from('profiles')
            .update({'avatar_url': picked})
            .eq('id', uid);
      } catch (_) {/* save best-effort — show locally regardless */}
    }
    setState(() => _localAvatarPath = picked);
  }

  // (Saved Recipes sheet removed — community bookmarks now surface inline
  //  on the Community tab; the Profile activity list only shows My Recipes.)

  void _showEditProfileSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context:            context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _EditProfileSheet(profile: widget.profile),
    );
  }

  void _shareApp() {
    Share.share(
      '🔥 Check out ChowSA — the AI-powered South African kitchen app!\n\n'
      'Scan recipes from TikTok & Instagram, match meals to your pantry, '
      'and build your grocery list automatically.\n\n'
      'https://play.google.com/store/apps/details?id=za.co.chowsa.app',
      subject: 'Cook smarter with ChowSA 🍲',
    );
  }

  void _openInbox(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => InboxScreen(
          messages:        widget.inboxMessages,
          onMarkRead:      widget.onInboxMarkRead,
          onImport:        widget.onInboxImport,
          onDeleteMessage: widget.onInboxDelete,
        ),
      ),
    );
  }

  void _openSettings(BuildContext context) {
    final hub = context.findAncestorStateOfType<_MainNavigationHubState>();
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => SettingsScreen(
          isMetric:            hub?._isMetric        ?? true,
          defaultServings:     hub?._defaultServings ?? 4,
          chowTheme:           hub?._chowTheme       ?? ChowTheme.fresh,
          onMetricChanged:     (v) => hub?.setState(() => hub._isMetric = v),
          // Update in-memory state AND persist to SharedPreferences so the
          // pantry generator picks it up on the next recipe request.
          onServingsChanged:   (v) {
            hub?.setState(() => hub._defaultServings = v);
            writeDefaultServings(v);
          },
          onChowThemeChanged:  (t) => hub?._handleChowThemeChanged(t),
          onFontChanged:       (f) => widget.onFontChanged?.call(f),
          // POPIA right-to-be-forgotten: after the RPC succeeds the privacy
          // screen calls this to reuse the existing sign-out teardown
          // (clears profile, drops route stack, lands on AuthScreen).
          onAccountDeleted:    () async => hub?._onSignOut(),
          // Easter-egg gate for the hidden Protea Blush theme — picker
          // shows it only when this handle matches ChowTheme.kBlushGateHandle.
          currentUserHandle:   widget.profile.handle,
        ),
      ),
    );
  }

  void _showRatingDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => const _RatingDialog(),
    );
  }

  void _showFeedbackSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context:            context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder:            (_) => const _FeedbackSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs  = Theme.of(context).colorScheme;
    final tt  = Theme.of(context).textTheme;
    final top = MediaQuery.of(context).padding.top;

    return Scaffold(
      backgroundColor: cs.surface,
      body: Column(
        children: [
          // ── Gradient hero header ───────────────────────────────────────────
          Container(
            width:   double.infinity,
            padding: EdgeInsets.only(
              top:    top + 32,
              bottom: 32,
              left:   24,
              right:  24,
            ),
            decoration: const BoxDecoration(
              // Deep Forest Green hero — mirrors the AppBar branding used on
              // Pantry / Shopping / Recipes / Auth. Replaces the previous
              // orange gradient that fought every other screen for attention.
              gradient: LinearGradient(
                begin:  Alignment.topLeft,
                end:    Alignment.bottomRight,
                colors: [Color(0xFF0F3E2B), Color(0xFF163E32), Color(0xFF205B4A)],
              ),
              borderRadius: BorderRadius.only(
                bottomLeft:  Radius.circular(32),
                bottomRight: Radius.circular(32),
              ),
            ),
            // ── Reactive profile header ──────────────────────────────────────
            // Centred avatar + @username + email in a Column, driven by a live
            // stream on the `profiles` row matching the authenticated user.
            // The inbox bell + settings gear sit in a small floating action
            // strip in the top-right corner so users still have access to
            // those screens — only their POSITION changed, not their presence.
            child: Stack(
              children: [
                StreamBuilder<List<Map<String, dynamic>>>(
                  stream: Supabase.instance.client
                      .from('profiles')
                      .stream(primaryKey: ['id'])
                      .eq('id',
                          Supabase.instance.client.auth.currentUser?.id ?? ''),
                  builder: (context, snapshot) {
                    if (!snapshot.hasData || snapshot.data!.isEmpty) {
                      return const Center(
                        child: SizedBox(
                          height: 130,
                          child: Center(
                            child: CircularProgressIndicator(
                                color: Colors.white),
                          ),
                        ),
                      );
                    }
                    final profile = snapshot.data!.first;
                    final username = (profile['username'] as String?) ??
                        (profile['handle'] as String?) ?? 'Chef';
                    final emailRaw = (profile['email'] as String?) ??
                        widget.profile.email;
                    final initialsSrc = username.isNotEmpty ? username : 'SU';
                    return Column(
                      children: [
                        GestureDetector(
                          onTap: () => _pickAvatar(context),
                          child: Stack(
                            alignment: Alignment.bottomRight,
                            children: [
                              // Avatar fallback — cream-sand surface with
                              // bottle-green initials. Matches the new
                              // "Mzansi Organic Luxury" palette: the gold
                              // is reserved for CTAs only, so the avatar
                              // shell reads as a neutral "card" surface
                              // and the green initials carry the brand
                              // contrast.
                              CircleAvatar(
                                radius: 46,
                                backgroundColor: AppTheme.kCreamSand,
                                child: _localAvatarPath != null
                                    ? ClipOval(
                                        child: Image.asset(
                                          _localAvatarPath!,
                                          width:  92,
                                          height: 92,
                                          fit:    BoxFit.cover,
                                          errorBuilder: (_, __, ___) => Text(
                                            initialsSrc.substring(
                                                0,
                                                initialsSrc.length >= 2 ? 2 : 1,
                                            ).toUpperCase(),
                                            style: const TextStyle(
                                                fontSize:   24,
                                                fontWeight: FontWeight.bold,
                                                color:      AppTheme.kBottleGreen),
                                          ),
                                        ),
                                      )
                                    : Text(
                                        initialsSrc.substring(
                                            0,
                                            initialsSrc.length >= 2 ? 2 : 1,
                                        ).toUpperCase(),
                                        style: const TextStyle(
                                            fontSize:   24,
                                            fontWeight: FontWeight.bold,
                                            color:      AppTheme.kBottleGreen),
                                      ),
                              ),
                              // Camera edit badge — Mango Gold accent. The
                              // gold dot pops against the cream avatar shell
                              // and the deep-green hero behind it without
                              // recreating the old orange-on-orange wash.
                              Container(
                                width:  26,
                                height: 26,
                                decoration: BoxDecoration(
                                  color:  AppTheme.kProteaGold,
                                  shape:  BoxShape.circle,
                                  border: Border.all(
                                    color: AppTheme.kAlabaster,
                                    width: 2,
                                  ),
                                ),
                                child: const Icon(
                                  Icons.camera_alt_rounded,
                                  color: AppTheme.kMidnight,
                                  size:  12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          // Raw username from the profile model — no '@' prefix.
                          // The handle is the identity ("Melrose" / "SumaraiJack")
                          // not a Twitter-style mention, so the symbol read as
                          // visual noise on the profile header.
                          username,
                          style: const TextStyle(
                              fontSize:   20,
                              fontWeight: FontWeight.bold,
                              color:      Colors.white),
                        ),
                        Text(
                          emailRaw,
                          style: TextStyle(
                              fontSize: 14,
                              color:    Colors.white.withValues(alpha: 0.8)),
                        ),
                        // ── Rank badge + private progress strip ──────────
                        // Public-facing title shown as a small badge under
                        // the email. The progress line below it (e.g.
                        // "14 posts until Level 2!") is PRIVATE — only the
                        // owner of the account ever reaches this screen so
                        // it's safe to render unconditionally here. The
                        // feed-side surface uses HandleRankBadge instead,
                        // which never exposes posts-to-next-tier.
                        const SizedBox(height: 8),
                        _PrivateRankStrip(handle: username),
                      ],
                    );
                  },
                ),

                // ── Top-right floating action strip (inbox + settings) ──────
                // Preserves access to both screens without intruding on the
                // centred-profile aesthetic of the new layout.
                Positioned(
                  top:   0,
                  right: 0,
                  child: Row(
                    children: [
                      // Profile-screen bell — observes the SAME
                      // ValueNotifier<int> as the Home Screen inbox icon
                      // (NotificationCenter.instance.unreadCount). The
                      // markAllRead() flip itself lives in
                      // InboxScreen.initState so the dual-badge sync
                      // fires regardless of which entry point opened the
                      // inbox (future deep links / push notifications
                      // benefit too). This bell just navigates.
                      AnimatedBuilder(
                        // NotificationCenter and NotificationsFeedService
                        // are both facades pointing at the SAME underlying
                        // InboxController.unreadCount — summing them
                        // double-counted every unread row. Listen once,
                        // read once.
                        animation: NotificationCenter.instance.unreadCount,
                        builder: (_, __) {
                          final unread =
                              NotificationCenter.instance.unreadCount.value;
                          return Stack(
                          clipBehavior: Clip.none,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.notifications_outlined,
                                  color: Colors.white),
                              tooltip:   'Inbox',
                              onPressed: () => _openInbox(context),
                            ),
                            if (unread > 0)
                              // IgnorePointer so the orange counter chip
                              // can't absorb taps and block the bell from
                              // navigating — the badge Container's color
                              // decoration was hit-testing opaque, and the
                              // Stack paints children in reverse hit-test
                              // order so taps in the upper-right of the
                              // bell landed on the badge with no onTap.
                              Positioned(
                                right: 6, top: 6,
                                child: IgnorePointer(
                                  child: Container(
                                  width: 16, height: 16,
                                  alignment: Alignment.center,
                                  decoration: const BoxDecoration(
                                    color: Color(0xFFE59B27),
                                    shape: BoxShape.circle,
                                  ),
                                  child: Text(
                                    '$unread',
                                    style: const TextStyle(
                                      color:      Colors.white,
                                      fontSize:   9,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                ),
                                ),
                              ),
                          ],
                        );
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.settings_outlined,
                            color: Colors.white),
                        tooltip:   'Settings',
                        onPressed: () => _openSettings(context),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),            // Container (gradient hero)

          // ── Bento stat tiles ─────────────────────────────────────────────
          // Three compact Bento-style cards showing activity counts at a glance.
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
            child: Row(
              children: [
                Expanded(
                  // ── LIVE "Saved" count ─────────────────────────────────────
                  // Previously bound to the SharedPreferences-backed
                  // _savedRecipes list, which could drift out of sync with the
                  // actual `recipes` table — e.g. when a saveFromCommunity
                  // cloud insert failed but the local list still cached the
                  // entry, the tile showed "1" while My Recipes was empty.
                  //
                  // Architecture:
                  //   • ValueListenableBuilder on RecipeRepository.updateNotifier
                  //     re-runs the count after every insert / update / delete
                  //   • FutureBuilder fires countAll() — which executes
                  //     `.count(CountOption.exact)` against the recipes table
                  //     scoped to auth.uid()
                  //   • Loads the cached count as a fallback so the tile never
                  //     flashes a stuck legacy value while the COUNT round-trips
                  child: ValueListenableBuilder<int>(
                    valueListenable: RecipeRepository.instance.updateNotifier,
                    builder: (_, __, ___) => FutureBuilder<int>(
                      // Initial render uses the prop-passed value (which itself
                      // reflects the local _savedRecipes list — fine as a first
                      // paint guess) so the tile renders instantly; the COUNT
                      // query then overwrites it with the authoritative number.
                      initialData: widget.savedRecipesCount,
                      future:      RecipeRepository.instance.countAll(),
                      builder: (_, snap) => _BentoStatCard(
                        icon:    Icons.bookmark_rounded,
                        count:   '${snap.data ?? 0}',
                        label:   'Saved',
                        bgColor: const Color(0xFF1A3A2A),
                        fgColor: const Color(0xFF6FCF97),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _BentoStatCard(
                    icon:    Icons.local_fire_department_rounded,
                    count:   '0',
                    label:   'Shared',
                    bgColor: cs.primaryContainer,
                    fgColor: cs.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: PressableScale(
                    // Reflect the latest count the moment the user returns from
                    // the planner — the .then(...) refresh covers cases where
                    // a foreign route (e.g. recipe detail → schedule) mutated
                    // the plan without the planner being in the route stack.
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => const MealPlannerScreen(),
                      ),
                    ).then((_) => MealPlannerScreen.refreshTotalPlannedCount()),
                    child: ValueListenableBuilder<int>(
                      valueListenable: MealPlannerScreen.totalPlannedNotifier,
                      builder: (_, total, __) => _BentoStatCard(
                        icon:    Icons.calendar_month_rounded,
                        count:   '$total',
                        label:   'Planned',
                        bgColor: cs.secondaryContainer,
                        fgColor: cs.onSecondaryContainer,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ── Scrollable content ─────────────────────────────────────────────
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 16),
              children: [
                // ── Activity section ─────────────────────────────────────────
                _SectionLabel(label: 'Activity'),
                // NOTE: 'My Recipes', 'Inbox', and 'Meal Plan Slots' tiles
                // were intentionally removed from the Profile activity list.
                // All three actions are already reachable from the primary
                // Home Screen deck (Chow Home tab) — the bento cards there
                // route to the same screens with live counts, so duplicating
                // them here was just visual noise on the Profile tab.
                //
                // Kitchen Circle stays — it's the one social-graph entry
                // point that has no Home-deck counterpart.
                // Shared Chows stays — read-only informational tile, no
                // duplicate elsewhere in the app yet.
                // ── Kitchen Circle (Friends) ─────────────────────────────────
                // StreamBuilder over the live realtime count. Drops to zero
                // the instant the user accepts an invite on another screen,
                // and ticks up immediately when a new pending row arrives
                // — no tab-rebuild or refresh needed.
                StreamBuilder<int>(
                  stream: _pendingInvitesStream,
                  builder: (_, snap) {
                    final pending = snap.data ?? 0;
                    return _ActionTile(
                      icon:  Icons.group_rounded,
                      title: 'My Kitchen Circle (Friends)',
                      trailing: pending > 0
                          ? Badge(
                              label: Text('$pending',
                                  style: const TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w800)),
                              child: const SizedBox.shrink(),
                            )
                          : null,
                      onTap: () => Navigator.push<void>(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => const KitchenCircleScreen(),
                        ),
                      ),
                    );
                  },
                ),
                FutureBuilder<int>(
                  future: _sharedChowsCountFuture,
                  builder: (_, snap) => _InfoTile(
                    icon:  Icons.share_outlined,
                    title: 'Shared Chows',
                    trailing: _CountBadge(count: snap.data ?? 0),
                  ),
                ),

                const SizedBox(height: 8),
                Divider(indent: 20, endIndent: 20, color: cs.outlineVariant),
                const SizedBox(height: 8),

                // ── App section ───────────────────────────────────────────────
                _SectionLabel(label: 'App'),
                // Pro upgrade CTA tile removed for v1.0 — every user gets
                // Pro features for free via EntitlementService.isPro.
                // Restore the gradient PRO tile here when Play Billing is
                // wired up in v1.1.
                _ActionTile(
                  icon:  Icons.star_outline_rounded,
                  title: 'Rate ChowSA',
                  onTap: () => _showRatingDialog(context),
                ),
                _ActionTile(
                  icon:  Icons.ios_share_outlined,
                  title: 'Share ChowSA with friends',
                  onTap: _shareApp,
                ),
                _ActionTile(
                  icon:  Icons.help_outline_rounded,
                  title: 'Help & Feedback',
                  onTap: () => _showFeedbackSheet(context),
                ),

                const SizedBox(height: 8),
                Divider(indent: 20, endIndent: 20, color: cs.outlineVariant),
                const SizedBox(height: 8),

                // ── Account section ───────────────────────────────────────────
                _SectionLabel(label: 'Account'),
                _ActionTile(
                  icon:  Icons.manage_accounts_outlined,
                  title: 'Edit Profile',
                  onTap: () => _showEditProfileSheet(context),
                ),
                // ── Privacy (POPIA) ────────────────────────────────────────────
                // Documented path referenced by the ChowSA Pro paywall:
                // Profile → Privacy → Erase my data. Pushes the same screen
                // that Settings exposes, so reviewers find the entry point
                // exactly where the in-app copy says it lives.
                _ActionTile(
                  icon:  Icons.shield_outlined,
                  title: 'Privacy',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => PrivacySettingsScreen(
                        onAccountDeleted: () async {
                          widget.onSignOut();
                        },
                      ),
                    ),
                  ),
                ),

                // Sign out
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: OutlinedButton.icon(
                    onPressed: widget.onSignOut,
                    icon:  Icon(Icons.logout_rounded, color: cs.error, size: 18),
                    label: Text(
                      'Sign Out',
                      style: TextStyle(color: cs.error, fontWeight: FontWeight.w700),
                    ),
                    style: OutlinedButton.styleFrom(
                      padding:  const EdgeInsets.symmetric(vertical: 14),
                      side:     BorderSide(color: cs.error.withAlpha(153)),
                      shape:    RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                  ),
                ),

                const SizedBox(height: 24),

                // App version footnote
                Center(
                  child: Text(
                    'ChowSA v1.0.0  •  Made with 🔥 in South Africa',
                    style: tt.bodySmall?.copyWith(
                      color:  cs.onSurfaceVariant.withAlpha(128),
                      height: 1.5,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// _PrivateRankStrip — owner-only rank badge + "X posts until Level Y"
// =============================================================================
//
// Rendered exclusively on the logged-in user's own Profile hero. The strip
// kicks off a Supabase post-count fetch on first build, then shows:
//   • the user's RankBadge (same one feed posts use)
//   • a small private line: "14 posts until Soweto Street Foodie!"
//
// The progress line is PRIVATE by contract — never reuse this widget on
// any feed / public surface.

class _PrivateRankStrip extends StatefulWidget {
  const _PrivateRankStrip({required this.handle});
  final String handle;

  @override
  State<_PrivateRankStrip> createState() => _PrivateRankStripState();
}

class _PrivateRankStripState extends State<_PrivateRankStrip> {
  int? _shareCount;

  String? get _uid => Supabase.instance.client.auth.currentUser?.id;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  void _resolve() {
    final uid = _uid;
    if (uid == null) return;
    final cached = UserRankService.instance.rankOfUid(uid, handle: widget.handle);
    if (cached != null && cached.isExclusive) return; // creators skip count
    UserRankService.instance.prefetchUid(uid).then((count) {
      if (!mounted) return;
      setState(() => _shareCount = count);
    });
  }

  /// Tap-to-pick title selector — lists the current tier's 5-title pool.
  Future<void> _openTitlePicker(UserRank rank) async {
    final pool = kTierTitlePools[rank.tier];
    if (pool == null) return; // exclusive creators don't pick
    final picked = await showModalBottomSheet<String>(
      context:            context,
      backgroundColor:    Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _TitlePickerSheet(
        tier:        rank.tier,
        pool:        pool,
        currentTitle: rank.title,
      ),
    );
    if (picked != null) await RankTitleStore.instance.setTitle(picked);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: RankTitleStore.instance.chosenTitle,
      builder: (_, chosen, __) {
        final uid = _uid;
        // Resolve via creator-aware path first (no count needed for them).
        UserRank? rank;
        if (uid != null) {
          rank = UserRank.forUser(
            handle:      widget.handle,
            shareCount:  _shareCount ?? 0,
            chosenTitle: chosen,
          );
        }
        if (rank == null) return const SizedBox(height: 24);

        // Creators: permanent badge + locked copy, no picker / progress.
        if (rank.isExclusive) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RankBadge(rank: rank, compact: false),
              const SizedBox(height: 6),
              Text(
                'Permanent creator title — locked to you ✨',
                style: TextStyle(
                  fontSize:   11.5,
                  fontWeight: FontWeight.w600,
                  color:      Colors.white.withValues(alpha: 0.85),
                ),
              ),
            ],
          );
        }

        // Standard ladder: tappable badge (opens picker) + progress line.
        final loaded   = _shareCount != null;
        final progress = !loaded
            ? null
            : (rank.sharesToNext != null && rank.nextTierTitle != null
                ? '${rank.sharesToNext} ${rank.sharesToNext == 1 ? 'share' : 'shares'} '
                  'until ${rank.nextTierTitle}'
                : 'Top tier reached — Legend status 🔥');

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              onTap: () => _openTitlePicker(rank!),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RankBadge(rank: rank, compact: false),
                  const SizedBox(width: 4),
                  Icon(Icons.expand_more_rounded,
                      size: 16, color: Colors.white.withValues(alpha: 0.7)),
                ],
              ),
            ),
            if (progress != null) ...[
              const SizedBox(height: 6),
              Text(
                progress,
                style: TextStyle(
                  fontSize:   11.5,
                  fontWeight: FontWeight.w600,
                  color:      Colors.white.withValues(alpha: 0.85),
                  letterSpacing: 0.2,
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

/// Bottom sheet listing the 5-title pool for the user's current tier.
class _TitlePickerSheet extends StatelessWidget {
  const _TitlePickerSheet({
    required this.tier,
    required this.pool,
    required this.currentTitle,
  });

  final int          tier;
  final List<String> pool;
  final String       currentTitle;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color:        Color(0xFFF4F1EA),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(
        top: 12, bottom: MediaQuery.of(context).padding.bottom + 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40, height: 4,
            decoration: BoxDecoration(
              color:        const Color(0xFFE6E2D8),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 22),
            child: Row(
              children: [
                Text(
                  'Choose your ${tierName(tier)} title',
                  style: const TextStyle(
                    fontSize:   15,
                    fontWeight: FontWeight.w900,
                    color:      Color(0xFF0C351E),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          for (final t in pool)
            ListTile(
              title: Text(
                t,
                style: TextStyle(
                  fontWeight: t == currentTitle
                      ? FontWeight.w900
                      : FontWeight.w600,
                  color: const Color(0xFF1F2A24),
                ),
              ),
              trailing: t == currentTitle
                  ? const Icon(Icons.check_circle_rounded,
                      color: Color(0xFFE59B27))
                  : null,
              onTap: () => Navigator.pop(context, t),
            ),
        ],
      ),
    );
  }
}

// =============================================================================
// _ProfileView sub-widgets
// =============================================================================

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
      child: Text(
        label.toUpperCase(),
        style: tt.labelSmall?.copyWith(
          color:        cs.onSurfaceVariant,
          letterSpacing: 1.2,
          fontWeight:   FontWeight.w700,
        ),
      ),
    );
  }
}

// A read-only info tile — no tap action, just displays a value.
class _InfoTile extends StatelessWidget {
  const _InfoTile({
    required this.icon,
    required this.title,
    required this.trailing,
  });

  final IconData icon;
  final String   title;
  final Widget   trailing;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return ListTile(
      leading:  Icon(icon, color: cs.onSurfaceVariant, size: 22),
      title:    Text(title),
      trailing: trailing,
      dense:    true,
    );
  }
}

// A tappable action tile — shows a chevron (or custom trailing widget).
class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.title,
    required this.onTap,
    this.trailing,
  });

  final IconData     icon;
  final String       title;
  final VoidCallback onTap;
  final Widget?      trailing;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return ListTile(
      leading:  Icon(icon, color: cs.onSurfaceVariant, size: 22),
      title:    Text(title),
      trailing: trailing ??
          Icon(Icons.chevron_right_rounded,
              color: cs.onSurfaceVariant.withAlpha(128), size: 20),
      onTap:    onTap,
      dense:    true,
    );
  }
}

// Small counter badge used on activity tiles.
class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color:        cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        '$count',
        style: TextStyle(
          fontSize:   12,
          fontWeight: FontWeight.w700,
          color:      cs.onSurfaceVariant,
        ),
      ),
    );
  }
}

// =============================================================================
// Bento stat card — compact profile metric tile
// =============================================================================

class _BentoStatCard extends StatelessWidget {
  const _BentoStatCard({
    required this.icon,
    required this.count,
    required this.label,
    required this.bgColor,
    required this.fgColor,
  });

  final IconData icon;
  final String   count;
  final String   label;
  final Color    bgColor;
  final Color    fgColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      decoration: BoxDecoration(
        color:        bgColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: fgColor, size: 18),
          const SizedBox(height: 10),
          Text(
            count,
            style: TextStyle(
              color:      fgColor,
              fontSize:   22,
              fontWeight: FontWeight.w900,
              height:     1.0,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            label,
            style: TextStyle(
              color:    fgColor.withAlpha(200),
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// _ProfileCookbookSheet — saved recipes list opened from Profile → Saved Recipes
// =============================================================================

class _ProfileCookbookSheet extends StatefulWidget {
  const _ProfileCookbookSheet({
    required this.recipes,
    required this.onDelete,
  });

  final List<SavedCommunityRecipe> recipes;
  final void Function(String id)   onDelete;

  @override
  State<_ProfileCookbookSheet> createState() => _ProfileCookbookSheetState();
}

class _ProfileCookbookSheetState extends State<_ProfileCookbookSheet> {
  late final List<SavedCommunityRecipe> _recipes;

  @override
  void initState() {
    super.initState();
    _recipes = List.from(widget.recipes);
  }

  void _deleteAt(int index) {
    final id = _recipes[index].id;
    setState(() => _recipes.removeAt(index));
    widget.onDelete(id);
  }

  void _showDetail(SavedCommunityRecipe r) {
    // useRootNavigator: true ensures the dialog pops above the bottom sheet
    // (otherwise the dialog is pushed into the sheet's own navigator and
    // immediately dismissed when the sheet closes, resulting in no visible dialog)
    showDialog<void>(
      context: context,
      useRootNavigator: true,
      builder: (_) => _SavedRecipeDetailDialog(recipe: r),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tt     = Theme.of(context).textTheme;
    final cs     = Theme.of(context).colorScheme;
    final bottom = MediaQuery.of(context).padding.bottom;

    return Container(
      decoration: BoxDecoration(
        color:        cs.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.82,
      ),
      child: Column(
        children: [
          Center(
            child: Container(
              margin:     const EdgeInsets.only(top: 12),
              width:      40,
              height:     4,
              decoration: BoxDecoration(
                color:        cs.outlineVariant,
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
                  'Saved Recipes',
                  style: tt.titleLarge?.copyWith(
                    fontWeight: FontWeight.w900,
                    color:      const Color(0xFF0C351E),
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color:        cs.primaryContainer,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '${_recipes.length}',
                    style: TextStyle(
                      color:      cs.onPrimaryContainer,
                      fontSize:   12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),
          Divider(color: cs.outlineVariant, height: 1),

          Expanded(
            child: _recipes.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.bookmark_add_outlined,
                            size: 48,
                            color: cs.onSurfaceVariant.withAlpha(128)),
                        const SizedBox(height: 12),
                        Text('No saved recipes yet',
                            style: tt.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 6),
                        Text(
                          'Bookmark posts in the Community\ntab to build your cookbook.',
                          textAlign: TextAlign.center,
                          style: tt.bodySmall?.copyWith(
                            color:  cs.onSurfaceVariant,
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                    itemCount:        _recipes.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (_, i) {
                      final r = _recipes[i];
                      return GestureDetector(
                        onTap: () => _showDetail(r),
                        child: Container(
                          padding:    const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color:        cs.surfaceContainerLow,
                            borderRadius: BorderRadius.circular(18),
                            border:       Border.all(color: cs.outlineVariant),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width:  44,
                                height: 44,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color:        const Color(0xFF0C351E)
                                      .withAlpha(15),
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
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      'by ${r.username}',
                                      style: tt.bodySmall?.copyWith(
                                          color: cs.onSurfaceVariant),
                                    ),
                                    if (r.tags.isNotEmpty) ...[
                                      const SizedBox(height: 6),
                                      Wrap(
                                        spacing:    4,
                                        runSpacing: 4,
                                        children: r.tags.take(3).map((t) =>
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 8, vertical: 2),
                                            decoration: BoxDecoration(
                                              color:        const Color(0xFF0C351E).withAlpha(10),
                                              borderRadius: BorderRadius.circular(20),
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
                              const SizedBox(width: 8),
                              // Delete button
                              GestureDetector(
                                onTap: () => _confirmDelete(i),
                                child: Container(
                                  width:  34,
                                  height: 34,
                                  decoration: BoxDecoration(
                                    color:        cs.errorContainer,
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Icon(
                                    Icons.delete_outline_rounded,
                                    size:  17,
                                    color: cs.onErrorContainer,
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

          SizedBox(height: bottom + 8),
        ],
      ),
    );
  }

  void _confirmDelete(int index) {
    showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove saved recipe?'),
        content: const Text('This will remove it from your cookbook.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Remove'),
          ),
        ],
      ),
    ).then((confirmed) {
      if (confirmed == true && mounted) _deleteAt(index);
    });
  }
}

// =============================================================================
// _RatingDialog — 5-star rating overlay
// =============================================================================

class _RatingDialog extends StatefulWidget {
  const _RatingDialog();

  @override
  State<_RatingDialog> createState() => _RatingDialogState();
}

class _RatingDialogState extends State<_RatingDialog> {
  int  _stars     = 0;
  bool _submitted = false;
  bool _launching = false;

  static const _kForest  = Color(0xFF0C351E);
  static const _kOrange  = Color(0xFFE59B27);
  static const _kCream   = Color(0xFFF4F1EA);

  /// Android applicationId used to build the Play Store URL — matches the
  /// `applicationId` in android/app/build.gradle.kts.
  static const _androidPackageId = 'za.co.chowsa.app';

  /// Preferred deep link — opens the Play Store APP directly to the
  /// ChowSA listing's review section. Resolves only on devices that have
  /// the Play Store installed.
  static const _marketUri =
      'market://details?id=$_androidPackageId';

  /// Web fallback. Used when `market://` isn't resolvable (Play Store
  /// missing, custom Android ROM, iOS, etc.). Opens the Play Store web
  /// listing in the device browser.
  static const _webStoreUrl =
      'https://play.google.com/store/apps/details?id=$_androidPackageId';

  /// Tap-a-star handler. Tries the native Play Store in-app review dialog
  /// first; if Google's quota policy declines (most common reason it no-ops
  /// — Play caps in-app prompts per user / per app version), falls back to
  /// the market:// deep link, then to the https Play Store listing.
  Future<void> _triggerInAppReview() async {
    try {
      final review = InAppReview.instance;
      if (await review.isAvailable()) {
        await review.requestReview();
        return;
      }
    } catch (_) { /* fall through to deep-link */ }

    try {
      final marketUri = Uri.parse(_marketUri);
      if (await canLaunchUrl(marketUri)) {
        if (await launchUrl(marketUri,
            mode: LaunchMode.externalApplication)) {
          return;
        }
      }
      await launchUrl(Uri.parse(_webStoreUrl),
          mode: LaunchMode.externalApplication);
    } catch (_) { /* swallow — non-fatal */ }
  }

  Future<void> _submitRating() async {
    if (_stars == 0) return;
    setState(() { _submitted = true; _launching = true; });

    // 4★ or 5★ → push the user to the Play Store. Try the `market://`
    // deep link first so the native Play Store app opens directly with
    // the review prompt; fall back to the https web listing on devices
    // where the deep link can't be resolved.
    if (_stars >= 4) {
      try {
        final marketUri = Uri.parse(_marketUri);
        var opened = false;
        if (await canLaunchUrl(marketUri)) {
          opened = await launchUrl(
            marketUri,
            mode: LaunchMode.externalApplication,
          );
        }
        if (!opened) {
          await launchUrl(
            Uri.parse(_webStoreUrl),
            mode: LaunchMode.externalApplication,
          );
        }
      } catch (_) {/* swallow — user is already on the thanks card */}
    }
    if (mounted) setState(() => _launching = false);
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;

    return Dialog(
      backgroundColor: _kCream,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: _submitted ? _buildThanks(tt) : _buildForm(tt),
      ),
    );
  }

  Widget _buildThanks(TextTheme tt) {
    final highRating = _stars >= 4;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          highRating ? Icons.star_rounded : Icons.check_circle_rounded,
          color: highRating ? _kOrange : _kForest,
          size: 52,
        ),
        const SizedBox(height: 14),
        Text(
          highRating ? 'Opening Play Store… 🔥' : 'Thanks for the feedback!',
          style: tt.titleMedium?.copyWith(
            fontWeight: FontWeight.w900,
            color: highRating ? _kOrange : _kForest,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          highRating
              ? 'A quick review on the Play Store helps ChowSA reach more South African home cooks.'
              : 'We really appreciate you taking the time. Your feedback helps us improve.',
          style:     tt.bodySmall?.copyWith(color: null, height: 1.5),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _launching ? null : () => Navigator.pop(context),
            style: FilledButton.styleFrom(
              backgroundColor: _kForest,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            child: _launching
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('Done', style: TextStyle(fontWeight: FontWeight.w800)),
          ),
        ),
      ],
    );
  }

  Widget _buildForm(TextTheme tt) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Icon badge
        Container(
          width: 60, height: 60,
          decoration: BoxDecoration(
            gradient:     const LinearGradient(
              colors: [Color(0xFFE8611A), Color(0xFFFF8F00)],
              begin:  Alignment.topLeft,
              end:    Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(18),
          ),
          child: const Icon(Icons.star_rounded, color: Colors.white, size: 30),
        ),
        const SizedBox(height: 16),
        Text(
          'Rate ChowSA',
          style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w900, color: _kForest),
        ),
        const SizedBox(height: 4),
        Text(
          'How are we doing?',
          style: tt.bodySmall?.copyWith(color: null),
        ),
        const SizedBox(height: 20),

        // Stars — tap fires the NATIVE Play Store in-app review dialog.
        // Falls back to the market://details deep link (and then to the
        // https web listing) on devices where the in-app prompt is
        // unavailable, so the user always lands somewhere they can rate.
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(5, (i) {
            final filled = i < _stars;
            return GestureDetector(
              onTap: () {
                setState(() => _stars = i + 1);
                _triggerInAppReview();
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Icon(
                  filled ? Icons.star_rounded : Icons.star_border_rounded,
                  color: filled ? _kOrange : const Color(0xFFBDB9B2),
                  size:  38,
                ),
              ),
            );
          }),
        ),
        const SizedBox(height: 24),

        // Submit
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _stars > 0 ? _submitRating : null,
            style: FilledButton.styleFrom(
              backgroundColor: _kForest,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape:   RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            child: Text(
              _stars == 0 ? 'Tap a star to rate' : 'Submit $_stars ★',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ),
        const SizedBox(height: 6),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text(
            'Maybe later',
            style: TextStyle(color: null, fontSize: 13),
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// _FeedbackSheet — help & feedback bottom sheet with topic chips + message field
// =============================================================================

class _FeedbackSheet extends StatefulWidget {
  const _FeedbackSheet();

  @override
  State<_FeedbackSheet> createState() => _FeedbackSheetState();
}

class _FeedbackSheetState extends State<_FeedbackSheet> {
  final _ctrl  = TextEditingController();
  bool  _submitted  = false;
  bool  _sending    = false;
  String? _selectedTopic;

  // _kForest intentionally kept for backgrounds / decorations (icon chip, snackbar).
  // DO NOT use it for text on surfaces — use cs.onSurface there.
  static const _kForest = Color(0xFF0C351E);

  static const _topics = [
    '🐛 Bug report',
    '💡 Feature idea',
    '❓ General question',
    '🔥 Other',
  ];

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// Same Android applicationId as _RatingDialog — both point at the same
  /// Play Store listing.
  static const _androidPackageId = 'za.co.chowsa.app';
  static const _marketUri  = 'market://details?id=$_androidPackageId';
  static const _webStoreUrl =
      'https://play.google.com/store/apps/details?id=$_androidPackageId';

  Future<void> _openPlayStoreListing() async {
    try {
      final marketUri = Uri.parse(_marketUri);
      if (await canLaunchUrl(marketUri)) {
        if (await launchUrl(marketUri,
            mode: LaunchMode.externalApplication)) {
          return;
        }
      }
      await launchUrl(Uri.parse(_webStoreUrl),
          mode: LaunchMode.externalApplication);
    } catch (_) { /* swallow — feedback was already delivered */ }
  }

  Future<void> _sendFeedback() async {
    final message = _ctrl.text.trim();
    if (message.isEmpty) return;
    setState(() => _sending = true);

    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      // Insert into user_feedback — the Postgres trigger forwards the row
      // to the send-feedback-email Edge Function which mails the support
      // inbox via Resend. RLS guarantees user_id = auth.uid().
      final client = Supabase.instance.client;
      final me     = client.auth.currentUser;
      await client.from('user_feedback').insert({
        'user_id':     me?.id,
        'user_email':  me?.email,
        'user_handle': me?.userMetadata?['handle'] as String?
                       ?? me?.userMetadata?['username'] as String?,
        'category':    _selectedTopic ?? 'unspecified',
        'message':     message,
      });

      if (!mounted) return;
      _ctrl.clear();
      navigator.pop();
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Feedback sent! Thanks for helping us improve ChowSA',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          behavior: SnackBarBehavior.floating,
          backgroundColor: _kForest,
        ),
      );
      // Step B: nudge the user to leave a public Play Store review while
      // they're still in feedback mode. market:// opens the native Play
      // Store app directly; the https web listing is the fallback for
      // devices without it (custom ROMs, etc.).
      await _openPlayStoreListing();
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Could not send feedback — please try again.\n$e',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.redAccent.shade700,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final tt          = Theme.of(context).textTheme;
    // Safe-area bottom — the home-indicator gap on iOS / nav-bar gap on
    // Android. Constant regardless of keyboard state.
    final safeBottom  = MediaQuery.of(context).padding.bottom;
    // Keyboard height when the soft keyboard is open; 0 when closed. This
    // is the value the spec wants threaded into the outer Padding so the
    // entire sheet slides upward to clear the keyboard.
    final keyboardInset = MediaQuery.of(context).viewInsets.bottom;

    // ── Keyboard-aware sheet structure ────────────────────────────────────
    //
    //   Padding (viewInsets.bottom)         ← lifts the sheet above the keyboard
    //   └── Container (decoration + safe-area + horizontal padding)
    //       └── SingleChildScrollView       ← scrolls if the sheet is still
    //           └── Column                    cramped on a short device
    //
    // The previous build read only `padding.bottom` (safe-area), so when the
    // keyboard slid up its 300dp pushed straight over the TextField. Wrapping
    // the Container in a Padding keyed to `viewInsets.bottom` solves it
    // because MediaQuery rebuilds the sheet whenever the inset changes.
    return Padding(
      padding: EdgeInsets.only(bottom: keyboardInset),
      child: Container(
        decoration: BoxDecoration(
          color:        Theme.of(context).colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        ),
        padding: EdgeInsets.fromLTRB(24, 16, 24, safeBottom + 24),
        child: SingleChildScrollView(
          // Bounce physics + drag-to-dismiss on the scrollview itself, so the
          // user can flick the cramped content down to peek at the keyboard
          // without dismissing the sheet (Flutter's default `ClampingScroll
          // Physics` would feel locked on a short device).
          physics: const ClampingScrollPhysics(),
          child: Column(
            mainAxisSize:      MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
            // Drag handle
            Center(
              child: Container(
                width: 40, height: 4,
                decoration: BoxDecoration(
                  color:        const Color(0xFFE6E2D8),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),

            if (_submitted) ...[
              // ── Thank-you state ────────────────────────────────────────────
              Center(
                child: Column(
                  children: [
                    const Icon(Icons.mark_email_read_outlined,
                        color: _kForest, size: 48),
                    const SizedBox(height: 14),
                    Text(
                      'Message sent! 🙏',
                      style: tt.titleMedium?.copyWith(
                        fontWeight: FontWeight.w900, color: _kForest,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Thanks for helping us make ChowSA better for every South African kitchen.',
                      textAlign: TextAlign.center,
                      style:     tt.bodySmall?.copyWith(
                        color: null, height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 24),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: () => Navigator.pop(context),
                        style: FilledButton.styleFrom(
                          backgroundColor: _kForest,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape:   RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                        ),
                        child: const Text('Close',
                            style: TextStyle(fontWeight: FontWeight.w800)),
                      ),
                    ),
                  ],
                ),
              ),
            ] else ...[
              // ── Form state ─────────────────────────────────────────────────
              Row(
                children: [
                  const Icon(Icons.help_outline_rounded, color: _kForest, size: 22),
                  const SizedBox(width: 10),
                  Text(
                    'Help & Feedback',
                    style: tt.titleLarge?.copyWith(
                      fontWeight: FontWeight.w900, color: _kForest,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Got a bug, idea, or question? We read every message.',
                style: tt.bodySmall?.copyWith(color: null),
              ),
              const SizedBox(height: 18),

              // Topic chips — selecting one pre-fills the subject line
              Wrap(
                spacing: 8, runSpacing: 8,
                children: [
                  for (final topic in _topics)
                    GestureDetector(
                      onTap: () {
                        setState(() => _selectedTopic = topic);
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: _selectedTopic == topic
                              ? _kForest
                              : _kForest.withAlpha(12),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: _selectedTopic == topic
                                ? _kForest
                                : _kForest.withAlpha(35),
                          ),
                        ),
                        child: Text(
                          topic,
                          style: TextStyle(
                            color: _selectedTopic == topic
                                ? Colors.white
                                : _kForest,
                            fontSize:   12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),

              // Message field
              TextField(
                controller:      _ctrl,
                minLines:        4,
                maxLines:        8,
                textInputAction: TextInputAction.newline,
                // No explicit `style` — inherits textTheme.bodyMedium which is
                // already set to headingColor in both light and dark variants.
                decoration: InputDecoration(
                  hintText:  'Describe your issue or idea…',
                  // Inherits hintStyle from inputDecorationTheme (bodyColor
                  // at reduced opacity) — no hardcode needed.
                  filled:    true,
                  // Theme fill is adaptive (white in light, cardBg in dark).
                  // Explicitly overriding here would break dark mode.
                  contentPadding: const EdgeInsets.all(16),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide:   BorderSide(
                      color: Theme.of(context).colorScheme.outlineVariant),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide:   BorderSide(
                      color: Theme.of(context).colorScheme.outlineVariant),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide:   BorderSide(
                      color: Theme.of(context).colorScheme.primary, width: 1.5),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Send button — opens native email app
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: (_ctrl.text.trim().isEmpty || _sending)
                      ? null
                      : _sendFeedback,
                  icon: _sending
                      ? const SizedBox(width: 16, height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.send_rounded, size: 18),
                  label: Text(
                    _sending ? 'Opening mail…' : 'Send Feedback',
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: _kForest,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: _kForest.withValues(alpha: 0.55),
                    disabledForegroundColor: Colors.white.withValues(alpha: 0.85),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                  ),
                ),
              ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// _SavedRecipeDetailDialog — full recipe view for a saved community recipe
// =============================================================================

class _SavedRecipeDetailDialog extends StatelessWidget {
  const _SavedRecipeDetailDialog({required this.recipe});

  final SavedCommunityRecipe recipe;

  static const _kForest = Color(0xFF0C351E);
  static const _kOrange = Color(0xFFE59B27);
  static const _kCream  = Color(0xFFF4F1EA);

  static const Map<String, Map<String, dynamic>> _mockRecipes = {
    '1': {
      'prepTime': '10 min', 'cookTime': '15 min', 'servings': '4',
      'ingredients': [
        '8 slices thick white bread',
        '200g mature cheddar, grated',
        '2 large tomatoes, sliced',
        '1 white onion, thinly sliced',
        '4 tbsp butter, softened',
        'Salt & pepper to taste',
        "Optional: Mrs Ball's Chutney",
      ],
      'steps': [
        'Butter both sides of each bread slice generously.',
        'Layer cheese, tomato and onion on 4 slices. Season well.',
        'Top with remaining slices, buttered side out.',
        'Place on medium coals or a flat gas pan. Press down.',
        'Cook 3–4 min per side until golden and cheese is melted.',
        "Serve immediately — great with Mrs Ball's Chutney.",
      ],
    },
    '2': {
      'prepTime': '30 min', 'cookTime': '5–6 hours', 'servings': '6',
      'ingredients': [
        '1.5 kg lamb shoulder, chunked',
        '4 medium potatoes, quartered',
        '3 carrots, sliced',
        '2 onions, chopped',
        '400g chopped tomatoes (tin)',
        '250ml dry red wine',
        '2 tbsp olive oil',
        '2 cloves garlic, minced',
        '1 tsp dried thyme',
        '1 tsp paprika',
        'Salt & pepper to taste',
        'Fresh parsley to serve',
      ],
      'steps': [
        'Heat oil in the potjie (size 3). Brown lamb in batches. Set aside.',
        'Fry onions and garlic until golden.',
        'Return lamb. Add wine, reduce 2 min.',
        'Add tomatoes, thyme, paprika, salt & pepper.',
        'Layer carrots then potatoes on top. Do NOT stir.',
        'Cover. Cook on low coals 4–5 hours — check every 45 min.',
        'Potjie is ready when lamb falls off the bone. Serve with rice.',
      ],
    },
    '3': {
      'prepTime': '15 min (+overnight soak)', 'cookTime': '45 min', 'servings': '6–8',
      'ingredients': [
        '500g dried samp',
        '400g canned black-eyed beans, drained',
        '1 onion, finely chopped',
        '2 tbsp sunflower oil',
        '1 tsp curry powder',
        '400g canned chopped tomatoes',
        '1 red + 1 green pepper, diced',
        '2 jalapeños, chopped',
        'Salt to taste',
      ],
      'steps': [
        'Soak samp overnight. Drain and rinse.',
        'Boil samp in fresh water 45–60 min until tender.',
        'Fry onion in oil. Add curry powder, fry 1 min.',
        'Add peppers, jalapeños and tomatoes. Simmer 15 min.',
        'Drain samp. Add beans and chakalaka mixture.',
        'Stir over low heat 5 min. Season with salt and serve.',
      ],
    },
  };

  Map<String, dynamic> get _data => _mockRecipes[recipe.id] ?? {
    'prepTime': 'See community post', 'cookTime': 'See community post', 'servings': '–',
    'ingredients': [
      'Full recipe details are with the original poster.',
      'Find the post by ${recipe.username} in the Community tab to see the full ingredient list.',
    ],
    'steps': [
      'Open the Community tab and search for "${recipe.recipeTitle}" to find the original post.',
      'You can ask ${recipe.username} for the full recipe in the comments.',
      'Tip: next time you save a recipe, more details will be available as this feature improves!',
    ],
  };

  @override
  Widget build(BuildContext context) {
    final tt        = Theme.of(context).textTheme;
    final data      = _data;
    final savedOn   = '${recipe.savedAt.day}/${recipe.savedAt.month}/${recipe.savedAt.year}';
    final ingList   = List<String>.from(data['ingredients'] as List);
    final stepsList = List<String>.from(data['steps'] as List);

    return Dialog(
      backgroundColor: _kCream,
      shape:           RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      insetPadding:    const EdgeInsets.symmetric(horizontal: 16, vertical: 28),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.85,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ── Green header ────────────────────────────────────────────
              Container(
                width:   double.infinity,
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
                color:   _kForest,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            recipe.recipeTitle,
                            style: tt.titleLarge?.copyWith(
                              color:      Colors.white,
                              fontWeight: FontWeight.w900,
                              height:     1.2,
                            ),
                          ),
                        ),
                        GestureDetector(
                          onTap: () => Navigator.pop(context),
                          child: Container(
                            padding:    const EdgeInsets.all(5),
                            decoration: BoxDecoration(
                              color:        Colors.white.withAlpha(30),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Icon(Icons.close_rounded,
                                color: Colors.white, size: 17),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'by ${recipe.username}  •  Saved $savedOn',
                      style: TextStyle(
                        color:    Colors.white.withAlpha(180),
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        _InfoChip(label: 'Prep: ${data['prepTime']}'),
                        _InfoChip(label: 'Cook: ${data['cookTime']}'),
                        _InfoChip(label: '${data['servings']} servings'),
                      ],
                    ),
                    if (recipe.tags.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 5,
                        children: recipe.tags.take(3).map((t) => Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color:        Colors.white.withAlpha(20),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(t,
                            style: const TextStyle(
                              color:      Colors.white,
                              fontSize:   10,
                              fontWeight: FontWeight.w600,
                            )),
                        )).toList(),
                      ),
                    ],
                  ],
                ),
              ),

              // ── Scrollable recipe ───────────────────────────────────────
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Ingredients
                      _RecipeSectionHeader(
                        icon: Icons.format_list_bulleted_rounded,
                        label: 'Ingredients',
                        count: ingList.length,
                      ),
                      const SizedBox(height: 8),
                      Container(
                        padding:    const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color:        Colors.white,
                          borderRadius: BorderRadius.circular(14),
                          border:       Border.all(color: const Color(0xFFE6E2D8)),
                        ),
                        child: Column(
                          children: ingList.map((ing) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  width: 6, height: 6,
                                  margin: const EdgeInsets.only(top: 6, right: 10),
                                  decoration: const BoxDecoration(
                                    color: _kOrange, shape: BoxShape.circle,
                                  ),
                                ),
                                Expanded(
                                  child: Text(ing,
                                    style: const TextStyle(
                                      fontSize: 13, height: 1.4,
                                    )),
                                ),
                              ],
                            ),
                          )).toList(),
                        ),
                      ),

                      const SizedBox(height: 18),

                      // Steps
                      _RecipeSectionHeader(
                        icon: Icons.format_list_numbered_rounded,
                        label: 'Method',
                        count: stepsList.length,
                      ),
                      const SizedBox(height: 8),
                      Container(
                        padding:    const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color:        Colors.white,
                          borderRadius: BorderRadius.circular(14),
                          border:       Border.all(color: const Color(0xFFE6E2D8)),
                        ),
                        child: Column(
                          children: stepsList.asMap().entries.map((e) => Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  width: 22, height: 22,
                                  margin: const EdgeInsets.only(right: 10, top: 1),
                                  decoration: const BoxDecoration(
                                    color: _kForest, shape: BoxShape.circle,
                                  ),
                                  alignment: Alignment.center,
                                  child: Text('${e.key + 1}',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w800,
                                    )),
                                ),
                                Expanded(
                                  child: Text(e.value,
                                    style: const TextStyle(
                                      fontSize: 13, height: 1.5,
                                    )),
                                ),
                              ],
                            ),
                          )).toList(),
                        ),
                      ),
                      const SizedBox(height: 4),
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

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.label});
  final String label;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color:        Colors.white.withAlpha(22),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(label,
      style: const TextStyle(
        color: Colors.white, fontSize: 10, fontWeight: FontWeight.w600,
      )),
  );
}

class _RecipeSectionHeader extends StatelessWidget {
  const _RecipeSectionHeader({
    required this.icon,
    required this.label,
    required this.count,
  });
  final IconData icon;
  final String   label;
  final int      count;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 15, color: const Color(0xFF0C351E)),
      const SizedBox(width: 6),
      Text(label,
        style: const TextStyle(
          fontWeight: FontWeight.w900,
          fontSize:   14,
          color:      Color(0xFF0C351E),
        )),
      const SizedBox(width: 6),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color:        const Color(0xFF0C351E).withAlpha(15),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text('$count',
          style: const TextStyle(
            fontSize: 10, fontWeight: FontWeight.w700,
            color: Color(0xFF0C351E),
          )),
      ),
    ],
  );
}

// =============================================================================
// _EditProfileSheet — edit display name and handle
// =============================================================================

class _EditProfileSheet extends StatefulWidget {
  const _EditProfileSheet({required this.profile});

  final UserProfile profile;

  @override
  State<_EditProfileSheet> createState() => _EditProfileSheetState();
}

class _EditProfileSheetState extends State<_EditProfileSheet> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _handleCtrl;
  bool _saving = false;

  // _kForest kept for icon chip backgrounds only.
  // Text on surfaces must use cs.onSurface / cs.primary to stay readable in dark mode.
  static const _kForest = Color(0xFF0C351E);

  @override
  void initState() {
    super.initState();
    _nameCtrl   = TextEditingController(text: widget.profile.handle);
    _handleCtrl = TextEditingController(text: widget.profile.handle);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _handleCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final newHandle = _handleCtrl.text.trim();
    final newName   = _nameCtrl.text.trim();
    if (newHandle.isEmpty) return;
    setState(() => _saving = true);

    // ── Cascading update strategy ──────────────────────────────────────────
    // ChowSA uses Method A (Dynamic Joins) — `channel_messages` stores only
    // `user_id`, and the chat bubble resolves the displayed handle at
    // render time via the `get_public_profile` SECURITY DEFINER RPC. So a
    // single UPDATE to `profiles` propagates the new name to every
    // historical post across every community category without any batch
    // script, trigger, or manual back-fill.
    //
    // We write BOTH `handle` AND `username` because the bubble's resolver
    // and `find_user_by_handle` both fall through `handle ?? username`.
    // Keeping the two in lock-step means lookups by either column hit the
    // fresh value.
    final db  = Supabase.instance.client;
    final uid = db.auth.currentUser?.id;
    final hubState =
        context.findAncestorStateOfType<_MainNavigationHubState>();
    try {
      if (uid != null) {
        // Only overwrite display_name when the user actually typed one —
        // the profiles_display_name_key UNIQUE index would otherwise
        // bounce two users who share the same handle.
        final payload = <String, dynamic>{
          'id':         uid,
          'handle':     newHandle,
          'username':   newHandle,
          'updated_at': DateTime.now().toIso8601String(),
        };
        if (newName.isNotEmpty) payload['display_name'] = newName;
        await db.from('profiles').upsert(payload);
        // Mirror the new handle into auth.users.raw_user_meta_data so the
        // bubble's "me" fast-path (which reads from currentUser.userMetadata)
        // resolves immediately for the signed-in author too.
        try {
          await db.auth.updateUser(UserAttributes(
            data: {
              'handle':   newHandle,
              'username': newHandle,
            },
          ));
        } catch (_) {/* metadata sync is best-effort */}
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      // Translate the unique-index violations the user is likely to hit
      // (taken username / display name) into a friendlier message.
      final raw  = e.toString().toLowerCase();
      final msg  = raw.contains('unique_lower_username') ||
                   raw.contains('duplicate key') &&
                       raw.contains('username')
          ? "That username is already taken. Try another one, chom!"
          : raw.contains('profiles_display_name_key')
              ? 'That display name is already in use — pick another.'
              : "Couldn't save profile: $e";
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg),
          backgroundColor: const Color(0xFFC62828),
          behavior:        SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
      return;
    }

    // ── Local UI bubble-up ─────────────────────────────────────────────────
    // The Profile header (and any other surface that reads `_profile`)
    // must reflect the new name before the next paint — no manual
    // pull-to-refresh, no app restart. We poke the hub state directly.
    if (hubState != null && hubState.mounted) {
      final oldProfile = hubState._profile;
      if (oldProfile != null) {
        hubState.setState(() {
          hubState._profile = UserProfile(
            id:     oldProfile.id,
            email:  oldProfile.email,
            handle: newHandle,
          );
        });
      }
    }

    if (!mounted) return;
    setState(() => _saving = false);
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text(
          'Profile updated! Your new name now shows on every community post.',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        backgroundColor: _kForest,
        behavior:        SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tt     = Theme.of(context).textTheme;
    final bottom = MediaQuery.of(context).viewInsets.bottom +
        MediaQuery.of(context).padding.bottom;

    final cs = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        // Use theme surface so the sheet adapts: cream in light, dark card in dark.
        color:        cs.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: EdgeInsets.fromLTRB(24, 24, 24, bottom + 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40, height: 4,
              margin:     const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color:        cs.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),

          Row(
            children: [
              Container(
                width: 40, height: 40,
                decoration: BoxDecoration(
                  color:        cs.primary,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.manage_accounts_outlined,
                    color: cs.onPrimary, size: 20),
              ),
              const SizedBox(width: 12),
              Text(
                'Edit Profile',
                style: tt.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  color:      cs.onSurface,
                ),
              ),
            ],
          ),

          const SizedBox(height: 24),

          Text('Display Name',
              style: tt.labelMedium?.copyWith(
                fontWeight: FontWeight.w700,
                // cs.primary stays readable in both light and dark variants.
                color: cs.primary,
              )),
          const SizedBox(height: 8),
          TextField(
            controller: _nameCtrl,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
              hintText: 'Your display name',
              // No fillColor / border overrides — inherit from
              // inputDecorationTheme which is already adaptive.
            ),
          ),

          const SizedBox(height: 16),

          Text('Username',
              style: tt.labelMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: cs.primary,
              )),
          const SizedBox(height: 8),
          TextField(
            controller: _handleCtrl,
            decoration: const InputDecoration(
              hintText: 'handle',
              // Inherits adaptive theme fill, borders, text colour.
            ),
          ),

          const SizedBox(height: 24),

          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _saving ? null : _save,
              style: FilledButton.styleFrom(
                backgroundColor: _kForest,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape:   RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
              ),
              child: _saving
                  ? const SizedBox(
                      width:  20,
                      height: 20,
                      child:  CircularProgressIndicator(
                          strokeWidth: 2.5, color: Colors.white),
                    )
                  : const Text(
                      'Save Changes',
                      style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
