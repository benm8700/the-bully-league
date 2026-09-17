import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../core/services/watch_feed_service.dart';
import '../../widgets/clip_reactions.dart';
import '../moderation/report_screen.dart';
import '../../widgets/live_tally.dart';

/// One battle, full screen. You watch the clip, PRE-SELECT the roaster you
/// think won (a green ring around their camera square), then CONFIRM at the
/// end - rather than casting instantly.
///
/// PICKING IS SPATIAL. The rendered clip is a fixed vertical stack - player 1
/// on top, player 2 underneath - so tapping the top or bottom half picks that
/// person, no names to read (names would clutter the middle of the faces; the
/// name you picked is shown only on the Submit button). The pick is a green
/// ring, not a vote: nothing is cast until you hit Submit, which unlocks once
/// most of the clip has played so the final round is seen first.
///
/// Playback is manual: it does NOT loop. A small corner button pauses/resumes
/// and replays; tapping the video itself picks a roaster.
class FeedPage extends StatefulWidget {
  const FeedPage({
    super.key,
    required this.match,
    required this.isActive,
    required this.onVote,
    required this.onCall,
  });

  final FeedMatch match;

  /// Only the page in view plays. Video decoding is expensive and a
  /// PageView keeps neighbours alive, so without this three clips would be
  /// running at once.
  final bool isActive;

  /// Casts a real ballot. Null result means it failed; the page keeps the
  /// choice visible so it can be retried.
  final Future<bool> Function(String votedForPlayerId) onVote;

  /// Records a call on a SETTLED battle - a private guess against a result
  /// already decided. Never a ballot, and it never touches anyone's rating.
  final void Function(String matchId, String chosenPlayerId) onCall;

  @override
  State<FeedPage> createState() => _FeedPageState();
}

/// Fraction of the clip that must play before Submit unlocks. With the
/// default three rounds this lands inside the final one.
const _revealAfter = 0.65;

/// The green pre-selection ring / confirm accent.
const _pickGreen = Color(0xFF3DDC84);

class _FeedPageState extends State<FeedPage> {
  VideoPlayerController? _controller;
  bool _failed = false;
  double _progress = 0;

  /// True once the clip has played to the end. It does not loop (developer's
  /// call, 2026-09-16), so at the end it holds on the last frame and the corner
  /// button offers a replay.
  bool _ended = false;

  /// The roaster tapped as the likely winner - a green ring, NOT a cast vote.
  String? _preselectedPlayerId;

  /// Set once the vote (or settled-battle call) has actually been submitted.
  String? _chosenPlayerId;
  bool _submitting = false;

  /// Can this viewer act on this battle - cast a real vote, or make a private
  /// "call" on a settled battle with a decisive result? If not (already voted,
  /// a participant watching their own, a tie), there is nothing to pick and it
  /// just shows the video and the tally/verdict.
  bool get _canAct =>
      widget.match.canVote || widget.match.verdict?.outcome == 'decided';

  /// Submit / the result box appear only once most of the clip has played.
  bool get _revealed => _progress >= _revealAfter || _ended || _failed;

  bool get _resultShown =>
      _chosenPlayerId != null || (!_canAct && _revealed);

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
      if (widget.isActive) {
        // Returning to a clip that had finished starts it over rather than
        // sitting frozen on the last frame.
        if (_ended) {
          c.seekTo(Duration.zero);
          _ended = false;
        }
        c.play();
      } else {
        c.pause();
      }
    }
  }

  /// The corner button: pause/resume, or restart once ended. Playback is
  /// manual now - tapping the video picks a roaster instead.
  void _togglePlay() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    final atEnd =
        c.value.position >= c.value.duration - const Duration(milliseconds: 60);
    setState(() {
      if (_ended || atEnd) {
        c.seekTo(Duration.zero);
        c.play();
        _ended = false;
      } else if (c.value.isPlaying) {
        c.pause();
      } else {
        c.play();
      }
    });
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
      await controller.setLooping(false);
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
    final pos = c.value.position.inMilliseconds;
    final next = pos / total;
    final ended = !c.value.isPlaying && pos >= total - 60;
    // Rebuild only when it matters - this fires many times a second.
    if ((next - _progress).abs() > 0.01 || ended != _ended) {
      setState(() {
        _progress = next;
        _ended = ended;
      });
    }
  }

  @override
  void dispose() {
    _controller?.removeListener(_onTick);
    _controller?.dispose();
    super.dispose();
  }

  /// Tapping a roaster's half of the video pre-selects them - a green ring,
  /// switchable, no vote cast yet.
  void _preselect(String id) {
    if (!_canAct || _chosenPlayerId != null) return;
    setState(() => _preselectedPlayerId = id);
  }

  /// Confirm the pre-selected roaster - THIS is where a vote is actually cast.
  void _submit() {
    final id = _preselectedPlayerId;
    if (id == null || _submitting) return;
    _choose(id);
  }

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
      // believes they judged a battle they didn't. Keep the pre-selection so
      // they can just hit Submit again.
      if (!ok) setState(() => _chosenPlayerId = null);
    } else if (widget.match.verdict?.outcome == 'decided') {
      // A call on a settled battle. Only worth recording where there was a
      // right answer - a tie has none.
      widget.onCall(widget.match.matchId, playerId);
    }
    if (mounted) setState(() => _submitting = false);
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final paused = controller != null && !controller.value.isPlaying;
    final ringForPlayer1 = _preselectedPlayerId == widget.match.player1Id;
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (controller != null)
            FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: controller.value.size.width,
                height: controller.value.size.height,
                child: VideoPlayer(controller),
              ),
            )
          else
            Center(
              child: _failed
                  ? const Text('This clip could not be loaded.',
                      style: TextStyle(color: Colors.white70))
                  : const CircularProgressIndicator(),
            ),
          // Green pre-selection ring around the chosen roaster's square.
          if (_canAct && _chosenPlayerId == null && _preselectedPlayerId != null)
            _ring(context, top: ringForPlayer1),
          // Tap zones for picking - whole top half / whole bottom half - while
          // there is still something to pick.
          if (_canAct && _chosenPlayerId == null) ..._pickZones(context),
          // Paused/ended cue, unless the result box is already covering it.
          if (paused && !_resultShown)
            IgnorePointer(
              child: Center(
                child: Icon(
                  _ended ? Icons.replay_rounded : Icons.play_arrow_rounded,
                  size: 64,
                  color: Colors.white.withValues(alpha: 0.6),
                ),
              ),
            ),
          if (controller != null) _playPauseButton(context, paused),
          if (_canAct && _chosenPlayerId == null && _revealed)
            _submitBar(context),
          if (_resultShown) _resultBox(context),
          _header(context),
          _reportButton(context),
          // Sits low and out of the way of both faces, always available.
          Positioned(
            left: 16,
            right: 16,
            bottom: MediaQuery.of(context).padding.bottom + 16,
            child: ClipReactions(
              matchId: widget.match.matchId,
              counts: widget.match.reactionCounts,
            ),
          ),
        ],
      ),
    );
  }

  /// Two full-height tap targets, top and bottom, matching the stacked render.
  /// No labels - names would sit over the faces; the picked name shows on the
  /// Submit button instead.
  List<Widget> _pickZones(BuildContext context) {
    final m = widget.match;
    final half = MediaQuery.of(context).size.height / 2;
    return [
      Positioned(
        top: 0,
        left: 0,
        right: 0,
        height: half,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _preselect(m.player1Id),
        ),
      ),
      Positioned(
        bottom: 0,
        left: 0,
        right: 0,
        height: half,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _preselect(m.player2Id),
        ),
      ),
    ];
  }

  Widget _ring(BuildContext context, {required bool top}) {
    final half = MediaQuery.of(context).size.height / 2;
    return Positioned(
      top: top ? 0 : half,
      left: 0,
      right: 0,
      height: half,
      child: IgnorePointer(
        child: Container(
          margin: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            border: Border.all(color: _pickGreen, width: 4),
            borderRadius: BorderRadius.circular(18),
            boxShadow: [
              BoxShadow(color: _pickGreen.withValues(alpha: 0.4), blurRadius: 12),
            ],
          ),
        ),
      ),
    );
  }

  /// A small circular play/pause/replay control, tucked top-right under the
  /// report button so it never covers a face or the reactions.
  Widget _playPauseButton(BuildContext context, bool paused) {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 60,
      right: 8,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.5),
          shape: BoxShape.circle,
        ),
        child: IconButton(
          icon: Icon(
            _ended
                ? Icons.replay_rounded
                : paused
                    ? Icons.play_arrow_rounded
                    : Icons.pause_rounded,
            color: Colors.white,
            size: 22,
          ),
          tooltip: paused ? 'Play' : 'Pause',
          onPressed: _togglePlay,
        ),
      ),
    );
  }

  /// The confirm bar: disabled with a hint until a roaster is picked, then it
  /// names the pick - the ONLY place a name appears on this screen.
  Widget _submitBar(BuildContext context) {
    final m = widget.match;
    final picked = _preselectedPlayerId;
    final name = picked == m.player1Id
        ? m.player1Username
        : picked == m.player2Id
            ? m.player2Username
            : null;
    final label = name == null
        ? 'Tap a roaster to pick a winner'
        : m.canVote
            ? 'Submit: $name won'
            : 'Call it: $name';
    return Positioned(
      left: 24,
      right: 24,
      bottom: MediaQuery.of(context).padding.bottom + 84,
      child: FilledButton(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 52),
          backgroundColor: name == null ? null : _pickGreen,
          foregroundColor: name == null ? null : Colors.black,
        ),
        onPressed: (picked == null || _submitting) ? null : _submit,
        child: _submitting
            ? const SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
      ),
    );
  }

  /// After submitting (or, for a battle you cannot act on, once revealed): the
  /// confirmation, and where allowed the live tally / verdict.
  Widget _resultBox(BuildContext context) {
    final v = widget.match.verdict;
    String line;
    if (widget.match.canVote) {
      line = _submitting ? 'Casting your vote...' : 'Judged. Swipe for the next one.';
    } else if (v == null && widget.match.windowOpen) {
      line = widget.match.isParticipant
          ? 'Your battle is still with the crowd.'
          : 'You judged this one. Still being decided.';
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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                line,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
              if (widget.match.windowOpen &&
                  (widget.match.alreadyVoted || widget.match.isParticipant)) ...[
                const SizedBox(height: 12),
                LiveTally(
                  matchId: widget.match.matchId,
                  player1Name: widget.match.player1Username,
                  player2Name: widget.match.player2Username,
                ),
              ],
            ],
          ),
        ),
    );
  }

  /// Flagging a battle from the feed. REQUIRED for Apple's Guideline 1.2 -
  /// this feed is the app's primary content surface, so a reviewer must be
  /// able to report from here. Deliberately quiet: a small icon, since harsh
  /// roasting is expected and not itself reportable.
  Widget _reportButton(BuildContext context) {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 8,
      right: 8,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.5),
          shape: BoxShape.circle,
        ),
        child: IconButton(
          icon: const Icon(Icons.flag_outlined, color: Colors.white, size: 20),
          tooltip: 'Report',
          onPressed: () => _openReport(context),
        ),
      ),
    );
  }

  /// A battle has two people in it, so reporting has to ask which.
  Future<void> _openReport(BuildContext context) async {
    final m = widget.match;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                'Who are you reporting?',
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
            ),
            ListTile(
              title: Text(m.player1Username),
              onTap: () => Navigator.of(sheetContext).pop(m.player1Id),
            ),
            ListTile(
              title: Text(m.player2Username),
              onTap: () => Navigator.of(sheetContext).pop(m.player2Id),
            ),
            TextButton(
              onPressed: () => Navigator.of(sheetContext).pop(),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReportScreen(
          reportedUserId: choice,
          matchId: m.matchId,
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final m = widget.match;
    final label = m.canVote
        ? 'Tap who won'
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
