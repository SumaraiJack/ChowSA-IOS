// lib/widgets/animated_emoji.dart
//
// Lightweight, repeat-looping emoji animator used by hub headers and the
// Community status-row tiles to give the surfaces a buzzing, alive feel
// without the weight of a full Lottie pipeline.
//
// Pick an [EmojiAnim] that matches the glyph's vibe:
//   • drive    — translates horizontally, eg. 🚚 rolling
//   • wave     — top-pivoted rotation, eg. 🎪 tent flag flapping
//   • swing    — top-pivoted wider rotation, eg. 🏷️ price tag swinging
//   • sizzle   — scale-jitter + micro-rotation, eg. 🍳 egg sizzling
//   • flicker  — scale + opacity pulse, eg. 🔥 flame flickering
//   • bounce   — vertical hop, eg. 🛒 trolley
//   • pulse    — gentle in/out scale with a soft halo, eg. community glow

import 'dart:math' as math;

import 'package:flutter/material.dart';

enum EmojiAnim { drive, wave, swing, sizzle, flicker, bounce, pulse }

class AnimatedEmoji extends StatefulWidget {
  const AnimatedEmoji({
    super.key,
    required this.emoji,
    required this.anim,
    this.size = 36,
    this.haloColor,
  });

  final String      emoji;
  final EmojiAnim   anim;
  final double      size;
  /// When non-null, a soft circular halo of this colour pulses behind the
  /// glyph in sync with the animation. Used by hero/header placements
  /// where the emoji needs to "pop" off the background.
  final Color?      haloColor;

  @override
  State<AnimatedEmoji> createState() => _AnimatedEmojiState();
}

class _AnimatedEmojiState extends State<AnimatedEmoji>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  Duration get _period {
    switch (widget.anim) {
      case EmojiAnim.drive:   return const Duration(milliseconds: 2400);
      case EmojiAnim.wave:    return const Duration(milliseconds: 1600);
      case EmojiAnim.swing:   return const Duration(milliseconds: 1800);
      case EmojiAnim.sizzle:  return const Duration(milliseconds:  900);
      case EmojiAnim.flicker: return const Duration(milliseconds:  700);
      case EmojiAnim.bounce:  return const Duration(milliseconds: 1200);
      case EmojiAnim.pulse:   return const Duration(milliseconds: 1800);
    }
  }

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: _period)..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) {
        final t = _ctrl.value;                       // 0..1
        final two = math.sin(t * 2 * math.pi);       // -1..1
        double dx = 0, dy = 0, scale = 1, rot = 0, opacity = 1;
        Alignment pivot = Alignment.center;

        switch (widget.anim) {
          case EmojiAnim.drive:
            dx = two * 4;
            // micro-bob
            dy = math.sin(t * 4 * math.pi) * 0.6;
            break;
          case EmojiAnim.wave:
            rot   = two * 0.10;
            pivot = Alignment.topCenter;
            break;
          case EmojiAnim.swing:
            rot   = two * 0.16;
            pivot = Alignment.topCenter;
            break;
          case EmojiAnim.sizzle:
            scale = 1 + two * 0.04;
            rot   = math.sin(t * 6 * math.pi) * 0.04;
            break;
          case EmojiAnim.flicker:
            scale   = 1 + two * 0.07;
            opacity = 0.85 + (two.abs() * 0.15);
            break;
          case EmojiAnim.bounce:
            dy = -two.abs() * 5;
            scale = 1 + two.abs() * 0.04;
            break;
          case EmojiAnim.pulse:
            scale = 1 + two * 0.05;
            opacity = 0.92 + two.abs() * 0.08;
            break;
        }

        Widget glyph = Transform.translate(
          offset: Offset(dx, dy),
          child: Transform.rotate(
            angle: rot,
            alignment: pivot,
            child: Transform.scale(
              scale: scale,
              child: Opacity(
                opacity: opacity,
                child: Text(
                  widget.emoji,
                  style: TextStyle(fontSize: widget.size),
                ),
              ),
            ),
          ),
        );

        if (widget.haloColor != null) {
          final haloScale = 1 + two.abs() * 0.25;
          glyph = Stack(
            alignment: Alignment.center,
            children: [
              Transform.scale(
                scale: haloScale,
                child: Container(
                  width:  widget.size * 1.55,
                  height: widget.size * 1.55,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        widget.haloColor!.withAlpha(120),
                        widget.haloColor!.withAlpha(0),
                      ],
                    ),
                  ),
                ),
              ),
              glyph,
            ],
          );
        }

        return glyph;
      },
    );
  }
}

/// Convenience mapper — pairs each [emoji] string the Community Hub uses
/// with the animation that best fits its character. Falls back to a gentle
/// pulse for anything unrecognised.
EmojiAnim animForCommunityEmoji(String emoji) {
  switch (emoji) {
    case '🚚':  return EmojiAnim.drive;
    case '🎪':  return EmojiAnim.wave;
    case '🏷️': return EmojiAnim.swing;
    case '🏷':  return EmojiAnim.swing;
    case '🍳':  return EmojiAnim.sizzle;
    case '🔥':  return EmojiAnim.flicker;
    case '🛒':  return EmojiAnim.bounce;
    default:    return EmojiAnim.pulse;
  }
}
