// lib/views/community_hub_screen.dart
//
// Hyper-local Suburb Hub Dashboard. Hosts:
//
//   • A prominent localized header ("Parklands Hub" / "Table View Hub") read
//     from the user's profile.suburb_district.
//   • Four Status Row Cards (Spotted / Gatherings / Pantry / What's Cooking)
//     wired to the realtime stream of `community_channels` so the tile copy
//     reflects whichever channel rows actually exist server-side.
//   • Tap → ChannelChatScreen for that category.

import 'dart:async';

import 'package:flutter/material.dart';
import '../models/hub_model.dart';
import '../services/community_hub_service.dart';
import '../services/local_hub_service.dart';
import '../state/community_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/motion.dart';
import '../widgets/animated_emoji.dart';
import 'channel_chat_screen.dart';
import 'local_braai_hub_view.dart';

class CommunityHubScreen extends StatefulWidget {
  const CommunityHubScreen({super.key});

  @override
  State<CommunityHubScreen> createState() => _CommunityHubScreenState();
}

class _CommunityHubScreenState extends State<CommunityHubScreen> {
  String? _suburb;
  bool    _isAdmin = false;

  // Per-category unread badges + the per-suburb channels stream now live
  // on CommunityController. This widget just ValueListenableBuilder's
  // off `CommunityController.instance.state` — no private map, no
  // private RealtimeChannel, no lifecycle observer.

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  // Maximum time _bootstrap() is allowed to wait for profile + admin
  // network calls before falling back to safe defaults. Prevents the
  // full-screen CircularProgressIndicator from spinning indefinitely when
  // Supabase is slow or the device has intermittent connectivity.
  static const _kBootstrapTimeout = Duration(seconds: 10);

  Future<void> _bootstrap() async {
    // Run both lookups in parallel — isCurrentUserAdmin() makes up to two
    // sequential RPC calls, so serial execution doubles worst-case latency.
    // Cap the whole parallel batch at _kBootstrapTimeout so a hanging
    // network request doesn't lock the Community tab on a spinner forever.
    try {
      final results = await Future.wait([
        CommunityHubService.instance.isCurrentUserAdmin(),
        CommunityHubService.instance.resolveActiveSuburb(),
      ]).timeout(
        _kBootstrapTimeout,
        onTimeout: () {
          // Couldn't complete within the window — use safe defaults so the
          // hub dashboard renders immediately with the fallback suburb.
          debugPrint(
            'CommunityHubScreen: bootstrap timed out after '
            '${_kBootstrapTimeout.inSeconds}s — using defaults.',
          );
          return [false, 'Table View'];
        },
      );

      if (!mounted) return;
      setState(() {
        _isAdmin = results[0] as bool;
        _suburb  = results[1] as String;
      });
    } catch (e) {
      // Any unexpected error — still clear the spinner with safe defaults.
      debugPrint('CommunityHubScreen: bootstrap error: $e');
      if (!mounted) return;
      setState(() {
        _isAdmin = false;
        _suburb  = 'Table View';
      });
    }

    // Kick a fresh GPS resolve in the background. The ValueNotifier listener
    // in build() picks up the updated hub name automatically.
    unawaited(LocalHubService.instance.refreshFromGps());

    // Tell the CommunityController to (re-)resolve the suburb. It owns
    // the channel_messages realtime channel and the per-category unread
    // refresh cycle for the whole app.
    unawaited(CommunityController.instance.refreshSuburb());
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (_suburb == null) {
      return Scaffold(
        backgroundColor: cs.surface,
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return ValueListenableBuilder<HubModel?>(
      valueListenable: LocalHubService.instance.currentHub,
      builder: (context, gpsHub, _) {
        // Prefer the live GPS hub when present, fall back to the
        // suburb-string resolved from the user profile.
        final suburb = gpsHub?.name ?? _suburb!;
        return _buildScaffold(context, suburb, gpsHub);
      },
    );
  }

  // ── Navigation ──────────────────────────────────────────────────────────
  //
  // Every category card navigates unconditionally — no "coming soon" gate,
  // no suburb-matching check, no silent lockout. If the user's suburb has a
  // seeded channel for the tapped category we use it; otherwise we fall back
  // to ANY channel of that category via `findAnyChannelForCategory` so the
  // user always lands in a real chat / board screen.

  /// Tap handler for a category card. Resolves a channel to navigate to —
  /// preferring the in-suburb match, falling back to any channel of the
  /// category — then pushes ChannelChatScreen. The synchronous-feeling tap
  /// is intentional: the suburb match is already in memory from the stream,
  /// so the slow path (cross-suburb DB fetch) only fires when there's no
  /// local match.
  Future<void> _openCategory(
      ChannelCategory   cat,
      CommunityChannel? inSuburbChannel, {
      required String   userSuburb,
  }) async {
    // Resolution order (was the source of the "posts vanish" bug for
    // What's Cooking + Braai):
    //
    //   1. The category row from the per-suburb stream snapshot, IF the
    //      stream has already emitted at least once.
    //   2. Otherwise an explicit one-shot lookup on (userSuburb, category)
    //      — guarantees we hit the caller's own room even on a cold open
    //      before the stream is hot.
    //   3. Only if neither succeeds do we fall back across suburbs. The
    //      fallback now skips the GLOBAL bucket so cooking taps never
    //      land in the World Cup Stadium chat by accident.
    var channel = inSuburbChannel;
    channel ??= await CommunityHubService.instance
        .findChannelForSuburbAndCategory(userSuburb, cat);
    channel ??=
        await CommunityHubService.instance.findAnyChannelForCategory(cat);
    if (!mounted || channel == null) return;
    // displaySuburbOverride keeps the chat header in the user's local
    // context even when the resolver fell back to a cross-suburb channel
    // (e.g. tapping What's Cooking in Table View when only the GLOBAL
    // cooking room exists should still show "#TableView-WhatsCooking").
    final showOverride =
        channel.suburb != userSuburb ? userSuburb : null;

    // Capture the entry moment — used only as a diagnostic anchor; the
    // actual `last_viewed_at` write happens on EXIT below so any posts
    // that arrive WHILE the user is reading the category are also
    // counted as "seen" (timestamp = now() at the moment they leave).
    final enteredAt = DateTime.now();
    debugPrint(
      '[community-hub] entered ${cat.wire} at ${enteredAt.toIso8601String()}',
    );

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChannelChatScreen(
          channelId:             channel!.id,
          isAdmin:               _isAdmin,
          displaySuburbOverride: showOverride,
        ),
      ),
    );
    if (!mounted) return;

    // CommunityController drops the badge to 0 instantly + fires the
    // mark_category_viewed RPC + re-pulls sibling counts. Every other
    // ValueListenableBuilder on the controller rebuilds in the same
    // frame — no per-screen setState needed.
    unawaited(CommunityController.instance.markCategoryViewed(cat));
  }

  // ── Layout ───────────────────────────────────────────────────────────────

  // NOTE: parameter is named `scaffoldCtx` (not `context`) to prevent
  // accidental shadowing of `this.context` — _openCategory must use the
  // State's BuildContext, not the builder's, so Navigator resolves
  // correctly.
  Widget _buildScaffold(BuildContext scaffoldCtx, String suburb, HubModel? gpsHub) {
    final cs = Theme.of(scaffoldCtx).colorScheme;
    final tt = Theme.of(scaffoldCtx).textTheme;

    return Scaffold(
      backgroundColor: cs.surface,
      body: SafeArea(
        child: ValueListenableBuilder<CommunityState>(
          valueListenable: CommunityController.instance.state,
          builder: (streamCtx, communityState, _) {
            // Controller is suburb-aware; if it hasn't resolved yet, fall
            // back to a one-shot fetch via the existing service so the
            // first paint isn't empty.
            final channels = communityState.channels;
            final byCat    = {for (final c in channels) c.category: c};

            return CustomScrollView(
              slivers: [
                // ── Header ─────────────────────────────────────────────
                SliverToBoxAdapter(
                  child: _HubHeader(
                    suburb:   suburb,
                    province: gpsHub?.province,
                    isAdmin:  _isAdmin,
                  ),
                ),

                // ── Section title ──────────────────────────────────────
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 22, 20, 10),
                    child: Text(
                      'Live in your area',
                      style: tt.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                        color:      cs.onSurface,
                      ),
                    ),
                  ),
                ),

                // ── Four status row cards ──────────────────────────────
                // onTap is ALWAYS non-null so the GestureDetector inside
                // PressableScale never swallows a tap silently:
                //   • channel found  → navigate to ChannelChatScreen
                //   • channel absent → friendly "coming soon" snackbar
                // This also means cards remain tappable while the stream
                // is still loading (snap.data == null) or when the GPS
                // suburb isn't in the seeded pilot set yet.
                SliverList.separated(
                  // Braai is rendered as its own dedicated tile below, so
                  // keep it out of the four canonical category cards even
                  // though the enum now includes it.
                  itemCount: ChannelCategory.values
                      .where((c) => c != ChannelCategory.braai)
                      .length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (_, i) {
                    final cat = ChannelCategory.values
                        .where((c) => c != ChannelCategory.braai)
                        .toList()[i];
                    final channel = byCat[cat];
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      // Gate fully removed. Every card is always saturated,
                      // always tappable, and every tap navigates straight
                      // into the chat / board for that category — no
                      // "coming soon" snackbar, no suburb-matching check.
                      // When the user's suburb has no seeded row for the
                      // category, _openCategory falls back to ANY channel
                      // of that category so the navigation still lands in
                      // a real room.
                      child: _StatusRowCard(
                        category:    cat,
                        channel:     channel,
                        isAvailable: true,
                        unreadCount: communityState.unreadFor(cat),
                        onTap:       () => _openCategory(
                          cat,
                          channel,
                          userSuburb: suburb,
                        ),
                      ),
                    );
                  },
                ),

                // ── Braai Recipes tile (appended to the list) ──────────
                // Sits below the four canonical channel cards. Routes to
                // the dedicated LocalBraaiHubView, NOT the My Recipes
                // screen — same destination as the home loadshedding
                // card's "Browse Braai Recipes" CTA.
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                    child: _BraaiRecipesTile(
                      unreadCount: communityState.unreadFor(ChannelCategory.braai),
                      onTap: () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const LocalBraaiHubView(),
                          ),
                        );
                        if (!mounted) return;
                        unawaited(CommunityController.instance
                            .markCategoryViewed(ChannelCategory.braai));
                      },
                    ),
                  ),
                ),

                SliverToBoxAdapter(child: SizedBox(
                  // Footer breathing room scaled to device height so the last
                  // card never collides with the bottom-nav indicator.
                  height: MediaQuery.of(scaffoldCtx).size.height * 0.08,
                )),
              ],
            );
          },
        ),
      ),
    );
  }
}

// =============================================================================
//   _HubHeader — Deep Forest Green hero, localized to active suburb
// =============================================================================

class _HubHeader extends StatelessWidget {
  const _HubHeader({
    required this.suburb,
    required this.isAdmin,
    this.province,
  });

  final String  suburb;
  final String? province;
  final bool    isAdmin;

  /// Returns the raw suburb name with any trailing " Hub" stripped — the
  /// word "Hub" is no longer rendered in the community section header.
  static String _headerTitle(String raw) {
    return raw
        .replaceAll(RegExp(r'\s+Hub\s*$', caseSensitive: false), '')
        .trim();
  }

  @override
  Widget build(BuildContext context) {
    final tt   = Theme.of(context).textTheme;
    final top  = MediaQuery.of(context).padding.top;

    return Container(
      width:   double.infinity,
      padding: EdgeInsets.only(
        top:    top + 24,
        bottom: 28,
        left:   24,
        right:  24,
      ),
      decoration: const BoxDecoration(
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
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Containerized illustrative location glyph.
          Container(
            width:  56,
            height: 56,
            decoration: BoxDecoration(
              color:        AppTheme.kAlabaster,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.35),
                width: 1,
              ),
            ),
            alignment: Alignment.center,
            child: const Text('📍', style: TextStyle(fontSize: 28)),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'YOUR LOCAL HUB',
                  style: tt.labelSmall?.copyWith(
                    color:         Colors.white.withValues(alpha: 0.7),
                    letterSpacing: 1.6,
                    fontWeight:    FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  // The upstream suburb string sometimes already contains a
                  // trailing " Hub" (when GPS resolves to a HubModel whose
                  // name embeds the suffix, or when a cached value has it
                  // baked in). Strip it before appending our own so we never
                  // render "Table View (Western Cape) Hub Hub".
                  _headerTitle(suburb),
                  style: tt.headlineMedium?.copyWith(
                    color:      Colors.white,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.4,
                  ),
                ),
                if (province != null && province!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    province!,
                    style: tt.labelMedium?.copyWith(
                      color:      Colors.white.withValues(alpha: 0.75),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                if (isAdmin) ...[
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppTheme.kProteaGold,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Text(
                      'ADMIN',
                      style: TextStyle(
                        color:         AppTheme.kMidnight,
                        fontSize:      10,
                        fontWeight:    FontWeight.w900,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          // ── Trailing standout — animated community/people glyph with a
          // soft glowing halo so it pops against the deep-forest gradient.
          // Sits in the right-hand void the spec called out.
          const SizedBox(width: 8),
          const AnimatedEmoji(
            emoji:     '🤝',
            anim:      EmojiAnim.pulse,
            size:      40,
            haloColor: Color(0xFFE59B27),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
//   _StatusRowCard — Deep Forest Green left rail + Soft Cream body
// =============================================================================

class _StatusRowCard extends StatelessWidget {
  const _StatusRowCard({
    required this.category,
    required this.channel,
    required this.onTap,
    this.unreadCount = 0,
    @Deprecated('Card is always active; param retained for call-site compat.')
    this.isAvailable = true,
  });

  final ChannelCategory   category;
  final CommunityChannel? channel;
  final VoidCallback      onTap;
  /// Number of posts in this category created since the user last
  /// opened it. Renders as an orange pill next to the chevron when > 0.
  final int               unreadCount;

  /// Retained for backward compatibility with any older call sites but
  /// ignored — the card is always rendered in its saturated, active state.
  /// All SOON-chip / opacity-dimming branches have been removed.
  final bool              isAvailable;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return PressableScale(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: AppTheme.kAlabaster,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: cs.outlineVariant.withValues(alpha: 0.6),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Deep Forest Green rail with the category emoji ──────────
              Container(
                width: 76,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin:  Alignment.topCenter,
                    end:    Alignment.bottomCenter,
                    colors: [Color(0xFF0F3E2B), Color(0xFF205B4A)],
                  ),
                ),
                alignment: Alignment.center,
                child: AnimatedEmoji(
                  emoji: category.emoji,
                  anim:  animForCommunityEmoji(category.emoji),
                  size:  36,
                ),
              ),

              // ── Cream body ─────────────────────────────────────────────
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment:  MainAxisAlignment.center,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              category.displayName,
                              style: tt.titleMedium?.copyWith(
                                fontWeight:    FontWeight.w800,
                                color:         AppTheme.kMidnight,
                                letterSpacing: -0.1,
                              ),
                            ),
                          ),
                          if (channel?.pinnedMessageId != null)
                            const Padding(
                              padding: EdgeInsets.only(right: 4),
                              child: Text('📌',
                                  style: TextStyle(fontSize: 14)),
                            ),
                          // Animated unread badge. Two coordinated bits:
                          //   • AnimatedScale collapses the entire pill to
                          //     scale 0 when count == 0 — implicit, bouncy,
                          //     and ignored by hit-testing once gone so the
                          //     layout stays clean.
                          //   • AnimatedSwitcher cross-fades + scales the
                          //     digits when the number changes (e.g. 13 →
                          //     0 or 4 → 5), giving the counter that "fun
                          //     pop" feel without us managing a controller.
                          AnimatedScale(
                            duration: const Duration(milliseconds: 320),
                            curve:    Curves.elasticOut,
                            scale:    unreadCount > 0 ? 1.0 : 0.0,
                            child: Container(
                              margin: const EdgeInsets.only(right: 4),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                color:        const Color(0xFFE59B27),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: AnimatedSwitcher(
                                duration: const Duration(milliseconds: 220),
                                transitionBuilder: (child, anim) =>
                                    ScaleTransition(
                                      scale: anim,
                                      child: FadeTransition(
                                        opacity: anim, child: child),
                                    ),
                                child: Text(
                                  unreadCount > 99 ? '99+' : '$unreadCount',
                                  key: ValueKey<int>(unreadCount),
                                  style: const TextStyle(
                                    color:      Colors.white,
                                    fontSize:   11,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Icon(
                            Icons.chevron_right_rounded,
                            color: cs.onSurfaceVariant,
                            size:  22,
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        category.tagline,
                        style: tt.bodySmall?.copyWith(
                          color:  AppTheme.kEarthGrey,
                          height: 1.35,
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
//   _BraaiRecipesTile — appended row for the "Braai Recipes" Local Hub entry
// =============================================================================
//
// Same visual language as _StatusRowCard (Deep Forest Green rail on the left,
// cream body with chevron) so it reads as a sibling of the four canonical
// channel cards rather than a stranded button.

class _BraaiRecipesTile extends StatelessWidget {
  const _BraaiRecipesTile({required this.onTap, this.unreadCount = 0});

  final VoidCallback onTap;
  final int          unreadCount;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return PressableScale(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: AppTheme.kAlabaster,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: cs.outlineVariant.withValues(alpha: 0.6),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 76,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin:  Alignment.topCenter,
                    end:    Alignment.bottomCenter,
                    colors: [Color(0xFF0F3E2B), Color(0xFF205B4A)],
                  ),
                ),
                alignment: Alignment.center,
                child: const AnimatedEmoji(
                  emoji: '🔥',
                  anim:  EmojiAnim.flicker,
                  size:  36,
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment:  MainAxisAlignment.center,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Braai Recipes',
                              style: tt.titleMedium?.copyWith(
                                fontWeight:    FontWeight.w800,
                                color:         AppTheme.kMidnight,
                                letterSpacing: -0.1,
                              ),
                            ),
                          ),
                          // Same animated badge structure as the
                          // _StatusRowCard tiles — collapses to scale 0
                          // when count == 0 so the layout stays clean.
                          AnimatedScale(
                            duration: const Duration(milliseconds: 320),
                            curve:    Curves.elasticOut,
                            scale:    unreadCount > 0 ? 1.0 : 0.0,
                            child: Container(
                              margin: const EdgeInsets.only(right: 4),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                color:        const Color(0xFFE59B27),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: AnimatedSwitcher(
                                duration: const Duration(milliseconds: 220),
                                transitionBuilder: (child, anim) =>
                                    ScaleTransition(
                                      scale: anim,
                                      child: FadeTransition(
                                          opacity: anim, child: child),
                                    ),
                                child: Text(
                                  unreadCount > 99 ? '99+' : '$unreadCount',
                                  key: ValueKey<int>(unreadCount),
                                  style: const TextStyle(
                                    color:      Colors.white,
                                    fontSize:   11,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Icon(
                            Icons.chevron_right_rounded,
                            color: cs.onSurfaceVariant,
                            size:  22,
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Coals, sosaties & boerie-roll inspo',
                        style: tt.bodySmall?.copyWith(
                          color:  AppTheme.kEarthGrey,
                          height: 1.35,
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
