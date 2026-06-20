// lib/widgets/motion.dart
//
// ChowSA motion polish — tactile micro-interactions.
//
// All durations are clamped to 150-300 ms per design spec. Curves favour
// snappy ease-out shapes on press, elastic on success. Nothing here should
// ever loop indefinitely except the shimmer (which is purely cosmetic loading
// state).
//
// Exports:
//   PressableScale       — wraps any card/tile with a press-down scale + dim.
//   SaveBounceButton     — Protea Gold save toggle with elasticOut pop.
//   ShimmerBox           — single shimmering rounded box (skeleton primitive).
//   PostCardSkeleton     — full community-feed post skeleton.

import 'package:flutter/material.dart';

// ═══════════════════════════════════════════════════════════════════════════
//   PressableScale — tactile press feedback for cards & tiles
// ═══════════════════════════════════════════════════════════════════════════

/// Wraps [child] so that a finger pressing down on it scales the whole tile
/// down by 4 % and dims it ~5 %, then snaps back when released. Behaves
/// transparently when [onTap] is null — pressing still animates, the gesture
/// just no-ops.
class PressableScale extends StatefulWidget {
  const PressableScale({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.scale = 0.96,
    this.duration = const Duration(milliseconds: 180),
    this.dimOpacity = 0.94,
    this.behavior = HitTestBehavior.opaque,
  });

  final Widget               child;
  final VoidCallback?        onTap;
  final VoidCallback?        onLongPress;
  final double               scale;
  final Duration             duration;
  final double               dimOpacity;
  final HitTestBehavior      behavior;

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale> {
  bool _down = false;

  void _setDown(bool v) {
    if (_down != v) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior:      widget.behavior,
      onTap:         widget.onTap,
      onLongPress:   widget.onLongPress,
      onTapDown:     (_) => _setDown(true),
      onTapUp:       (_) => _setDown(false),
      onTapCancel:   () => _setDown(false),
      child: AnimatedScale(
        scale:    _down ? widget.scale : 1.0,
        duration: widget.duration,
        curve:    Curves.easeOut,
        child: AnimatedOpacity(
          opacity:  _down ? widget.dimOpacity : 1.0,
          duration: widget.duration,
          curve:    Curves.easeOut,
          child:    widget.child,
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//   SaveBounceButton — Protea Gold spring on bookmark toggle
// ═══════════════════════════════════════════════════════════════════════════

/// A bookmark toggle that pops outward with [Curves.elasticOut] each time
/// [isSaved] flips. Internally a [FilledButton] / [FilledButton.tonal] swap so
/// it inherits the active theme's accent colours.
class SaveBounceButton extends StatefulWidget {
  const SaveBounceButton({
    super.key,
    required this.isSaved,
    required this.onTap,
    this.savedLabel   = 'Saved!',
    this.unsavedLabel = 'Save to Recipes',
  });

  final bool         isSaved;
  final VoidCallback onTap;
  final String       savedLabel;
  final String       unsavedLabel;

  @override
  State<SaveBounceButton> createState() => _SaveBounceButtonState();
}

class _SaveBounceButtonState extends State<SaveBounceButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final Animation<double>   _bounce;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync:    this,
      duration: const Duration(milliseconds: 280),
      value:    1.0,
    );
    _bounce = Tween<double>(begin: 0.85, end: 1.0)
        .chain(CurveTween(curve: Curves.elasticOut))
        .animate(_c);
  }

  @override
  void didUpdateWidget(covariant SaveBounceButton old) {
    super.didUpdateWidget(old);
    if (old.isSaved != widget.isSaved) {
      _c.forward(from: 0.0);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _handleTap() {
    _c.forward(from: 0.0);
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    final saved = widget.isSaved;
    return ScaleTransition(
      scale: _bounce,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        switchInCurve:  Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        child: saved
            ? FilledButton.icon(
                key: const ValueKey('saved'),
                onPressed: _handleTap,
                icon: const Icon(Icons.bookmark_rounded, size: 16),
                label: Text(
                  widget.savedLabel,
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 13),
                ),
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              )
            : FilledButton.tonalIcon(
                key: const ValueKey('unsaved'),
                onPressed: _handleTap,
                icon: const Icon(Icons.bookmark_border_rounded, size: 16),
                label: Text(
                  widget.unsavedLabel,
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 13),
                ),
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//   ShimmerBox — single skeleton primitive with sliding gradient sheen
// ═══════════════════════════════════════════════════════════════════════════

/// A rounded box with a soft horizontal shimmer that slides Cream → deeper
/// tone → Cream every ~1100 ms. Pulls base colour from
/// `colorScheme.surfaceContainerLow` so it adapts to every theme.
class ShimmerBox extends StatefulWidget {
  const ShimmerBox({
    super.key,
    this.width,
    this.height = 16,
    this.radius = 8,
  });

  final double? width;
  final double  height;
  final double  radius;

  @override
  State<ShimmerBox> createState() => _ShimmerBoxState();
}

class _ShimmerBoxState extends State<ShimmerBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))
        ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs   = Theme.of(context).colorScheme;
    final base = cs.surfaceContainerLow;
    // Slightly deeper tone of the same surface — works for light and dark.
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final highlight = isDark
        ? Color.lerp(base, Colors.white, 0.06)!
        : Color.lerp(base, Colors.black, 0.06)!;

    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) {
        final t = _c.value; // 0 → 1
        return Container(
          width:  widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.radius),
            gradient: LinearGradient(
              begin:  Alignment(-1.0 - 2 * t, 0),
              end:    Alignment( 1.0 - 2 * t, 0),
              colors: [base, highlight, base],
              stops:  const [0.35, 0.5, 0.65],
            ),
          ),
        );
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
//   PostCardSkeleton — community-feed loading placeholder
// ═══════════════════════════════════════════════════════════════════════════

/// Mirrors the visual rhythm of `_PostCard` so swapping it in during fetch
/// avoids any layout jump. Use inside a `ListView.separated` exactly like the
/// real card.
class PostCardSkeleton extends StatelessWidget {
  const PostCardSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.7)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header — avatar + name lines
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
            child: Row(
              children: const [
                ShimmerBox(width: 38, height: 38, radius: 19),
                SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ShimmerBox(width: 140, height: 12, radius: 6),
                      SizedBox(height: 6),
                      ShimmerBox(width:  80, height: 10, radius: 5),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // Image block
          const AspectRatio(
            aspectRatio: 16 / 11,
            child: ShimmerBox(radius: 0, height: double.infinity),
          ),
          // Caption lines
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ShimmerBox(height: 12, radius: 6),
                SizedBox(height: 8),
                ShimmerBox(width: 220, height: 12, radius: 6),
              ],
            ),
          ),
          // Tag chips
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 14, 12, 0),
            child: Row(
              children: [
                ShimmerBox(width: 60, height: 22, radius: 11),
                SizedBox(width: 6),
                ShimmerBox(width: 80, height: 22, radius: 11),
                SizedBox(width: 6),
                ShimmerBox(width: 50, height: 22, radius: 11),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // Action row
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Row(
              children: [
                ShimmerBox(width: 40, height: 18, radius: 9),
                SizedBox(width: 16),
                ShimmerBox(width: 40, height: 18, radius: 9),
                Spacer(),
                ShimmerBox(width: 130, height: 32, radius: 12),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
