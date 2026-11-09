import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// THE app-wide playback bar for recorded video (developer, 2026-11-09: "no
/// matter what video someone's watching, unless it's live, they can use this
/// bar to go back and rewatch"). Used by MatchClipPlayer, the Vote feed and
/// LoopingVideo (intros). There is deliberately NO restart / rewind-10 button
/// anywhere - tapping the start of this bar does that.
///
/// Thin to look at, ~44px tall to touch; tap or drag anywhere on it. Put it on
/// a dark scrim - it is white.
///
/// Covers [start, end] of the video (end <= 0 means the whole video).
class ClipScrubber extends StatefulWidget {
  const ClipScrubber({
    super.key,
    required this.controller,
    this.start = Duration.zero,
    this.end = Duration.zero,
    this.onSeekEnd,
  });

  final VideoPlayerController controller;
  final Duration start;
  final Duration end;

  /// Called when a tap or drag finishes (e.g. to resume playback).
  final VoidCallback? onSeekEnd;

  @override
  State<ClipScrubber> createState() => ClipScrubberState();
}

class ClipScrubberState extends State<ClipScrubber> {
  double? _dragFraction; // non-null while the finger is down

  Duration get _rangeEnd {
    final total = widget.controller.value.duration;
    final e = widget.end;
    return e > Duration.zero && e < total ? e : total;
  }

  Duration get _length {
    final l = _rangeEnd - widget.start;
    return l > Duration.zero ? l : Duration.zero;
  }

  double _fractionNow() {
    final len = _length.inMilliseconds;
    if (len == 0) return 0;
    final pos = widget.controller.value.position - widget.start;
    return (pos.inMilliseconds / len).clamp(0.0, 1.0);
  }

  void _seekTo(double fraction) {
    final ms = (fraction * _length.inMilliseconds).round();
    widget.controller.seekTo(widget.start + Duration(milliseconds: ms));
  }

  double _fractionFor(Offset local, double width) =>
      width <= 0 ? 0 : (local.dx / width).clamp(0.0, 1.0);

  static String _fmt(Duration d) {
    final s = d.inSeconds;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: widget.controller,
      builder: (context, value, _) {
        final dragging = _dragFraction != null;
        final f = _dragFraction ?? _fractionNow();
        final shown = Duration(
          milliseconds: (f * _length.inMilliseconds).round(),
        );
        final timeStyle = const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontFeatures: [FontFeature.tabularFigures()],
        );
        return LayoutBuilder(
          builder: (context, box) {
            final w = box.maxWidth;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) {
                _seekTo(_fractionFor(d.localPosition, w));
                widget.onSeekEnd?.call();
              },
              onHorizontalDragStart: (d) => setState(
                () => _dragFraction = _fractionFor(d.localPosition, w),
              ),
              onHorizontalDragUpdate: (d) {
                setState(
                  () => _dragFraction = _fractionFor(d.localPosition, w),
                );
                _seekTo(_dragFraction!);
              },
              onHorizontalDragEnd: (_) {
                if (_dragFraction != null) _seekTo(_dragFraction!);
                setState(() => _dragFraction = null);
                widget.onSeekEnd?.call();
              },
              onHorizontalDragCancel: () =>
                  setState(() => _dragFraction = null),
              child: SizedBox(
                height: 44,
                child: Stack(
                  alignment: Alignment.centerLeft,
                  children: [
                    // Track
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      height: dragging ? 8 : 5,
                      decoration: BoxDecoration(
                        color: Colors.white30,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    // Played
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      height: dragging ? 8 : 5,
                      width: w * f,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    // Thumb
                    Positioned(
                      left: (w * f - (dragging ? 10 : 7)).clamp(0.0, w),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 120),
                        width: dragging ? 20 : 14,
                        height: dragging ? 20 : 14,
                        decoration: const BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(color: Colors.black45, blurRadius: 4),
                          ],
                        ),
                      ),
                    ),
                    // Times, tucked just under the track
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Row(
                        children: [
                          Text(_fmt(shown), style: timeStyle),
                          const Spacer(),
                          Text(_fmt(_length), style: timeStyle),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}
