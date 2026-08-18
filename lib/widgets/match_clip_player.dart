import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// Plays a match's highlight clip, so someone judging a battle can
/// actually watch it.
///
/// Until this existed, in-app voting meant reading two usernames and
/// picking one - which makes the vote noise rather than judgement, and
/// quietly undermines the vote-confidence weighting that assumes more
/// votes means a better-judged match.
///
/// Renders an honest empty state when there is no clip. That is currently
/// the common case: rendering is on-demand and admin-only, and publishing
/// is a deliberate human gate, so most matches have nothing to show yet.
/// Saying so is better than an endless spinner.
class MatchClipPlayer extends StatefulWidget {
  const MatchClipPlayer({
    super.key,
    required this.videoUrl,
    this.onWatchedEnough,
    this.watchSecondsRequired = 0,
  });

  final String? videoUrl;

  /// Called once the clip has genuinely played for [watchSecondsRequired]
  /// seconds, so a caller can unlock a vote button.
  ///
  /// FIRES IMMEDIATELY when there is nothing to watch - no clip, a clip
  /// that failed to load, or a requirement of zero. **Failing open is the
  /// whole design here.** Most matches still have no published clip, so a
  /// gate that waited for a video that will never arrive would not slow
  /// down careless voting, it would stop judging altogether - and votes
  /// are the scarce resource the entire ladder runs on.
  final VoidCallback? onWatchedEnough;

  /// How much of the clip must actually play first. Capped at the clip's
  /// own length, so a short clip is never ungateable.
  final int watchSecondsRequired;

  @override
  State<MatchClipPlayer> createState() => _MatchClipPlayerState();
}

class _MatchClipPlayerState extends State<MatchClipPlayer> {
  VideoPlayerController? _controller;
  bool _initialising = false;
  String? _error;
  bool _watchedEnough = false;

  /// Measured from the player's own reported position rather than a wall
  /// clock, so leaving it paused, or backgrounding the app, does not
  /// count. That is the point: the exploit being priced up is SPEED.
  Duration _furthestReached = Duration.zero;

  @override
  void initState() {
    super.initState();
    _load();
    // Nothing to watch means nothing to wait for.
    if (widget.watchSecondsRequired <= 0 ||
        (widget.videoUrl?.isEmpty ?? true)) {
      _satisfy();
    }
  }

  void _satisfy() {
    if (_watchedEnough) return;
    _watchedEnough = true;
    // Deferred so a caller can safely setState in response, including
    // when this fires during initState.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.onWatchedEnough?.call();
    });
  }

  void _onTick() {
    final controller = _controller;
    if (controller == null || _watchedEnough) return;
    final position = controller.value.position;
    // The clip loops, so position resets - keep the furthest point rather
    // than the current one, or a loop would reset progress toward the
    // requirement.
    if (position > _furthestReached) _furthestReached = position;
    final duration = controller.value.duration;
    // Capped at the clip's length: a 12-second clip cannot be watched for
    // 15, and requiring the impossible would lock voting on short clips.
    final required = Duration(
      seconds: widget.watchSecondsRequired,
    ) > duration && duration > Duration.zero ?
      duration : Duration(seconds: widget.watchSecondsRequired);
    if (_furthestReached >= required) _satisfy();
  }

  @override
  void didUpdateWidget(MatchClipPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoUrl != widget.videoUrl) {
      _controller?.dispose();
      _controller = null;
      _load();
    }
  }

  Future<void> _load() async {
    final url = widget.videoUrl;
    if (url == null || url.isEmpty) return;
    setState(() {
      _initialising = true;
      _error = null;
    });
    final controller = VideoPlayerController.networkUrl(Uri.parse(url));
    try {
      await controller.initialize();
      // Loops because these are short clips and a judge will often want a
      // second look at a line before deciding.
      await controller.setLooping(true);
      if (!mounted) {
        await controller.dispose();
        return;
      }
      controller.addListener(_onTick);
      setState(() {
        _controller = controller;
        _initialising = false;
      });
    } catch (e) {
      await controller.dispose();
      if (!mounted) return;
      setState(() {
        _initialising = false;
        _error = 'Could not load this clip.';
      });
      // A clip that will not load must not block judging - the same
      // fail-open rule as having no clip at all.
      _satisfy();
    }
  }

  @override
  void dispose() {
    _controller?.removeListener(_onTick);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.videoUrl == null || widget.videoUrl!.isEmpty) {
      return _placeholder(
        context,
        Icons.movie_outlined,
        'Clip not available yet',
        'You can still judge on the result, but the video for this battle '
            'has not been published.',
      );
    }
    if (_error != null) {
      return _placeholder(context, Icons.error_outline, 'Clip unavailable', _error!);
    }
    final controller = _controller;
    if (_initialising || controller == null) {
      return AspectRatio(
        aspectRatio: 9 / 16,
        child: Container(
          color: Colors.black12,
          child: const Center(child: CircularProgressIndicator()),
        ),
      );
    }

    return AspectRatio(
      aspectRatio: controller.value.aspectRatio,
      child: Stack(
        alignment: Alignment.center,
        children: [
          VideoPlayer(controller),
          // Tap anywhere to play/pause. No custom chrome: the clip is
          // vertical and short, and controls overlaying a face is exactly
          // the wrong place for them.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() {
              controller.value.isPlaying ? controller.pause() : controller.play();
            }),
            child: AnimatedOpacity(
              opacity: controller.value.isPlaying ? 0 : 1,
              duration: const Duration(milliseconds: 150),
              child: Container(
                color: Colors.black26,
                child: const Center(
                  child: Icon(Icons.play_arrow, size: 56, color: Colors.white),
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: VideoProgressIndicator(controller, allowScrubbing: true),
          ),
        ],
      ),
    );
  }

  Widget _placeholder(
      BuildContext context, IconData icon, String title, String body) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Icon(icon, size: 36),
          const SizedBox(height: 10),
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 6),
          Text(body,
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center),
        ],
      ),
    );
  }
}
