// lib/models/inbox_message.dart
//
// Represents a single share that arrived in the user's inbox. Two flavours
// today: a shared shopping list and a shared recipe — distinguished by
// [kind] so the inbox card can render the correct copy ("Shared a grocery
// list" vs "Shared a recipe") and the tap-handler can route to the right
// destination (ShoppingListScreen import vs RecipeDetailScreen).

import 'shopping_list.dart';

enum InboxMessageKind {
  shoppingList,
  recipe,
  mealPlan,
}

InboxMessageKind _kindFromString(String? s) {
  switch (s) {
    case 'recipe':
    case 'shared_recipe':
      return InboxMessageKind.recipe;
    case 'meal_plan':
    case 'shared_meal_plan':
      return InboxMessageKind.mealPlan;
    case 'shopping_list':
    case 'shared_list':
    default:
      return InboxMessageKind.shoppingList;
  }
}

class InboxMessage {
  InboxMessage({
    required this.id,
    required this.fromHandle,
    required this.listName,
    required this.listId,
    required this.items,
    required this.receivedAt,
    this.kind          = InboxMessageKind.shoppingList,
    this.recipeIngredients = const <String>[],
    this.recipeInstructions = const <String>[],
    this.isRead     = false,
    this.isImported = false,
  });

  final String             id;
  final String             fromHandle;   // e.g. "@SiphoK"
  final String             listName;     // doubles as recipe title when kind == recipe
  final String             listId;
  final List<ShoppingItem> items;        // empty for recipe shares
  final DateTime           receivedAt;
  final InboxMessageKind   kind;
  final List<String>       recipeIngredients;
  final List<String>       recipeInstructions;
  bool                     isRead;
  bool                     isImported;

  // ── Helpers ──────────────────────────────────────────────────────────────────

  String get displaySender => fromHandle.startsWith('@')
      ? fromHandle
      : '@$fromHandle';

  String get timeAgo {
    final diff = DateTime.now().difference(receivedAt);
    if (diff.inMinutes < 1)  return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours   < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  // ── Serialisation ─────────────────────────────────────────────────────────────

  Map<String, dynamic> toJson() => {
        'id':         id,
        'fromHandle': fromHandle,
        'listName':   listName,
        'listId':     listId,
        'items':      items.map((i) => i.toJson()).toList(),
        'receivedAt': receivedAt.toIso8601String(),
        'isRead':     isRead,
        'isImported': isImported,
        'kind':                kind.name,
        'recipeIngredients':   recipeIngredients,
        'recipeInstructions':  recipeInstructions,
      };

  factory InboxMessage.fromJson(Map<String, dynamic> j) => InboxMessage(
        id:         j['id']         as String,
        fromHandle: j['fromHandle'] as String,
        listName:   j['listName']   as String,
        listId:     j['listId']     as String,
        items:      (j['items'] as List<dynamic>)
            .map((e) => ShoppingItem.fromJson(e as Map<String, dynamic>))
            .toList(),
        receivedAt: DateTime.parse(j['receivedAt'] as String),
        kind:       _kindFromString(j['kind'] as String?),
        recipeIngredients: (j['recipeIngredients'] as List<dynamic>?)
                ?.map((e) => e.toString())
                .toList() ?? const <String>[],
        recipeInstructions: (j['recipeInstructions'] as List<dynamic>?)
                ?.map((e) => e.toString())
                .toList() ?? const <String>[],
        isRead:     j['isRead']     as bool? ?? false,
        isImported: j['isImported'] as bool? ?? false,
      );

  /// Parses a raw `inbox_messages` row from Supabase into an InboxMessage.
  /// Handles both kinds — distinguishes via `message_type` and reads the
  /// kind-specific payload fields.
  factory InboxMessage.fromInboxRow(Map<String, dynamic> row) {
    final payload = (row['payload'] as Map?)?.cast<String, dynamic>() ?? {};
    final kind    = _kindFromString(row['message_type'] as String?);
    final received = DateTime.tryParse(row['created_at'] as String? ?? '')
        ?? DateTime.now();
    if (kind == InboxMessageKind.mealPlan) {
      // Meal-plan shares carry the whole `days` map inside payload —
      // the inbox card just needs the title + sender, and the import
      // handler reads back `payload.days` for the planner merge.
      return InboxMessage(
        id:         row['id'] as String,
        fromHandle: payload['sender_handle'] as String? ?? 'Someone',
        listName:   payload['title']
                ?? payload['list_name']
                ?? 'Shared Meal Plan',
        listId:     row['id'] as String,
        items:      const [],
        kind:       InboxMessageKind.mealPlan,
        receivedAt: received,
      );
    }
    if (kind == InboxMessageKind.recipe) {
      return InboxMessage(
        id:         row['id'] as String,
        fromHandle: payload['sender_handle'] as String? ?? 'Someone',
        listName:   payload['recipe_title']  as String? ?? 'Shared Recipe',
        listId:     payload['recipe_id']     as String? ?? row['id'] as String,
        items:      const [],
        kind:       InboxMessageKind.recipe,
        recipeIngredients: (payload['ingredients'] as List<dynamic>?)
                ?.map((e) {
                  if (e is Map && e['name'] != null) return e['name'].toString();
                  return e.toString();
                })
                .toList() ?? const <String>[],
        recipeInstructions: (payload['instructions'] as List<dynamic>?)
                ?.map((e) => e.toString())
                .toList() ?? const <String>[],
        receivedAt: received,
      );
    }
    final itemsJson = (payload['items'] as List<dynamic>?) ?? [];
    return InboxMessage(
      id:         row['id'] as String,
      fromHandle: payload['sender_handle'] as String? ?? 'Someone',
      listName:   payload['list_name']    as String? ?? 'Shared List',
      listId:     payload['list_id']      as String? ?? row['id'] as String,
      items:      itemsJson
          .map((e) => ShoppingItem.fromJson(e as Map<String, dynamic>))
          .toList(),
      kind:       InboxMessageKind.shoppingList,
      receivedAt: received,
    );
  }
}
