import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../core/emoji_ratings.dart';
import '../../core/services/clip_cache.dart';
import '../../core/services/follows_service.dart';
import '../../core/services/watch_feed_service.dart';
import '../../theme/house_theme.dart';
import '../../widgets/match/watch_strip.dart';
import '../moderation/report_screen.dart';
import '../profile/performer_profile_screen.dart';
import '../../widgets/live_tally.dart';
import '../../widgets/neon_dialog.dart';
import '../../widgets/neon_note.dart';
import '../../widgets/player_avatar.dart';

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
    this.watchedToEnd = false,
    this.onWatchedToEnd,
    required this.onVote,
    required this.onCall,
  });

  final FeedMatch match;

  /// Only the page in view plays. Video decoding is expensive and a
  /// PageView keeps neighbours alive, so without this three clips would be
  /// running at once.
  final bool isActive;

  /// Already watched to the end earlier this session (the page was rebuilt,
  /// e.g. swiping back to retry a failed vote) - voting is open straight away.
  final bool watchedToEnd;
  final VoidCallback? onWatchedToEnd;

  /// Casts a real ballot - a per-round map {roundIndex: winnerId}, plus the
  /// required per-player emoji ratings {playerId: emojiKey}. False result means
  /// it failed; the page keeps the picks so it can be retried.
  final Future<bool> Function(
    Map<int, String> picks,
    Map<String, String> emojiRatings,
  )
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

/// Gap between the bottom edge and the bottom overlays. The Judge feed has
/// no scrubber (developer, 2026-11-18: judges watch it once, through - a
/// scrubber let them drag to the end to unlock the vote, and took space
/// from the faces). It plays once, holds the last frame, offers a replay.
const _scrubH = 12.0;

/// Half the burned-in clip strip's height as a fraction of the clip height
/// (55px of 1920), measured from the seam: the picked half's outline sits
/// right on the video's edge where it meets the strip.
const _stripHalfFraction = 55 / 1920;

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

  // The emoji rating boxes only come up once the battle has been watched to
  // the END, and step aside while it plays again (developer, 2026-11-17).
  late bool _seenEnd = widget.watchedToEnd;
  bool _playing = false;

  /// The single overall winner the judge picked, by tapping that player's
  /// half of the clip. Replaces per-round voting (developer's call): tap the
  /// top or bottom roaster's video to pick the match winner; tap the other to
  /// switch.
  String? _selectedWinner;

  /// Set once the vote (or settled-battle call) has actually been submitted -
  /// the chosen winner, used by the result box.
  String? _chosenPlayerId;
  bool _submitting = false;

  /// The emoji rating the judge picks for each player after choosing the
  /// winner (required for a real ballot). Keyed by nothing here - just the two
  /// slots, filled from the emoji panel.
  String? _emojiP1;
  String? _emojiP2;

  int get _roundCount => widget.match.roundCount.clamp(1, 12);

  /// Face-Off (improv): a blind simultaneous prompt battle. Its clip plays one
  /// performer's whole set then the other's (sequential, full-frame, red then
  /// blue gel border), so the tap-top/tap-bottom winner pick and the
  /// pinned-to-half emoji bars don't apply - it gets explicit winner buttons
  /// and a combined emoji panel instead.
  bool get _isImprov => widget.match.mode == 'improv';

  /// Can this viewer act on this battle - cast a real vote, or make a private
  /// "call" on a settled battle with a decisive result? If not (already voted,
  /// a participant watching their own, a tie), there is nothing to pick and it
  /// just shows the video and the tally/verdict.
  bool get _canAct =>
      widget.match.canVote || widget.match.verdict?.outcome == 'decided';

  /// Submit / the result box appear only once most of the clip has played.
  bool get _revealed => _watchedFraction >= _revealAfter || _failed;

  /// Milliseconds of the clip actually PLAYED (forward playback only), so
  /// dragging the scrubber to the end cannot unlock Submit without watching.
  int _watchedMs = 0;
  int? _lastPosMs;

  double get _watchedFraction {
    final total = _controller?.value.duration.inMilliseconds ?? 0;
    return total <= 0 ? 0 : _watchedMs / total;
  }

  bool get _resultShown => _chosenPlayerId != null || (!_canAct && _revealed);

  @override
  void initState() {
    super.initState();
    _load();
    _loadPhotos();
    _watchFollows();
  }

  // Each roaster's battle-card selfie, for the tappable pictures on the
  // clip (index 0 = player 1 / top, 1 = player 2 / bottom).
  final List<String?> _photos = [null, null];

  // The follow bubble (developer, 2026-11-18): tapping a roaster's picture
  // opens a small card beside it - Follow right there, or View profile.
  final _follows = FollowsService();
  final List<bool> _following = [false, false];
  final List<StreamSubscription<bool>> _followSubs = [];

  void _watchFollows() {
    final ids = [widget.match.player1Id, widget.match.player2Id];
    for (var i = 0; i < 2; i++) {
      _followSubs.add(
        _follows.isFollowing(ids[i]).listen((f) {
          if (mounted && _following[i] != f) {
            setState(() => _following[i] = f);
          }
        }, onError: (_) {}),
      );
    }
  }

  int? _bubbleFor;
  Timer? _bubbleClose;

  void _closeBubble() {
    _bubbleClose?.cancel();
    if (_bubbleFor != null && mounted) setState(() => _bubbleFor = null);
  }

  bool _followBusy = false;

  Future<void> _toggleFollow(String uid, bool following) async {
    if (_followBusy) return;
    _followBusy = true;
    _bubbleClose?.cancel();
    try {
      if (following) {
        await _follows.unfollow(uid);
      } else {
        await _follows.follow(uid);
        // Let the "Following" state show for a beat, then tidy away.
        _bubbleClose = Timer(const Duration(milliseconds: 1100), _closeBubble);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't update that. Try again.")),
        );
      }
    } finally {
      _followBusy = false;
    }
  }

  Future<void> _loadPhotos() async {
    final m = widget.match;
    final db = FirebaseFirestore.instance;
    try {
      final snaps = await Future.wait([
        db.collection('users').doc(m.player1Id).get(),
        db.collection('users').doc(m.player2Id).get(),
      ]);
      String? photo(DocumentSnapshot<Map<String, dynamic>> s) {
        final profile = s.data()?['profile'] as Map?;
        final face = profile?['facePhotoUrl'];
        if (face is String && face.isNotEmpty) return face;
        final list = profile?['photoUrls'];
        return list is List && list.isNotEmpty ? list.first as String? : null;
      }

      if (!mounted) return;
      setState(() {
        _photos[0] = photo(snaps[0]);
        _photos[1] = photo(snaps[1]);
      });
    } catch (_) {
      // No pictures: the initials fallback still shows and still taps.
    }
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

  Future<void> _load() async {
    final url = widget.match.videoUrl;
    if (url == null || url.isEmpty) {
      setState(() => _failed = true);
      return;
    }
    // Play from a local file if this clip is ALREADY cached - then rewind and
    // scrubbing are instant (a streamed clip re-buffers on every backward seek,
    // since ExoPlayer keeps no back-buffer). If it is not cached yet, stream it
    // now for an instant start rather than waiting on a download; the feed
    // prefetches ahead, so the clips you swipe to next are already local. Falls
    // back to streaming if file playback fails - a clip never breaks on the
    // cache.
    File? file;
    try {
      file = await ClipCacheService.instance.readyFile(url);
    } catch (_) {
      file = null;
    }
    if (!mounted) return;
    if (file != null &&
        await _tryController(VideoPlayerController.file(file))) {
      return;
    }
    if (!mounted) return;
    if (await _tryController(
      VideoPlayerController.networkUrl(Uri.parse(url)),
    )) {
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
    final last = _lastPosMs;
    if (c.value.isPlaying && last != null) {
      final d = pos - last;
      // Normal playback advances a few hundred ms per tick; anything bigger
      // (or backwards) is a seek and earns no watch time.
      if (d > 0 && d < 1500) _watchedMs += d;
    }
    _lastPosMs = pos;
    final next = pos / total;
    final ended = !c.value.isPlaying && pos >= total - 60;
    final playing = c.value.isPlaying;
    // Rebuild only when it matters - this fires many times a second.
    if ((next - _progress).abs() > 0.01 ||
        ended != _ended ||
        playing != _playing ||
        (ended && !_seenEnd)) {
      setState(() {
        _progress = next;
        _ended = ended;
        _playing = playing;
        if (ended && !_seenEnd) {
          _seenEnd = true;
          widget.onWatchedToEnd?.call();
        }
      });
    }
  }

  bool _heldPause = false;

  void _holdPause() {
    final c = _controller;
    if (c == null || !c.value.isInitialized || !c.value.isPlaying) return;
    _heldPause = true;
    c.pause();
  }

  void _holdResume() {
    if (!_heldPause) return;
    _heldPause = false;
    if (mounted && widget.isActive) _controller?.play();
  }

  @override
  void dispose() {
    _bubbleClose?.cancel();
    for (final sub in _followSubs) {
      sub.cancel();
    }
    _controller?.removeListener(_onTick);
    _controller?.dispose();
    super.dispose();
  }

  /// Pick the overall winner by tapping their half of the clip. No vote is
  /// cast until Submit; tapping the other player switches the pick.
  void _pickWinner(String playerId) {
    if (!_canAct || _chosenPlayerId != null) return;
    // Tapping the already-picked roaster again UNSELECTS, collapsing the emoji
    // bars + submit bar back to the clean watching state. Tapping the other
    // roaster switches the pick.
    setState(
      () => _selectedWinner = _selectedWinner == playerId ? null : playerId,
    );
  }

  /// Face-Off winner pick: select (switchable), never toggle-off - the pick
  /// comes from an explicit button, so re-tapping the chosen one should keep
  /// it, not clear it.
  void _selectWinner(String playerId) {
    if (!_canAct || _chosenPlayerId != null) return;
    setState(() => _selectedWinner = playerId);
  }

  /// The whole Face-Off vote flow, in one bottom panel over the sequential
  /// clip:
  ///   1. before most of the clip has played: a quiet "watch both sets" hint;
  ///   2. revealed, no winner yet: "Who was funnier?" + a red P1 / blue P2
  ///      button (the gel colours match the clip's borders);
  ///   3. winner picked, open ballot: both emoji rows + a Submit bar gated on
  ///      rating both;
  ///   4. winner picked, settled battle: a "Call it" button (no rating).
  Widget _improvVotePanel(BuildContext context) {
    final m = widget.match;
    final insetBottom = MediaQuery.of(context).padding.bottom;
    final winner = _selectedWinner;

    // Still watching - a quiet, non-blocking nudge, nothing to tap yet.
    if (!_revealed) {
      return Positioned(
        left: 0,
        right: 0,
        bottom: insetBottom + _scrubH + 8,
        child: IgnorePointer(
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Text(
                'Watch both sets, then vote',
                style: TextStyle(color: Colors.white, fontSize: 13),
              ),
            ),
          ),
        ),
      );
    }

    return Positioned(
      left: 0,
      right: 0,
      bottom: insetBottom + _scrubH,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0x00000000), Color(0xCC000000)],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Who was funnier?',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _improvWinnerButton(
                    m.player1Id,
                    m.player1Username,
                    House.gelRed,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _improvWinnerButton(
                    m.player2Id,
                    m.player2Username,
                    House.gelBlue,
                  ),
                ),
              ],
            ),
            // Open ballot: once a winner is chosen, rate both, then submit.
            if (m.canVote && winner != null) ...[
              const SizedBox(height: 14),
              _improvEmojiRow(
                m.player1Username,
                _emojiP1,
                (k) => setState(() => _emojiP1 = k),
                House.gelRed,
              ),
              const SizedBox(height: 8),
              _improvEmojiRow(
                m.player2Username,
                _emojiP2,
                (k) => setState(() => _emojiP2 = k),
                House.gelBlue,
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: _pickGreen.withValues(alpha: 0.9),
                    foregroundColor: Colors.black,
                    disabledBackgroundColor: Colors.white.withValues(
                      alpha: 0.14,
                    ),
                    disabledForegroundColor: Colors.white70,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    textStyle: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  onPressed: _submitting ? null : _submit,
                  child: _submitting
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.black,
                          ),
                        )
                      : const Text('Vote'),
                ),
              ),
            ],
            // Settled battle: a private "call", no rating.
            if (!m.canVote && winner != null) ...[
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: _pickGreen.withValues(alpha: 0.48),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    textStyle: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  onPressed: _submitting ? null : _submit,
                  child: Text(
                    'Call it: '
                    '${winner == m.player1Id ? m.player1Username : m.player2Username}',
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// One of the two Face-Off winner buttons. Filled in that performer's gel
  /// colour when chosen, outlined otherwise - the same red/blue used on the
  /// clip's border, so "the red one" is unambiguous.
  Widget _improvWinnerButton(String playerId, String name, Color gel) {
    final selected = _selectedWinner == playerId;
    return GestureDetector(
      onTap: () => _selectWinner(playerId),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
        decoration: BoxDecoration(
          color: selected ? gel : Colors.black.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: gel, width: 2),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (selected)
              const Padding(
                padding: EdgeInsets.only(right: 6),
                child: Icon(Icons.check_circle, color: Colors.white, size: 18),
              ),
            Flexible(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// A compact "Rating for {name}" + four emoji row, for the Face-Off panel.
  /// Same choices as the stacked-clip emoji bar, laid out inline rather than
  /// pinned to a half of the video.
  Widget _improvEmojiRow(
    String name,
    String? selected,
    ValueChanged<String> onSelect,
    Color accent,
  ) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 7),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent.withValues(alpha: 0.9), width: 1.5),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: accent,
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          for (final r in kEmojiRatings)
            GestureDetector(
              onTap: () => onSelect(r.key),
              child: Container(
                margin: const EdgeInsets.only(left: 6),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: selected == r.key
                      ? accent.withValues(alpha: 0.9)
                      : Colors.white.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(r.emoji, style: const TextStyle(fontSize: 19)),
              ),
            ),
        ],
      ),
    );
  }

  void _submit() {
    final winner = _selectedWinner;
    if (winner == null || _submitting) return;
    // Emoji ratings are optional (developer, 2026-11-18); a real ballot only
    // waits for the clip to have played to the end.
    if (widget.match.canVote && !(_seenEnd || _isImprov)) return;
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
      // every round"), plus the required per-player emoji ratings.
      final picks = {for (int r = 0; r < _roundCount; r++) r: winnerId};
      final emojiRatings = {
        widget.match.player1Id: ?_emojiP1,
        widget.match.player2Id: ?_emojiP2,
      };
      final ok = await widget.onVote(picks, emojiRatings);
      if (!mounted) return;
      // A failed ballot must not look like a cast one. Keep the pick so they
      // can just hit Submit again.
      if (!ok) setState(() => _chosenPlayerId = null);
    } else if (widget.match.verdict?.outcome == 'decided') {
      // A call on a settled battle. Only worth recording where there was a
      // right answer - a tie has none. No emoji rating on a settled call.
      widget.onCall(widget.match.matchId, winnerId);
    }
    if (mounted) setState(() => _submitting = false);
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    // Hold anywhere on the clip to pause, let go to carry on (developer,
    // 2026-11-18) - a quick tap still picks the winner. On the outermost
    // widget so it sees presses over every layer.
    return GestureDetector(
      onLongPressStart: (_) => _holdPause(),
      onLongPressEnd: (_) => _holdResume(),
      onLongPressCancel: _holdResume,
      child: ColoredBox(
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
                    ? const Text(
                        'This clip could not be loaded.',
                        style: TextStyle(color: Colors.white70),
                      )
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
            // under the buttons below (they win their own taps). FACE-OFF skips
            // this: its clip is SEQUENTIAL (one full-frame set then the other),
            // so there are no top/bottom halves to tap - it uses explicit
            // red/blue winner buttons in the panel below instead.
            if (!_isImprov && _canAct && _chosenPlayerId == null)
              _winnerSelectLayer(context),
            // The roasters' pictures, on top of the pick layer so a tap opens
            // the name + Follow card instead of picking a winner.
            // Only once the clip is showing - never floating on a black screen.
            if (!_isImprov &&
                controller != null &&
                controller.value.isInitialized)
              _playerPictures(context),
            // Replay, only once the clip has played to the end (no scrubber
            // here, see _scrubH). Bottom-right, clear of the Vote pill.
            if (controller != null && _ended)
              Positioned(
                right: 12,
                bottom: MediaQuery.of(context).padding.bottom + _scrubH,
                child: _ReplayButton(
                  onTap: () {
                    controller.seekTo(Duration.zero);
                    controller.play();
                    setState(() => _ended = false);
                  },
                ),
              ),
            // The compact winner-confirm + Submit pill, once a half is picked.
            // Face-Off uses its own bottom panel (sequential clip, explicit
            // winner buttons) instead of the tap-the-half flow.
            if (!_isImprov) _voteBox(context),
            if (_isImprov && _canAct && _chosenPlayerId == null)
              _improvVotePanel(context),
            if (_resultShown) _resultBox(context),
            _header(context),
            // Only while judging (canVote hides the top-left _header, so no
            // overlap); on an archive clip the vote-count chip takes that corner.
            if (widget.match.canVote && _chosenPlayerId == null)
              _kindBadge(context),
            _stripReportFlag(context),
          ],
        ),
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
      child: LayoutBuilder(
        builder: (context, c) {
          // The clip strip is burned into the clip on the seam (~5.7% of
          // the height, cover-centred like the clip). The picked half's
          // outline stops short of it, so it never draws through the
          // clock, logo and round (developer, 2026-11-17). The whole half
          // stays tappable - only the outline is inset.
          final gap = c.maxHeight * _stripHalfFraction;
          return Column(
            children: [
              Expanded(
                child: _selectHalf(
                  top: true,
                  playerId: m.player1Id,
                  seamGap: gap,
                ),
              ),
              Expanded(
                child: _selectHalf(
                  top: false,
                  playerId: m.player2Id,
                  seamGap: gap,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _selectHalf({
    required bool top,
    required String playerId,
    double seamGap = 0,
  }) {
    final selected = _selectedWinner == playerId;
    // The picked player's own stage gel (top = player 1 = red, bottom =
    // player 2 = blue), so the pick carries the same colour used on the emoji
    // bars, tally and judges' table. The outline plus a small "<name> WINS" pill at
    // the top-centre of the picked half (developer, 2026-11-09: while rating
    // emojis a judge must be able to SEE the pick is still the right person).
    // No fill - it must not cover the faces.
    // Just the outline now: the picked name lives on the Vote button at the
    // bottom ("VOTE FOR <name>", developer 2026-11-18).
    final color = top ? House.gelRed : House.gelBlue;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _pickWinner(playerId),
      child: Padding(
        padding: EdgeInsets.only(
          bottom: top ? seamGap : 0,
          top: top ? 0 : seamGap,
        ),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            border: Border.all(
              color: selected ? color : Colors.transparent,
              width: 5,
            ),
          ),
        ),
      ),
    );
  }

  /// The bottom action, which changes with the flow so the screen only ever
  /// shows what is relevant:
  ///  - BEFORE a winner is picked: a quiet, non-blocking "Tap the winner"
  ///    hint (the clean watching state has no emoji bars);
  ///  - AFTER a pick: a DOCKED full-width submit bar whose LABEL is the prompt
  ///    ("Rate both to submit" -> "Submit vote"), so there is no separate
  ///    "please rate" copy and the emoji bars above it stay clear;
  ///  - on a SETTLED battle: a compact "Call it" pill (no rating step).
  Widget _voteBox(BuildContext context) {
    if (!_canAct || _chosenPlayerId != null) return const SizedBox.shrink();
    final m = widget.match;
    final winner = _selectedWinner;
    final insetBottom = MediaQuery.of(context).padding.bottom;

    // Nothing picked: nothing shown (developer, 2026-11-18: no "Tap the
    // winner" prompt - picking a half is obvious). Also stepped aside while
    // a follow bubble is open, which it would otherwise cover.
    if (winner == null || _bubbleFor != null) return const SizedBox.shrink();

    final isP1 = winner == m.player1Id;
    final name = isP1 ? m.player1Username : m.player2Username;
    final color = isP1 ? House.gelRed : House.gelBlue;

    // Settled battle: a private "call" on a decided result, no emoji rating.
    // Open ballot: votable once the clip has played to the end (emoji ratings
    // are optional); until then the pill shows greyed with a short line.
    final ready = !m.canVote || _seenEnd;
    final hint = ready ? null : 'Voting opens when the battle ends';
    final screen = MediaQuery.sizeOf(context);
    final map = _ClipMap(screen);
    return Positioned(
      left: 0,
      right: 0,
      // At the bottom of the PICKED roaster's half (developer, 2026-11-18):
      // for the top player just above their picture + emoji row (which hug
      // the strip), for the bottom one above the scrubber.
      bottom: isP1
          ? screen.height - map.y(960 - 55 - _kAvatarGap - _kAvatarD) + 10
          : insetBottom + _scrubH + 6,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hint != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                hint,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.75),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  shadows: const [Shadow(color: Colors.black, blurRadius: 6)],
                ),
              ),
            ),
          _VotePill(
            label: m.canVote ? 'Vote for $name' : 'Call it: $name',
            color: color,
            enabled: ready && !_submitting,
            onTap: _submit,
          ),
        ],
      ),
    );
  }

  /// After submitting (or, for a battle you cannot act on, once revealed): the
  /// confirmation, and where allowed the live tally / verdict.
  Widget _resultBox(BuildContext context) {
    final m = widget.match;
    final v = m.verdict;
    String title;
    String? message;
    IconData icon = Icons.check_rounded;
    Color accent = NeonNote.judgeGreen;
    if (m.canVote) {
      title = 'Judged';
      message = 'Swipe for the next one.';
    } else if (v == null && m.windowOpen) {
      if (m.isParticipant) {
        title = 'Your battle';
        message = 'Still with the crowd.';
        icon = Icons.hourglass_top_rounded;
        accent = NeonNote.pink;
      } else {
        title = 'You judged this one';
        message = 'Still being decided.';
        icon = Icons.hourglass_top_rounded;
      }
    } else if (v == null || v.outcome == 'undecided') {
      title = 'No verdict';
      message = 'Nobody judged this one.';
      icon = Icons.remove_rounded;
    } else if (v.outcome == 'tie') {
      title = 'Dead even';
      message = 'The crowd tied it.';
      icon = Icons.balance_rounded;
    } else {
      final agreed = v.winnerId == _chosenPlayerId;
      final winner = v.winnerId == m.player1Id
          ? m.player1Username
          : m.player2Username;
      final share =
          (v.winnerId == m.player1Id ? v.player1Share : 1 - v.player1Share) *
          100;
      title = agreed ? 'You called it' : 'Crowd disagreed';
      message = '$winner took it with ${share.round()}%.';
      icon = agreed ? Icons.check_rounded : Icons.close_rounded;
      accent = agreed ? NeonNote.judgeGreen : NeonNote.pink;
    }

    // Low on the screen and see-through to taps (developer, 2026-11-18):
    // centred, it sat right over both players' pictures, so a judge could
    // no longer open a profile to follow someone after voting.
    return Positioned(
      left: 16,
      right: 16,
      bottom: MediaQuery.of(context).padding.bottom + 72,
      child: IgnorePointer(
        child: Center(
          child: NeonNote(
            title: title,
            message: message,
            icon: icon,
            accent: accent,
            // The vote split is for the two roasters only - judges just
            // keep judging (developer, 2026-11-18).
            child: m.windowOpen && m.isParticipant
                ? LiveTally(
                    matchId: m.matchId,
                    player1Name: m.player1Username,
                    player2Name: m.player2Username,
                  )
                : null,
          ),
        ),
      ),
    );
  }

  /// THE ROASTERS' PICTURES (developer, 2026-11-17 - replaced the burned-in
  /// names and the follow button). The clip has each player's selfie burned
  /// in at the far left beside the strip, with a ring lit while they talk
  /// (functions/clipStrip.js `avatarSpots`). The app draws the same picture
  /// exactly over it - so older clips without one still get it - and a tap
  /// opens their profile (Follow is at the top). The burned ring stays
  /// visible around it.
  Widget _playerPictures(BuildContext context) {
    final m = widget.match;
    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, c) {
          final map = _ClipMap(c.biggest);
          final d = _kAvatarD * map.scale;
          Widget pic(int i, double clipY) {
            final name = i == 0 ? m.player1Username : m.player2Username;
            // A hair larger than the burned photo so no edge of it peeks out.
            return Positioned(
              key: ValueKey('pic$i'),
              left: map.x(_kAvatarLeft) - 1,
              top: map.y(clipY) - 1,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  _bubbleClose?.cancel();
                  setState(() => _bubbleFor = _bubbleFor == i ? null : i);
                },
                // A white ring and a small + badge in the player's colour
                // (top red, bottom blue - their winner box colour), so it
                // reads as a button (developer, 2026-11-17). The + turns
                // into a check once you follow them.
                child: _TappablePicture(
                  name: name,
                  photoUrl: _photos[i],
                  size: d + 2,
                  color: i == 0 ? House.gelRed : House.gelBlue,
                  following: _following[i],
                ),
              ),
            );
          }

          // Optional emoji ratings, a small row right beside each picture
          // (developer, 2026-11-18: no box, no "Rating for" label, never a
          // gate). Tap to rate, tap again to clear. Only while judging.
          final rating = widget.match.canVote && _chosenPlayerId == null;
          Widget emojis(int i, double clipY) => Positioned(
            key: ValueKey('emojis$i'),
            left: map.x(_kAvatarLeft + _kAvatarD) + 8,
            top: map.y(clipY) + d / 2 - _EmojiRow.height / 2,
            child: _EmojiRow(
              selected: i == 0 ? _emojiP1 : _emojiP2,
              color: i == 0 ? House.gelRed : House.gelBlue,
              onSelect: (k) => setState(() {
                if (i == 0) {
                  _emojiP1 = _emojiP1 == k ? null : k;
                } else {
                  _emojiP2 = _emojiP2 == k ? null : k;
                }
              }),
            ),
          );
          const topY = 960 - 55 - _kAvatarGap - _kAvatarD;
          const bottomY = 960 + 55 + _kAvatarGap;
          final open = _bubbleFor;
          Widget bubble(int i, double clipY) {
            final id = i == 0 ? m.player1Id : m.player2Id;
            final name = i == 0 ? m.player1Username : m.player2Username;
            final isMe = FirebaseAuth.instance.currentUser?.uid == id;
            final following = _following[i];
            // Opens AWAY from the strip so it never covers the clock: the
            // top player's grows up from the picture's bottom edge, the
            // bottom player's down from its top edge.
            return Positioned(
              key: ValueKey('bubble$i'),
              left: map.x(_kAvatarLeft + _kAvatarD) + 8,
              top: i == 0 ? null : map.y(clipY),
              bottom: i == 0 ? c.maxHeight - (map.y(clipY) + d) : null,
              child: _FollowBubble(
                name: name,
                color: i == 0 ? House.gelRed : House.gelBlue,
                following: following,
                showFollow: !isMe,
                onFollow: () => _toggleFollow(id, following),
                onProfile: () {
                  _closeBubble();
                  _openProfile(context, id, name);
                },
              ),
            );
          }

          return Stack(
            children: [
              // While the bubble is open, a tap anywhere else just closes
              // it (and does not pick a winner).
              if (open != null)
                Positioned.fill(
                  key: const ValueKey('bubbleDismiss'),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _closeBubble,
                  ),
                ),
              pic(0, topY),
              pic(1, bottomY),
              if (rating && open != 0) emojis(0, topY),
              if (rating && open != 1) emojis(1, bottomY),
              if (open == 0) bubble(0, topY),
              if (open == 1) bubble(1, bottomY),
            ],
          );
        },
      ),
    );
  }

  /// Straight to their profile (developer, 2026-11-18: the in-between card
  /// was one menu too many - Follow is right at the top of the profile).
  /// The clip pauses so its sound doesn't play under their intro video, and
  /// picks up again on return if it had been playing.
  Future<void> _openProfile(
    BuildContext context,
    String uid,
    String name,
  ) async {
    final c = _controller;
    final wasPlaying = c != null && c.value.isInitialized && c.value.isPlaying;
    if (wasPlaying) await c.pause();
    if (!context.mounted) return;
    await PerformerProfileScreen.open(context, uid, username: name);
    if (wasPlaying && mounted && widget.isActive) _controller?.play();
  }

  /// Report, from a small flag at the RIGHT end of the clip strip burned into
  /// the clip (developer, 2026-11-17: the right-hand button column - report,
  /// play/pause, follow - is gone; the scrubber covers play/rewind). REQUIRED
  /// for Apple's Guideline 1.2: this feed is the app's main content surface,
  /// so reporting must be findable here. Kept quiet (a dim outline flag, then
  /// a "who are you reporting?" sheet), since harsh roasting is the point
  /// and not itself reportable. The strip's own content starts ~18% in from
  /// each edge, so the ends are free on every phone.
  Widget _stripReportFlag(BuildContext context) {
    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, c) => Stack(
          children: [
            Positioned(
              right: 2,
              top: c.maxHeight / 2 - 22,
              child: IconButton(
                tooltip: 'Report this clip',
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  Icons.outlined_flag_rounded,
                  size: 22,
                  color: Colors.white.withValues(alpha: 0.7),
                ),
                onPressed: () => _openReport(context),
              ),
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
    final wasPlaying = c != null && c.value.isInitialized && c.value.isPlaying;
    if (wasPlaying) {
      await c.pause();
      if (mounted) setState(() {}); // repaint the corner icon to "play"
    }
    if (!context.mounted) return;
    final choice = await showNeonSheet<String>(
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
            // Each name in its player's colour (top red, bottom blue - the
            // colour of their box on the clip), with their picture, so it is
            // obvious who is who (developer, 2026-11-17).
            for (final p in [
              (
                id: m.player1Id,
                name: m.player1Username,
                photo: _photos[0],
                color: House.gelRed,
                where: 'Top video',
              ),
              (
                id: m.player2Id,
                name: m.player2Username,
                photo: _photos[1],
                color: House.gelBlue,
                where: 'Bottom video',
              ),
            ])
              ListTile(
                leading: _TappablePicture(
                  name: p.name,
                  photoUrl: p.photo,
                  size: 40,
                  color: p.color,
                  badge: false,
                ),
                title: Text(
                  p.name,
                  style: TextStyle(color: p.color, fontWeight: FontWeight.w800),
                ),
                subtitle: Text(p.where),
                onTap: () => Navigator.of(sheetContext).pop(p.id),
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
        builder: (_) =>
            ReportScreen(reportedUserId: choice, matchId: m.matchId),
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

  /// A small chip, top-left, naming what kind of battle this is so a judge
  /// knows what they are judging (2026-11-15, developer's call): RANKED
  /// (purple), ROAST A FRIEND (pink-red), FACE-OFF (teal - a blind simultaneous
  /// prompt battle shown one set at a time, not a broken one-person roast).
  Widget _kindBadge(BuildContext context) {
    final mode = widget.match.mode;
    final color = battleKindColor(mode);
    // Beside the Judge screen's back button (drawn by WatchFeedScreen at the
    // top-left), not under it - it used to cover the label (2026-11-15).
    return Positioned(
      top: MediaQuery.of(context).padding.top + 14,
      left: 64,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          child: Text(
            battleKindLabel(mode),
            style: TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.0,
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final m = widget.match;
    // While you can still vote, the bottom hint carries the "Tap the winner"
    // instruction, so a top chip would just be redundant - hide it.
    if (m.canVote) return const SizedBox.shrink();
    final label = m.isParticipant
        ? 'Your battle'
        : '${m.voteCount} ${m.voteCount == 1 ? "vote" : "votes"}';
    return Positioned(
      top: MediaQuery.of(context).padding.top + 14,
      left: 64, // beside the back button, not under it
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(
            label,
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ),
      ),
    );
  }
}

/// The burned-in pictures' spot on the 1080x1920 clip (mirrors
/// functions/clipStrip.js STRIP.avatarLeft / avatarD / avatarGap - keep in step).
const double _kAvatarLeft = 124;
const double _kAvatarGap = 10;
const double _kAvatarD = 100;

/// Maps 1080x1920 clip pixels onto the feed box, where the clip is shown
/// BoxFit.cover and centred.
class _ClipMap {
  _ClipMap(this._box)
    : scale = (_box.width / 1080) > (_box.height / 1920)
          ? _box.width / 1080
          : _box.height / 1920;

  final Size _box;
  final double scale;

  double x(double clipX) => (_box.width - 1080 * scale) / 2 + clipX * scale;
  double y(double clipY) => (_box.height - 1920 * scale) / 2 + clipY * scale;
}

/// A player's picture that looks like a button: a white ring and, on the
/// clip, a small + badge in the player's colour (tap = name + Follow card).
class _TappablePicture extends StatelessWidget {
  const _TappablePicture({
    required this.name,
    required this.photoUrl,
    required this.size,
    required this.color,
    this.badge = true,
    this.following = false,
  });

  final String name;
  final String? photoUrl;
  final double size;
  final Color color;
  final bool badge;
  final bool following;

  @override
  Widget build(BuildContext context) {
    final ring = (size * 0.06).clamp(2.0, 3.5);
    final badgeSize = (size * 0.36).clamp(16.0, 22.0);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              // White, not the player's colour: the clip's own ring around
              // it glows PINK while that player talks (clipStrip.js), and a
              // red ring would blur into that. The player's colour is on
              // the + badge.
              border: Border.all(color: Colors.white, width: ring),
              boxShadow: const [
                BoxShadow(color: Colors.black54, blurRadius: 6),
              ],
            ),
            child: PlayerAvatar(
              name: name,
              photoUrl: photoUrl,
              size: size - ring * 2,
            ),
          ),
          if (badge)
            Positioned(
              right: -2,
              bottom: -2,
              child: Container(
                width: badgeSize,
                height: badgeSize,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 1.5),
                ),
                child: Icon(
                  following ? Icons.check_rounded : Icons.add_rounded,
                  size: badgeSize - 6,
                  color: Colors.white,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The Judge feed's one action (developer, 2026-11-18): a compact neon pill
/// in the picked roaster's colour - `VOTE FOR name` - that replaced the
/// big green Submit bar and the "<name> WINS" tag. Greyed until voting opens.
class _VotePill extends StatelessWidget {
  const _VotePill({
    required this.label,
    required this.color,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final Color color;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Flat and quiet (developer, 2026-11-18: the glowing gradient looked
    // cheap): a solid pill in the player's colour, a soft drop shadow, a
    // small check. Greyed = dark glass with a thin outline.
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.66,
        ),
        padding: const EdgeInsets.fromLTRB(14, 8, 18, 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          color: enabled ? color : Colors.black.withValues(alpha: 0.5),
          border: Border.all(
            color: enabled
                ? Colors.transparent
                : Colors.white.withValues(alpha: 0.28),
            width: 1,
          ),
          boxShadow: enabled
              ? const [
                  BoxShadow(
                    color: Colors.black45,
                    blurRadius: 10,
                    offset: Offset(0, 3),
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.check_rounded,
              size: 17,
              color: enabled ? Colors.white : Colors.white38,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: enabled ? Colors.white : Colors.white54,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.2,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The optional emoji rating beside a player's picture (developer,
/// 2026-11-18). Folded away by default as a small "Rate" chip; a tap fans the
/// four emojis out in place, and picking one folds them away again, leaving
/// the picked emoji (tap it to change). Tapping the picked emoji in the open
/// row clears it. Left open with no pick, it folds itself after a few seconds.
/// Swallows taps so a near-miss never flips the winner pick underneath.
class _EmojiRow extends StatefulWidget {
  const _EmojiRow({
    required this.selected,
    required this.color,
    required this.onSelect,
  });

  static const double height = 34;

  final String? selected;
  final Color color;
  final ValueChanged<String> onSelect;

  @override
  State<_EmojiRow> createState() => _EmojiRowState();
}

class _EmojiRowState extends State<_EmojiRow> {
  bool _open = false;
  Timer? _autoClose;

  void _setOpen(bool open) {
    _autoClose?.cancel();
    if (open) {
      _autoClose = Timer(const Duration(seconds: 5), () {
        if (mounted) setState(() => _open = false);
      });
    }
    setState(() => _open = open);
  }

  @override
  void dispose() {
    _autoClose?.cancel();
    super.dispose();
  }

  Widget _disc(String emoji, bool picked) {
    const h = _EmojiRow.height;
    return Container(
      width: h,
      height: h,
      margin: const EdgeInsets.only(right: 2),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: picked
            ? widget.color.withValues(alpha: 0.9)
            : Colors.transparent,
        border: picked ? Border.all(color: Colors.white, width: 1.5) : null,
      ),
      child: Text(
        emoji,
        style: TextStyle(
          fontSize: picked ? 19 : 17,
          shadows: const [Shadow(color: Colors.black87, blurRadius: 4)],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sel = widget.selected;
    Widget child;
    if (_open) {
      child = Row(
        key: const ValueKey('open'),
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final r in kEmojiRatings)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                widget.onSelect(r.key);
                _setOpen(false);
              },
              child: Opacity(
                opacity: sel == null || sel == r.key ? 1 : 0.45,
                child: _disc(r.emoji, sel == r.key),
              ),
            ),
        ],
      );
    } else if (sel != null) {
      final r = kEmojiRatings.firstWhere(
        (e) => e.key == sel,
        orElse: () => kEmojiRatings.first,
      );
      child = GestureDetector(
        key: const ValueKey('picked'),
        behavior: HitTestBehavior.opaque,
        onTap: () => _setOpen(true),
        child: _disc(r.emoji, true),
      );
    } else {
      child = GestureDetector(
        key: const ValueKey('chip'),
        behavior: HitTestBehavior.opaque,
        onTap: () => _setOpen(true),
        child: Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 11),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.35),
              width: 1,
            ),
          ),
          child: const Text(
            'Rate',
            style: TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {},
      child: SizedBox(
        height: _EmojiRow.height,
        child: Align(
          alignment: Alignment.centerLeft,
          widthFactor: 1,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 160),
            transitionBuilder: (c, a) => FadeTransition(
              opacity: a,
              child: SizeTransition(
                sizeFactor: a,
                axis: Axis.horizontal,
                alignment: Alignment.centerLeft,
                child: c,
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// The Judge feed's replay, shown once the clip has played to the end: a
/// small dark-glass circle, so it never competes with the Vote pill.
class _ReplayButton extends StatelessWidget {
  const _ReplayButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.black.withValues(alpha: 0.5),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.35),
            width: 1,
          ),
        ),
        child: const Icon(Icons.replay_rounded, color: Colors.white, size: 22),
      ),
    );
  }
}

/// The follow bubble beside a roaster's picture (developer, 2026-11-18): their
/// name, a Follow button that works right there (flips to "Following"), and a
/// "View profile" link. Dark glass with a neon edge in the player's colour.
class _FollowBubble extends StatelessWidget {
  const _FollowBubble({
    required this.name,
    required this.color,
    required this.following,
    required this.showFollow,
    required this.onFollow,
    required this.onProfile,
  });

  final String name;
  final Color color;
  final bool following;
  final bool showFollow;
  final VoidCallback onFollow;
  final VoidCallback onProfile;

  @override
  Widget build(BuildContext context) {
    const pink = Color(0xFFFF2E7E);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {},
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.66,
        ),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xF21C1226), Color(0xF20B0911)],
          ),
          border: Border.all(color: color.withValues(alpha: 0.85), width: 1.3),
          boxShadow: [
            BoxShadow(color: color.withValues(alpha: 0.35), blurRadius: 14),
            const BoxShadow(color: Colors.black54, blurRadius: 10),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (showFollow) ...[
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onFollow,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 160),
                      height: 30,
                      padding: const EdgeInsets.symmetric(horizontal: 11),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(15),
                        color: following ? Colors.transparent : pink,
                        border: Border.all(
                          color: following
                              ? Colors.white.withValues(alpha: 0.5)
                              : pink,
                          width: 1.2,
                        ),
                        boxShadow: following
                            ? null
                            : [
                                BoxShadow(
                                  color: pink.withValues(alpha: 0.45),
                                  blurRadius: 10,
                                ),
                              ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            following
                                ? Icons.check_rounded
                                : Icons.person_add_alt_1_rounded,
                            size: 15,
                            color: Colors.white,
                          ),
                          const SizedBox(width: 5),
                          Text(
                            following ? 'Following' : 'Follow',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                ],
                Flexible(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onProfile,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Text(
                        'View profile',
                        maxLines: 1,
                        overflow: TextOverflow.fade,
                        softWrap: false,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.8),
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          decoration: TextDecoration.underline,
                          decorationColor: Colors.white.withValues(alpha: 0.5),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
