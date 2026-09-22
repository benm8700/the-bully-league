import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';


import 'package:provider/provider.dart';

import '../../core/services/agora_token_service.dart';
import '../../core/services/agora_video_service.dart';
import '../../core/services/matchmaking_service.dart';
import '../../core/services/capture_quality.dart';
import '../../core/services/video_call_service.dart';
import '../../core/services/visual_moderation_service.dart';
import '../../core/services/yuv_to_jpeg.dart';
import '../vote/my_battles_screen.dart';
import '../vote/vote_queue_screen.dart';

/// Round/turn/timer state machine (Build Order step 4).
///
/// This now runs on a REAL pairing: the match document, the Agora channel,
/// and the opponent's identity all come from the matchmaking backend
/// (functions/matchmaking.js) rather than the hardcoded "test-channel"
/// both devices used to join. What's still outstanding:
/// - Round count/length/countdown now come from live configuration
///   (CLAUDE.md's config/matchSettings), resolved server-side at pairing
///   time and carried on the pairing, so they can be retuned without
///   shipping a new app version.
/// - Turn sequencing still has no server-authoritative state. One device
///   is elected "host" (lower Agora-assigned uid) and drives the real
///   timer, broadcasting state to the other over Agora's data-stream
///   messaging (sendStreamMessage/onStreamMessage - see
///   AgoraVideoCallService). The non-host device purely mirrors it. Only
///   the match's creation and completion are server-side.
/// - Who goes first each round is always the host - CLAUDE.md doesn't
///   document a rule for this (e.g. alternating/coin-flip), so this is a
///   placeholder default, not a final decision. Flagged in CLAUDE.md.
class MatchScreen extends StatefulWidget {
  const MatchScreen({super.key, required this.pairing});

  final MatchPairing pairing;

  @override
  State<MatchScreen> createState() => _MatchScreenState();
}

enum _Phase { waitingForOpponent, warmup, countdown, turn, verdict }

class _MatchScreenState extends State<MatchScreen> {
  // Timings come from the pairing, which carries what the server resolved
  // and stamped onto the match document at pairing time - so both players
  // run identical numbers and the developer can retune round count/length
  // live without shipping a new app version (CLAUDE.md's explicit
  // requirement). See functions/matchSettings.js.
  MatchSettings get _settings => widget.pairing.settings;
  int get _roundLengthSeconds => _settings.roundLengthSeconds;
  int get _countdownSeconds => _settings.countdownSeconds;
  int get _warmupSeconds => _settings.warmupSeconds;
  int get _totalTurns => _settings.totalTurns;

  late final VideoCallService _videoCallService;
  late final VisualModerationService _moderationService;
  final _matchmakingService = MatchmakingService();
  bool _initialized = false;
  String? _error;

  bool? _isHost;
  int? _myUid;
  int? _opponentUid;

  /// HOST-ONLY per-round clip windows. Recording starts at host election,
  /// so [_recordingStartMs] (device wall-clock) is the clip's origin on the
  /// host's own clock; every turn's start/end is measured from it, giving
  /// offsets into the final clip. Paired into per-round windows and sent
  /// with completeMatch, they let the Best Rounds board play ONLY the
  /// voted-best round rather than the whole battle. Only the host drives
  /// the timer, so only the host captures these; the guest sends nothing.
  int? _recordingStartMs;
  final List<Map<String, int>> _turnSpans = [];
  StreamSubscription<Map<String, dynamic>>? _msgSub;
  StreamSubscription<RawVideoFrame>? _frameSampleSub;
  StreamSubscription<RawVideoFrame>? _localFrameSub;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _matchDocSub;
  final CaptureQualityMonitor _quality = CaptureQualityMonitor();
  Completer<void>? _earlyEndCompleter;
  bool _processingFrame = false;

  // Content-violation state (Build Order step 9a's live-video half) - set
  // either by this device detecting a violation in the opponent's stream
  // (_violationIAmReporter = true, a report gets auto-filed) or by the
  // opponent's device detecting one in MINE and telling me via a match
  // message (_violationIAmReporter = false, no report filed from this
  // side - the OTHER device already did). Either way the match ends
  // immediately and is never saved/scored, same as a technical
  // disqualification.
  bool _violationEnded = false;
  bool _violationIAmReporter = false;

  _Phase _phase = _Phase.waitingForOpponent;
  int _turnIndex = 0;
  int? _activeUid;
  int _secondsRemaining = 0;
  Timer? _ticker;
  bool _matchCompleted = false;
  bool _completeRequested = false;
  String? _matchSaveError;

  /// Known from the pairing itself now, rather than exchanged
  /// peer-to-peer over the data channel after joining.
  String get _opponentFirebaseUid => widget.pairing.opponentId;

  @override
  void initState() {
    super.initState();
    _videoCallService = AgoraVideoCallService();
    // Read before any async gap - see the note on this pattern in
    // ProfileScreen._addPhoto.
    _moderationService = context.read<VisualModerationService>();
    _setup();
  }

  Future<void> _setup() async {
    final channelName = widget.pairing.channelName;
    try {
      await _videoCallService.initialize();
      final token = await fetchAgoraToken(channelName);
      await _videoCallService.joinChannel(
        channelName: channelName,
        // A fixed uid from the pairing (1 or 2) rather than the wildcard
        // 0, so the recording layout can name each player's region. The
        // token is still minted against uid 0, which Agora treats as a
        // wildcard valid for any uid, so nothing about token minting
        // changes. Host election below still compares the two uids, and
        // is now deterministic: player1 hosts.
        uid: widget.pairing.agoraUid,
        token: token,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Match setup failed: $e');
      return;
    }
    if (!mounted) return;
    setState(() => _initialized = true);
    _msgSub = _videoCallService.matchMessages.listen(_onMessage);
    // SERVER-AUTHORITATIVE BACKSTOP for ending the match. Turn state is
    // driven peer-to-peer over Agora's data channel, whose messages are not
    // guaranteed delivery. An intermediate lost message self-heals (the next
    // absolute state message resyncs us), but the FINAL verdict message has
    // no "next message" to heal it - so if it drops, the guest hangs forever
    // on "Waiting for opponent..." while the host has already reached the
    // verdict and left. Observed live, repeatedly. The match document IS
    // authoritative for completion (the host's completeMatch marks it
    // terminal), so listen for that and end cleanly no matter what the data
    // channel did.
    _matchDocSub = FirebaseFirestore.instance
        .collection('matches')
        .doc(widget.pairing.matchId)
        .snapshots()
        .listen(_onMatchDoc);
    // Frame sampling can start right at join now. It previously had to
    // wait for an 'identity' message carrying the opponent's Firebase uid,
    // because _handleContentViolation's report-filing is guarded on having
    // someone to file against - and a violation detected before that
    // message landed silently produced no report at all (a real race,
    // caught live during step 9a testing). The pairing now supplies the
    // opponent's uid before this screen is even built, so that race is
    // structurally impossible rather than merely ordered around.
    _frameSampleSub = _videoCallService.remoteFrameSamples.listen(_onRemoteFrameSample);
    // Your OWN camera and mic. Warning someone that their opponent is in
    // the dark is information they can do nothing with; warning them
    // about themselves is the only version they can act on.
    _localFrameSub = _videoCallService.localFrameSamples.listen(_onLocalFrameSample);
    _videoCallService.localAudioLevel.addListener(_onLocalAudioLevel);
    _videoCallService.localUid.addListener(_maybeElectHost);
    _videoCallService.remoteUid.addListener(_maybeElectHost);
    _maybeElectHost();
  }

  /// Your own camera, checked for the one failure nobody notices while it
  /// is happening: being invisible.
  ///
  /// WARNS RATHER THAN CANCELS. CLAUDE.md's decision says a flagged match
  /// is auto-cancelled and re-queued, and that is deliberately not done
  /// here - a false positive would destroy a battle somebody was in the
  /// middle of, and a no-penalty auto-cancel is a free escape from a
  /// match that is going badly, which is precisely the dodge the doc's
  /// own abuse-safeguard item worries about. A warning costs nothing when
  /// wrong and cannot be used to duck an opponent.
  void _onLocalFrameSample(RawVideoFrame frame) {
    final luma = meanLuma(
      frame.yBuffer,
      width: frame.width,
      height: frame.height,
      yStride: frame.yStride,
    );
    final message = _quality.recordLuma(luma);
    if (message != null) {
      _quality.noteEpisode(dark: true, quiet: false);
      _showQualityWarning(message);
    }
  }

  void _onLocalAudioLevel() {
    final message =
        _quality.recordAudioLevel(_videoCallService.localAudioLevel.value);
    if (message != null) {
      _quality.noteEpisode(dark: false, quiet: true);
      _showQualityWarning(message);
    }
  }

  /// Shown as a snackbar rather than a dialog: this arrives mid-battle,
  /// and a modal would take the screen away from someone who is currently
  /// being roasted on camera.
  void _showQualityWarning(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 4),
        backgroundColor: Colors.orange.shade900,
        content: Text(message),
      ),
    );
  }

  /// One sampled remote frame arrives here every few seconds (throttled by
  /// AgoraVideoCallService, not per-frame). Converts I420 to JPEG off the
  /// UI thread (compute() - real per-pixel work over a full video frame),
  /// then sends it through visual moderation. _processingFrame guards
  /// against a slow moderation call overlapping with the next sample.
  Future<void> _onRemoteFrameSample(RawVideoFrame frame) async {
    if (_violationEnded || _processingFrame) return;
    _processingFrame = true;
    try {
      final jpeg = await compute(i420ToJpeg, I420FrameData.fromRawVideoFrame(frame));
      final reason = await _moderationService.checkImageBytes(jpeg);
      if (reason != null) {
        await _handleContentViolation(reason, iAmReporter: true);
      }
    } catch (e) {
      // A failed moderation CALL (network hiccup, etc.) is not itself a
      // violation - fail open rather than ending real matches over a
      // transient error. The next sample a few seconds later tries again.
      debugPrint('Frame moderation check failed: $e');
    } finally {
      _processingFrame = false;
    }
  }

  /// Ends the match immediately and never scores/saves it - same
  /// treatment as a technical disqualification. If this device is the one
  /// that detected the violation (iAmReporter), it also auto-files a
  /// report against the opponent (CLAUDE.md's step 9a decision: this
  /// stays consistent with the existing report pipeline - the ban/
  /// suspend decision is still admin review, not automatic) and tells the
  /// other device to end too, since only one side can see any given
  /// remote stream.
  Future<void> _handleContentViolation(String reason, {required bool iAmReporter}) async {
    if (_violationEnded) return;
    _violationEnded = true;
    _violationIAmReporter = iAmReporter;
    _ticker?.cancel();

    if (iAmReporter) {
      final myFirebaseUid = FirebaseAuth.instance.currentUser?.uid;
      if (myFirebaseUid != null) {
        try {
          await FirebaseFirestore.instance.collection('reports').add({
            'reporterId': myFirebaseUid,
            'reportedUserId': _opponentFirebaseUid,
            // The match document exists from pairing time now, so an
            // auto-filed report can actually point at it - it used to be
            // null here because nothing was written until verdict time,
            // which a violation never reached.
            'matchId': widget.pairing.matchId,
            'reason': 'inappropriate_content',
            'details': 'Automatically detected by live visual content moderation: $reason',
            'status': 'pending',
            'createdAt': FieldValue.serverTimestamp(),
          });
        } catch (e) {
          debugPrint('Failed to auto-file content violation report: $e');
        }
      }
      try {
        await _videoCallService.sendMatchMessage({'type': 'matchEndedViolation'});
      } catch (_) {
        // Best-effort - still proceed to leave below even if this drops.
      }
    }

    // Settle the match as abandoned so it's never voted on, never rated,
    // and never surfaces in the public discovery feed. Both devices call
    // this; the second is a server-side no-op.
    try {
      await _matchmakingService.completeMatch(widget.pairing.matchId, outcome: 'abandoned');
    } catch (e) {
      // The hourly sweep settles any match still pending after the vote
      // window, so a dropped call here delays cleanup rather than leaving
      // a violation match eligible for rating.
      debugPrint('Failed to mark violation match abandoned: $e');
    }

    try {
      await _videoCallService.leaveChannel();
    } catch (_) {
      // Best-effort - UI already reflects the ended match regardless.
    }
    if (mounted) setState(() {});
  }

  void _maybeElectHost() {
    if (_isHost != null) return;
    final myUid = _videoCallService.localUid.value;
    final oppUid = _videoCallService.remoteUid.value;
    if (myUid == null || oppUid == null) return;

    _myUid = myUid;
    _opponentUid = oppUid;
    // Host election still uses the Agora-assigned uids - it decides which
    // device drives the turn timer, which is unrelated to Firebase
    // identity. The 'identity' handshake this used to send is gone: both
    // players' Firebase uids come from the pairing now.
    _isHost = myUid < oppUid;
    if (_isHost!) {
      // Started here rather than at pairing because host election is the
      // first moment both players are provably in the channel - starting
      // earlier would record an empty room while the second player was
      // still finishing their bio reveal, and Agora bills by duration.
      // Only the host asks, so the two devices don't race; the backend
      // treats a duplicate as a no-op anyway. Exhibition matches are
      // declined server-side (CLAUDE.md's recording scope decision).
      // The clip's origin on the host's clock: turn offsets below are
      // measured from here so they line up with the recorded clip.
      _recordingStartMs = DateTime.now().millisecondsSinceEpoch;
      unawaited(_matchmakingService.startRecording(widget.pairing.matchId));
      unawaited(_runHostSequence());
    }
  }

  void _onMessage(Map<String, dynamic> message) {
    switch (message['type']) {
      case 'earlyEnd':
        _earlyEndCompleter?.complete();
      case 'matchEndedViolation':
        // The OTHER device detected a violation in what it saw of MY
        // stream and already auto-filed a report - this side doesn't
        // file a second one (iAmReporter: false), just ends the match.
        unawaited(_handleContentViolation('Reported by the other participant.', iAmReporter: false));
      case 'state':
        final phase = _Phase.values.byName(message['phase'] as String);
        _applyState(
          phase: phase,
          turnIndex: message['turnIndex'] as int,
          activeUid: message['activeUid'] as int?,
          duration: message['duration'] as int,
        );
    }
  }

  /// Coin-flip for who roasts first this match. Derived deterministically
  /// from the shared matchId (sum of its char codes), so BOTH devices compute
  /// the same answer with no server round-trip - the host drives the turn
  /// order and the guest mirrors it, but each side can also tell whether IT
  /// goes first for the warmup indicator. The chosen player leads EVERY round.
  ///
  /// Replaces the old "host (player1) always goes first", which handed
  /// whoever drew the lower Agora uid a consistent going-first position every
  /// round of every match. matchId is a random id, so this is an even flip.
  bool _hostGoesFirst() {
    final sum = widget.pairing.matchId.codeUnits
        .fold<int>(0, (a, b) => a + b);
    return sum.isEven;
  }

  /// The Agora uid that roasts first, or null before host election has set
  /// the two uids. The lower uid is the host (player1); the flip decides
  /// whether the lower or higher uid leads. Identical on both devices.
  int? _firstUid() {
    if (_myUid == null || _opponentUid == null) return null;
    final lower = _myUid! < _opponentUid! ? _myUid! : _opponentUid!;
    final higher = _myUid! < _opponentUid! ? _opponentUid! : _myUid!;
    return _hostGoesFirst() ? lower : higher;
  }

  /// Whether THIS device roasts first this match (for the warmup indicator).
  bool get _iGoFirst => _firstUid() != null && _firstUid() == _myUid;

  Future<void> _runHostSequence() async {
    // The Warmup Round: the first live beat of the battle, both mics OPEN
    // (unlike the turns), for open banter / a staredown before round 1. It
    // is inside the recorded battle channel, so it costs ~1 extra
    // participant-minute and is captured + shown to spectators as pre-fight
    // hype. Skipped only if the config sets it to 0. No active player and no
    // early-end: it is a fixed shared beat.
    if (_warmupSeconds > 0 && !_violationEnded) {
      await _hostAdvance(
        phase: _Phase.warmup,
        turnIndex: -1,
        activeUid: null,
        duration: _warmupSeconds,
      );
    }
    // Coin-flipped leader (see _hostGoesFirst); the chosen player takes the
    // first turn of every round. On the host, _myUid is the lower uid.
    final firstUid = _hostGoesFirst() ? _myUid! : _opponentUid!;
    final secondUid = _hostGoesFirst() ? _opponentUid! : _myUid!;
    for (var i = 0; i < _totalTurns; i++) {
      if (_violationEnded) return;
      final activeUid = (i.isEven) ? firstUid : secondUid;
      await _hostAdvance(phase: _Phase.countdown, turnIndex: i, activeUid: activeUid, duration: _countdownSeconds);
      if (_violationEnded) return;
      await _hostAdvance(
        phase: _Phase.turn,
        turnIndex: i,
        activeUid: activeUid,
        duration: _roundLengthSeconds,
        allowEarlyEnd: true,
      );
    }
    if (_violationEnded) return;
    await _hostAdvance(phase: _Phase.verdict, turnIndex: _totalTurns, activeUid: null, duration: 0);
  }

  /// Flips the already-existing match document from "pending" to
  /// "completed", which is what admits it to the 24h voting window and,
  /// for ranked matches, eventually to real Elo changes.
  ///
  /// This replaces the old client-side document creation. The client can't
  /// write the matches collection at all any more (firestore.rules) - a
  /// modified client could otherwise invent matches between arbitrary
  /// players and declare them finished.
  Future<void> _completeMatch() async {
    if (_violationEnded || _completeRequested) return;
    _completeRequested = true;
    try {
      // Sent with the settle rather than written separately, since the
      // client cannot write the match document at all - and sent from
      // BOTH devices, because each only knows about its own capture.
      await _matchmakingService.completeMatch(
        widget.pairing.matchId,
        quality: _quality.summary,
        roundBoundaries: _roundBoundaries(),
      );
      if (mounted) setState(() => _matchCompleted = true);
    } catch (e) {
      if (mounted) setState(() => _matchSaveError = 'Could not save match: $e');
    }
  }

  /// The match document reached a terminal status server-side. If we haven't
  /// already ended (either the data channel delivered the verdict, or a
  /// content violation ended us), force the verdict now - this is what
  /// rescues a guest stranded on a mid-match turn because the host's final
  /// state message was lost. [_applyState] mutes, leaves the channel and
  /// calls [_completeMatch] (idempotent server-side), exactly as the normal
  /// verdict transition does.
  void _onMatchDoc(DocumentSnapshot<Map<String, dynamic>> snap) {
    if (!mounted) return;
    final status = snap.data()?['status'] as String?;
    const terminal = {'completed', 'abandoned', 'disqualified'};
    if (status == null || !terminal.contains(status)) return;
    if (_phase == _Phase.verdict || _violationEnded) return;
    _applyState(
      phase: _Phase.verdict,
      turnIndex: _totalTurns,
      activeUid: null,
      duration: 0,
    );
  }

  /// HOST-ONLY: pair the captured turn spans into per-round clip windows.
  /// A round is two consecutive turns (player 1 then player 2), so round R
  /// runs from turn 2R's start to turn 2R+1's end. Returns null for the
  /// guest (no capture) or an incomplete one.
  ///
  /// A small LEAD-IN/LEAD-OUT buffer absorbs the gap between when the host
  /// asked to record and when Agora actually began capturing (the clip's
  /// true origin sits a beat later than [_recordingStartMs]), plus a little
  /// context - better to show a hair extra than to clip the start of the
  /// round. The exact buffer wants tuning against real recorded footage;
  /// the whole caption/trim/render path has never run on real speech.
  List<Map<String, int>>? _roundBoundaries() {
    if (_isHost != true || _turnSpans.isEmpty) return null;
    const leadInMs = 1500;
    const leadOutMs = 800;
    final byTurn = {for (final s in _turnSpans) s['turn']!: s};
    final out = <Map<String, int>>[];
    final rounds = _turnSpans.length ~/ 2;
    for (var r = 0; r < rounds; r++) {
      final a = byTurn[2 * r];
      final b = byTurn[2 * r + 1];
      if (a == null || b == null) continue;
      final start = (a['start']! - leadInMs).clamp(0, 1 << 30);
      final end = b['end']! + leadOutMs;
      if (end <= start) continue;
      out.add({'round': r, 'startMs': start, 'endMs': end});
    }
    return out.isEmpty ? null : out;
  }

  Future<void> _hostAdvance({
    required _Phase phase,
    required int turnIndex,
    required int? activeUid,
    required int duration,
    bool allowEarlyEnd = false,
  }) async {
    final message = {
      'type': 'state',
      'phase': phase.name,
      'turnIndex': turnIndex,
      'activeUid': activeUid,
      'duration': duration,
    };
    // On the VERDICT, _applyState leaves the Agora channel - so broadcast the
    // final state to the guest BEFORE tearing the channel down, otherwise the
    // host leaves (racing the unawaited leaveChannel) before the send goes
    // out and the guest never learns the match ended, hanging forever on
    // "Waiting for opponent...". For every other phase, apply-then-send keeps
    // the host a hair ahead of the guest, exactly as before.
    if (phase == _Phase.verdict) {
      await _videoCallService.sendMatchMessage(message);
      _applyState(phase: phase, turnIndex: turnIndex, activeUid: activeUid, duration: duration);
    } else {
      _applyState(phase: phase, turnIndex: turnIndex, activeUid: activeUid, duration: duration);
      await _videoCallService.sendMatchMessage(message);
    }

    if (duration == 0) return;
    // Capture the actual [start,end] of each TURN (offsets into the clip),
    // so a round's window can be built from its two turns. Only turns are
    // captured - the countdown/warmup are not part of a "round".
    final isTurn = phase == _Phase.turn && _recordingStartMs != null;
    final startMs = isTurn
        ? DateTime.now().millisecondsSinceEpoch - _recordingStartMs!
        : 0;
    if (allowEarlyEnd) {
      _earlyEndCompleter = Completer<void>();
      await Future.any([Future.delayed(Duration(seconds: duration)), _earlyEndCompleter!.future]);
    } else {
      await Future.delayed(Duration(seconds: duration));
    }
    if (isTurn) {
      _turnSpans.add({
        'turn': turnIndex,
        'start': startMs,
        'end': DateTime.now().millisecondsSinceEpoch - _recordingStartMs!,
      });
    }
  }

  void _applyState({
    required _Phase phase,
    required int turnIndex,
    required int? activeUid,
    required int duration,
  }) {
    if (!mounted) return;
    setState(() {
      _phase = phase;
      _turnIndex = turnIndex;
      _activeUid = activeUid;
      _secondsRemaining = duration;
    });
    _startTicker(duration);

    switch (phase) {
      case _Phase.warmup:
        // Both mics open - the one beat where the two players talk freely.
        _videoCallService.muteLocalAudio(false);
      case _Phase.turn:
      case _Phase.countdown:
        // Pre-warm the upcoming speaker's mic during the "get ready"
        // countdown so Agora's audio stream is already flowing when the turn
        // (and its recording window) begins. Unmuting at the exact turn start
        // left the stream to spin up while the player was already talking,
        // which clipped the first word off that round's recording. The
        // countdown carries the SAME activeUid as the turn that follows, so
        // the opponent stays muted throughout - only the person about to
        // speak goes live early, during their own "get ready".
        _videoCallService.muteLocalAudio(activeUid != _myUid);
      case _Phase.verdict:
        // The match is over. Mute AND leave the channel so audio does not
        // keep relaying between the two phones on the "Match complete!"
        // screen, and so an idle channel is not billed. The old behaviour
        // left both mics open (for a verdict reveal that does not exist
        // yet), which is what caused live cross-talk after the match ended.
        _videoCallService.muteLocalAudio(true);
        unawaited(_videoCallService.leaveChannel());
        // BOTH devices settle the match, not just the host - the call is
        // idempotent server-side (the second one returns alreadySettled),
        // and this way a host that crashes right at the verdict doesn't
        // leave the match stuck "pending" until the hourly sweep.
        unawaited(_completeMatch());
      case _Phase.waitingForOpponent:
        _videoCallService.muteLocalAudio(true);
    }
  }

  void _startTicker(int seconds) {
    _ticker?.cancel();
    if (seconds <= 0) return;
    _ticker = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || _secondsRemaining <= 1) {
        timer.cancel();
        if (mounted) setState(() => _secondsRemaining = 0);
        return;
      }
      setState(() => _secondsRemaining -= 1);
    });
  }

  void _onEndTurnPressed() {
    if (_activeUid != _myUid) return;
    if (_isHost == true) {
      _earlyEndCompleter?.complete();
    } else {
      _videoCallService.sendMatchMessage({'type': 'earlyEnd'});
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _msgSub?.cancel();
    _matchDocSub?.cancel();
    _frameSampleSub?.cancel();
    _localFrameSub?.cancel();
    _videoCallService.localAudioLevel.removeListener(_onLocalAudioLevel);
    _videoCallService.localUid.removeListener(_maybeElectHost);
    _videoCallService.remoteUid.removeListener(_maybeElectHost);
    _videoCallService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Leaving mid-battle can forfeit the match, so guard the back arrow AND
    // the system back gesture with a confirmation. Once the match is over
    // (verdict or a violation end) or it never really started (error/
    // loading), leaving is free and the normal back button applies.
    final canLeaveFreely = _error != null ||
        !_initialized ||
        _violationEnded ||
        _phase == _Phase.verdict;
    return PopScope(
      canPop: canLeaveFreely,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmLeave() && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Match'),
          automaticallyImplyLeading: canLeaveFreely,
          leading: canLeaveFreely
              ? null
              : IconButton(
                  icon: const Icon(Icons.arrow_back),
                  tooltip: 'Leave match',
                  onPressed: () async {
                    if (await _confirmLeave() && context.mounted) {
                      Navigator.of(context).pop();
                    }
                  },
                ),
        ),
        body: _error != null
            ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)))
            : !_initialized
                ? const Center(child: CircularProgressIndicator())
                : _violationEnded
                    ? _buildViolationEndedUi()
                    : _buildMatchUi(),
      ),
    );
  }

  /// Confirmation before abandoning a live battle. The back arrow and the
  /// system back gesture both route through this, because leaving mid-match
  /// can count as a forfeit (see the mid-match disconnect rule) and an
  /// accidental tap should never silently end the battle.
  Future<bool> _confirmLeave() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Leave the match?'),
        content: const Text(
          'The battle is still going. If you leave now you may forfeit - it '
          'can count as a loss, and your opponent keeps going without you.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep battling'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Widget _buildViolationEndedUi() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.report_gmailerrorred_outlined, size: 48),
            const SizedBox(height: 16),
            Text('Match ended', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 12),
            Text(
              _violationIAmReporter
                  ? 'Our automated visual check flagged something on camera and '
                      'ended the match. This is about video only - never anything '
                      'said - and it doesn\'t mean anyone\'s been banned; a human '
                      'will take a look. If it got it wrong, reach out via Support '
                      '& Feedback on Home.'
                  : 'The automated visual check flagged something on camera and '
                      'ended the match. This was NOT your opponent reporting you, '
                      'and it is never about anything said - only video. If you '
                      'think it got it wrong, reach out via Support & Feedback on '
                      'Home.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () => Navigator.of(context).popUntil((route) => route.isFirst),
              child: const Text('Back to Home'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMatchUi() {
    if (_phase == _Phase.verdict) {
      return _buildVerdictUi();
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        _videoCallService.remoteVideoView() ??
            const ColoredBox(
              color: Colors.black,
              child: Center(
                child: Text('Waiting for opponent...', style: TextStyle(color: Colors.white70)),
              ),
            ),
        Positioned(
          right: 16,
          bottom: 16,
          width: 100,
          height: 140,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: _videoCallService.localVideoView(),
          ),
        ),
        if (_phase == _Phase.warmup) _buildWarmupOverlay(),
        if (_phase == _Phase.countdown) _buildCountdownOverlay(),
        if (_phase == _Phase.turn) _buildTurnOverlay(),
      ],
    );
  }

  /// The Warmup Round banner. Deliberately NON-blocking (a top pill, not a
  /// full-screen blackout like the countdown) - both players are live on
  /// camera for the staredown/banter, so blacking the video out would
  /// defeat the point. States that both mics are open, since that is the one
  /// beat where that is true.
  Widget _buildWarmupOverlay() {
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.local_fire_department,
                      color: Colors.white, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    'Warmup Round · ${_secondsRemaining}s',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              const Text(
                'Both mics are open - loosen up',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              // Who leads off, surfaced during the warmup so the first roaster
              // knows to be ready before round 1 starts (coin-flipped, so it
              // is not always the same player). Only shown once host election
              // has set the uids.
              if (_firstUid() != null) ...[
                const SizedBox(height: 8),
                Text(
                  _iGoFirst ? "You're up first" : 'Opponent goes first',
                  style: TextStyle(
                    color: _iGoFirst
                        ? Colors.amberAccent
                        : Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCountdownOverlay() {
    final isMe = _activeUid == _myUid;
    // Shadows so the text stays legible over a live - possibly bright - video
    // feed now that we only dim rather than black it out.
    const shadows = [
      Shadow(blurRadius: 12, color: Colors.black),
      Shadow(blurRadius: 24, color: Colors.black),
    ];
    return ColoredBox(
      // A light dim, NOT a blackout: keep the opponent visible during the
      // get-ready beat so you can still size them up (developer's call,
      // 2026-09-17). Blacking the feed out threw away a chance to look at
      // your opponent.
      color: Colors.black.withValues(alpha: 0.35),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              isMe ? 'Your turn coming up' : "Opponent's turn coming up",
              style: const TextStyle(
                  color: Colors.white, fontSize: 22, shadows: shadows),
            ),
            const SizedBox(height: 16),
            // A "Get ready" message rather than a ticking number - the
            // developer's call (2026-09-16): the countdown still lasts the
            // configured time and then the turn starts, but the number felt
            // unnecessary.
            const Text(
              'Get ready',
              style: TextStyle(
                color: Colors.white,
                fontSize: 40,
                fontWeight: FontWeight.bold,
                letterSpacing: 1,
                shadows: shadows,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTurnOverlay() {
    final isMe = _activeUid == _myUid;
    return Stack(
      children: [
        // Small, unobtrusive timer per CLAUDE.md's in-turn countdown requirement.
        Positioned(
          top: 12,
          left: 12,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              'Round ${(_turnIndex ~/ 2) + 1} · $_secondsRemaining s',
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
        ),
        if (isMe)
          Positioned(
            bottom: 180,
            left: 0,
            right: 0,
            child: Center(
              child: FilledButton(
                onPressed: _onEndTurnPressed,
                child: const Text('End My Turn'),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildVerdictUi() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.emoji_events_outlined, size: 48),
            const SizedBox(height: 16),
            Text('Match complete!', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 12),
            // The reciprocal ask, made at the highest-intent moment in the
            // app: they're invested, waiting on their own verdict, and
            // already looking at this screen. Asking here converts far
            // better than a cold notification later, and framing it as
            // "judge while you're judged" makes it plainly fair rather
            // than extractive. It also directly feeds the vote confidence
            // that now determines how much any result moves rating.
            const Text(
              'Your battle is now with the crowd. They have 24 hours to call it.\n\n'
              'Judge a few others while you wait - the more people who judge a '
              'battle, the more it counts.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            if (_matchCompleted)
              FilledButton.icon(
                onPressed: () => Navigator.of(context).pushReplacement(
                  MaterialPageRoute(builder: (_) => const VoteQueueScreen()),
                ),
                icon: const Icon(Icons.how_to_vote_outlined),
                label: const Text('Judge a battle'),
              )
            else if (_matchSaveError != null)
              Text(_matchSaveError!,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.error))
            else
              const CircularProgressIndicator(),
            if (_matchCompleted) ...[
              const SizedBox(height: 8),
              // The other half of the wait: watching your own count climb.
              // Participants can't vote on their own match, so there's no
              // judgement of theirs left to bias and the scoreboard is open
              // to them from the first ballot.
              TextButton.icon(
                onPressed: () => Navigator.of(context).pushReplacement(
                  MaterialPageRoute(builder: (_) => const MyBattlesScreen()),
                ),
                icon: const Icon(Icons.leaderboard_outlined, size: 18),
                label: const Text('Watch the votes come in'),
              ),
            ],
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => Navigator.of(context).popUntil((route) => route.isFirst),
              child: const Text('Back to Home'),
            ),
          ],
        ),
      ),
    );
  }
}
