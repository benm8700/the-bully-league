import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../core/services/watch_feed_service.dart';
import '../../widgets/clip_reactions.dart';
import '../moderation/report_screen.dart';
import '../../widgets/live_tally.dart';

/// One battle, full screen. You watch the clip, then pick a winner for EACH
/// round in a panel and CONFIRM - the match goes to whoever won the most
/// rounds (developer's call, 2026-09-17), which forces judges to weigh every
/// round rather than one overall impression.
///
/// The picker unlocks once most of the clip has played, so the final round is
/// seen before you commit. Nothing is cast until Submit; the button names the
/// computed winner. The rendered clip is a fixed vertical stack (player 1 on
/// top), and the round chips are ordered to match (player 1 on the left).
///
/// Playback is manual: it does NOT loop. A small corner button pauses/resumes
/// and replays.
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

  /// Casts a real ballot - a per-round map {roundIndex: winnerId}. False
  /// result means it failed; the page keeps the picks so it can be retried.
  final Future<bool> Function(Map<int, String> picks) onVote;

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

  /// Per-round winner picks (round index -> playerId), before submitting.
  /// The match winner is whoever won the most rounds.
  final Map<int, String> _picks = {};

  /// Set once the vote (or settled-battle call) has actually been submitted -
  /// the computed winner (most rounds won), used by the result box.
  String? _chosenPlayerId;
  bool _submitting = false;

  int get _roundCount => widget.match.roundCount.clamp(1, 12);
  bool get _allPicked => _picks.length >= _roundCount;

  /// Winner by most rounds won, or null on a tie (possible only with an even
  /// round count).
  String? get _computedWinner {
    var p1 = 0;
    var p2 = 0;
    for (final id in _picks.values) {
      if (id == widget.match.player1Id) {
        p1++;
      } else if (id == widget.match.player2Id) {
        p2++;
      }
    }
    if (p1 > p2) return widget.match.player1Id;
    if (p2 > p1) return widget.match.player2Id;
    return null;
  }

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

  /// Pick a winner for one round (green highlight, no vote cast yet).
  void _pickRound(int round, String playerId) {
    if (!_canAct || _chosenPlayerId != null) return;
    setState(() => _picks[round] = playerId);
  }

  /// Confirm all rounds - THIS is where a vote is actually cast. The winner
  /// is whoever won the most rounds.
  void _submit() {
    if (!_allPicked || _submitting) return;
    final winner = _computedWinner;
    if (winner == null) return; // a tie - nothing decisive to submit
    _choose(winner);
  }

  Future<void> _choose(String winnerId) async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _chosenPlayerId = winnerId;
    });
    if (widget.match.canVote) {
      final ok = await widget.onVote(Map<int, String>.from(_picks));
      if (!mounted) return;
      // A failed ballot must not look like a cast one, or the viewer
      // believes they judged a battle they didn't. Keep the picks so they
      // can just hit Submit again.
      if (!ok) setState(() => _chosenPlayerId = null);
    } else if (widget.match.verdict?.outcome == 'decided') {
      // A call on a settled battle. Only worth recording where there was a
      // right answer - a tie has none.
      widget.onCall(widget.match.matchId, winnerId);
    }
    if (mounted) setState(() => _submitting = false);
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final paused = controller != null && !controller.value.isPlaying;
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
            _pickerPanel(context),
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

  /// The per-round picker: a winner for each round, then Submit. The match
  /// goes to whoever won the most rounds (shown on the Submit button). The
  /// top player in the stacked clip is player 1 - the chips are ordered to
  /// match (player 1 on the left).
  Widget _pickerPanel(BuildContext context) {
    final m = widget.match;
    final winner = _computedWinner;
    final winnerName = winner == m.player1Id
        ? m.player1Username
        : winner == m.player2Id
            ? m.player2Username
            : null;
    final label = !_allPicked
        ? 'Pick a winner for every round'
        : winnerName == null
            ? "It's a tie - break it on the last round"
            : m.canVote
                ? 'Submit: $winnerName won'
                : 'Call it: $winnerName';
    return Positioned(
      left: 12,
      right: 12,
      bottom: MediaQuery.of(context).padding.bottom + 64,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Who won each round?',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            for (int r = 0; r < _roundCount; r++) _roundRow(context, r),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 48),
                  backgroundColor: (_allPicked && winner != null)
                      ? _pickGreen
                      : null,
                  foregroundColor: (_allPicked && winner != null)
                      ? Colors.black
                      : null,
                ),
                onPressed: (!_allPicked || winner == null || _submitting)
                    ? null
                    : _submit,
                child: _submitting
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(label,
                        style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _roundRow(BuildContext context, int round) {
    final m = widget.match;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 62,
            child: Text('Round ${round + 1}',
                style: const TextStyle(color: Colors.white70, fontSize: 12)),
          ),
          Expanded(child: _playerChip(round, m.player1Id, m.player1Username)),
          const SizedBox(width: 6),
          Expanded(child: _playerChip(round, m.player2Id, m.player2Username)),
        ],
      ),
    );
  }

  Widget _playerChip(int round, String playerId, String name) {
    final selected = _picks[round] == playerId;
    return GestureDetector(
      onTap: () => _pickRound(round, playerId),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 8),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? _pickGreen : Colors.white.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? _pickGreen : Colors.white24,
          ),
        ),
        child: Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: selected ? Colors.black : Colors.white,
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            fontSize: 13,
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
        ? 'Judge each round'
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
