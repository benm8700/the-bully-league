import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../core/services/clip_cache.dart';
import '../../core/services/watch_feed_service.dart';
import '../../widgets/clip_reactions.dart';
import '../../widgets/follow_button.dart';
import '../moderation/report_screen.dart';
import '../profile/performer_profile_screen.dart';
import '../../widgets/live_tally.dart';

/// One battle, full screen. You watch the clip, then pick the overall winner
/// by TAPPING that roaster's half of the video - the composite is player 1 on
/// top and player 2 on the bottom, so tapping the top or bottom picks them.
/// The picked half gets a green outline; tap the other to switch. (Developer's
/// call, 2026-09-21: one overall winner, chosen on the video box itself,
/// rather than a per-round panel that covered the faces.)
///
/// The Submit panel unlocks once most of the clip has played, so the final
/// round is seen before you commit. Nothing is cast until Submit. A separate
/// optional "best round" tap feeds the Best Rounds board - "who won" and
/// "which round was funniest" are different questions.
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

  /// Casts a real ballot - a per-round map {roundIndex: winnerId}, plus the
  /// optional funniest-round index. False result means it failed; the page
  /// keeps the picks so it can be retried.
  final Future<bool> Function(Map<int, String> picks, int? funniestRound)
      onVote;

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

  /// The single overall winner the judge picked, by tapping that player's
  /// half of the clip. Replaces per-round voting (developer's call): tap the
  /// top or bottom roaster's video to pick the match winner; tap the other to
  /// switch.
  String? _selectedWinner;

  /// Set once the vote (or settled-battle call) has actually been submitted -
  /// the chosen winner, used by the result box.
  String? _chosenPlayerId;
  bool _submitting = false;

  int get _roundCount => widget.match.roundCount.clamp(1, 12);

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

  /// Whether the "Vote for X" pill is currently on screen (a half is picked
  /// and the vote is not yet cast). Used to clear the reactions off the very
  /// bottom edge so the pill can dock there without colliding with them.
  bool get _voteBoxShowing =>
      _selectedWinner != null && _canAct && _chosenPlayerId == null;

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

  /// Jumps back ten seconds so a judge can re-hear a line without hunting.
  /// Resumes playing if the clip had already ended.
  void _rewind() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    final target = c.value.position - const Duration(seconds: 10);
    c.seekTo(target < Duration.zero ? Duration.zero : target);
    if (_ended || !c.value.isPlaying) {
      c.play();
      setState(() => _ended = false);
    }
  }

  Future<void> _load() async {
    final url = widget.match.videoUrl;
    if (url == null || url.isEmpty) {
      setState(() => _failed = true);
      return;
    }
    // Play from a local file when we can, so rewind and scrubbing are instant
    // (a streamed clip re-buffers on every backward seek - ExoPlayer keeps no
    // back-buffer). The feed prefetches ahead, so most clips are already local
    // by the time you reach them. Falls back to streaming if the download OR
    // the file fails to play - a clip must never break because of the cache.
    File? file;
    try {
      file = await ClipCacheService.instance.getFile(url);
    } catch (_) {
      file = null;
    }
    if (!mounted) return;
    if (file != null &&
        await _tryController(VideoPlayerController.file(file))) {
      return;
    }
    if (!mounted) return;
    if (await _tryController(VideoPlayerController.networkUrl(Uri.parse(url)))) {
      return;
    }
    if (mounted) setState(() => _failed = true);
  }

  /// Initializes [controller], wires it up and shows it. Returns true on
  /// success; on failure disposes it and returns false so [_load] can fall
  /// back to the next source (cached file -> network stream).
  Future<bool> _tryController(VideoPlayerController controller) async {
    try {
      await controller.initialize();
      await controller.setLooping(false);
      controller.addListener(_onTick);
      if (!mounted) {
        await controller.dispose();
        return true;
      }
      setState(() => _controller = controller);
      if (widget.isActive) await controller.play();
      return true;
    } catch (_) {
      await controller.dispose();
      return false;
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

  /// Pick the overall winner by tapping their half of the clip. No vote is
  /// cast until Submit; tapping the other player switches the pick.
  void _pickWinner(String playerId) {
    if (!_canAct || _chosenPlayerId != null) return;
    setState(() => _selectedWinner = playerId);
  }

  void _submit() {
    final winner = _selectedWinner;
    if (winner == null || _submitting) return;
    _choose(winner);
  }

  Future<void> _choose(String winnerId) async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _chosenPlayerId = winnerId;
    });
    if (widget.match.canVote) {
      // A single overall winner, sent as the backend's per-round tally ("won
      // every round"). castVote also accepts a bare votedForPlayerId, so
      // either shape is fine; this keeps the onVote signature unchanged.
      final picks = {for (int r = 0; r < _roundCount; r++) r: winnerId};
      final ok = await widget.onVote(picks, null);
      if (!mounted) return;
      // A failed ballot must not look like a cast one. Keep the pick so they
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
          // A subtle top scrim: the feed runs full-bleed under the system
          // status bar, so its icons and the header chip need a dark wash to
          // stay legible over a bright clip.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Container(
                height: MediaQuery.of(context).padding.top + 56,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x99000000), Color(0x00000000)],
                  ),
                ),
              ),
            ),
          ),
          // Tap a roaster's HALF of the clip to pick the overall winner - the
          // selection IS the video box, so nothing covers the faces. Sits
          // under the buttons below (they win their own taps).
          if (_canAct && _chosenPlayerId == null) _winnerSelectLayer(context),
          // (Removed the big center play/replay overlay: it flashed on every
          // rewind seek - the seek briefly pauses the clip - and duplicated the
          // corner play/pause control. The corner buttons and tap-to-pick are
          // the interactions now.)
          if (controller != null) _playPauseButton(context, paused),
          if (controller != null) _rewindButton(context),
          _followButton(context),
          // The compact "Vote for X" pill, docked to the bottom of the
          // selected half - only shown once a half is picked.
          _voteBox(context),
          if (_resultShown) _resultBox(context),
          _header(context),
          _reportButton(context),
          // Sits low and out of the way of both faces. Hidden while a winner
          // is picked so the "Vote for X" pill can dock at the very bottom
          // edge without colliding with the reactions row.
          if (!_voteBoxShowing)
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

  /// The tap-to-pick overlay: two full-height halves over the clip. Tapping
  /// the TOP half picks player 1, the BOTTOM half player 2 (the composite is
  /// player 1 on top). The picked half gets a bright green outline + a "Your
  /// pick" badge; nothing covers the faces. It sits UNDER the corner buttons
  /// and the reactions in the Stack, so those still win their own taps.
  Widget _winnerSelectLayer(BuildContext context) {
    final m = widget.match;
    return Positioned.fill(
      child: Column(
        children: [
          Expanded(child: _selectHalf(top: true, playerId: m.player1Id)),
          Expanded(child: _selectHalf(top: false, playerId: m.player2Id)),
        ],
      ),
    );
  }

  Widget _selectHalf({required bool top, required String playerId}) {
    final selected = _selectedWinner == playerId;
    // JUST the outline - no fill, no glow, no badge (developer's call): the
    // green box must not cover the faces. The selected player's name is
    // confirmed in the Submit panel below.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _pickWinner(playerId),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          border: Border.all(
            color: selected ? _pickGreen : Colors.transparent,
            width: 5,
          ),
        ),
      ),
    );
  }

  /// The compact vote box - appears ONLY once a half is selected, docked to
  /// the bottom edge of THAT half: a top pick sits at the midline seam (the
  /// bottom of the top square), a bottom pick sits at the very bottom (the
  /// bottom of the bottom square). Just a "Vote for X" pill, so it never
  /// blocks the faces or the action.
  Widget _voteBox(BuildContext context) {
    final winner = _selectedWinner;
    if (winner == null || !_canAct || _chosenPlayerId != null) {
      return const SizedBox.shrink();
    }
    final m = widget.match;
    final name = winner == m.player1Id ? m.player1Username : m.player2Username;
    final topSelected = winner == m.player1Id;
    final h = MediaQuery.of(context).size.height;
    final label = m.canVote ? 'Vote for $name' : 'Call it: $name';
    return Positioned(
      left: 0,
      right: 0,
      // Lower on each half: a top pick sits right at the midline seam (the
      // very bottom of the top square), a bottom pick sits just above the
      // reactions at the very bottom.
      bottom: topSelected
          ? h * 0.5 - 30
          : MediaQuery.of(context).padding.bottom + 8,
      child: Center(
        child: FilledButton(
          style: FilledButton.styleFrom(
            // Transparent enough to never hide the clip behind it - the pill
            // sits right at the bottom edge over the video.
            backgroundColor: _pickGreen.withValues(alpha: 0.48),
            foregroundColor: Colors.black,
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
            textStyle:
                const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.black),
                )
              : Text(label),
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

  /// A small rewind-10s control, directly under the play/pause button so the
  /// corner stays a single tidy column - a way to go back without a scrubber
  /// cluttering the clip. Sits BELOW play/pause (top+60) and ABOVE the Follow
  /// button (moved to top+164) so the three corner controls never overlap.
  Widget _rewindButton(BuildContext context) {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 112,
      right: 8,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.5),
          shape: BoxShape.circle,
        ),
        child: IconButton(
          icon: const Icon(Icons.replay_10_rounded, color: Colors.white, size: 22),
          tooltip: 'Rewind 10 seconds',
          onPressed: _rewind,
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

  /// Follow one of the two roasters, right from the feed - the app's primary
  /// content surface, so the place a fan is most likely to discover someone.
  /// A small circular button on the right rail, tucked under play/pause.
  Widget _followButton(BuildContext context) {
    return Positioned(
      // Moved down (was top+112) to make room for the rewind button, so the
      // corner column is report / play-pause / rewind / follow with no overlap.
      top: MediaQuery.of(context).padding.top + 164,
      right: 8,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.5),
          shape: BoxShape.circle,
        ),
        child: IconButton(
          icon: const Icon(Icons.person_add_alt_1,
              color: Colors.white, size: 20),
          tooltip: 'Follow',
          onPressed: () => _openFollow(context),
        ),
      ),
    );
  }

  /// A battle has two people in it, so following asks which - each row opens
  /// their fame page, and follows inline via the Follow pill.
  Future<void> _openFollow(BuildContext context) async {
    final m = widget.match;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                'Follow a roaster',
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
            ),
            for (final p in [
              (id: m.player1Id, name: m.player1Username),
              (id: m.player2Id, name: m.player2Username),
            ])
              ListTile(
                title: Text(p.name),
                trailing: FollowButton(uid: p.id, compact: true),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  PerformerProfileScreen.open(context, p.id, username: p.name);
                },
              ),
          ],
        ),
      ),
    );
  }

  /// A battle has two people in it, so reporting has to ask which.
  Future<void> _openReport(BuildContext context) async {
    final m = widget.match;
    // Pause the clip for the whole report interaction. A battle playing with
    // audio behind a "who are you reporting?" sheet and a report form is
    // jarring and distracting - reporting is a serious action, not a moment to
    // keep the show running. Restored on return if it had been playing.
    final c = _controller;
    final wasPlaying =
        c != null && c.value.isInitialized && c.value.isPlaying;
    if (wasPlaying) {
      await c.pause();
      if (mounted) setState(() {}); // repaint the corner icon to "play"
    }
    if (!context.mounted) return;
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
    if (choice == null || !context.mounted) {
      // Sheet dismissed without choosing - resume if it had been playing and
      // this clip is still the one on screen.
      if (wasPlaying && widget.isActive) {
        _controller?.play();
        if (mounted) setState(() {});
      }
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReportScreen(
          reportedUserId: choice,
          matchId: m.matchId,
        ),
      ),
    );
    // Back from the report screen - restore playback to how they left it.
    if (wasPlaying &&
        widget.isActive &&
        (_controller?.value.isInitialized ?? false)) {
      _controller?.play();
      if (mounted) setState(() {});
    }
  }

  Widget _header(BuildContext context) {
    final m = widget.match;
    final label = m.canVote
        ? 'Tap the winner'
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
