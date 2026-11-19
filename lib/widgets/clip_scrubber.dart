import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:video_player/video_player.dart';

/// THE app-wide playback bar for recorded video (developer, 2026-11-09: "no
/// matter what video someone's watching, unless it's live, they can use this
/// bar to go back and rewatch"). Used by MatchClipPlayer, the Vote feed and
/// LoopingVideo (intros). There is deliberately NO restart / rewind-10 button
/// anywhere - tapping the start of this bar does that.
///
/// The handle is a round PLAY/PAUSE button (developer, 2026-11-17: the
/// separate pause button went away, and the little dot did not look
/// pressable): tap the handle to pause or play, tap the track to jump, drag
/// anything to scrub. Put it on a dark scrim - it is white.
///
/// Covers [start, end] of the video (end <= 0 means the whole video).
class ClipScrubber extends StatefulWidget {
  const ClipScrubber({
    super.key,
    required this.controller,
    this.start = Duration.zero,
    this.end = Duration.zero,
    this.onSeekEnd,
    this.onTogglePlay,
  });

  final VideoPlayerController controller;
  final Duration start;
  final Duration end;

  /// Called when a tap or drag finishes (e.g. to resume playback).
  final VoidCallback? onSeekEnd;

  /// The handle's play/pause tap, for a host that keeps its own play state
  /// (MatchClipPlayer). Without it the handle drives the controller directly.
  final VoidCallback? onTogglePlay;

  @override
  State<ClipScrubber> createState() => ClipScrubberState();
}

class ClipScrubberState extends State<ClipScrubber>
    with SingleTickerProviderStateMixin {
  double? _dragFraction; // non-null while the finger is down

  // SMOOTH MOTION (developer, 2026-11-18: the bar looked "erratic").
  // video_player only reports the position every ~0.5s, so the bar and
  // handle used to hop in steps. Between reports we extrapolate from the
  // last one with a per-frame ticker, so they glide at the frame rate.
  late final Ticker _ticker;
  Duration _basePos = Duration.zero;
  final Stopwatch _sinceBase = Stopwatch();

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((_) {
      if (mounted) setState(() {});
    });
    widget.controller.addListener(_onValue);
    _onValue();
  }

  @override
  void didUpdateWidget(ClipScrubber oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onValue);
      widget.controller.addListener(_onValue);
      _onValue();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onValue);
    _ticker.dispose();
    super.dispose();
  }

  void _onValue() {
    final v = widget.controller.value;
    if (v.position != _basePos) {
      _basePos = v.position;
      _sinceBase
        ..reset()
        ..start();
    }
    final playing = v.isPlaying && !v.isBuffering;
    if (playing && !_ticker.isActive) {
      _sinceBase
        ..reset()
        ..start();
      _ticker.start();
    } else if (!playing && _ticker.isActive) {
      _ticker.stop();
    }
  }

  /// The position to draw: the last reported one, carried forward by the
  /// time since while playing (never more than one report interval ahead).
  Duration get _smoothPos {
    final v = widget.controller.value;
    if (!v.isPlaying || v.isBuffering) return v.position;
    final ahead = Duration(
      milliseconds: (_sinceBase.elapsedMilliseconds * v.playbackSpeed)
          .round()
          .clamp(0, 700),
    );
    final p = _basePos + ahead;
    return p > v.duration ? v.duration : p;
  }

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
    final pos = _smoothPos - widget.start;
    return (pos.inMilliseconds / len).clamp(0.0, 1.0);
  }

  /// The handle's tap: pause, play, or start over once the clip has ended.
  void _togglePlay() {
    final c = widget.controller;
    if (!c.value.isInitialized) return;
    if (c.value.isPlaying) {
      c.pause();
      return;
    }
    final atEnd =
        c.value.position >= _rangeEnd - const Duration(milliseconds: 80);
    if (atEnd) c.seekTo(widget.start);
    c.play();
  }

  static const double _knob = 32;
  static const double _knobDrag = 38;
  static const double _trackY = 20; // the track's centre line

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
                // On the handle (generous radius): play / pause.
                final knobX = w * f;
                final dx = d.localPosition.dx - knobX;
                final dy = d.localPosition.dy - _trackY;
                if (dx * dx + dy * dy <= 26 * 26) {
                  (widget.onTogglePlay ?? _togglePlay)();
                  return;
                }
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
                height: 58,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    // Track
                    Positioned(
                      left: 0,
                      right: 0,
                      top: _trackY - (dragging ? 4 : 2.5),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 120),
                        height: dragging ? 8 : 5,
                        decoration: BoxDecoration(
                          color: Colors.white30,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                    // Played
                    Positioned(
                      left: 0,
                      top: _trackY - (dragging ? 4 : 2.5),
                      child: Container(
                        height: dragging ? 8 : 5,
                        width: w * f,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                    // The handle: a round play/pause button riding the track.
                    Positioned(
                      left: (w * f - (dragging ? _knobDrag : _knob) / 2).clamp(
                        0.0,
                        w - (dragging ? _knobDrag : _knob),
                      ),
                      top: _trackY - (dragging ? _knobDrag : _knob) / 2,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 120),
                        width: dragging ? _knobDrag : _knob,
                        height: dragging ? _knobDrag : _knob,
                        decoration: const BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(color: Colors.black54, blurRadius: 6),
                          ],
                        ),
                        child: Icon(
                          value.isPlaying
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          color: Colors.black,
                          size: 22,
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
