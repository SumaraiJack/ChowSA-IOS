// lib/services/friends_service.dart
//
// Social-graph backend for ChowSA. Powers the Kitchen Circle screen and
// the share-list autocomplete.
//
// Required Supabase schema (run once):
//
//   create table friendships (
//     id           uuid primary key default gen_random_uuid(),
//     requester_id uuid not null references profiles(id) on delete cascade,
//     receiver_id  uuid not null references profiles(id) on delete cascade,
//     status       text not null check (status in ('pending','accepted')),
//     created_at   timestamptz not null default now(),
//     unique (requester_id, receiver_id)
//   );
//   alter table friendships enable row level security;
//
//   -- Either party can read their edges
//   create policy "see_own_edges" on friendships for select to authenticated
//     using (auth.uid() = requester_id or auth.uid() = receiver_id);
//   -- Anyone authenticated can invite
//   create policy "send_invite"  on friendships for insert to authenticated
//     with check (auth.uid() = requester_id);
//   -- Only the receiver can flip a row to accepted
//   create policy "accept"       on friendships for update to authenticated
//     using (auth.uid() = receiver_id);
//   -- Either party can break the friendship / cancel a pending invite
//   create policy "remove"       on friendships for delete to authenticated
//     using (auth.uid() = requester_id or auth.uid() = receiver_id);
//
// Realtime: add `friendships` to the supabase_realtime publication so the
// pending-requests badge updates instantly.

import 'package:supabase_flutter/supabase_flutter.dart';
import 'moderation_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Lightweight Profile model (just what the social-graph screens need)
// ─────────────────────────────────────────────────────────────────────────────

class FriendProfile {
  const FriendProfile({
    required this.id,
    required this.handle,
    this.displayName,
    this.email,
    this.avatarUrl,
  });

  final String  id;
  final String  handle;
  final String? displayName;
  final String? email;
  final String? avatarUrl;

  /// Two-letter initials for the avatar circle when no avatarUrl is set.
  String get initials {
    final source = (displayName?.isNotEmpty ?? false) ? displayName! : handle;
    final parts = source.trim().split(RegExp(r'\s+|_|-'));
    if (parts.isEmpty) return '?';
    if (parts.length == 1) {
      return parts.first.substring(0, parts.first.length >= 2 ? 2 : 1)
          .toUpperCase();
    }
    return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
  }

  factory FriendProfile.fromRow(Map<String, dynamic> r) => FriendProfile(
    id:          r['id']           as String,
    handle:      (r['handle']      as String?) ?? '',
    displayName: r['display_name'] as String?,
    email:       r['email']        as String?,
    avatarUrl:   r['avatar_url']   as String?,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Friendship row enums + struct
// ─────────────────────────────────────────────────────────────────────────────

enum FriendshipStatus { pending, accepted }

class Friendship {
  Friendship({
    required this.id,
    required this.requesterId,
    required this.receiverId,
    required this.status,
    required this.other,
    required this.createdAt,
  });

  final String           id;
  final String           requesterId;
  final String           receiverId;
  final FriendshipStatus status;
  /// The "other" party — i.e. the friend from the current user's perspective.
  final FriendProfile    other;
  final DateTime         createdAt;
}

// ─────────────────────────────────────────────────────────────────────────────
// Service
// ─────────────────────────────────────────────────────────────────────────────

class FriendsService {
  FriendsService._();
  static final FriendsService instance = FriendsService._();

  SupabaseClient get _db  => Supabase.instance.client;
  String?        get _uid => _db.auth.currentUser?.id;

  // ── User search ──────────────────────────────────────────────────────────────
  /// Search the profiles table by **username** substring (case-insensitive).
  /// Leading `@` characters are stripped from [query] before the DB call so
  /// typing "@mel" finds the same rows as typing "mel".
  /// Excludes the current user from results.
  Future<List<FriendProfile>> searchUsers(String query) async {
    // Sanitise per spec — strip an accidental '@' and trim whitespace so the
    // pattern "@mel" still matches usernames containing "mel". This is the
    // autocomplete path, so we deliberately wrap the cleaned token in
    // %wildcards% for a substring match (not the exact-match form used by
    // the single-recipient lookup in shared_assets_service.dart).
    final String cleanQuery = query.replaceFirst('@', '').trim();
    if (cleanQuery.length < 2) return [];
    try {
      final rows = await _db
          .from('profiles')
          .select('id, handle, display_name, email, avatar_url')
          .ilike('username', '%$cleanQuery%')   // case-insensitive substring
          .limit(20);
      final me      = _uid;
      // Exclude anyone in a block relationship with the current user
      // in EITHER direction — searches for sending invites or @mentions
      // should never surface a blocked or blocking account.
      final blocked = await ModerationService.instance
          .blockedIdsEitherDirection();
      return (rows as List)
          .map((r) => FriendProfile.fromRow(r as Map<String, dynamic>))
          .where((p) => p.id != me && !blocked.contains(p.id))
          .toList();
    } catch (_) {
      return [];
    }
  }

  // ── Invite ──────────────────────────────────────────────────────────────────
  /// Sends a friend invitation by inserting a `status='pending'` row.
  /// Throws if not authenticated, if the row already exists, or on RLS failure.
  Future<void> inviteFriend(String receiverId) async {
    final me = _uid;
    if (me == null) {
      throw const _NotAuthenticated();
    }
    if (me == receiverId) {
      throw _SelfInvite();
    }
    // Block check happens client-side BEFORE the insert so we can throw
    // a clean, user-facing error instead of leaning on an RLS denial
    // (which would surface as a cryptic 42501 PostgrestException).
    // The DB-side guarantee still holds via the moderation service's
    // own checks — this is just the UX layer.
    final blocked = await ModerationService.instance
        .blockedIdsEitherDirection();
    if (blocked.contains(receiverId)) {
      throw const _BlockedInviteAttempt();
    }
    await _db.from('friendships').insert({
      'requester_id': me,
      'receiver_id':  receiverId,
      'status':       'pending',
    });
  }

  /// Accepts a pending request (only the receiver can do this — RLS gated).
  Future<void> acceptFriend(String friendshipId) async {
    await _db.from('friendships')
        .update({'status': 'accepted'})
        .eq('id', friendshipId);
  }

  /// Removes a friendship row entirely (decline a pending invite, or unfriend
  /// an accepted one). RLS allows either party.
  Future<void> removeFriend(String friendshipId) async {
    await _db.from('friendships').delete().eq('id', friendshipId);
  }

  // ── List queries ────────────────────────────────────────────────────────────

  /// All accepted friends from the current user's perspective.
  /// The `other` field is always the FRIEND, never the current user.
  Future<List<Friendship>> loadAcceptedFriends() async {
    return _loadFriendships(status: 'accepted');
  }

  /// All incoming pending requests — i.e. someone invited the current user.
  ///
  /// Embedded `requester:requester_id(...)` joins on `profiles` are blocked
  /// by the row-level read policy (auth.uid() = id), so we fetch the
  /// friendship rows naked and hydrate each requester's public profile via
  /// the `get_public_profile` SECURITY DEFINER RPC.
  Future<List<Friendship>> loadPendingIncoming() async {
    final me = _uid;
    if (me == null) return [];
    try {
      final rows = await _db
          .from('friendships')
          .select('id, requester_id, receiver_id, status, created_at')
          .eq('receiver_id', me)
          .eq('status', 'pending')
          .order('created_at', ascending: false);
      final list = <Friendship>[];
      for (final r in (rows as List)) {
        final m = r as Map<String, dynamic>;
        final reqId = m['requester_id'] as String;
        final other = await _resolvePublicProfile(reqId);
        list.add(Friendship(
          id:          m['id']           as String,
          requesterId: reqId,
          receiverId:  m['receiver_id']  as String,
          status:      FriendshipStatus.pending,
          other:       other,
          createdAt:   DateTime.parse(m['created_at'] as String),
        ));
      }
      return list;
    } catch (_) {
      return [];
    }
  }

  /// Calls `get_public_profile(uid)` and returns a [FriendProfile]. Falls
  /// back to a placeholder when the RPC returns no row (deleted user, etc.).
  Future<FriendProfile> _resolvePublicProfile(String uid) async {
    try {
      final res = await _db
          .rpc('get_public_profile', params: {'uid': uid});
      Map<String, dynamic>? row;
      if (res is List && res.isNotEmpty) {
        row = Map<String, dynamic>.from(res.first as Map);
      } else if (res is Map) {
        row = Map<String, dynamic>.from(res);
      }
      if (row != null) return FriendProfile.fromRow(row);
    } catch (_) {/* swallow — fall through */}
    return FriendProfile(id: uid, handle: 'chow mate');
  }

  /// Stream of accepted friends — bumps when any friendship is added/removed.
  Stream<List<Friendship>> streamAcceptedFriends() async* {
    yield await loadAcceptedFriends();
    // For instant updates we'd want a Realtime stream — for now we re-load on
    // every emission of the underlying table stream. Cheap enough for the
    // expected friend list size.
    final me = _uid;
    if (me == null) return;
    final tableStream = _db
        .from('friendships')
        .stream(primaryKey: ['id'])
        .order('created_at');
    await for (final _ in tableStream) {
      yield await loadAcceptedFriends();
    }
  }

  /// Number of pending incoming invitations — used by the Profile screen
  /// badge on the "My Kitchen Circle" tile.
  Future<int> pendingIncomingCount() async {
    final me = _uid;
    if (me == null) return 0;
    try {
      final res = await _db
          .from('friendships')
          .select('id')
          .eq('receiver_id', me)
          .eq('status', 'pending')
          .count(CountOption.exact);
      return res.count;
    } catch (_) {
      return 0;
    }
  }

  /// Live stream of the same count. Re-emits whenever any friendship row
  /// involving the current user changes — invites arriving, the receiver
  /// accepting (status → 'accepted'), or either side deleting. Used by the
  /// Profile-tab badge so the unread number drops to zero the instant the
  /// user accepts in another screen, without forcing a tab rebuild.
  ///
  /// Implementation note: Supabase Realtime table streams only accept ONE
  /// server-side filter, so we filter by `receiver_id = me` and do the
  /// `status = 'pending'` cut on the client. The set is tiny (incoming
  /// invites for one user), so the cost is negligible.
  Stream<int> streamPendingIncomingCount() async* {
    final me = _uid;
    if (me == null) {
      yield 0;
      return;
    }
    // Emit the truth from a one-shot count first so the badge paints
    // correctly during the brief window before the realtime channel is
    // ready (avoids a 0 flicker on cold start).
    yield await pendingIncomingCount();

    try {
      final tableStream = _db
          .from('friendships')
          .stream(primaryKey: ['id'])
          .eq('receiver_id', me);

      await for (final rows in tableStream) {
        yield rows.where((r) => r['status'] == 'pending').length;
      }
    } catch (_) {
      // Realtime channel failed (network drop, duplicate-subscribe race,
      // table not in publication). Degrade silently — the badge keeps the
      // last good count instead of surfacing an error frame that the UI
      // would render as a red ErrorWidget.
    }
  }

  // ── Internal helpers ────────────────────────────────────────────────────────

  Future<List<Friendship>> _loadFriendships({required String status}) async {
    final me = _uid;
    if (me == null) return [];
    try {
      // Two queries — one for each side of the edge — then dedupe. We do
      // NOT use a PostgREST embed for `other:` because the row-level read
      // policy on `profiles` (auth.uid() = id) silently returns null for
      // anyone other than the caller, which was the root cause of the
      // empty "My Kitchen Circle" friends list.
      final asRequester = await _db
          .from('friendships')
          .select('id, requester_id, receiver_id, status, created_at')
          .eq('requester_id', me)
          .eq('status', status);
      final asReceiver  = await _db
          .from('friendships')
          .select('id, requester_id, receiver_id, status, created_at')
          .eq('receiver_id', me)
          .eq('status', status);

      final rows = <Map<String, dynamic>>[
        ...(asRequester as List).cast<Map<String, dynamic>>(),
        ...(asReceiver  as List).cast<Map<String, dynamic>>(),
      ];

      // Dedupe before issuing RPC fetches.
      final seenIds = <String>{};
      final unique  = <Map<String, dynamic>>[];
      for (final r in rows) {
        if (seenIds.add(r['id'] as String)) unique.add(r);
      }

      // Hide any friendship whose other party is in a block
      // relationship with the current user in EITHER direction. The
      // friend row stays in the DB (so an unblock restores them
      // instantly without a re-invite), but the UI treats them as
      // if they aren't there — no listing, no mention suggestion.
      final blockedIds = await ModerationService.instance
          .blockedIdsEitherDirection();

      final out = <Friendship>[];
      for (final m in unique) {
        final reqId = m['requester_id'] as String;
        final recId = m['receiver_id']  as String;
        final otherId = (reqId == me) ? recId : reqId;
        if (blockedIds.contains(otherId)) continue;
        final other = await _resolvePublicProfile(otherId);
        out.add(Friendship(
          id:          m['id']           as String,
          requesterId: reqId,
          receiverId:  recId,
          status:      status == 'accepted'
              ? FriendshipStatus.accepted
              : FriendshipStatus.pending,
          other:       other,
          createdAt:   DateTime.parse(m['created_at'] as String),
        ));
      }
      return out;
    } catch (_) {
      return [];
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exceptions
// ─────────────────────────────────────────────────────────────────────────────

class _NotAuthenticated implements Exception {
  const _NotAuthenticated();
  @override String toString() => 'Sign in to manage your Kitchen Circle.';
}

class _SelfInvite implements Exception {
  @override String toString() => "You can't invite yourself, chom.";
}

/// Thrown by [FriendsService.inviteFriend] when either party has a
/// standing block. Surfaces a friendly UI message instead of letting
/// the call fail with an opaque RLS denial.
class _BlockedInviteAttempt implements Exception {
  const _BlockedInviteAttempt();
  @override
  String toString() =>
      "You can't connect with this user right now — one of you has "
      "blocked the other.";
}
