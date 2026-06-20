// lib/services/moderation_service.dart
//
// Single entry point for the UGC moderation actions Google Play's UGC
// policy requires every social app to expose:
//
//   • Report a community post     (post_reports)
//   • Report a channel message    (channel_message_reports)
//   • Block another user          (user_blocks → RLS hides their content)
//   • Unblock                     (delete the row)
//
// The DB layer hides blocked users' posts / channel messages / comments
// via RLS SELECT policies, so the caller never sees their content again
// after a block — no client-side filtering needed.

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class ModerationService {
  ModerationService._();
  static final ModerationService instance = ModerationService._();

  SupabaseClient get _db => Supabase.instance.client;

  // ── Reports ────────────────────────────────────────────────────────────────

  Future<void> reportPost(String postId, {String? reason}) async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) throw StateError('Not signed in.');
    try {
      await _db.from('post_reports').insert({
        'post_id':     postId,
        'reporter_id': uid,
        'reason':      reason ?? 'Community report',
        'reported_at': DateTime.now().toIso8601String(),
      });
    } on PostgrestException catch (e) {
      // 23505 → already reported, treat as success.
      if (e.code != '23505') rethrow;
    }
  }

  Future<void> reportChannelMessage(String messageId,
      {String? reason}) async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) throw StateError('Not signed in.');
    try {
      await _db.from('channel_message_reports').insert({
        'message_id':  messageId,
        'reporter_id': uid,
        'reason':      reason ?? 'Community report',
        'reported_at': DateTime.now().toIso8601String(),
      });
    } on PostgrestException catch (e) {
      if (e.code != '23505') rethrow;
    }
  }

  // ── Blocks ─────────────────────────────────────────────────────────────────

  Future<void> blockUser(String otherUserId) async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) throw StateError('Not signed in.');
    if (uid == otherUserId) {
      throw ArgumentError('Cannot block yourself.');
    }
    try {
      await _db.from('user_blocks').insert({
        'blocker_id': uid,
        'blocked_id': otherUserId,
      });
    } on PostgrestException catch (e) {
      if (e.code != '23505') rethrow;
    }
  }

  Future<void> unblockUser(String otherUserId) async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return;
    await _db
        .from('user_blocks')
        .delete()
        .eq('blocker_id', uid)
        .eq('blocked_id', otherUserId);
  }

  Future<bool> isBlocked(String otherUserId) async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return false;
    try {
      final row = await _db
          .from('user_blocks')
          .select('blocked_id')
          .eq('blocker_id', uid)
          .eq('blocked_id', otherUserId)
          .maybeSingle();
      return row != null;
    } catch (e) {
      if (kDebugMode) debugPrint('[Moderation] isBlocked failed: $e');
      return false;
    }
  }

  /// Returns the list of users the current account has blocked. Used by the
  /// "Blocked users" Settings screen so the user can unblock.
  Future<List<Map<String, dynamic>>> listBlocked() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return const [];
    final rows = await _db
        .from('user_blocks')
        .select('blocked_id, created_at')
        .eq('blocker_id', uid)
        .order('created_at', ascending: false);
    return (rows as List).cast<Map<String, dynamic>>();
  }

  /// Returns every user id that has a block relationship with the
  /// current user in EITHER direction — both people the current user
  /// has blocked AND people who blocked the current user. Used by
  /// friend lists, mention pickers, and the invite flow to make
  /// blocked accounts disappear from both sides of the relationship
  /// at once. Empty when signed out or on any DB failure so the UI
  /// degrades by showing everyone rather than throwing.
  Future<Set<String>> blockedIdsEitherDirection() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return const <String>{};
    try {
      // Two narrow queries beat one OR'd query because Supabase's
      // .or() filter syntax is fiddly and easy to misquote. The set
      // is tiny in practice (blocks per account), so two round-trips
      // is fine.
      final iBlocked  = await _db
          .from('user_blocks')
          .select('blocked_id')
          .eq('blocker_id', uid);
      final blockedMe = await _db
          .from('user_blocks')
          .select('blocker_id')
          .eq('blocked_id', uid);
      return <String>{
        for (final r in (iBlocked  as List)) r['blocked_id'] as String,
        for (final r in (blockedMe as List)) r['blocker_id'] as String,
      };
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[Moderation] blockedIdsEitherDirection failed: $e');
      }
      return const <String>{};
    }
  }
}
