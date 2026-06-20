// lib/services/smart_suggestions_service.dart
//
// Backend layer for the Smart Suggestions Engine.
//
//   • topIngredientsFromShoppingHistory  — aggregates the user's most
//                                          frequently bought items from
//                                          shopping_list_items.
//   • isFeatureEnabledForCurrentUser     — reads `profiles.feature_flags
//                                          ->>'smart_suggestions'`.
//   • currentPartnerId                   — reads `profiles.partner_id`.
//   • linkPartnerByHandle                — sets partner_id by looking up
//                                          a profile by handle/username.
//   • addToWeeklyPlanner                 — owner-side insert.
//   • watchOwnerPlanner                  — partner-side realtime stream.

import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/weekly_planner_entry.dart';

class SmartSuggestionsService {
  SmartSuggestionsService._();
  static final instance = SmartSuggestionsService._();

  SupabaseClient get _sb => Supabase.instance.client;
  String? get _uid       => _sb.auth.currentUser?.id;

  // ── Feature gate — Melrose only, pinned by UUID ───────────────────────────
  //
  // Smart Suggestions is a creator-exclusive feature for Melrose (the dev's
  // wife). Identity is locked to her EXACT `auth.users.id` so the gate can
  // never be exposed to anyone else — not by a handle change, not by a
  // similar-looking username like "melrose21" or "Mel89", not by manually
  // editing `profiles.feature_flags`. The UUID is immutable for the
  // lifetime of her Supabase auth row.
  //
  // If she ever signs in on a new account (rare — would need a full
  // password reset) update the constant below and ship a new build.

  /// Melrose's permanent Supabase auth uid — the only user allowed to see
  /// the Smart Suggestions card.
  static const String _kMelroseUid =
      '33d5fb08-c92e-4048-b043-294dc422b5b7';

  Future<bool> isFeatureEnabledForCurrentUser() async {
    // Sync, zero-network gate. The previous `feature_flags` lookup added
    // 150–400 ms of round-trip per home-screen build for everyone (not
    // just Melrose), and any user with shell access to their own profile
    // row could flip the flag on. The UUID match closes both holes.
    final uid = _uid;
    return uid != null && uid == _kMelroseUid;
  }

  // ── Top ingredients aggregation ───────────────────────────────────────────

  /// Returns the [limit] most frequently purchased ingredient names by the
  /// current user, derived from their `shopping_list_items` joined to
  /// `shopping_lists` on user_id.
  ///
  /// We use a PostgREST embedded resource (`shopping_lists!inner(user_id)`)
  /// so RLS on shopping_lists already filters to the caller's own lists —
  /// no extra .eq('user_id', uid) needed, and no public RPC required.
  Future<List<String>> topIngredientsFromShoppingHistory({int limit = 10}) async {
    final uid = _uid;
    if (uid == null) return const [];
    try {
      // Pull a generous window of recent items; aggregate client-side.
      // shopping_list_items has no user_id of its own — we ride on
      // shopping_lists' RLS via the inner join filter.
      final rows = await _sb
          .from('shopping_list_items')
          .select('name, shopping_lists!inner(user_id)')
          .eq('shopping_lists.user_id', uid)
          .order('created_at', ascending: false)
          .limit(500);
      final counts = <String, int>{};
      for (final r in (rows as List).cast<Map<String, dynamic>>()) {
        final raw = (r['name'] as String?)?.trim().toLowerCase();
        if (raw == null || raw.isEmpty) continue;
        counts[raw] = (counts[raw] ?? 0) + 1;
      }
      final sorted = counts.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      return sorted.take(limit).map((e) => _titleCase(e.key)).toList();
    } catch (_) {
      return const [];
    }
  }

  String _titleCase(String s) =>
      s.split(' ').map((w) =>
          w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}').join(' ');

  // ── Partner linking ───────────────────────────────────────────────────────

  /// Looks up [handle] (case-insensitive, with or without leading '@') and
  /// sets the current user's `partner_id` to the matched profile's id.
  /// Throws on no-match or self-link attempt. Returns the matched profile
  /// row so callers can confirm "you linked @SumaraiJack".
  Future<Map<String, dynamic>> linkPartnerByHandle(String handle) async {
    final uid = _uid;
    if (uid == null) {
      throw StateError('Must be signed in to link a partner.');
    }
    final clean = handle.trim().replaceFirst(RegExp(r'^@'), '');
    if (clean.isEmpty) {
      throw ArgumentError('Enter a partner handle.');
    }
    // Route via the `find_user_by_handle` SECURITY DEFINER RPC so the
    // row-level read policy on `profiles` doesn't hide every other user's
    // row from us. Same fix as Kitchen Circle / share-list flows.
    final rpcRes = await _sb
        .rpc('find_user_by_handle', params: {'q': clean});
    Map<String, dynamic>? match;
    if (rpcRes is List && rpcRes.isNotEmpty) {
      match = Map<String, dynamic>.from(rpcRes.first as Map);
    } else if (rpcRes is Map) {
      match = Map<String, dynamic>.from(rpcRes);
    }
    if (match == null || match['id'] == null) {
      throw StateError('No user found with the handle "@$clean".');
    }
    final partnerUid = match['id'] as String;
    if (partnerUid == uid) {
      throw StateError('You cannot link yourself as your own partner.');
    }
    await _sb
        .from('profiles')
        .update({'partner_id': partnerUid})
        .eq('id', uid);
    return match;
  }

  /// Clears the current user's partner link.
  Future<void> unlinkPartner() async {
    final uid = _uid;
    if (uid == null) return;
    await _sb.from('profiles').update({'partner_id': null}).eq('id', uid);
  }

  /// Returns the current user's linked partner id (or null).
  Future<String?> currentPartnerId() async {
    final uid = _uid;
    if (uid == null) return null;
    try {
      final row = await _sb
          .from('profiles')
          .select('partner_id')
          .eq('id', uid)
          .maybeSingle();
      return row?['partner_id'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// Returns the profile id whose `partner_id` points at the current user,
  /// i.e. "the person who linked ME as their partner". Used by SumaraiJack
  /// to discover Melrose's user id for the planner stream.
  Future<String?> ownerWhoLinkedMe() async {
    final uid = _uid;
    if (uid == null) return null;
    try {
      final row = await _sb
          .from('profiles')
          .select('id')
          .eq('partner_id', uid)
          .limit(1)
          .maybeSingle();
      return row?['id'] as String?;
    } catch (_) {
      return null;
    }
  }

  // ── Weekly planner writes ─────────────────────────────────────────────────

  /// Inserts an approved meal idea into `weekly_planner` for the current
  /// user. Owner-side write; partner side never calls this (RLS would
  /// reject it anyway).
  Future<WeeklyPlannerEntry> addToWeeklyPlanner({
    required MealSlot       mealSlot,
    required String         title,
    String?                 summary,
    List<String>            ingredients       = const [],
    List<String>            instructions      = const [],
    List<String>            sourceIngredients = const [],
    DateTime?               suggestedFor,
  }) async {
    final uid = _uid;
    if (uid == null) {
      throw StateError('Must be signed in to save a meal.');
    }
    final inserted = await _sb
        .from('weekly_planner')
        .insert({
          'user_id':           uid,
          'meal_slot':         mealSlot.wire,
          'title':             title.trim(),
          if (summary != null && summary.trim().isNotEmpty)
            'summary':         summary.trim(),
          'ingredients':       ingredients,
          'instructions':      instructions,
          'source_ingredients': sourceIngredients,
          if (suggestedFor != null)
            'suggested_for':   suggestedFor
                .toIso8601String()
                .split('T')
                .first,
        })
        .select()
        .single();
    return WeeklyPlannerEntry.fromRow(inserted);
  }

  // ── Planner reads / streams ───────────────────────────────────────────────

  /// Realtime stream of [ownerUserId]'s planner entries. Partner side uses
  /// `ownerWhoLinkedMe()` to discover the owner uid, then subscribes here.
  /// Owner side can also subscribe to their own id for a self-feed.
  ///
  /// RLS guarantees the caller only sees rows they're allowed to:
  ///   • Owner — their own rows.
  ///   • Partner — owner's rows, read-only.
  Stream<List<WeeklyPlannerEntry>> watchOwnerPlanner(String ownerUserId) {
    return _sb
        .from('weekly_planner')
        .stream(primaryKey: ['id'])
        .eq('user_id', ownerUserId)
        .order('created_at')
        .map((rows) => rows
            .map(WeeklyPlannerEntry.fromRow)
            .toList(growable: false));
  }
}
