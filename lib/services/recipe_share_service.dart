// lib/services/recipe_share_service.dart
//
// Handles both share routes for a personal recipe:
//
//   Route A — channel_messages INSERT (What's Cooking hub chat)
//     Resolves the cooking channel for the user's active suburb and posts
//     a message into the same channel_messages stream the chat screen
//     subscribes to. Lands in every hub subscriber's live thread instantly
//     via Supabase realtime.
//
//   Route B — native system share sheet (share_plus)
//     Formats a plain-text summary and hands it to the OS so the user can
//     send to WhatsApp, email, SMS, or any installed app.
//
// All Supabase calls are wrapped in try/catch — callers receive a [ShareResult]
// enum so they can surface the right snackbar without catching themselves.

import 'package:flutter/foundation.dart';
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/recipe.dart';
import '../utils/measurement_format.dart';
import 'community_hub_service.dart';

// ── Result enum ───────────────────────────────────────────────────────────────

enum ShareResult {
  /// Post written to channel_messages successfully.
  communitySuccess,

  /// The user is not signed in — cannot write to channel_messages.
  notSignedIn,

  /// No "What's Cooking" channel exists for the user's active suburb.
  channelNotFound,

  /// Supabase insert failed (network, RLS, etc.).
  communityError,

  /// System share sheet was invoked. We don't have a "did they share?" signal
  /// from share_plus, so this is always the result of a system share attempt.
  systemShareInvoked,
}

// ── Service ───────────────────────────────────────────────────────────────────

class RecipeShareService {
  RecipeShareService._();
  static final instance = RecipeShareService._();

  SupabaseClient get _db => Supabase.instance.client;

  // ── Route A: community feed post ─────────────────────────────────────────

  /// Inserts a new row into `community_posts` shaped like a recipe share.
  ///
  /// The caption follows the spec copy:
  ///   "Check out this recipe I just cooked: <title>! 🍽️"
  ///
  /// [imageUrl] is optional — when present it's stamped on `image_url` so
  /// the feed card renders the recipe photo. When absent the card falls back
  /// to the gradient placeholder, exactly as with any other text-only post.
  Future<ShareResult> shareToWhatsCooking({
    required Recipe recipe,
    String?         imageUrl,
  }) async {
    final user = _db.auth.currentUser;
    if (user == null) return ShareResult.notSignedIn;

    // Caption: spec-exact copy + brief ingredient hint. Clamped to the
    // channel_messages.message_text CHECK (length BETWEEN 1 AND 2000).
    var caption = _buildCaption(recipe);

    // Publish a public snapshot into shared_recipes so ANY chat viewer can
    // read the recipe (the personal `recipes` table is RLS-locked to its
    // owner). The chat message carries a [shared_recipe:<id>] marker that
    // points at the snapshot — the bubble fetches it on tap.
    String? sharedId;
    try {
      final realSource = (recipe.sourceUrl != null &&
              recipe.sourceUrl!.startsWith('http'))
          ? recipe.sourceUrl
          : null;
      final inserted = await _db.from('shared_recipes').insert({
        'shared_by':                user.id,
        'title':                    recipe.title,
        'ingredients':              recipe.ingredients
            .map((i) => i.toJson())
            .toList(),
        'instructions':             recipe.instructions,
        'is_loadshedding_friendly': recipe.isLoadsheddingFriendly,
        'is_braai_ready':           recipe.isBraaiReady,
        if (realSource != null) 'source_url': realSource,
      }).select('id').single();
      sharedId = inserted['id'] as String?;
    } catch (e) {
      debugPrint(
        'RecipeShareService.shareToWhatsCooking: shared_recipes insert '
        'failed — message will post without a tap target: $e',
      );
    }

    if (sharedId != null) {
      caption = '$caption\n\n[shared_recipe:$sharedId]';
    }
    if (caption.length > 2000) caption = '${caption.substring(0, 1997)}…';

    try {
      // Resolve the cooking channel for the user's active suburb. This is
      // the same `(suburb, category='cooking')` row the chat screen
      // subscribes to via watchMessages.
      final suburb = await CommunityHubService.instance.resolveActiveSuburb();
      final channelRow = await _db
          .from('community_channels')
          .select('id')
          .eq('suburb',   suburb)
          .eq('category', 'cooking')
          .maybeSingle();

      final channelId = channelRow?['id'] as String?;
      if (channelId == null) {
        debugPrint(
          'RecipeShareService.shareToWhatsCooking: no cooking channel '
          'for suburb="$suburb"',
        );
        return ShareResult.channelNotFound;
      }

      // Insert into channel_messages so the row lands in the same stream
      // the What's Cooking chat reads. user_id MUST equal auth.uid() to
      // satisfy the channel_messages_insert_self RLS policy. created_at
      // is left to the column default (now()).
      await _db.from('channel_messages').insert({
        'channel_id':   channelId,
        'user_id':      user.id,
        'message_text': caption,
        if (imageUrl != null && imageUrl.isNotEmpty) 'image_url': imageUrl,
      });
      return ShareResult.communitySuccess;
    } catch (e) {
      debugPrint('RecipeShareService.shareToWhatsCooking error: $e');
      return ShareResult.communityError;
    }
  }

  // ── Route B: system share sheet ──────────────────────────────────────────

  /// Invokes the native OS share sheet with a formatted recipe summary.
  ///
  /// The subject line doubles as the WhatsApp / SMS preview text.
  /// [sourceUrl] is included as a tappable link when available so the
  /// recipient can open the original recipe source.
  Future<ShareResult> shareViaSystem({required Recipe recipe}) async {
    final body = _buildShareText(recipe);
    final subject = '${recipe.title} — ChowSA Recipe 🍽️';

    await Share.share(body, subject: subject);
    // share_plus doesn't expose whether the user actually sent — we treat
    // invoking the sheet as a completed action.
    return ShareResult.systemShareInvoked;
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  String _buildCaption(Recipe recipe) {
    final buf = StringBuffer(
      'Check out this recipe I just cooked: ${recipe.title}! 🍽️',
    );
    if (recipe.ingredients.isNotEmpty) {
      buf.write('\n\n${recipe.ingredients.length} ingredient'
          '${recipe.ingredients.length == 1 ? '' : 's'} — ');
      // Surface the first 3 ingredients as a teaser, comma-separated.
      final preview = recipe.ingredients
          .take(3)
          .map((i) => i.name)
          .join(', ');
      buf.write(preview);
      if (recipe.ingredients.length > 3) buf.write('…');
    }
    return buf.toString();
  }

  String _buildShareText(Recipe recipe) {
    final buf = StringBuffer();
    buf.writeln('🍽️  ${recipe.title}');
    buf.writeln();

    if (recipe.ingredients.isNotEmpty) {
      buf.writeln('── INGREDIENTS ──────────────');
      for (final ing in recipe.ingredients) {
        buf.writeln('• ${formatIngredientLine(ing)}');
      }
      buf.writeln();
    }

    if (recipe.instructions.isNotEmpty) {
      buf.writeln('── METHOD ───────────────────');
      for (var i = 0; i < recipe.instructions.length; i++) {
        buf.writeln('${i + 1}. ${recipe.instructions[i]}');
      }
      buf.writeln();
    }

    if (recipe.sourceUrl != null &&
        recipe.sourceUrl!.startsWith('http')) {
      buf.writeln('🔗 ${recipe.sourceUrl}');
      buf.writeln();
    }

    buf.write('Shared via ChowSA 🇿🇦');
    return buf.toString();
  }

}
