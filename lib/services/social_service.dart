// lib/services/social_service.dart
//
// Unified social engine for ChowSA — likes, friendships ("Braai invites"),
// and Kitchen Circle asset sharing.
//
// Mirrors the Supabase schema:
//   • post_likes     (post_id, user_id) — unique
//   • friendships    (requester_id, receiver_id, status)
//   • shared_assets  (sender_id, receiver_id, asset_type, payload, ...)
//   • profiles       (id, username/handle, email, ...)
//
// Use this service as the canonical single entry point for new social
// features. The existing FriendsService / SharedAssetsService /
// community-feed inline like logic still work — `SocialService` is a thin
// re-implementation of the same surface, exposed under one class so future
// callers don't have to juggle three imports.

import 'package:supabase_flutter/supabase_flutter.dart';

class SocialService {
  final _client = Supabase.instance.client;

  // ─────────────────────────────────────────────────────────────────────────
  // LIKES ENGINE
  // ─────────────────────────────────────────────────────────────────────────

  /// Toggles the current user's like on [postId].
  /// Returns the new "is-liked" state — `true` when freshly liked, `false`
  /// when freshly unliked OR on any error (so the UI can fail safe).
  Future<bool> toggleLike(String postId) async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return false;

    try {
      final existing = await _client
          .from('post_likes')
          .select()
          .eq('post_id', postId)
          .eq('user_id', userId)
          .maybeSingle();

      if (existing != null) {
        await _client
            .from('post_likes')
            .delete()
            .eq('post_id', postId)
            .eq('user_id', userId);
        return false; // Unliked
      } else {
        await _client
            .from('post_likes')
            .insert({'post_id': postId, 'user_id': userId});
        return true; // Liked
      }
    } catch (_) {
      return false;
    }
  }

  /// Returns `{likesCount, commentsCount, isLiked}` for a single post.
  /// Useful for refreshing one card without re-pulling the whole feed.
  Future<Map<String, dynamic>> getPostMetrics(String postId) async {
    final userId = _client.auth.currentUser?.id;

    final likesRes    = await _client
        .from('post_likes')
        .select('id')
        .eq('post_id', postId);
    final commentsRes = await _client
        .from('comments')
        .select('id')
        .eq('post_id', postId);

    bool isLikedByMe = false;
    if (userId != null) {
      final userLike = await _client
          .from('post_likes')
          .select()
          .eq('post_id', postId)
          .eq('user_id', userId)
          .maybeSingle();
      isLikedByMe = userLike != null;
    }

    return {
      'likesCount':    (likesRes    as List).length,
      'commentsCount': (commentsRes as List).length,
      'isLiked':       isLikedByMe,
    };
  }

  // ─────────────────────────────────────────────────────────────────────────
  // CHANNEL MESSAGE REACTIONS (PR 2 — WhatsApp-parity)
  // ─────────────────────────────────────────────────────────────────────────
  //
  // Targets `channel_message_reactions` (migration 20260622) — one row per
  // (message_id, user_id, emoji) triple. Allowed emoji set is locked at
  // the DB via a CHECK constraint to the SA reaction palette:
  //   ❤️  👍  😂  🔥  😮  😢  🙏
  //
  // Reactions replaced the old single-heart channel_message_likes flow
  // (removed 2026-06-19). Caller flips local state instantly, awaits
  // this, snaps back if the returned value disagrees with the optimistic
  // guess (RLS denial, network blip, double-tap race).

  /// Toggles the current user's [emoji] reaction on the given channel
  /// message. Enforces a single-reaction-per-user-per-message policy:
  ///
  ///   • Tapping the SAME emoji you already reacted with → unreacts.
  ///   • Tapping a DIFFERENT emoji → atomically swaps your previous
  ///     reaction for the new one (radio-button semantics).
  ///   • Tapping with no existing reaction → inserts.
  ///
  /// Returns the new "is-reacted" state — `true` when the new emoji is
  /// now active, `false` when removed OR on any error so the UI can fail
  /// safe and reconcile via the per-bubble realtime stream.
  ///
  /// Implementation note: the DB composite PK is still
  /// (message_id, user_id, emoji) so multi-emoji rows are physically
  /// possible. The blanket `delete().eq(message_id).eq(user_id)` below
  /// also cleans up any legacy multi-reaction rows lingering from
  /// before this enforcement landed.
  Future<bool> toggleChannelMessageReaction(
    String messageId,
    String emoji,
  ) async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return false;

    try {
      // Pull every reaction the current user has on this message — the
      // composite PK allowed multiple emojis per user historically, so
      // a list (not maybeSingle) is the safe read.
      final rows = await _client
          .from('channel_message_reactions')
          .select('emoji')
          .eq('message_id', messageId)
          .eq('user_id',    userId);

      final existingEmojis = (rows as List)
          .map((r) => (r as Map)['emoji'] as String)
          .toSet();

      // Same emoji already reacted → unreact + remove any siblings.
      if (existingEmojis.contains(emoji)) {
        await _client
            .from('channel_message_reactions')
            .delete()
            .eq('message_id', messageId)
            .eq('user_id',    userId);
        return false;
      }

      // Different emoji (or none) → atomic swap: clear all of the user's
      // existing reactions on this message, then insert the new one. The
      // two operations run sequentially; the per-bubble stream emits an
      // intermediate state for ~1 frame before reconciling — acceptable.
      if (existingEmojis.isNotEmpty) {
        await _client
            .from('channel_message_reactions')
            .delete()
            .eq('message_id', messageId)
            .eq('user_id',    userId);
      }
      await _client.from('channel_message_reactions').insert({
        'message_id': messageId,
        'user_id':    userId,
        'emoji':      emoji,
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Legacy heart-toggle metrics. The underlying `channel_message_likes`
  /// table was dropped on 2026-06-19 when reactions replaced the single-
  /// heart flow, but Crashlytics still surfaces PGRST205 from older
  /// app versions calling this. No live caller remains in the tree —
  /// returning zero here keeps any stale binding from crashing.
  Future<Map<String, dynamic>> getChannelMessageLikeMetrics(
      String messageId) async {
    return {'likesCount': 0, 'isLiked': false};
  }

  // ─────────────────────────────────────────────────────────────────────────
  // BRAAI INVITES (FRIENDS)
  // ─────────────────────────────────────────────────────────────────────────

  /// Sends a friend invite by the target user's USERNAME.
  ///
  /// Sanitisation: strips every leading `@` character and trims whitespace
  /// before querying `profiles.username` (case-insensitive exact match via
  /// `.ilike` with no wildcards). Throws [SocialException] on every failure
  /// path so callers can surface a clean snackbar.
  Future<void> sendBraaiInvite(String enteredUsername) async {
    final currentUserId = _client.auth.currentUser?.id;
    if (currentUserId == null) {
      throw const SocialException('User unauthenticated');
    }

    // Sanitise per spec — strip an accidental '@' and trim whitespace so the
    // DB query string never contains the symbol. .ilike() then does the
    // case-insensitive match ("melrose" matches "Melrose" in profiles).
    final String cleanUsername =
        enteredUsername.replaceFirst('@', '').trim();

    if (cleanUsername.isEmpty) {
      throw const SocialException(
        'Please enter a ChowSA username to send an invite.',
      );
    }

    // Look up by EITHER `username` OR `handle` via the SECURITY DEFINER RPC
    // `find_user_by_handle`. We previously hit `profiles` directly with an
    // `ilike` filter, which silently returned 0 rows for any user OTHER
    // than the caller — the row-level read policy on `profiles` restricts
    // SELECT to `auth.uid() = id`. The RPC bypasses that for an explicit
    // by-handle lookup while still gating on `auth.uid() IS NOT NULL`.
    final rpcRes = await _client
        .rpc('find_user_by_handle', params: {'q': cleanUsername});
    Map<String, dynamic>? targetUser;
    if (rpcRes is List && rpcRes.isNotEmpty) {
      targetUser = Map<String, dynamic>.from(rpcRes.first as Map);
    } else if (rpcRes is Map) {
      targetUser = Map<String, dynamic>.from(rpcRes);
    }

    if (targetUser == null || targetUser['id'] == null) {
      throw SocialException('Could not find username $cleanUsername');
    }

    // Wrap the insert so the UNIQUE constraint on
    // friendships_requester_id_receiver_id_key (one (requester, receiver)
    // pair only) no longer bubbles up as a raw PostgrestException. The
    // 23505 collision is the user-facing "already invited" case — catch
    // it and re-throw a SocialException with a friendly copy that the
    // snackbar layer can surface verbatim.
    try {
      await _client.from('friendships').insert({
        'requester_id': currentUserId,
        'receiver_id':  targetUser['id'],
        'status':       'pending',
      });
    } on PostgrestException catch (e) {
      final isDuplicate = e.code == '23505' ||
          (e.message.toLowerCase().contains('duplicate')) ||
          (e.message.toLowerCase()
              .contains('friendships_requester_id_receiver_id_key')) ||
          (e.details?.toString().toLowerCase().contains('duplicate') ?? false);
      if (isDuplicate) {
        throw const SocialException(
          'An invitation or circle link is already active or pending '
          'with this user!',
        );
      }
      // Any other PostgrestException → surface its message cleanly so
      // the snackbar isn't a raw stack trace.
      throw SocialException('Could not send invite: ${e.message}');
    }
  }

  /// Receiver-side response. `accept: true` flips status → `accepted`.
  /// `accept: false` deletes the row entirely (decline / cancel).
  Future<void> respondToInvite(String friendshipId, bool accept) async {
    if (accept) {
      await _client
          .from('friendships')
          .update({'status': 'accepted'})
          .eq('id', friendshipId);
    } else {
      await _client.from('friendships').delete().eq('id', friendshipId);
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // ASSET SHARING
  // ─────────────────────────────────────────────────────────────────────────

  /// Inserts an asset (shopping list, menu, recipe, etc.) into the receiver's
  /// inbox. Looks up the sender's display name from the `profiles` table so
  /// the receiver sees "Chef {name} shared a list" rather than a raw uuid.
  Future<void> shareToKitchenCircle({
    required String              receiverId,
    required String              assetType,
    required Map<String, dynamic> payload,
  }) async {
    final currentUserId = _client.auth.currentUser?.id;
    if (currentUserId == null) return;

    // The profiles table uses `username` in the new schema; if that column
    // isn't present yet (older project) we silently fall back to a generic
    // sender name so the share still succeeds.
    String senderName = 'Another Chef';
    try {
      final profile = await _client
          .from('profiles')
          .select('username')
          .eq('id', currentUserId)
          .single();
      senderName = (profile['username'] as String?) ?? senderName;
    } catch (_) { /* profile missing 'username' col — keep default */ }

    await _client.from('shared_assets').insert({
      'sender_id':   currentUserId,
      'receiver_id': receiverId,
      'sender_name': senderName,
      'asset_type':  assetType,
      'payload':     payload,
    });
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Typed exception so callers can branch on type instead of string matching.
// Implements Exception so it satisfies Dart's `only_throw_errors` lint rule.
// ─────────────────────────────────────────────────────────────────────────────

class SocialException implements Exception {
  const SocialException(this.message);
  final String message;
  @override
  String toString() => message;
}
