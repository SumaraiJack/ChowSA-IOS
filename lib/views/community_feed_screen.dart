// lib/views/community_feed_screen.dart — top imports
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:image_picker/image_picker.dart';
import '../services/community_hub_service.dart';
import '../widgets/motion.dart';
import '../widgets/mention_suggestion_field.dart';
import '../services/moderation_service.dart';
import '../models/user_rank.dart';

// =============================================================================
// _FeedScope — the three locality lenses for the community feed
// =============================================================================

/// Controls how the community feed is scoped and sorted.
///
///   • [nearby]   — Posts sorted by locality priority:
///                    (1) same suburb_district → (2) same city → (3) national.
///                    Default view; shows everything but floats local chow.
///   • [cityWide] — Only posts from the current user's city, newest first.
///   • [national] — All SA posts, newest first (original unfiltered feed).
enum _FeedScope { nearby, cityWide, national }

// =============================================================================
// Constants — trending tags and mock data
// =============================================================================

const _kTags = [
  '#BraaiBroodjies',
  '#WinterWarmers',
  '#PotjieMaster',
  '#BudgetMeals',
  '#UmngqushoVibes',
  '#KapseKos',
  '#BraaiSeason',
  '#LoadsheddingCooking',
];

// ---------------------------------------------------------------------------
// _PostData — in-file model, not persisted
// ---------------------------------------------------------------------------

class _PostData {
  final String id;
  final String username;
  final String initials;
  final Color  avatarColor;
  final String timestamp;
  final String recipeTitle;
        String caption;
  final List<String> tags;
  int likeCount;
  int commentCount;
  final List<Color> gradientColors;
  final IconData dishIcon;
  final bool isLoadsheddingFriendly;
  bool isLiked;
  bool isSaved;
  final String? localImagePath;
  /// Public Supabase Storage URL — set AFTER the image is uploaded to the
  /// 'posts' bucket. Takes priority over [localImagePath] at render time so
  /// every device sees the same image (not just the author's device).
  final String? imageUrl;
  /// Supabase user_id of whoever created this post — used for ownership check
  final String? authorUserId;

  /// Poster's suburb/district at time of posting (e.g. "Table View").
  /// Null for posts created before the locality migration.
  final String? suburbDistrict;

  /// Poster's city at time of posting (e.g. "Cape Town").
  /// Null for posts created before the locality migration.
  final String? city;

  _PostData({
    required this.id,
    required this.username,
    required this.initials,
    required this.avatarColor,
    required this.timestamp,
    required this.recipeTitle,
    required this.caption,
    required this.tags,
    required this.likeCount,
    required this.commentCount,
    required this.gradientColors,
    required this.dishIcon,
    required this.isLoadsheddingFriendly,
    this.isLiked = false,
    this.isSaved = false,
    this.localImagePath,
    this.imageUrl,
    this.authorUserId,
    this.suburbDistrict,
    this.city,
  });

  /// Produces a NEW _PostData with the specified fields overridden.
  ///
  /// Critical for the Realtime channel callbacks: when a like/comment event
  /// arrives we must REPLACE the list element with a new instance, not
  /// mutate `likeCount` on the existing object. Flutter's ListView.builder
  /// diffs rows by reference identity — mutating a field on the same
  /// _PostData reference leaves the existing element in place and the
  /// row never rebuilds (which is exactly the bug that masked the
  /// previous "counters stuck" issue).
  _PostData copyWith({
    int?    likeCount,
    int?    commentCount,
    bool?   isLiked,
    bool?   isSaved,
  }) {
    return _PostData(
      id:                     id,
      username:               username,
      initials:               initials,
      avatarColor:            avatarColor,
      timestamp:              timestamp,
      recipeTitle:            recipeTitle,
      caption:                caption,
      tags:                   tags,
      likeCount:              likeCount    ?? this.likeCount,
      commentCount:           commentCount ?? this.commentCount,
      gradientColors:         gradientColors,
      dishIcon:               dishIcon,
      isLoadsheddingFriendly: isLoadsheddingFriendly,
      isLiked:                isLiked      ?? this.isLiked,
      isSaved:                isSaved      ?? this.isSaved,
      localImagePath:         localImagePath,
      imageUrl:               imageUrl,
      authorUserId:           authorUserId,
      suburbDistrict:         suburbDistrict,
      city:                   city,
    );
  }
}

// =============================================================================
// SavedCommunityRecipe — lightweight model for lifted save state
// =============================================================================

class SavedCommunityRecipe {
  final String id;
  final String recipeTitle;
  final String username;
  final List<String> tags;
  final DateTime savedAt;
  /// Remote image URL captured at save time so the save-to-recipes pipeline
  /// can persist `image_url` into the recipes row. Null when the post had
  /// only the gradient-placeholder dish art.
  final String? imageUrl;

  const SavedCommunityRecipe({
    required this.id,
    required this.recipeTitle,
    required this.username,
    required this.tags,
    required this.savedAt,
    this.imageUrl,
  });
}

// =============================================================================
// Screen
// =============================================================================

class CommunityFeedScreen extends StatefulWidget {
  const CommunityFeedScreen({
    super.key,
    this.savedRecipeIds = const {},
    this.onToggleSave,
    this.initialPostId,
  });

  /// IDs currently saved — drives the "Saved!" button state.
  final Set<String> savedRecipeIds;
  /// Called when user taps Save/Unsave on a post. Parent owns persistence.
  final void Function(SavedCommunityRecipe recipe, bool saved)? onToggleSave;

  /// Optional post id to scroll into view after the feed hydrates. Used
  /// by the @mention push notification deep-link so tapping "X mentioned
  /// you" lands on the exact post that contains the @-tag. Highlight
  /// effect is briefly applied to draw the user's eye to it.
  final String? initialPostId;

  @override
  State<CommunityFeedScreen> createState() => _CommunityFeedScreenState();
}

class _CommunityFeedScreenState extends State<CommunityFeedScreen> {
  final List<_PostData>       _posts         = [];
  bool                        _loading       = true;
  int                         _activeTag     = 0;
  final TextEditingController _searchCtrl    = TextEditingController();
  String                      _searchQuery   = '';
  bool                        _searchFocused = false;
  final FocusNode             _searchFocus   = FocusNode();

  // ── Locality feed state ───────────────────────────────────────────────────
  _FeedScope _scope       = _FeedScope.nearby;
  String?    _userSuburb;   // profiles.suburb_district of the signed-in user
  String?    _userCity;     // profiles.city of the signed-in user

  SupabaseClient get _db => Supabase.instance.client;
  String? get _userId => _db.auth.currentUser?.id;

  @override
  void initState() {
    super.initState();
    _searchFocus.addListener(
        () => setState(() => _searchFocused = _searchFocus.hasFocus));
    _loadUserLocation(); // load before _loadPosts so sort is correct on first render
    _loadPosts();
    _subscribeToNewPosts();
  }

  // ── Realtime channel references (for cleanup) ──────────────────────────────
  // Two screen-level Realtime channels:
  //
  //   _postsChannel        → community_posts INSERT/UPDATE/DELETE
  //                          (new posts appear, deleted posts disappear,
  //                          edits re-render)
  //
  //   _feedUpdatesChannel  → post_likes + post_comments INSERT/DELETE
  //                          (live counter updates with explicit logging
  //                          and a subscription-status logger so we can
  //                          see WebSocket connection state in the console)
  RealtimeChannel? _postsChannel;
  RealtimeChannel? _feedUpdatesChannel;

  @override
  void dispose() {
    _searchCtrl.dispose();
    _searchFocus.dispose();
    _postsChannel?.unsubscribe();
    _feedUpdatesChannel?.unsubscribe();
    super.dispose();
  }

  // ── Locality helpers ───────────────────────────────────────────────────────

  /// Fetches the current user's suburb_district and city from `profiles` so
  /// the feed can apply the locality priority sort. Runs in parallel with
  /// _loadPosts — if it resolves after the posts arrive, `setState` triggers
  /// an in-memory re-sort with no extra network call.
  Future<void> _loadUserLocation() async {
    if (_userId == null) return;
    try {
      final row = await _db
          .from('profiles')
          .select('suburb_district, city')
          .eq('id', _userId!)
          .maybeSingle();
      if (!mounted || row == null) return;
      setState(() {
        _userSuburb = (row['suburb_district'] as String?)?.trim();
        _userCity   = (row['city']            as String?)?.trim();
      });
    } catch (_) {/* location stays null → fallback to national sort */}
  }

  /// Returns a locality priority bucket for [post] given the current user's
  /// home suburb and city.
  ///
  ///   0 → same suburb_district (Priority 1 — Nearby)
  ///   1 → same city, different suburb (Priority 2 — City-Wide)
  ///   2 → anywhere else in SA (Priority 3 — National)
  int _localityPriority(_PostData post) {
    final suburb = _userSuburb?.toLowerCase();
    final city   = _userCity?.toLowerCase();

    if (suburb != null && suburb.isNotEmpty &&
        post.suburbDistrict?.toLowerCase() == suburb) {
      return 0;
    }
    if (city != null && city.isNotEmpty &&
        post.city?.toLowerCase() == city) {
      return 1;
    }
    return 2;
  }

  // ── Load posts from Supabase ───────────────────────────────────────────────

  Future<void> _loadPosts() async {
    try {
      // ── PostgREST resource-embedding for live counters ──────────────────────
      // `post_likes(count)` and `comments(count)` ride on each row as
      // synthetic relations holding `[{count: N}]`. This replaces the stale
      // denormalised like_count / comment_count columns with the actual row
      // counts from the junction tables — so a like added on another device
      // appears here the next time the feed loads (or on a Realtime echo).
      //
      // Schema this requires:
      //   • post_likes(id uuid pk, post_id uuid fk → community_posts.id,
      //                user_id uuid fk → auth.users.id, unique(post_id,user_id))
      //   • comments  (id uuid pk, post_id uuid fk → community_posts.id, …)
      //   • Foreign keys must be declared so PostgREST can infer the relation.
      final rows = await _db
          .from('community_posts')
          .select('*, post_likes(count), comments(count)')
          .order('created_at', ascending: false)
          .limit(50);

      final likedIds = await _getLikedPostIds();

      if (!mounted) return;
      setState(() {
        _posts
          ..clear()
          ..addAll((rows as List).map((r) => _postFromRow(r, likedIds)));
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<Set<String>> _getLikedPostIds() async {
    if (_userId == null) return {};
    try {
      final rows = await _db
          .from('post_likes')
          .select('post_id')
          .eq('user_id', _userId!);
      return {for (final r in rows as List) r['post_id'] as String};
    } catch (_) {
      return {};
    }
  }

  _PostData _postFromRow(Map<String, dynamic> r, Set<String> likedIds) {
    final colors = (r['gradient_colors'] as List? ?? ['#BF360C', '#FF8F00'])
        .map((c) => Color(int.parse('0xFF${(c as String).replaceFirst('#', '')}')))
        .toList();
    final isLiked = likedIds.contains(r['id'] as String);

    // ── Extract embedded counts (PostgREST `relation(count)` syntax) ────────
    // The response shape for each is `[{count: 42}]`. Fall back to the
    // legacy denormalised columns when the embed is missing (e.g. running
    // against an older Supabase schema without the junction tables yet).
    final likeCount    = _readEmbeddedCount(r['post_likes'])
                       ?? (r['like_count']    as int?) ?? 0;
    final commentCount = _readEmbeddedCount(r['comments'])
                       ?? (r['comment_count'] as int?) ?? 0;

    return _PostData(
      id:                     r['id'] as String,
      username:               r['handle'] as String,
      initials:               r['initials'] as String,
      avatarColor:            Color(int.parse(
          '0xFF${(r['avatar_color'] as String).replaceFirst('#', '')}')),
      timestamp:              _formatTime(r['created_at'] as String),
      recipeTitle:            r['recipe_title'] as String,
      caption:                r['caption'] as String,
      tags:                   List<String>.from(r['tags'] as List? ?? []),
      likeCount:              likeCount,
      commentCount:           commentCount,
      gradientColors:         colors,
      dishIcon:               Icons.restaurant_rounded,
      isLoadsheddingFriendly: (r['is_loadshedding_friendly'] as bool?) ?? false,
      isLiked:                isLiked,
      isSaved:                widget.savedRecipeIds.contains(r['id'] as String),
      // Read the persisted Supabase Storage URL (column: image_url).
      // Treat empty strings as absent so old rows don't render a broken icon.
      imageUrl:               (r['image_url'] as String?)?.trim().isNotEmpty == true
                                  ? r['image_url'] as String
                                  : null,
      authorUserId:           r['user_id']          as String?,
      suburbDistrict:         r['suburb_district']  as String?,
      city:                   r['city']             as String?,
    );
  }

  /// Pulls the `count` out of a PostgREST embedded `relation(count)` payload.
  /// Returns null when the embed is missing or shaped unexpectedly so the
  /// caller can fall back to a legacy denormalised column.
  int? _readEmbeddedCount(dynamic embed) {
    if (embed is List && embed.isNotEmpty) {
      final first = embed.first;
      if (first is Map && first['count'] is int) {
        return first['count'] as int;
      }
    }
    return null;
  }

  String _formatTime(String iso) {
    try {
      final dt  = DateTime.parse(iso).toLocal();
      final ago = DateTime.now().difference(dt);
      if (ago.inMinutes < 1)  return 'Just now';
      if (ago.inMinutes < 60) return '${ago.inMinutes} min ago';
      if (ago.inHours   < 24) return '${ago.inHours}h ago';
      return '${ago.inDays}d ago';
    } catch (_) {
      return '';
    }
  }

  // ── Realtime subscriptions ──────────────────────────────────────────────────
  //
  // TWO screen-level channels, each with a focused responsibility:
  //
  //   1. _postsChannel       → INSERT/UPDATE/DELETE on community_posts
  //                            (keeps the feed list in sync)
  //
  //   2. _feedUpdatesChannel → ALL events on post_likes + post_comments
  //                            (drives live counter updates with explicit
  //                            logging so we can see in the console whether
  //                            the WebSocket is connected and whether events
  //                            are actually arriving from the server)
  //
  // Why the explicit `channel.onPostgresChanges() / .subscribe(status, error)`
  // pattern instead of the higher-level `.stream()` API:
  //   • debugPrint of every payload proves events ARE arriving (vs. silent
  //     swallowing in the stream wrapper)
  //   • The subscribe-callback exposes the connection lifecycle —
  //     `SUBSCRIBED`, `CHANNEL_ERROR`, `TIMED_OUT`, `CLOSED` — which lets
  //     us distinguish "Realtime is broken" from "Realtime works but
  //     events aren't routed to this widget"
  //
  // Required Supabase config (already verified in dashboard):
  //   Database → Replication → supabase_realtime → post_likes ✓, post_comments ✓

  void _subscribeToNewPosts() {
    // ── Channel 1: feed list (existing) ──────────────────────────────────
    _postsChannel = _db.channel('community_posts_realtime')
        .onPostgresChanges(
          event:  PostgresChangeEvent.insert,
          schema: 'public',
          table:  'community_posts',
          callback: (payload) async {
            if (!mounted) return;
            final likedIds = await _getLikedPostIds();
            final post = _postFromRow(payload.newRecord, likedIds);
            // Don't duplicate our own optimistic post
            if (_posts.any((p) => p.id == post.id)) return;
            if (mounted) setState(() => _posts.insert(0, post));
          },
        )
        .onPostgresChanges(
          event:  PostgresChangeEvent.update,
          schema: 'public',
          table:  'community_posts',
          callback: (payload) async {
            if (!mounted) return;
            final newRow = payload.newRecord;
            final id     = newRow['id'] as String?;
            if (id == null) return;
            final idx = _posts.indexWhere((p) => p.id == id);
            if (idx == -1) return;
            // Re-parse the row with current like state
            final likedIds = await _getLikedPostIds();
            final updated  = _postFromRow(newRow, likedIds);
            if (mounted) setState(() => _posts[idx] = updated);
          },
        )
        .onPostgresChanges(
          event:  PostgresChangeEvent.delete,
          schema: 'public',
          table:  'community_posts',
          callback: (payload) {
            if (!mounted) return;
            final oldRow = payload.oldRecord;
            final id     = oldRow['id'] as String?;
            if (id == null) return;
            if (mounted) setState(() => _posts.removeWhere((p) => p.id == id));
          },
        )
        .subscribe();

    // ── Channel 2: live like + comment counters ──────────────────────────
    // Spec-exact wiring: single channel named `public:feed_updates`, two
    // onPostgresChanges chains (one per table), subscribe() with a status +
    // error callback for connection diagnostics.
    _feedUpdatesChannel = _db
        .channel('public:feed_updates')
        .onPostgresChanges(
          event:  PostgresChangeEvent.all,
          schema: 'public',
          table:  'post_likes',
          callback: (payload) {
            debugPrint(
                'Realtime Like Event received: ${payload.toString()}');
            _handleLikeEvent(payload);
          },
        )
        .onPostgresChanges(
          event:  PostgresChangeEvent.all,
          schema: 'public',
          table:  'post_comments',
          callback: (payload) {
            debugPrint(
                'Realtime Comment Event received: ${payload.toString()}');
            _handleCommentEvent(payload);
          },
        )
        .subscribe((status, error) {
          debugPrint('Supabase Stream Connection Status: $status');
          if (error != null) {
            // The subscribe callback types `error` as Object? — calling
            // `.message` on it doesn't compile (the previous build failure).
            // Use toString() as the universal fallback; if the runtime type
            // happens to be a typed Supabase error with a `.message` field,
            // surface that explicitly so the log line stays readable.
            String detail;
            if (error is PostgrestException) {
              detail = error.message;
            } else if (error is RealtimeSubscribeException) {
              detail = error.toString();
            } else {
              detail = error.toString();
            }
            debugPrint('Supabase Stream Connection Error: $detail');
          }
        });
  }

  // ── Like-event handler ─────────────────────────────────────────────────
  //
  // 1. Pull post_id out of newRecord (INSERT/UPDATE) or oldRecord (DELETE)
  // 2. Find the post in our local _posts list
  // 3. Fetch the canonical like count from the DB (one cheap COUNT query)
  // 4. Refresh isLiked for the current user
  // 5. REPLACE the post via copyWith() — never mutate fields in place,
  //    because ListView.builder won't rebuild a row whose _PostData
  //    reference identity is unchanged.

  Future<void> _handleLikeEvent(PostgresChangePayload payload) async {
    if (!mounted) return;

    final record = (payload.newRecord.isNotEmpty
        ? payload.newRecord
        : payload.oldRecord);
    final postId = record['post_id'] as String?;
    if (postId == null) {
      debugPrint('Realtime Like Event: missing post_id, skipping');
      return;
    }

    final idx = _posts.indexWhere((p) => p.id == postId);
    if (idx == -1) {
      // Affected post isn't on screen — nothing to update.
      return;
    }

    try {
      // Canonical count from the source of truth.
      final response = await _db
          .from('post_likes')
          .select('id')
          .eq('post_id', postId)
          .count(CountOption.exact);

      // Refresh isLiked for the signed-in user.
      bool isLikedByMe = false;
      if (_userId != null) {
        final myLike = await _db
            .from('post_likes')
            .select('id')
            .eq('post_id', postId)
            .eq('user_id', _userId!)
            .maybeSingle();
        isLikedByMe = myLike != null;
      }

      if (!mounted) return;
      // copyWith → new _PostData instance → ListView.builder sees the
      // identity change → row rebuilds → _ActionButton picks up new label.
      setState(() {
        _posts[idx] = _posts[idx].copyWith(
          likeCount: response.count,
          isLiked:   isLikedByMe,
        );
      });
      debugPrint('Post $postId likeCount → ${response.count} (isLiked=$isLikedByMe)');
    } catch (e) {
      debugPrint('Realtime Like Event reconciliation failed: $e');
    }
  }

  // ── Comment-event handler ──────────────────────────────────────────────

  Future<void> _handleCommentEvent(PostgresChangePayload payload) async {
    if (!mounted) return;

    final record = (payload.newRecord.isNotEmpty
        ? payload.newRecord
        : payload.oldRecord);
    final postId = record['post_id'] as String?;
    if (postId == null) {
      debugPrint('Realtime Comment Event: missing post_id, skipping');
      return;
    }

    final idx = _posts.indexWhere((p) => p.id == postId);
    if (idx == -1) return;

    try {
      final response = await _db
          .from('post_comments')
          .select('id')
          .eq('post_id', postId)
          .count(CountOption.exact);

      if (!mounted) return;
      setState(() {
        _posts[idx] = _posts[idx].copyWith(commentCount: response.count);
      });
      debugPrint('Post $postId commentCount → ${response.count}');
    } catch (e) {
      debugPrint('Realtime Comment Event reconciliation failed: $e');
    }
  }

  // ── Search + scope filter ──────────────────────────────────────────────────

  List<_PostData> get _filteredPosts {
    // ── 1. Text search filter ────────────────────────────────────────────────
    final query = _searchQuery.trim().toLowerCase();
    Iterable<_PostData> posts = _posts;

    if (query.isNotEmpty) {
      posts = posts.where((p) {
        if (p.recipeTitle.toLowerCase().contains(query)) return true;
        if (p.caption.toLowerCase().contains(query))     return true;
        return p.tags.any((t) => t.toLowerCase().contains(query));
      });
    }

    // ── 2. Scope filter + sort ───────────────────────────────────────────────
    switch (_scope) {
      // ── Nearby: show everything, sorted locality priority → then recency ──
      case _FeedScope.nearby:
        final sorted = posts.toList();
        // _posts is already newest-first from the DB query; a stable sort on
        // priority bucket preserves that recency order within each bucket.
        sorted.sort((a, b) =>
            _localityPriority(a).compareTo(_localityPriority(b)));
        return sorted;

      // ── City-Wide: only posts from the current user's city ───────────────
      case _FeedScope.cityWide:
        final city = _userCity?.toLowerCase();
        if (city == null || city.isEmpty) {
          // User has no city set yet — show everything so the feed isn't empty.
          return posts.toList();
        }
        return posts
            .where((p) => p.city?.toLowerCase() == city)
            .toList();

      // ── National: all posts, recency order (original behaviour) ──────────
      case _FeedScope.national:
        return posts.toList();
    }
  }

  // ── Interaction handlers ───────────────────────────────────────────────────

  void _toggleLike(int originalIndex) async {
    if (originalIndex < 0 || originalIndex >= _posts.length) return;
    final post     = _posts[originalIndex];

    // Prevent liking the same post twice — if already liked, tap = unlike
    final nowLiked = !post.isLiked;

    // Optimistic local update
    setState(() {
      _posts[originalIndex].isLiked = nowLiked;
      final newCount = _posts[originalIndex].likeCount + (nowLiked ? 1 : -1);
      _posts[originalIndex].likeCount = newCount < 0 ? 0 : newCount;
    });

    // Only hit the DB if the user is signed in
    if (_userId == null) return;

    try {
      if (nowLiked) {
        await _db.from('post_likes').upsert(
          {'post_id': post.id, 'user_id': _userId!},
          onConflict: 'post_id,user_id',
        );
      } else {
        await _db.from('post_likes')
            .delete()
            .eq('post_id', post.id)
            .eq('user_id', _userId!);
      }

      // ── Reconcile with the canonical server count ─────────────────────────
      // Optimistic ±1 is only correct when nobody else liked/unliked between
      // our query and now. Hit the junction table for the authoritative count
      // and overwrite the local value. Falls back silently if it errors —
      // the optimistic value stays as a best guess.
      try {
        final response = await _db
            .from('post_likes')
            .select('id')
            .eq('post_id', post.id)
            .count(CountOption.exact);
        if (mounted) {
          setState(() => _posts[originalIndex].likeCount = response.count);
        }
      } catch (_) { /* keep optimistic count */ }
    } catch (_) {
      // Revert on failure
      if (mounted) setState(() {
        _posts[originalIndex].isLiked = !nowLiked;
        final revert = _posts[originalIndex].likeCount + (nowLiked ? -1 : 1);
        _posts[originalIndex].likeCount = revert < 0 ? 0 : revert;
      });
    }
  }

  void _toggleSave(_PostData post) {
    final idx = _posts.indexOf(post);
    if (idx == -1) return;
    final nowSaved = !_posts[idx].isSaved;
    setState(() => _posts[idx].isSaved = nowSaved);

    // Notify parent so saved recipes are persisted globally.
    widget.onToggleSave?.call(
      SavedCommunityRecipe(
        id:          post.id,
        recipeTitle: post.recipeTitle,
        username:    post.username,
        tags:        post.tags,
        savedAt:     DateTime.now(),
        imageUrl:    post.imageUrl,
      ),
      nowSaved,
    );

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          nowSaved
              ? '"${post.recipeTitle}" saved to My Recipes!'
              : '"${post.recipeTitle}" removed from My Recipes.',
        ),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _onTagTap(int index) {
    final tag   = _kTags[index];
    final query = tag.toLowerCase();
    setState(() {
      _activeTag   = index;
      _searchQuery = query;
      _searchCtrl.text = tag;
    });
    _searchFocus.unfocus();
  }

  void _clearSearch() {
    setState(() {
      _searchQuery = '';
      _activeTag   = 0;
      _searchCtrl.clear();
    });
  }

  void _showCommentSheet(BuildContext context, _PostData post) {
    final idx = _posts.indexOf(post);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _CommentSheet(
        post: post,
        onCommentAdded: (text) {
          if (idx != -1) setState(() => _posts[idx].commentCount++);
        },
      ),
    );
  }

  // ── Edit Post — premium-style modal matching the Share a Chow framework ──
  // Reuses the same _ShareChowSheet widget in editing mode so the user gets
  // the full structural form (title + caption + tag chips + image preview),
  // not a tiny AlertDialog. The sheet pre-populates from `post`, surfaces an
  // "Update Post" submit button, and writes the UPDATE call to Supabase via
  // _ShareChowSheet._submitEdit().
  void _editPost(BuildContext context, _PostData post) {
    final idx = _posts.indexOf(post);
    if (idx == -1) return;

    showModalBottomSheet<void>(
      context:            context,
      isScrollControlled: true,
      backgroundColor:    Colors.transparent,
      builder: (_) => _ShareChowSheet(
        editingPost: post,
        onUpdated: (updated) {
          // Swap the in-memory post so the feed reflects the edit
          // immediately — no need to wait for the Realtime channel echo.
          if (mounted) setState(() => _posts[idx] = updated);
        },
      ),
    );
  }

  void _deletePost(_PostData post) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete post?'),
        content: const Text('This will remove your post from the community feed.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () async {
              setState(() => _posts.remove(post));
              Navigator.pop(ctx);
              try {
                await _db.from('community_posts')
                    .delete()
                    .eq('id', post.id);
              } catch (_) {/* already removed locally */}
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  void _showShareChowSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context:            context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ShareChowSheet(
        onPosted: (newPost) async {
          // Optimistically add to feed immediately — author sees local file.
          setState(() => _posts.insert(0, newPost));

          // Capture messenger before any await so we can show snackbars
          // even if the widget is no longer in the primary navigation stack
          // by the time the async chain completes.
          final messenger = ScaffoldMessenger.of(context);

          // Persist to Supabase — three sequential steps, each with its own
          // error scope so a failure in one step doesn't silently kill the rest.
          try {
            final user   = _db.auth.currentUser;
            final handle = user?.userMetadata?['handle'] as String?
                ?? user?.email?.split('@').first
                ?? 'Chef';
            final initials = handle.length >= 2
                ? handle.substring(0, 2).toUpperCase()
                : handle.toUpperCase();

            // ── Step 1: Upload image to Supabase Storage ──────────────────────
            // Runs BEFORE the DB insert so the public URL can be stamped on
            // the row. If the upload fails we still insert — just without an
            // image_url — so the text post persists rather than being lost.
            String? publicUrl;
            if (newPost.localImagePath != null) {
              final localFile = File(newPost.localImagePath!);
              if (await localFile.exists()) {
                try {
                  // Delegate to the centralised upload helper — guarantees a
                  // unique object key (`<uid>/<epoch_ms>_<hex>.<ext>`) and
                  // returns the public URL of the exact object just written,
                  // so the row insert below pairs with the right image.
                  publicUrl = await CommunityHubService.instance
                      .uploadCommunityFeedImage(localFile);
                } catch (uploadErr) {
                  // Storage upload failed — log and continue without image_url.
                  // The text post still reaches the DB; the image falls back to
                  // the gradient placeholder on every device.
                  debugPrint('CommunityFeed: image upload failed: $uploadErr');
                  publicUrl = null;
                }
              }
            }

            // ── Step 2: Insert post row with the public URL ───────────────────
            // image_url is only included when the upload succeeded (publicUrl
            // non-null). suburb_district / city locality columns are included
            // when the user's profile has them resolved — both columns now
            // exist on community_posts after migration 20260602_community_posts.
            final inserted = await _db.from('community_posts').insert({
              'user_id':       user?.id,
              'handle':        handle,
              'initials':      initials,
              'avatar_color':  '#E55B2B',
              'recipe_title':  newPost.recipeTitle,
              'caption':       newPost.caption,
              'tags':          newPost.tags,
              'gradient_colors': ['#BF360C', '#FF8F00'],
              'dish_icon':     'restaurant_rounded',
              'is_loadshedding_friendly': false,
              if (publicUrl   != null) 'image_url':       publicUrl,
              if (_userSuburb != null) 'suburb_district': _userSuburb,
              if (_userCity   != null) 'city':            _userCity,
            }).select().single();

            // ── Step 3: Swap optimistic post for the real persisted row ───────
            // The returned row carries image_url from the DB column so the
            // feed switches from local-file rendering to network-URL rendering
            // without any flicker (same image, different source).
            if (mounted) {
              final realPost = _postFromRow(inserted, {});
              final idx = _posts.indexWhere((p) => p.id == newPost.id);
              if (idx != -1) setState(() => _posts[idx] = realPost);
            }

            // ── Success snackbar ──────────────────────────────────────────────
            if (mounted) {
              messenger.showSnackBar(
                SnackBar(
                  content: const Text('Your chow is live! 🔥'),
                  behavior: SnackBarBehavior.floating,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  duration: const Duration(seconds: 3),
                ),
              );
            }
          } catch (e) {
            // DB insert failed. The optimistic post stays visible for the
            // current session but won't survive a reload. Show a visible error
            // so the user knows to try again — previously this was a silent
            // swallow which is what caused the "image vanishes on return" bug.
            debugPrint('CommunityFeed: post insert failed: $e');
            if (mounted) {
              messenger.showSnackBar(
                SnackBar(
                  content: const Text(
                    'Could not save your post — please try again.',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  backgroundColor: Colors.red.shade700,
                  behavior:        SnackBarBehavior.floating,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  duration: const Duration(seconds: 4),
                ),
              );
            }
          }
        },
      ),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final colors   = Theme.of(context).colorScheme;
    final filtered = _filteredPosts;

    return Scaffold(
      backgroundColor: colors.surface,
      body: Column(
        children: [
          _FeedAppBar(),

          // ── Search bar ───────────────────────────────────────────────────────
          _CommunitySearchBar(
            controller:  _searchCtrl,
            focusNode:   _searchFocus,
            isFocused:   _searchFocused,
            hasQuery:    _searchQuery.isNotEmpty,
            onChanged:   (v) => setState(() => _searchQuery = v),
            onClear:     _clearSearch,
          ),

          // ── Locality scope chips (hidden while search is active) ──────────
          if (_searchQuery.isEmpty)
            _LocalityChipBar(
              scope:      _scope,
              userSuburb: _userSuburb,
              userCity:   _userCity,
              onChanged:  (s) => setState(() => _scope = s),
            ),

          // ── Trending tags (hidden while search is active) ─────────────────
          if (_searchQuery.isEmpty)
            _TrendingTagsBar(
              tags:        _kTags,
              activeIndex: _activeTag,
              onTap:       _onTagTap,
            ),

          // ── Results ──────────────────────────────────────────────────────────
          Expanded(
            child: _loading
                ? ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
                    itemCount: 4,
                    separatorBuilder: (_, __) => const SizedBox(height: 16),
                    itemBuilder: (_, __) => const PostCardSkeleton(),
                  )
                : filtered.isEmpty && _searchQuery.isNotEmpty
                    ? _SearchEmptyState(query: _searchQuery, onClear: _clearSearch)
                    : filtered.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.local_fire_department_rounded,
                                    size: 48, color: Color(0xFFE59B27)),
                                const SizedBox(height: 12),
                                Text('No posts yet — be the first!',
                                    style: Theme.of(context).textTheme.titleSmall),
                              ],
                            ),
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
                            itemCount: filtered.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 16),
                            itemBuilder: (context, i) {
                              final post = filtered[i];
                              // @mention deep-link: wrap the matched post
                              // in a soft gold halo so the user's eye
                              // immediately lands on the post that tagged
                              // them. Halo persists for the screen's life
                              // (cheap to render; no timer scaffolding).
                              final isHighlighted =
                                  widget.initialPostId != null &&
                                  post.id == widget.initialPostId;
                              Widget card = PressableScale(
                                behavior: HitTestBehavior.deferToChild,
                                child: _PostCard(
                                  post:          post,
                                  onLike:        () => _toggleLike(_posts.indexOf(post)),
                                  onComment:     () => _showCommentSheet(context, post),
                                  onSave:        () => _toggleSave(post),
                                  onEdit:        () => _editPost(context, post),
                                  onDelete:      () => _deletePost(post),
                                  currentUserId: _userId,
                                ),
                              );
                              if (isHighlighted) {
                                card = Container(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(
                                      color: const Color(0xFFE59B27),
                                      width: 2,
                                    ),
                                    boxShadow: const [
                                      BoxShadow(
                                        color:        Color(0x55E59B27),
                                        blurRadius:   18,
                                        spreadRadius: 1,
                                      ),
                                    ],
                                  ),
                                  child: card,
                                );
                              }
                              return card;
                            },
                          ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showShareChowSheet(context),
        icon: const Icon(Icons.add_a_photo_rounded),
        label: const Text(
          'Share a Chow',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}

// =============================================================================
// _LocalityChipBar — Nearby / City-Wide / National scope selector
// =============================================================================

/// A minimal horizontal-scrolling chip row that lets the user shift the
/// feed between three locality lenses without any dropdown or modal.
///
/// Chip labels dynamically reflect the user's actual location when known:
///   Nearby      → "Table View" (suburb name), else generic "Nearby"
///   City-Wide   → "Cape Town"  (city name),   else generic "City-Wide"
///   National    → always "🇿🇦 National"
class _LocalityChipBar extends StatelessWidget {
  const _LocalityChipBar({
    required this.scope,
    required this.onChanged,
    this.userSuburb,
    this.userCity,
  });

  final _FeedScope             scope;
  final ValueChanged<_FeedScope> onChanged;
  final String?                userSuburb;
  final String?                userCity;

  static const _kForest = Color(0xFF0C351E);

  @override
  Widget build(BuildContext context) {
    final chips = [
      _ChipSpec(
        scope:  _FeedScope.nearby,
        icon:   Icons.location_on_rounded,
        // Show suburb name if known, so "Table View" reads naturally on the chip.
        label:  (userSuburb != null && userSuburb!.isNotEmpty)
                    ? userSuburb!
                    : 'Nearby',
      ),
      _ChipSpec(
        scope:  _FeedScope.cityWide,
        icon:   Icons.location_city_rounded,
        label:  (userCity != null && userCity!.isNotEmpty)
                    ? userCity!
                    : 'City-Wide',
      ),
      _ChipSpec(
        scope:  _FeedScope.national,
        icon:   Icons.public_rounded,
        label:  'National',
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 40,
          child: ListView.separated(
            scrollDirection:  Axis.horizontal,
            padding:          const EdgeInsets.symmetric(horizontal: 16),
            itemCount:        chips.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              final chip     = chips[i];
              final isActive = scope == chip.scope;

              return GestureDetector(
                onTap: () => onChanged(chip.scope),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve:    Curves.easeInOut,
                  padding:  const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: isActive ? _kForest : Colors.transparent,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: isActive
                          ? _kForest
                          : const Color(0xFFE6E2D8),
                      width: isActive ? 0 : 1.2,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        chip.icon,
                        size:  14,
                        color: isActive
                            ? Colors.white
                            : const Color(0xFF55534E),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        chip.label,
                        style: TextStyle(
                          fontSize:   12,
                          fontWeight: FontWeight.w700,
                          color:      isActive
                              ? Colors.white
                              : const Color(0xFF55534E),
                          letterSpacing: 0.1,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 6),
      ],
    );
  }
}

class _ChipSpec {
  const _ChipSpec({
    required this.scope,
    required this.icon,
    required this.label,
  });
  final _FeedScope scope;
  final IconData   icon;
  final String     label;
}

// =============================================================================
// =============================================================================
// _CommunitySearchBar
// =============================================================================

class _CommunitySearchBar extends StatelessWidget {
  const _CommunitySearchBar({
    required this.controller,
    required this.focusNode,
    required this.isFocused,
    required this.hasQuery,
    required this.onChanged,
    required this.onClear,
  });

  final TextEditingController controller;
  final FocusNode             focusNode;
  final bool                  isFocused;
  final bool                  hasQuery;
  final ValueChanged<String>  onChanged;
  final VoidCallback          onClear;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        decoration: BoxDecoration(
          color:        Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isFocused
                ? const Color(0xFF0C351E)
                : const Color(0xFFE6E2D8),
            width: isFocused ? 1.5 : 1.0,
          ),
          boxShadow: isFocused
              ? [
                  const BoxShadow(
                    color:      Color(0x201E4D2B),
                    blurRadius: 14,
                    offset:     Offset(0, 3),
                  )
                ]
              : [],
        ),
        child: TextField(
          controller:  controller,
          focusNode:   focusNode,
          onChanged:   onChanged,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: 'Search recipes, #hashtags, captions…',
            hintStyle: TextStyle(
              color:    cs.onSurfaceVariant.withAlpha(120),
              fontSize: 14,
            ),
            prefixIcon: const Icon(
              Icons.search_rounded,
              color: Color(0xFF0C351E),
              size:  22,
            ),
            suffixIcon: hasQuery
                ? IconButton(
                    icon:    const Icon(Icons.close_rounded, size: 18),
                    color: null,
                    onPressed: onClear,
                  )
                : null,
            filled:      false,
            border:      InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(
                vertical: 14, horizontal: 4),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// _SearchEmptyState
// =============================================================================

class _SearchEmptyState extends StatelessWidget {
  const _SearchEmptyState({required this.query, required this.onClear});

  final String       query;
  final VoidCallback onClear;

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
              width:  72,
              height: 72,
              decoration: BoxDecoration(
                color:        const Color(0xFF0C351E).withAlpha(15),
                borderRadius: BorderRadius.circular(22),
              ),
              child: const Icon(Icons.search_off_rounded,
                  size: 34, color: Color(0xFF0C351E)),
            ),
            const SizedBox(height: 18),
            Text(
              'No results for "$query"',
              textAlign: TextAlign.center,
              style: tt.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color:      const Color(0xFF0C351E),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Try a different recipe name, ingredient, or hashtag '
              'like #BraaiBroodjies.',
              textAlign: TextAlign.center,
              style: tt.bodyMedium?.copyWith(
                  color: null, height: 1.55),
            ),
            const SizedBox(height: 20),
            TextButton.icon(
              onPressed: onClear,
              icon:  const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('Clear search'),
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFFE59B27),
                textStyle: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Feed app bar
// =============================================================================

class _FeedAppBar extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text   = Theme.of(context).textTheme;

    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
        child: Row(
          children: [
            // Brand mark
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [colors.primary, colors.secondary],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.local_fire_department_rounded,
                  color: Colors.white, size: 20),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Community',
                  style: text.titleLarge?.copyWith(
                    fontWeight: FontWeight.w900,
                    height: 1.1,
                  ),
                ),
                Text(
                  'What SA is cooking right now',
                  style: text.labelSmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.search_rounded),
              tooltip: 'Search recipes',
              onPressed: () {},
            ),
            IconButton(
              icon: const Icon(Icons.notifications_none_rounded),
              tooltip: 'Notifications',
              onPressed: () {},
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Trending tags bar
// =============================================================================

class _TrendingTagsBar extends StatelessWidget {
  const _TrendingTagsBar({
    required this.tags,
    required this.activeIndex,
    required this.onTap,
  });

  final List<String> tags;
  final int          activeIndex;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text   = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 0, 8),
          child: Text(
            'Trending in SA',
            style: text.labelSmall?.copyWith(
              color: colors.onSurfaceVariant,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
            ),
          ),
        ),
        SizedBox(
          height: 40,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: tags.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              final isActive = i == activeIndex;
              return GestureDetector(
                onTap: () => onTap(i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeInOut,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: isActive ? colors.primary : colors.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    tags[i],
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: isActive ? colors.onPrimary : colors.onSurfaceVariant,
                      letterSpacing: 0.1,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 4),
        Divider(
          height: 1,
          color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ],
    );
  }
}

// =============================================================================
// Post card
// =============================================================================

class _PostCard extends StatelessWidget {
  const _PostCard({
    required this.post,
    required this.onLike,
    required this.onComment,
    required this.onSave,
    this.onEdit,
    this.onDelete,
    this.currentUserId,
  });

  final _PostData    post;
  final VoidCallback onLike;
  final VoidCallback onComment;
  final VoidCallback onSave;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final String?       currentUserId;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text   = Theme.of(context).textTheme;

    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: colors.outlineVariant.withValues(alpha: 0.7)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Post header ──────────────────────────────────────────────────
          _PostHeader(
            post:          post,
            onEdit:        onEdit,
            onDelete:      onDelete,
            currentUserId: currentUserId,
          ),

          // ── Dish image / photo ───────────────────────────────────────────
          // Prefer the public Supabase URL when available so every device sees
          // the same image. Fall back to the local file path only for the
          // optimistic in-flight post on the author's own device, then to the
          // gradient placeholder when no image source is set.
          _PostImage(
            path:        post.imageUrl ?? post.localImagePath,
            placeholder: _DishImagePlaceholder(
              gradientColors:         post.gradientColors,
              dishIcon:               post.dishIcon,
              recipeTitle:            post.recipeTitle,
              isLoadsheddingFriendly: post.isLoadsheddingFriendly,
            ),
          ),

          // ── Caption ──────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: Text(
              post.caption,
              style: text.bodyMedium?.copyWith(height: 1.55),
            ),
          ),

          // ── Tags ─────────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: post.tags
                  .map((tag) => _TagChip(tag: tag))
                  .toList(),
            ),
          ),

          // ── Divider ───────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Divider(
              height: 1,
              color: colors.outlineVariant.withValues(alpha: 0.5),
            ),
          ),

          // ── Action row ───────────────────────────────────────────────────
          _PostActions(
            post: post,
            onLike: onLike,
            onComment: onComment,
            onSave: onSave,
          ),

          const SizedBox(height: 4),
        ],
      ),
    );
  }
}

// =============================================================================
// Post header (avatar + name + timestamp)
// =============================================================================

class _PostHeader extends StatelessWidget {
  const _PostHeader({
    required this.post,
    this.onEdit,
    this.onDelete,
    this.currentUserId,
  });

  final _PostData     post;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final String?       currentUserId;

  bool get _isOwnPost =>
      (currentUserId != null &&
          post.authorUserId != null &&
          currentUserId == post.authorUserId) ||
      post.username == 'You';

  Future<void> _submitReport(BuildContext context) async {
    final db = Supabase.instance.client;
    try {
      await db.from('post_reports').insert({
        'post_id':     post.id,
        'reporter_id': db.auth.currentUser?.id,
        'reason':      'Community report',
        'reported_at': DateTime.now().toIso8601String(),
      });
    } catch (_) {}
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Post reported — our team will review it soon'),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> _showPostMenu(BuildContext context) async {
    // The sheet RETURNS a string tag for the user's choice; we dispatch the
    // real handler AFTER the sheet's pop animation settles. This avoids the
    // '_dependents.isEmpty is not true' framework assert that fires when
    // Navigator.pop and a synchronous follow-up showModalBottomSheet()/
    // showDialog() run in the same microtask — the dismissed sheet's
    // Element still carries live InheritedWidget dependents at the moment
    // the new route mounts.
    final action = await showModalBottomSheet<String>(
      context:            context,
      backgroundColor:    Colors.transparent,
      isScrollControlled: true,
      useRootNavigator:   true,
      builder: (sheetCtx) {
        final bottomInset = MediaQuery.of(sheetCtx).viewInsets.bottom;
        final bottomPad   = MediaQuery.of(sheetCtx).padding.bottom;
        return Padding(
          // Push the entire sheet up: nav bar (~60) + safe area + breathing room
          padding: EdgeInsets.only(
            bottom: bottomInset + bottomPad + 72,
          ),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color:        const Color(0xFFF4F1EA),
              borderRadius: BorderRadius.circular(24),
              boxShadow: const [
                BoxShadow(
                  color:      Color(0x22000000),
                  blurRadius: 24,
                  offset:     Offset(0, -4),
                ),
              ],
            ),
            padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
            child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Drag handle
              Center(
                child: Container(
                  width: 40, height: 4,
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE6E2D8),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              // Post title chip
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Row(
                  children: [
                    const Icon(Icons.restaurant_menu_rounded,
                        color: Color(0xFF0C351E), size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        post.recipeTitle,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize:   14,
                          color:      Color(0xFF0C351E),
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              const SizedBox(height: 4),
              if (_isOwnPost) ...[
                ListTile(
                  leading: const Icon(Icons.edit_rounded, color: Color(0xFF0C351E)),
                  title: const Text('Edit post',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                  onTap: () => Navigator.pop(sheetCtx, 'edit'),
                ),
                ListTile(
                  leading: const Icon(Icons.delete_outline_rounded,
                      color: Colors.redAccent),
                  title: const Text('Delete post',
                      style: TextStyle(fontWeight: FontWeight.w700,
                          color: Colors.redAccent)),
                  onTap: () => Navigator.pop(sheetCtx, 'delete'),
                ),
              ] else ...[
                ListTile(
                  leading: const Icon(Icons.flag_outlined, color: Colors.redAccent),
                  title: const Text('Report post',
                      style: TextStyle(fontWeight: FontWeight.w700,
                          color: Colors.redAccent)),
                  subtitle: const Text('Sent to ChowSA moderators',
                      style: TextStyle(fontSize: 12)),
                  onTap: () => Navigator.pop(sheetCtx, 'report'),
                ),
                ListTile(
                  leading: const Icon(Icons.block_rounded, color: Colors.redAccent),
                  title: const Text('Block user',
                      style: TextStyle(fontWeight: FontWeight.w700,
                          color: Colors.redAccent)),
                  subtitle: const Text(
                      "You won't see their posts or messages anywhere",
                      style: TextStyle(fontSize: 12)),
                  onTap: () => Navigator.pop(sheetCtx, 'block'),
                ),
              ],
              const SizedBox(height: 4),
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: () => Navigator.pop(sheetCtx),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                  child: const Text('Cancel',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
        ),
      );
      },
    );

    // Bottom sheet is fully dismissed; the widget tree has settled, so any
    // route push the handler does will mount cleanly.
    if (!context.mounted || action == null) return;
    switch (action) {
      case 'edit':
        onEdit?.call();
      case 'delete':
        onDelete?.call();
      case 'report':
        await _submitReport(context);
      case 'block':
        await _submitBlock(context);
    }
  }

  Future<void> _submitBlock(BuildContext context) async {
    final uid = post.authorUserId;
    if (uid == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Block user?'),
        content: const Text(
          "You won't see this user's posts or messages anywhere in ChowSA. "
          'You can undo this from Settings → Privacy → Blocked users.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Block'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ModerationService.instance.blockUser(uid);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('User blocked.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not block: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text   = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 8, 10),
      child: Row(
        children: [
          // Avatar
          CircleAvatar(
            radius: 20,
            backgroundColor: post.avatarColor,
            child: Text(
              post.initials,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: Colors.white,
              ),
            ),
          ),
          const SizedBox(width: 10),
          // Name + timestamp
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        post.username,
                        style: text.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 6),
                    // Per-user rank badge — pulls the title from the
                    // UserRankService cache and falls back to a lazy
                    // count fetch the first time a handle is seen.
                    // SumaraiJack / Melrose render their exclusive
                    // overrides instantly (no DB round-trip needed).
                    HandleRankBadge(handle: post.username),
                  ],
                ),
                Text(
                  post.timestamp,
                  style: text.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
          // Overflow menu
          IconButton(
            icon: Icon(
              Icons.more_horiz_rounded,
              color: colors.onSurfaceVariant,
            ),
            onPressed: () => _showPostMenu(context),
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// _PostImage — universal post-photo renderer
//
// Classifies the path string and routes to the correct image source:
//   • http:// or https://             → Image.network (in-memory cached)
//   • assets/...                      → Image.asset
//   • everything else                 → Image.file (local filesystem path)
//   • null OR error                   → [placeholder]
//
// The path-string classifier is deliberately broad so it covers any sensible
// platform path Flutter will hand us:
//   /data/user/0/...  (Android internal)
//   /storage/emulated/...  (Android external)
//   /var/mobile/.../cache/...  (iOS)
//   C:\Users\... or G:\Claude\... (Windows debug builds)
//   cache/..., data/... (legacy relative paths)
// =============================================================================

enum _PostImageKind { network, asset, local }

_PostImageKind _classifyImagePath(String path) {
  final p = path.trim();
  if (p.startsWith('http://') || p.startsWith('https://')) {
    return _PostImageKind.network;
  }
  if (p.startsWith('assets/') || p.startsWith('asset:')) {
    return _PostImageKind.asset;
  }
  // Anything else (absolute path, drive letter, or relative cache/data prefix)
  // is treated as a local file.
  return _PostImageKind.local;
}

class _PostImage extends StatelessWidget {
  const _PostImage({
    required this.path,
    required this.placeholder,
  });

  final String? path;
  final Widget  placeholder;
  static const double height = 220;

  @override
  Widget build(BuildContext context) {
    if (path == null || path!.trim().isEmpty) return placeholder;

    final kind = _classifyImagePath(path!);

    Widget img;
    switch (kind) {
      case _PostImageKind.network:
        img = Image.network(
          path!,
          fit:    BoxFit.cover,
          width:  double.infinity,
          height: height,
          // Loading state — show a thin progress indicator over the placeholder
          // so the post layout doesn't jump when the bytes arrive.
          loadingBuilder: (ctx, child, progress) {
            if (progress == null) return child;
            return Stack(
              fit: StackFit.expand,
              children: [
                placeholder,
                Container(
                  color: Colors.black.withAlpha(40),
                  alignment: Alignment.center,
                  child: const SizedBox(
                    width: 28, height: 28,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5, color: Colors.white),
                  ),
                ),
              ],
            );
          },
          errorBuilder: (_, __, ___) => placeholder,
        );
        break;

      case _PostImageKind.asset:
        img = Image.asset(
          path!,
          fit:    BoxFit.cover,
          width:  double.infinity,
          height: height,
          errorBuilder: (_, __, ___) => placeholder,
        );
        break;

      case _PostImageKind.local:
        // Guard: if the file is gone (e.g., user cleared app storage), fall
        // back to the gradient placeholder rather than crashing.
        final file = File(path!);
        if (!file.existsSync()) return placeholder;
        img = Image.file(
          file,
          fit:    BoxFit.cover,
          width:  double.infinity,
          height: height,
          errorBuilder: (_, __, ___) => placeholder,
        );
        break;
    }

    return SizedBox(height: height, width: double.infinity, child: img);
  }
}

// =============================================================================
// Dish image placeholder
// =============================================================================

class _DishImagePlaceholder extends StatelessWidget {
  const _DishImagePlaceholder({
    required this.gradientColors,
    required this.dishIcon,
    required this.recipeTitle,
    required this.isLoadsheddingFriendly,
  });

  final List<Color> gradientColors;
  final IconData    dishIcon;
  final String      recipeTitle;
  final bool        isLoadsheddingFriendly;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return SizedBox(
      height: 220,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // ── Gradient background ──────────────────────────────────────────
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: gradientColors,
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
          ),

          // ── Decorative bokeh circles (simulate food photography depth) ───
          ..._buildBokehCircles(),

          // ── Centre dish icon ─────────────────────────────────────────────
          Center(
            child: Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.15),
                shape: BoxShape.circle,
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.3),
                  width: 1.5,
                ),
              ),
              child: Icon(dishIcon, color: Colors.white, size: 42),
            ),
          ),

          // ── Bottom frosted overlay: recipe title + loadshedding badge ────
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.fromLTRB(14, 24, 14, 12),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.transparent, Color(0xCC000000)],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      recipeTitle,
                      style: text.titleSmall?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        shadows: [
                          const Shadow(
                            color: Colors.black38,
                            blurRadius: 4,
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (isLoadsheddingFriendly) ...[
                    const SizedBox(width: 8),
                    _LoadsheddingMicroBadge(friendly: true),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Scatter soft translucent circles to simulate out-of-focus bokeh.
  List<Widget> _buildBokehCircles() {
    final specs = [
      _BokehSpec(left: -20,  top: 20,   size: 120, opacity: 0.08),
      _BokehSpec(right: -10, top: 40,   size: 90,  opacity: 0.10),
      _BokehSpec(left: 60,   bottom: 10,size: 100, opacity: 0.07),
      _BokehSpec(right: 30,  bottom: 20,size: 140, opacity: 0.06),
    ];

    return specs.map((s) {
      return Positioned(
        left:   s.left,
        right:  s.right,
        top:    s.top,
        bottom: s.bottom,
        child: Container(
          width: s.size,
          height: s.size,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: s.opacity ?? 1.0),
            shape: BoxShape.circle,
          ),
        ),
      );
    }).toList();
  }
}

class _BokehSpec {
  final double? left, right, top, bottom, size, opacity;
  const _BokehSpec({
    this.left, this.right, this.top, this.bottom,
    required this.size, required this.opacity,
  });
}

// =============================================================================
// Loadshedding micro-badge (image overlay variant)
// =============================================================================

class _LoadsheddingMicroBadge extends StatelessWidget {
  const _LoadsheddingMicroBadge({required this.friendly});

  final bool friendly;

  @override
  Widget build(BuildContext context) {
    final bg    = friendly ? const Color(0xFF0C351E) : const Color(0xFF2C2C2E);
    final fg    = friendly ? const Color(0xFF6FCF97) : const Color(0xFF98989F);
    final icon  = friendly
        ? Icons.local_fire_department_rounded
        : Icons.bolt_rounded;
    final label = friendly ? 'Braai Ready' : 'Needs Power';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: fg, size: 11),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: fg,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Tag chip
// =============================================================================

class _TagChip extends StatelessWidget {
  const _TagChip({required this.tag});

  final String tag;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: colors.secondaryContainer.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        tag,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: colors.onSecondaryContainer,
        ),
      ),
    );
  }
}

// =============================================================================
// Post actions (like / comment / save)
// =============================================================================

class _PostActions extends StatelessWidget {
  const _PostActions({
    required this.post,
    required this.onLike,
    required this.onComment,
    required this.onSave,
  });

  final _PostData    post;
  final VoidCallback onLike;
  final VoidCallback onComment;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          // ── Like counter ──────────────────────────────────────────────────
          // Reads from post.likeCount, which is updated by the screen-level
          // `public:feed_updates` channel callback in _FeedRealtimeMixin.
          // That callback uses copyWith() to REPLACE the post instance in
          // _posts, so the ListView.builder diff picks up the change and
          // this _ActionButton rebuilds with the new count.
          _ActionButton(
            icon: post.isLiked
                ? Icons.favorite_rounded
                : Icons.favorite_border_rounded,
            label: '${post.likeCount}',
            color: post.isLiked ? Colors.redAccent : colors.onSurfaceVariant,
            onTap: onLike,
          ),
          const SizedBox(width: 4),

          // ── Comment counter — same pattern ────────────────────────────────
          _ActionButton(
            icon:  Icons.mode_comment_outlined,
            label: '${post.commentCount}',
            color: colors.onSurfaceVariant,
            onTap: onComment,
          ),

          const Spacer(),

          // ── Save to My Recipes ────────────────────────────────────────────
          SaveBounceButton(
            isSaved: post.isSaved,
            onTap:   onSave,
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// _ActionButton — Like / Comment counter button
// =============================================================================
//
// Counters are NOT subscribed to Realtime directly. The screen-level channel
// `public:feed_updates` (see _subscribeToNewPosts in _CommunityFeedScreenState)
// receives every INSERT/DELETE on post_likes + post_comments and triggers a
// setState() that replaces the affected _PostData via copyWith(). That
// reference change makes ListView.builder rebuild the row, which rebuilds
// this _ActionButton with the new label.

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final IconData     icon;
  final String       label;
  final Color        color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(width: 5),
            Text(
              label,
              style: text.bodySmall?.copyWith(
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// _CommentSheet — comment input and display for a post
// =============================================================================

class _CommentSheet extends StatefulWidget {
  const _CommentSheet({required this.post, required this.onCommentAdded});
  final _PostData post;
  final void Function(String) onCommentAdded;

  @override
  State<_CommentSheet> createState() => _CommentSheetState();
}

class _CommentSheetState extends State<_CommentSheet> {
  final _ctrl  = TextEditingController();
  final _focus = FocusNode();
  final List<Map<String, String>> _comments = [];
  bool _loadingComments = true;

  SupabaseClient get _db => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _loadComments();
  }

  Future<void> _loadComments() async {
    try {
      final rows = await _db
          .from('post_comments')
          .select('handle, body, created_at')
          .eq('post_id', widget.post.id)
          .order('created_at', ascending: true);
      if (!mounted) return;
      setState(() {
        _comments.addAll((rows as List).map((r) => {
          'author': r['handle'] as String,
          'text':   r['body']   as String,
        }));
        _loadingComments = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingComments = false);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submit() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;

    final user   = _db.auth.currentUser;
    final handle = user?.userMetadata?['handle'] as String?
        ?? user?.email?.split('@').first
        ?? 'Chef';
    final initials = handle.length >= 2
        ? handle.substring(0, 2).toUpperCase()
        : handle.toUpperCase();

    // Optimistic
    setState(() => _comments.add({'author': handle, 'text': text}));
    widget.onCommentAdded(text);
    _ctrl.clear();
    _focus.requestFocus();

    try {
      await _db.from('post_comments').insert({
        'post_id':  widget.post.id,
        'user_id':  user?.id,
        'handle':   handle,
        'initials': initials,
        'body':     text,
      });
    } catch (_) {/* comment already shown locally */}
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom +
        MediaQuery.of(context).padding.bottom;
    return Container(
      padding: EdgeInsets.fromLTRB(20, 20, 20, bottom + 16),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.75,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFFF4F1EA),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Handle
          Center(
            child: Container(
              width: 40, height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: const Color(0xFFE6E2D8),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Text(
            'Comments on "${widget.post.recipeTitle}"',
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: Color(0xFF0C351E),
            ),
          ),
          const SizedBox(height: 12),
          if (_loadingComments)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_comments.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: Text('No comments yet — be the first! 👇',
                    style: TextStyle(color: null)),
              ),
            )
          else
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: _comments.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (_, i) {
                  final c = _comments[i];
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      CircleAvatar(
                        radius: 16,
                        backgroundColor: const Color(0xFF0C351E),
                        child: Text(
                          (c['author'] ?? 'U').substring(0, 1).toUpperCase(),
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w800),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(c['author'] ?? '',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 12,
                                      color: Color(0xFF0C351E))),
                              const SizedBox(height: 2),
                              Text(c['text'] ?? '',
                                  style: const TextStyle(fontSize: 13)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: MentionSuggestionField(
                  controller: _ctrl,
                  focusNode: _focus,
                  autofocus: true,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _submit(),
                  decoration: InputDecoration(
                    hintText: 'Add a comment… use @ to tag',
                    filled: true,
                    fillColor: Colors.white,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
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
                  backgroundColor: const Color(0xFF0C351E),
                  minimumSize: const Size(52, 52),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                child: const Icon(Icons.send_rounded, size: 18),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// _ShareChowSheet — lets the user share a recipe post to the community feed
// =============================================================================

class _ShareChowSheet extends StatefulWidget {
  const _ShareChowSheet({
    this.onPosted,
    this.editingPost,
    this.onUpdated,
  });
  // Create mode — fired with a brand-new _PostData when no editingPost given.
  final void Function(_PostData post)? onPosted;

  // Edit mode — when non-null, the sheet pre-populates from this post and
  // the submit button reads "Update Post" instead of "Post to Community".
  final _PostData? editingPost;
  final void Function(_PostData updated)? onUpdated;

  @override
  State<_ShareChowSheet> createState() => _ShareChowSheetState();
}

class _ShareChowSheetState extends State<_ShareChowSheet> {
  final _titleCtrl   = TextEditingController();
  final _captionCtrl = TextEditingController();
  final _picker      = ImagePicker();
  bool  _submitted   = false;
  XFile? _pickedImage;
  bool  _pickingImage = false;

  /// Remote image URL we inherited from the editingPost. Used for the preview
  /// thumbnail when the user hasn't picked a new local image yet. Cleared
  /// when the user taps × on the preview, signalling "remove the image".
  String? _existingImageUrl;

  static const _kForest = Color(0xFF0C351E);
  static const _kOrange = Color(0xFFE59B27);
  static const _kCream  = Color(0xFFF4F1EA);

  static const _kTags = [
    '#BraaiBroodjies',
    '#WinterWarmers',
    '#PotjieMaster',
    '#BudgetMeals',
    '#LoadsheddingCooking',
    '#KapseKos',
  ];

  final Set<String> _selectedTags = {};

  /// True when this sheet is opened against an existing post.
  bool get _isEditing => widget.editingPost != null;

  @override
  void initState() {
    super.initState();
    // ── Pre-populate every form field from the editingPost ──────────────────
    final edit = widget.editingPost;
    if (edit != null) {
      _titleCtrl.text   = edit.recipeTitle;
      _captionCtrl.text = edit.caption;
      _selectedTags.addAll(edit.tags);
      _existingImageUrl = edit.imageUrl;
    }
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _captionCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    if (_pickingImage) return;
    setState(() => _pickingImage = true);
    try {
      final source = await showModalBottomSheet<ImageSource>(
        context: context,
        backgroundColor: Colors.transparent,
        builder: (_) => Container(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          decoration: const BoxDecoration(
            color: Color(0xFFF4F1EA),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(color: const Color(0xFFE6E2D8), borderRadius: BorderRadius.circular(2))),
              ListTile(
                leading: const Icon(Icons.camera_alt_rounded, color: Color(0xFF0C351E)),
                title: const Text('Take a photo', style: TextStyle(fontWeight: FontWeight.w700)),
                onTap: () => Navigator.pop(context, ImageSource.camera),
              ),
              ListTile(
                leading: const Icon(Icons.photo_library_rounded, color: Color(0xFF0C351E)),
                title: const Text('Choose from gallery', style: TextStyle(fontWeight: FontWeight.w700)),
                onTap: () => Navigator.pop(context, ImageSource.gallery),
              ),
            ],
          ),
        ),
      );
      if (source == null) { setState(() => _pickingImage = false); return; }
      final file = await _picker.pickImage(source: source, imageQuality: 80, maxWidth: 1280);
      if (mounted) setState(() { _pickedImage = file; _pickingImage = false; });
    } catch (e) {
      if (mounted) {
        setState(() => _pickingImage = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open camera: $e'),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
        );
      }
    }
  }

  bool _posting = false;

  void _flashError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        backgroundColor: const Color(0xFFC62828),
        behavior:        SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  Future<void> _submit() async {
    // ── Field validation — surface feedback instead of silently bailing ──────
    if (_titleCtrl.text.trim().isEmpty) {
      _flashError('Give your chow a name first, chom.');
      return;
    }
    if (_posting) return;  // guard against double-tap
    setState(() => _posting = true);

    // ── EDIT MODE — Supabase UPDATE against the existing row ────────────────
    if (_isEditing) {
      await _submitEdit();
      return;
    }

    // ── Image persistence ───────────────────────────────────────────────────
    // Copy the picked image into permanent app-documents storage. If the copy
    // fails AND we can't get a usable fallback, we abort the submit rather
    // than silently posting a broken image reference.
    String? permanentImagePath;
    if (_pickedImage != null) {
      try {
        final appDir = await getApplicationDocumentsDirectory();
        final fname  = 'chow_post_${DateTime.now().millisecondsSinceEpoch}.jpg';
        final dest   = File('${appDir.path}/$fname');
        await dest.writeAsBytes(await _pickedImage!.readAsBytes());
        // Verify the file landed before we trust the path.
        if (!await dest.exists()) {
          throw const FileSystemException('write_succeeded_but_file_missing');
        }
        permanentImagePath = dest.path;
      } catch (e) {
        // Last-resort fallback: use the original XFile path if it still
        // exists on disk. Otherwise abort with a clear error.
        final fallback = File(_pickedImage!.path);
        if (await fallback.exists()) {
          permanentImagePath = _pickedImage!.path;
        } else {
          if (!mounted) return;
          setState(() => _posting = false);
          _flashError(
              'Could not attach the photo. Pick it again or post without one.');
          return;
        }
      }
    }

    if (!mounted) return;

    // Build a real _PostData and hand it to the parent feed
    final avatarColors = [
      const Color(0xFF1565C0), const Color(0xFF2E7D32),
      const Color(0xFF6A1B9A), const Color(0xFFBF360C),
    ];
    final icons = [
      Icons.outdoor_grill_rounded, Icons.restaurant_rounded,
      Icons.local_fire_department_rounded, Icons.soup_kitchen_rounded,
    ];
    final gradients = [
      [const Color(0xFFBF360C), const Color(0xFFFF8F00)],
      [const Color(0xFF1B5E20), const Color(0xFF4CAF50)],
      [const Color(0xFF4A148C), const Color(0xFF9C27B0)],
    ];
    final rng = DateTime.now().millisecondsSinceEpoch;
    final handle = _titleCtrl.text.trim();
    final newPost = _PostData(
      id:           'user_${rng}',
      username:     'You',
      initials:     handle.length >= 2
          ? handle.substring(0, 2).toUpperCase()
          : handle.toUpperCase(),
      avatarColor:  avatarColors[rng % avatarColors.length],
      timestamp:    'Just now',
      recipeTitle:  handle,
      caption:      _captionCtrl.text.trim().isEmpty
          ? 'Check out this recipe I made! 🔥'
          : _captionCtrl.text.trim(),
      tags:         _selectedTags.toList(),
      likeCount:    0,
      commentCount: 0,
      gradientColors: gradients[rng % gradients.length]
          .cast<Color>(),
      dishIcon:     icons[rng % icons.length],
      isLoadsheddingFriendly: false,
      localImagePath: permanentImagePath,
      authorUserId: Supabase.instance.client.auth.currentUser?.id,
    );
    widget.onPosted?.call(newPost);
    if (mounted) {
      setState(() {
        _posting   = false;
        _submitted = true;
      });
    }
  }

  // ── EDIT submit — Supabase UPDATE for the targeted post row ───────────────
  // Persists the title / caption / tags edits straight to the community_posts
  // row matching widget.editingPost.id. Image uploads on edit are intentionally
  // out of scope for this pass (the spec didn't request re-uploading a new
  // photo on edit), but the path is here if you want to add it later — same
  // upload + getPublicUrl pattern used by the create flow.
  Future<void> _submitEdit() async {
    final editing = widget.editingPost!;
    final newTitle   = _titleCtrl.text.trim();
    final newCaption = _captionCtrl.text.trim().isEmpty
        ? 'Check out this recipe I made! 🔥'
        : _captionCtrl.text.trim();
    final newTags = _selectedTags.toList();

    try {
      await Supabase.instance.client
          .from('community_posts')
          .update({
            'recipe_title': newTitle,
            'caption':      newCaption,
            'tags':         newTags,
          })
          .eq('id', editing.id);
    } catch (e) {
      // Re-check mounted AFTER the await so we never touch a disposed
      // Element if the user dismissed the sheet mid-update.
      if (!mounted) return;
      setState(() => _posting = false);
      _flashError("Couldn't save changes: $e");
      return;
    }

    // Re-check mounted AFTER the network await — same lifecycle safety as
    // the catch branch above.
    if (!mounted) return;

    // Build the patched _PostData and hand it to the parent so it can swap
    // the existing list entry in place without waiting for a Realtime refresh.
    final updated = _PostData(
      id:                     editing.id,
      username:               editing.username,
      initials:               editing.initials,
      avatarColor:            editing.avatarColor,
      timestamp:              editing.timestamp,
      recipeTitle:            newTitle,
      caption:                newCaption,
      tags:                   newTags,
      likeCount:              editing.likeCount,
      commentCount:           editing.commentCount,
      gradientColors:         editing.gradientColors,
      dishIcon:               editing.dishIcon,
      isLoadsheddingFriendly: editing.isLoadsheddingFriendly,
      isLiked:                editing.isLiked,
      isSaved:                editing.isSaved,
      localImagePath:         editing.localImagePath,
      imageUrl:               editing.imageUrl,
      authorUserId:           editing.authorUserId,
      suburbDistrict:         editing.suburbDistrict,
      city:                   editing.city,
    );

    // Flip our own state FIRST so the sheet swaps to the thank-you panel
    // immediately, then defer the parent's setState to the next frame via
    // addPostFrameCallback. This prevents the parent feed's _posts[idx] =
    // updated rebuild from racing against the sheet's own rebuild during
    // an in-flight modal animation — which was the trigger for the
    // _dependents.isEmpty assert.
    setState(() {
      _posting   = false;
      _submitted = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Parent may have unmounted while we waited for the next frame.
      // Calling onUpdated against a disposed feed is harmless (the
      // callback's setState is guarded), but the post-frame deferral is
      // what actually prevents the crash.
      widget.onUpdated?.call(updated);
    });
  }

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
      padding: EdgeInsets.fromLTRB(24, 24, 24, bottom + 24),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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

            if (_submitted) ...[
              // ── Thank-you state ──────────────────────────────────────────
              Center(
                child: Column(
                  children: [
                    Container(
                      width:  72,
                      height: 72,
                      decoration: BoxDecoration(
                        color:        _kForest.withAlpha(20),
                        borderRadius: BorderRadius.circular(22),
                        border:       Border.all(color: _kForest.withAlpha(50)),
                      ),
                      child: const Icon(Icons.check_circle_rounded,
                          color: _kForest, size: 38),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _isEditing ? 'Post updated! ✅' : 'Chow shared! 🔥',
                      style: tt.titleMedium?.copyWith(
                        fontWeight: FontWeight.w900,
                        color:      _kForest,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _isEditing
                          ? 'Your changes are live on the\nChowSA community feed.'
                          : 'Your recipe has been submitted to the\nChowSA community feed.',
                      textAlign: TextAlign.center,
                      style: tt.bodySmall?.copyWith(
                        color: null,
                        height: 1.6,
                      ),
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: () => Navigator.pop(context),
                        style: FilledButton.styleFrom(
                          backgroundColor: _kForest,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16)),
                        ),
                        child: const Text(
                          'Back to Community',
                          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ] else ...[
              // ── Form ──────────────────────────────────────────────────────
              Row(
                children: [
                  GestureDetector(
                    onTap: _pickPhoto,
                    child: Container(
                      width: 40, height: 40,
                      decoration: BoxDecoration(
                        color:        _kOrange,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: _pickingImage
                          ? const Padding(
                              padding: EdgeInsets.all(10),
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.add_a_photo_rounded,
                              color: Colors.white, size: 20),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    _isEditing ? 'Edit your Chow' : 'Share a Chow',
                    style: tt.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color:      _kForest,
                    ),
                  ),
                ],
              ),

              // ── Photo preview ──────────────────────────────────────────────
              // Priority: freshly-picked local file > existing remote URL from
              // the post being edited > empty "add photo" placeholder.
              if (_pickedImage != null) ...[
                const SizedBox(height: 12),
                Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: Image.file(
                        File(_pickedImage!.path),
                        height: 160, width: double.infinity,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          height: 80,
                          decoration: BoxDecoration(
                            color: _kForest.withAlpha(20),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: const Center(child: Icon(Icons.image_rounded, color: _kForest, size: 32)),
                        ),
                      ),
                    ),
                    Positioned(
                      top: 8, right: 8,
                      child: GestureDetector(
                        onTap: () => setState(() => _pickedImage = null),
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
                          child: const Icon(Icons.close_rounded, color: Colors.white, size: 16),
                        ),
                      ),
                    ),
                  ],
                ),
              ] else if (_existingImageUrl != null && _existingImageUrl!.isNotEmpty) ...[
                const SizedBox(height: 12),
                Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: Image.network(
                        _existingImageUrl!,
                        height: 160, width: double.infinity,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          height: 80,
                          decoration: BoxDecoration(
                            color: _kForest.withAlpha(20),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: const Center(child: Icon(Icons.image_rounded, color: _kForest, size: 32)),
                        ),
                      ),
                    ),
                    // "Replace photo" CTA — lets the user swap the existing
                    // image for a fresh pick (XFile takes over the preview).
                    Positioned(
                      bottom: 8, right: 8,
                      child: GestureDetector(
                        onTap: _pickPhoto,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.swap_horiz_rounded,
                                  color: Colors.white, size: 14),
                              SizedBox(width: 4),
                              Text('Replace',
                                  style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ] else ...[
                const SizedBox(height: 12),
                GestureDetector(
                  onTap: _pickPhoto,
                  child: Container(
                    height: 80,
                    decoration: BoxDecoration(
                      color:        _kForest.withAlpha(10),
                      borderRadius: BorderRadius.circular(14),
                      border:       Border.all(color: _kForest.withAlpha(40), style: BorderStyle.solid),
                    ),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.add_photo_alternate_outlined, color: _kForest.withAlpha(180), size: 28),
                          const SizedBox(height: 4),
                          Text('Add a photo (optional)',
                            style: TextStyle(color: _kForest.withAlpha(160), fontSize: 12, fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ),
                  ),
                ),
              ],

              Text('Recipe title *',
                  style: tt.labelMedium?.copyWith(
                    fontWeight: FontWeight.w700, color: _kForest)),
              const SizedBox(height: 8),
              TextField(
                controller: _titleCtrl,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  hintText: 'e.g. Boerewors Rolls with Chakalaka',
                  filled:   true,
                  fillColor: Colors.white,
                  contentPadding:
                      const EdgeInsets.fromLTRB(16, 14, 16, 14),
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
                    borderSide:   const BorderSide(color: _kForest, width: 1.5),
                  ),
                ),
              ),

              const SizedBox(height: 16),

              Text('Caption',
                  style: tt.labelMedium?.copyWith(
                    fontWeight: FontWeight.w700, color: _kForest)),
              const SizedBox(height: 8),
              MentionSuggestionField(
                controller: _captionCtrl,
                maxLines:   3,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: 'Tell the community about this dish… use @ to tag',
                  filled:   true,
                  fillColor: Colors.white,
                  contentPadding: const EdgeInsets.all(14),
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
                    borderSide:   const BorderSide(color: _kForest, width: 1.5),
                  ),
                ),
              ),

              const SizedBox(height: 16),

              Text('Tags',
                  style: tt.labelMedium?.copyWith(
                    fontWeight: FontWeight.w700, color: _kForest)),
              const SizedBox(height: 8),
              Wrap(
                spacing:    8,
                runSpacing: 8,
                children: _kTags.map((tag) {
                  final selected = _selectedTags.contains(tag);
                  return GestureDetector(
                    onTap: () => setState(() {
                      if (selected) _selectedTags.remove(tag);
                      else _selectedTags.add(tag);
                    }),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 7),
                      decoration: BoxDecoration(
                        color:        selected
                            ? _kForest
                            : _kForest.withAlpha(12),
                        borderRadius: BorderRadius.circular(22),
                        border:       Border.all(
                          color: selected
                              ? _kForest
                              : _kForest.withAlpha(40),
                        ),
                      ),
                      child: Text(
                        tag,
                        style: TextStyle(
                          fontSize:   13,
                          fontWeight: FontWeight.w600,
                          color:      selected
                              ? Colors.white
                              : _kForest,
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),

              const SizedBox(height: 24),

              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  // Disabled while a post is in-flight to prevent double-submits
                  // that would persist the same image twice.
                  onPressed: _posting ? null : _submit,
                  icon: _posting
                      ? const SizedBox(
                          width: 18, height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2.5, color: Colors.white),
                        )
                      : Icon(
                          _isEditing
                              ? Icons.check_rounded
                              : Icons.local_fire_department_rounded,
                          size: 18,
                        ),
                  label: Text(
                    _posting
                        ? (_isEditing ? 'Updating…' : 'Posting…')
                        : (_isEditing ? 'Update Post' : 'Post to Community'),
                    style: const TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 15),
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: _kOrange,
                    disabledBackgroundColor: _kOrange.withAlpha(140),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape:   RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
