import '../utils/measurement_format.dart';

class Ingredient {
  final double? quantity;
  final String? unit;
  final String name;
  final String? localizedName;

  const Ingredient({
    this.quantity,
    this.unit,
    required this.name,
    this.localizedName,
  });

  // The name shown to the user — falls back to the original if no localized name exists.
  String get displayName => localizedName ?? name;

  Map<String, dynamic> toJson() => {
        'quantity': quantity,
        'unit': unit,
        'name': name,
        'localizedName': localizedName,
      };

  factory Ingredient.fromJson(Map<String, dynamic> json) => Ingredient(
        quantity: (json['quantity'] as num?)?.toDouble(),
        unit: json['unit'] as String?,
        name: json['name'] as String,
        localizedName: json['localizedName'] as String?,
      );

  /// Single source of truth for "qty unit name" rendering across the
  /// app. Delegates to [formatIngredientLine] so imperial units (cups,
  /// tsp, tbsp) are auto-converted to SA metric (g / ml) and quantities
  /// are snapped to clean kitchen numbers. Every call site that used
  /// `.toString()` for ingredients now picks up the conversion
  /// automatically.
  @override
  String toString() => formatIngredientLine(this);
}
