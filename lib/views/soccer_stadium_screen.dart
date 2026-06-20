// lib/views/soccer_stadium_screen.dart
//
// World Cup Soccer Stadium Screen.
//
// Layout (top → bottom):
//
//   ┌─────────────────────────────────────────────┐
//   │  _StadiumHeader  (pinned, intrinsic height) │
//   │  • Bafana green/gold gradient or dark navy  │
//   │  • Live score / VS countdown / Full Time    │
//   │  • Trophy Lottie → tabbed fixture sheet     │
//   └─────────────────────────────────────────────┘
//   ┌─────────────────────────────────────────────┐
//   │  _StadiumChatBody  (Expanded, ~70%)         │
//   │  Realtime banter channel, wired to the      │
//   │  GLOBAL community_channel row seeded by the │
//   │  wc_matches migration.                      │
//   └─────────────────────────────────────────────┘
//
// Bug fixes applied in this version
// ──────────────────────────────────
//  • Chat race condition: SoccerStadiumScreen now listens to
//    WorldCupService.stadiumChannelIdNotifier so it rebuilds the moment the
//    async channel lookup completes — previously the screen would lock on
//    "Stadium chat loading…" because nothing triggered a repaint after the
//    plain String? field was populated.
//
//  • Header overflow: _ScoreBlock wraps team columns in flexible layout with
//    maxLines + ellipsis on every label so long names never overflow.
//
//  • Fixture sheet: converted to StatefulWidget with three tabs
//    (Live ⚡ / Upcoming 📅 / Finished ✓) and richer match cards.

import 'dart:io';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:dotlottie_loader/dotlottie_loader.dart';
import 'package:image_picker/image_picker.dart';
import 'package:lottie/lottie.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/wc_match_model.dart';
import '../services/community_hub_service.dart';
import '../services/moderation_service.dart';
import '../services/social_service.dart';
import '../services/world_cup_service.dart';
import '../widgets/motion.dart';
import 'chat_reaction_overlay.dart';

// ── Design tokens ──────────────────────────────────────────────────────────

const _kGold       = Color(0xFFD4A017);
const _kGreenDeep  = Color(0xFF004D25);
const _kGreenMid   = Color(0xFF006633);
const _kGreenLight = Color(0xFF1A7A47);
const _kNavyDeep   = Color(0xFF1A1A2E);
const _kNavyMid    = Color(0xFF16213E);
const _kNavyLight  = Color(0xFF0F3460);
const _kDarkBg     = Color(0xFF111111);
const _kDarkCard   = Color(0xFF1E1E1E);
const _kDarkBorder = Color(0xFF333333);
const _kWhite      = Colors.white;

// =============================================================================
//   Screen entry point
// =============================================================================

class SoccerStadiumScreen extends StatefulWidget {
  const SoccerStadiumScreen({super.key});

  @override
  State<SoccerStadiumScreen> createState() => _SoccerStadiumScreenState();
}

class _SoccerStadiumScreenState extends State<SoccerStadiumScreen> {
  // Holds the resolved channel ID — updated via ValueNotifier listener so
  // the chat body renders as soon as the async lookup completes.
  String? _channelId;

  // True once the 3-second resolver budget has elapsed without a channel.
  // The view swaps the infinite spinner for [_ChatUnavailable] so the user
  // sees something actionable instead of staring at "Connecting to
  // stadium…" forever.
  bool _resolveTimedOut = false;

  Timer? _resolveTimer;

  static const _kResolveTimeout = Duration(seconds: 3);

  @override
  void initState() {
    super.initState();
    // Snapshot whatever is already resolved (if init() completed before we
    // opened the screen).
    _channelId = WorldCupService.instance.stadiumChannelId;

    // Listen for the channel ID to resolve if it hasn't yet.  When the
    // notifier fires, we call setState so the Scaffold rebuilds and swaps
    // _ChatResolving for the real _StadiumChatBody.
    WorldCupService.instance.stadiumChannelIdNotifier
        .addListener(_onChannelIdResolved);

    // 3-second timeout. If the channel still isn't resolved by then, kick
    // a second resolve attempt explicitly (covers the case where init()
    // hit a transient network blip during boot) and, if THAT also returns
    // null, flip _resolveTimedOut so the UI exits the spinner state.
    if (_channelId == null) {
      _resolveTimer = Timer(_kResolveTimeout, _onResolveTimeout);
    }
  }

  Future<void> _onResolveTimeout() async {
    if (!mounted || _channelId != null) return;
    final retried =
        await WorldCupService.instance.retryStadiumChannelResolve();
    if (!mounted) return;
    if (retried != null) {
      setState(() => _channelId = retried);
    } else {
      setState(() => _resolveTimedOut = true);
    }
  }

  void _onChannelIdResolved() {
    final id = WorldCupService.instance.stadiumChannelIdNotifier.value;
    if (id != null && id != _channelId && mounted) {
      _resolveTimer?.cancel();
      setState(() {
        _channelId       = id;
        _resolveTimedOut = false;
      });
    }
  }

  void _onRetryFromError() {
    setState(() => _resolveTimedOut = false);
    _resolveTimer?.cancel();
    _resolveTimer = Timer(_kResolveTimeout, _onResolveTimeout);
    // Fire the resolver immediately; the timer is the safety net.
    unawaited(WorldCupService.instance.retryStadiumChannelResolve());
  }

  @override
  void dispose() {
    _resolveTimer?.cancel();
    WorldCupService.instance.stadiumChannelIdNotifier
        .removeListener(_onChannelIdResolved);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<WcMatchModel?>(
      valueListenable: WorldCupService.instance.priorityMatch,
      builder: (context, match, _) {
        final isBafana = match?.isBafanaMatch ?? false;
        return Scaffold(
          backgroundColor: _kDarkBg,
          // EXPLICIT: leave the default behaviour on (true) so the body
          // shrinks when the IME opens. The composer at the bottom of the
          // chat body relies on this — without it the soft keyboard would
          // cover the input field entirely.
          resizeToAvoidBottomInset: true,
          body: Column(
            children: [
              // ── Pinned header ───────────────────────────────────────────
              _StadiumHeader(match: match, isBafana: isBafana),

              // ── Live banter chat ────────────────────────────────────────
              // Wrapped in Expanded so the middle area dynamically gives
              // back vertical space to the keyboard. The chat body itself
              // is a Column with its own Expanded around the message list,
              // so the squeeze cascades correctly to the empty-state /
              // message list / composer stack inside.
              Expanded(
                child: _channelId != null
                    ? _StadiumChatBody(
                        channelId: _channelId!,
                        isBafana:  isBafana,
                      )
                    : _resolveTimedOut
                        ? _ChatUnavailable(onRetry: _onRetryFromError)
                        : const _ChatResolving(),
              ),
            ],
          ),
        );
      },
    );
  }
}

// =============================================================================
//   _StadiumHeader — pinned top block
// =============================================================================

class _StadiumHeader extends StatelessWidget {
  const _StadiumHeader({required this.match, required this.isBafana});

  final WcMatchModel? match;
  final bool          isBafana;

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.of(context).padding.top;

    return Container(
      width: double.infinity,
      padding: EdgeInsets.only(top: topPad + 6, bottom: 16),
      decoration: BoxDecoration(
        gradient: isBafana
            ? const LinearGradient(
                colors: [_kGreenDeep, _kGreenMid, _kGreenLight],
                begin:  Alignment.topLeft,
                end:    Alignment.bottomRight,
              )
            : const LinearGradient(
                colors: [_kNavyDeep, _kNavyMid, _kNavyLight],
                begin:  Alignment.topLeft,
                end:    Alignment.bottomRight,
              ),
        borderRadius: const BorderRadius.only(
          bottomLeft:  Radius.circular(28),
          bottomRight: Radius.circular(28),
        ),
        border: isBafana
            ? Border.all(color: _kGold.withAlpha(80), width: 1.5)
            : null,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [

          // ── App-bar row: back · title · trophy ──────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 8, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back_rounded,
                      color: _kWhite, size: 22),
                  onPressed: () => Navigator.maybePop(context),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        isBafana ? '🇿🇦  BAFANA BAFANA' : '⚽  FIFA WORLD CUP 2026™',
                        style: const TextStyle(
                          color:      _kWhite,
                          fontSize:   15,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.4,
                        ),
                      ),
                      if (match != null)
                        Text(
                          match!.stage.toUpperCase(),
                          style: TextStyle(
                            color:         isBafana
                                ? _kGold.withAlpha(200)
                                : Colors.white54,
                            fontSize:      10.5,
                            fontWeight:    FontWeight.w700,
                            letterSpacing: 1.2,
                          ),
                        ),
                    ],
                  ),
                ),
                // Trophy button → fixture sheet
                _TrophyButton(isBafana: isBafana),
              ],
            ),
          ),

          const SizedBox(height: 10),

          // ── Score / upcoming block ───────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: match != null
                ? _ScoreBlock(match: match!, isBafana: isBafana)
                : Text(
                    'Tournament kicks off 11 June 2026  🏆',
                    style: TextStyle(
                      color:    Colors.white.withAlpha(160),
                      fontSize: 13,
                      height:   1.4,
                    ),
                    textAlign: TextAlign.center,
                  ),
          ),

          // ── Bafana hype ticker ───────────────────────────────────────────
          if (isBafana) ...[
            const SizedBox(height: 8),
            Container(
              margin:  const EdgeInsets.fromLTRB(16, 0, 16, 0),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              decoration: BoxDecoration(
                color:        _kGold.withAlpha(28),
                borderRadius: BorderRadius.circular(8),
                border:       Border.all(color: _kGold.withAlpha(80)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: const [
                  Text('🟡', style: TextStyle(fontSize: 11)),
                  SizedBox(width: 6),
                  Text(
                    'MZANSI IS WATCHING — MAKE SOME NOISE!',
                    style: TextStyle(
                      color:      _kGold,
                      fontSize:   9.5,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.0,
                    ),
                  ),
                  SizedBox(width: 6),
                  Text('🟢', style: TextStyle(fontSize: 11)),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// =============================================================================
//   _TrophyButton — Lottie icon that opens the tabbed fixture sheet
// =============================================================================
//
// First-run affordance:
//   The trophy is the only way into the Match Center / full fixture sheet,
//   but its purpose isn't obvious from the icon alone. On a user's first
//   visit we surface a pulsing tooltip bubble below the trophy reading
//   "Tap here for full fixtures & Match Center!".
//
//   Dismissal is sticky — the bubble disappears for good once the user
//   either taps the trophy (opening the sheet) or taps the bubble's close
//   chip. State is persisted under [_kFixturesHintSeenKey] in
//   SharedPreferences so it survives reinstalls of the screen and reboots.

const _kFixturesHintSeenKey = 'has_seen_fixtures_hint';

class _TrophyButton extends StatefulWidget {
  const _TrophyButton({required this.isBafana});

  final bool isBafana;

  @override
  State<_TrophyButton> createState() => _TrophyButtonState();
}

class _TrophyButtonState extends State<_TrophyButton>
    with SingleTickerProviderStateMixin {
  static const _lottiePath =
      'assets/animations/Soccer Sport Trophy with Soccer Ball and Shoes.lottie';

  final GlobalKey _trophyKey = GlobalKey();
  OverlayEntry?    _hintEntry;
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat(reverse: true);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShowHint());
  }

  @override
  void dispose() {
    _hintEntry?.remove();
    _hintEntry = null;
    _pulse.dispose();
    super.dispose();
  }

  Future<void> _maybeShowHint() async {
    if (!mounted) return;
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    if (prefs.getBool(_kFixturesHintSeenKey) ?? false) return;
    _showHintOverlay();
  }

  Future<void> _dismissHint() async {
    if (_hintEntry == null) return;
    _hintEntry!.remove();
    _hintEntry = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kFixturesHintSeenKey, true);
  }

  void _showHintOverlay() {
    final renderObject =
        _trophyKey.currentContext?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.attached) return;
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;

    final size   = renderObject.size;
    final origin = renderObject.localToGlobal(Offset.zero);
    // Position the bubble just below the trophy, right-aligned to it so the
    // arrow points up at the icon's centre.
    final trophyCenterX = origin.dx + size.width / 2;
    final top           = origin.dy + size.height + 8;

    _hintEntry = OverlayEntry(
      builder: (ctx) {
        final screenW = MediaQuery.of(ctx).size.width;
        const bubbleW = 230.0;
        // Clamp so the bubble never bleeds off-screen on small devices.
        final left = (trophyCenterX - bubbleW + 24)
            .clamp(8.0, screenW - bubbleW - 8.0);
        final arrowOffsetFromLeft = (trophyCenterX - left).clamp(20.0, bubbleW - 20.0);

        return Positioned(
          top:  top,
          left: left,
          width: bubbleW,
          child: _FixturesHintBubble(
            arrowOffsetFromLeft: arrowOffsetFromLeft,
            pulse:               _pulse,
            isBafana:            widget.isBafana,
            onDismiss:           _dismissHint,
          ),
        );
      },
    );
    overlay.insert(_hintEntry!);
  }

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      onTap: () {
        // Tapping the trophy counts as "seen" — the user has discovered the
        // entry point, so the hint should never reappear.
        _dismissHint();
        _openFixtureSheet(context);
      },
      child: Container(
        key:    _trophyKey,
        width:  52,
        height: 52,
        decoration: BoxDecoration(
          color:        widget.isBafana
              ? _kGold.withAlpha(25)
              : Colors.white.withAlpha(15),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: widget.isBafana ? _kGold.withAlpha(100) : Colors.white24,
            width: 1.2,
          ),
        ),
        child: DotLottieLoader.fromAsset(
          _lottiePath,
          frameBuilder: (ctx, comp) {
            if (comp == null || comp.animations.isEmpty) {
              // File not yet decoded or not found — fallback to material icon
              return const Center(
                child: Icon(Icons.emoji_events_rounded,
                    color: _kGold, size: 26),
              );
            }
            return Lottie.memory(
              comp.animations.values.first,
              width:  40,
              height: 40,
              fit:    BoxFit.contain,
              repeat: true,
            );
          },
        ),
      ),
    );
  }

  void _openFixtureSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context:            context,
      backgroundColor:    _kDarkCard,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => const _FixtureSheet(),
    );
  }
}

// =============================================================================
//   _FixturesHintBubble — first-run coach-mark below the trophy
// =============================================================================

class _FixturesHintBubble extends StatelessWidget {
  const _FixturesHintBubble({
    required this.arrowOffsetFromLeft,
    required this.pulse,
    required this.isBafana,
    required this.onDismiss,
  });

  final double           arrowOffsetFromLeft;
  final Animation<double> pulse;
  final bool             isBafana;
  final VoidCallback     onDismiss;

  @override
  Widget build(BuildContext context) {
    final accent = isBafana ? _kGold : Colors.blueAccent.shade100;
    return Material(
      type: MaterialType.transparency,
      child: FadeTransition(
        opacity: AlwaysStoppedAnimation(1.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize:       MainAxisSize.min,
          children: [
            // ── Arrow pointing up at the trophy ──────────────────────────────
            Padding(
              padding: EdgeInsets.only(left: arrowOffsetFromLeft - 6),
              child: CustomPaint(
                size:    const Size(12, 7),
                painter: _BubbleArrowPainter(color: accent),
              ),
            ),
            // ── Pulsing bubble body ──────────────────────────────────────────
            AnimatedBuilder(
              animation: pulse,
              builder: (_, child) {
                // Gentle 0.92 → 1.0 alpha breathing on the border + soft
                // outer glow so the bubble draws the eye without being noisy.
                final t = 0.6 + 0.4 * pulse.value;
                return Container(
                  decoration: BoxDecoration(
                    color:        Colors.black.withAlpha(230),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: accent.withAlpha((255 * t).round()),
                      width: 1.4,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color:    accent.withAlpha((90 * t).round()),
                        blurRadius: 18,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                  child: child,
                );
              },
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.emoji_events_rounded,
                        color: accent, size: 18),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Tap here for full fixtures & Match Center!',
                        style: TextStyle(
                          color:      _kWhite,
                          fontSize:   12.5,
                          fontWeight: FontWeight.w700,
                          height:     1.3,
                        ),
                      ),
                    ),
                    InkResponse(
                      radius:   16,
                      onTap:    onDismiss,
                      child: const Padding(
                        padding: EdgeInsets.all(2),
                        child: Icon(Icons.close_rounded,
                            color: Colors.white54, size: 16),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BubbleArrowPainter extends CustomPainter {
  _BubbleArrowPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color..style = PaintingStyle.fill;
    final path = Path()
      ..moveTo(size.width / 2, 0)
      ..lineTo(0, size.height)
      ..lineTo(size.width, size.height)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _BubbleArrowPainter old) => old.color != color;
}

// =============================================================================
//   _ScoreBlock — main match display: teams + score / VS + live minute
// =============================================================================

class _ScoreBlock extends StatelessWidget {
  const _ScoreBlock({required this.match, required this.isBafana});

  final WcMatchModel match;
  final bool         isBafana;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Team A
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(match.teamAFlagEmoji,
                  style: const TextStyle(fontSize: 32)),
              const SizedBox(height: 4),
              Text(
                match.teamA,
                style: const TextStyle(
                  color:      _kWhite,
                  fontWeight: FontWeight.w800,
                  fontSize:   13,
                ),
                maxLines:  1,
                overflow:  TextOverflow.ellipsis,
              ),
            ],
          ),
        ),

        // Centre: score or VS
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (match.isLive || match.isFinished) ...[
                Text(
                  '${match.teamAScore}  –  ${match.teamBScore}',
                  style: const TextStyle(
                    color:      _kWhite,
                    fontWeight: FontWeight.w900,
                    fontSize:   26,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 4),
                if (match.isLive)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 7, height: 7,
                        decoration: const BoxDecoration(
                          color: Colors.redAccent,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        "LIVE  ${match.liveMinute}'",
                        style: const TextStyle(
                          color:      Colors.redAccent,
                          fontWeight: FontWeight.w800,
                          fontSize:   10.5,
                        ),
                      ),
                    ],
                  )
                else
                  const Text(
                    'FULL TIME',
                    style: TextStyle(
                      color:      Colors.white54,
                      fontWeight: FontWeight.w700,
                      fontSize:   10.5,
                    ),
                  ),
              ] else ...[
                Text(
                  'VS',
                  style: TextStyle(
                    color:      isBafana ? _kGold : Colors.white54,
                    fontWeight: FontWeight.w900,
                    fontSize:   20,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _kickoffLabel,
                  style: const TextStyle(
                    color:    Colors.white54,
                    fontSize: 10,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ],
          ),
        ),

        // Team B
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(match.teamBFlagEmoji,
                  style: const TextStyle(fontSize: 32)),
              const SizedBox(height: 4),
              Text(
                match.teamB,
                style: const TextStyle(
                  color:      _kWhite,
                  fontWeight: FontWeight.w800,
                  fontSize:   13,
                ),
                maxLines:  1,
                overflow:  TextOverflow.ellipsis,
                textAlign: TextAlign.end,
              ),
            ],
          ),
        ),
      ],
    );
  }

  String get _kickoffLabel {
    final dt = match.matchTime;
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    const months = [
      'Jan','Feb','Mar','Apr','May','Jun',
      'Jul','Aug','Sep','Oct','Nov','Dec',
    ];
    return '${dt.day} ${months[dt.month - 1]}\n$hh:$mm';
  }
}

// =============================================================================
//   _FixtureSheet — tabbed fixture list (Upcoming / Finished)
//
//   LIVE tab removed per spec — match status is now derived from kickoff
//   time vs. wall clock so a stale `scheduled` row in the DB whose
//   `match_time` is already in the past automatically slides into the
//   FINISHED tab. Bug ref: 44118 / 44121.
// =============================================================================

class _FixtureSheet extends StatefulWidget {
  const _FixtureSheet();

  @override
  State<_FixtureSheet> createState() => _FixtureSheetState();
}

class _FixtureSheetState extends State<_FixtureSheet>
    with SingleTickerProviderStateMixin {

  late final TabController _tabs;

  // Mirror of WorldCupService.allMatches — kept in sync via listener so
  // the sheet shows the latest fixtures and responds to realtime changes.
  List<WcMatchModel> _all = [];

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _all  = WorldCupService.instance.allMatches.value;
    WorldCupService.instance.allMatches.addListener(_onMatchesUpdated);
  }

  void _onMatchesUpdated() {
    if (mounted) {
      setState(() => _all = WorldCupService.instance.allMatches.value);
    }
  }

  @override
  void dispose() {
    WorldCupService.instance.allMatches.removeListener(_onMatchesUpdated);
    _tabs.dispose();
    super.dispose();
  }

  void _refresh() {
    WorldCupService.instance.init();
  }

  // Bucketing rule (tightened alongside the service-side promotion fix):
  // a match counts as FINISHED only when the row carries an explicit
  // `finished` status OR a non-zero scoreline has landed. Past-kickoff
  // rows that are still 0-0 with no status flip stay in UPCOMING rather
  // than ghosting into FULL TIME at 0-0 the moment the wall clock
  // crosses kickoff.
  bool _effectivelyFinished(WcMatchModel m) =>
      m.isFinished || (m.teamAScore != 0 || m.teamBScore != 0);

  /// "Effectively live" — explicit live, OR kickoff has just passed within
  /// the last 2h30 (covers TheSportsDB lag + cron interval). Such matches
  /// should NOT clutter the UPCOMING list — they're already prominently
  /// surfaced by the hero card at the top of the hub.
  bool _effectivelyLive(WcMatchModel m) {
    if (_effectivelyFinished(m)) return false;
    if (m.isLive) return true;
    final now = DateTime.now();
    final freshKickoff = now.subtract(const Duration(hours: 2, minutes: 30));
    return m.matchTime.isBefore(now) && m.matchTime.isAfter(freshKickoff);
  }

  List<WcMatchModel> get _upcoming => _all
      .where((m) => !_effectivelyFinished(m) && !_effectivelyLive(m))
      .toList();
  List<WcMatchModel> get _finished =>
      _all.where(_effectivelyFinished).toList();

  @override
  Widget build(BuildContext context) {
    final screenH  = MediaQuery.of(context).size.height;
    final all      = _all;
    final upcoming = _upcoming;
    final finished = _finished;

    return SizedBox(
      height: screenH * 0.82,
      child: Builder(
        builder: (context) {
          return Column(
            children: [

              // ── Drag handle ─────────────────────────────────────────────
              const SizedBox(height: 12),
              Center(
                child: Container(
                  width:  44, height: 4,
                  decoration: BoxDecoration(
                    color:        Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 14),

              // ── Sheet header ────────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 16, 0),
                child: Row(
                  children: [
                    const Text('🏆', style: TextStyle(fontSize: 22)),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'FIFA WORLD CUP 2026™',
                        style: TextStyle(
                          color:      _kWhite,
                          fontSize:   16,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                    // Manual refresh — re-hits the API.
                    IconButton(
                      icon:    const Icon(Icons.refresh_rounded,
                                          color: Colors.white70, size: 20),
                      tooltip: 'Refresh',
                      onPressed: _refresh,
                    ),
                    // Total match count chip.
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color:        Colors.white12,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        '${all.length} matches',
                        style: const TextStyle(
                          color:    Colors.white60,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 12),

              // ── Tab bar ─────────────────────────────────────────────────
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color:        Colors.white.withAlpha(10),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: TabBar(
                  controller:   _tabs,
                  indicator:    BoxDecoration(
                    color:        _kGold,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  indicatorSize:      TabBarIndicatorSize.tab,
                  dividerColor:       Colors.transparent,
                  labelColor:         Colors.black87,
                  unselectedLabelColor: Colors.white54,
                  labelStyle: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize:   12,
                    letterSpacing: 0.3,
                  ),
                  unselectedLabelStyle: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize:   12,
                  ),
                  padding: const EdgeInsets.all(4),
                  tabs: const [
                    Tab(text: 'UPCOMING'),
                    Tab(text: 'FINISHED'),
                  ],
                ),
              ),

              const SizedBox(height: 8),

              // ── Tab views ───────────────────────────────────────────────
              Expanded(
                child: TabBarView(
                  controller: _tabs,
                  children: [
                    _FixtureList(
                      matches:    upcoming,
                      allMatches: all,
                      emptyText:  'No upcoming matches scheduled.',
                      emptyEmoji: '📅',
                    ),
                    _FixtureList(
                      matches:    finished,
                      allMatches: all,
                      emptyText:  'No finished matches yet.',
                      emptyEmoji: '🏁',
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ── _FixtureList — date-grouped, sticky-header scrollable list ─────────────
//
// Premium redesign per the spec's reference:
//   • Matches sorted chronologically.
//   • Grouped by kickoff date — one section per day.
//   • Sticky date header ("Thursday, 11 June 2026") before each section.
//   • Each match card carries its tournament metadata (GROUP X • MATCH N)
//     at the very top in a small, tracking-spaced all-caps font.
//
// Match-number-per-group is computed from the FULL set so "Group A · Match 3"
// is deterministic across the season, not just relative to the current tab.

class _FixtureList extends StatelessWidget {
  const _FixtureList({
    required this.matches,
    required this.allMatches,
    required this.emptyText,
    required this.emptyEmoji,
  });

  final List<WcMatchModel> matches;
  /// The entire tournament's match list, used to derive a stable per-group
  /// match index that doesn't shift when tabs are switched.
  final List<WcMatchModel> allMatches;
  final String             emptyText;
  final String             emptyEmoji;

  @override
  Widget build(BuildContext context) {
    if (matches.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(emptyEmoji, style: const TextStyle(fontSize: 40)),
            const SizedBox(height: 12),
            Text(
              emptyText,
              style: const TextStyle(
                color:    Colors.white38,
                fontSize: 14,
              ),
            ),
          ],
        ),
      );
    }

    // ── 1. Stable per-group match number, computed from ALL matches ──────
    final indexByMatchId = _computeGroupMatchIndex(allMatches);

    // ── 2. Sort the tab's matches chronologically ─────────────────────────
    final sorted = [...matches]
      ..sort((a, b) => a.matchTime.compareTo(b.matchTime));

    // ── 3. Group by venue-local date (preserves day boundaries) ───────────
    final groups = <DateTime, List<WcMatchModel>>{};
    for (final m in sorted) {
      final local = m.matchTime.toLocal();
      final dayKey = DateTime(local.year, local.month, local.day);
      groups.putIfAbsent(dayKey, () => <WcMatchModel>[]).add(m);
    }
    final sortedDays = groups.keys.toList()..sort();

    // ── 4. Flatten groups → a single linear list of typed entries ────────
    //
    // Previous implementation used SliverPersistentHeader(pinned: true)
    // for every date header. Flutter's built-in sliver pins each header
    // INDEPENDENTLY — there's no built-in "only one pinned at a time"
    // behaviour — so every date header stacked on top of the previous
    // one as the user scrolled, eventually covering every match card.
    //
    // Switched to a flat ListView.builder over a typed `_FixtureEntry`
    // list. Date headers are now just inline rows that scroll naturally
    // with their match cards. As the user scrolls down, the previous
    // date header scrolls off-screen at the top and the next one comes
    // into view in its natural list position. No stacking, no pinned-
    // header arithmetic, no extra package.
    final entries = <_FixtureEntry>[];
    for (final day in sortedDays) {
      entries.add(_FixtureEntry.header(day));
      for (final m in groups[day]!) {
        entries.add(_FixtureEntry.match(m, indexByMatchId[m.id]));
      }
    }

    return ListView.builder(
      padding:   const EdgeInsets.only(bottom: 32),
      itemCount: entries.length,
      itemBuilder: (_, i) {
        final entry = entries[i];
        if (entry.isHeader) {
          return _DateHeaderRow(day: entry.day!);
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: _FixtureCard(
            match:           entry.match!,
            groupMatchIndex: entry.groupMatchIndex,
          ),
        );
      },
    );
  }

  /// Returns a map of match id → 1-based match number within that match's
  /// group (e.g. the 3rd Group-A match by kickoff = 3). Computed from the
  /// FULL [all] list so the number is stable across tab filters.
  static Map<String, int> _computeGroupMatchIndex(List<WcMatchModel> all) {
    final byGroup = <String, List<WcMatchModel>>{};
    for (final m in all) {
      final g = m.groupCode;
      if (g == null) continue;
      byGroup.putIfAbsent(g, () => <WcMatchModel>[]).add(m);
    }
    final result = <String, int>{};
    for (final entry in byGroup.entries) {
      final list = entry.value
        ..sort((a, b) => a.matchTime.compareTo(b.matchTime));
      for (var i = 0; i < list.length; i++) {
        result[list[i].id] = i + 1;
      }
    }
    return result;
  }
}

// ── _DateHeaderRow — inline "Thursday, 11 June 2026" section header ──
//
// Plain Padding+Text — no sliver, no pinning. Scrolls naturally with its
// match cards as a regular list item.

class _DateHeaderRow extends StatelessWidget {
  const _DateHeaderRow({required this.day});
  final DateTime day;

  static const _dayNames = [
    'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'
  ];
  static const _months = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December'
  ];

  @override
  Widget build(BuildContext context) {
    final label =
        '${_dayNames[day.weekday - 1]}, ${day.day} ${_months[day.month - 1]} ${day.year}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 10),
      child: Text(
        label,
        style: const TextStyle(
          color:         _kWhite,
          fontSize:      18,
          fontWeight:    FontWeight.w700,
          letterSpacing: -0.2,
        ),
      ),
    );
  }
}

// ── _FixtureEntry — discriminated row type for the flat ListView ─────────

class _FixtureEntry {
  const _FixtureEntry._({
    required this.isHeader,
    this.day,
    this.match,
    this.groupMatchIndex,
  });

  factory _FixtureEntry.header(DateTime day) =>
      _FixtureEntry._(isHeader: true, day: day);

  factory _FixtureEntry.match(WcMatchModel m, int? index) =>
      _FixtureEntry._(isHeader: false, match: m, groupMatchIndex: index);

  final bool          isHeader;
  final DateTime?     day;
  final WcMatchModel? match;
  final int?          groupMatchIndex;
}

// ── _FixtureCard — rich match card used in all three tabs ─────────────────

class _FixtureCard extends StatelessWidget {
  const _FixtureCard({
    required this.match,
    required this.groupMatchIndex,
  });

  final WcMatchModel match;
  /// 1-based index of this match within its group, computed across the
  /// full season. Used to render "GROUP A • MATCH 3". Null for knockouts
  /// (no group code) — in which case the stage label is rendered instead.
  final int?         groupMatchIndex;

  @override
  Widget build(BuildContext context) {
    final isBafana = match.isBafanaMatch;
    final now      = DateTime.now();
    // "Effectively live" — also true when the DB row is still 'scheduled'
    // but the kickoff has passed within the last 2h30. Covers TheSportsDB's
    // 5–15 min lag in flipping strStatus + the 15-min cron interval, so a
    // just-kicked-off match shows the LIVE badge + gold border immediately
    // instead of staying as a generic UPCOMING card for ~30 min.
    final freshKickoff = now.subtract(const Duration(hours: 2, minutes: 30));
    final isLive = match.isLive
        || (match.isUpcoming
            && match.matchTime.isBefore(now)
            && match.matchTime.isAfter(freshKickoff));
    // Mirrors `_FixtureSheet._effectivelyFinished` exactly — a match
    // counts as finished only when the row carries an explicit
    // `finished` status OR a non-zero scoreline has landed. Previously
    // this also flipped on past-kickoff alone, which produced the
    // split-state seen in 44939: the card painted FULL TIME 0-0 while
    // the bucketer kept the row in UPCOMING (because no real score had
    // arrived). The two now share one truth.
    final isFinishedEffective =
        match.isFinished || match.teamAScore != 0 || match.teamBScore != 0;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: isBafana
            ? _kGreenDeep.withAlpha(210)
            : _kDarkCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isLive
              ? Colors.redAccent.withAlpha(120)
              : isBafana
                  ? _kGold.withAlpha(100)
                  : _kDarkBorder,
          width: isLive ? 1.4 : 1.0,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [

          // ── 1. Status pill + GROUP X • MATCH N metadata + Bafana badge ──
          Row(
            children: [
              _StatusPill(
                match:               match,
                isBafana:            isBafana,
                isFinishedEffective: isFinishedEffective,
                isLiveEffective:     isLive && !match.isLive,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _metadataLabel(),
                  style: TextStyle(
                    color:         isBafana ? _kGold.withAlpha(220) : Colors.white54,
                    fontSize:      10.5,
                    fontWeight:    FontWeight.w800,
                    letterSpacing: 1.4,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (isBafana)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color:        _kGold.withAlpha(30),
                    borderRadius: BorderRadius.circular(6),
                    border:       Border.all(color: _kGold.withAlpha(80)),
                  ),
                  child: const Text(
                    '🇿🇦 BAFANA',
                    style: TextStyle(
                      color:      _kGold,
                      fontSize:   9,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
            ],
          ),

          const SizedBox(height: 14),

          // ── 2. Teams + score/VS row ─────────────────────────────────────
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Team A — flag + name with graceful auto-shrink
              Expanded(
                child: Row(
                  children: [
                    Text(match.teamAFlagEmoji,
                        style: const TextStyle(fontSize: 24)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FittedBox(
                        fit:       BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          match.teamA,
                          maxLines: 1,
                          style: const TextStyle(
                            color:      _kWhite,
                            fontWeight: FontWeight.w600,
                            fontSize:   14,
                            letterSpacing: -0.1,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // Centre column — score for live/finished, time for upcoming.
              // Time uses tabular figures via `fontFeatures` so the digits
              // line up like a scoreboard across cards.
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: isLive || isFinishedEffective
                    ? Text(
                        '${match.teamAScore}  –  ${match.teamBScore}',
                        style: TextStyle(
                          color:      isLive ? Colors.white : Colors.white70,
                          fontWeight: FontWeight.w900,
                          fontSize:   20,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      )
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'VS',
                            style: TextStyle(
                              color:      isBafana
                                  ? _kGold
                                  : Colors.white38,
                              fontWeight: FontWeight.w900,
                              fontSize:   13,
                              letterSpacing: 1.2,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _kickoffTimeOnly,
                            style: const TextStyle(
                              color:        _kWhite,
                              fontWeight:   FontWeight.w800,
                              fontSize:     15,
                              letterSpacing: 0.4,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
              ),

              // Team B — name + flag
              Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Expanded(
                      child: FittedBox(
                        fit:       BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: Text(
                          match.teamB,
                          maxLines: 1,
                          textAlign: TextAlign.end,
                          style: const TextStyle(
                            color:      _kWhite,
                            fontWeight: FontWeight.w600,
                            fontSize:   14,
                            letterSpacing: -0.1,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(match.teamBFlagEmoji,
                        style: const TextStyle(fontSize: 24)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// "GROUP A • MATCH 3" for group-stage rows, falls back to the stage
  /// label ("ROUND OF 16", "QUARTER-FINAL") for knockouts where there's no
  /// group code to anchor the index against.
  String _metadataLabel() {
    final group = match.groupCode;
    if (group != null && groupMatchIndex != null) {
      return 'GROUP $group  •  MATCH $groupMatchIndex';
    }
    return match.stage.toUpperCase();
  }

  /// HH:mm SAST — South African Standard Time (UTC+2, no DST). The
  /// surrounding sticky date header already carries the full day context,
  /// so we keep the per-card label compact.
  String get _kickoffTimeOnly {
    final sast = match.matchTime.toUtc().add(const Duration(hours: 2));
    final hh = sast.hour.toString().padLeft(2, '0');
    final mm = sast.minute.toString().padLeft(2, '0');
    return '$hh:$mm SAST';
  }
}

// ── _StatusPill — coloured status badge per match state ────────────────────

class _StatusPill extends StatelessWidget {
  const _StatusPill({
    required this.match,
    required this.isBafana,
    this.isFinishedEffective = false,
    this.isLiveEffective     = false,
  });
  final WcMatchModel match;
  final bool         isBafana;
  /// Set by the parent card when the kickoff is in the past — forces the
  /// "FULL TIME" rendering even if the DB still says `status='scheduled'`.
  final bool         isFinishedEffective;
  /// Set by the parent card when kickoff has just passed but the DB row
  /// still says `status='scheduled'` (TheSportsDB lag + 15-min cron gap).
  /// Forces the LIVE pill so the user sees a real-time live indicator
  /// instead of UPCOMING for half an hour after a real kickoff.
  final bool         isLiveEffective;

  @override
  Widget build(BuildContext context) {
    if (match.isLive || isLiveEffective) {
      final now = DateTime.now();
      final elapsed = match.isLive
          ? match.liveMinute
          : now.difference(match.matchTime).inMinutes.clamp(1, 120);
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7, height: 7,
            decoration: const BoxDecoration(
              color: Colors.redAccent, shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 5),
          Text(
            "LIVE  $elapsed'",
            style: const TextStyle(
              color:      Colors.redAccent,
              fontWeight: FontWeight.w800,
              fontSize:   10.5,
            ),
          ),
        ],
      );
    }
    if (match.isFinished || isFinishedEffective) {
      return const Text(
        'FULL TIME',
        style: TextStyle(
          color:      Colors.white38,
          fontWeight: FontWeight.w700,
          fontSize:   10.5,
        ),
      );
    }
    // Scheduled
    return Text(
      'UPCOMING',
      style: TextStyle(
        color:      isBafana ? _kGold : Colors.blueAccent.shade100,
        fontWeight: FontWeight.w700,
        fontSize:   10.5,
      ),
    );
  }
}

// =============================================================================
//   _StadiumChatBody — realtime banter chat
// =============================================================================

class _StadiumChatBody extends StatefulWidget {
  const _StadiumChatBody({
    required this.channelId,
    required this.isBafana,
  });

  final String channelId;
  final bool   isBafana;

  @override
  State<_StadiumChatBody> createState() => _StadiumChatBodyState();
}

/// Per-bubble target for the floating reaction strip + action menu.
/// Mirrors `_BraaiReactionTarget` / `_ReactionTarget` in the other
/// chat surfaces so soccer banter gets the same long-press UX.
class _StadiumReactionTarget {
  const _StadiumReactionTarget({required this.message, required this.rect});
  final ChannelMessage message;
  final Rect           rect;
}

class _StadiumChatBodyState extends State<_StadiumChatBody> {
  final _composerCtrl  = TextEditingController();
  final _scrollCtrl    = ScrollController();

  /// One GlobalKey per visible message so we can read its render rect off
  /// the chosen tile when long-pressed, and hand that rect to
  /// ChatReactionOverlay so the emoji strip + action menu can anchor
  /// relative to the bubble.
  final Map<String, GlobalKey>    _bubbleKeys     = {};
  final OverlayPortalController   _reactionPortal = OverlayPortalController();
  _StadiumReactionTarget?         _reactionTarget;

  Map<String, ChannelMessage> _seedMessages = {};
  bool _seeded = false;
  // Ids ever observed in the live realtime snapshot. Once a row has been
  // seen live, it must remain live — if it disappears from the snapshot
  // it has been DELETED upstream, and we must not re-surface it from the
  // stale `_seedMessages` cache. Without this set, another user's delete
  // would only clear the row for the deleter, not for everyone else.
  final Set<String> _seenLiveIds = <String>{};

  final Set<String>         _deletedIds  = {};
  final Map<String, String> _editedTexts = {};

  /// userId → handle cache. Hydrated from the seed (which carries the
  /// profiles join) and topped up by [_hydrateHandlesFor] whenever a
  /// realtime row arrives from a sender we haven't seen yet — realtime
  /// payloads can't join the profiles table, so we fetch on demand.
  final Map<String, String> _handleByUserId = {};
  final Set<String>         _handleFetchInFlight = {};

  XFile? _draftImage;
  bool   _uploadingImage = false;

  @override
  void initState() {
    super.initState();
    _loadSeed();
  }

  @override
  void dispose() {
    _composerCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadSeed() async {
    try {
      final list = await CommunityHubService.instance
          .fetchMessages(widget.channelId);
      if (!mounted) return;
      setState(() {
        _seedMessages = {for (final m in list) m.id: m};
        _seeded       = true;
        // Prime the userId → handle cache from the joined seed rows so
        // re-seen senders render instantly on the next stream tick.
        for (final m in list) {
          final uid = m.userId;
          final h   = m.authorHandle;
          if (uid != null && h != null && h.isNotEmpty) {
            _handleByUserId[uid] = h;
          }
        }
      });
    } catch (e) {
      debugPrint('StadiumChat: seed load failed: $e');
      if (mounted) setState(() => _seeded = true);
    }
  }

  /// One-shot fetch of `profiles.handle / username` for any sender we don't
  /// already have cached. Called when realtime emits a row from an unknown
  /// userId — fills `_handleByUserId` and triggers a rebuild so the bubble
  /// swaps `@fan` for the real handle the moment the round-trip returns.
  Future<void> _hydrateHandlesFor(Iterable<String> userIds) async {
    final missing = userIds
        .where((id) => !_handleByUserId.containsKey(id))
        .where((id) => !_handleFetchInFlight.contains(id))
        .toSet();
    if (missing.isEmpty) return;
    _handleFetchInFlight.addAll(missing);
    try {
      final rows = await Supabase.instance.client
          .from('profiles')
          .select('id, handle, username')
          .inFilter('id', missing.toList());
      if (!mounted) return;
      setState(() {
        for (final r in (rows as List).cast<Map<String, dynamic>>()) {
          final id = r['id'] as String?;
          final h  = (r['handle']   as String?)?.trim().isNotEmpty == true
                       ? r['handle']   as String
                       : (r['username'] as String?);
          if (id != null && h != null && h.isNotEmpty) {
            _handleByUserId[id] = h;
          }
        }
      });
    } catch (e) {
      debugPrint('StadiumChat: profile hydrate failed: $e');
    } finally {
      _handleFetchInFlight.removeAll(missing);
    }
  }

  void _scrollToBottom() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollCtrl.hasClients) return;
      final pos = _scrollCtrl.position;
      if (pos.maxScrollExtent - pos.pixels < 300) {
        _scrollCtrl.animateTo(
          pos.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve:    Curves.easeOut,
        );
      }
    });
  }

  Future<void> _send() async {
    final text  = _composerCtrl.text.trim();
    final image = _draftImage;
    if (text.isEmpty && image == null) return;

    final messenger = ScaffoldMessenger.of(context);
    _composerCtrl.clear();
    setState(() {
      _draftImage     = null;
      if (image != null) _uploadingImage = true;
    });

    try {
      String? imageUrl;
      if (image != null) {
        final bytes = await image.readAsBytes();
        imageUrl = await CommunityHubService.instance.uploadWhatsCookingImage(
          bytes, filename: image.name, contentType: image.mimeType,
        );
      }
      await CommunityHubService.instance.postMessage(
        channelId: widget.channelId,
        text:      text.isEmpty ? '📷' : text,
        imageUrl:  imageUrl,
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(
        content:  Text('Could not send: $e'),
        behavior: SnackBarBehavior.floating,
      ));
    } finally {
      if (mounted) setState(() => _uploadingImage = false);
    }
  }

  // ── Reaction overlay wiring ─────────────────────────────────────────
  //
  // Long-press on ANY bubble (own OR someone else's) opens the same
  // floating ChatReactionOverlay that the 5 Community Hub categories
  // (Spotted, Gatherings, Pantry, What's Cooking, Braai) use: emoji
  // reaction strip on top + action sheet (Copy / Delete-own / Report /
  // Block) below. Keeps the long-press UX identical across every chat
  // surface in the app.

  void _openReactionMenu(ChannelMessage msg) {
    final key = _bubbleKeys[msg.id];
    final ctx = key?.currentContext;
    if (ctx == null) return;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return;
    final origin = box.localToGlobal(Offset.zero);
    setState(() {
      _reactionTarget = _StadiumReactionTarget(
        message: msg,
        rect:    origin & box.size,
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
    await SocialService().toggleChannelMessageReaction(msg.id, emoji);
  }

  void _dispatchReactionMenuAction(String action) {
    final target = _reactionTarget;
    if (target == null) return;
    final msg = target.message;
    _closeReactionMenu();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      switch (action) {
        case 'copy':
          await _copyMessageText(msg);
        case 'delete':
          await _performDeleteOwnMessage(msg);
        case 'report':
          await _reportMessage(msg);
        case 'block':
          await _blockMessageAuthor(msg);
      }
    });
  }

  Future<void> _copyMessageText(ChannelMessage msg) async {
    await Clipboard.setData(ClipboardData(text: msg.messageText));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content:  Text('Copied to clipboard.'),
      behavior: SnackBarBehavior.floating,
    ));
  }

  Future<void> _reportMessage(ChannelMessage msg) async {
    try {
      await ModerationService.instance.reportChannelMessage(msg.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content:  Text('Message reported — our team will review it.'),
        behavior: SnackBarBehavior.floating,
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content:  Text('Could not report: $e'),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  Future<void> _blockMessageAuthor(ChannelMessage msg) async {
    final uid = msg.userId;
    if (uid == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title:   const Text('Block user?'),
        content: const Text(
          "You won't see this user's messages or posts anywhere in ChowSA. "
          'You can undo this from Settings → Privacy → Blocked users.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child:     const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style:     TextButton.styleFrom(foregroundColor: Colors.red),
            child:     const Text('Block'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ModerationService.instance.blockUser(uid);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content:  Text('User blocked.'),
        behavior: SnackBarBehavior.floating,
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content:  Text('Could not block: $e'),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  // ── Own-message deletion ─────────────────────────────────────────────────
  //
  // Two paths reach the delete:
  //   • Overlay action (Delete from the long-press menu) — the overlay's
  //     "Delete message · This cannot be undone." copy is itself the
  //     confirmation, so we go straight to _performDeleteOwnMessage.
  //   • Swipe-to-dismiss (own messages only) — goes through the legacy
  //     _showDeleteConfirmSheet for the swipe gesture.

  /// Pops a "Delete Message / Cancel" action sheet and returns the user's
  /// choice. Used by BOTH the long-press menu and the swipe gesture.
  Future<bool?> _showDeleteConfirmSheet() async {
    return showModalBottomSheet<bool>(
      context:         context,
      backgroundColor: _kDarkCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color:        Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded,
                  color: Colors.redAccent),
              title:   const Text(
                'Delete Message',
                style: TextStyle(
                  color:      Colors.redAccent,
                  fontWeight: FontWeight.w800,
                ),
              ),
              onTap: () => Navigator.pop(ctx, true),
            ),
            ListTile(
              leading: const Icon(Icons.close_rounded, color: Colors.white54),
              title:   const Text('Cancel',
                  style: TextStyle(color: Colors.white70)),
              onTap: () => Navigator.pop(ctx, false),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// Optimistically removes [msg] from the visible list (via [_deletedIds],
  /// which the StreamBuilder merge filters by) and fires the Supabase
  /// delete. Rolls back the optimistic state on failure. Used by both
  /// long-press → action sheet AND swipe-to-delete.
  Future<void> _performDeleteOwnMessage(ChannelMessage msg) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _deletedIds.add(msg.id));
    try {
      await CommunityHubService.instance.deleteChannelMessage(msg);
    } catch (e) {
      if (mounted) setState(() => _deletedIds.remove(msg.id));
      messenger.showSnackBar(SnackBar(
        content:  Text('Could not delete: $e'),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  Future<void> _pickImage() async {
    final source = await showModalBottomSheet<ImageSource>(
      context:         context,
      backgroundColor: _kDarkCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Text('📷', style: TextStyle(fontSize: 22)),
              title: const Text('Take a photo',
                  style: TextStyle(color: _kWhite)),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Text('🖼️', style: TextStyle(fontSize: 22)),
              title: const Text('Choose from gallery',
                  style: TextStyle(color: _kWhite)),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;
    final picked = await ImagePicker().pickImage(
      source: source, imageQuality: 80, maxWidth: 1920,
    );
    if (picked != null && mounted) setState(() => _draftImage = picked);
  }

  @override
  Widget build(BuildContext context) {
    // Wrap the entire chat body in an OverlayPortal so the floating
    // ChatReactionOverlay (emoji strip + action sheet) paints above the
    // chat AND the composer when a long-press fires. Identical pattern
    // to channel_chat_screen.dart and local_braai_hub_view.dart.
    return OverlayPortal(
      controller: _reactionPortal,
      overlayChildBuilder: (_) {
        final target = _reactionTarget;
        if (target == null) return const SizedBox.shrink();
        final me   = Supabase.instance.client.auth.currentUser?.id;
        final mine = me != null && target.message.userId == me;
        return ChatReactionOverlay(
          bubbleRect:  target.rect,
          onReact:     (e) => _applyReaction(target.message, e),
          onAction:    _dispatchReactionMenuAction,
          onDismiss:   _closeReactionMenu,
          canEdit:     false,
          canDelete:   mine,
          canPin:      false,
          // Report + Block surface only on OTHER users' messages —
          // matches Play UGC policy + the 5 community categories.
          canModerate: !mine,
          isPinned:    false,
        );
      },
      child: Column(
      children: [

        // ── Section label ─────────────────────────────────────────────────
        Container(
          color:   _kDarkBg,
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: widget.isBafana
                      ? _kGold.withAlpha(25)
                      : Colors.white10,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: widget.isBafana
                        ? _kGold.withAlpha(80)
                        : Colors.white24,
                  ),
                ),
                child: Text(
                  '⚡  LIVE BANTER',
                  style: TextStyle(
                    color:         widget.isBafana ? _kGold : Colors.white70,
                    fontSize:      11,
                    fontWeight:    FontWeight.w900,
                    letterSpacing: 1.0,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Drop your takes here…',
                  style: TextStyle(color: Colors.white38, fontSize: 12),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),

        // ── Message list ──────────────────────────────────────────────────
        Expanded(
          child: StreamBuilder<List<ChannelMessage>>(
            stream: CommunityHubService.instance
                .watchMessages(widget.channelId),
            builder: (context, snap) {
              // Show loading spinner only when no seed data AND stream not yet
              // delivered — avoids the spinner locking if the stream is slow.
              if (!_seeded && !snap.hasData) {
                return const Center(
                  child: CircularProgressIndicator(color: _kGold),
                );
              }

              final liveById = {
                for (final m in (snap.data ?? <ChannelMessage>[]))
                  m.id: m,
              };
              // Track every id the live stream has ever delivered. Any
              // seed-only row whose id later appeared live and then
              // vanished is a DELETED row and must NOT be re-surfaced.
              _seenLiveIds.addAll(liveById.keys);

              // Merge seed (which has author handles from the join) with the
              // live stream (which doesn't join profiles). For rows whose
              // handle isn't in the seed, fall back to the userId → handle
              // cache and schedule a background fetch for anything still
              // unknown so the bubble updates the moment the profile lands.
              final missingHandleUserIds = <String>[];
              final merged = <ChannelMessage>[
                ..._seedMessages.values.where((m) =>
                    !liveById.containsKey(m.id) &&
                    !_seenLiveIds.contains(m.id)),
                ...liveById.values.map((m) {
                  final seed   = _seedMessages[m.id];
                  final cached = m.userId != null
                      ? _handleByUserId[m.userId!]
                      : null;
                  final resolvedHandle = seed?.authorHandle ?? cached;
                  if (resolvedHandle == null && m.userId != null) {
                    missingHandleUserIds.add(m.userId!);
                  }
                  if (resolvedHandle != null) {
                    return ChannelMessage(
                      id:             m.id,
                      channelId:      m.channelId,
                      userId:         m.userId,
                      messageText:    m.messageText,
                      eventTimestamp: m.eventTimestamp,
                      createdAt:      m.createdAt,
                      authorHandle:   resolvedHandle,
                      imageUrl:       m.imageUrl,
                    );
                  }
                  return m;
                }),
              ]..sort((a, b) => a.createdAt.compareTo(b.createdAt));

              if (missingHandleUserIds.isNotEmpty) {
                // Schedule outside the build phase so we don't setState during
                // a build (the fetch itself calls setState on completion).
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _hydrateHandlesFor(missingHandleUserIds);
                });
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
                      imageUrl:       m.imageUrl,
                    );
                  })
                  .toList(growable: false);

              if (visible.isEmpty) {
                return _EmptyBanter(isBafana: widget.isBafana);
              }

              _scrollToBottom();
              final me = Supabase.instance.client.auth.currentUser;

              return ListView.separated(
                controller:      _scrollCtrl,
                padding:         const EdgeInsets.fromLTRB(12, 8, 12, 8),
                itemCount:       visible.length,
                separatorBuilder: (_, __) => const SizedBox(height: 4),
                itemBuilder:     (_, i) {
                  final m    = visible[i];
                  final isMe = me != null && m.userId == me.id;
                  final bubbleKey =
                      _bubbleKeys.putIfAbsent(m.id, () => GlobalKey());
                  // Long-press wired on every bubble (own AND others'). The
                  // overlay action sheet gates Delete behind ownership and
                  // Report/Block behind not-ownership, so the gesture is
                  // safe to expose universally.
                  Widget bubble = _BanterBubble(
                    message:    m,
                    isMe:       isMe,
                    isBafana:   widget.isBafana,
                    bubbleKey:  bubbleKey,
                    onLongPress: () => _openReactionMenu(m),
                  );
                  if (!isMe) return bubble;

                  // Swipe-to-delete for own messages.
                  //   • Left-only swipe (DismissDirection.endToStart).
                  //   • Red background with a centred-right white delete icon.
                  //   • confirmDismiss pops the same action sheet the long
                  //     press uses, so the user always gets one chance to
                  //     back out.
                  //   • onDismissed re-checks ownership defensively before
                  //     firing the Supabase delete — the Dismissible itself
                  //     is already gated by `isMe`, but a belt-and-braces
                  //     ownership check inside the callback is cheap
                  //     insurance against any future refactor that
                  //     accidentally surfaces the gesture to non-owners.
                  return Dismissible(
                    key:       ValueKey('banter_${m.id}'),
                    direction: DismissDirection.endToStart,
                    background: Container(
                      margin: const EdgeInsets.symmetric(vertical: 2),
                      padding: const EdgeInsets.only(right: 20),
                      decoration: BoxDecoration(
                        color:        Colors.red.shade700,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      alignment: Alignment.centerRight,
                      child: const Icon(Icons.delete,
                          color: Colors.white, size: 24),
                    ),
                    confirmDismiss: (_) async {
                      final confirmed = await _showDeleteConfirmSheet();
                      return confirmed == true;
                    },
                    onDismissed: (_) {
                      final currentUserId =
                          Supabase.instance.client.auth.currentUser?.id;
                      if (currentUserId == null ||
                          m.userId != currentUserId) {
                        return;
                      }
                      _performDeleteOwnMessage(m);
                    },
                    child: bubble,
                  );
                },
              );
            },
          ),
        ),

        // ── Composer ─────────────────────────────────────────────────────
        _StadiumComposer(
          controller:    _composerCtrl,
          draftImage:    _draftImage,
          uploading:     _uploadingImage,
          isBafana:      widget.isBafana,
          onAttachImage: _pickImage,
          onClearImage:  () => setState(() => _draftImage = null),
          onSend:        _send,
        ),
      ],
      ),
    );
  }
}

// =============================================================================
//   _BanterBubble
// =============================================================================

class _BanterBubble extends StatelessWidget {
  const _BanterBubble({
    required this.message,
    required this.isMe,
    required this.isBafana,
    this.bubbleKey,
    this.onLongPress,
  });

  final ChannelMessage message;
  final bool           isMe;
  final bool           isBafana;

  /// GlobalKey assigned to the inner bubble container so the chat body
  /// can read its render rect when surfacing the floating reaction
  /// overlay. Optional — falls through to no key if omitted.
  final GlobalKey?     bubbleKey;

  /// Long-press handler — when provided, the bubble container forwards
  /// the gesture to the floating ChatReactionOverlay (emoji strip +
  /// action menu). Wired on every bubble (own AND others') so the
  /// long-press UX matches the 5 Community Hub categories.
  final VoidCallback?  onLongPress;

  @override
  Widget build(BuildContext context) {
    // Resolve the sender handle exactly the same way every other
    // community chat surface does: prefer the joined profile handle on
    // the message, fall back to "chommie" while the parent's
    // userId→handle hydrate is still in flight. Never render the raw
    // 'fan' placeholder, and never render the generic "You" — the
    // user's own handle is just as much an identity as everyone
    // else's, and showing it keeps the column visually consistent.
    final rawHandle = message.authorHandle?.trim();
    final handle    = (rawHandle == null || rawHandle.isEmpty)
        ? 'chommie'
        : rawHandle;
    final hh = message.createdAt.toLocal().hour.toString().padLeft(2, '0');
    final mm = message.createdAt.toLocal().minute.toString().padLeft(2, '0');

    final bubbleBg = isMe
        ? (isBafana ? _kGreenDeep : const Color(0xFF1E3A5F))
        : _kDarkCard;
    final bubbleBorder = isMe
        ? (isBafana ? _kGold.withAlpha(100) : Colors.blueAccent.withAlpha(80))
        : _kDarkBorder;

    final handleColor = isBafana ? _kGold : Colors.blueAccent.shade100;

    return Column(
      crossAxisAlignment:
          isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        // ── Author handle — sits ABOVE the bubble, aligned right for own
        // messages and left for everyone else's. Always rendered so every
        // bubble carries its sender, including own messages.
        Padding(
          padding: EdgeInsets.fromLTRB(
            isMe ? 0 : 10, 4, isMe ? 10 : 0, 2,
          ),
          child: Text(
            '@$handle',
            style: TextStyle(
              color:      handleColor,
              fontSize:   11.5,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.2,
            ),
          ),
        ),
        Align(
          alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
          child: GestureDetector(
            // Long-press on EVERY bubble surfaces the floating
            // ChatReactionOverlay (emoji strip + action menu). The
            // overlay itself gates Delete behind ownership and
            // Report/Block behind not-ownership.
            behavior:    HitTestBehavior.opaque,
            onLongPress: onLongPress,
            child: Container(
            key: bubbleKey,
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.78,
            ),
            margin:  const EdgeInsets.symmetric(vertical: 2),
            padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
            decoration: BoxDecoration(
              color:        bubbleBg,
              borderRadius: BorderRadius.only(
                topLeft:     const Radius.circular(14),
                topRight:    const Radius.circular(14),
                bottomLeft:  Radius.circular(isMe ? 14 : 4),
                bottomRight: Radius.circular(isMe ? 4  : 14),
              ),
              border: Border.all(color: bubbleBorder, width: 1),
            ),
            child: Column(
              crossAxisAlignment:
                  isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                Text(
                  '$hh:$mm',
                  style: const TextStyle(
                    color:    Colors.white38,
                    fontSize: 9.5,
                  ),
                ),
            if (message.hasImage) ...[
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(
                  message.imageUrl!,
                  width:        220,
                  fit:          BoxFit.cover,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
            ],
            if (!(message.hasImage && message.messageText.trim() == '📷')) ...[
              const SizedBox(height: 3),
              Text(
                message.messageText,
                style: const TextStyle(
                  color:    _kWhite,
                  fontSize: 13.5,
                  height:   1.35,
                ),
              ),
            ],
          ],
        ),
      ),
      ),
    ),
      ],
    );
  }
}

// =============================================================================
//   _StadiumComposer
// =============================================================================

class _StadiumComposer extends StatelessWidget {
  const _StadiumComposer({
    required this.controller,
    required this.draftImage,
    required this.uploading,
    required this.isBafana,
    required this.onAttachImage,
    required this.onClearImage,
    required this.onSend,
  });

  final TextEditingController controller;
  final XFile?                draftImage;
  final bool                  uploading;
  final bool                  isBafana;
  final VoidCallback          onAttachImage;
  final VoidCallback          onClearImage;
  final VoidCallback          onSend;

  @override
  Widget build(BuildContext context) {
    final sendColor = isBafana ? _kGold : Colors.blueAccent;

    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
        decoration: const BoxDecoration(
          color: _kDarkCard,
          border: Border(
            top: BorderSide(color: Colors.white12, width: 0.6),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (draftImage != null) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 8, left: 4),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.file(
                        File(draftImage!.path),
                        width: 52, height: 52, fit: BoxFit.cover,
                      ),
                    ),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'Photo ready',
                        style: TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                    ),
                    if (!uploading)
                      InkWell(
                        onTap: onClearImage,
                        child: const Padding(
                          padding: EdgeInsets.all(4),
                          child: Icon(Icons.close_rounded,
                              color: Colors.white38, size: 16),
                        ),
                      ),
                  ],
                ),
              ),
            ],
            Row(
              children: [
                IconButton(
                  icon: Icon(
                    draftImage == null
                        ? Icons.add_photo_alternate_outlined
                        : Icons.photo_rounded,
                    color: draftImage == null ? Colors.white38 : sendColor,
                    size: 22,
                  ),
                  onPressed: uploading ? null : onAttachImage,
                ),
                Expanded(
                  child: TextField(
                    controller:      controller,
                    minLines:        1,
                    maxLines:        4,
                    style: const TextStyle(color: _kWhite, fontSize: 14),
                    textInputAction: TextInputAction.send,
                    onSubmitted:     (_) => onSend(),
                    decoration: InputDecoration(
                      hintText:  'Drop your takes here… ⚽',
                      hintStyle: const TextStyle(
                          color: Colors.white38, fontSize: 13),
                      filled:     true,
                      fillColor:  Colors.white.withAlpha(8),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(22),
                        borderSide:   BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                PressableScale(
                  onTap: uploading ? null : onSend,
                  child: Container(
                    padding: const EdgeInsets.all(11),
                    decoration: BoxDecoration(
                      color: sendColor, shape: BoxShape.circle,
                    ),
                    child: uploading
                        ? SizedBox(
                            width: 18, height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color:       isBafana
                                  ? Colors.black87
                                  : Colors.white,
                            ),
                          )
                        : Icon(
                            Icons.send_rounded,
                            color: isBafana ? Colors.black87 : _kWhite,
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
//   _EmptyBanter
// =============================================================================

class _EmptyBanter extends StatelessWidget {
  const _EmptyBanter({required this.isBafana});
  final bool isBafana;

  @override
  Widget build(BuildContext context) {
    // LayoutBuilder + SingleChildScrollView + ConstrainedBox is the canonical
    // "centered when there's room, scrollable when there isn't" recipe:
    //   • When the parent Expanded gives us plenty of height (no keyboard),
    //     the ConstrainedBox forces a min-height equal to the viewport, so
    //     Center positions the column in the middle as before.
    //   • When the keyboard opens and the Expanded's height drops below the
    //     content's intrinsic height, the SingleChildScrollView lets the
    //     fixed-size emoji + text scroll gracefully instead of throwing the
    //     yellow-and-black "Bottom overflowed by N pixels" stripe.
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          // BouncingScrollPhysics so the user only sees the scroll affordance
          // if they actively drag — when there's room the content sits dead
          // centre and looks like a plain placeholder.
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: constraints.maxHeight,
            ),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      isBafana ? '🇿🇦' : '⚽',
                      style: const TextStyle(fontSize: 52),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      isBafana
                          ? 'Be the first to hype up Bafana!'
                          : 'Be the first to drop a take!',
                      style: const TextStyle(
                        color:      Colors.white54,
                        fontSize:   15,
                        fontWeight: FontWeight.w700,
                      ),
                      textAlign: TextAlign.center,
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
//   _ChatResolving — shown only while channel ID is still being looked up
// =============================================================================

class _ChatResolving extends StatelessWidget {
  const _ChatResolving();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 28, height: 28,
            child: CircularProgressIndicator(
              color:       _kGold,
              strokeWidth: 2.5,
            ),
          ),
          SizedBox(height: 14),
          Text(
            'Connecting to stadium…',
            style: TextStyle(
              color:      Colors.white38,
              fontSize:   13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
//   _ChatUnavailable — shown when the 3-second resolver budget elapses
// =============================================================================
//
// Replaces the infinite spinner once the timeout fires AND the retry also
// fails to resolve a channel. Gives the user something actionable (Try
// again) instead of a stuck loading state.

class _ChatUnavailable extends StatelessWidget {
  const _ChatUnavailable({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cell_tower_rounded,
                color: _kGold, size: 36),
            const SizedBox(height: 12),
            const Text(
              'Stadium chat is offline',
              textAlign: TextAlign.center,
              style: TextStyle(
                color:      _kWhite,
                fontSize:   16,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.2,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              "We couldn't reach the live banter room. Check your "
              'connection and try again.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color:    Colors.white54,
                fontSize: 13,
                height:   1.35,
              ),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: onRetry,
              icon:  const Icon(Icons.refresh_rounded, size: 18),
              label: const Text(
                'Try again',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: _kGold,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(
                    horizontal: 22, vertical: 12),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
