// lib/models/hub_model.dart
//
// Maps a row returned by the Supabase RPC `get_nearest_hubs`. The function
// is backed by a PostGIS index over ~12k SA neighbourhood anchor points
// (see migration 20260602_hubs_postgis.sql) and returns the rows ranked by
// great-circle distance from a (lat, lon) query point.
//
// Wire format (one row):
//   {
//     "id":               "<uuid>",
//     "name":             "Table View",
//     "slug":             "table-view",
//     "province":         "Western Cape",
//     "distance_meters":  842.17
//   }

class HubModel {
  const HubModel({
    required this.id,
    required this.name,
    required this.slug,
    required this.province,
    required this.distanceMeters,
  });

  final String id;
  final String name;
  final String slug;
  final String province;
  final double distanceMeters;

  factory HubModel.fromJson(Map<String, dynamic> json) {
    return HubModel(
      id:             json['id']       as String,
      name:           json['name']     as String,
      slug:           json['slug']     as String,
      province:       json['province'] as String? ?? '',
      distanceMeters: (json['distance_meters'] as num?)?.toDouble() ?? 0.0,
    );
  }

  Map<String, dynamic> toJson() => {
        'id':              id,
        'name':            name,
        'slug':            slug,
        'province':        province,
        'distance_meters': distanceMeters,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is HubModel && other.id == id);

  @override
  int get hashCode => id.hashCode;
}
