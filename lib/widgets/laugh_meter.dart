import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

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

    return Column(
      children: [
        Text(
          title,
          style: text.headlineSmall?.copyWith(
            fontWeight: FontWeight.bold,
            // GOAT gets the one piece of special treatment in the whole
            // display, because it is the one rank that is genuinely scarce
            // rather than a threshold anybody can eventually cross.
            color: isGoat ? _hot : null,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 10),
        _Gauge(fill: fill, glow: isGoat),
        const SizedBox(height: 8),
        Text(
          caption,
          style: text.bodySmall,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

/// Cold at the bottom, hot at the top - the heat gauge CLAUDE.md's Laugh
/// Meter concept describes.
const _cold = Color(0xFF3D7EFF);
const _warm = Color(0xFFFFA726);
const _hot = Color(0xFFFF3D3D);

class _Gauge extends StatelessWidget {
  const _Gauge({required this.fill, this.glow = false});

  final double fill;
  final bool glow;

  static const _height = 14.0;
  static const _radius = BorderRadius.all(Radius.circular(7));

  @override
  Widget build(BuildContext context) {
    final track = Theme.of(context).colorScheme.surfaceContainerHighest;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return SizedBox(
          // The TRACK is explicitly full width. Without this the whole
          // gauge sized itself to the filled portion, so a half-full
          // meter rendered as a short stub with nothing to compare it
          // against - which reads as a loading bar rather than progress.
          width: width,
          height: _height,
          child: Stack(
            children: [
              // Positioned.fill, because a bare child of a Stack sizes to
              // ITSELF - which is how the coloured bar came out with zero
              // height and painted nothing at all.
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: track,
                    borderRadius: _radius,
                  ),
                ),
              ),
              ClipRRect(
                borderRadius: _radius,
                child: SizedBox(
                  width: width * fill,
                  height: _height,
                  // The gradient is painted across the WHOLE track and
                  // then clipped, so a given colour means the same thing
                  // at every rank. Letting it rescale to the filled part
                  // would make a quarter-full meter look as hot as a full
                  // one, and would shift the colours under a player after
                  // every match.
                  child: OverflowBox(
                    alignment: Alignment.centerLeft,
                    minWidth: width,
                    maxWidth: width,
                    child: Container(
                      width: width,
                      height: _height,
                      decoration: BoxDecoration(
                        borderRadius: _radius,
                        gradient: const LinearGradient(
                          colors: [_cold, _warm, _hot],
                          stops: [0.0, 0.55, 1.0],
                        ),
                        boxShadow: glow
                            ? [
                                BoxShadow(
                                  color: _hot.withValues(alpha: 0.6),
                                  blurRadius: 12,
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
      },
    );
  }
}
