// lib/views/community_feed_card.dart
//
// Stand-alone CommunityFeedCard powered by SocialService.
//
// Takes a raw Supabase row (Map<String, dynamic>) as input rather than the
// older _PostData model — designed so it can be dropped into any
// ListView.builder that's reading directly from the community_posts table:
//
//   ListView.builder(
//     itemCount: rows.length,
//     itemBuilder: (_, i) => CommunityFeedCard(post: rows[i]),
//   )
//
// Hits the SocialService for every metric — no local mock data, no
// optimistic counters that drift from the server.

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/social_service.dart';

class CommunityFeedCard extends StatefulWidget {
  const CommunityFeedCard({super.key, required this.post});

  final Map<String, dynamic> post;

  @override
  State<CommunityFeedCard> createState() => _CommunityFeedCardState();
}

class _CommunityFeedCardState extends State<CommunityFeedCard> {
  final _socialService = SocialService();

  int  _likesCount    = 0;
  int  _commentsCount = 0;
  bool _isLiked       = false;

  /// Resolved poster handle — fetched async via `_loadAuthorUsername` so the
  /// card never displays a raw `user_id` uuid string.
  String? _authorUsername;

  @override
  void initState() {
    super.initState();
    _loadMetrics();
    _loadAuthorUsername();
  }

  Future<void> _loadAuthorUsername() async {
    // Prefer the row's pre-joined username if present (community feed query
    // can embed it via PostgREST: `*, profiles:user_id(username)`).
    final pre = widget.post['username'] as String?;
    if (pre != null && pre.isNotEmpty) {
      setState(() => _authorUsername = pre);
      return;
    }
    final authorId = widget.post['user_id'] as String?;
    if (authorId == null || authorId.isEmpty) return;
    try {
      final row = await Supabase.instance.client
          .from('profiles')
          .select('username, handle')
          .eq('id', authorId)
          .maybeSingle();
      if (!mounted || row == null) return;
      final resolved = (row['username'] as String?) ??
                       (row['handle']   as String?);
      if (resolved != null && resolved.isNotEmpty) {
        setState(() => _authorUsername = resolved);
      }
    } catch (_) { /* leave _authorUsername null → fall back to label */ }
  }

  void _openImageLightbox(String imageUrl) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        iconTheme:       const IconThemeData(color: Colors.white),
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 0.5,
          maxScale: 4.0,
          child: Image.network(imageUrl),
        ),
      ),
    )));
  }

  Future<void> _loadMetrics() async {
    final metrics = await _socialService.getPostMetrics(
        widget.post['id'] as String);
    if (!mounted) return;
    setState(() {
      _likesCount    = (metrics['likesCount']    as int?) ?? 0;
      _commentsCount = (metrics['commentsCount'] as int?) ?? 0;
      _isLiked       = (metrics['isLiked']       as bool?) ?? false;
    });
  }

  Future<void> _handleLike() async {
    // Optimistic UI: flip immediately, then reconcile with the service
    // response so a slow network doesn't make the tap feel unresponsive.
    final wasLiked = _isLiked;
    setState(() {
      _isLiked    = !wasLiked;
      _likesCount = (_likesCount + (wasLiked ? -1 : 1)).clamp(0, 1 << 31);
    });

    final currentlyLiked = await _socialService.toggleLike(
        widget.post['id'] as String);

    // Reconcile if the server result disagrees with our optimistic guess
    // (e.g. RLS denied, network hiccup, double-tap race).
    if (mounted && currentlyLiked != !wasLiked) {
      setState(() {
        _isLiked    = currentlyLiked;
        _likesCount = (_likesCount + (currentlyLiked ? 1 : -1))
            .clamp(0, 1 << 31);
      });
    }
  }

  // Placeholder until the real CommentsSheet is built (Step 4+).
  void _showCommentsBottomSheet(String postId) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        builder: (_, scrollController) => Container(
          decoration: const BoxDecoration(
            color: Color(0xFFF4F1EA),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: const EdgeInsets.all(20),
          child: ListView(
            controller: scrollController,
            children: const [
              Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    'Comments coming soon, chom! 💬',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF0C351E),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final post     = widget.post;
    final title    = (post['recipe_title'] as String?) ?? 'Untitled';
    final cap      = (post['caption']      as String?) ?? '';
    final imageUrl = (post['image_url']    as String?)?.trim();
    final hasImage = imageUrl != null && imageUrl.isNotEmpty;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Tappable photo with pinch-to-zoom lightbox ─────────────────
          if (hasImage)
            GestureDetector(
              onTap: () => _openImageLightbox(imageUrl),
              child: Image.network(
                imageUrl,
                height: 220,
                width:  double.infinity,
                fit:    BoxFit.cover,
                errorBuilder: (_, __, ___) => const SizedBox(height: 0),
              ),
            ),

          // ── Title + author + caption ──────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize:   16,
                    fontWeight: FontWeight.w800,
                    color:      Color(0xFF0C351E),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '@${_authorUsername ?? "chef"}',
                  style: const TextStyle(
                    fontSize:   12,
                    fontWeight: FontWeight.w600,
                    color:      Color(0xFFE59B27),
                  ),
                ),
                if (cap.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    cap,
                    style: const TextStyle(
                        fontSize: 13, height: 1.4),
                  ),
                ],
              ],
            ),
          ),

          // ── Action row ──────────────────────────────────────────────────
          Row(
            children: [
              IconButton(
                icon: Icon(
                  _isLiked ? Icons.favorite : Icons.favorite_border,
                  color: _isLiked ? Colors.red : Colors.grey,
                ),
                onPressed: _handleLike,
              ),
              Text('$_likesCount'),
              const SizedBox(width: 16),
              IconButton(
                icon: const Icon(
                  Icons.mode_comment_outlined,
                  color: Colors.grey,
                ),
                onPressed: () =>
                    _showCommentsBottomSheet(widget.post['id'] as String),
              ),
              Text('$_commentsCount'), // ← live count tracker
            ],
          ),
        ],
      ),
    );
  }
}
