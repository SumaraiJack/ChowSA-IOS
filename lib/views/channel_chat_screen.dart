// lib/views/channel_chat_screen.dart
//
// Real-time chat for a single community_channel row. Three responsibilities
// stack vertically below the AppBar:
//
//   1. Sticky Pinned Announcement Banner    — Soft Cream + Mango Gold pin,
//                                              visible when pinned_message_id
//                                              is non-null. Hosts the
//                                              "Remind Me" 🔔 button when the
//                                              pinned message carries an
//                                              event_timestamp.
//   2. Message list                          — oldest → newest; admin users
//                                              get a long-press contextual
//                                              "Pin / Unpin" action.
//   3. Composer                              — text + optional event time.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/social_service.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/ingredient.dart';
import '../models/recipe.dart';
import '../utils/measurement_format.dart';
import '../services/community_hub_service.dart';
import '../services/event_reminder_service.dart';
import '../services/image_compression_service.dart';
import '../services/location_permission_gate.dart';
import '../services/media_quota_service.dart';
import '../services/moderation_service.dart';
import '../services/recipe_repository.dart';
import '../state/chat_bubble_theme.dart';
import '../theme/app_theme.dart';
import '../widgets/mention_suggestion_field.dart';
import '../widgets/motion.dart';
import 'chat_image_lightbox.dart';
import 'chat_reaction_overlay.dart';

// Hidden markers appended by RecipeShareService. The `shared_recipe` form
// (current) points at a row in the public shared_recipes snapshot table
// so ANY viewer can open it. The `recipe` form is a legacy marker that
// points at the sharer's private recipes row — kept for backward compat
// with messages posted before the shared_recipes migration.
final RegExp _kSharedRecipeMarker =
    RegExp(r'\[shared_recipe:([0-9a-fA-F-]{32,36})\]');
final RegExp _kLegacyRecipeMarker =
    RegExp(r'\[recipe:([0-9a-fA-F-]{32,36})\]');
final RegExp _kAnyRecipeMarker =
    RegExp(r'\[(?:shared_)?recipe:([0-9a-fA-F-]{32,36})\]');

/// PR 4: Process-wide cache of resolved avatar URLs, keyed by user_id.
/// Once one bubble has resolved an author's avatar (own session, RPC, or
/// seed-join), every subsequent bubble belonging to the same author reads
/// from the cache instead of refetching. Fixes the intermittent "S"
/// fallback we saw across screenshots 44537 / 44540 — the previous code
/// re-read `userMetadata['avatar_url']` per bubble, which is null for any
/// user whose avatar was set via `profiles.avatar_url` update (the path
/// the avatar picker uses).
///
/// Stores null sentinels too, so a known-no-avatar user doesn't trigger
/// repeated lookups. Cleared on a full process restart only.
final Map<String, String?> _chatAvatarCache = <String, String?>{};

/// State payload for an open reaction overlay. Captures the targeted
/// message, its pinned-state, and the screen rect of its bubble at the
/// moment of long-press so the overlay can position the floating strip
/// relative to it. Constructed by [_ChannelChatScreenState._openReactionMenu]
/// and cleared by [_ChannelChatScreenState._closeReactionMenu].
class _ReactionTarget {
  const _ReactionTarget({
    required this.message,
    required this.isPinned,
    required this.rect,
  });
  final ChannelMessage message;
  final bool           isPinned;
  final Rect           rect;
}

class ChannelChatScreen extends StatefulWidget {
  const ChannelChatScreen({
    super.key,
    required this.channelId,
    required this.isAdmin,
    this.displaySuburbOverride,
    this.initialMessageId,
  });

  final String channelId;
  final bool   isAdmin;

  /// Optional suburb label to render in the app-bar title / subtitle
  /// REGARDLESS of which suburb the underlying channel row belongs to.
  /// Used when the hub falls back to a cross-suburb channel (e.g. GLOBAL
  /// What's Cooking) but we still want the header to read in the user's
  /// active local context — "#TableView-WhatsCooking" instead of the raw
  /// "#GLOBAL-WhatsCooking".
  final String? displaySuburbOverride;

  /// Optional message id to scroll into view + briefly highlight on first
  /// paint. Used by the @mention push notification deep-link so tapping
  /// "SumaraiJack mentioned you" lands you on the exact bubble that
  /// contains the @-tag. Reuses the pinned-banner jump scaffolding
  /// (_bubbleKeys / _highlightedMessageId / _highlightTimer).
  final String? initialMessageId;

  @override
  State<ChannelChatScreen> createState() => _ChannelChatScreenState();
}

class _ChannelChatScreenState extends State<ChannelChatScreen> {
  final _composerController = TextEditingController();
  final _scrollController   = ScrollController();

  /// Initial fetch results, hydrated with author handles.
  Map<String, ChannelMessage> _seedMessages = {};
  bool _seeded = false;

  // ── Local optimistic state ───────────────────────────────────────────────
  // Deleted/edited messages are reflected locally immediately so the UI
  // doesn't wait for the Supabase realtime event to round-trip. The realtime
  // stream will eventually converge to the same state.
  final Set<String>     _deletedIds  = {};
  final Map<String,String> _editedTexts = {};

  // ── Search (category-scoped) ─────────────────────────────────────────────
  // Filter is applied client-side against the current channel's stream:
  //   • The query matches case-insensitively against message text…
  //   • …OR against the post author's resolved handle (cached in
  //     `_userHandleCache` once a bubble has resolved it via the
  //     `get_public_profile` RPC).
  // Toggling search resets the focus + scroll so the user lands at the
  // top of the filtered results.
  bool _searchActive = false;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  final FocusNode             _searchFocus      = FocusNode();
  final Map<String, String>   _userHandleCache  = {};

  /// Last non-null channel row seen by the StreamBuilder. When the realtime
  /// stream momentarily emits null (reconnect blip, RLS re-evaluation,
  /// publication catch-up), we render the cached row instead of letting
  /// the header revert to "#channel" with no subtitle.
  CommunityChannel? _lastResolvedChannel;

  /// Optional event timestamp the user attached to the next message.
  DateTime? _draftEventTimestamp;

  /// Optional image the user picked for the next message. Held in memory
  /// until _sendMessage uploads it to the `whats-cooking-pics` bucket and
  /// stamps the resulting public URL onto the channel_messages row.
  XFile? _draftImage;
  bool   _uploadingImage = false;

  /// Optional location pin the user dropped via the location IconButton.
  /// Lat/lng are stored together (the DB has a both-or-neither CHECK
  /// constraint, see migration 20260610_channel_messages_spot_pin.sql).
  /// `is_spot_pin = true` is sent alongside so the row is filterable on
  /// the Spotted-feed map view. Cleared after _sendMessage succeeds.
  double? _draftLatitude;
  double? _draftLongitude;
  /// Optional human-typed location label — "Engen garage Tableview",
  /// "Sea Point promenade", etc. When set without coords, the open-side
  /// chip hands this to Google Maps as a search query (geo:0,0?q=…)
  /// instead of opening a specific lat/lng. Lets users drop a pin for a
  /// food truck they saw across the street without driving over to it.
  String? _draftLocationName;
  bool    _fetchingLocation = false;

  // ── Pinned-banner jump scaffolding ───────────────────────────────────────
  //
  // When the pinned banner is tapped, we (a) scroll the chat list to the
  // pinned message's bubble and (b) flash a temporary gold highlight on it.
  // Implementation:
  //   • _bubbleKeys — one GlobalKey per visible message, attached to the
  //     bubble's outer Container, so we can call Scrollable.ensureVisible
  //     against a real BuildContext (the ListView is variable-height, so
  //     we can't compute an exact pixel offset from the index alone).
  //   • _highlightedMessageId — id of the bubble currently glowing. Cleared
  //     by [_highlightTimer] after the briefly-flash window elapses.
  final Map<String, GlobalKey> _bubbleKeys      = {};
  String?                      _highlightedMessageId;
  Timer?                       _highlightTimer;

  // ── PR 2: WhatsApp-parity reaction overlay ─────────────────────────────
  //
  // Long-press on a bubble captures the bubble's screen rect off its cached
  // GlobalKey, sets [_reactionTarget], and shows [_reactionPortal]. The
  // ListView's physics swap to NeverScrollableScrollPhysics for the
  // overlay's lifetime so the rect we captured stays accurate (the bubble
  // can't scroll out from under the floating strip). Dismiss / reaction /
  // action selection all run through [_closeReactionMenu] to teardown
  // cleanly.
  final OverlayPortalController _reactionPortal = OverlayPortalController();
  _ReactionTarget?              _reactionTarget;

  /// Cached realtime stream for the message list. Created ONCE in initState
  /// and reused across every build. The previous code called
  /// `watchMessages(...)` directly inside the StreamBuilder, which returned
  /// a fresh Stream object on every rebuild — so each setState (incl. the
  /// optimistic-delete `_deletedIds.add()` purge) tore down the live
  /// subscription and re-fetched the table, briefly resurrecting the deleted
  /// bubble until the realtime DELETE event arrived. Caching the stream
  /// keeps the optimistic purge sticky and stops the "delete only after
  /// re-entering the screen" symptom in What's Cooking.
  late final Stream<List<ChannelMessage>> _messagesStream;
  late final Stream<CommunityChannel?>    _channelStream;

  @override
  void initState() {
    super.initState();
    _messagesStream =
        CommunityHubService.instance.watchMessages(widget.channelId);
    _channelStream  =
        CommunityHubService.instance.watchChannel(widget.channelId);
    _loadInitialMessages();
  }

  Future<void> _loadInitialMessages() async {
    try {
      final list = await CommunityHubService.instance
          .fetchMessages(widget.channelId);
      if (!mounted) return;
      // Seed handle cache from the joined `profiles` payload so the
      // search filter can hit handles without waiting for each bubble
      // to mount + resolve.
      for (final m in list) {
        if (m.userId != null && m.authorHandle != null) {
          _userHandleCache[m.userId!] = m.authorHandle!;
        }
      }
      setState(() {
        _seedMessages = {for (final m in list) m.id: m};
        _seeded       = true;
      });
      // Best-effort fill in any user_ids the seed didn't carry handles
      // for (RLS hides the embedded join for non-self rows).
      unawaited(_hydrateMissingHandles(list.map((m) => m.userId).toSet()));

      // @mention deep-link: caller asked us to land on a specific message.
      // Defer a frame so the ListView has had time to build its bubbles
      // (the GlobalKeys we need are populated by itemBuilder), then reuse
      // the pinned-banner jump scaffolding to scroll + flash highlight.
      if (widget.initialMessageId != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _jumpToPinnedMessage(widget.initialMessageId!);
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _seeded = true);
    }
  }

  /// Fills in handles for any uids not already in [_userHandleCache] by
  /// calling the `get_public_profile` SECURITY DEFINER RPC. Single round
  /// trip per unknown uid; results power the username branch of the
  /// search filter.
  Future<void> _hydrateMissingHandles(Set<String?> uids) async {
    final missing = uids
        .whereType<String>()
        .where((u) => !_userHandleCache.containsKey(u))
        .toSet();
    if (missing.isEmpty) return;
    final db = Supabase.instance.client;
    for (final uid in missing) {
      try {
        final res = await db
            .rpc('get_public_profile', params: {'uid': uid});
        Map<String, dynamic>? row;
        if (res is List && res.isNotEmpty) {
          row = Map<String, dynamic>.from(res.first as Map);
        } else if (res is Map) {
          row = Map<String, dynamic>.from(res);
        }
        final h = (row?['handle']   as String?)
               ?? (row?['username'] as String?);
        if (h != null && mounted) {
          setState(() => _userHandleCache[uid] = h);
        }
      } catch (_) {/* swallow — search just won't match that user */}
    }
  }

  void _toggleSearch() {
    setState(() {
      _searchActive = !_searchActive;
      if (!_searchActive) {
        _searchQuery = '';
        _searchController.clear();
        _searchFocus.unfocus();
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _searchFocus.requestFocus();
        });
      }
    });
  }

  @override
  void dispose() {
    _composerController.dispose();
    _scrollController.dispose();
    _searchController.dispose();
    _searchFocus.dispose();
    _highlightTimer?.cancel();
    super.dispose();
  }

  // ── Pinned-banner tap handler ────────────────────────────────────────────
  //
  // Looks up the pinned bubble's GlobalKey, scrolls it into the upper third
  // of the viewport, and flashes the highlight for 1800 ms. If the message
  // isn't in the loaded list (rare — it'd mean the pinned id points at
  // history older than our fetch window), we surface a gentle snackbar
  // rather than navigating away.
  void _jumpToPinnedMessage(String messageId) {
    final ctx = _bubbleKeys[messageId]?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration:  const Duration(milliseconds: 420),
        curve:     Curves.easeInOutCubic,
        alignment: 0.25, // ~25 % from the viewport top — keeps context above
      );
      setState(() => _highlightedMessageId = messageId);
      _highlightTimer?.cancel();
      _highlightTimer = Timer(const Duration(milliseconds: 1800), () {
        if (!mounted) return;
        setState(() => _highlightedMessageId = null);
      });
      return;
    }
    // Fallback — pinned message isn't loaded in the current window.
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content:  Text('Loading pinned message…'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // ── Scroll-to-bottom helper ──────────────────────────────────────────────
  // Called from the message list builder. Uses addPostFrameCallback ONLY when
  // the widget is still mounted, which avoids the '_dependents.isEmpty' crash
  // that happens when the callback fires after the widget tree is disposed.
  /// Last observed bottom view inset (= soft-keyboard height). Tracked
  /// so [didChangeDependencies] can detect a 0 → positive transition
  /// and scroll the latest bubble back into view above the keyboard.
  double _lastViewInset = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    if (inset > _lastViewInset) {
      // Keyboard just opened. The Scaffold has already shrunk the body
      // and shifted the composer above the keyboard, but the ListView's
      // current scroll offset may now leave the last message hidden;
      // fire a post-frame scroll-to-bottom so it pops back into view.
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }
    _lastViewInset = inset;
  }

  void _scrollToBottom() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_scrollController.hasClients) return;
      final pos = _scrollController.position;
      // Only auto-scroll if within 200 px of the bottom so we don't
      // hijack the user's manual scroll position mid-thread.
      if (pos.maxScrollExtent - pos.pixels < 200) {
        _scrollController.animateTo(
          pos.maxScrollExtent,
          duration: const Duration(milliseconds: 220),
          curve:    Curves.easeOut,
        );
      }
    });
  }

  // ── Send ────────────────────────────────────────────────────────────────

  Future<void> _sendMessage() async {
    final text  = _composerController.text.trim();
    final image = _draftImage;
    // Allow sending a photo-only message (no caption), but block fully empty
    // sends so we never insert a NULL-message row.
    if (text.isEmpty && image == null) return;

    final messenger = ScaffoldMessenger.of(context); // capture before await
    final ts        = _draftEventTimestamp;
    final lat       = _draftLatitude;
    final lng       = _draftLongitude;
    final locName   = _draftLocationName;
    final hasCoords = lat != null && lng != null;
    final hasName   = locName != null && locName.trim().isNotEmpty;
    final hasPin    = hasCoords || hasName;

    // ── GPS guard on submit ───────────────────────────────────────────────
    // If a GPS-coords pin is staged, verify the OS Location toggle is
    // still ON before sending. Typed-location pins skip this — they
    // don't depend on the device GPS at all.
    if (hasCoords) {
      final servicesOn = await Geolocator.isLocationServiceEnabled();
      if (!mounted) return;
      if (!servicesOn) {
        messenger.showSnackBar(const SnackBar(
          content:  Text('Hey Chomma, turn your GPS on please 😁🇿🇦'),
          behavior: SnackBarBehavior.floating,
        ));
        return; // abort the send — composer stays intact
      }
    }

    // Optimistically clear the composer so the keyboard doesn't show a flicker
    // of "sent then re-rendered" text.
    _composerController.clear();
    setState(() {
      _draftEventTimestamp = null;
      _draftImage          = null;
      _draftLatitude       = null;
      _draftLongitude      = null;
      _draftLocationName   = null;
      if (image != null) _uploadingImage = true;
    });

    try {
      String? imageUrl;
      if (image != null) {
        final bytes = await image.readAsBytes();
        imageUrl = await CommunityHubService.instance.uploadWhatsCookingImage(
          bytes,
          filename:    image.name,
          contentType: image.mimeType,
        );
      }
      await CommunityHubService.instance.postMessage(
        channelId:      widget.channelId,
        text:           text.isEmpty ? '📷' : text,
        eventTimestamp: ts,
        imageUrl:       imageUrl,
        latitude:       hasCoords ? lat : null,
        longitude:      hasCoords ? lng : null,
        locationName:   hasName    ? locName.trim() : null,
        // Flag every message carrying a pin (coords OR typed label) as
        // a Spotted-pin row so the map view + filters can find it
        // without parsing message text.
        isSpotPin:      hasPin,
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content:  Text('Could not send: $e'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _uploadingImage = false);
    }
  }

  // ── Image attach ─────────────────────────────────────────────────────────
  //
  // Opens a small action sheet that routes to the camera or gallery via
  // image_picker. The selected XFile is held in [_draftImage] until the user
  // taps send — at which point _sendMessage uploads it to the
  // `whats-cooking-pics` bucket and stamps the public URL on the row.

  Future<void> _pickImage() async {
    // Freemium quota gate — free users get 1 free photo per day, two more
    // via rewarded ads (3/day hard cap). Pro skips this entirely.
    final ok = await MediaQuotaService.instance
        .requestUse(context, MediaKind.photo);
    if (!ok || !mounted) return;
    final source = await showModalBottomSheet<ImageSource>(
      context:         context,
      backgroundColor: AppTheme.kAlabaster,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Text('📷', style: TextStyle(fontSize: 22)),
              title:   const Text('Take a photo'),
              subtitle: const Text(
                'Snap your meal with the camera.',
                style: TextStyle(fontSize: 12),
              ),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Text('🖼️', style: TextStyle(fontSize: 22)),
              title:   const Text('Choose from gallery'),
              subtitle: const Text(
                'Pick an existing photo from your phone.',
                style: TextStyle(fontSize: 12),
              ),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;
    try {
      // PR 4: route through ImageCompressionService.pickForChat so the
      // platform-side downscale + JPEG re-encode runs at 1280 px / Q75
      // (WhatsApp-tuned). Previously we used 1920 / Q80 which often
      // exceeded 1 MB on portrait phone photos — the bytes hit Supabase
      // Storage uncompressed and every viewer scrolling past the bubble
      // paid the download cost.
      final picked = await ImageCompressionService.instance.pickForChat(
        source: source,
      );
      if (picked == null || !mounted) return;
      setState(() => _draftImage = picked);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content:  Text('Could not open picker: $e'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _pickEventTimestamp() async {
    final now  = DateTime.now();
    final date = await showDatePicker(
      context:     context,
      initialDate: now.add(const Duration(hours: 4)),
      firstDate:   now,
      lastDate:    now.add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context:     context,
      initialTime: TimeOfDay.fromDateTime(now.add(const Duration(hours: 4))),
    );
    if (time == null || !mounted) return;
    setState(() => _draftEventTimestamp =
        DateTime(date.year, date.month, date.day, time.hour, time.minute));
  }

  // ── Location pin ─────────────────────────────────────────────────────────
  //
  // Fetches the device's current GPS coordinates and stamps them onto the
  // next outgoing message. Used by the Spotted channel when a user wants
  // to drop a pin on a food truck / pop-up.
  //
  // Permission flow:
  //   1. Check current permission (no dialog).
  //   2. If denied (but NOT deniedForever), request — awaits the OS dialog.
  //   3. If deniedForever, surface a snackbar and bail. The user has to
  //      enable Location in OS Settings; we don't show our own dialog.
  //   4. With permission, fetch a single low-accuracy fix (city-level is
  //      plenty for "Spotted" purposes and is much faster + lower battery
  //      than high-accuracy). 6-second timeLimit so a hung GPS doesn't
  //      lock the composer indefinitely.
  Future<void> _pickLocation() async {
    if (_fetchingLocation) return;
    final messenger = ScaffoldMessenger.of(context);

    // Freemium quota gate — pin drops follow the same daily ladder as
    // photos (1 free + 2 ad-unlocked, capped at 3/day). Pro short-circuits.
    final ok = await MediaQuotaService.instance
        .requestUse(context, MediaKind.pin);
    if (!ok || !mounted) return;

    // Dismiss the soft keyboard first. With the keyboard up, a floating
    // snackbar surfaced by the GPS-off / permission-denied branches lands
    // BEHIND the IME and is invisible to the user — which is exactly
    // why this button felt dead when location services were off.
    FocusScope.of(context).unfocus();

    setState(() => _fetchingLocation = true);
    try {
      // ── GPS guard ─────────────────────────────────────────────────────
      // isLocationServiceEnabled checks the OS-level Location toggle (NOT
      // app permission — that's the next check below). If the user has
      // GPS switched off entirely, surface an actionable dialog (with an
      // "Open Settings" CTA) instead of a snackbar that the keyboard can
      // hide.
      final servicesOn = await Geolocator.isLocationServiceEnabled();
      if (!servicesOn) {
        if (!mounted) return;
        await _showLocationBlockedDialog(
          title:  'Turn on GPS to drop a pin',
          body:   'Your phone\'s location services are off. Switch them on '
                  'in Settings, then tap the pin again.',
          openSettings: () => Geolocator.openLocationSettings(),
        );
        return;
      }

      // App-wide gate keeps this in lock-step with the bootstrap requesters.
      final perm = await LocationPermissionGate.instance.ensure();
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        if (!mounted) return;
        await _showLocationBlockedDialog(
          title:  'Allow ChowSA to use your location',
          body:   perm == LocationPermission.deniedForever
              ? 'You\'ve permanently denied location access. Re-enable it '
                'in the system settings for ChowSA, then tap the pin again.'
              : 'Location permission is needed to drop a Spotted pin.',
          openSettings: () => Geolocator.openAppSettings(),
        );
        return;
      }

      // Route through the gate — dedupes against any concurrent startup
      // location fetch so we don't stack a second Play-Services accuracy
      // dialog on top of the user's pin-drop flow.
      final pos = await LocationPermissionGate.instance.getPosition(
        accuracy:  LocationAccuracy.low,
        timeLimit: const Duration(seconds: 6),
      );
      if (!mounted) return;

      // Strict null + null-island guard. The previous code silently
      // returned on `pos == null`, which made the pin button feel dead
      // when GPS couldn't get a fix (tunnel, indoor lock, A-GPS timeout).
      // (0,0) is the "no fix" sentinel some older Android builds return.
      final lat = pos?.latitude;
      final lng = pos?.longitude;
      final valid =
          lat != null && lng != null && lat != 0.0 && lng != 0.0;

      // Diagnostic — surfaces in `adb logcat` and the Dart DevTools
      // console so intermittent drop failures are debuggable on-device.
      debugPrint(
        '📍 Hub Map: Dropping pin for channel ${widget.channelId} '
        'at ($lat, $lng) — valid=$valid',
      );

      if (!valid) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'Location not set — could not get a GPS fix. '
              'Step outside or try again in a moment.',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }
      setState(() {
        _draftLatitude     = lat;
        _draftLongitude    = lng;
        _draftLocationName = null;  // GPS pin overrides any typed label
      });
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content:  Text('Could not fetch location: $e'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _fetchingLocation = false);
    }
  }

  /// Opens a small text dialog so the user can type a location label
  /// — "Engen garage Tableview", "Sea Point promenade", etc. — instead
  /// of attaching their GPS coords. Used by the "drive-past Spotted"
  /// flow: I'm not at the food truck but I want to drop a pin where
  /// it is. The typed label is stored on the next outgoing message
  /// (with no coords) and the open-side chip hands it to Google Maps
  /// as a search query.
  Future<void> _pickTypedLocation() async {
    // Same daily quota as a GPS pin — both ultimately become Spotted
    // entries that take up community-feed real estate.
    final ok = await MediaQuotaService.instance
        .requestUse(context, MediaKind.pin);
    if (!ok || !mounted) return;

    // Dialog body is a StatefulWidget so it owns the TextEditingController
    // and disposes it in its own [State.dispose]. Disposing the controller
    // from the *parent* after showDialog returned caused a framework
    // "_dependents.isEmpty" assertion: showDialog's Future completes when
    // Navigator.pop fires, NOT when the dialog's exit animation finishes,
    // so the embedded EditableText was still mid-tear-down when the
    // controller got disposed.
    final typed = await showDialog<String>(
      context: context,
      builder: (_) =>
          _TypedLocationDialog(initial: _draftLocationName ?? ''),
    );
    if (typed == null || typed.isEmpty || !mounted) return;
    setState(() {
      // Typed pin and GPS coords are mutually exclusive — store one or
      // the other, never both, so the chip never has to guess which
      // one the user actually wanted.
      _draftLocationName = typed;
      _draftLatitude     = null;
      _draftLongitude    = null;
    });
  }

  /// Modal dialog used by the location pin button when GPS is off or
  /// permission is denied. A modal is far more visible than a floating
  /// snackbar — the previous flow would surface a SnackBar that the soft
  /// keyboard hid, making the pin button feel completely dead.
  Future<void> _showLocationBlockedDialog({
    required String       title,
    required String       body,
    required Future<bool> Function() openSettings,
  }) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(title,
            style: const TextStyle(fontWeight: FontWeight.w800)),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              try {
                await openSettings();
              } catch (_) {/* settings page can't be opened — silent */}
            },
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );
  }

  // ── Pin / Unpin (admin only) ────────────────────────────────────────────

  Future<void> _togglePin(ChannelMessage msg, bool isPinned) async {
    final messenger = ScaffoldMessenger.of(context); // capture before await
    try {
      await CommunityHubService.instance.setPinnedMessage(
        channelId: widget.channelId,
        messageId: isPinned ? null : msg.id,
      );
      messenger.showSnackBar(
        SnackBar(
          content:  Text(isPinned ? 'Unpinned' : 'Pinned to channel'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content:  Text('Pin failed: $e'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  // (Legacy _showMessageActions bottom-sheet removed in PR 2 — long-press
  // now routes through _openReactionMenu → ChatReactionOverlay, which
  // dispatches Edit / Delete / Pin / Copy through the same downstream
  // handlers (_editMessage, _runDelete, _togglePin, _copyMessageText).)

  // ── Edit message ────────────────────────────────────────────────────────

  Future<void> _editMessage(ChannelMessage msg) async {
    // Capture messenger BEFORE any await so we never access BuildContext
    // after an async gap — this is the primary cause of the
    // '_dependents.isEmpty' assertion crash.
    final messenger = ScaffoldMessenger.of(context);

    // The dialog body lives in its own StatefulWidget (_EditMessageDialog)
    // which owns the TextEditingController in initState/dispose — NOT
    // inline in the build method. That guarantees the controller's
    // lifecycle is tied to the dialog's own Element, not this State's,
    // and prevents the '_dependents.isEmpty' assert that fires when a
    // controller-bound TextField outlives or is rebuilt against the
    // wrong parent.
    //
    // useRootNavigator: true anchors the dialog to the ROOT Navigator
    // instead of any nested one (channel chat sits inside a nested
    // Navigator on some routes). The root is the stable, top-level
    // parent context — pushing routes against it sidesteps any in-
    // flight Inherited deactivation in the nested tree.
    final newText = await showDialog<String>(
      context:          context,
      useRootNavigator: true,
      builder:          (_) => _EditMessageDialog(
        initialText: msg.messageText,
      ),
    );
    if (newText == null || newText.isEmpty) return;
    if (newText == msg.messageText) return;
    // Re-check mounted AFTER the showDialog await so a setState below can't
    // touch a disposed Element if the user navigated away mid-edit.
    if (!mounted) return;

    // Bind to a local non-nullable so flow analysis carries the promotion
    // across the setState closure and the network call.
    final updatedText = newText;

    // Optimistic local update — message text changes instantly in the UI
    // before the network round-trip completes.
    setState(() => _editedTexts[msg.id] = updatedText);

    try {
      await Supabase.instance.client
          .from('channel_messages')
          .update({'message_text': updatedText})
          .eq('id', msg.id);
      // Messenger captured before await — safe to use regardless of mounted.
      messenger.showSnackBar(
        const SnackBar(
          content:  Text('Message updated'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      // Roll back the optimistic update on failure.
      if (mounted) setState(() => _editedTexts.remove(msg.id));
      messenger.showSnackBar(
        SnackBar(
          content:  Text('Could not edit: $e'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  // ── Delete message ──────────────────────────────────────────────────────
  // Both the swipe path (Dismissible.onDismissed) and the long-press
  // path (action-sheet 'delete' case) now run through `_runDelete` so
  // the optimistic purge + DB call + rollback live in one place.
  // The legacy `_deleteMessage` was a duplicate of that logic and has
  // been removed.


  // ── Swipe-to-delete confirmation ─────────────────────────────────────────
  //
  // Option A clean-dismiss flow:
  //   • [_confirmDeleteDialog] just shows the AlertDialog and returns the
  //     user's bool answer. NO state mutation here — that fight with the
  //     Dismissible settle-back tween was the source of the "card stays
  //     frozen on glass" bug.
  //   • The Dismissible's `confirmDismiss` awaits this dialog; on `true`
  //     it lets the swipe complete naturally so Flutter runs the proper
  //     exit tween and disposes of the row Element cleanly.
  //   • [_runDelete] is then called from the Dismissible's onDismissed
  //     callback — at that point the slot is already gone visually, so
  //     the setState that purges `_deletedIds` / `_seedMessages` /
  //     `_bubbleKeys` can't race the animation.
  Future<bool> _confirmDeleteDialog() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Delete message?',
            style: TextStyle(fontWeight: FontWeight.w800)),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red.shade700,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return confirm == true;
  }

  /// Post-dismiss state purge + server DELETE. Called from the
  /// Dismissible's `onDismissed` (after the exit tween completes) AND
  /// from the long-press action sheet (where there's no animation to
  /// race against). Idempotent — re-entering `_deletedIds` is a no-op.
  Future<void> _runDelete(ChannelMessage msg) async {
    final messenger = ScaffoldMessenger.of(context);
    final seedSnapshot = _seedMessages[msg.id];
    if (mounted) {
      setState(() {
        _deletedIds.add(msg.id);
        _seedMessages.remove(msg.id);
        _bubbleKeys.remove(msg.id);
      });
    }
    try {
      await CommunityHubService.instance.deleteChannelMessage(msg);
      messenger.showSnackBar(
        const SnackBar(
          content:  Text('Message deleted'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      // Roll back the optimistic purge so the row reappears.
      if (mounted) {
        setState(() {
          _deletedIds.remove(msg.id);
          if (seedSnapshot != null) {
            _seedMessages[msg.id] = seedSnapshot;
          }
        });
      }
      messenger.showSnackBar(
        SnackBar(
          content:  Text('Could not delete: $e'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  // ── PR 2: Reaction overlay lifecycle ────────────────────────────────────

  /// Opens the floating reaction strip + unified action menu for [msg].
  /// Reads the bubble's screen rect off its cached GlobalKey at call time
  /// — re-resolving on each open keeps the rect correct even if the list
  /// scrolled between the previous open and now.
  void _openReactionMenu(ChannelMessage msg, bool isPinned) {
    final key = _bubbleKeys[msg.id];
    final ctx = key?.currentContext;
    if (ctx == null) return;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return;
    final origin = box.localToGlobal(Offset.zero);
    final rect   = origin & box.size;
    setState(() {
      _reactionTarget = _ReactionTarget(
        message:  msg,
        isPinned: isPinned,
        rect:     rect,
      );
    });
    _reactionPortal.show();
  }

  void _closeReactionMenu() {
    if (_reactionPortal.isShowing) _reactionPortal.hide();
    if (_reactionTarget != null) {
      setState(() => _reactionTarget = null);
    }
  }

  Future<void> _applyReaction(ChannelMessage msg, String emoji) async {
    _closeReactionMenu();
    // Fire-and-forget — the bubble's own .stream() subscription on
    // channel_message_reactions will reconcile the count when the row
    // INSERT/DELETE round-trip lands.
    await SocialService().toggleChannelMessageReaction(msg.id, emoji);
  }

  void _dispatchReactionMenuAction(String action) {
    final target = _reactionTarget;
    if (target == null) return;
    final msg      = target.message;
    final isPinned = target.isPinned;
    _closeReactionMenu();
    // Defer to the next frame so the overlay's hide() completes before any
    // dialog/route is pushed — otherwise the dialog's barrier flashes
    // alongside the still-painting overlay barrier.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      switch (action) {
        case 'copy':
          await _copyMessageText(msg);
        case 'edit':
          await _editMessage(msg);
        case 'delete':
          await _runDelete(msg);
        case 'pin':
          await _togglePin(msg, isPinned);
        case 'report':
          await _reportMessage(msg);
        case 'block':
          await _blockMessageAuthor(msg);
      }
    });
  }

  Future<void> _reportMessage(ChannelMessage msg) async {
    try {
      await ModerationService.instance.reportChannelMessage(msg.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Message reported — our team will review it.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not report: $e')),
      );
    }
  }

  Future<void> _blockMessageAuthor(ChannelMessage msg) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Block user?'),
        content: const Text(
          "You won't see this user's messages or posts anywhere in ChowSA. "
          'You can undo this from Settings → Privacy → Blocked users.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Block'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final uid = msg.userId;
    if (uid == null) return;
    try {
      await ModerationService.instance.blockUser(uid);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('User blocked.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not block: $e')),
      );
    }
  }

  Future<void> _copyMessageText(ChannelMessage msg) async {
    final text = msg.messageText.replaceAll(_kAnyRecipeMarker, '').trim();
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content:  Text('Copied to clipboard'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // ── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: cs.surface,
      // Explicit so the body resizes when the soft keyboard opens —
      // the Column's last child (_Composer) then sits flush above the
      // keyboard, and Expanded(ListView) shrinks to keep the latest
      // bubbles visible. (Default is true, but stamping it here makes
      // the contract self-documenting next to the composer wiring.)
      resizeToAvoidBottomInset: true,
      // ── PR 2: reaction overlay portal ─────────────────────────────────
      // OverlayPortal at the body root so the floating reaction strip +
      // unified action menu can reach the full screen (including over
      // the AppBar) when shown. The chat content lives in the [child],
      // unchanged; the overlay reads [_reactionTarget] which is set by
      // [_openReactionMenu] off the bubble's cached GlobalKey rect.
      body: OverlayPortal(
        controller: _reactionPortal,
        overlayChildBuilder: (overlayCtx) {
          final target = _reactionTarget;
          if (target == null) return const SizedBox.shrink();
          final me   = Supabase.instance.client.auth.currentUser?.id;
          final mine = me != null && target.message.userId == me;
          return ChatReactionOverlay(
            bubbleRect:  target.rect,
            onReact:     (e) => _applyReaction(target.message, e),
            onAction:    _dispatchReactionMenuAction,
            onDismiss:   _closeReactionMenu,
            canEdit:     mine,
            canDelete:   mine,
            canPin:      widget.isAdmin,
            // Report / Block surface only on OTHER users' messages — Play
            // UGC policy requires both, and showing them on your own
            // messages would be confusing.
            canModerate: !mine,
            isPinned:    target.isPinned,
          );
        },
        child: StreamBuilder<CommunityChannel?>(
          stream: _channelStream,
        builder: (context, chanSnap) {
          // Sticky resolved channel: cache every non-null emission so a
          // transient null (reconnect / RLS blip) doesn't flip the header
          // back to "#channel" with no subtitle. Mutating a field here is
          // safe — we don't call setState, just update the cache for the
          // next paint to read.
          if (chanSnap.data != null) _lastResolvedChannel = chanSnap.data;
          final channel = chanSnap.data ?? _lastResolvedChannel;
          return Column(
            children: [
              // ── App bar ──────────────────────────────────────────────
              // Title is DERIVED from (suburb, category) so the canonical
              // #{Suburb}-{Section} pattern is always rendered, regardless
              // of what the channel row's `name` column happens to store.
              // Updates automatically the moment the StreamBuilder receives
              // a row whose suburb/category differs — switching areas in
              // the hub navigates to a different channel id, which feeds
              // a fresh stream here.
              _ChannelAppBar(
                // Display suburb is the user's active location override
                // when present, falling back to the channel row's own
                // suburb. Stops the GLOBAL fallback channel from leaking
                // a "#GLOBAL-…" header at users sitting in Table View.
                title: channel == null
                    ? '#channel'
                    : _formatChannelHashtag(
                        widget.displaySuburbOverride ?? channel.suburb,
                        channel.category),
                subtitle: channel == null
                    ? ''
                    : '${widget.displaySuburbOverride ?? channel.suburb} · '
                      '${channel.category.displayName}',
                category: channel?.category,
                searchActive:     _searchActive,
                searchController: _searchController,
                searchFocus:      _searchFocus,
                onSearchToggle:   _toggleSearch,
                onSearchChanged:  (v) =>
                    setState(() => _searchQuery = v),
              ),

              // ── Pinned banner (sticky below AppBar) ──────────────────
              // Hoist the pinned id into a local so the closure captures the
              // non-null String directly and the analyzer is happy.
              if (channel?.pinnedMessageId case final String pinnedId)
                _PinnedBanner(
                  channelId:       widget.channelId,
                  pinnedMessageId: pinnedId,
                  seedLookup:      _seedMessages,
                  isAdmin:         widget.isAdmin,
                  messagesStream:  _messagesStream,
                  onTap:           () => _jumpToPinnedMessage(pinnedId),
                  onUnpin:         () => CommunityHubService.instance
                      .setPinnedMessage(
                          channelId: widget.channelId, messageId: null),
                ),

              // ── Message list (realtime) ──────────────────────────────
              Expanded(
                child: StreamBuilder<List<ChannelMessage>>(
                  stream: _messagesStream,
                  builder: (context, snap) {
                    if (!_seeded && !snap.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    // Merge: realtime stream wins, fall back to seed handles.
                    //
                    // Once the live stream has emitted (`snap.hasData == true`)
                    // it is the authoritative source for message *existence*.
                    // Seed entries are only consulted to enrich a live row
                    // with the joined `authorHandle` / `authorAvatarUrl` —
                    // never as a fallback source for the row itself. That
                    // way, when another user (e.g. SumaraiJack) deletes a
                    // message, the realtime snapshot drops it, and so do we
                    // — instead of resurrecting it from the now-stale
                    // initial fetch in `_seedMessages`.
                    //
                    // Before the first live emission we still surface
                    // `_seedMessages` so the chat doesn't blink to empty
                    // between fetch and the first realtime tick.
                    final liveById = {
                      for (final m in (snap.data ?? const <ChannelMessage>[]))
                        m.id: m,
                    };
                    final liveAuthoritative = snap.hasData;
                    final merged = <ChannelMessage>[
                      if (!liveAuthoritative)
                        ..._seedMessages.values.where(
                            (m) => !liveById.containsKey(m.id)),
                      ...liveById.values.map((m) {
                        // If we have the joined seed (with handle), merge it.
                        final seed = _seedMessages[m.id];
                        if (seed != null && seed.authorHandle != null) {
                          return ChannelMessage(
                            id:             m.id,
                            channelId:      m.channelId,
                            userId:         m.userId,
                            messageText:    m.messageText,
                            eventTimestamp: m.eventTimestamp,
                            createdAt:      m.createdAt,
                            authorHandle:   seed.authorHandle,
                            authorAvatarUrl: m.authorAvatarUrl ?? seed.authorAvatarUrl,
                            imageUrl:       m.imageUrl,
                            // Carry location/spot-pin fields across the merge
                            // so the Spotted chip survives a navigate-away &
                            // re-enter cycle (those fields aren't in the seed
                            // join but are on the realtime row).
                            latitude:       m.latitude,
                            longitude:      m.longitude,
                            locationName:   m.locationName,
                            isSpotPin:      m.isSpotPin,
                          );
                        }
                        return m;
                      }),
                    ]..sort((a, b) => a.createdAt.compareTo(b.createdAt));

                    // Apply local optimistic filters:
                    //  • _deletedIds — hide deleted messages immediately.
                    //  • _editedTexts — show updated text immediately.
                    //  • _searchQuery — case-insensitive match against
                    //    EITHER the resolved author handle OR the
                    //    message text (the location-name string is also
                    //    matched so a search for "Saturday Market"
                    //    finds a Spotted pin posted under that label).
                    // Schedule a best-effort handle hydration for any
                    // user_ids the cache hasn't seen yet so the search
                    // filter's username branch always has something to
                    // match against, even for users whose bubbles haven't
                    // rendered yet (scroll buffer, search hides them).
                    final uids = <String?>{for (final m in merged) m.userId};
                    if (uids.any((u) =>
                        u != null && !_userHandleCache.containsKey(u))) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) unawaited(_hydrateMissingHandles(uids));
                      });
                    }

                    final q = _searchQuery.trim().toLowerCase();
                    final filtering = q.isNotEmpty;
                    bool matches(ChannelMessage m) {
                      if (!filtering) return true;
                      final text = m.messageText.toLowerCase();
                      if (text.contains(q)) return true;
                      final locName = (m.locationName ?? '').toLowerCase();
                      if (locName.contains(q)) return true;
                      final handle = (m.authorHandle
                              ?? _userHandleCache[m.userId])
                          ?.toLowerCase();
                      if (handle != null && handle.contains(q)) return true;
                      return false;
                    }
                    final visible = merged
                        .where((m) => !_deletedIds.contains(m.id))
                        .map((m) {
                          final edited = _editedTexts[m.id];
                          if (edited == null) return m;
                          return ChannelMessage(
                            id:             m.id,
                            channelId:      m.channelId,
                            userId:         m.userId,
                            messageText:    edited,
                            eventTimestamp: m.eventTimestamp,
                            createdAt:      m.createdAt,
                            authorHandle:   m.authorHandle,
                            authorAvatarUrl: m.authorAvatarUrl,
                            imageUrl:       m.imageUrl,
                            latitude:       m.latitude,
                            longitude:      m.longitude,
                            locationName:   m.locationName,
                            isSpotPin:      m.isSpotPin,
                          );
                        })
                        .where(matches)
                        .toList(growable: false);

                    if (visible.isEmpty) {
                      return filtering
                          ? _NoSearchMatches(query: _searchQuery.trim())
                          : const _EmptyState();
                    }

                    // Scroll to bottom using the safe helper (avoids the
                    // '_dependents.isEmpty' crash from calling
                    // addPostFrameCallback inside a StreamBuilder builder).
                    _scrollToBottom();

                    final currentUserId =
                        Supabase.instance.client.auth.currentUser?.id;

                    return ListView.separated(
                      controller: _scrollController,
                      // PR 2: freeze scroll while the reaction overlay is
                      // open so the bubble rect captured at long-press
                      // can't drift out from under the floating strip.
                      // The overlay's barrier already absorbs taps, but
                      // this swap blocks momentum scroll too.
                      physics: _reactionTarget != null
                          ? const NeverScrollableScrollPhysics()
                          : null,
                      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                      itemCount: visible.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (_, i) {
                        final m        = visible[i];
                        final isPinned = m.id == channel?.pinnedMessageId;
                        final isOwn    = currentUserId != null &&
                                         m.userId == currentUserId;
                        final isHighlighted = _highlightedMessageId == m.id;

                        // Attach a stable GlobalKey per message so the pinned-
                        // banner tap can call Scrollable.ensureVisible against
                        // the bubble's BuildContext (variable-height list, so
                        // we can't compute pixel offsets from index alone).
                        final bubbleKey =
                            _bubbleKeys.putIfAbsent(m.id, () => GlobalKey());

                        // Wrap in Dismissible for swipe-to-delete (own messages
                        // only). Swipe left → shows a red delete background.
                        // On confirm dismissed we call _confirmDelete.
                        Widget bubble = ChatMessageBubble(
                          key:            bubbleKey,
                          message:        m,
                          isPinned:       isPinned,
                          isHighlighted:  isHighlighted,
                          isAdmin:        widget.isAdmin,
                          isOwn:          isOwn,
                          // PR 2: long-press routes through the WhatsApp-
                          // parity overlay (reaction strip + unified menu).
                          onLongPress:    () => _openReactionMenu(m, isPinned),
                        );

                        // PR 5: constrain bubble to ~75% screen width and
                        // align right for own messages, left for others.
                        // The GlobalKey is still on ChatMessageBubble so the
                        // overlay's rect capture reads the now-constrained
                        // bubble rect, not the full row.
                        final maxBubbleW =
                            MediaQuery.of(context).size.width * 0.78;
                        bubble = Align(
                          alignment: isOwn
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(maxWidth: maxBubbleW),
                            child: bubble,
                          ),
                        );

                        if (isOwn) {
                          bubble = Dismissible(
                            // Single id-keyed widget per row. The bubble's
                            // GlobalKey is inside `bubble` already, so the
                            // outer KeyedSubtree we used to have on top
                            // was redundant and held the Element in the
                            // slot through the dismiss animation.
                            key:       ValueKey('msg_${m.id}'),
                            direction: DismissDirection.endToStart,
                            // Show the confirm dialog. Returning `true`
                            // lets Flutter run the full slide-out tween
                            // and dispose of the row Element cleanly.
                            // The actual state purge + server DELETE run
                            // in `onDismissed` AFTER the tween finishes
                            // — no more race with the settle-back tween.
                            confirmDismiss: (_) => _confirmDeleteDialog(),
                            onDismissed:    (_) => _runDelete(m),
                            background: Container(
                              alignment: Alignment.centerRight,
                              padding:   const EdgeInsets.only(right: 20),
                              decoration: BoxDecoration(
                                color:        Colors.red.shade700,
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: const Icon(
                                Icons.delete_rounded,
                                color: Colors.white,
                                size:  26,
                              ),
                            ),
                            child: bubble,
                          );
                          return bubble;
                        }

                        // Non-own rows — no Dismissible. Stable id key on
                        // the bubble itself is enough for reconciliation.
                        return KeyedSubtree(
                          key:   ValueKey('row_${m.id}'),
                          child: bubble,
                        );
                      },
                    );
                  },
                ),
              ),

              // ── Composer ─────────────────────────────────────────────
              // Location pin is whitelisted to the location-anchored
              // categories (Spotted, Gatherings, The Pantry). What's
              // Cooking + Braai Recipes are conversational rooms where a
              // GPS pin isn't meaningful, so we hide the button there
              // entirely instead of letting the user attach coordinates
              // that the UI won't use.
              _Composer(
                controller:       _composerController,
                eventTimestamp:   _draftEventTimestamp,
                onClearEventTime: () =>
                    setState(() => _draftEventTimestamp = null),
                onAttachTime:     _pickEventTimestamp,
                onAttachImage:    _pickImage,
                onClearImage:     () => setState(() => _draftImage = null),
                draftImage:       _draftImage,
                uploading:        _uploadingImage,
                onSend:           _sendMessage,
                showLocationButton: channel?.category == ChannelCategory.spotted
                                  || channel?.category == ChannelCategory.gatherings
                                  || channel?.category == ChannelCategory.pantry,
                hasLocation:      (_draftLatitude != null &&
                                   _draftLongitude != null) ||
                                  (_draftLocationName?.trim().isNotEmpty
                                      ?? false),
                fetchingLocation: _fetchingLocation,
                onAttachLocation: _pickLocation,
                onAttachTypedLocation: _pickTypedLocation,
                onClearLocation:  () => setState(() {
                                    _draftLatitude     = null;
                                    _draftLongitude    = null;
                                    _draftLocationName = null;
                                  }),
              ),
            ],
          );
        },
        ),
      ),
    );
  }
}

// =============================================================================
//   Canonical channel hashtag helper
// =============================================================================
//
// Produces "#{Suburb}-{Section}" from a (suburb, category) pair, matching
// the design template:
//   • Table View   + The Pantry      → #TableView-Pantry
//   • Claremont    + What's Cooking  → #Claremont-WhatsCooking
//   • GLOBAL       + What's Cooking  → #GLOBAL-WhatsCooking
//
// Suburb keeps its casing minus whitespace; the category segment uses a
// terse PascalCase form (drops articles like "The" and apostrophes).
// Living in this file rather than the model so the visual format can
// evolve without touching the data layer.

String _formatChannelHashtag(String suburb, ChannelCategory cat) {
  // Strip any trailing " Hub" (case-insensitive) BEFORE compacting the
  // string, otherwise "Table View (Western Cape) Hub" would render as
  // "#TableView(WesternCape)Hub-Spotted" instead of the cleaner
  // "#TableView(WesternCape)-Spotted".
  final suburbPart = suburb
      .replaceAll(RegExp(r'\s+Hub\s*$', caseSensitive: false), '')
      .replaceAll(RegExp(r'\s+'), '');
  final catPart = switch (cat) {
    ChannelCategory.spotted    => 'Spotted',
    ChannelCategory.gatherings => 'Gatherings',
    ChannelCategory.pantry     => 'Pantry',
    ChannelCategory.cooking    => 'WhatsCooking',
    ChannelCategory.braai      => 'Braai',
  };
  return '#$suburbPart-$catPart';
}

// =============================================================================
//   _ChannelAppBar
// =============================================================================

class _ChannelAppBar extends StatelessWidget {
  const _ChannelAppBar({
    required this.title,
    required this.subtitle,
    required this.category,
    required this.searchActive,
    required this.searchController,
    required this.searchFocus,
    required this.onSearchToggle,
    required this.onSearchChanged,
  });

  final String           title;
  final String           subtitle;
  /// Drives the flavour-line row under the title. Null while the channel
  /// stream is still resolving — we just suppress the row in that case so
  /// the header doesn't flicker copy in and out.
  final ChannelCategory? category;

  /// Search bar state, owned by [_ChannelChatScreenState]. Tapping the
  /// magnifying glass flips [searchActive]; the in-place TextField then
  /// pipes its onChanged through [onSearchChanged] so the parent screen
  /// can filter the stream as the user types.
  final bool                  searchActive;
  final TextEditingController searchController;
  final FocusNode             searchFocus;
  final VoidCallback          onSearchToggle;
  final ValueChanged<String>  onSearchChanged;

  @override
  Widget build(BuildContext context) {
    final top  = MediaQuery.of(context).padding.top;
    final flav = category?.flavourLine;
    return Container(
      width:   double.infinity,
      padding: EdgeInsets.only(top: top + 8, bottom: 14, left: 8, right: 8),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF0F3E2B), Color(0xFF205B4A)],
          begin:  Alignment.topLeft,
          end:    Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.only(
          bottomLeft:  Radius.circular(24),
          bottomRight: Radius.circular(24),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
            onPressed: () => Navigator.maybePop(context),
          ),
          Expanded(
            child: searchActive
                ? _buildSearchField(context)
                : _buildTitleColumn(context, flav),
          ),
          // ── Search toggle ─────────────────────────────────────────────
          IconButton(
            icon: Icon(
              searchActive ? Icons.close_rounded : Icons.search_rounded,
              color: Colors.white,
            ),
            tooltip: searchActive
                ? 'Close search'
                : 'Search this category',
            onPressed: onSearchToggle,
          ),
        ],
      ),
    );
  }

  Widget _buildTitleColumn(BuildContext context, String? flav) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: const TextStyle(
              color:         Colors.white,
              fontSize:      17,
              fontWeight:    FontWeight.w900,
              letterSpacing: -0.2,
            )),
        if (subtitle.isNotEmpty)
          Text(subtitle,
              style: TextStyle(
                color:    Colors.white.withValues(alpha: 0.75),
                fontSize: 11.5,
              )),
        // ── Category flavour line ──────────────────────────────
        // SA-flavoured one-liner that gives each room its own
        // personality. Rendered as a soft pill so it reads as
        // ambient context rather than another title.
        if (category != null && flav != null && flav.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8, right: 4),
            child: Container(
              padding: const EdgeInsets.fromLTRB(10, 6, 12, 6),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.18),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(category!.emoji,
                      style: const TextStyle(fontSize: 14)),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      flav,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.92),
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        height: 1.3,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildSearchField(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.22),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Row(
        children: [
          Icon(
            Icons.search_rounded,
            color: Colors.white.withValues(alpha: 0.85),
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller:      searchController,
              focusNode:       searchFocus,
              onChanged:       onSearchChanged,
              textInputAction: TextInputAction.search,
              style: const TextStyle(
                color:      Colors.white,
                fontSize:   14,
                fontWeight: FontWeight.w600,
              ),
              cursorColor: Colors.white,
              decoration: InputDecoration(
                isDense:    true,
                hintText:   'Search this category — try a name or ingredient',
                hintStyle: TextStyle(
                  color:    Colors.white.withValues(alpha: 0.55),
                  fontSize: 13,
                ),
                border:          InputBorder.none,
                enabledBorder:   InputBorder.none,
                focusedBorder:   InputBorder.none,
                contentPadding:  EdgeInsets.zero,
              ),
            ),
          ),
          if (searchController.text.isNotEmpty)
            GestureDetector(
              onTap: () {
                searchController.clear();
                onSearchChanged('');
              },
              child: Icon(
                Icons.cancel_rounded,
                color: Colors.white.withValues(alpha: 0.75),
                size: 18,
              ),
            ),
        ],
      ),
    );
  }
}

// =============================================================================
//   _PinnedBanner — Soft Cream sticky header with the Mango Gold pin glyph
// =============================================================================

class _PinnedBanner extends StatelessWidget {
  const _PinnedBanner({
    required this.channelId,
    required this.pinnedMessageId,
    required this.seedLookup,
    required this.isAdmin,
    required this.onUnpin,
    required this.onTap,
    required this.messagesStream,
  });

  final String                       channelId;
  final String                       pinnedMessageId;
  final Map<String, ChannelMessage>  seedLookup;
  final bool                         isAdmin;
  final Future<void> Function()      onUnpin;

  /// Fired when the user taps the banner body — the parent state scrolls
  /// the chat list to the pinned message and flashes a highlight on it.
  final VoidCallback                 onTap;

  /// Shared with the parent screen so banner + list both subscribe to a
  /// single realtime channel — re-creating the stream here per build would
  /// duplicate subscriptions and break the optimistic-delete UI.
  final Stream<List<ChannelMessage>> messagesStream;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    // Pull the live row out of the same realtime stream the chat uses, so
    // edits to the pinned message text refresh the banner without polling.
    return StreamBuilder<List<ChannelMessage>>(
      stream: messagesStream,
      builder: (context, snap) {
        ChannelMessage? msg;
        final live = snap.data;
        if (live != null) {
          for (final m in live) {
            if (m.id == pinnedMessageId) { msg = m; break; }
          }
        }
        msg ??= seedLookup[pinnedMessageId];
        if (msg == null) {
          return const SizedBox.shrink();
        }
        // The banner is now a tappable shortcut to the pinned message.
        // Wrapped with Material + InkWell so the ripple is clipped to the
        // rounded border; the admin's unpin IconButton sits OUTSIDE the
        // InkWell so its own tap target doesn't bubble up to the jump.
        final borderRadius = BorderRadius.circular(18);
        return Container(
          margin: const EdgeInsets.fromLTRB(14, 12, 14, 4),
          decoration: BoxDecoration(
            color:        AppTheme.kAlabaster,
            borderRadius: borderRadius,
            border: Border.all(
              color: AppTheme.kProteaGold.withValues(alpha: 0.55),
              width: 1.2,
            ),
          ),
          child: Material(
            color:        Colors.transparent,
            borderRadius: borderRadius,
            child: InkWell(
              onTap:        onTap,
              borderRadius: borderRadius,
              splashColor:  AppTheme.kProteaGold.withValues(alpha: 0.16),
              highlightColor: AppTheme.kProteaGold.withValues(alpha: 0.08),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Mango Gold pin chip.
                    Container(
                      width:  36, height: 36,
                      decoration: BoxDecoration(
                        color: AppTheme.kProteaGold,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      alignment: Alignment.center,
                      child: const Text('📌', style: TextStyle(fontSize: 18)),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'PINNED ANNOUNCEMENT',
                            style: TextStyle(
                              color:         cs.onSurfaceVariant,
                              fontSize:      10,
                              letterSpacing: 1.3,
                              fontWeight:    FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            msg.messageText,
                            maxLines:  3,
                            overflow:  TextOverflow.ellipsis,
                            style: const TextStyle(
                              color:      AppTheme.kMidnight,
                              fontSize:   14,
                              fontWeight: FontWeight.w600,
                              height:     1.35,
                            ),
                          ),
                          if (msg.hasEvent) ...[
                            const SizedBox(height: 8),
                            _RemindMeButton(message: msg),
                          ],
                          // Subtle affordance — tells the user the card is
                          // tappable without dominating the layout.
                          const SizedBox(height: 6),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.arrow_downward_rounded,
                                  size: 11, color: cs.onSurfaceVariant),
                              const SizedBox(width: 3),
                              Text(
                                'Tap to view in thread',
                                style: TextStyle(
                                  color:      cs.onSurfaceVariant,
                                  fontSize:   10,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.2,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    if (isAdmin)
                      IconButton(
                        tooltip: 'Unpin',
                        icon:    const Icon(Icons.close_rounded, size: 20),
                        onPressed: () async {
                          await onUnpin();
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Unpinned')),
                          );
                        },
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// =============================================================================
//   _RemindMeButton — Mango Gold 🔔 → ✓ Reminded
// =============================================================================

class _RemindMeButton extends StatefulWidget {
  const _RemindMeButton({required this.message});
  final ChannelMessage message;

  @override
  State<_RemindMeButton> createState() => _RemindMeButtonState();
}

class _RemindMeButtonState extends State<_RemindMeButton> {
  bool _busy     = false;
  bool _reminded = false;

  @override
  void initState() {
    super.initState();
    _reminded = EventReminderService.instance.isReminded(widget.message.id);
  }

  Future<void> _toggle() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (_reminded) {
        await EventReminderService.instance
            .cancelReminder(widget.message.id);
        if (!mounted) return;
        setState(() => _reminded = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Reminder cancelled')),
        );
        return;
      }
      final eventName = _eventNameFromText(widget.message.messageText);
      final outcome = await EventReminderService.instance.scheduleReminder(
        messageId:      widget.message.id,
        eventName:      eventName,
        eventTimestamp: widget.message.eventTimestamp!,
      );
      if (!mounted) return;
      switch (outcome) {
        case ReminderOutcome.scheduled:
          setState(() => _reminded = true);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text(
                "Lekker — we'll buzz you 2 hours before.")),
          );
        case ReminderOutcome.tooLate:
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text(
                'Less than 2 hours away — too late to schedule.')),
          );
        case ReminderOutcome.denied:
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text(
                'Enable notifications in system settings to use reminders.')),
          );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Heuristic: take the first line of the message (or the first 40 chars)
  /// as the event name in the notification payload.
  static String _eventNameFromText(String text) {
    final firstLine = text.split('\n').first.trim();
    if (firstLine.length <= 60) return firstLine;
    return '${firstLine.substring(0, 57)}…';
  }

  @override
  Widget build(BuildContext context) {
    final ts = widget.message.eventTimestamp!;
    final whenLabel = _formatEventWhen(ts);

    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 10,
      runSpacing: 6,
      children: [
        Text(
          whenLabel,
          style: const TextStyle(
            color:      AppTheme.kEarthGrey,
            fontSize:   12,
            fontWeight: FontWeight.w600,
          ),
        ),
        PressableScale(
          onTap: _busy ? null : _toggle,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve:    Curves.easeOut,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: _reminded
                  ? const Color(0xFF1A3A2A)
                  : AppTheme.kProteaGold,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_busy)
                  const SizedBox(
                    width: 14, height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppTheme.kMidnight,
                    ),
                  )
                else
                  Text(
                    _reminded ? '✓' : '🔔',
                    style: const TextStyle(fontSize: 14),
                  ),
                const SizedBox(width: 6),
                Text(
                  _reminded ? 'Reminded' : 'Remind Me',
                  style: TextStyle(
                    color: _reminded
                        ? const Color(0xFF6FCF97)
                        : AppTheme.kMidnight,
                    fontSize:   12.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.1,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  static String _formatEventWhen(DateTime ts) {
    final local = ts.toLocal();
    const months = [
      'Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec',
    ];
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '${local.day} ${months[local.month - 1]} · $hh:$mm';
  }
}

// =============================================================================
//   ChatMessageBubble
// =============================================================================

class ChatMessageBubble extends StatefulWidget {
  const ChatMessageBubble({
    super.key,
    required this.message,
    required this.isPinned,
    required this.isAdmin,
    required this.isOwn,
    required this.onLongPress,
    this.isHighlighted = false,
  });

  final ChannelMessage message;
  final bool           isPinned;
  final bool           isAdmin;
  /// PR 5: true when this bubble belongs to the signed-in user. Drives
  /// alignment (right), tinted fill, and the side of the tail notch.
  final bool           isOwn;
  final VoidCallback   onLongPress;

  /// When true the bubble renders a temporary gold glow + thicker border.
  /// Toggled by the parent State after a pinned-banner tap to draw the
  /// user's eye to the jumped-to message, then cleared after ~1.8 s.
  final bool           isHighlighted;

  @override
  State<ChatMessageBubble> createState() => _ChatMessageBubbleState();
}

class _ChatMessageBubbleState extends State<ChatMessageBubble> {
  String? _resolvedHandle;
  String? _resolvedAvatar;
  bool    _lookupDone = false;

  /// Shared SocialService instance for the reaction toggle path. The
  /// like-row engine (and its _likesSub stream + _toggleLike + the
  /// _isLiked/_likesCount/_likeInFlight quartet) was removed in PR 4 —
  /// reactions fully supplant likes as the social signal on chat rows.
  final SocialService _social = SocialService();

  // ── PR 2: per-bubble reaction state ─────────────────────────────────────
  // One realtime subscription on channel_message_reactions filtered to
  // this message id. Stream INSERT/DELETE events tick the aggregate map
  // (emoji → (count, mine)) live without polling. _toggleReaction
  // optimistically flips the local cell then awaits the service. The
  // stream reconciles the final state so mismatches self-correct within
  // ~one round-trip.
  StreamSubscription<List<Map<String, dynamic>>>? _reactionsSub;
  Map<String, ({int count, bool mine})>           _reactionAgg = const {};

  @override
  void initState() {
    super.initState();
    _resolveHandle();
    _subscribeReactions();
  }

  @override
  void dispose() {
    _reactionsSub?.cancel();
    super.dispose();
  }

  // ── PR 2: reactions stream + toggle ─────────────────────────────────────

  void _subscribeReactions() {
    final me = Supabase.instance.client.auth.currentUser?.id;
    _reactionsSub = Supabase.instance.client
        .from('channel_message_reactions')
        .stream(primaryKey: ['message_id', 'user_id', 'emoji'])
        .eq('message_id', widget.message.id)
        .listen(
          (rows) {
            if (!mounted) return;
            final next = <String, ({int count, bool mine})>{};
            for (final r in rows) {
              final emoji = r['emoji'] as String?;
              if (emoji == null) continue;
              final mine = me != null && r['user_id'] == me;
              final prev = next[emoji];
              next[emoji] = (
                count: (prev?.count ?? 0) + 1,
                mine:  (prev?.mine  ?? false) || mine,
              );
            }
            setState(() => _reactionAgg = next);
          },
          // Realtime drops (WebSocket code 1006) surface as exceptions on
          // this stream. Without an onError handler they propagate as
          // uncaught async errors and Crashlytics records them as FATAL
          // (#90e60632). Swallow — reactions resume on auto-reconnect.
          onError: (_) {},
        );
  }

  /// Optimistic toggle for a tap on an existing reaction pill. The long-
  /// press strip routes through the parent's _applyReaction handler
  /// instead, so the overlay can teardown atomically; this path is for
  /// re-taps on the always-visible in-bubble strip.
  Future<void> _toggleReaction(String emoji) async {
    final cell = _reactionAgg[emoji] ?? (count: 0, mine: false);
    final wasMine = cell.mine;
    setState(() {
      final newCount = cell.count + (wasMine ? -1 : 1);
      final next = Map<String, ({int count, bool mine})>.from(_reactionAgg);
      if (newCount <= 0) {
        next.remove(emoji);
      } else {
        next[emoji] = (count: newCount, mine: !wasMine);
      }
      _reactionAgg = next;
    });
    // Service call; the realtime stream will reconcile if RLS denies.
    await _social.toggleChannelMessageReaction(widget.message.id, emoji);
  }

  Future<void> _resolveHandle() async {
    // Seed already carried profile fields? Use them — and prime the
    // shared avatar cache so other bubbles authored by the same user
    // can short-circuit straight to the resolved value.
    if (widget.message.authorHandle != null) {
      _resolvedHandle = widget.message.authorHandle;
      _resolvedAvatar = widget.message.authorAvatarUrl
          ?? _chatAvatarCache[widget.message.userId ?? ''];
      _lookupDone = true;
      if (widget.message.userId != null &&
          widget.message.authorAvatarUrl != null) {
        _chatAvatarCache[widget.message.userId!] =
            widget.message.authorAvatarUrl;
      }
      return;
    }
    if (widget.message.userId == null) {
      if (mounted) setState(() { _resolvedHandle = null; _lookupDone = true; });
      return;
    }
    final uid = widget.message.userId!;
    final me  = Supabase.instance.client.auth.currentUser;
    if (me?.id == uid) {
      final handle =
          (me?.userMetadata?['handle'] as String?)
          ?? (me?.userMetadata?['username'] as String?)
          ?? me?.email?.split('@').first;
      String? avatar = me?.userMetadata?['avatar_url'] as String?;
      // PR 4 fix: session metadata is stale for users who set their
      // avatar via the profile picker (the picker writes to
      // profiles.avatar_url, not auth.updateUser → userMetadata). When
      // metadata is empty, fall back to the profiles row, going through
      // the cache so siblings don't re-query.
      if (avatar == null || avatar.isEmpty) {
        if (_chatAvatarCache.containsKey(uid)) {
          avatar = _chatAvatarCache[uid];
        } else {
          try {
            final row = await Supabase.instance.client
                .from('profiles')
                .select('avatar_url')
                .eq('id', uid)
                .maybeSingle();
            avatar = (row?['avatar_url'] as String?)?.trim();
            if (avatar != null && avatar.isEmpty) avatar = null;
            _chatAvatarCache[uid] = avatar;
          } catch (_) {/* fall through — initials remain */}
        }
      } else {
        _chatAvatarCache[uid] = avatar;
      }
      if (mounted) {
        setState(() {
          _resolvedHandle = handle;
          _resolvedAvatar = avatar;
          _lookupDone     = true;
        });
      }
      return;
    }
    // Non-self path: check the shared cache before the RPC round-trip
    // so re-renders (scroll out / back in) don't refetch.
    if (_chatAvatarCache.containsKey(uid)) {
      _resolvedAvatar = _chatAvatarCache[uid];
    }
    try {
      // Route through the `get_public_profile` SECURITY DEFINER RPC. A
      // direct `.from('profiles').select().eq('id', other_user_id)` is
      // blocked by the row-level read policy (`auth.uid() = id`) which
      // returned null for every author except the caller themselves.
      final rpcRes = await Supabase.instance.client
          .rpc('get_public_profile', params: {'uid': uid});
      Map<String, dynamic>? row;
      if (rpcRes is List && rpcRes.isNotEmpty) {
        row = Map<String, dynamic>.from(rpcRes.first as Map);
      } else if (rpcRes is Map) {
        row = Map<String, dynamic>.from(rpcRes);
      }
      final handle =
          (row?['handle']   as String?)
          ?? (row?['username'] as String?);
      var avatar = (row?['avatar_url'] as String?)?.trim();
      if (avatar != null && avatar.isEmpty) avatar = null;
      _chatAvatarCache[uid] = avatar;
      if (mounted) {
        setState(() {
          _resolvedHandle = handle;
          _resolvedAvatar = avatar;
          _lookupDone     = true;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _lookupDone = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs      = Theme.of(context).colorScheme;
    final message = widget.message;
    final isPinned = widget.isPinned;

    // Build the display label:
    //   • resolved handle from seed/session/lookup → "@handle"
    //   • lookup in progress                       → "@…"  (brief flicker avoided)
    //   • lookup done, still nothing               → "chow mate" (neutral, not scary)
    final authorLabel = _resolvedHandle != null
        ? '@$_resolvedHandle'
        : (_lookupDone ? 'chow mate' : '@…');

    // Day chip ("Today" / "Yesterday" / weekday or date) — pulled from the
    // post's own created_at so timeline entries are always grouped relative
    // to the *post's* local day, not the viewer's current "minutes ago" delta.
    final dayLabel  = _relativeDay(message.createdAt);
    // Exact wall-clock time the post was created, formatted in the device's
    // local timezone so every viewer sees the same number that was on the
    // poster's clock at write time.
    final timeLabel = _exactClock(message.createdAt);

    final isHighlighted = widget.isHighlighted;
    final isOwn         = widget.isOwn;
    // PR 5: WhatsApp-style asymmetric tail. The notched corner sits on
    // the side closest to the screen edge (own → top-right, others →
    // top-left) and signals message ownership at a glance.
    final bubbleRadius = BorderRadius.only(
      topLeft:     Radius.circular(isOwn ? 18 : 4),
      topRight:    Radius.circular(isOwn ? 4  : 18),
      bottomLeft:  const Radius.circular(18),
      bottomRight: const Radius.circular(18),
    );
    return ValueListenableBuilder<String>(
      valueListenable: ChatBubbleThemeController.instance.selectedId,
      builder: (ctx, themeId, _) {
        final palette = ChatBubbleThemeController.themeForId(themeId);
        final bubbleFill = isOwn ? palette.own : palette.other;
        return _buildBubble(
          context, cs,
          isHighlighted: isHighlighted,
          isPinned:      isPinned,
          bubbleRadius:  bubbleRadius,
          bubbleFill:    bubbleFill,
          message:       message,
          authorLabel:   authorLabel,
          dayLabel:      dayLabel,
          timeLabel:     timeLabel,
        );
      },
    );
  }

  Widget _buildBubble(
    BuildContext context,
    ColorScheme cs, {
    required bool          isHighlighted,
    required bool          isPinned,
    required BorderRadius  bubbleRadius,
    required Color         bubbleFill,
    required ChannelMessage message,
    required String        authorLabel,
    required String        dayLabel,
    required String        timeLabel,
  }) {
    return GestureDetector(
      // Long-press available to all users (own messages: edit/delete) and
      // admins (pin/unpin). The action sheet itself gates each option.
      onLongPress: widget.onLongPress,
      behavior:    HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 280),
        curve:    Curves.easeOutCubic,
        padding:  const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color:        bubbleFill,
          borderRadius: bubbleRadius,
          border: Border.all(
            color: isHighlighted
                ? AppTheme.kProteaGold
                : isPinned
                    ? AppTheme.kProteaGold.withValues(alpha: 0.5)
                    : cs.outlineVariant.withValues(alpha: 0.5),
            width: isHighlighted ? 2.0 : (isPinned ? 1.2 : 1.0),
          ),
          boxShadow: isHighlighted
              ? [
                  BoxShadow(
                    color:        AppTheme.kProteaGold.withValues(alpha: 0.35),
                    blurRadius:   16,
                    spreadRadius: 1,
                  ),
                ]
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header row: avatar · @handle · day · exact time · pin ────
            Row(
              children: [
                _AuthorAvatar(
                  avatarUrl: _resolvedAvatar,
                  handle:    _resolvedHandle,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    authorLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color:      cs.primary,
                      fontSize:   12.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Day chip (Today / Yesterday / Tuesday / 12 May)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 1.5),
                  decoration: BoxDecoration(
                    color:        cs.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    dayLabel,
                    style: TextStyle(
                      color:         cs.onSurfaceVariant,
                      fontSize:      10.5,
                      fontWeight:    FontWeight.w800,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  timeLabel,
                  style: TextStyle(
                    color:      cs.onSurfaceVariant,
                    fontSize:   11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (isPinned) ...[
                  const Spacer(),
                  const Text('📌', style: TextStyle(fontSize: 13)),
                ],
              ],
            ),
            // ── Image attachment ────────────────────────────────────────
            // PR 1: BoundedChatImage caps height at 280, caches the natural
            // aspect per URL so re-mounts don't re-flow, and Hero-tags the
            // bitmap so a tap flies the image into ChatImageLightbox. Tag
            // is keyed on message.id (not the URL) so two messages sharing
            // an image don't collide.
            if (message.hasImage) ...[
              const SizedBox(height: 10),
              BoundedChatImage(
                imageUrl:  message.imageUrl!,
                heroTag:   'msg-image-${message.id}',
                messageId: message.id,
              ),
            ],
            const SizedBox(height: 6),
            // Hide a lone 📷 placeholder when there's an image and no caption.
            // Also strip the hidden `[recipe:<id>]` marker — that's purely a
            // signal for the chip rendered below, not user-visible text.
            if (!(message.hasImage && message.messageText.trim() == '📷'))
              Text(
                message.messageText
                    .replaceAll(_kAnyRecipeMarker, '')
                    .trimRight(),
                style: const TextStyle(
                  color: AppTheme.kMidnight,
                  fontSize:   14.5,
                  fontWeight: FontWeight.w500,
                  height: 1.4,
                ),
              ),
            // ── PR 4: like row removed ───────────────────────────────────
            // Reactions (the 7-emoji strip from PR 2) fully supplant the
            // heart toggle as the social signal on chat bubbles. The
            // _toggleLike / _isLiked / _likesCount state and the
            // channel_message_likes .stream() subscription are gone from
            // the bubble State; the DB table itself is left in place so
            // historical data isn't dropped from production.
            //
            if (message.hasEvent) ...[
              const SizedBox(height: 10),
              _RemindMeButton(message: message),
            ],
            // ── Spotted location chip ──────────────────────────────────
            // Rendered when the row carries valid coords OR when the
            // is_spot_pin flag is explicitly set (the flag is the canonical
            // signal; the coord check is a graceful fallback for any
            // pre-flag rows that happen to have coords).
            if (message.hasLocation || message.isSpotPin) ...[
              const SizedBox(height: 10),
              _SpottedLocationChip(
                latitude:     message.latitude,
                longitude:    message.longitude,
                locationName: message.locationName,
                postedAt:     message.createdAt,
                onLongPress:  widget.onLongPress,
              ),
            ],
            // ── Shared recipe CTA ──────────────────────────────────────
            // Posted via RecipeShareService.shareToWhatsCooking. Newer
            // posts use `[shared_recipe:<uuid>]` → public snapshot table;
            // older posts use `[recipe:<uuid>]` → private recipes row.
            if (_kAnyRecipeMarker.firstMatch(message.messageText) != null) ...[
              const SizedBox(height: 10),
              Builder(builder: (_) {
                final sharedMatch =
                    _kSharedRecipeMarker.firstMatch(message.messageText);
                if (sharedMatch != null) {
                  return _SharedRecipeChip(
                    sharedRecipeId: sharedMatch.group(1)!,
                    onLongPress:    widget.onLongPress,
                  );
                }
                final legacyMatch =
                    _kLegacyRecipeMarker.firstMatch(message.messageText)!;
                return _SharedRecipeChip(
                  legacyPrivateRecipeId: legacyMatch.group(1)!,
                  onLongPress:           widget.onLongPress,
                );
              }),
            ],
            // ── PR 2: reaction aggregate strip ───────────────────────
            // Moved to render LAST in the bubble Column (below text,
            // event chip, spotted chip, and shared-recipe chip) so the
            // pills sit at the bottom edge with breathing room and
            // never crowd the message body. Renders one pill per emoji
            // that has at least one reaction. Pills accent when the
            // current user has contributed; tapping a pill toggles
            // their own reaction in/out.
            if (_reactionAgg.isNotEmpty) ...[
              const SizedBox(height: 8),
              ReactionAggregateStrip(
                aggregate: _reactionAgg,
                onToggle:  _toggleReaction,
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ── Time formatters ─────────────────────────────────────────────────────
  //
  // Day label rules, in the viewer's local timezone:
  //   • Same calendar date as today           → "Today"
  //   • Yesterday                              → "Yesterday"
  //   • Within the last 6 days                 → weekday name ("Tuesday")
  //   • Older                                  → "12 May" (or "12 May 2025"
  //                                              when the year differs)

  static String _relativeDay(DateTime t) {
    final local = t.toLocal();
    final now   = DateTime.now();
    final today     = DateTime(now.year,   now.month,   now.day);
    final thatDay   = DateTime(local.year, local.month, local.day);
    final diffDays  = today.difference(thatDay).inDays;
    if (diffDays == 0) return 'Today';
    if (diffDays == 1) return 'Yesterday';
    if (diffDays > 1 && diffDays < 7) {
      const weekdays = [
        'Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday',
      ];
      return weekdays[local.weekday - 1];
    }
    const months = [
      'Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec',
    ];
    if (local.year == now.year) {
      return '${local.day} ${months[local.month - 1]}';
    }
    return '${local.day} ${months[local.month - 1]} ${local.year}';
  }

  static String _exactClock(DateTime t) {
    final local = t.toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }
}

// =============================================================================
//   _SpottedLocationChip — premium map-link chip rendered inside the bubble
// =============================================================================
//
// Shown when a message carries a Spotted location pin (lat/lng + is_spot_pin
// flag). Acts as a deep-link into the device's native maps app — the user
// taps anywhere on the chip and the OS opens the coordinate in Google Maps
// (Android), Apple Maps (iOS), or a Google Maps web URL (any other host
// platform).
//
// URL scheme selection:
//   • iOS / macOS                 → https://maps.apple.com/?q=<lat>,<lng>
//   • Android                     → geo:<lat>,<lng>?q=<lat>,<lng>
//   • Everything else             → https://www.google.com/maps/search/
//                                   ?api=1&query=<lat>,<lng>
//
// The Android `geo:` scheme requires no permissions and is the canonical
// "open the map app" intent. Apple's universal-link form opens Apple Maps
// on iOS/macOS without needing a separate app scheme.

class _SpottedLocationChip extends StatelessWidget {
  const _SpottedLocationChip({
    required this.latitude,
    required this.longitude,
    required this.locationName,
    required this.postedAt,
    this.onLongPress,
  });

  final double?       latitude;
  final double?       longitude;
  final String?       locationName;
  final DateTime      postedAt;
  /// Forwarded so a long-press on the chip still surfaces the parent bubble's
  /// edit/delete action sheet — without this the InkWell's gesture arena
  /// swallows the long-press and own-message actions become unreachable
  /// whenever a Spotted pin is attached.
  final VoidCallback? onLongPress;

  Uri _buildMapUri(double lat, double lng) {
    if (Platform.isIOS || Platform.isMacOS) {
      return Uri.parse('https://maps.apple.com/?q=$lat,$lng');
    }
    if (Platform.isAndroid) {
      // The label after ?q renders as the pin caption in Google Maps.
      return Uri.parse('geo:$lat,$lng?q=$lat,$lng');
    }
    // Desktop / web / anything else — universal Google Maps URL.
    return Uri.parse(
        'https://www.google.com/maps/search/?api=1&query=$lat,$lng');
  }

  /// Maps URI for a typed-only pin — no coords, just a search string.
  /// Pings the user's default maps app and asks it to search for the
  /// label. Lets a user post "Engen garage Tableview" and have the
  /// recipient land on whichever garage Google Maps thinks they mean.
  Uri _buildMapSearchUri(String query) {
    final encoded = Uri.encodeComponent(query);
    if (Platform.isIOS || Platform.isMacOS) {
      return Uri.parse('https://maps.apple.com/?q=$encoded');
    }
    if (Platform.isAndroid) {
      return Uri.parse('geo:0,0?q=$encoded');
    }
    return Uri.parse(
        'https://www.google.com/maps/search/?api=1&query=$encoded');
  }

  Future<void> _openInMaps(BuildContext context) async {
    final lat  = latitude;
    final lng  = longitude;
    final name = locationName?.trim();
    final hasCoords = lat != null && lng != null && lat != 0.0 && lng != 0.0;
    final hasName   = name != null && name.isNotEmpty;

    if (!hasCoords && !hasName) {
      debugPrint(
        '📍 Hub Map: refusing to open empty pin '
        '(lat=$lat, lng=$lng, name=$name)',
      );
      return;
    }

    final messenger = ScaffoldMessenger.of(context);
    // Prefer coords when available — they're exact. Fall back to a
    // search-by-name when this is a typed-only pin (driver-by-the-beach
    // food-truck scenario).
    final uri = hasCoords
        ? _buildMapUri(lat, lng)
        : _buildMapSearchUri(name!);
    try {
      // externalApplication forces the native maps handler instead of an
      // in-app web view — that's the whole point of this chip.
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) {
        messenger.showSnackBar(
          const SnackBar(
            content:  Text('No maps app available to open this location.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content:  Text('Could not open maps: $e'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  /// Lightweight relative-time label for the subtitle. Distance-from-user is
  /// out of scope for this pass (would need the viewer's GPS at render time,
  /// which means a separate permission flow); the timestamp is the next-best
  /// "why this matters now" signal.
  String _subtitleLabel() {
    if (locationName != null && locationName!.trim().isNotEmpty) {
      return locationName!.trim();
    }
    final ago = DateTime.now().difference(postedAt);
    if (ago.inMinutes < 1)  return 'Spotted just now · tap to open';
    if (ago.inMinutes < 60) return 'Spotted ${ago.inMinutes} min ago · tap to open';
    if (ago.inHours   < 24) return 'Spotted ${ago.inHours}h ago · tap to open';
    return 'Spotted ${ago.inDays}d ago · tap to open';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final borderRadius = BorderRadius.circular(14);

    return Material(
      color:        Colors.transparent,
      borderRadius: borderRadius,
      child: InkWell(
        onTap:        () => _openInMaps(context),
        onLongPress:  onLongPress,
        borderRadius: borderRadius,
        splashColor:  AppTheme.kProteaGold.withValues(alpha: 0.18),
        highlightColor: AppTheme.kProteaGold.withValues(alpha: 0.10),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
          decoration: BoxDecoration(
            color: AppTheme.kProteaGold.withValues(alpha: 0.10),
            borderRadius: borderRadius,
            border: Border.all(
              color: AppTheme.kProteaGold.withValues(alpha: 0.45),
              width: 1,
            ),
          ),
          child: Row(
            children: [
              // ── Map glyph chip ─────────────────────────────────────────
              Container(
                width:  36, height: 36,
                decoration: BoxDecoration(
                  color: AppTheme.kProteaGold,
                  borderRadius: BorderRadius.circular(10),
                ),
                alignment: Alignment.center,
                child: const Icon(
                  Icons.map_rounded,
                  color: AppTheme.kMidnight,
                  size:  20,
                ),
              ),
              const SizedBox(width: 12),
              // ── Label column ───────────────────────────────────────────
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize:       MainAxisSize.min,
                  children: [
                    const Text(
                      'SPOTTED LOCATION',
                      style: TextStyle(
                        color:         AppTheme.kMidnight,
                        fontSize:      10.5,
                        fontWeight:    FontWeight.w900,
                        letterSpacing: 1.4,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _subtitleLabel(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color:      cs.onSurfaceVariant,
                        fontSize:   12,
                        fontWeight: FontWeight.w600,
                        height:     1.25,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.arrow_outward_rounded,
                color: cs.onSurfaceVariant,
                size:  18,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
//   _SharedRecipeChip — tappable "View Recipe" card for a shared recipe post
// =============================================================================
//
// Rendered when a chat message carries a `[recipe:<uuid>]` marker. Tapping
// loads the recipe (RLS-scoped to the viewer's own recipes) and pushes the
// RecipeDetailScreen. Long-press forwards to the bubble's action sheet so
// the chip never swallows edit/delete on the parent message.

class _SharedRecipeChip extends StatelessWidget {
  const _SharedRecipeChip({
    this.sharedRecipeId,
    this.legacyPrivateRecipeId,
    this.onLongPress,
  }) : assert(sharedRecipeId != null || legacyPrivateRecipeId != null);

  /// Points at a public `shared_recipes` snapshot row — readable by everyone.
  final String?       sharedRecipeId;

  /// Legacy marker that points at a row in the sharer's private `recipes`
  /// table. Only the sharer themselves will be able to open it (RLS) — every
  /// other viewer falls back to a "private to sharer" snackbar.
  final String?       legacyPrivateRecipeId;
  final VoidCallback? onLongPress;

  Future<void> _open(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    if (sharedRecipeId != null) {
      final row = await Supabase.instance.client
          .from('shared_recipes')
          .select()
          .eq('id', sharedRecipeId!)
          .maybeSingle();
      if (row == null) {
        messenger.showSnackBar(const SnackBar(
          content:  Text('That shared recipe is no longer available.'),
          behavior: SnackBarBehavior.floating,
        ));
        return;
      }
      final recipe = _recipeFromSharedRow(row);
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => _SharedRecipeViewerScreen(recipe: recipe),
        ),
      );
      return;
    }

    // Legacy path — pre-shared_recipes posts. Only the sharer (RLS owner)
    // can open these.
    final recipe =
        await RecipeRepository.instance.getById(legacyPrivateRecipeId!);
    if (recipe == null) {
      messenger.showSnackBar(const SnackBar(
        content:  Text(
          'This older shared recipe is private to the sharer — ask them to '
          're-share so everyone can open it.',
        ),
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => _SharedRecipeViewerScreen(recipe: recipe),
      ),
    );
  }

  static Recipe _recipeFromSharedRow(Map<String, dynamic> row) {
    final ingRaw = row['ingredients'];
    final ingredients = (ingRaw is List)
        ? ingRaw
            .whereType<Map>()
            .map((m) => Ingredient.fromJson(Map<String, dynamic>.from(m)))
            .toList()
        : <Ingredient>[];
    final stepsRaw = row['instructions'];
    final steps = (stepsRaw is List)
        ? stepsRaw.map((s) => s.toString()).toList()
        : <String>[];
    return Recipe(
      title:                  row['title'] as String,
      ingredients:            ingredients,
      instructions:           steps,
      isLoadsheddingFriendly: (row['is_loadshedding_friendly'] as bool?) ?? false,
      isBraaiReady:           (row['is_braai_ready']           as bool?) ?? false,
      sourceUrl:              row['source_url'] as String?,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final borderRadius = BorderRadius.circular(14);

    return Material(
      color:        Colors.transparent,
      borderRadius: borderRadius,
      child: InkWell(
        onTap:        () => _open(context),
        onLongPress:  onLongPress,
        borderRadius: borderRadius,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
          decoration: BoxDecoration(
            color: AppTheme.kBottleGreen.withValues(alpha: 0.08),
            borderRadius: borderRadius,
            border: Border.all(
              color: AppTheme.kBottleGreen.withValues(alpha: 0.45),
              width: 1,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 36, height: 36,
                decoration: BoxDecoration(
                  color: AppTheme.kBottleGreen,
                  borderRadius: BorderRadius.circular(10),
                ),
                alignment: Alignment.center,
                child: const Icon(
                  Icons.menu_book_rounded,
                  color: Colors.white,
                  size:  20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize:       MainAxisSize.min,
                  children: [
                    const Text(
                      'SHARED RECIPE',
                      style: TextStyle(
                        color:         AppTheme.kMidnight,
                        fontSize:      10.5,
                        fontWeight:    FontWeight.w900,
                        letterSpacing: 1.4,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Tap to open the full recipe',
                      style: TextStyle(
                        color:      cs.onSurfaceVariant,
                        fontSize:   12,
                        fontWeight: FontWeight.w600,
                        height:     1.25,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.arrow_outward_rounded,
                color: cs.onSurfaceVariant,
                size:  18,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
//   _SharedRecipeViewerScreen — read-only viewer + "Save to My Recipes" CTA
// =============================================================================
//
// Opened when a viewer taps a shared-recipe chip in chat. Renders the recipe
// title, ingredients, and method as plain text — no edit affordances. A
// single FilledButton at the bottom inserts the recipe into the viewer's
// own `recipes` table so they can cook it without leaving ChowSA.
//
// Why not reuse RecipeDetailScreen? That screen has edit mode wired up; we
// want a strictly non-editable surface for someone else's shared content.

class _SharedRecipeViewerScreen extends StatefulWidget {
  const _SharedRecipeViewerScreen({required this.recipe});

  final Recipe recipe;

  @override
  State<_SharedRecipeViewerScreen> createState() =>
      _SharedRecipeViewerScreenState();
}

class _SharedRecipeViewerScreenState extends State<_SharedRecipeViewerScreen> {
  bool _saving = false;
  bool _saved  = false;

  Future<void> _save() async {
    if (_saving || _saved) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = true);
    try {
      await RecipeRepository.instance.insert(widget.recipe);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saved  = true;
      });
      messenger.showSnackBar(const SnackBar(
        content:  Text('Saved to My Recipes 🍽️'),
        behavior: SnackBarBehavior.floating,
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      messenger.showSnackBar(SnackBar(
        content:  Text('Could not save: $e'),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs     = Theme.of(context).colorScheme;
    final tt     = Theme.of(context).textTheme;
    final recipe = widget.recipe;

    return Scaffold(
      backgroundColor: AppTheme.kAlabaster,
      appBar: AppBar(
        backgroundColor: AppTheme.kBottleGreen,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text(
          'Shared Recipe',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 120),
        children: [
          Text(
            recipe.title,
            style: tt.headlineSmall?.copyWith(
              fontWeight:    FontWeight.w900,
              color:         AppTheme.kMidnight,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              if (recipe.isBraaiReady)
                _Badge(text: '🔥 Braai-ready'),
              if (recipe.isLoadsheddingFriendly)
                _Badge(text: '⚡ Loadshedding-friendly'),
            ],
          ),
          const SizedBox(height: 24),
          Text(
            'Ingredients',
            style: tt.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
              color:      AppTheme.kBottleGreen,
            ),
          ),
          const SizedBox(height: 8),
          if (recipe.ingredients.isEmpty)
            Text('No ingredients listed.',
                style: TextStyle(color: cs.onSurfaceVariant))
          else
            ...recipe.ingredients.map((ing) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  '• ${formatIngredientLine(ing)}',
                  style: const TextStyle(fontSize: 14.5, height: 1.4),
                ),
              );
            }),
          const SizedBox(height: 20),
          Text(
            'Method',
            style: tt.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
              color:      AppTheme.kBottleGreen,
            ),
          ),
          const SizedBox(height: 8),
          if (recipe.instructions.isEmpty)
            Text('No steps provided.',
                style: TextStyle(color: cs.onSurfaceVariant))
          else
            ...recipe.instructions.asMap().entries.map((e) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(
                    '${e.key + 1}. ${e.value}',
                    style: const TextStyle(fontSize: 14.5, height: 1.45),
                  ),
                )),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: FilledButton.icon(
            onPressed: _saved || _saving ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width:  16, height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color:       Colors.white,
                    ),
                  )
                : Icon(_saved
                    ? Icons.check_rounded
                    : Icons.bookmark_add_rounded),
            label: Text(
              _saved ? 'Saved to My Recipes' : 'Save to My Recipes',
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                fontSize:   15,
              ),
            ),
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.kProteaGold,
              foregroundColor: AppTheme.kMidnight,
              padding:         const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppTheme.kProteaGold.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: AppTheme.kProteaGold.withValues(alpha: 0.55),
        ),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize:   11.5,
          fontWeight: FontWeight.w800,
          color:      AppTheme.kMidnight,
        ),
      ),
    );
  }
}

// =============================================================================
//   _AuthorAvatar — circular avatar that falls back to a handle initial
// =============================================================================

class _AuthorAvatar extends StatelessWidget {
  const _AuthorAvatar({required this.avatarUrl, required this.handle});

  final String? avatarUrl;
  final String? handle;

  @override
  Widget build(BuildContext context) {
    // avatar_url stores either a local asset path
    // ('assets/avatars/Melrose.png') OR an http(s) URL. The previous code
    // assumed network-only and silently rendered a blank circle for the
    // asset-path case — same root cause as the Kitchen Circle bug.
    ImageProvider? avatarImage;
    if (avatarUrl != null && avatarUrl!.isNotEmpty) {
      if (avatarUrl!.startsWith('assets/')) {
        avatarImage = AssetImage(avatarUrl!);
      } else if (avatarUrl!.startsWith('http://') ||
                 avatarUrl!.startsWith('https://')) {
        avatarImage = NetworkImage(avatarUrl!);
      }
    }
    if (avatarImage != null) {
      return CircleAvatar(
        radius:          11,
        backgroundColor: AppTheme.kProteaGold.withValues(alpha: 0.3),
        backgroundImage: avatarImage,
      );
    }
    final initial = (handle != null && handle!.isNotEmpty)
        ? handle![0].toUpperCase()
        : '?';
    return CircleAvatar(
      radius:          11,
      backgroundColor: AppTheme.kProteaGold,
      child: Text(
        initial,
        style: const TextStyle(
          color:      AppTheme.kMidnight,
          fontSize:   11,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}
// (End ChatMessageBubbleState)

// =============================================================================
//   _Composer
// =============================================================================

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.eventTimestamp,
    required this.onClearEventTime,
    required this.onAttachTime,
    required this.onAttachImage,
    required this.onClearImage,
    required this.draftImage,
    required this.uploading,
    required this.onSend,
    required this.showLocationButton,
    required this.hasLocation,
    required this.fetchingLocation,
    required this.onAttachLocation,
    required this.onAttachTypedLocation,
    required this.onClearLocation,
  });

  final TextEditingController controller;
  final DateTime?             eventTimestamp;
  final VoidCallback          onClearEventTime;
  final VoidCallback          onAttachTime;
  final VoidCallback          onAttachImage;
  final VoidCallback          onClearImage;
  final XFile?                draftImage;
  final bool                  uploading;
  final VoidCallback          onSend;

  /// True for category rooms where dropping a GPS pin is meaningful
  /// (Spotted, Gatherings, The Pantry). What's Cooking + Braai Recipes
  /// pass false — the IconButton AND the staged-pin chip are hidden
  /// entirely in those rooms.
  final bool                  showLocationButton;

  /// True when the parent state has a Spotted location pin staged for the
  /// next outgoing message. Drives the floating chip + the IconButton's
  /// active/inactive colour.
  final bool                  hasLocation;
  /// True while the geolocator fetch is in flight — disables the button
  /// and swaps its icon for a tiny spinner so the user knows the tap
  /// registered.
  final bool                  fetchingLocation;
  final VoidCallback          onAttachLocation;
  /// Fires when the user picks "Type the location" from the attach
  /// sheet — parent state opens a small text dialog and stashes the
  /// typed label in [_draftLocationName] for the next outgoing
  /// message.
  final VoidCallback          onAttachTypedLocation;
  final VoidCallback          onClearLocation;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        decoration: BoxDecoration(
          color: cs.surface,
          border: Border(
            top: BorderSide(
              color: cs.outlineVariant.withValues(alpha: 0.6),
              width: 0.6,
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (eventTimestamp != null) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 6, left: 4),
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 6,
                  children: [
                    const Text('🗓️', style: TextStyle(fontSize: 14)),
                    Text(
                      _RemindMeButtonState._formatEventWhen(eventTimestamp!),
                      style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w700),
                    ),
                    InkWell(
                      onTap: onClearEventTime,
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 4),
                        child: Icon(Icons.close_rounded, size: 14),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            // ── Location-pin chip ──────────────────────────────────────────
            // Floats just above the input row when a coordinate has been
            // staged. The X clears the draft pin client-side without
            // touching the message itself, in case the user changes their
            // mind before tapping Send.
            if (showLocationButton && hasLocation) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 6, left: 4),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(10, 5, 6, 5),
                  decoration: BoxDecoration(
                    color:        AppTheme.kProteaGold.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: AppTheme.kProteaGold.withValues(alpha: 0.55),
                      width: 1,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('📍', style: TextStyle(fontSize: 13)),
                      const SizedBox(width: 6),
                      const Text(
                        'Location attached',
                        style: TextStyle(
                          fontSize:   12,
                          fontWeight: FontWeight.w700,
                          color:      AppTheme.kMidnight,
                        ),
                      ),
                      const SizedBox(width: 2),
                      InkWell(
                        onTap:        onClearLocation,
                        borderRadius: BorderRadius.circular(20),
                        child: const Padding(
                          padding: EdgeInsets.all(4),
                          child: Icon(Icons.close_rounded, size: 14,
                              color: AppTheme.kMidnight),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            // ── Picked-image preview chip ─────────────────────────────────
            // Shown above the input row so the user can confirm what they
            // selected and remove it before sending.
            if (draftImage != null) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 8, left: 2),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.file(
                        File(draftImage!.path),
                        width:  56,
                        height: 56,
                        fit:    BoxFit.cover,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        uploading
                            ? 'Uploading photo…'
                            : 'Photo ready — tap send to post.',
                        style: TextStyle(
                          fontSize:   12,
                          fontWeight: FontWeight.w600,
                          color:      cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                    if (!uploading)
                      InkWell(
                        onTap: onClearImage,
                        borderRadius: BorderRadius.circular(20),
                        child: const Padding(
                          padding: EdgeInsets.all(6),
                          child: Icon(Icons.close_rounded, size: 16),
                        ),
                      ),
                  ],
                ),
              ),
            ],
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // ── Fun "+" attach widget ──────────────────────────────
                // All per-category attach actions (calendar / photo /
                // location) collapse into a single playful gold circle.
                // Tapping it opens a small action sheet so the composer
                // row stays flat and pill-shaped — no more icon clutter
                // squeezing the text field, which is what caused the
                // pixel overflow on smaller phones.
                Padding(
                  padding: const EdgeInsets.only(bottom: 2, right: 6),
                  child: _ComposerAttachButton(
                    anyAttached: eventTimestamp != null ||
                        draftImage != null ||
                        (showLocationButton && hasLocation),
                    busy: uploading || fetchingLocation,
                    onTap: () => _showAttachSheet(
                      context,
                      onAttachTime:     onAttachTime,
                      onAttachImage:    uploading ? null : onAttachImage,
                      onAttachLocation: (uploading || fetchingLocation)
                          ? null
                          : onAttachLocation,
                      onAttachTypedLocation:
                          uploading ? null : onAttachTypedLocation,
                      showLocation:    showLocationButton,
                      hasEvent:        eventTimestamp != null,
                      hasImage:        draftImage != null,
                      hasLocation:     hasLocation,
                    ),
                  ),
                ),
                Expanded(
                  // WhatsApp-style pill composer: filled background, fully
                  // rounded, no underline. Suggestions render ABOVE the
                  // field so the dropdown floats up into the message list
                  // instead of getting squashed by the keyboard.
                  child: Container(
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: cs.outlineVariant.withValues(alpha: 0.5),
                        width: 0.8,
                      ),
                    ),
                    child: MentionSuggestionField(
                      controller: controller,
                      minLines: 1,
                      maxLines: 3,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => onSend(),
                      suggestionsAbove: true,
                      decoration: const InputDecoration(
                        hintText: 'Message · use @ to tag someone',
                        isDense: true,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                PressableScale(
                  onTap: uploading ? null : onSend,
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: const BoxDecoration(
                      color: AppTheme.kProteaGold,
                      shape: BoxShape.circle,
                    ),
                    child: uploading
                        ? const SizedBox(
                            width: 20, height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.4,
                              color: AppTheme.kMidnight,
                            ),
                          )
                        : const Icon(
                            Icons.send_rounded,
                            color: AppTheme.kMidnight,
                            size:  20,
                          ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
//   _ComposerAttachButton — fun "+" widget that opens the attach sheet
// =============================================================================
//
// Single playful gold circle that replaces the row of inline IconButtons
// (calendar / photo / location). When something is already attached it
// swaps to a check-mark + bottle-green so the user can see at a glance
// that the next send will carry an attachment. While a background fetch
// or upload is running it shows a tiny spinner.
class _ComposerAttachButton extends StatelessWidget {
  const _ComposerAttachButton({
    required this.anyAttached,
    required this.busy,
    required this.onTap,
  });

  final bool         anyAttached;
  final bool         busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bg = anyAttached
        ? AppTheme.kBottleGreen
        : AppTheme.kProteaGold;
    final fg = anyAttached
        ? AppTheme.kProteaGold
        : AppTheme.kMidnight;
    return PressableScale(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: bg,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color:     bg.withValues(alpha: 0.35),
              blurRadius: 8,
              offset:    const Offset(0, 2),
            ),
          ],
        ),
        alignment: Alignment.center,
        child: busy
            ? SizedBox(
                width: 18, height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  color: fg,
                ),
              )
            : Icon(
                anyAttached
                    ? Icons.check_rounded
                    : Icons.add_rounded,
                color: fg,
                size:  24,
              ),
      ),
    );
  }
}

/// Pops a small playful action sheet listing every attach option the
/// channel supports. Hidden options (e.g. location in chat-only rooms)
/// don't appear. Each tile closes the sheet, then triggers the parent
/// callback so the existing picker flows run unchanged.
Future<void> _showAttachSheet(
  BuildContext context, {
  required VoidCallback  onAttachTime,
  required VoidCallback? onAttachImage,
  required VoidCallback? onAttachLocation,
  required VoidCallback? onAttachTypedLocation,
  required bool          showLocation,
  required bool          hasEvent,
  required bool          hasImage,
  required bool          hasLocation,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (ctx) {
      final cs = Theme.of(ctx).colorScheme;
      return SafeArea(
        top: false,
        child: Container(
          margin:  const EdgeInsets.fromLTRB(12, 0, 12, 12),
          padding: const EdgeInsets.fromLTRB(8, 10, 8, 8),
          decoration: BoxDecoration(
            color:        cs.surface,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: cs.outlineVariant.withValues(alpha: 0.6),
              width: 0.6,
            ),
            boxShadow: [
              BoxShadow(
                color:     Colors.black.withValues(alpha: 0.12),
                blurRadius: 18,
                offset:    const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width:  40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color:        cs.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              _AttachTile(
                emoji:    '🗓️',
                label:    hasEvent
                    ? 'Update event time'
                    : 'Attach event time',
                tint:     AppTheme.kProteaGold,
                onTap: () {
                  Navigator.of(ctx).pop();
                  onAttachTime();
                },
              ),
              _AttachTile(
                emoji:    '📷',
                label:    hasImage ? 'Replace photo' : 'Attach photo',
                tint:     AppTheme.kBottleGreen,
                enabled:  onAttachImage != null,
                onTap: onAttachImage == null
                    ? null
                    : () {
                        Navigator.of(ctx).pop();
                        onAttachImage();
                      },
              ),
              if (showLocation) ...[
                _AttachTile(
                  emoji:    '📍',
                  label:    hasLocation
                      ? 'Use my current location (refresh)'
                      : 'Use my current location',
                  tint:     const Color(0xFFC1432A),
                  enabled:  onAttachLocation != null,
                  onTap: onAttachLocation == null
                      ? null
                      : () {
                          Navigator.of(ctx).pop();
                          onAttachLocation();
                        },
                ),
                _AttachTile(
                  emoji:    '🔎',
                  label:    'Type the location',
                  tint:     AppTheme.kBottleGreen,
                  enabled:  onAttachTypedLocation != null,
                  onTap: onAttachTypedLocation == null
                      ? null
                      : () {
                          Navigator.of(ctx).pop();
                          onAttachTypedLocation();
                        },
                ),
              ],
            ],
          ),
        ),
      );
    },
  );
}

// =============================================================================
//   _TypedLocationDialog — text input for the "type the location" flow
// =============================================================================
//
// Owns its own TextEditingController so the framework cleans the
// controller up when this State unmounts. Disposing the controller
// from the parent (after `await showDialog`) raced the dialog exit
// animation and crashed with the "_dependents.isEmpty" framework
// assertion.
class _TypedLocationDialog extends StatefulWidget {
  const _TypedLocationDialog({required this.initial});

  final String initial;

  @override
  State<_TypedLocationDialog> createState() => _TypedLocationDialogState();
}

class _TypedLocationDialogState extends State<_TypedLocationDialog> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
      title: const Text(
        'Type the location',
        style: TextStyle(fontWeight: FontWeight.w800),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "Drop a pin even if you're not standing there — when a "
            "chommie taps it, Google Maps will search for this place.",
            style: TextStyle(fontSize: 13, height: 1.4),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _ctrl,
            autofocus:  true,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              hintText: 'e.g. Engen garage, Tableview',
              border:   OutlineInputBorder(),
              isDense:  true,
            ),
            onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child:     const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(context).pop(_ctrl.text.trim()),
          child: const Text('Attach'),
        ),
      ],
    );
  }
}

class _AttachTile extends StatelessWidget {
  const _AttachTile({
    required this.emoji,
    required this.label,
    required this.tint,
    required this.onTap,
    this.enabled = true,
  });

  final String        emoji;
  final String        label;
  final Color         tint;
  final VoidCallback? onTap;
  final bool          enabled;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: InkWell(
        onTap:        enabled ? onTap : null,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 40, height: 40,
                decoration: BoxDecoration(
                  color:        tint.withValues(alpha: 0.18),
                  shape:        BoxShape.circle,
                  border: Border.all(
                    color: tint.withValues(alpha: 0.55),
                    width: 1,
                  ),
                ),
                alignment: Alignment.center,
                child: Text(emoji, style: const TextStyle(fontSize: 18)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize:   14.5,
                    fontWeight: FontWeight.w700,
                    color:      cs.onSurface,
                  ),
                ),
              ),
              Icon(Icons.chevron_right_rounded,
                  color: cs.onSurfaceVariant, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
//   _EmptyState
// =============================================================================

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('🌱', style: TextStyle(fontSize: 48)),
            const SizedBox(height: 12),
            Text(
              'Be the first to say howzit.',
              style: Theme.of(context).textTheme.titleSmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/// Replaces [_EmptyState] when the user typed a search query that matches
/// nothing in the current category's stream. Distinct copy so users
/// know it's a filter result, not an empty channel.
class _NoSearchMatches extends StatelessWidget {
  const _NoSearchMatches({required this.query});
  final String query;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('🔍', style: TextStyle(fontSize: 44)),
            const SizedBox(height: 12),
            Text(
              'No posts match "$query"',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              'Try a different name, ingredient, or keyword — or close '
              'search to see the full feed.',
              style: TextStyle(
                color:    cs.onSurfaceVariant,
                fontSize: 12.5,
                height:   1.4,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
//   _EditMessageDialog — stable, self-contained edit dialog
// =============================================================================
//
// Why a dedicated StatefulWidget rather than an inline AlertDialog:
//   • The TextEditingController is instantiated in initState() and disposed
//     in dispose() — bound to THIS widget's Element lifecycle, not the
//     parent's. Eliminates the controller-outlives-Element class of
//     '_dependents.isEmpty' crashes.
//   • initialText is passed by VALUE, not by reading from a Provider or
//     InheritedWidget. The dialog never re-subscribes to ancestor state
//     while open, so dependency drops during dispose can't fight in-flight
//     rebuilds.
//   • The dialog Pops with the trimmed new text (or null on cancel). The
//     parent does ALL the async work — this widget never touches the
//     network or rebuilds the surrounding chat list.

class _EditMessageDialog extends StatefulWidget {
  const _EditMessageDialog({required this.initialText});

  final String initialText;

  @override
  State<_EditMessageDialog> createState() => _EditMessageDialogState();
}

class _EditMessageDialogState extends State<_EditMessageDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: const Text('Edit message',
          style: TextStyle(fontWeight: FontWeight.w800)),
      content: TextField(
        controller: _controller,
        maxLines:   4,
        minLines:   1,
        autofocus:  true,
        decoration: const InputDecoration(hintText: 'Message text'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
