// lib/views/chat_image_lightbox.dart
//
// PR 1 of the WhatsApp-parity chat upgrade. Contains:
//
//   • BoundedChatImage         — bubble-side inline image. Caps height at
//                                 _kMaxInlineHeight, resolves and caches
//                                 the natural aspect per URL so re-mounts
//                                 skip the placeholder, wraps the bitmap
//                                 in a Hero keyed to the message id so a
//                                 tap can fly into the lightbox without
//                                 layout jumps.
//
//   • openChatImageLightbox(…) — push helper that routes to ChatImageLightbox
//                                 via a non-opaque PageRouteBuilder. Non-
//                                 opaque keeps the chat painted underneath,
//                                 which is what guarantees the return Hero
//                                 always has a source widget to land on.
//
//   • ChatImageLightbox        — full-screen viewer. InteractiveViewer
//                                 inside the Hero (NOT wrapping it — that
//                                 breaks the matrix transform mid-flight).
//                                 Tap-outside / close button / back button
//                                 dismiss; pinch-to-zoom + pan inside.
//
// Scope: visual + interaction only. No DB writes, no message-state hooks,
// no realtime subscriptions. Safe to ship independently of the reactions
// PR that comes next.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// =============================================================================
// Aspect-ratio cache
// =============================================================================
//
// Persists for the life of the Dart isolate. Keyed by image URL — the
// natural aspect doesn't change for a given asset, and the cache lets us
// avoid the 4:3-placeholder → resolved-aspect reflow when a bubble
// scrolls out of the cacheExtent and back in.

const double _kMaxInlineHeight   = 280;
const double _kDefaultAspect     = 4 / 3;
const double _kCornerRadius      = 12;
const double _kBubbleSidePadding = 14;   // matches ListView outer padding
const double _kBubbleInnerInset  = 14;   // matches bubble inner padding
const double _kRowSidePadding    = _kBubbleSidePadding + _kBubbleInnerInset;

final Map<String, double> _imageAspectCache = <String, double>{};

// =============================================================================
// BoundedChatImage — inline image rendered inside a message bubble
// =============================================================================

class BoundedChatImage extends StatefulWidget {
  const BoundedChatImage({
    super.key,
    required this.imageUrl,
    required this.heroTag,
    required this.messageId,
  });

  final String imageUrl;
  final String heroTag;
  /// PR 3: passed straight through to the lightbox so its existence-watcher
  /// can pop the route when the underlying row is deleted in real time.
  final String messageId;

  @override
  State<BoundedChatImage> createState() => _BoundedChatImageState();
}

class _BoundedChatImageState extends State<BoundedChatImage> {
  ImageStream?         _stream;
  ImageStreamListener? _listener;
  double?              _aspect;

  @override
  void initState() {
    super.initState();
    _aspect = _imageAspectCache[widget.imageUrl];
    if (_aspect == null) _resolveAspect();
  }

  @override
  void didUpdateWidget(covariant BoundedChatImage old) {
    super.didUpdateWidget(old);
    if (old.imageUrl != widget.imageUrl) {
      _detachListener();
      _aspect = _imageAspectCache[widget.imageUrl];
      if (_aspect == null) _resolveAspect();
    }
  }

  @override
  void dispose() {
    _detachListener();
    super.dispose();
  }

  void _detachListener() {
    if (_stream != null && _listener != null) {
      _stream!.removeListener(_listener!);
    }
    _stream = null;
    _listener = null;
  }

  /// Resolve the image's natural aspect ratio off the network image stream
  /// so the bubble can settle on the final shape before the bitmap finishes
  /// decoding into the visible widget. Result is cached forever per URL.
  void _resolveAspect() {
    final provider = NetworkImage(widget.imageUrl);
    final stream   = provider.resolve(const ImageConfiguration());
    final listener = ImageStreamListener(
      (info, _) {
        final w = info.image.width.toDouble();
        final h = info.image.height.toDouble();
        if (h <= 0 || w <= 0) return;
        final ratio = w / h;
        _imageAspectCache[widget.imageUrl] = ratio;
        if (mounted) setState(() => _aspect = ratio);
      },
      onError: (_, __) {/* swallow — error UI handled by Image.errorBuilder */},
    );
    stream.addListener(listener);
    _stream   = stream;
    _listener = listener;
  }

  /// Derives the decoded bitmap width so Flutter can downscale during
  /// decode rather than after rasterization. ~3-4× memory + scroll perf
  /// win on portrait phone photos.
  int _cacheWidthFor(BuildContext context, double widthLogical) {
    final dpr = MediaQuery.of(context).devicePixelRatio;
    return (widthLogical * dpr).round().clamp(64, 2048);
  }

  @override
  Widget build(BuildContext context) {
    final cs    = Theme.of(context).colorScheme;
    final aspect = _aspect ?? _kDefaultAspect;

    return LayoutBuilder(
      builder: (ctx, constraints) {
        // Resolve display dimensions against the actual bubble inner width.
        // Portrait images naturally exceed _kMaxInlineHeight and get cropped
        // via BoxFit.cover. Landscape images sit at their natural height
        // (clipped to the same ceiling).
        final width        = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.of(context).size.width - _kRowSidePadding * 2;
        final naturalHeight = width / aspect;
        final height       = naturalHeight.clamp(80.0, _kMaxInlineHeight);
        final cacheWidth   = _cacheWidthFor(ctx, width);

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => openChatImageLightbox(
            context,
            imageUrl:  widget.imageUrl,
            heroTag:   widget.heroTag,
            messageId: widget.messageId,
          ),
          child: SizedBox(
            width:  width,
            height: height,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(_kCornerRadius),
              child: Hero(
                tag: widget.heroTag,
                flightShuttleBuilder: _flightShuttleBuilder,
                child: Image.network(
                  widget.imageUrl,
                  fit:         BoxFit.cover,
                  width:       width,
                  height:      height,
                  cacheWidth:  cacheWidth,
                  // Placeholder height matches the resolved height so the
                  // bubble doesn't reflow when the bitmap arrives.
                  loadingBuilder: (_, child, progress) {
                    if (progress == null) return child;
                    return Container(
                      width:  width,
                      height: height,
                      color:  cs.surfaceContainerLow,
                      alignment: Alignment.center,
                      child: const CircularProgressIndicator(strokeWidth: 2),
                    );
                  },
                  errorBuilder: (_, __, ___) => Container(
                    width:  width,
                    height: height < 100 ? height : 100,
                    color:  cs.surfaceContainerLow,
                    alignment: Alignment.center,
                    child: const Text(
                      'Image unavailable',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Shared Hero flight shuttle — interpolates the image's corner radius from
/// the inline bubble (rounded ~12 px) to the lightbox (square 0 px) and
/// back. Without this the corners snap at flight-start/end which looks
/// abrupt against the slow size tween.
Widget _flightShuttleBuilder(
  BuildContext flightContext,
  Animation<double> animation,
  HeroFlightDirection direction,
  BuildContext fromHeroContext,
  BuildContext toHeroContext,
) {
  final hero = direction == HeroFlightDirection.push
      ? fromHeroContext.widget as Hero
      : toHeroContext.widget as Hero;
  return AnimatedBuilder(
    animation: animation,
    builder: (ctx, _) {
      final t = direction == HeroFlightDirection.push
          ? animation.value
          : 1 - animation.value;
      final radius = _kCornerRadius * (1 - t);
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: hero.child,
      );
    },
  );
}

// =============================================================================
// Lightbox route helper
// =============================================================================

/// Pushes the chat image lightbox on top of the current route. Uses a
/// non-opaque PageRouteBuilder so the chat list stays painted underneath —
/// the return Hero is then guaranteed to find a source widget to land on
/// (the bubble is still mounted and visible behind the lightbox barrier).
Future<void> openChatImageLightbox(
  BuildContext context, {
  required String imageUrl,
  required String heroTag,
  required String messageId,
}) {
  return Navigator.of(context, rootNavigator: true).push<void>(
    PageRouteBuilder<void>(
      opaque:                     false,
      barrierColor:               Colors.transparent,
      barrierDismissible:         false,
      transitionDuration:         const Duration(milliseconds: 280),
      reverseTransitionDuration:  const Duration(milliseconds: 220),
      pageBuilder: (ctx, anim, __) => ChatImageLightbox(
        imageUrl:  imageUrl,
        heroTag:   heroTag,
        messageId: messageId,
        animation: anim,
      ),
    ),
  );
}

// =============================================================================
// ChatImageLightbox — full-screen viewer
// =============================================================================

class ChatImageLightbox extends StatefulWidget {
  const ChatImageLightbox({
    super.key,
    required this.imageUrl,
    required this.heroTag,
    required this.messageId,
    required this.animation,
  });

  final String            imageUrl;
  final String            heroTag;
  final String            messageId;
  final Animation<double> animation;

  @override
  State<ChatImageLightbox> createState() => _ChatImageLightboxState();
}

class _ChatImageLightboxState extends State<ChatImageLightbox>
    with SingleTickerProviderStateMixin {
  // InteractiveViewer's transformation is exposed via this controller so
  // the swipe-down dismiss handler can read "scale == identity" before
  // claiming a vertical drag. When the user is zoomed-in, the controller's
  // value diverges from identity and the drag falls through to
  // InteractiveViewer for pan instead.
  final TransformationController _viewer = TransformationController();

  // ── Swipe-down dismiss state ───────────────────────────────────────────
  //
  // [_drag] is the accumulated vertical offset from the gesture start. We
  // translate the image by this amount and fade the barrier
  // proportionally to give the user a continuous "letting go" feel. On
  // release: velocity > 300 OR offset > 120 → pop. Otherwise [_snapBack]
  // animates the offset back to 0.
  double _drag = 0;
  late final AnimationController _snapBack;
  double _snapBackStart = 0;

  // ── Live-deletion safe-catch (PR 3) ────────────────────────────────────
  // Single .stream() subscription scoped to this message id. The moment
  // the row disappears server-side (owner delete / admin delete / CASCADE
  // from a parent table drop) the stream re-emits with an empty list and
  // we pop the route. Without this, the return Hero has no source widget
  // to land on and Flutter rasterises a stranded backdrop until the user
  // hits the close button manually.
  StreamSubscription<List<Map<String, dynamic>>>? _existenceSub;

  /// True the moment we initiate a pop (deletion or swipe). Stops the
  /// existence-watcher from triggering a second pop attempt during the
  /// reverse Hero flight, which would surface as a route-stack assert.
  bool _popping = false;

  @override
  void initState() {
    super.initState();
    _snapBack = AnimationController(
      vsync:    this,
      duration: const Duration(milliseconds: 240),
    )..addListener(_runSnapBack);
    _subscribeExistence();
  }

  @override
  void dispose() {
    _existenceSub?.cancel();
    _snapBack
      ..removeListener(_runSnapBack)
      ..dispose();
    _viewer.dispose();
    super.dispose();
  }

  // ── Existence subscription ─────────────────────────────────────────────

  void _subscribeExistence() {
    _existenceSub = Supabase.instance.client
        .from('channel_messages')
        .stream(primaryKey: ['id'])
        .eq('id', widget.messageId)
        .listen(
          (rows) {
            if (!mounted || _popping) return;
            if (rows.isEmpty) _dismiss(reason: _DismissReason.deleted);
          },
          // Realtime drops (WebSocket code 1006) surface as exceptions on
          // this stream. Without an onError handler they become uncaught
          // async errors and Crashlytics records them as FATAL
          // (#90e60632). Swallow — the lightbox can stay open through a
          // brief disconnect; the realtime channel auto-reconnects.
          onError: (_) {},
        );
  }

  // ── Dismiss paths ──────────────────────────────────────────────────────

  void _dismiss({_DismissReason reason = _DismissReason.user}) {
    if (_popping) return;
    _popping = true;
    final nav = Navigator.of(context);
    if (nav.canPop()) nav.pop();
  }

  // ── Snap-back animation ────────────────────────────────────────────────

  void _runSnapBack() {
    if (!mounted) return;
    setState(() {
      _drag = _snapBackStart * (1 - _snapBack.value);
    });
  }

  // ── Vertical drag handlers ─────────────────────────────────────────────

  bool _atIdentity() {
    // getMaxScaleOnAxis returns the effective scale of the current matrix
    // — 1.0 means InteractiveViewer is in its rest pose. We allow a tiny
    // tolerance so floating-point drift doesn't lock the dismiss gesture
    // out after a programmatic reset.
    final scale = _viewer.value.getMaxScaleOnAxis();
    return (scale - 1.0).abs() < 0.01;
  }

  void _onDragStart(DragStartDetails _) {
    _snapBack.stop();
    setState(() => _drag = 0);
  }

  void _onDragUpdate(DragUpdateDetails d) {
    setState(() {
      // Allow some upward give for a natural feel, clamp downward so the
      // image can't slide forever before release.
      _drag = (_drag + d.delta.dy).clamp(-80.0, 800.0);
    });
  }

  void _onDragEnd(DragEndDetails d) {
    final v = d.primaryVelocity ?? 0;
    if (v > 300 || _drag > 120) {
      _dismiss();
      return;
    }
    _snapBackStart = _drag;
    _snapBack
      ..reset()
      ..forward();
  }

  @override
  Widget build(BuildContext context) {
    final safeTop = MediaQuery.of(context).padding.top;
    // Barrier opacity follows the push animation, but ALSO fades out as
    // the user drags the image downward so the chat surface bleeds back
    // into view in real time.
    final pushOpacity = widget.animation.drive(
      CurveTween(curve: Curves.easeOut),
    );
    final dragFade = (1 - (_drag.abs() / 320)).clamp(0.0, 1.0);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          // ── Dismiss barrier (tap outside the image closes the route) ──
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap:    _dismiss,
              child: FadeTransition(
                opacity: pushOpacity,
                child: Opacity(
                  opacity: dragFade,
                  child:   Container(color: Colors.black),
                ),
              ),
            ),
          ),

          // ── Image stage ──────────────────────────────────────────────
          // ValueListenableBuilder on the TransformationController swaps
          // the drag-handler GestureDetector in/out based on the current
          // scale. At identity (1.0×) vertical drag = dismiss. Once
          // zoomed in, the wrapper is gone and InteractiveViewer handles
          // every gesture including pan — preserves pinch-to-zoom UX.
          Center(
            child: Transform.translate(
              offset: Offset(0, _drag),
              child: Hero(
                tag: widget.heroTag,
                flightShuttleBuilder: _flightShuttleBuilder,
                child: ValueListenableBuilder<Matrix4>(
                  valueListenable: _viewer,
                  builder: (ctx, _, child) {
                    final viewer = InteractiveViewer(
                      transformationController: _viewer,
                      minScale:     1,
                      maxScale:     4,
                      clipBehavior: Clip.none,
                      child: child!,
                    );
                    if (!_atIdentity()) return viewer;
                    return GestureDetector(
                      onVerticalDragStart:  _onDragStart,
                      onVerticalDragUpdate: _onDragUpdate,
                      onVerticalDragEnd:    _onDragEnd,
                      child: viewer,
                    );
                  },
                  child: Image.network(
                    widget.imageUrl,
                    fit: BoxFit.contain,
                    loadingBuilder: (_, child, progress) {
                      if (progress == null) return child;
                      return const SizedBox(
                        width: 48, height: 48,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color:       Colors.white,
                        ),
                      );
                    },
                    errorBuilder: (_, __, ___) => const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'Image unavailable',
                        style: TextStyle(color: Colors.white, fontSize: 14),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),

          // ── Close button (top-right, safe-area aware) ────────────────
          // Fades out alongside the barrier when the user drags so the
          // close affordance doesn't linger over the bleed-through chat.
          Positioned(
            top:   safeTop + 6,
            right: 6,
            child: FadeTransition(
              opacity: pushOpacity,
              child: Opacity(
                opacity: dragFade,
                child: Material(
                  color:        Colors.black.withValues(alpha: 0.35),
                  shape:        const CircleBorder(),
                  clipBehavior: Clip.antiAlias,
                  child: IconButton(
                    icon:      const Icon(Icons.close_rounded,
                        color: Colors.white),
                    tooltip:   'Close',
                    onPressed: _dismiss,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Internal — used by [_ChatImageLightboxState._dismiss] to differentiate
/// a user-initiated dismiss (tap / swipe / close button) from a forced
/// dismiss triggered by the message being deleted server-side. Currently
/// both code paths run the same Navigator.pop(), but keeping the reason
/// distinct lets us layer in deletion-specific UX (e.g. a brief "Message
/// deleted" toast) without touching the call sites.
enum _DismissReason { user, deleted }
