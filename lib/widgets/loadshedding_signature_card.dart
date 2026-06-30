// lib/widgets/loadshedding_signature_card.dart
//
// Two-state "power status" hero card. Extracted in WS5 from
// scraper_screen.dart so it can be mounted inside CommunityHubScreen (its
// new home — see PLAN.md §WS5). No behaviour change vs the original; only
// the outer widget name is now public.
//
// Wires LoadsheddingService (unchanged data source — EskomSePush + cache +
// suburb resolution via Geolocator) and renders ONE of two distinct UI
// states:
//
//   STATE A — POWER ON  (no active loadshedding window in current suburb)
//     • Cream surface, hairline border, NO drop shadow
//     • Avocado-green vertical accent line on the left edge
//     • Copy: "Fire Up the Grid 🔥"
//     • Avocado primary CTA → onSeeBraaiRecipes
//
//   STATE B — POWER OFF  (loadshedding actively impacting the suburb)
//     • Cream surface, soft warning border (mango at 60% alpha)
//     • Mango status pill showing stage + current slot
//     • Copy: "Quick stovetop meals ready in 20 min 🔋"
//     • Mango primary CTA → onSeeQuickMeals

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../services/loadshedding_service.dart';
import '../services/location_permission_gate.dart';
import '../theme/app_theme.dart';

class LoadsheddingSignatureCard extends StatefulWidget {
  const LoadsheddingSignatureCard({
    super.key,
    this.onSeeBraaiRecipes,
    this.onSeeQuickMeals,
    this.compact = false,
  });

  /// Fired when the user taps the CTA in the POWER ON state.
  /// Parent should route to a braai-content destination.
  final VoidCallback? onSeeBraaiRecipes;

  /// Fired when the user taps the CTA in the POWER OFF state.
  /// Parent should route to a gas-hob / no-electricity filtered recipe view.
  final VoidCallback? onSeeQuickMeals;

  /// When true the card renders as a single compact status strip —
  /// just the POWER ON / OFF pill + area pill, no headline, no CTA.
  /// Used inside Community so the screen leads with channels.
  final bool compact;

  @override
  State<LoadsheddingSignatureCard> createState() =>
      _LoadsheddingSignatureCardState();
}

class _LoadsheddingSignatureCardState
    extends State<LoadsheddingSignatureCard>
    with WidgetsBindingObserver {
  final _service = LoadsheddingService();
  LoadsheddingStatus? _status;
  bool _locationDenied = false;

  /// Last permission state we observed. Used by the lifecycle observer to
  /// detect a grant-while-backgrounded transition.
  LocationPermission _lastPerm = LocationPermission.denied;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _requestLocationThenFetch();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _requestLocationThenFetch() async {
    LocationPermission perm = LocationPermission.denied;
    try {
      perm = await LocationPermissionGate.instance.ensure();
    } catch (_) {
      // GPS unavailable — fall back to default suburb.
    }

    _lastPerm = perm;
    if (!mounted) return;

    if (perm == LocationPermission.deniedForever) {
      setState(() => _locationDenied = true);
    } else {
      if (_locationDenied) setState(() => _locationDenied = false);
    }

    final justGranted = perm == LocationPermission.whileInUse
                     || perm == LocationPermission.always;
    final status = await _service.getStatus(forceRefresh: justGranted);
    if (!mounted) return;
    setState(() => _status = status);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state != AppLifecycleState.resumed) return;

    Geolocator.checkPermission().then((perm) {
      if (!mounted) return;
      final wasGranted = _lastPerm == LocationPermission.whileInUse
                      || _lastPerm == LocationPermission.always;
      final nowGranted = perm == LocationPermission.whileInUse
                      || perm == LocationPermission.always;
      _lastPerm = perm;
      if (!wasGranted && nowGranted) {
        if (_locationDenied) setState(() => _locationDenied = false);
        _refresh();
      }
    });
  }

  Future<void> _refresh() async {
    if (mounted) setState(() => _status = null);
    try {
      final status = await _service.getStatus(forceRefresh: true);
      if (mounted) setState(() => _status = status);
    } catch (_) {
      if (mounted && _status == null) {
        setState(() => _status = LoadsheddingStatus(
          isActive: false, stage: 0, todaySlots: [],
          daysFree: 0, source: 'offline',
        ));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _status;

    if (s == null) {
      return Container(
        height: widget.compact ? 56 : 168,
        decoration: BoxDecoration(
          color:        AppTheme.kCreamSand,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: AppTheme.kHairline,
            width: 1,
          ),
        ),
        alignment: Alignment.center,
        child: SizedBox(
          width: 22, height: 22,
          child: CircularProgressIndicator(
            strokeWidth: 2.4,
            color:       AppTheme.kBottleGreen,
          ),
        ),
      );
    }

    return s.isActive ? _buildPowerOff(s) : _buildPowerOn(s);
  }

  // STATE A — POWER ON
  Widget _buildPowerOn(LoadsheddingStatus s) {
    final text   = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color:        AppTheme.kCreamSand,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppTheme.kHairline, width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _DottedWaveformPainter(
                color:    AppTheme.kBottleGreen.withAlpha(28),
                spacing:  18,
                amplitude:14,
              ),
            ),
          ),
          Positioned(
            left: 0, top: 14, bottom: 14,
            child: Container(
              width: 4,
              decoration: BoxDecoration(
                color:        AppTheme.kBottleGreen,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 18, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _LsStatusPill(
                      color: AppTheme.kBottleGreen,
                      icon:  Icons.bolt_rounded,
                      label: 'POWER ON',
                    ),
                    const SizedBox(width: 8),
                    if (s.daysFree > 0)
                      _LsStatusPill(
                        color: colors.onSurfaceVariant,
                        label: '${s.daysFree}d loadshedding-free',
                      )
                    else if (s.source != 'offline')
                      _LsStatusPill(
                        color: colors.onSurfaceVariant,
                        label: _locationDenied
                            ? 'Cape Town · default'
                            : s.displaySuburb,
                      ),
                    const Spacer(),
                    GestureDetector(
                      onTap: _refresh,
                      child: Icon(
                        Icons.refresh_rounded,
                        size:  18,
                        color: colors.onSurfaceVariant.withAlpha(160),
                      ),
                    ),
                  ],
                ),
                if (!widget.compact) ...[
                  const SizedBox(height: 16),
                  Text(
                    'Fire Up the Grid 🔥',
                    style: text.headlineSmall?.copyWith(
                      fontWeight:    FontWeight.w900,
                      color:         AppTheme.kBottleGreen,
                      letterSpacing: -0.3,
                      height:        1.2,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Coals stay hot tonight. Full electrical menu available — '
                    'oven, hob, microwave all good to go.',
                    style: text.bodySmall?.copyWith(
                      color:  colors.onSurfaceVariant,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 16),
                  GestureDetector(
                    onTap: widget.onSeeBraaiRecipes,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 12),
                      decoration: BoxDecoration(
                        color:        AppTheme.kBottleGreen,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.outdoor_grill_rounded,
                              color: AppTheme.kAlabaster, size: 16),
                          const SizedBox(width: 8),
                          Text(
                            'Browse Braai Recipes',
                            style: TextStyle(
                              color:      AppTheme.kAlabaster,
                              fontWeight: FontWeight.w800,
                              fontSize:   13.5,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Icon(Icons.arrow_forward_rounded,
                              color: AppTheme.kAlabaster, size: 15),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  // STATE B — POWER OFF
  Widget _buildPowerOff(LoadsheddingStatus s) {
    final text   = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    final accent = colors.secondary;

    return Container(
      decoration: BoxDecoration(
        color:        AppTheme.kCreamSand,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: accent.withAlpha(150), width: 1.5),
        boxShadow: [
          BoxShadow(
            color:      accent.withAlpha(28),
            blurRadius: 18,
            spreadRadius: 1,
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _DottedWaveformPainter(
                color:     accent.withAlpha(28),
                spacing:   18,
                amplitude: 14,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 18, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _LsStatusPill(
                      color: accent,
                      icon:  Icons.flash_off_rounded,
                      label: s.todaySlots.isNotEmpty
                          ? '${s.stageLabel.toUpperCase()} · ${s.todaySlots.first}'
                          : s.stageLabel.toUpperCase(),
                    ),
                    const Spacer(),
                    GestureDetector(
                      onTap: _refresh,
                      child: Icon(
                        Icons.refresh_rounded,
                        size:  18,
                        color: colors.onSurfaceVariant.withAlpha(160),
                      ),
                    ),
                  ],
                ),
                if (s.todaySlots.length > 1) ...[
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    children: s.todaySlots.skip(1).map((slot) => Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color:        accent.withAlpha(20),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: accent.withAlpha(60)),
                      ),
                      child: Text(
                        'Also $slot',
                        style: TextStyle(
                          color:      accent,
                          fontSize:   10,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    )).toList(),
                  ),
                ],
                if (!widget.compact) ...[
                  const SizedBox(height: 16),
                  Text(
                    'Quick stovetop meals ready in 20 min 🔋',
                    style: text.headlineSmall?.copyWith(
                      fontWeight:    FontWeight.w900,
                      color:         AppTheme.kBottleGreen,
                      letterSpacing: -0.3,
                      height:        1.2,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'We\'ve filtered to gas-hob, braai-grid, and no-cook recipes '
                    'only — every option here works without mains power.',
                    style: text.bodySmall?.copyWith(
                      color:  colors.onSurfaceVariant,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    onPressed: widget.onSeeQuickMeals,
                    icon:  const Icon(Icons.local_fire_department_rounded,
                        size: 16),
                    label: const Text('Show Gas-Hob Meals'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// _LsStatusPill — small rounded pill used by both Loadshedding states
// =============================================================================

class _LsStatusPill extends StatelessWidget {
  const _LsStatusPill({
    required this.color,
    required this.label,
    this.icon,
  });

  final Color    color;
  final String   label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color:        color.withAlpha(28),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withAlpha(80)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, color: color, size: 12),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              color:         color,
              fontSize:      10.5,
              fontWeight:    FontWeight.w800,
              letterSpacing: 0.4,
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// _DottedWaveformPainter — subtle power-waveform texture for the card backdrop
// =============================================================================

class _DottedWaveformPainter extends CustomPainter {
  const _DottedWaveformPainter({
    required this.color,
    this.spacing   = 18.0,
    this.amplitude = 12.0,
  });

  final Color  color;
  final double spacing;
  final double amplitude;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final rows = [size.height * 0.30, size.height * 0.70];

    for (var rowIdx = 0; rowIdx < rows.length; rowIdx++) {
      final centerY = rows[rowIdx];
      final phase = rowIdx == 0 ? 0.0 : math.pi;

      double x = 0;
      while (x < size.width) {
        final y = centerY + amplitude *
            math.sin((x / size.width) * math.pi * 6 + phase);
        canvas.drawCircle(Offset(x, y), 1.6, paint);
        x += spacing;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DottedWaveformPainter old) =>
      old.color     != color ||
      old.spacing   != spacing ||
      old.amplitude != amplitude;
}
