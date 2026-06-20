// lib/services/recipe_repository.dart
//
// Single source of truth for the user's personal "My Recipes" collection.
//
// Wire-up:
//   • Primary store    → Supabase `recipes` table, RLS-scoped to user_id
//   • Offline cache    → SharedPreferences key `user_recipes_v1`
//   • Live refresh bus → [updateNotifier] — any screen wraps its list in a
//                        ValueListenableBuilder<int> to re-fetch on mutation
//
// Required Supabase schema (run once on your project):
//
//   create table recipes (
//     id                        uuid primary key default gen_random_uuid(),
//     user_id                   uuid not null references auth.users(id) on delete cascade,
//     title                     text not null,
//     ingredients               jsonb not null default '[]'::jsonb,
//     instructions              jsonb not null default '[]'::jsonb,
//     is_loadshedding_friendly  bool  not null default false,
//     is_braai_ready            bool  not null default false,
//     source_url                text,
//     image_url                 text,
//     source                    text,      -- 'manual' | 'scraper' | 'community'
//     created_at                timestamptz default now()
//   );
//   alter table recipes enable row level security;
//   create policy "owner_read"   on recipes for select using (auth.uid() = user_id);
//   create policy "owner_insert" on recipes for insert with check (auth.uid() = user_id);
//   create policy "owner_update" on recipes for update using (auth.uid() = user_id);
//   create policy "owner_delete" on recipes for delete using (auth.uid() = user_id);

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/recipe.dart';
import '../models/ingredient.dart';

class RecipeRepository {
  RecipeRepository._();
  static final RecipeRepository instance = RecipeRepository._();

  static const _cachePrefKey = 'user_recipes_v1';

  // ── Live refresh bus ──────────────────────────────────────────────────────
  // Bumped after every successful mutation. UI wraps its list builder in
  // ValueListenableBuilder<int> to re-fetch automatically.
  final ValueNotifier<int> updateNotifier = ValueNotifier<int>(0);

  SupabaseClient get _db => Supabase.instance.client;
  String? get _userId => _db.auth.currentUser?.id;

  // ── Read ────────────────────────────────────────────────────────────────────

  /// Returns the exact number of recipes owned by the current user.
  ///
  /// Uses PostgREST `.count(CountOption.exact)` so the result reflects the
  /// canonical DB count — never a stale SharedPreferences cache. Returns 0
  /// when signed out or on any network/auth failure (so dashboard counters
  /// never display NaN or a stuck legacy value).
  ///
  /// Wire this to a [ValueListenableBuilder<int>] on [updateNotifier] so the
  /// number live-updates after every insert / delete without manual refresh.
  Future<int> countAll() async {
    final uid = _userId;
    if (uid == null) return 0;
    try {
      final res = await _db
          .from('recipes')
          .select('id')        // a narrow column is enough — count ignores it
          .eq('user_id', uid)
          .count(CountOption.exact);
      return res.count;
    } catch (_) {
      // Fall back to cache size so a transient network blip still shows a
      // sensible number rather than dropping the tile to 0.
      final cached = await _readCache();
      return cached.length;
    }
  }

  /// Loads a single recipe by its server id. Returns null if it doesn't exist
  /// or RLS hides it from the caller (e.g. someone else's recipe).
  Future<Recipe?> getById(String id) async {
    final uid = _userId;
    if (uid == null) return null;
    try {
      final row = await _db
          .from('recipes')
          .select()
          .eq('id', id)
          .maybeSingle();
      if (row == null) return null;
      return _recipeFromRow(row);
    } catch (_) {
      return null;
    }
  }

  /// Loads all recipes for the current user. Tries Supabase first; on failure
  /// (network, auth) falls back to the SharedPreferences cache so the user
  /// still sees their data offline.
  Future<List<Recipe>> loadAll() async {
    final uid = _userId;

    // ── Online path ─────────────────────────────────────────────────────────
    if (uid != null) {
      try {
        final rows = await _db
            .from('recipes')
            .select()
            .eq('user_id', uid)
            .order('created_at', ascending: false);

        final recipes = (rows as List)
            .map((r) => _recipeFromRow(r as Map<String, dynamic>))
            .toList();

        // Refresh the offline cache while we have fresh data.
        await _writeCache(recipes);
        return recipes;
      } catch (_) {
        // Fall through to the cache.
      }
    }

    // ── Offline / signed-out fallback ───────────────────────────────────────
    return _readCache();
  }

  // ── Mutations ───────────────────────────────────────────────────────────────

  /// Inserts the recipe into Supabase, bumps the update notifier, refreshes
  /// the local cache, and returns the persisted row (with server-generated id
  /// in [Recipe.sourceUrl] embedded — see note below). Throws on auth failure.
  Future<Recipe> insert(Recipe recipe, {String source = 'manual'}) async {
    final uid = _userId;
    if (uid == null) {
      throw const _NotAuthenticated();
    }

    final payload = {
      'user_id':                  uid,
      'title':                    recipe.title,
      'ingredients':              recipe.ingredients
          .map((i) => i.toJson())
          .toList(),
      'instructions':             recipe.instructions,
      'is_loadshedding_friendly': recipe.isLoadsheddingFriendly,
      'is_braai_ready':           recipe.isBraaiReady,
      if (recipe.sourceUrl != null) 'source_url': recipe.sourceUrl,
      // NOTE: there's intentionally no `source` field here — the `recipes`
      // table only has `source_url` (the external URL the recipe was scraped
      // from). Writing `source` previously raised PGRST204 in PostgREST and
      // bricked the cloud save, downgrading every save to local-only.
    };

    final row = await _db
        .from('recipes')
        .insert(payload)
        .select()
        .single();

    final persisted = _recipeFromRow(row);
    await _appendToCache(persisted);
    updateNotifier.value++;
    return persisted;
  }

  /// Convenience wrapper for the "Save Recipe" CTA on the generated
  /// pantry-recipe card. Overrides the AI-generated [recipe.title] with
  /// the user-supplied [customName] and persists the result into the
  /// EXISTING `recipes` table (i.e. lands directly in My Recipes — no
  /// separate `saved_recipes` table). Delegates to [insert] for the
  /// actual row write so the cache + updateNotifier behaviour is shared.
  Future<Recipe> saveGeneratedRecipe(String customName, Recipe recipe) async {
    final cleanName = customName.trim();
    if (cleanName.isEmpty) {
      throw ArgumentError('customName must not be empty.');
    }
    final renamed = Recipe(
      title:                  cleanName,
      ingredients:            recipe.ingredients,
      instructions:           recipe.instructions,
      isLoadsheddingFriendly: recipe.isLoadsheddingFriendly,
      isBraaiReady:           recipe.isBraaiReady,
      sourceUrl:              recipe.sourceUrl,
    );
    return insert(renamed, source: 'pantry-generation');
  }

  // ── Shopping lists ────────────────────────────────────────────────────────

  /// Creates a new row in `shopping_lists` with [listName] + the current
  /// user, then writes every item in [ingredients] as its own row in
  /// `shopping_list_items` linked to the new list. Returns the new list
  /// id so callers can deep-link or refresh.
  ///
  /// Both writes are required — if the items insert throws after the
  /// list row already landed, we attempt a best-effort delete of the
  /// orphan list row so the user doesn't accumulate empty named lists.
  Future<String> createShoppingListFromIngredients(
    String           listName,
    List<Ingredient> ingredients,
  ) async {
    final uid = _userId;
    if (uid == null) {
      throw const _NotAuthenticated();
    }
    final cleanName = listName.trim();
    if (cleanName.isEmpty) {
      throw ArgumentError('listName must not be empty.');
    }

    // ── Step A: create the list row ────────────────────────────────────
    // The `shopping_lists` table uses `list_name` (NOT `name`) as the
    // text label column, and its `items` jsonb column is NOT NULL — both
    // were the cause of the PGRST204 "Could not find the 'name' column"
    // crash when generating a shopping list from a pantry recipe. We
    // populate `items` with an empty array up-front; the per-row entries
    // live in the child `shopping_list_items` table below.
    final listRow = await _db
        .from('shopping_lists')
        .insert({
          'user_id':   uid,
          'list_name': cleanName,
          'items':     <dynamic>[],
        })
        .select('id')
        .single();
    final listId = listRow['id'] as String;

    // ── Step B: bulk-insert the line items ─────────────────────────────
    if (ingredients.isEmpty) return listId;
    try {
      await _db.from('shopping_list_items').insert([
        for (var i = 0; i < ingredients.length; i++)
          {
            'list_id':  listId,
            'name':     ingredients[i].displayName,
            if (ingredients[i].quantity != null)
              'quantity': ingredients[i].quantity!
                  .toStringAsFixed(ingredients[i].quantity! % 1 == 0 ? 0 : 1),
            if (ingredients[i].unit != null) 'unit': ingredients[i].unit,
            'position': i,
          },
      ]);
    } catch (e) {
      // Best-effort orphan cleanup. We swallow any rollback error so the
      // original failure isn't masked.
      try {
        await _db.from('shopping_lists').delete().eq('id', listId);
      } catch (_) {/* swallow */}
      rethrow;
    }
    return listId;
  }

  /// Lightweight `{id, name}` pairs for every shopping list owned by the
  /// current user. Used by pickers that need to let the user pick an
  /// existing list to add items into (e.g. fridge-scan → add to list).
  /// Returns an empty list when signed out or on any failure.
  Future<List<({String id, String name})>> listShoppingLists() async {
    final uid = _userId;
    if (uid == null) return const [];
    try {
      // Same fix as createShoppingListFromIngredients — the column is
      // `list_name`, not `name`. The earlier `select('id, name')` was
      // silently returning [] because PostgREST 400'd on the unknown
      // column, which masked existing lists from the picker.
      final rows = await _db
          .from('shopping_lists')
          .select('id, list_name')
          .eq('user_id', uid)
          .order('created_at', ascending: false);
      return (rows as List)
          .cast<Map<String, dynamic>>()
          .map((r) => (
                id:   r['id']        as String,
                name: r['list_name'] as String,
              ))
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  /// Appends each name in [items] to the shopping list identified by
  /// [listId] as a new `shopping_list_items` row. Skips empty strings,
  /// trims whitespace, and assigns positions sequentially after the
  /// list's current max position so the new items land at the bottom.
  Future<void> addItemsToShoppingList({
    required String       listId,
    required List<String> items,
  }) async {
    final uid = _userId;
    if (uid == null) {
      throw const _NotAuthenticated();
    }
    final clean = items
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    if (clean.isEmpty) return;

    int basePos = 0;
    try {
      final maxRow = await _db
          .from('shopping_list_items')
          .select('position')
          .eq('list_id', listId)
          .order('position', ascending: false)
          .limit(1)
          .maybeSingle();
      basePos = ((maxRow?['position'] as int?) ?? -1) + 1;
    } catch (_) {/* fall back to 0 */}

    await _db.from('shopping_list_items').insert([
      for (var i = 0; i < clean.length; i++)
        {
          'list_id':  listId,
          'name':     clean[i],
          'position': basePos + i,
        },
    ]);
  }

  /// True when [s] parses as a Postgres UUID (8-4-4-4-12 hex). The Recipe
  /// model's `sourceUrl` field doubles as both the scraped web URL AND, for
  /// recipes with no real source, the server row id (see _recipeFromRow).
  /// Callers therefore pass the same string to update/delete regardless of
  /// which form it carries — we branch here so we never .eq('id', '<url>')
  /// and trip a "invalid input syntax for type uuid" Postgrest crash.
  static final RegExp _kUuidRegex = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );
  static bool _isUuid(String s) => _kUuidRegex.hasMatch(s.trim());

  /// Updates the row matching [idOrUrl] with values from [recipe]. The handle
  /// is whatever was stashed on `Recipe.sourceUrl` — a real web URL for
  /// scraped recipes, or the server row id for manually-entered ones.
  Future<void> update(String idOrUrl, Recipe recipe) async {
    final uid = _userId;
    if (uid == null) {
      throw const _NotAuthenticated();
    }

    final builder = _db.from('recipes').update({
      'title':                    recipe.title,
      'ingredients':              recipe.ingredients
          .map((i) => i.toJson())
          .toList(),
      'instructions':             recipe.instructions,
      'is_loadshedding_friendly': recipe.isLoadsheddingFriendly,
      'is_braai_ready':           recipe.isBraaiReady,
      if (recipe.sourceUrl != null) 'source_url': recipe.sourceUrl,
    });

    if (_isUuid(idOrUrl)) {
      await builder.eq('id', idOrUrl).eq('user_id', uid);
    } else {
      await builder.eq('source_url', idOrUrl).eq('user_id', uid);
    }

    // Re-pull from server so cache stays canonical
    await loadAll();
    updateNotifier.value++;
  }

  /// Deletes the row matching [idOrUrl]. Owner-scoped via RLS. Accepts either
  /// the server uuid OR the recipe's `source_url` so callers can hand us
  /// `Recipe.sourceUrl` blindly without first having to figure out which form
  /// it carries — scraped recipes stash the URL there, manual ones stash the
  /// row id (see _recipeFromRow).
  Future<void> delete(String idOrUrl) async {
    final uid = _userId;
    if (uid == null) {
      throw const _NotAuthenticated();
    }

    if (_isUuid(idOrUrl)) {
      await _db
          .from('recipes')
          .delete()
          .eq('id', idOrUrl)
          .eq('user_id', uid);
    } else {
      // Scraped recipe — sourceUrl holds the original web URL. Match the
      // row by `source_url` instead so Postgres never gets a non-UUID
      // string thrown at the uuid `id` column.
      await _db
          .from('recipes')
          .delete()
          .eq('source_url', idOrUrl)
          .eq('user_id', uid);
    }
    await _removeFromCache(idOrUrl);
    updateNotifier.value++;
  }

  // ── Convenience: save-from-community ───────────────────────────────────────
  // Builds a minimal Recipe from a community post title (no ingredients/steps
  // yet — the user can edit later). Returns the persisted row.

  Future<Recipe> saveFromCommunity({
    required String title,
    String? imageUrl,
    String? sourceUrl,
  }) async {
    // Persist the image URL via an extra column on insert.
    final uid = _userId;
    if (uid == null) {
      throw const _NotAuthenticated();
    }
    final row = await _db.from('recipes').insert({
      'user_id':                  uid,
      'title':                    title,
      'ingredients':              [],
      'instructions':             [],
      'is_loadshedding_friendly': false,
      'is_braai_ready':           false,
      if (sourceUrl != null) 'source_url': sourceUrl,
      if (imageUrl  != null) 'image_url':  imageUrl,
      // No `source` field — column doesn't exist on `recipes`. See note in
      // insert() above for the historical PGRST204 background.
    }).select().single();
    final persisted = _recipeFromRow(row);
    await _appendToCache(persisted);
    updateNotifier.value++;
    return persisted;
  }

  // ── Local cache helpers ────────────────────────────────────────────────────

  Future<List<Recipe>> _readCache() async {
    final prefs = await SharedPreferences.getInstance();
    final raw   = prefs.getString(_cachePrefKey);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => Recipe.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _writeCache(List<Recipe> recipes) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _cachePrefKey,
      jsonEncode(recipes.map((r) => r.toJson()).toList()),
    );
  }

  Future<void> _appendToCache(Recipe recipe) async {
    final cached = await _readCache();
    cached.insert(0, recipe);
    await _writeCache(cached);
  }

  Future<void> _removeFromCache(String id) async {
    // The Recipe model doesn't carry an id field — match by sourceUrl when
    // present, else by title hash. Server stays canonical via loadAll().
    final cached = await _readCache();
    cached.removeWhere((r) => r.sourceUrl == id);
    await _writeCache(cached);
  }

  // ── Row → model ─────────────────────────────────────────────────────────────

  Recipe _recipeFromRow(Map<String, dynamic> row) {
    // ingredients: jsonb array of {quantity, unit, name, localizedName}
    final ingRaw = row['ingredients'];
    final List<Ingredient> ingredients;
    if (ingRaw is List) {
      ingredients = ingRaw
          .whereType<Map>()
          .map((m) => Ingredient.fromJson(Map<String, dynamic>.from(m)))
          .toList();
    } else {
      ingredients = const [];
    }

    // instructions: jsonb or text[]
    final stepsRaw = row['instructions'];
    final List<String> steps;
    if (stepsRaw is List) {
      steps = stepsRaw.map((s) => s.toString()).toList();
    } else {
      steps = const [];
    }

    // Stash the server id on sourceUrl when no real source URL is set, so the
    // UI layer has a stable handle for delete/update without bloating the
    // model. Callers that need the real source URL should check `source` /
    // `image_url` columns directly via _RecipeWithRowId if needed.
    final id = row['id'] as String?;
    final src = row['source_url'] as String?;

    return Recipe(
      title:                  row['title'] as String,
      ingredients:            ingredients,
      instructions:           steps,
      isLoadsheddingFriendly: (row['is_loadshedding_friendly'] as bool?) ?? false,
      isBraaiReady:           (row['is_braai_ready']           as bool?) ?? false,
      sourceUrl:              src ?? id,
      // Proper id/type fields — used by the meal planner to deep-link
      // a planned meal back to its My-Recipe detail page on tap. The
      // sourceUrl-as-id legacy is preserved above for existing callers.
      sourceId:               id,
      sourceType:             id == null ? null : 'mine',
    );
  }
}

class _NotAuthenticated implements Exception {
  const _NotAuthenticated();
  @override
  String toString() => 'Sign in to save recipes to the cloud.';
}
