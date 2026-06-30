// lib/services/community_hub_service.dart
//
// Data layer for the hyper-local Community Engine. Wraps the four tables
// introduced in 20260602_community_channels.sql:
//
//   • community_channels       — one row per (suburb, category) hub
//   • channel_messages         — chat history
//   • profiles.user_role       — RBAC discriminator
//   • public.is_admin(uuid)    — RLS helper exposed as PostgREST RPC
//
// All real-time fan-out uses Supabase's Postgres-changes channels so the UI
// can subscribe without polling.

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

// =============================================================================
//   Storage-key helper
// =============================================================================
//
// Generates a per-object key that is provably unique even under fast double-
// taps or simultaneous uploads from two devices for the same user. Combines
// `millisecondsSinceEpoch` (ordering + readability) with a `Random.secure()`
// 8-byte hex suffix (collision-resistant). Avoids adding a `uuid` dependency
// while satisfying the same guarantee as a `uuid.v4()`.
//
// Object key shape:  <uid>/<epoch_ms>_<16-hex-chars>.<ext>
//
// Owner-prefixed so the storage RLS policies (`owner = auth.uid()` on
// UPDATE/DELETE) line up cleanly with the path layout.
final _secureRandom = Random.secure();

String _uniqueObjectKey({required String uid, required String ext}) {
  final ms     = DateTime.now().millisecondsSinceEpoch;
  final bytes  = List<int>.generate(8, (_) => _secureRandom.nextInt(256));
  final suffix = bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  return '$uid/${ms}_$suffix.$ext';
}

String _extFromFilename(String filename, {String fallback = 'jpg'}) {
  if (!filename.contains('.')) return fallback;
  final ext = filename.split('.').last.toLowerCase();
  return ext.isEmpty ? fallback : ext;
}

// =============================================================================
//   COLD-START SAFEGUARD — community unlock threshold (WS4)
// =============================================================================
//
// A locality's channel set stays in a friendly "coming to your area" state
// until [kCommunityUnlockThreshold] distinct users have posted in any of
// its channels. Five empty channels per suburb look dead to a brand-new
// user; this gate protects the first impression without throttling the
// vision (see PLAN.md §WS4).
//
// Threshold is intentionally a single named constant so it can be tuned
// later without hunting through call sites. Active count comes from
// `public.get_locality_active_count(p_suburb)` (SECURITY DEFINER RPC).
const int kCommunityUnlockThreshold = 10;

// =============================================================================
//   ENUMS + MODELS
// =============================================================================

enum ChannelCategory { spotted, gatherings, pantry, cooking, braai }

extension ChannelCategoryX on ChannelCategory {
  String get wire => switch (this) {
        ChannelCategory.spotted    => 'spotted',
        ChannelCategory.gatherings => 'gatherings',
        ChannelCategory.pantry     => 'pantry',
        ChannelCategory.cooking    => 'cooking',
        ChannelCategory.braai      => 'braai',
      };

  String get displayName => switch (this) {
        ChannelCategory.spotted    => 'Spotted',
        ChannelCategory.gatherings => 'Gatherings',
        ChannelCategory.pantry     => 'The Pantry',
        ChannelCategory.cooking    => "What's Cooking",
        ChannelCategory.braai      => 'Braai',
      };

  String get tagline => switch (this) {
        ChannelCategory.spotted    => 'Live food trucks & pop-ups',
        ChannelCategory.gatherings => 'Markets, potjies & festivals',
        ChannelCategory.pantry     => 'Grocery deals & stock alerts',
        ChannelCategory.cooking    => 'Local daily social feed',
        ChannelCategory.braai      => 'Coals, sosaties & boerie-roll inspo',
      };

  String get emoji => switch (this) {
        ChannelCategory.spotted    => '🚚',
        ChannelCategory.gatherings => '🎪',
        ChannelCategory.pantry     => '🏷️',
        ChannelCategory.cooking    => '🍳',
        ChannelCategory.braai      => '🔥',
      };

  /// Longer SA-flavoured one-liner rendered under the chat header inside
  /// each category's room. Distinct from [tagline] (which is the short
  /// status-card subtitle on the Community Hub dashboard).
  String get flavourLine => switch (this) {
        ChannelCategory.spotted    =>
          'Catch the local food trucks, pop-ups, and legendary street food '
          'before they move on!',
        ChannelCategory.gatherings =>
          'Local markets, potjies, and food festivals. Find out where the '
          'gees is at!',
        ChannelCategory.pantry     =>
          'Spot a massive grocery deal or a stock alert? Share it so the '
          'community can save!',
        ChannelCategory.cooking    =>
          'Showing off your dinner or looking for culinary inspiration? '
          'Post your daily chow here!',
        ChannelCategory.braai      =>
          'Coals, chops, marinade tips, and braai banter. Strictly for the '
          'masters of the fire!',
      };

  static ChannelCategory? fromWire(String? s) => switch (s) {
        'spotted'    => ChannelCategory.spotted,
        'gatherings' => ChannelCategory.gatherings,
        'pantry'     => ChannelCategory.pantry,
        'cooking'    => ChannelCategory.cooking,
        'braai'      => ChannelCategory.braai,
        _            => null,
      };
}

class CommunityChannel {
  CommunityChannel({
    required this.id,
    required this.name,
    required this.suburb,
    required this.category,
    required this.pinnedMessageId,
    required this.createdAt,
  });

  final String           id;
  final String           name;
  final String           suburb;
  final ChannelCategory  category;
  final String?          pinnedMessageId;
  final DateTime         createdAt;

  factory CommunityChannel.fromRow(Map<String, dynamic> r) => CommunityChannel(
        id:              r['id']                as String,
        name:            r['name']              as String,
        suburb:          r['suburb']            as String,
        category:        ChannelCategoryX.fromWire(r['category'] as String?)
                            ?? ChannelCategory.cooking,
        pinnedMessageId: r['pinned_message_id'] as String?,
        createdAt:       DateTime.parse(r['created_at'] as String),
      );

  CommunityChannel copyWith({String? pinnedMessageId}) => CommunityChannel(
        id:              id,
        name:            name,
        suburb:          suburb,
        category:        category,
        pinnedMessageId: pinnedMessageId,
        createdAt:       createdAt,
      );
}

class ChannelMessage {
  ChannelMessage({
    required this.id,
    required this.channelId,
    required this.userId,
    required this.messageText,
    required this.eventTimestamp,
    required this.createdAt,
    this.authorHandle,
    this.authorAvatarUrl,
    this.imageUrl,
    this.latitude,
    this.longitude,
    this.locationName,
    this.isSpotPin = false,
  });

  final String     id;
  final String     channelId;
  final String?    userId;
  final String     messageText;
  final DateTime?  eventTimestamp;
  final DateTime   createdAt;

  /// Optional, hydrated by `fetchMessages` via the joined `profiles` row.
  final String?    authorHandle;

  /// Optional avatar URL from `profiles.avatar_url` (also via the join).
  final String?    authorAvatarUrl;

  /// Optional public URL of an image attached to this message — uploaded to
  /// the `whats-cooking-pics` storage bucket by the composer attach button.
  final String?    imageUrl;

  /// Optional WGS-84 location pin attached to this message. Used by the
  /// Spotted channel when a user drops a pin on a food truck / pop-up.
  /// `latitude` and `longitude` are paired — a DB CHECK constraint
  /// enforces that they are either both null or both present (and in
  /// valid WGS-84 ranges). `locationName` is a free-text human label.
  final double?    latitude;
  final double?    longitude;
  final String?    locationName;

  /// True when this message is a Spotted location drop (food truck,
  /// pop-up, etc). Mirrored by the `is_spot_pin` column with a default of
  /// false, so plain chat messages stay flagged false without any client
  /// having to set it explicitly.
  final bool       isSpotPin;

  bool get hasEvent    => eventTimestamp != null;
  bool get hasImage    => imageUrl != null && imageUrl!.isNotEmpty;
  /// Spotted pin coords must be present AND non-zero. (0,0) is in the
  /// Gulf of Guinea — a known "null island" sentinel for missing GPS
  /// fixes. Rendering a pin there made the marker appear "intermittent"
  /// because some rows arrived from older clients with 0/0 instead of
  /// null and the chip silently linked to a random spot in the ocean.
  bool get hasLocation =>
      latitude  != null && longitude != null &&
      latitude  != 0    && longitude != 0;

  factory ChannelMessage.fromRow(Map<String, dynamic> r) {
    final profile = r['profiles'];
    String? handle;
    String? avatar;
    if (profile is Map<String, dynamic>) {
      handle = profile['handle']     as String?
            ?? profile['username']   as String?;
      avatar = profile['avatar_url'] as String?;
    }
    // Coordinates: PostgREST returns numerics as either `int` or `double`
    // depending on whether they have a fractional part. Coerce both via
    // num.toDouble() so we never crash on a coord that happens to be a
    // whole number like 0 or -90.
    final lat = r['latitude'];
    final lng = r['longitude'];
    return ChannelMessage(
      id:             r['id']              as String,
      channelId:      r['channel_id']      as String,
      userId:         r['user_id']         as String?,
      messageText:    r['message_text']    as String,
      eventTimestamp: r['event_timestamp'] == null
          ? null
          : DateTime.parse(r['event_timestamp'] as String),
      createdAt:      DateTime.parse(r['created_at'] as String),
      authorHandle:   handle,
      authorAvatarUrl: avatar,
      imageUrl:       r['image_url'] as String?,
      latitude:       lat is num ? lat.toDouble() : null,
      longitude:      lng is num ? lng.toDouble() : null,
      locationName:   r['location_name'] as String?,
      isSpotPin:      (r['is_spot_pin'] as bool?) ?? false,
    );
  }

  /// Wire-format map for INSERT/UPDATE against `channel_messages`. Optional
  /// fields are OMITTED rather than written as nulls so the database
  /// defaults (e.g. `is_spot_pin = false`) and the CHECK constraints (e.g.
  /// both-or-neither coords) are respected cleanly.
  Map<String, dynamic> toRow() {
    final hasCoords = latitude != null && longitude != null;
    return <String, dynamic>{
      'id':           id,
      'channel_id':   channelId,
      if (userId != null)         'user_id':         userId,
      'message_text': messageText,
      if (eventTimestamp != null) 'event_timestamp': eventTimestamp!.toUtc().toIso8601String(),
      'created_at':   createdAt.toUtc().toIso8601String(),
      if (imageUrl != null && imageUrl!.isNotEmpty) 'image_url': imageUrl,
      // Both-or-neither — never write a half-populated coord pair. The DB
      // CHECK would reject it anyway, but we filter client-side first to
      // surface clearer errors.
      if (hasCoords) 'latitude':  latitude,
      if (hasCoords) 'longitude': longitude,
      if (locationName != null && locationName!.isNotEmpty)
        'location_name': locationName,
      // Only write is_spot_pin when explicitly true. False is the column
      // default, so we let the DB fill it for plain chat messages.
      if (isSpotPin) 'is_spot_pin': true,
    };
  }
}

// =============================================================================
//   SERVICE
// =============================================================================

class CommunityHubService {
  CommunityHubService._();
  static final instance = CommunityHubService._();

  SupabaseClient get _sb => Supabase.instance.client;

  // ── Suburb resolution ─────────────────────────────────────────────────────

  /// Resolves the active suburb for the current user.
  ///
  /// Resolution order:
  ///   1. `profiles.cooking_preferences->>'suburb_district'`  (preferred)
  ///   2. `profiles.cooking_preferences->>'suburb'`
  ///   3. `profiles.cooking_preferences->>'city'`
  ///   4. Fallback: `'Table View'` — one of the seeded pilot suburbs so the
  ///      dashboard still renders the four hub cards out of the box.
  ///
  /// Reads against `cooking_preferences` (jsonb) because the deployed
  /// `profiles` schema doesn't carry dedicated suburb / city columns yet —
  /// location metadata is persisted into that JSON blob from the loadshedding
  /// flow + weather service.
  Future<String> resolveActiveSuburb() async {
    final uid = _sb.auth.currentUser?.id;
    if (uid == null) return 'Table View';
    try {
      final row = await _sb
          .from('profiles')
          .select('cooking_preferences')
          .eq('id', uid)
          .maybeSingle();
      final prefs = row?['cooking_preferences'];
      if (prefs is Map<String, dynamic>) {
        final s = (prefs['suburb_district'] as String?)?.trim()
            ?? (prefs['suburb'] as String?)?.trim()
            ?? (prefs['city']   as String?)?.trim();
        if (s != null && s.isNotEmpty) return s;
      }
      return 'Table View';
    } catch (_) {
      return 'Table View';
    }
  }

  // ── Locality active count (WS4 cold-start gate) ─────────────────────────
  //
  // Distinct authors who have posted in any channel of the given suburb.
  // Backed by the SECURITY DEFINER RPC `get_locality_active_count` so the
  // count is honest even when the caller can't read the underlying rows
  // (e.g. a viewer in a different suburb). Falls back to 0 on failure so
  // the gate fails closed (UI keeps the friendly "coming soon" state
  // rather than opening on a flaky network).
  Future<int> getLocalityActiveCount(String suburb) async {
    final clean = suburb.trim();
    if (clean.isEmpty) return 0;
    try {
      final res = await _sb.rpc(
        'get_locality_active_count',
        params: {'p_suburb': clean},
      );
      if (res is int)    return res;
      if (res is num)    return res.toInt();
      if (res is String) return int.tryParse(res) ?? 0;
      return 0;
    } catch (_) {
      return 0;
    }
  }

  // ── Admin check (RBAC) ────────────────────────────────────────────────────

  /// Server-side authoritative answer: calls the `public.is_admin()` RPC
  /// from the migration. Falls back to a direct `user_role` select if the
  /// RPC isn't exposed yet.
  Future<bool> isCurrentUserAdmin() async {
    final uid = _sb.auth.currentUser?.id;
    if (uid == null) return false;
    try {
      final res = await _sb.rpc('is_admin', params: {'uid': uid});
      if (res is bool) return res;
    } catch (_) {
      // Fall through to the direct lookup below.
    }
    try {
      final row = await _sb
          .from('profiles')
          .select('user_role')
          .eq('id', uid)
          .maybeSingle();
      return (row?['user_role'] as String?) == 'admin';
    } catch (_) {
      return false;
    }
  }

  // ── Channels ──────────────────────────────────────────────────────────────

  /// One-shot fetch of the 4 channels for the supplied [suburb]. Used as the
  /// initial paint on the dashboard before the realtime stream catches up.
  Future<List<CommunityChannel>> fetchChannelsForSuburb(String suburb) async {
    final rows = await _sb
        .from('community_channels')
        .select()
        .eq('suburb', suburb)
        .order('category');
    return (rows as List)
        .cast<Map<String, dynamic>>()
        .map(CommunityChannel.fromRow)
        .toList();
  }

  /// Exact-match channel lookup: returns the (suburb, category) row when it
  /// exists, otherwise null. Used as the authoritative resolver for the
  /// Community Hub's category cards so taps always land in the caller's own
  /// suburb room — not in a sibling suburb or the GLOBAL fallback.
  Future<CommunityChannel?> findChannelForSuburbAndCategory(
    String suburb,
    ChannelCategory category,
  ) async {
    final row = await _sb
        .from('community_channels')
        .select()
        .eq('suburb',   suburb)
        .eq('category', category.wire)
        .maybeSingle();
    if (row == null) return null;
    return CommunityChannel.fromRow(Map<String, dynamic>.from(row));
  }

  /// Cross-suburb fallback for [category]. Used ONLY when the caller's
  /// suburb has no seeded row — the previous behaviour preferred GLOBAL,
  /// but for `cooking` the GLOBAL row is the World Cup Stadium chat (a
  /// completely separate room) which made What's Cooking posts appear to
  /// "vanish" — they were being written into the stadium chat on the
  /// first cold open before the per-suburb stream had finished loading.
  /// We now SKIP GLOBAL by default and return the alphabetically-first
  /// in-suburb row, which is always a real per-suburb hub.
  Future<CommunityChannel?> findAnyChannelForCategory(
    ChannelCategory category, {
    bool allowGlobal = false,
  }) async {
    final rows = await _sb
        .from('community_channels')
        .select()
        .eq('category', category.wire)
        .order('suburb');
    final list = (rows as List)
        .cast<Map<String, dynamic>>()
        .map(CommunityChannel.fromRow)
        .toList();
    if (list.isEmpty) return null;
    final nonGlobal = list.where((c) => c.suburb != 'GLOBAL').toList();
    if (nonGlobal.isNotEmpty) return nonGlobal.first;
    return allowGlobal ? list.first : null;
  }

  /// Live stream of every `community_channels` row, filtered client-side to
  /// the active [suburb]. Uses the realtime publication added in the
  /// migration so pinned-message-id changes propagate to the chat banner
  /// without a manual refetch.
  Stream<List<CommunityChannel>> watchChannelsForSuburb(String suburb) {
    return _sb
        .from('community_channels')
        .stream(primaryKey: ['id'])
        .map((rows) => rows
            .where((r) => r['suburb'] == suburb)
            .map(CommunityChannel.fromRow)
            .toList()
          ..sort((a, b) => a.category.wire.compareTo(b.category.wire)));
  }

  /// Single-channel watcher — used by the chat screen to keep
  /// `pinned_message_id` reactive in the banner header.
  Stream<CommunityChannel?> watchChannel(String channelId) {
    return _sb
        .from('community_channels')
        .stream(primaryKey: ['id'])
        .eq('id', channelId)
        .map((rows) => rows.isEmpty
            ? null
            : CommunityChannel.fromRow(rows.first));
  }

  // ── Messages ──────────────────────────────────────────────────────────────

  /// Initial message history with author handles joined in.
  Future<List<ChannelMessage>> fetchMessages(String channelId,
      {int limit = 100}) async {
    final rows = await _sb
        .from('channel_messages')
        .select('*, profiles:user_id ( handle, username, avatar_url )')
        .eq('channel_id', channelId)
        .order('created_at', ascending: false)
        .limit(limit);
    return (rows as List)
        .cast<Map<String, dynamic>>()
        .map(ChannelMessage.fromRow)
        .toList()
        .reversed
        .toList();
  }

  /// Realtime stream of messages in a single channel, oldest → newest. Author
  /// handles are NOT joined here (Supabase realtime can't join across tables),
  /// so the UI should use [fetchMessages] for first paint and merge new rows
  /// from this stream on top.
  Stream<List<ChannelMessage>> watchMessages(String channelId) {
    return _sb
        .from('channel_messages')
        .stream(primaryKey: ['id'])
        .eq('channel_id', channelId)
        .order('created_at')
        .map((rows) =>
            rows.map(ChannelMessage.fromRow).toList());
  }

  Future<ChannelMessage> postMessage({
    required String   channelId,
    required String   text,
    DateTime?         eventTimestamp,
    String?           imageUrl,
    double?           latitude,
    double?           longitude,
    String?           locationName,
    bool              isSpotPin = false,
  }) async {
    final uid = _sb.auth.currentUser?.id;
    if (uid == null) {
      throw StateError('Must be signed in to post.');
    }
    // Both-or-neither client-side gate. The DB CHECK constraint
    // (channel_messages_coords_paired) enforces this server-side too —
    // we filter here to surface clearer errors before the round-trip.
    final hasCoords = latitude != null && longitude != null;
    final inserted = await _sb
        .from('channel_messages')
        .insert({
          'channel_id':      channelId,
          'user_id':         uid,
          'message_text':    text.trim(),
          'event_timestamp': eventTimestamp?.toUtc().toIso8601String(),
          // image_url is only included when an attachment was actually
          // uploaded — keeps the column NULL for plain text messages and
          // avoids painting a broken-image placeholder on the bubble.
          if (imageUrl != null && imageUrl.isNotEmpty) 'image_url': imageUrl,
          // Spotted location pin: lat/lng are written as a pair or not at
          // all. is_spot_pin is only sent when true (column default is
          // false, so plain chat messages stay flagged false without us
          // having to say so explicitly).
          if (hasCoords) 'latitude':      latitude,
          if (hasCoords) 'longitude':     longitude,
          if (locationName != null && locationName.isNotEmpty)
            'location_name': locationName,
          if (isSpotPin) 'is_spot_pin': true,
        })
        .select()
        .single();
    return ChannelMessage.fromRow(inserted);
  }

  // ── Image upload ──────────────────────────────────────────────────────────

  /// Uploads [bytes] into the `whats-cooking-pics` storage bucket and returns
  /// the public URL of the **newly-created** object. Throws on auth failure
  /// or upload error so the caller can roll back the optimistic state.
  ///
  /// Object key: see [_uniqueObjectKey]. The key combines epoch-ms with a
  /// secure-random 8-byte suffix so two uploads in the same millisecond (or
  /// from two devices for the same user) can never collide and overwrite
  /// each other's cached assets — the previous `<uid>/<epoch_ms>.<ext>`
  /// shape was responsible for old-image ghosting into new posts.
  ///
  /// `upsert: false` is critical: it asks the storage API to refuse the
  /// write if the key already exists, turning any residual collision into
  /// a hard error instead of a silent overwrite.
  Future<String> uploadWhatsCookingImage(
    Uint8List bytes, {
    required String filename,
    String? contentType,
  }) async {
    final uid = _sb.auth.currentUser?.id;
    if (uid == null) {
      throw StateError('Must be signed in to upload images.');
    }
    final ext = _extFromFilename(filename);
    final key = _uniqueObjectKey(uid: uid, ext: ext);

    await _sb.storage.from('whats-cooking-pics').uploadBinary(
          key,
          bytes,
          fileOptions: FileOptions(
            contentType: contentType ?? 'image/$ext',
            upsert:      false,
          ),
        );
    // getPublicUrl is a deterministic string-builder over the supplied key —
    // returning it AFTER the await guarantees the URL points at the exact
    // object we just wrote, never a stale namesake.
    return _sb.storage.from('whats-cooking-pics').getPublicUrl(key);
  }

  /// Uploads [file] into the `posts` storage bucket (community feed photos)
  /// and returns the public URL of the newly-created object. Same uniqueness
  /// guarantee as [uploadWhatsCookingImage] — see [_uniqueObjectKey].
  ///
  /// Centralised here (rather than inline in community_feed_screen) so both
  /// upload surfaces share a single, audited object-key generator.
  Future<String> uploadCommunityFeedImage(
    File file, {
    String? filename,
    String? contentType,
  }) async {
    final uid = _sb.auth.currentUser?.id;
    if (uid == null) {
      throw StateError('Must be signed in to upload images.');
    }
    final ext = _extFromFilename(filename ?? file.path);
    final key = _uniqueObjectKey(uid: uid, ext: ext);

    await _sb.storage.from('posts').upload(
          key,
          file,
          fileOptions: FileOptions(
            contentType: contentType ?? 'image/$ext',
            upsert:      false,
          ),
        );
    return _sb.storage.from('posts').getPublicUrl(key);
  }

  // ── Pin / Unpin (admin) ───────────────────────────────────────────────────

  /// Sets [messageId] as the channel's pinned message. Pass `null` to clear
  /// the pin. RLS on `community_channels` blocks this unless the caller is
  /// an admin — the migration's `community_channels_admin_write` policy.
  Future<void> setPinnedMessage({
    required String  channelId,
    required String? messageId,
  }) async {
    await _sb
        .from('community_channels')
        .update({'pinned_message_id': messageId})
        .eq('id', channelId);
  }

  // ── Message deletion + storage cleanup ────────────────────────────────────
  //
  // The previous delete path only removed the `channel_messages` row, which
  // left the uploaded photo orphaned in the `whats-cooking-pics` storage
  // bucket forever. The row delete and the storage cleanup now live behind a
  // single service entry point so the two can't drift apart, and any storage
  // failure is swallowed so a missing-object never bubbles up as a UI error.

  /// Deletes [message]'s row from `channel_messages` and, if the row carried
  /// an `image_url`, also removes the underlying object from the
  /// `whats-cooking-pics` storage bucket.
  ///
  /// The row delete is awaited first and its result is authoritative — if the
  /// DB call throws, this method throws and no storage call is made. The
  /// storage cleanup that follows is wrapped in its own try/catch so a
  /// missing-object / network blip can't propagate as an unhandled error
  /// after the row is already gone.
  Future<void> deleteChannelMessage(ChannelMessage message) async {
    await _sb
        .from('channel_messages')
        .delete()
        .eq('id', message.id);

    final url = message.imageUrl;
    if (url == null || url.isEmpty) return;

    final key = _storageKeyFromPublicUrl(url, bucket: 'whats-cooking-pics');
    if (key == null) return;

    try {
      await _sb.storage.from('whats-cooking-pics').remove([key]);
    } catch (e) {
      // Best-effort cleanup. The row is already gone; if the object is
      // missing (already cleaned up, or never uploaded successfully) or the
      // remove() round-trip fails, we don't want to surface that to the UI.
      // Log so the orphan can be reaped by a background sweeper if needed.
      // ignore: avoid_print
      print('deleteChannelMessage: storage cleanup failed for $key: $e');
    }
  }

  /// Parses the object key out of a Supabase Storage public URL of the form
  ///   https://<project>.supabase.co/storage/v1/object/public/<bucket>/<key>
  /// Returns null if the URL doesn't reference [bucket] (defensive — protects
  /// against accidentally deleting from the wrong bucket if a row carries a
  /// URL that was rewritten or pointed elsewhere).
  String? _storageKeyFromPublicUrl(String url, {required String bucket}) {
    final marker = '/object/public/$bucket/';
    final i = url.indexOf(marker);
    if (i < 0) return null;
    final tail = url.substring(i + marker.length);
    // Strip any query string / fragment Supabase might append for cache
    // busting so the key matches the original upload exactly.
    final cleaned = tail.split('?').first.split('#').first;
    return cleaned.isEmpty ? null : cleaned;
  }
}
