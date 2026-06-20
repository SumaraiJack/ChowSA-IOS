// lib/widgets/world_cup_ticker.dart
//
// Dashboard ticker widget for the World Cup feature.
//
// Renders with green/gold Bafana overrides when is_bafana_match is true.
// Displays a pulsing LIVE dot when status == 'live'.
// Shows a countdown when status == 'scheduled'.
// Displays the final score when status == 'finished'.
//
// Built from the blueprint provided in the spec, extended with:
//   • AnimatedContainer for the Bafana colour transition
//   • A live-minute pulse animation (red dot blink)
//   • Countdown string formatted from matchTime

import 'dart:async';
import 'package:flutter/material.dart';
import '../models/wc_match_model.dart';

// ── Design tokens (self-contained — no dependency on app_theme.dart) ─────────
const _kGoldBafana    = Color(0xFFD4A017);   // SA gold
const _kGreenBafana   = Color(0xFF004D25);   // SA deep green
const _kWhite         = Colors.white;

class WorldCupTicker extends StatefulWidget {
  const WorldCupTicker({
    super.key,
    required this.match,
    required this.onTap,
  });

  final WcMatchModel match;
  final VoidCallback onTap;

  @override
  State<WorldCupTicker> createState() => _WorldCupTickerState();
}

class _WorldCupTickerState extends State<WorldCupTicker>
    with SingleTickerProviderStateMixin {

  // Live dot blink controller (only active when status == 'live')
  late final AnimationController _blink;
  late final Animation<double>    _blinkAnim;

  // Countdown timer — refreshes the "in Xh Xm" label every minute
  Timer? _countdownTimer;
  Duration _timeUntil = Duration.zero;

  @override
  void initState() {
    super.initState();
    _blink = AnimationController(
      vsync:    this,
      duration: const Duration(milliseconds: 900),
    );
    _blinkAnim = CurvedAnimation(parent: _blink, curve: Curves.easeInOut);

    if (widget.match.isLive) {
      _blink.repeat(reverse: true);
    }
    if (widget.match.isUpcoming) {
      _updateCountdown();
      _countdownTimer = Timer.periodic(
        const Duration(minutes: 1),
        (_) { if (mounted) setState(_updateCountdown); },
      );
    }
  }

  @override
  void didUpdateWidget(WorldCupTicker old) {
    super.didUpdateWidget(old);
    if (widget.match.isLive && !_blink.isAnimating) {
      _blink.repeat(reverse: true);
    } else if (!widget.match.isLive && _blink.isAnimating) {
      _blink.stop();
    }
  }

  @override
  void dispose() {
    _blink.dispose();
    _countdownTimer?.cancel();
    super.dispose();
  }

  void _updateCountdown() {
    _timeUntil = widget.match.matchTime.difference(DateTime.now());
  }

  String get _countdownLabel {
    if (_timeUntil.isNegative) return 'Starting soon';
    final h = _timeUntil.inHours;
    final m = _timeUntil.inMinutes.remainder(60);
    if (h > 48) return 'In ${_timeUntil.inDays}d';
    if (h > 0)  return 'In ${h}h ${m}m';
    return m > 0 ? 'In ${m}m' : 'Starting soon';
  }

  @override
  Widget build(BuildContext context) {
    final m        = widget.match;
    final isBafana = m.isBafanaMatch;

    // Visual container is ALWAYS the SA green/gold treatment so every
    // upcoming-match card on the home dashboard reads as "Mzansi pride".
    // The label text (BAFANA UPCOMING 🔥 vs UPCOMING MATCH) and the
    // MZANSI HYPE badge stay conditional on isBafana below.

    return GestureDetector(
      onTap: widget.onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 350),
        curve:    Curves.easeOut,
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          color:        _kGreenBafana,
          borderRadius: BorderRadius.circular(16),
          border:       Border.all(color: _kGoldBafana, width: 1.8),
          boxShadow: [
            BoxShadow(
              color:      _kGoldBafana.withAlpha(60),
              blurRadius: 12,
              offset:     const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [

            // ── Top row: status label + Bafana badge ─────────────────────
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _StatusLabel(match: m, blinkAnim: _blinkAnim,
                    isBafana: isBafana),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isBafana)
                      _BafanaBadge(label: 'MZANSI HYPE'),
                    const SizedBox(width: 6),
                    const Icon(
                      Icons.chevron_right_rounded,
                      color: Colors.white54,
                      size:  18,
                    ),
                  ],
                ),
              ],
            ),

            const SizedBox(height: 10),

            // ── Score / fixture row ───────────────────────────────────────
            //
            // Layout: [flag · name] — [VS / score / countdown] — [name · flag]
            // Each side is wrapped in Expanded with FittedBox(scaleDown) so
            // long names ("Bosnia and Herzegovina", "Korea Republic") shrink
            // their font size gracefully instead of getting ellipsised. The
            // centre block sits in its own Padding wrapper so VS / countdown
            // stay vertically centred and don't push into the team names.
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Team A — flag + name
                Expanded(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.start,
                    children: [
                      Text(
                        m.teamAFlagEmoji,
                        style: const TextStyle(fontSize: 26),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FittedBox(
                          fit:       BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Text(
                            m.teamA,
                            maxLines: 1,
                            style: const TextStyle(
                              color:      _kWhite,
                              fontWeight: FontWeight.w800,
                              fontSize:   15,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // Centre: score / VS / countdown — vertically centred
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: _CentreBlock(
                    match:          m,
                    isBafana:       isBafana,
                    countdownLabel: _countdownLabel,
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
                            m.teamB,
                            maxLines:  1,
                            textAlign: TextAlign.end,
                            style: const TextStyle(
                              color:      _kWhite,
                              fontWeight: FontWeight.w800,
                              fontSize:   15,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        m.teamBFlagEmoji,
                        style: const TextStyle(fontSize: 26),
                      ),
                    ],
                  ),
                ),
              ],
            ),

            // ── Stage label ───────────────────────────────────────────────
            const SizedBox(height: 6),
            Text(
              m.stage.toUpperCase(),
              style: const TextStyle(
                color:         Colors.white38,
                fontSize:      9.5,
                fontWeight:    FontWeight.w700,
                letterSpacing: 1.2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
//   Sub-widgets
// =============================================================================

class _StatusLabel extends StatelessWidget {
  const _StatusLabel({
    required this.match,
    required this.blinkAnim,
    required this.isBafana,
  });

  final WcMatchModel      match;
  final Animation<double> blinkAnim;
  final bool              isBafana;

  @override
  Widget build(BuildContext context) {
    if (match.isLive) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FadeTransition(
            opacity: blinkAnim,
            child: Container(
              width:  8, height: 8,
              decoration: const BoxDecoration(
                color: Colors.redAccent, shape: BoxShape.circle,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            "LIVE  ${match.liveMinute}'",
            style: const TextStyle(
              color:      Colors.redAccent,
              fontWeight: FontWeight.w900,
              fontSize:   12,
              letterSpacing: 0.5,
            ),
          ),
        ],
      );
    }
    if (match.isFinished) {
      return const Text(
        'FULL TIME',
        style: TextStyle(
          color:      Colors.white54,
          fontWeight: FontWeight.w800,
          fontSize:   12,
          letterSpacing: 0.5,
        ),
      );
    }
    // Scheduled
    return Text(
      isBafana ? 'BAFANA UPCOMING 🔥' : 'UPCOMING MATCH',
      style: TextStyle(
        color:      isBafana ? _kGoldBafana : Colors.blueAccent.shade100,
        fontWeight: FontWeight.w800,
        fontSize:   12,
        letterSpacing: 0.5,
      ),
    );
  }
}

class _CentreBlock extends StatelessWidget {
  const _CentreBlock({
    required this.match,
    required this.isBafana,
    required this.countdownLabel,
  });

  final WcMatchModel match;
  final bool         isBafana;
  final String       countdownLabel;

  @override
  Widget build(BuildContext context) {
    if (match.isLive || match.isFinished) {
      return Text(
        '${match.teamAScore}  –  ${match.teamBScore}',
        style: const TextStyle(
          color:      _kWhite,
          fontWeight: FontWeight.w900,
          fontSize:   22,
          letterSpacing: -0.5,
        ),
      );
    }
    // Scheduled — show VS + countdown
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'VS',
          style: TextStyle(
            color:      isBafana ? _kGoldBafana : Colors.white54,
            fontWeight: FontWeight.w900,
            fontSize:   16,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          countdownLabel,
          style: const TextStyle(
            color:    Colors.white54,
            fontSize: 10,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _BafanaBadge extends StatelessWidget {
  const _BafanaBadge({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color:        _kGoldBafana,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color:      Color(0xFF1A0A00),
          fontSize:   9.5,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}
