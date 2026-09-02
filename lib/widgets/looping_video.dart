import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// A minimal looping video player for a network URL - used for the
/// mandatory intro video, both as the self-review preview on the profile
/// and as the opponent's "tell me about yourself" during the pre-match
/// reveal (where it is rewatchable ammo). Tap toggles play/pause.
///
/// Deliberately NOT [MatchClipPlayer], which is tailored to match clips
/// (vertical/landscape renditions, a watch-time gate). An intro is one file
/// the viewer studies on a loop, so this is the simpler right tool.
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
    with WidgetsBindingObserver {
  VideoPlayerController? _controller;
  bool _ready = false;
  bool _failed = false;
  bool _wasPlayingBeforeBackground = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  /// Pause when the app leaves the foreground so a looping clip never keeps
  /// playing its audio unattended (a real device looped an intro's audio in
  /// the background - 2026-09-01). Resume only if it was actually playing when
  /// we left, so a deliberate pause is never overridden.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = _controller;
    if (c == null || !_ready) return;
    if (state == AppLifecycleState.resumed) {
      if (_wasPlayingBeforeBackground) c.play();
    } else {
      _wasPlayingBeforeBackground = c.value.isPlaying;
      c.pause();
    }
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
      if (widget.autoPlay) await controller.play();
      if (mounted) setState(() => _ready = true);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
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
        onTap: () => setState(() {
          controller.value.isPlaying ? controller.pause() : controller.play();
        }),
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
