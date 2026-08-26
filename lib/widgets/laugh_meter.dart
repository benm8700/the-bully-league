import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';


/// The Laugh Meter - the user-facing face of the rating system.
///
/// CLAUDE.md's Display decision: the Elo number is invisible plumbing, and
/// what a player sees is a themed gauge that fills toward the next rank
/// with the rank title as the primary label. The raw number lives in the
/// detailed stats view on the profile for anyone who wants precision.
///
/// THE FILL IS COMPUTED SERVER-SIDE, deliberately. The ladder's thresholds
/// live in functions/rating.js, and this project has already been bitten
/// by copying them into the client: the rank-change copy was first written
/// here with a hand-copied tier order that omitted Headliner, which would
/// have called a promotion a demotion for anyone near it.
///
/// NO NUMBERS APPEAR ON IT. The hidden-criteria decision is explicit that
/// the exact thresholds are not shown but a partial progress indicator is,
/// so this renders a bar and a mood - a percentage would let anyone
/// back-compute the thresholds one match at a time.
class LaughMeter extends StatefulWidget {
  const LaughMeter({super.key, this.fallbackTitle});

  /// The rank title from the user document the caller is already
  /// streaming.
  ///
  /// THE GAUGE IS THE OPTIONAL PART, THE TITLE IS NOT. The first
  /// version of this failed quiet and rendered nothing at all, which
  /// meant one failed call removed the player's rank from Home
  /// entirely - strictly worse than the plain text badge it replaced.
  /// A degraded meter should lose the bar, never the identity.
  final String? fallbackTitle;

  @override
  State<LaughMeter> createState() => _LaughMeterState();
}

class _LaughMeterState extends State<LaughMeter> {
  Map<String, dynamic>? _meter;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final result = await FirebaseFunctions.instance
          .httpsCallable('getLaughMeter')
          .call<Map<String, dynamic>>();
      if (mounted) setState(() => _meter = result.data);
    } catch (e) {
      // Fails QUIET in the UI - a broken gauge on the first screen makes
      // the whole app look broken - but it is logged, because a
      // silently-swallowed callable failure is the exact shape of bug
      // this project keeps meeting.
      debugPrint('LaughMeter failed: $e');
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final meter = _meter;
    final text = Theme.of(context).textTheme;

    // Degraded and loading states both still show the rank title when
    // one is known, so the player's identity never disappears from Home
    // just because a callable was slow or unreachable.
    if (_failed || meter == null) {
      final title = widget.fallbackTitle;
      if (title == null) {
        return SizedBox(height: _failed ? 0 : 72);
      }
      return Column(
        children: [
          Text(
            title,
            style: text.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
          // The bar's own height is held while loading so Home does not
          // jump when the call lands.
          SizedBox(height: _failed ? 0 : 32),
        ],
      );
    }

    final title = meter['title'] as String? ?? 'Average Joe';
    final fill = (meter['fill'] as num?)?.toDouble().clamp(0.0, 1.0) ?? 0.0;
    final caption = meter['caption'] as String? ?? '';
    final state = meter['state'] as String? ?? 'climbing';
    final isGoat = state == 'goat';

    final sig = context.palette.signature;
    final glow = isGoat || sig == 'glow';

    final inner = Column(
      children: [
        Text(
          title,
          style: text.headlineLarge?.copyWith(
            // GOAT gets the one piece of special treatment in the whole
            // display, because it is the one rank that is genuinely scarce
            // rather than a threshold anybody can eventually cross. The
            // glow direction tints the rank the accent too, so the
            // identity carries the neon.
            color: (isGoat || sig == 'glow') ? context.palette.accent : null,
            shadows: sig == 'glow'
                ? [Shadow(color: context.palette.accent.withValues(alpha: 0.6), blurRadius: 18)]
                : null,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        // The bar ran edge to edge on the first pass, which read as a
        // rendering fault rather than a gauge. It needs the same
        // margin as everything else on the screen.
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: _Gauge(
            fill: fill,
            glow: glow,
            segmented: context.palette.segmentedGauge,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          caption,
          style: text.bodySmall,
          textAlign: TextAlign.center,
        ),
      ],
    );

    // The collectible-card signature wraps the whole identity in a
    // framed panel with a foil sheen, so the rank reads as a card rather
    // than as loose text - the treatment that makes this direction more
    // than a palette.
    if (sig == 'frame') {
      final scheme = Theme.of(context).colorScheme;
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 20),
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: context.palette.accent, width: 1.5),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              context.palette.accent.withValues(alpha: 0.10),
              scheme.surfaceContainer,
              context.palette.gelB.withValues(alpha: 0.10),
            ],
          ),
        ),
        child: inner,
      );
    }
    return inner;
  }
}

/// The meter's palette comes from the room, not from fire.
///
/// A heat gradient - cold blue through orange to red - is the first
/// thing anyone reaches for on a roast app, and the first version of
/// this widget used exactly that. It says "spicy" and nothing else, and
/// it fought the identity the rest of the app now has. This is the
/// spotlight instead: the bar fills with the same brass the app uses
/// everywhere to mean live, lit, yours.
class _Gauge extends StatelessWidget {
  const _Gauge({
    required this.fill,
    this.glow = false,
    this.segmented = false,
  });

  final double fill;
  final bool glow;
  final bool segmented;

  static const _height = 14.0;
  static const _radius = BorderRadius.all(Radius.circular(3));

  @override
  Widget build(BuildContext context) {
    // The arcade signature: a chunky segmented power bar rather than a
    // smooth fill. Ten cells light in the gauge's gradient; the rest sit
    // dark. Reads as a cabinet health bar, which is the whole point.
    if (segmented) {
      const cells = 10;
      final lit = (fill * cells).round().clamp(0, cells);
      final scheme = Theme.of(context).colorScheme;
      return SizedBox(
        height: _height + 4,
        child: Row(
          children: List.generate(cells, (i) {
            final on = i < lit;
            final t = cells <= 1 ? 0.0 : i / (cells - 1);
            return Expanded(
              child: Container(
                margin: EdgeInsets.only(right: i == cells - 1 ? 0 : 3),
                decoration: BoxDecoration(
                  color: on
                      ? Color.lerp(context.palette.gaugeFrom,
                          context.palette.gaugeTo, t)
                      : scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(1),
                  boxShadow: on
                      ? [BoxShadow(
                          color: (Color.lerp(context.palette.gaugeFrom,
                                  context.palette.gaugeTo, t))!
                              .withValues(alpha: 0.5),
                          blurRadius: 6)]
                      : null,
                ),
              ),
            );
          }),
        ),
      );
    }
    return SizedBox(
      height: _height,
      child: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: _radius,
                border: Border.all(color: const Color(0xFF2A2422)),
              ),
            ),
          ),
          // Clipped with a CLIPPER rather than sized with a LayoutBuilder.
          //
          // The previous version measured the track with a LayoutBuilder
          // and then over-sized the fill with an OverflowBox to keep the
          // gradient anchored. That combination triggered a layout during
          // layout, and Flutter's assertion for it fires only in DEBUG -
          // so release builds rendered it fine while every debug build
          // failed to lay out the whole Home body and painted nothing at
          // all. A clipper gets the same result from the size it is
          // already given, with no second layout pass.
          Positioned.fill(
            child: ClipRRect(
              borderRadius: _radius,
              child: ClipRect(
                clipper: _FillClipper(fill),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: _radius,
                    // Anchored across the WHOLE track, so a given colour
                    // means the same thing at every rank rather than
                    // shifting under the player after every match.
                    gradient: LinearGradient(
                      colors: [
                        context.palette.gaugeFrom,
                        context.palette.gaugeTo,
                        context.palette.gaugeTo,
                      ],
                      stops: const [0.0, 0.75, 1.0],
                    ),
                    boxShadow: glow
                        ? [
                            BoxShadow(
                              color: context.palette.accent.withValues(alpha: 0.6),
                              blurRadius: 16,
                              spreadRadius: 1,
                            ),
                          ]
                        : null,
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

/// Shows the left [fraction] of whatever it is given.
class _FillClipper extends CustomClipper<Rect> {
  const _FillClipper(this.fraction);

  final double fraction;

  @override
  Rect getClip(Size size) => Rect.fromLTWH(
        0,
        0,
        size.width * fraction.clamp(0.0, 1.0),
        size.height,
      );

  @override
  bool shouldReclip(_FillClipper old) => old.fraction != fraction;
}
