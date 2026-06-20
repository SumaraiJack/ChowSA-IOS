// lib/views/chat_reaction_overlay.dart
//
// PR 2 of the WhatsApp-parity chat upgrade. Self-contained overlay layer
// that fires on long-press of a chat bubble.
//
// Visual structure (top-to-bottom):
//   ┌────────────────────────────────────────────────────────┐
//   │ semi-translucent black barrier (tap = dismiss)         │
//   │                                                        │
//   │      ┌──────────────────────────┐                      │
//   │      │  ❤  👍  😂  🔥  😮  😢  🙏 │  ← reaction strip   │
//   │      └──────────────────────────┘                      │
//   │             [original bubble]                          │
//   │      (rendered by the chat list below, untouched)      │
//   │                                                        │
//   │   ┌────────────────────────────┐                       │
//   │   │ 📋  Copy text              │                       │
//   │   │ ✏️  Edit message            │ ← unified action menu │
//   │   │ 🗑️  Delete message          │                       │
//   │   │ 📌  Pin to channel         │                       │
//   │   └────────────────────────────┘                       │
//   └────────────────────────────────────────────────────────┘
//
// Strip sits ABOVE the bubble when the bubble is in the lower half of the
// screen, BELOW it when the bubble is near the top. The action menu is
// pinned to the bottom safe-area for stable position regardless of bubble
// location.
//
// All gestures route through this overlay while it's open — the
// underlying ListView's physics are also swapped to NeverScrollable by
// the parent, so the chat surface is fully frozen until dismiss.
//
// Lifecycle: opened via OverlayPortal.show() from the chat screen, closed
// by tap-outside, action selection, reaction selection, or back button.

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Locked-down emoji set persisted by the DB CHECK constraint on
/// `channel_message_reactions.emoji` (migration 20260622). Order here
/// drives the visual order of both the long-press strip AND the
/// aggregate-display strip inside the bubble.
const List<String> kChatReactionEmojis = [
  '❤️', '👍', '😂', '🔥', '😮', '😢', '🙏',
];

/// SA-flavoured labels — shown as tooltips on long-press of an individual
/// emoji on the strip. Optional flavour; the emoji itself is the primary
/// affordance.
const Map<String, String> kChatReactionLabels = {
  '❤️': 'Love',
  '👍': 'Sharp / Awuye',
  '😂': 'Lekker laugh',
  '🔥': 'Braai / Hot',
  '😮': 'Yoh!',
  '😢': 'Eish',
  '🙏': 'Thanks / Rha',
};

// =============================================================================
// ChatReactionOverlay — root widget rendered into the chat's OverlayPortal
// =============================================================================

class ChatReactionOverlay extends StatefulWidget {
  const ChatReactionOverlay({
    super.key,
    required this.bubbleRect,
    required this.onReact,
    required this.onAction,
    required this.onDismiss,
    required this.canEdit,
    required this.canDelete,
    required this.canPin,
    required this.isPinned,
    this.canModerate = false,
  });

  /// Screen-space rect of the bubble that was long-pressed. Captured by
  /// the parent off the cached GlobalKey at the moment of long-press, so
  /// the rect stays valid even if the underlying bubble rebuilds.
  final Rect                    bubbleRect;
  final ValueChanged<String>    onReact;
  final ValueChanged<String>    onAction;
  final VoidCallback            onDismiss;
  final bool                    canEdit;
  final bool                    canDelete;
  final bool                    canPin;
  final bool                    isPinned;
  /// True when the long-pressed message belongs to someone OTHER than the
  /// current user — surfaces "Report" + "Block user" rows, required by
  /// Google Play's UGC policy. False for own messages so users don't see
  /// "block yourself".
  final bool                    canModerate;

  @override
  State<ChatReactionOverlay> createState() => _ChatReactionOverlayState();
}

class _ChatReactionOverlayState extends State<ChatReactionOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double>   _curve;

  /// Estimated strip footprint. 7 emojis × ~46 px each + 16 px outer
  /// padding lands at ~338; round to 340 so the horizontal clamp has a
  /// fixed width to anchor against. Height is the rendered material
  /// pill (text 26 + vertical padding 12 + a couple px of breathing room).
  static const _stripWidth  = 340.0;
  static const _stripHeight = 50.0;
  static const _stripGap    = 8.0;

  /// Per-row height in [_ActionMenu] (emoji + title + optional subtitle +
  /// vertical padding). Conservative — slightly higher than the average
  /// rendered row so the strip's bottom-clamp keeps a real visual gap
  /// even when every row carries a subtitle.
  static const _menuRowHeight       = 70.0;
  /// Top + bottom padding inside the menu card.
  static const _menuVerticalPadding = 16.0;
  /// Gap between the bottom of the strip and the top of the action menu.
  /// Locked to a constant — the menu always anchors directly below the
  /// strip with exactly this gap, regardless of where in the viewport
  /// the bubble sits. The previous logic bottom-anchored the menu
  /// "when there was room", which made the gap balloon for bubbles
  /// high in the viewport and shrink for bubbles low down. Constant
  /// gap → identical layout across Spotted, Gatherings, Pantry,
  /// What's Cooking, and Braai Hub.
  static const _stripMenuGap        = 14.0;
  /// Bottom margin on the menu's Positioned (matches the
  /// `bottom: mq.padding.bottom + 16` below).
  static const _menuBottomMargin    = 16.0;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync:    this,
      duration: const Duration(milliseconds: 220),
    )..forward();
    _curve = CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mq     = MediaQuery.of(context);
    final bubble = widget.bubbleRect;

    // PR 5/44556: strip is the anchor, menu follows it.
    //
    // 1. Place the strip above the bubble when there's room, otherwise
    //    below. Clamp ONLY to the viewport bounds (AppBar at top,
    //    screen edge at bottom) — the menu no longer constrains it.
    // 2. Position the menu by `top` so it can shift down with the strip
    //    when the strip is forced low. When the strip sits high (normal
    //    case), the max() keeps the menu at its default bottom-anchored
    //    position so the user's thumb still has a near-the-bottom hit
    //    target. The two surfaces are stacked with [_stripMenuGap] of
    //    breathing room by construction — they can't overlap.
    final topSafe   = mq.padding.top + kToolbarHeight + 6;
    final stripBottomBound = mq.size.height
        - mq.padding.bottom
        - 8
        - _stripHeight;

    final rowCount = 1
        + (widget.canEdit     ? 1 : 0)
        + (widget.canDelete   ? 1 : 0)
        + (widget.canPin      ? 1 : 0)
        + (widget.canModerate ? 2 : 0);  // Report + Block
    final menuHeight = rowCount * _menuRowHeight + _menuVerticalPadding;

    final roomAbove  = bubble.top - topSafe;
    final preferAbove = roomAbove >= _stripHeight + _stripGap;
    var stripTop = preferAbove
        ? bubble.top - _stripHeight - _stripGap
        : bubble.bottom + _stripGap;
    final clampMax = stripBottomBound < topSafe ? topSafe : stripBottomBound;
    stripTop = stripTop.clamp(topSafe, clampMax);

    final stripBottom = stripTop + _stripHeight;
    // Menu is ALWAYS anchored directly below the strip with a constant
    // gap. The old "bottom-anchor when there's room" branch produced
    // wildly inconsistent gaps depending on bubble position — that was
    // exactly the visual bug across Spotted / Gatherings / Pantry /
    // What's Cooking. If the constant-anchored menu would slide off
    // the bottom of the viewport, push BOTH the strip and menu up so
    // the menu's bottom edge sits on _menuBottomMargin above the
    // bottom inset (the strip + bubble follow because stripTop is
    // recomputed from menuTop below).
    final bottomBound = mq.size.height - mq.padding.bottom - _menuBottomMargin;
    var menuTop = stripBottom + _stripMenuGap;
    if (menuTop + menuHeight > bottomBound) {
      // Force the menu to sit at the bottom bound and back-compute the
      // strip into its slot directly above (still gap-locked).
      menuTop  = bottomBound - menuHeight;
      stripTop = (menuTop - _stripMenuGap - _stripHeight)
          .clamp(topSafe, clampMax);
    }

    // Horizontal: centre over the bubble's centroid, then clamp so the
    // strip stays fully inside the viewport (12 px margin each side).
    // Computing left explicitly (instead of a Center widget) means a
    // narrow bubble pinned to the screen edge still gets a fully
    // visible strip — the previous Center-wrapped layout could push
    // half the strip off-screen when MediaQuery was unusually narrow.
    final desiredLeft = bubble.center.dx - _stripWidth / 2;
    final stripLeft = desiredLeft.clamp(
      12.0,
      (mq.size.width - _stripWidth - 12.0).clamp(12.0, double.infinity),
    );

    return Stack(
      children: [
        // ── Barrier — dims the chat and captures outside-taps ──────────
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap:    widget.onDismiss,
            child: FadeTransition(
              opacity: _curve,
              child:   Container(
                color: Colors.black.withValues(alpha: 0.45),
              ),
            ),
          ),
        ),

        // ── Reaction strip ─────────────────────────────────────────────
        // Positioned by `left/top` only — width is left to the Row's
        // intrinsic content so the SA emoji pool (some glyphs are
        // VS-16 sequences that render slightly wider on certain font
        // fallbacks) can't trip the "RIGHT OVERFLOWED BY 1.7 PIXELS"
        // banner against a hard 340-px clamp. [_stripWidth] remains as
        // the *centering anchor* for [stripLeft] math above; the actual
        // rendered width can run a couple of pixels over without harm.
        Positioned(
          top:  stripTop,
          left: stripLeft,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.92, end: 1.0).animate(
              CurvedAnimation(parent: _ctrl, curve: Curves.easeOutBack),
            ),
            alignment: preferAbove
                ? Alignment.bottomCenter
                : Alignment.topCenter,
            child: FadeTransition(
              opacity: _curve,
              child:   _ReactionStrip(
                onTap:     widget.onReact,
                animation: _ctrl,
              ),
            ),
          ),
        ),

        // ── Unified action menu ────────────────────────────────────────
        // Anchored by `top` (computed off the strip's bottom + a 12 px
        // gap) so the strip and menu always stack cleanly. In the normal
        // case the strip sits high and [menuTop] resolves to the default
        // bottom-anchored position; when the strip is forced low (bubble
        // near the top of the viewport), the menu shifts down with it.
        Positioned(
          left:  16,
          right: 16,
          top:   menuTop,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.25),
              end:   Offset.zero,
            ).animate(_curve),
            child: FadeTransition(
              opacity: _curve,
              child:   _ActionMenu(
                canEdit:     widget.canEdit,
                canDelete:   widget.canDelete,
                canPin:      widget.canPin,
                canModerate: widget.canModerate,
                isPinned:  widget.isPinned,
                onAction:  widget.onAction,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// _ReactionStrip — the 7-emoji floating bar
// =============================================================================

class _ReactionStrip extends StatelessWidget {
  const _ReactionStrip({
    required this.onTap,
    required this.animation,
  });
  final ValueChanged<String> onTap;
  final Animation<double>    animation;

  /// Per-emoji stagger window. The first glyph starts at t=0, each next
  /// one offsets by [_kStaggerStep], and each glyph's own animation runs
  /// over [_kStaggerWindow] using easeOutBack so the entrance reads as a
  /// quick cascade with a soft overshoot.
  static const double _kStaggerStep   = 0.07;
  static const double _kStaggerWindow = 0.35;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color:        AppTheme.kAlabaster,
          borderRadius: BorderRadius.circular(30),
          boxShadow: [
            BoxShadow(
              color:      Colors.black.withValues(alpha: 0.22),
              blurRadius: 20,
              offset:     const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (int i = 0; i < kChatReactionEmojis.length; i++)
              _StaggeredEmojiButton(
                emoji:     kChatReactionEmojis[i],
                index:     i,
                animation: animation,
                onTap:     onTap,
                staggerStep:   _kStaggerStep,
                staggerWindow: _kStaggerWindow,
              ),
          ],
        ),
      ),
    );
  }
}

class _StaggeredEmojiButton extends StatelessWidget {
  const _StaggeredEmojiButton({
    required this.emoji,
    required this.index,
    required this.animation,
    required this.onTap,
    required this.staggerStep,
    required this.staggerWindow,
  });

  final String              emoji;
  final int                 index;
  final Animation<double>   animation;
  final ValueChanged<String> onTap;
  final double              staggerStep;
  final double              staggerWindow;

  @override
  Widget build(BuildContext context) {
    final start = (index * staggerStep).clamp(0.0, 0.9);
    final end   = (start + staggerWindow).clamp(start + 0.001, 1.0);
    final curve = CurvedAnimation(
      parent: animation,
      curve:  Interval(start, end, curve: Curves.easeOutBack),
    );
    final fade  = CurvedAnimation(
      parent: animation,
      curve:  Interval(start, end, curve: Curves.easeOut),
    );
    return ScaleTransition(
      scale: curve,
      child: FadeTransition(
        opacity: fade,
        child: Tooltip(
          message:     kChatReactionLabels[emoji] ?? '',
          preferBelow: false,
          child: InkResponse(
            onTap:  () => onTap(emoji),
            radius: 26,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 7, vertical: 6),
              child: Text(emoji, style: const TextStyle(fontSize: 26)),
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// _ActionMenu — Edit / Delete / Pin / Copy with conditional rows
// =============================================================================

class _ActionMenu extends StatelessWidget {
  const _ActionMenu({
    required this.canEdit,
    required this.canDelete,
    required this.canPin,
    required this.isPinned,
    required this.onAction,
    this.canModerate = false,
  });

  final bool                    canEdit;
  final bool                    canDelete;
  final bool                    canPin;
  final bool                    isPinned;
  final bool                    canModerate;
  final ValueChanged<String>    onAction;

  @override
  Widget build(BuildContext context) {
    return Material(
      color:        AppTheme.kAlabaster,
      borderRadius: BorderRadius.circular(20),
      elevation:    8,
      shadowColor:  Colors.black.withValues(alpha: 0.35),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Copy is the universal action — visible to everyone.
          _ActionRow(
            emoji: '📋',
            label: 'Copy text',
            onTap: () => onAction('copy'),
          ),
          if (canEdit)
            _ActionRow(
              emoji: '✏️',
              label: 'Edit message',
              onTap: () => onAction('edit'),
            ),
          if (canDelete)
            _ActionRow(
              emoji:       '🗑️',
              label:       'Delete message',
              subtitle:    'This cannot be undone.',
              destructive: true,
              onTap:       () => onAction('delete'),
            ),
          if (canModerate)
            _ActionRow(
              emoji:    '🚩',
              label:    'Report message',
              subtitle: 'Send to our moderation team.',
              onTap:    () => onAction('report'),
            ),
          if (canModerate)
            _ActionRow(
              emoji:       '🚫',
              label:       'Block user',
              subtitle:    "You won't see their messages anywhere in the app.",
              destructive: true,
              onTap:       () => onAction('block'),
            ),
          if (canPin)
            _ActionRow(
              emoji:    isPinned ? '📍' : '📌',
              label:    isPinned ? 'Unpin message' : 'Pin to channel',
              subtitle: isPinned
                  ? 'Removes the announcement banner for everyone.'
                  : 'Shows this as a sticky banner above the chat.',
              onTap:    () => onAction('pin'),
            ),
        ],
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.emoji,
    required this.label,
    required this.onTap,
    this.subtitle,
    this.destructive = false,
  });

  final String       emoji;
  final String       label;
  final String?      subtitle;
  final bool         destructive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = destructive ? Colors.red.shade700 : AppTheme.kMidnight;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        child: Row(
          children: [
            Text(emoji, style: const TextStyle(fontSize: 20)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize:       MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      color:      fg,
                      fontWeight: FontWeight.w700,
                      fontSize:   14.5,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: TextStyle(
                        color:    fg.withValues(alpha: 0.65),
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// ReactionAggregateStrip — the in-bubble row of "❤️ 3  🔥 1" pills
// =============================================================================
//
// Rendered by _MessageBubble directly under the like row. Each pill shows
// an emoji + count; "mine" reactions get an accent outline so the user
// can tell which ones they've contributed to. Tap a pill to toggle that
// reaction.

class ReactionAggregateStrip extends StatelessWidget {
  const ReactionAggregateStrip({
    super.key,
    required this.aggregate,
    required this.onToggle,
  });

  /// emoji → (count, isMine)
  final Map<String, ({int count, bool mine})> aggregate;
  final ValueChanged<String>                   onToggle;

  @override
  Widget build(BuildContext context) {
    // Render in the canonical emoji order so the strip layout stays stable
    // across rebuilds even as the underlying counts change.
    final entries = [
      for (final e in kChatReactionEmojis)
        if (aggregate[e] != null) (e, aggregate[e]!),
    ];
    if (entries.isEmpty) return const SizedBox.shrink();

    return Wrap(
      spacing:    6,
      runSpacing: 4,
      children: [
        for (final (emoji, cell) in entries)
          _ReactionPill(
            emoji:    emoji,
            count:    cell.count,
            mine:     cell.mine,
            onTap:    () => onToggle(emoji),
          ),
      ],
    );
  }
}

class _ReactionPill extends StatelessWidget {
  const _ReactionPill({
    required this.emoji,
    required this.count,
    required this.mine,
    required this.onTap,
  });

  final String       emoji;
  final int          count;
  final bool         mine;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final countColor =
        mine ? AppTheme.kMidnight : cs.onSurfaceVariant;
    return InkWell(
      onTap:        onTap,
      borderRadius: BorderRadius.circular(20),
      // AnimatedContainer interpolates the mine ↔ not-mine palette swap so
      // the outline/fill change reads as a continuous tween rather than a
      // hard cut every time the user taps in/out of their own reaction.
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve:    Curves.easeOut,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: mine
              ? AppTheme.kProteaGold.withValues(alpha: 0.18)
              : cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: mine
                ? AppTheme.kProteaGold
                : cs.outlineVariant.withValues(alpha: 0.6),
            width: mine ? 1.2 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(emoji, style: const TextStyle(fontSize: 13)),
            const SizedBox(width: 4),
            // AnimatedSwitcher swaps the count digit out via a scale +
            // fade so every increment "pops" in. Keyed on the count so
            // identical numbers (e.g. rebuilding without a change) don't
            // re-animate, while every real bump gets the bounce.
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              switchInCurve:  Curves.easeOutBack,
              switchOutCurve: Curves.easeIn,
              transitionBuilder: (child, anim) => ScaleTransition(
                scale: anim,
                child: FadeTransition(opacity: anim, child: child),
              ),
              child: Text(
                '$count',
                key: ValueKey<int>(count),
                style: TextStyle(
                  color:      countColor,
                  fontSize:   11.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
