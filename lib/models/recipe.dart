import 'ingredient.dart';

class Recipe {
  final String title;
  final List<Ingredient> ingredients;
  final List<String> instructions;
  final bool isLoadsheddingFriendly;
  // True only when the method explicitly uses a braai grid, kettle braai,
  // potjie pot, or open fire/coals. Gas hob, oven, stovetop, and no-cook
  // recipes are false. Defaults to false for backward-compat with cached data.
  final bool isBraaiReady;
  final String? sourceUrl;

  /// Optional reference id pointing back to the canonical record this
  /// recipe was instantiated from. Used by the meal planner so a tile
  /// can re-fetch full ingredients/instructions via [sourceType] when
  /// the user taps a planned meal. Null for custom-typed entries.
  final String? sourceId;

  /// What kind of record [sourceId] points at:
  ///   • 'mine'      — id in the user's `recipes` Supabase table.
  ///   • 'community' — id in the community recipe feed.
  /// Null for custom-typed entries.
  final String? sourceType;

  const Recipe({
    required this.title,
    required this.ingredients,
    required this.instructions,
    required this.isLoadsheddingFriendly,
    this.isBraaiReady = false,
    this.sourceUrl,
    this.sourceId,
    this.sourceType,
  });

  Map<String, dynamic> toJson() => {
        'title':                  title,
        'ingredients':            ingredients.map((i) => i.toJson()).toList(),
        'instructions':           instructions,
        'isLoadsheddingFriendly': isLoadsheddingFriendly,
        'isBraaiReady':           isBraaiReady,
        'sourceUrl':              sourceUrl,
        'sourceId':               sourceId,
        'sourceType':             sourceType,
      };

  factory Recipe.fromJson(Map<String, dynamic> json) => Recipe(
        title:                  json['title']  as String,
        ingredients: (json['ingredients'] as List<dynamic>)
            .map((e) => Ingredient.fromJson(e as Map<String, dynamic>))
            .toList(),
        instructions:           List<String>.from(json['instructions'] as List),
        // Null-safe: older cached recipes / Supabase rows before the migration
        // won't have these keys. Both check camelCase (Gemini JSON) AND
        // snake_case (Supabase row) so the same factory works for both sources.
        isLoadsheddingFriendly:
            (json['isLoadsheddingFriendly'] as bool?)
            ?? (json['is_loadshedding_friendly'] as bool?)
            ?? false,
        isBraaiReady:
            (json['isBraaiReady'] as bool?)
            ?? (json['is_braai_ready'] as bool?)
            ?? false,
        sourceUrl:
            (json['sourceUrl'] as String?)
            ?? (json['source_url'] as String?),
        sourceId:
            (json['sourceId'] as String?)
            ?? (json['source_id'] as String?),
        sourceType:
            (json['sourceType'] as String?)
            ?? (json['source_type'] as String?),
      );

  Recipe copyWith({
    String?            title,
    List<Ingredient>?  ingredients,
    List<String>?      instructions,
    bool?              isLoadsheddingFriendly,
    bool?              isBraaiReady,
    String?            sourceUrl,
    String?            sourceId,
    String?            sourceType,
  }) =>
      Recipe(
        title:                  title                  ?? this.title,
        ingredients:            ingredients            ?? this.ingredients,
        instructions:           instructions           ?? this.instructions,
        isLoadsheddingFriendly: isLoadsheddingFriendly ?? this.isLoadsheddingFriendly,
        isBraaiReady:           isBraaiReady           ?? this.isBraaiReady,
        sourceUrl:              sourceUrl              ?? this.sourceUrl,
        sourceId:               sourceId               ?? this.sourceId,
        sourceType:             sourceType             ?? this.sourceType,
      );
}
