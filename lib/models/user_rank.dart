// lib/models/user_rank.dart
//
// User Creator Rankings — cross-cultural SA tier progression driven by the
// `shared_recipes` count (shares published to the What's Cooking feed).
//
// Tiers (by share count):
//   • Tier 1  Entry    (0  – 10)
//   • Tier 2  Mid      (11 – 21)
//   • Tier 3  Advanced (22 – 44)
//   • Tier 4  Top      (45+)
//
// Each tier carries a 5-title pool; the owner picks their preferred public
// title on their profile (persisted via RankTitleStore). Other surfaces
// (feed badges) show the pool default for the user's tier.
//
// Permanent creator overrides bypass the ladder entirely:
//   • "SumaraiJack" → "Cyber Chef"     + Creator badge
//   • "Melrose"     → "Southern Chef"  + Creator badge
//
// Progress numbers ("3 shares until …") are PRIVATE — owner profile only.

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// ─────────────────────────────────────────────────────────────────────────
// Tier definitions
// ─────────────────────────────────────────────────────────────────────────

/// 5-title pools per tier. Index 0 is the pool default (shown on public
/// surfaces and when the owner hasn't picked a title yet).
const Map<int, List<String>> kTierTitlePools = {
  1: [
    'Apprentice / Laatie',
    'Umkhwetha',
    'Kombuis Nuweling',
    'Chopping Board Assistant',
    'Aardappel Krapper',
  ],
  2: [
    'Soweto Street Foodie',
    'Huiskok',
    'Duidelike Cook',
    'Chief Taster',
    'Pantry Boss',
  ],
  3: [
    'Karoo Tannie',
    'Sisi Womphreki',
    'Cape Malay Kitchen Queen / King',
    'Master of the Coals',
    'Potjie Professor',
  ],
  4: [
    'Braai Master 🔥',
    'Umphathi We-Batyu',
    'Groot Kok',
    'Legend of the Lekker',
    'The Ultimate Chow Architect',
  ],
};

/// Lower bound (inclusive) of each tier, used for threshold math.
const Map<int, int> _kTierFloor = {1: 0, 2: 11, 3: 22, 4: 45};

/// Resolve the tier number (1-4) for a raw share count.
int tierForShares(int shares) {
  if (shares >= 45) return 4;
  if (shares >= 22) return 3;
  if (shares >= 11) return 2;
  return 1;
}

/// Short label for a tier number — used in progress copy ("… until Tier 2").
String tierName(int tier) => switch (tier) {
      4 => 'Top Tier',
      3 => 'Advanced',
      2 => 'Mid Tier',
      _ => 'Entry',
    };

// ─────────────────────────────────────────────────────────────────────────
// UserRank
// ─────────────────────────────────────────────────────────────────────────

class UserRank {
  const UserRank({
    required this.tier,
    required this.title,
    required this.isExclusive,
    this.isCreator = false,
    this.sharesToNext,
    this.nextTierTitle,
  });

  /// 1-4 for the standard ladder; 0 for exclusive creator overrides.
  final int    tier;

  /// Public-facing display title.
  final String title;

  /// True for SumaraiJack / Melrose permanent overrides.
  final bool   isExclusive;

  /// True for accounts that carry the permanent Creator badge. (Same two
  /// accounts as [isExclusive] today, kept as its own flag so the badge
  /// logic stays explicit.)
  final bool   isCreator;

  /// Shares still needed to reach the next tier. Null at Tier 4 / exclusive.
  final int?   sharesToNext;

  /// Pool-default title of the next tier — names the goal in progress copy.
  final String? nextTierTitle;

  /// Resolve a rank.
  ///
  /// [handle]      — public username (case-insensitive creator match).
  /// [shareCount]  — `shared_recipes` rows authored by this user.
  /// [chosenTitle] — the owner's persisted title pick. Honoured only when it
  ///                 belongs to the current tier's pool; otherwise the pool
  ///                 default is used (so a stale pick from a lower tier never
  ///                 leaks through after promotion).
  static UserRank forUser({
    String? handle,
    required int shareCount,
    String? chosenTitle,
  }) {
    final lower = (handle ?? '').trim().toLowerCase();

    if (lower == 'sumaraijack') {
      return const UserRank(
        title: 'Cyber Chef', tier: 0, isExclusive: true, isCreator: true,
      );
    }
    if (lower == 'melrose') {
      return const UserRank(
        title: 'Southern Chef', tier: 0, isExclusive: true, isCreator: true,
      );
    }

    final tier = tierForShares(shareCount);
    final pool = kTierTitlePools[tier]!;
    final title = (chosenTitle != null && pool.contains(chosenTitle))
        ? chosenTitle
        : pool.first;

    int?    sharesToNext;
    String? nextTierTitle;
    if (tier < 4) {
      final nextFloor = _kTierFloor[tier + 1]!;
      sharesToNext  = (nextFloor - shareCount).clamp(0, nextFloor);
      nextTierTitle = kTierTitlePools[tier + 1]!.first;
    }

    return UserRank(
      tier:          tier,
      title:         title,
      isExclusive:   false,
      sharesToNext:  sharesToNext,
      nextTierTitle: nextTierTitle,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Tier visual style — colour + icon per tier (and the creator override).
// ─────────────────────────────────────────────────────────────────────────

class RankStyle {
  const RankStyle({required this.bg, required this.fg, required this.icon});
  final Color    bg;
  final Color    fg;
  final IconData icon;

  static RankStyle of(UserRank r) {
    if (r.isCreator) {
      return const RankStyle(
        bg:   Color(0xFF6A1B9A),
        fg:   Colors.white,
        icon: Icons.verified_rounded,
      );
    }
    return switch (r.tier) {
      4 => const RankStyle(
            bg: Color(0xFFE59B27), fg: Colors.white,
            icon: Icons.local_fire_department_rounded),
      3 => const RankStyle(
            bg: Color(0xFF0F3E2B), fg: Colors.white,
            icon: Icons.workspace_premium_rounded),
      2 => const RankStyle(
            bg: Color(0xFF3A7361), fg: Colors.white,
            icon: Icons.restaurant_rounded),
      _ => const RankStyle(
            bg: Color(0xFFEDE9E3), fg: Color(0xFF55534E),
            icon: Icons.spa_rounded),
    };
  }
}

// ─────────────────────────────────────────────────────────────────────────
// RankTitleStore — owner's persisted title pick (single signed-in user
// per device, so a single SharedPreferences key suffices).
// ─────────────────────────────────────────────────────────────────────────

class RankTitleStore {
  RankTitleStore._();
  static final RankTitleStore instance = RankTitleStore._();

  static const _kKey = 'creator_rank_title_v1';

  final ValueNotifier<String?> chosenTitle = ValueNotifier<String?>(null);
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    chosenTitle.value = prefs.getString(_kKey);
  }

  Future<void> setTitle(String title) async {
    chosenTitle.value = title;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kKey, title);
  }
}

// ─────────────────────────────────────────────────────────────────────────
// UserRankService — caches share counts. uid path is authoritative
// (shared_recipes.shared_by); the handle path resolves uid first.
// ─────────────────────────────────────────────────────────────────────────

class UserRankService {
  UserRankService._();
  static final UserRankService instance = UserRankService._();

  final Map<String, int>         _byUid     = {};
  final Map<String, Future<int>> _inflight  = {};
  final Map<String, String?>     _handleToUid = {};

  SupabaseClient get _db => Supabase.instance.client;

  /// Synchronous rank for the signed-in owner. Returns null until the
  /// count has been prefetched.
  UserRank? rankOfUid(String uid, {String? handle, String? chosenTitle}) {
    final lower = (handle ?? '').toLowerCase();
    if (lower == 'sumaraijack' || lower == 'melrose') {
      return UserRank.forUser(handle: handle, shareCount: 0);
    }
    final c = _byUid[uid];
    if (c == null) return null;
    return UserRank.forUser(
      handle: handle, shareCount: c, chosenTitle: chosenTitle);
  }

  Future<int> prefetchUid(String uid) {
    if (_byUid.containsKey(uid)) return Future.value(_byUid[uid]);
    final existing = _inflight[uid];
    if (existing != null) return existing;
    final f = _countShares('shared_by', uid);
    _inflight[uid] = f;
    f.then((v) { _byUid[uid] = v; _inflight.remove(uid); })
     .catchError((_) { _inflight.remove(uid); });
    return f;
  }

  /// Feed-side lookup by handle. Resolves handle→uid via get_public_profile
  /// (cached), then counts shares for that uid. Creator handles short-circuit.
  UserRank? rankOfHandle(String handle) {
    final lower = handle.toLowerCase();
    if (lower == 'sumaraijack' || lower == 'melrose') {
      return UserRank.forUser(handle: handle, shareCount: 0);
    }
    final uid = _handleToUid[lower];
    if (uid == null) return null;
    final c = _byUid[uid];
    if (c == null) return null;
    return UserRank.forUser(handle: handle, shareCount: c);
  }

  Future<void> prefetchHandle(String handle) async {
    final lower = handle.toLowerCase();
    if (lower == 'sumaraijack' || lower == 'melrose') return;
    if (_handleToUid.containsKey(lower) && _byUid.containsKey(_handleToUid[lower])) {
      return;
    }
    try {
      final res = await _db.rpc('find_user_by_handle', params: {'q': handle});
      Map<String, dynamic>? row;
      if (res is List && res.isNotEmpty) {
        row = Map<String, dynamic>.from(res.first as Map);
      } else if (res is Map) {
        row = Map<String, dynamic>.from(res);
      }
      final uid = row?['id'] as String?;
      _handleToUid[lower] = uid;
      if (uid != null) await prefetchUid(uid);
    } catch (_) {
      _handleToUid[lower] = null;
    }
  }

  Future<int> _countShares(String column, String value) async {
    try {
      return await _db
          .from('shared_recipes')
          .count(CountOption.exact)
          .eq(column, value);
    } catch (_) {
      return 0;
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────
// RankBadge — title pill + tier icon. Used on feed + profile.
// ─────────────────────────────────────────────────────────────────────────

class RankBadge extends StatelessWidget {
  const RankBadge({super.key, required this.rank, this.compact = true});

  final UserRank rank;
  final bool     compact;

  @override
  Widget build(BuildContext context) {
    final s = RankStyle.of(rank);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 6 : 10,
        vertical:   compact ? 2 : 4,
      ),
      decoration: BoxDecoration(
        color:        s.bg,
        borderRadius: BorderRadius.circular(20),
        boxShadow: rank.isCreator
            ? const [BoxShadow(
                color: Color(0x506A1B9A), blurRadius: 6, offset: Offset(0, 1))]
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(s.icon, size: compact ? 10 : 13, color: s.fg),
          SizedBox(width: compact ? 3 : 5),
          Flexible(
            child: Text(
              rank.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color:      s.fg,
                fontSize:   compact ? 10 : 12,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.2,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// HandleRankBadge — feed convenience (handle → uid → shares → badge).
// ─────────────────────────────────────────────────────────────────────────

class HandleRankBadge extends StatefulWidget {
  const HandleRankBadge({super.key, required this.handle});
  final String handle;

  @override
  State<HandleRankBadge> createState() => _HandleRankBadgeState();
}

class _HandleRankBadgeState extends State<HandleRankBadge> {
  UserRank? _rank;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(HandleRankBadge old) {
    super.didUpdateWidget(old);
    if (old.handle != widget.handle) _resolve();
  }

  void _resolve() {
    final cached = UserRankService.instance.rankOfHandle(widget.handle);
    if (cached != null) { _rank = cached; return; }
    UserRankService.instance.prefetchHandle(widget.handle).then((_) {
      if (!mounted) return;
      setState(() => _rank =
          UserRankService.instance.rankOfHandle(widget.handle));
    });
  }

  @override
  Widget build(BuildContext context) {
    final r = _rank;
    if (r == null) return const SizedBox.shrink();
    return RankBadge(rank: r);
  }
}
