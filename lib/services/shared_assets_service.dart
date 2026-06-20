// lib/services/shared_assets_service.dart
//
// Cross-user asset sharing for shopping lists and weekly menu plans.
//
// Unified Supabase schema (run once):
//
//   create table shared_assets (
//     id          uuid primary key default gen_random_uuid(),
//     sender_id   uuid not null references auth.users(id) on delete cascade,
//     receiver_id uuid not null references auth.users(id) on delete cascade,
//     asset_type  text not null check (asset_type in ('shopping_list','menu')),
//     payload     jsonb not null,
//     is_read     boolean not null default false,
//     created_at  timestamptz not null default now()
//   );
//   alter table shared_assets enable row level security;
//   create policy "send"   on shared_assets for insert to authenticated
//     with check (auth.uid() = sender_id);
//   create policy "inbox"  on shared_assets for select to authenticated
//     using (auth.uid() = receiver_id);
//   create policy "markread" on shared_assets for update to authenticated
//     using (auth.uid() = receiver_id);
//
// Realtime: add the table to `supabase_realtime` publication so the inbox
// listener in MainNavigationHub receives instant push events.

import 'package:supabase_flutter/supabase_flutter.dart';

enum SharedAssetType {
  shoppingList('shopping_list'),
  menu('menu');

  const SharedAssetType(this.dbValue);
  final String dbValue;
}

class SharedAsset {
  SharedAsset({
    required this.id,
    required this.senderId,
    required this.receiverId,
    required this.assetType,
    required this.payload,
    required this.isRead,
    required this.createdAt,
  });

  final String                id;
  final String                senderId;
  final String                receiverId;
  final SharedAssetType       assetType;
  final Map<String, dynamic>  payload;
  final bool                  isRead;
  final DateTime              createdAt;

  factory SharedAsset.fromRow(Map<String, dynamic> r) => SharedAsset(
    id:         r['id']          as String,
    senderId:   r['sender_id']   as String,
    receiverId: r['receiver_id'] as String,
    assetType:  SharedAssetType.values.firstWhere(
                  (t) => t.dbValue == r['asset_type'],
                  orElse: () => SharedAssetType.shoppingList),
    payload:    Map<String, dynamic>.from(r['payload'] as Map),
    isRead:     (r['is_read']     as bool?)   ?? false,
    createdAt:  DateTime.parse(r['created_at'] as String),
  );

  String get senderHandle =>
      (payload['sender_handle'] as String?) ?? 'Someone';
  String get displayTitle =>
      (payload['title'] as String?) ?? (payload['list_name'] as String?) ?? 'Shared item';
}

class SharedAssetsService {
  SharedAssetsService._();
  static final SharedAssetsService instance = SharedAssetsService._();

  SupabaseClient    get _db   => Supabase.instance.client;
  String?           get _uid  => _db.auth.currentUser?.id;

  // ── Recipient resolution ────────────────────────────────────────────────────
  /// Looks up a user's auth id from their ChowSA **username**.
  ///
  /// Sanitisation per spec:
  ///   • `.replaceFirst('@', '')` strips an accidental '@' prefix the user
  ///     pasted or typed (UI no longer renders one, but copy-paste from
  ///     elsewhere can still introduce one)
  ///   • `.trim()` drops surrounding whitespace
  ///   • `.ilike('username', cleanUsername)` performs a case-insensitive
  ///     exact match so "melrose" finds the row for "Melrose"
  ///
  /// Returns null when no matching profile row exists.
  Future<String?> resolveReceiverId(String username) async {
    // Sanitise per spec — strip an accidental '@' and trim whitespace, then
    // scan BOTH `username` and `handle` columns case-insensitively. Some
    // accounts populate only one of the two (e.g. "Melrose" lives under
    // `handle` with a NULL `username`) — checking just `username` produced
    // false "user not found" failures on legit accounts.
    final String cleanUsername =
        username.replaceFirst('@', '').trim();
    if (cleanUsername.isEmpty) return null;
    try {
      // Route through the `find_user_by_handle` SECURITY DEFINER RPC so
      // the row-level read policy on `profiles` (auth.uid() = id) doesn't
      // silently hide every other user's row from us.
      final rpcRes = await _db
          .rpc('find_user_by_handle', params: {'q': cleanUsername});
      if (rpcRes is List && rpcRes.isNotEmpty) {
        return (rpcRes.first as Map)['id'] as String?;
      }
      if (rpcRes is Map) {
        return rpcRes['id'] as String?;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  // ── Send ────────────────────────────────────────────────────────────────────

  /// Sends a shopping list to another ChowSA user by handle.
  /// Returns the receiver_id on success; throws on auth / lookup / insert failure.
  Future<String> sendShoppingList({
    required String              receiverHandle,
    required String              listName,
    required List<Map<String, dynamic>> items,
    String?                       senderHandle,
  }) async {
    final senderId = _uid;
    if (senderId == null) {
      throw const _NotAuthenticated();
    }
    final receiverId = await resolveReceiverId(receiverHandle);
    if (receiverId == null) {
      throw _UnknownRecipient(receiverHandle);
    }

    await _db.from('shared_assets').insert({
      'sender_id':   senderId,
      'receiver_id': receiverId,
      'asset_type':  SharedAssetType.shoppingList.dbValue,
      'payload': {
        'sender_handle': senderHandle ?? '',
        'title':         listName,
        'list_name':     listName,
        'items':         items,
      },
      'is_read': false,
    });

    return receiverId;
  }

  /// Sends a weekly menu plan to another ChowSA user by handle.
  /// `days` is a map of day-name → list of recipe titles per slot,
  /// e.g. `{'Monday': {'breakfast': ['Pap'], 'lunch': [...]}, ...}`.
  Future<String> sendMenu({
    required String                          receiverHandle,
    required String                          title,
    required Map<String, dynamic>            days,
    String?                                   senderHandle,
  }) async {
    final senderId = _uid;
    if (senderId == null) {
      throw const _NotAuthenticated();
    }
    final receiverId = await resolveReceiverId(receiverHandle);
    if (receiverId == null) {
      throw _UnknownRecipient(receiverHandle);
    }

    await _db.from('shared_assets').insert({
      'sender_id':   senderId,
      'receiver_id': receiverId,
      'asset_type':  SharedAssetType.menu.dbValue,
      'payload': {
        'sender_handle': senderHandle ?? '',
        'title':         title,
        'days':          days,
      },
      'is_read': false,
    });

    return receiverId;
  }

  // ── Inbox stream (for the home/notification listener) ──────────────────────
  /// Realtime stream of unread shared assets for the current user.
  /// Empty stream when not signed in. Each emission is the latest snapshot
  /// of unread rows ordered by created_at desc.
  Stream<List<SharedAsset>> streamUnreadForCurrentUser() {
    final uid = _uid;
    if (uid == null) return const Stream.empty();
    return _db
        .from('shared_assets')
        .stream(primaryKey: ['id'])
        .eq('receiver_id', uid)
        .order('created_at')
        .map((rows) {
          return rows
              .where((r) => (r['is_read'] as bool?) != true)
              .map(SharedAsset.fromRow)
              .toList();
        });
  }

  /// Marks one shared asset as read.
  Future<void> markRead(String id) async {
    await _db.from('shared_assets').update({'is_read': true}).eq('id', id);
  }
}

// ── Exceptions ─────────────────────────────────────────────────────────────────

class _NotAuthenticated implements Exception {
  const _NotAuthenticated();
  @override
  String toString() => 'Sign in to share with another ChowSA user.';
}

class _UnknownRecipient implements Exception {
  _UnknownRecipient(this.username);
  final String username;
  @override
  String toString() => 'Could not find username $username';
}
