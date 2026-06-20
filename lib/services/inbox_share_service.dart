// lib/services/inbox_share_service.dart
//
// ONE PATH for every "share to a ChowSA user's inbox" surface — shopping
// lists, recipes, and any future kind. Replaces the divergent code that
// used to live in _ShareListSheet._sendToUser and _ShareSheet._shareToUser.
//
// Contract:
//   1. Caller passes a kind + payload + recipient handle.
//   2. Service resolves the handle → user_id via `find_user_by_handle`
//      (the same SECURITY DEFINER RPC the shopping-list path uses).
//   3. INSERT into inbox_messages with both receiver_id AND
//      receiver_handle (the realtime listener on the recipient's device
//      filters on receiver_handle for backwards compat).
//   4. On 23505 unique-violation (duplicate share dedupe index), runs an
//      UPDATE on the existing row so re-shares refresh the payload + flip
//      is_read=false without throwing.
//   5. Re-reads the row via .select().single() so the caller only treats
//      the share as successful if Supabase confirms a row exists. No more
//      "UI success but recipient never receives" — the snackbar fires
//      only when the row is verified server-side.
//
// Error contract:
//   • [InboxShareUnknownRecipient]  — handle not found by RPC.
//   • [InboxShareDeniedException]   — RLS rejected the write.
//   • [InboxShareTimeoutException]  — round-trip exceeded budget.
//   • [InboxShareException]         — anything else, with original
//     PostgrestException code/message preserved for logging.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/recipe.dart';
import '../models/shopping_list.dart';

enum InboxShareKind { shoppingList, recipe, mealPlan }

extension InboxShareKindX on InboxShareKind {
  /// Value written to `inbox_messages.message_type`.
  String get wire => switch (this) {
        InboxShareKind.shoppingList => 'shared_list',
        InboxShareKind.recipe       => 'shared_recipe',
        InboxShareKind.mealPlan     => 'shared_meal_plan',
      };

  String get noun => switch (this) {
        InboxShareKind.shoppingList => 'Shopping list',
        InboxShareKind.recipe       => 'Recipe',
        InboxShareKind.mealPlan     => 'Meal plan',
      };
}

/// Confirmed inbox row, returned only after Supabase round-trips a 200.
class InboxShareResult {
  const InboxShareResult({
    required this.messageId,
    required this.receiverHandle,
    required this.kind,
    required this.wasUpdate,
  });
  final String          messageId;
  final String          receiverHandle;
  final InboxShareKind  kind;
  /// True when the row already existed and was UPDATEd in place by the
  /// dedupe fallback — false on a clean INSERT.
  final bool            wasUpdate;
}

class InboxShareService {
  InboxShareService._();
  static final InboxShareService instance = InboxShareService._();

  SupabaseClient get _db => Supabase.instance.client;

  /// Shares a ShoppingList to [recipientHandle]. Returns the verified
  /// inbox row; throws on failure.
  Future<InboxShareResult> shareShoppingList({
    required ShoppingList list,
    required String       recipientHandle,
  }) =>
      _share(
        kind:            InboxShareKind.shoppingList,
        recipientHandle: recipientHandle,
        // Unique key inside the dedupe index — for lists it's the list id
        // so repeat shares of the SAME list update the existing row, but
        // a brand-new list creates a fresh inbox card.
        dedupeKey:       list.id,
        payloadBuilder:  (senderHandle) => {
          'sender_handle': senderHandle,
          'list_name':     list.name,
          'list_id':       list.id,
          'items':         list.items.map((i) => i.toJson()).toList(),
        },
      );

  /// Shares a weekly meal plan to [recipientHandle]. [days] follows the
  /// same shape SharedAssetsService.sendMenu emits — `{ Monday: { ... } }`.
  /// Persists into inbox_messages so the recipient can re-open the share
  /// later from the Inbox screen, not just the live banner.
  Future<InboxShareResult> shareMealPlan({
    required String                title,
    required Map<String, dynamic>  days,
    required String                recipientHandle,
  }) =>
      _share(
        kind:            InboxShareKind.mealPlan,
        recipientHandle: recipientHandle,
        dedupeKey:       title.trim().toLowerCase(),
        payloadBuilder:  (senderHandle) => {
          'sender_handle': senderHandle,
          'list_name':     title,    // re-use list_name so the inbox card
                                     // header renders the actual title.
          'title':         title,
          'days':          days,
        },
      );

  /// Shares a Recipe to [recipientHandle]. Returns the verified inbox row;
  /// throws on failure.
  Future<InboxShareResult> shareRecipe({
    required Recipe recipe,
    required String recipientHandle,
  }) =>
      _share(
        kind:            InboxShareKind.recipe,
        recipientHandle: recipientHandle,
        // Recipes don't carry a stable id on the model, so the dedupe
        // key is the title — reshares of "Malva Pudding" to the same
        // friend refresh the existing card instead of stacking.
        dedupeKey:       recipe.title.trim().toLowerCase(),
        payloadBuilder:  (senderHandle) => {
          'sender_handle': senderHandle,
          'recipe_title':  recipe.title,
          'ingredients':   recipe.ingredients
              .map((i) => i.toJson()).toList(),
          'instructions':  recipe.instructions,
        },
      );

  // ── Core ───────────────────────────────────────────────────────────────

  Future<InboxShareResult> _share({
    required InboxShareKind                       kind,
    required String                               recipientHandle,
    required String                               dedupeKey,
    required Map<String, dynamic> Function(String) payloadBuilder,
  }) async {
    final me = _db.auth.currentUser;
    if (me == null) {
      throw const InboxShareException('not_authenticated', 'Please sign in.');
    }
    final senderId      = me.id;
    final senderHandle  = (me.userMetadata?['handle'] as String?)
                       ?? me.email?.split('@').first
                       ?? 'Someone';

    final cleanHandle = recipientHandle
        .replaceFirst('@', '')
        .trim()
        .toLowerCase();
    if (cleanHandle.isEmpty) {
      throw const InboxShareException(
        'empty_handle',
        'Type a ChowSA handle before tapping Send.',
      );
    }

    // 1) Resolve receiver_id via the same SECURITY DEFINER RPC the
    //    shopping-list path uses. RLS on `profiles` blocks a direct
    //    .select() against another user, so the RPC is the only path.
    String? receiverId;
    String? receiverHandle;
    try {
      final rpcRes = await _db
          .rpc('find_user_by_handle', params: {'q': cleanHandle})
          .timeout(const Duration(seconds: 10));
      Map<String, dynamic>? row;
      if (rpcRes is List && rpcRes.isNotEmpty) {
        row = Map<String, dynamic>.from(rpcRes.first as Map);
      } else if (rpcRes is Map) {
        row = Map<String, dynamic>.from(rpcRes);
      }
      receiverId     = row?['id']     as String?;
      receiverHandle = (row?['handle']   as String?)
                    ?? (row?['username'] as String?);
    } on TimeoutException {
      throw const InboxShareTimeoutException();
    }
    if (receiverId == null || receiverHandle == null) {
      throw InboxShareUnknownRecipient(cleanHandle);
    }

    final payload = payloadBuilder(senderHandle);
    // Stamp the dedupe key under a predictable column so the partial
    // unique indexes can match each kind: lists use `list_id`, recipes
    // and meal plans both use `share_key`.
    final payloadWithKey = {
      ...payload,
      if (kind == InboxShareKind.recipe ||
          kind == InboxShareKind.mealPlan)
        'share_key': dedupeKey,
    };

    // 2) INSERT, fall back to UPDATE on 23505 dedupe violation, and
    //    re-read via .select().single() so we only return after the row
    //    is verifiably present in the DB.
    String  messageId;
    bool    wasUpdate = false;
    try {
      final inserted = await _db
          .from('inbox_messages')
          .insert({
            'sender_id':       senderId,
            'receiver_id':     receiverId,
            'receiver_handle': receiverHandle.toLowerCase(),
            'message_type':    kind.wire,
            'status':          'pending_import',
            'is_read':         false,
            'payload':         payloadWithKey,
          })
          .select('id')
          .single()
          .timeout(const Duration(seconds: 12));
      messageId = inserted['id'] as String;
    } on PostgrestException catch (e) {
      if (e.code == '42501') {
        // RLS: only authenticated senders may insert. Rare — the JWT was
        // probably stale or RLS policies were tightened mid-session.
        throw const InboxShareDeniedException();
      }
      if (e.code != '23505') {
        // Anything else is a true failure — rethrow with full context so
        // the caller's catch can show the real reason.
        throw InboxShareException(e.code ?? 'unknown', e.message);
      }
      // 23505 = dedupe index hit. Patch the existing row in place so a
      // re-share refreshes payload + bumps the unread flag.
      wasUpdate = true;
      final updated = await _db
          .from('inbox_messages')
          .update({
            'payload':    payloadWithKey,
            'is_read':    false,
            'status':     'pending_import',
            'created_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('sender_id',       senderId)
          .eq('receiver_handle', receiverHandle.toLowerCase())
          .eq('message_type',    kind.wire)
          .filter(
            kind == InboxShareKind.shoppingList
                ? 'payload->>list_id'
                : 'payload->>share_key',
            'eq',
            dedupeKey,
          )
          .select('id')
          .single()
          .timeout(const Duration(seconds: 12));
      messageId = updated['id'] as String;
    } on TimeoutException {
      throw const InboxShareTimeoutException();
    }

    if (kDebugMode) {
      debugPrint(
        '[InboxShareService] ${kind.wire} → @$receiverHandle '
        '(id=$messageId, update=$wasUpdate)',
      );
    }
    return InboxShareResult(
      messageId:      messageId,
      receiverHandle: receiverHandle,
      kind:           kind,
      wasUpdate:      wasUpdate,
    );
  }
}

// ── Exceptions ─────────────────────────────────────────────────────────────

class InboxShareException implements Exception {
  const InboxShareException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => 'InboxShareException($code): $message';
}

class InboxShareUnknownRecipient extends InboxShareException {
  InboxShareUnknownRecipient(String handle)
      : super('unknown_recipient', 'No ChowSA user found for @$handle.');
}

class InboxShareDeniedException extends InboxShareException {
  const InboxShareDeniedException()
      : super('denied', "You don't have permission to share that.");
}

class InboxShareTimeoutException extends InboxShareException {
  const InboxShareTimeoutException()
      : super('timeout', 'Network timed out — please try again.');
}
