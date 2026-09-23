import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../core/route_observer.dart';
import '../core/services/clip_cache.dart';

/// Which player's half of the stacked clip is picked as the winner. The clip
/// composites player 1 on TOP and player 2 on the BOTTOM.
enum ClipSelectRegion { none, top, bottom }

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
    this.startMs,
    this.endMs,
    this.onSelectTop,
    this.onSelectBottom,
    this.selectedRegion = ClipSelectRegion.none,
  });

  final String? videoUrl;

  /// "Pick a winner" mode. When [onSelectTop]/[onSelectBottom] are provided,
  /// tapping the TOP half of the stacked clip picks the top player and the
  /// BOTTOM half picks the bottom player, and [selectedRegion] gets a bright
  /// green outline. In this mode the tap-to-play/pause is disabled (the clip
  /// loops on its own); rewinding is still the scrub bar. The selection IS the
  /// video box, so nothing overlays and blocks the players.
  final VoidCallback? onSelectTop;
  final VoidCallback? onSelectBottom;
  final ClipSelectRegion selectedRegion;

  /// Optional clip segment. When BOTH are set (and endMs > startMs) the
  /// player shows ONLY [startMs, endMs] of the clip - it seeks there on
  /// load and loops within that window rather than the whole clip. This is
  /// what lets the Best Rounds board play just the voted-best round instead
  /// of the entire battle. Null = play the whole clip (the old behaviour).
  final int? startMs;
  final int? endMs;

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

class _MatchClipPlayerState extends State<MatchClipPlayer>
    with WidgetsBindingObserver, RouteAware {
  VideoPlayerController? _controller;
  bool _initialising = false;
  String? _error;
  bool _watchedEnough = false;

  // The three conditions that must ALL hold for the clip to actually play.
  // The clip loops for rewatching, so without the route half it kept playing
  // the match's round audio underneath the next screen (heard on a device,
  // 2026-09-16). It never auto-plays, so _wantPlaying starts false.
  bool _wantPlaying = false;
  bool _appForeground = true;
  bool _routeVisible = true;

  /// Measured from the player's own reported position rather than a wall
  /// clock, so leaving it paused, or backgrounding the app, does not
  /// count. That is the point: the exploit being priced up is SPEED.
  Duration _furthestReached = Duration.zero;

  /// The round window, when this player is in segment mode.
  bool get _segmented =>
      widget.startMs != null &&
      widget.endMs != null &&
      widget.endMs! > widget.startMs!;
  Duration get _segStart => Duration(milliseconds: widget.startMs ?? 0);
  Duration get _segEnd => Duration(milliseconds: widget.endMs ?? 0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
    if (controller == null) return;
    // Segment mode: loop within the round window rather than the whole clip.
    // Runs even after the watch gate is satisfied (the board has no gate),
    // so it must come before the _watchedEnough return below.
    if (_segmented) {
      final duration = controller.value.duration;
      final end = _segEnd > duration && duration > Duration.zero
          ? duration
          : _segEnd;
      if (controller.value.position >= end) {
        controller.seekTo(_segStart);
      }
    }
    if (_watchedEnough) return;
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
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ModalRoute<dynamic>? route = ModalRoute.of(context);
    if (route != null) appRouteObserver.subscribe(this, route);
  }

  /// Play only when the user wants it AND the app is foreground AND this is
  /// the visible route. Everything routes through here so "resume" can never
  /// fire while the clip is still hidden.
  void _syncPlayback() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    final shouldPlay = _wantPlaying && _appForeground && _routeVisible;
    if (shouldPlay && !c.value.isPlaying) {
      c.play();
    } else if (!shouldPlay && c.value.isPlaying) {
      c.pause();
    }
  }

  // RouteAware: covered by another screen -> pause; visible again -> resume.
  @override
  void didPushNext() {
    _routeVisible = false;
    _syncPlayback();
  }

  @override
  void didPopNext() {
    _routeVisible = true;
    _syncPlayback();
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
    // Prefer a cached local FILE so the scrubber and restart are instant - a
    // streamed clip re-buffers on every seek. This screen shows one clip at a
    // time with no prefetch, so it downloads-then-plays (getFile) rather than
    // the feed's stream-if-not-cached approach. Falls back to streaming if the
    // download or file playback fails, so a clip never breaks on the cache.
    File? file;
    try {
      file = await ClipCacheService.instance.getFile(url);
    } catch (_) {
      file = null;
    }
    if (!mounted) return;
    if (file != null &&
        await _setUpController(VideoPlayerController.file(file))) {
      return;
    }
    if (!mounted) return;
    if (await _setUpController(VideoPlayerController.networkUrl(Uri.parse(url)))) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _initialising = false;
      _error = 'Could not load this clip.';
    });
    // A clip that will not load must not block judging - the same fail-open
    // rule as having no clip at all.
    _satisfy();
  }

  /// Initializes and wires up [controller]. Returns true on success (or if the
  /// widget was disposed mid-load); false on failure so [_load] can fall back
  /// to the next source (cached file -> network stream).
  Future<bool> _setUpController(VideoPlayerController controller) async {
    try {
      await controller.initialize();
      // Full-clip looping only when NOT segmented. In segment mode the native
      // loop is off and _onTick loops within [startMs, endMs] instead, and we
      // seek to the round's start so the first frame - and the poster while
      // paused - is the round rather than the clip's open.
      await controller.setLooping(!_segmented);
      if (_segmented) await controller.seekTo(_segStart);
      if (!mounted) {
        await controller.dispose();
        return true;
      }
      controller.addListener(_onTick);
      setState(() {
        _controller = controller;
        _initialising = false;
      });
      return true;
    } catch (_) {
      await controller.dispose();
      return false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appForeground = state == AppLifecycleState.resumed;
    _syncPlayback();
  }

  @override
  void dispose() {
    appRouteObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
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
          // In "pick a winner" mode, the two halves of the stacked clip are
          // the tap targets - tap a player's box to select them, tap the
          // other to switch. Otherwise, tap anywhere to play/pause.
          if (_selectionMode) _selectionLayer() else _playPauseLayer(controller),
          // Playback controls: a restart button plus a clearly visible,
          // draggable scrubber lifted off the bottom edge. Scrubbing was
          // always enabled, but a hairline bar flush to the edge read as
          // "no rewind" - and judges need to go back and re-hear a line.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.fromLTRB(4, 12, 12, 10),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Colors.black54],
                ),
              ),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.replay, color: Colors.white),
                    tooltip: 'Restart',
                    onPressed: () {
                      controller.seekTo(_segStart);
                      _wantPlaying = true;
                      _syncPlayback();
                      setState(() {});
                    },
                  ),
                  Expanded(
                    child: VideoProgressIndicator(
                      controller,
                      allowScrubbing: true,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      colors: const VideoProgressColors(
                        playedColor: Colors.white,
                        bufferedColor: Colors.white38,
                        backgroundColor: Colors.white24,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  bool get _selectionMode =>
      widget.onSelectTop != null || widget.onSelectBottom != null;

  Widget _playPauseLayer(VideoPlayerController controller) {
    // Tap anywhere to play/pause. No custom chrome: the clip is vertical and
    // short, and controls overlaying a face is exactly the wrong place.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        _wantPlaying = !_wantPlaying;
        _syncPlayback();
        setState(() {});
      },
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
    );
  }

  Widget _selectionLayer() {
    return Positioned.fill(
      child: Column(
        children: [
          Expanded(child: _selectHalf(top: true)),
          Expanded(child: _selectHalf(top: false)),
        ],
      ),
    );
  }

  Widget _selectHalf({required bool top}) {
    final region = top ? ClipSelectRegion.top : ClipSelectRegion.bottom;
    final selected = widget.selectedRegion == region;
    const green = Color(0xFF31D67A);
    // JUST the outline - no fill, glow or badge, so it never covers the faces.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: top ? widget.onSelectTop : widget.onSelectBottom,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          border: Border.all(
            color: selected ? green : Colors.transparent,
            width: 5,
          ),
        ),
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
