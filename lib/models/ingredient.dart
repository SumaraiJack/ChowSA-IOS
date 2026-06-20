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

  @override
  String toString() {
    final qty = quantity != null ? '${quantity!.toStringAsFixed(quantity! % 1 == 0 ? 0 : 1)} ' : '';
    final u = unit != null ? '$unit ' : '';
    return '$qty$u$displayName';
  }
}
