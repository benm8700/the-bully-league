import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../core/route_observer.dart';

/// A minimal looping video player for a network URL - used for the
/// mandatory intro video, both as the self-review preview on the profile
/// and as the opponent's "tell me about yourself" during the pre-match
/// reveal (where it is rewatchable ammo). Tap toggles play/pause.
///
/// Deliberately NOT [MatchClipPlayer], which is tailored to match clips
/// (vertical/landscape renditions, a watch-time gate). An intro is one file
/// the viewer studies on a loop, so this is the simpler right tool.
///
/// PLAYBACK IS GATED ON VISIBILITY. A looping clip only actually plays when
/// the caller wants it playing AND the app is foreground AND this widget is
/// the visible route. It pauses if the app is backgrounded OR another screen
/// is pushed over it, and resumes only when all three are true again. Without
/// the route half, an intro kept looping its audio underneath whatever you
/// navigated to (heard on a device, 2026-09-16).
class LoopingVideo extends StatefulWidget {
  const LoopingVideo({
    super.key,
    required this.url,
    this.autoPlay = true,
    this.muted = false,
    this.borderRadius = 12,
  });

  final String url;
  final bool autoPlay;
  final bool muted;
  final double borderRadius;

  @override
  State<LoopingVideo> createState() => _LoopingVideoState();
}

class _LoopingVideoState extends State<LoopingVideo>
    with WidgetsBindingObserver, RouteAware {
  VideoPlayerController? _controller;
  bool _ready = false;
  bool _failed = false;

  // The three conditions that must ALL hold for the clip to actually play.
  bool _wantPlaying = false; // the caller's / user's intent
  bool _appForeground = true;
  bool _routeVisible = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ModalRoute<dynamic>? route = ModalRoute.of(context);
    if (route != null) appRouteObserver.subscribe(this, route);
  }

  /// Play only when wanted AND foreground AND the visible route. Any change to
  /// those three funnels through here rather than calling play/pause directly,
  /// so the "resume" case can never fire while the clip is still hidden.
  void _syncPlayback() {
    final c = _controller;
    if (c == null || !_ready) return;
    final shouldPlay = _wantPlaying && _appForeground && _routeVisible;
    if (shouldPlay && !c.value.isPlaying) {
      c.play();
    } else if (!shouldPlay && c.value.isPlaying) {
      c.pause();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appForeground = state == AppLifecycleState.resumed;
    _syncPlayback();
  }

  // RouteAware: another screen pushed over this one -> pause; it popped and
  // we're on top again -> resume (if still wanted and foreground).
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
  void didUpdateWidget(LoopingVideo old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      _controller?.dispose();
      _controller = null;
      _ready = false;
      _failed = false;
      _init();
    }
  }

  Future<void> _init() async {
    final controller = VideoPlayerController.networkUrl(Uri.parse(widget.url));
    _controller = controller;
    try {
      await controller.initialize();
      await controller.setLooping(true);
      if (widget.muted) await controller.setVolume(0);
      if (!mounted) return;
      _wantPlaying = widget.autoPlay;
      _ready = true;
      _syncPlayback();
      setState(() {});
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    appRouteObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  void _toggle() {
    _wantPlaying = !_wantPlaying;
    _syncPlayback();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_failed) {
      return AspectRatio(
        aspectRatio: 9 / 16,
        child: ColoredBox(
          color: scheme.surfaceContainerHighest,
          child: Center(
            child: Text('Video unavailable',
                style: TextStyle(color: scheme.onSurfaceVariant)),
          ),
        ),
      );
    }
    final controller = _controller;
    if (!_ready || controller == null) {
      return const AspectRatio(
        aspectRatio: 9 / 16,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: GestureDetector(
        onTap: _toggle,
        child: AspectRatio(
          aspectRatio: controller.value.aspectRatio == 0
              ? 9 / 16
              : controller.value.aspectRatio,
          child: Stack(
            alignment: Alignment.center,
            children: [
              VideoPlayer(controller),
              if (!controller.value.isPlaying)
                const Icon(Icons.play_circle_fill,
                    size: 56, color: Colors.white70),
            ],
          ),
        ),
      ),
    );
  }
}
