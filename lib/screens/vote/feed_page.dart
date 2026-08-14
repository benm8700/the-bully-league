import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../core/services/watch_feed_service.dart';

/// One battle, full screen, with the choice laid over the players' faces.
///
/// THE CHOICE SITS ON THE VIDEO, not in a list below it. The rendered clip
/// is a fixed vertical stack - player 1 on top, player 2 underneath - so
/// tapping a half is unambiguous. The screen this replaced listed usernames
/// as buttons, which asked someone who had just watched two minutes of a
/// stranger to remember which name went with which face. Tapping the person
/// is spatial rather than nominal, and needs no memory at all.
///
/// The choice appears only once most of the clip has played, so the last
/// round is seen before anyone commits. Round boundaries aren't recorded in
/// the render - only the raw match knows them - so this is a fraction of
/// duration, which with the default three rounds lands in the final one.
class FeedPage extends StatefulWidget {
  const FeedPage({
    super.key,
    required this.match,
    required this.isActive,
    required this.onVote,
  });

  final FeedMatch match;

  /// Only the page in view plays. Video decoding is expensive and a
  /// PageView keeps neighbours alive, so without this three clips would be
  /// running at once.
  final bool isActive;

  /// Casts a real ballot. Null result means it failed; the page keeps the
  /// choice visible so it can be retried.
  final Future<bool> Function(String votedForPlayerId) onVote;

  @override
  State<FeedPage> createState() => _FeedPageState();
}

/// Fraction of the clip that must play before the choice appears. With the
/// default three rounds this lands inside the final one.
const _revealAfter = 0.65;

class _FeedPageState extends State<FeedPage> {
  VideoPlayerController? _controller;
  bool _failed = false;
  double _progress = 0;

  /// Set once this viewer has picked, whether that was a real ballot or a
  /// private call on a settled match.
  String? _chosenPlayerId;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(FeedPage old) {
    super.didUpdateWidget(old);
    if (old.isActive != widget.isActive) {
      final c = _controller;
      if (c == null) return;
      widget.isActive ? c.play() : c.pause();
    }
  }

  Future<void> _load() async {
    final url = widget.match.videoUrl;
    if (url == null || url.isEmpty) {
      setState(() => _failed = true);
      return;
    }
    final controller = VideoPlayerController.networkUrl(Uri.parse(url));
    try {
      await controller.initialize();
      await controller.setLooping(true);
      controller.addListener(_onTick);
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _controller = controller);
      if (widget.isActive) await controller.play();
    } catch (_) {
      await controller.dispose();
      if (mounted) setState(() => _failed = true);
    }
  }

  void _onTick() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    final total = c.value.duration.inMilliseconds;
    if (total <= 0) return;
    final next = c.value.position.inMilliseconds / total;
    // Rebuild only when it matters - this fires many times a second.
    if ((next - _progress).abs() > 0.01) {
      setState(() => _progress = next);
    }
  }

  @override
  void dispose() {
    _controller?.removeListener(_onTick);
    _controller?.dispose();
    super.dispose();
  }

  bool get _choiceVisible =>
      _chosenPlayerId == null && (_progress >= _revealAfter || _failed);

  Future<void> _choose(String playerId) async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _chosenPlayerId = playerId;
    });
    if (widget.match.canVote) {
      final ok = await widget.onVote(playerId);
      if (!mounted) return;
      // A failed ballot must not look like a cast one, or the viewer
      // believes they judged a battle they didn't.
      if (!ok) setState(() => _chosenPlayerId = null);
    }
    if (mounted) setState(() => _submitting = false);
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_controller != null)
            FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: _controller!.value.size.width,
                height: _controller!.value.size.height,
                child: VideoPlayer(_controller!),
              ),
            )
          else
            Center(
              child: _failed
                  ? const Text('This clip could not be loaded.',
                      style: TextStyle(color: Colors.white70))
                  : const CircularProgressIndicator(),
            ),
          if (_choiceVisible) ..._choiceOverlay(context),
          if (_chosenPlayerId != null) _afterChoice(context),
          _header(context),
        ],
      ),
    );
  }

  /// One tap target per player, each covering that player's half of the
  /// frame, matching the stacked layout of the render itself.
  List<Widget> _choiceOverlay(BuildContext context) {
    final m = widget.match;
    return [
      Positioned(
        top: 0, left: 0, right: 0, bottom: null,
        height: MediaQuery.of(context).size.height / 2,
        child: _half(m.player1Username, () => _choose(m.player1Id), true),
      ),
      Positioned(
        bottom: 0, left: 0, right: 0,
        height: MediaQuery.of(context).size.height / 2,
        child: _half(m.player2Username, () => _choose(m.player2Id), false),
      ),
    ];
  }

  Widget _half(String name, VoidCallback onTap, bool top) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Align(
        alignment: top ? Alignment.bottomCenter : Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: Colors.white24),
            ),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              child: Text(
                widget.match.canVote ? '$name won' : 'Call it: $name',
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// After a pick: for an open match, confirmation. For a settled one, the
  /// verdict, and whether the crowd agreed.
  Widget _afterChoice(BuildContext context) {
    final v = widget.match.verdict;
    String line;
    if (widget.match.canVote) {
      line = _submitting ? 'Casting your vote...' : 'Judged. Swipe for the next one.';
    } else if (v == null || v.outcome == 'undecided') {
      line = 'Nobody judged this one.';
    } else if (v.outcome == 'tie') {
      line = 'The crowd tied it.';
    } else {
      final agreed = v.winnerId == _chosenPlayerId;
      final winner = v.winnerId == widget.match.player1Id
          ? widget.match.player1Username
          : widget.match.player2Username;
      final share = (v.winnerId == widget.match.player1Id
              ? v.player1Share
              : 1 - v.player1Share) *
          100;
      line = '${agreed ? "You agreed with the crowd." : "The crowd disagreed."}\n'
          '$winner took it with ${share.round()}%.';
    }

    return Align(
      alignment: Alignment.center,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 32),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.75),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          line,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final m = widget.match;
    final label = m.canVote
        ? 'Who won?'
        : m.isParticipant
            ? 'Your battle'
            : '${m.voteCount} ${m.voteCount == 1 ? "vote" : "votes"}';
    return Positioned(
      top: MediaQuery.of(context).padding.top + 8,
      left: 16,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(label,
              style: const TextStyle(color: Colors.white, fontSize: 12)),
        ),
      ),
    );
  }
}
