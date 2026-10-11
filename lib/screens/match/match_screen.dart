import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';


import 'package:provider/provider.dart';

import '../../core/main_stage_battle.dart';
import '../../core/services/agora_token_service.dart';
import '../../core/services/agora_video_service.dart';
import '../../core/services/matchmaking_service.dart';
import '../../core/services/capture_quality.dart';
import '../../core/services/video_call_service.dart';
import '../../core/services/visual_moderation_service.dart';
import '../../core/services/yuv_to_jpeg.dart';
import '../../theme/app_theme.dart';
import '../../widgets/match/ability_deploy_bar.dart';
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

// A regular battle now runs the chess-clock format (2026-10-11): a short
// warmup, then the MainStageBattleState engine scaled to 30s each, yield-only
// at the amateur tier (interrupts come from the paid loadout). waitingForOpponent
// -> warmup -> battle -> verdict.
enum _Phase { waitingForOpponent, warmup, battle, verdict }

class _MatchScreenState extends State<MatchScreen>
    with SingleTickerProviderStateMixin {
  // Timings come from the pairing, which carries what the server resolved
  // and stamped onto the match document at pairing time - so both players
  // run identical numbers and the developer can retune the format live
  // without shipping a new app version. See functions/matchSettings.js.
  MatchSettings get _settings => widget.pairing.settings;
  int get _warmupSeconds => _settings.warmupSeconds;

  /// The chess-clock config, from the stamped settings so both devices agree.
  MainStageBattleConfig get _battleConfig => MainStageBattleConfig(
        turnMs: _settings.turnSeconds * 1000,
        interrupts: _settings.interrupts,
        shotClockMs: _settings.shotClockSeconds * 1000,
        graceMs: _settings.graceMs,
      );

  late final VideoCallService _videoCallService;
  late final VisualModerationService _moderationService;
  final _matchmakingService = MatchmakingService();
  bool _initialized = false;
  String? _error;

  bool? _isHost;

  StreamSubscription<Map<String, dynamic>>? _msgSub;
  StreamSubscription<RawVideoFrame>? _frameSampleSub;
  StreamSubscription<RawVideoFrame>? _localFrameSub;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _matchDocSub;
  final CaptureQualityMonitor _quality = CaptureQualityMonitor();
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
  int _secondsRemaining = 0; // warmup countdown only
  Timer? _ticker; // warmup countdown only
  bool _matchCompleted = false;
  bool _completeRequested = false;
  String? _matchSaveError;

  // The chess-clock battle. The host owns the engine and drives it on a
  // ~300ms tick, broadcasting the whole state; the guest renders it and sends
  // yield/interrupt intents back. Mirrors MainStageBattleScreen.
  MainStageBattleState? _battle;
  Timer? _battleTick;
  bool _engineStarted = false;

  // Interrupt grace cue: the floor-holder's clock flashes red + buzzes while a
  // steal is winding up. Harmless when interrupts are off (nothing fires it).
  late final AnimationController _pulse;
  bool _beingInterrupted = false;

  /// Known from the pairing itself now, rather than exchanged
  /// peer-to-peer over the data channel after joining.
  String get _opponentFirebaseUid => widget.pairing.opponentId;

  /// The engine is keyed by Firebase uid (like MainStageBattleScreen), so the
  /// floor/mic logic uses these rather than the Agora uids (which only decide
  /// who hosts).
  String get _myFirebaseUid => FirebaseAuth.instance.currentUser?.uid ?? '';
  int get _nowMs => DateTime.now().millisecondsSinceEpoch;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 450));
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
    _battleTick?.cancel();

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

    // Host election uses the Agora-assigned uids - it decides which device
    // drives the chess-clock engine, which is unrelated to Firebase identity
    // (the engine itself is keyed by Firebase uid). Deterministic: the lower
    // uid (player1) hosts.
    _isHost = myUid < oppUid;
    if (_isHost!) {
      // Started here rather than at pairing because host election is the
      // first moment both players are provably in the channel - starting
      // earlier would record an empty room while the second player was
      // still finishing their bio reveal, and Agora bills by duration.
      // Only the host asks, so the two devices don't race; the backend
      // treats a duplicate as a no-op anyway. Exhibition matches are
      // declined server-side (CLAUDE.md's recording scope decision). No round
      // boundaries are captured - the chess-clock battle has no rounds, so the
      // highlight renders full-length.
      unawaited(_matchmakingService.startRecording(widget.pairing.matchId));
      unawaited(_runHostSequence());
    }
  }

  void _onMessage(Map<String, dynamic> message) {
    // The violation and warmup messages use 'type'; the chess-clock engine
    // uses 't' (ms_state host->guest, ms_intent guest->host), matching
    // MainStageBattleScreen's wire format.
    if (message['type'] == 'matchEndedViolation') {
      // The OTHER device detected a violation in what it saw of MY stream and
      // already auto-filed a report - this side doesn't file a second one
      // (iAmReporter: false), just ends the match.
      unawaited(_handleContentViolation(
          'Reported by the other participant.', iAmReporter: false));
      return;
    }
    if (message['type'] == 'warmup') {
      // Host-broadcast opening beat. The guest mirrors the warmup countdown;
      // the first ms_state that follows flips both sides into the battle.
      _enterWarmup((message['duration'] as num?)?.toInt() ?? _warmupSeconds);
      return;
    }
    final t = message['t'];
    if (t == 'ms_state' && _isHost != true) {
      final s = message['s'];
      if (s is Map) {
        _battle = MainStageBattleState.fromMap(Map<String, dynamic>.from(s));
        if (_phase != _Phase.battle && !_battle!.isOver) {
          setState(() => _phase = _Phase.battle);
        }
        _afterBattleState(broadcast: false);
      }
    } else if (t == 'ms_intent' && _isHost == true) {
      final ev = _eventFromName(message['ev'] as String?);
      if (ev != null) _hostApply(ev, by: message['by'] as String?);
    }
  }

  MsEvent? _eventFromName(String? n) {
    switch (n) {
      case 'yield':
        return MsEvent.yield;
      case 'interrupt':
        return MsEvent.interrupt;
      case 'endEarly':
        return MsEvent.endEarly;
      default:
        return null;
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

  /// Whether THIS device takes the floor first (for the warmup indicator).
  /// The coin flip picks the HOST to lead or not; the host device leads when
  /// hostGoesFirst, the guest leads when it doesn't - so each side is "first"
  /// exactly when its host-ness matches the flip. Identical maths both sides.
  bool get _iGoFirst => _isHost != null && (_isHost! == _hostGoesFirst());

  /// HOST: the opening warmup beat, then open the chess-clock engine and drive
  /// it. The warmup is a fixed shared beat (both mics open) inside the recorded
  /// channel - pre-fight banter/staredown, captured and shown to spectators.
  Future<void> _runHostSequence() async {
    if (_warmupSeconds > 0 && !_violationEnded) {
      await _videoCallService.sendMatchMessage(
          {'type': 'warmup', 'duration': _warmupSeconds});
      _enterWarmup(_warmupSeconds);
      await Future<void>.delayed(Duration(seconds: _warmupSeconds));
    }
    if (_violationEnded || !mounted) return;
    _openEngine();
  }

  /// HOST: open the chess-clock engine and start the authoritative tick. The
  /// coin-flipped leader (by Firebase uid) takes the floor first.
  void _openEngine() {
    if (_engineStarted) return;
    _engineStarted = true;
    final firstFloor = _hostGoesFirst() ? _myFirebaseUid : _oppFirebaseUid;
    var b = MainStageBattleState.create(
      [_myFirebaseUid, _oppFirebaseUid],
      config: _battleConfig,
    );
    b = b.reduce(MsEvent.open, by: firstFloor, atMs: _nowMs);
    _battle = b;
    if (mounted) setState(() => _phase = _Phase.battle);
    _afterBattleState(broadcast: true);
    _battleTick = Timer.periodic(const Duration(milliseconds: 300), (_) {
      if (_battle == null || _battle!.isOver || _violationEnded) return;
      _hostApply(MsEvent.tick);
    });
  }

  /// HOST: apply an event, auto-start the holder's talk clock (V1 keeps talk
  /// auto-started; voice-driven start is a later refinement), then broadcast.
  void _hostApply(MsEvent ev, {String? by}) {
    if (_isHost != true || _battle == null) return;
    var b = _battle!.reduce(ev, by: by, atMs: _nowMs);
    if (b.floor != null && !b.talking) {
      b = b.reduce(MsEvent.startTalking, by: b.floor, atMs: _nowMs);
    }
    _battle = b;
    _afterBattleState(broadcast: true);
  }

  /// Push an intent: the host applies it; the guest sends it to the host (the
  /// authority). The engine re-checks validity either way.
  void _intent(MsEvent ev) {
    if (_battle == null || _battle!.isOver || _violationEnded) return;
    if (_isHost == true) {
      _hostApply(ev, by: _myFirebaseUid);
    } else {
      _videoCallService
          .sendMatchMessage({'t': 'ms_intent', 'ev': ev.name, 'by': _myFirebaseUid});
    }
  }

  /// Common reaction to any new battle state: one speaker at a time (mute me
  /// unless I hold the floor), repaint, broadcast if host, settle on end.
  void _afterBattleState({required bool broadcast}) {
    final b = _battle;
    if (b == null) return;
    _videoCallService.muteLocalAudio(b.mutedPlayer == _myFirebaseUid);
    if (broadcast && _isHost == true) {
      _videoCallService.sendMatchMessage({'t': 'ms_state', 's': b.toMap()});
    }
    _driveInterruptCue(b);
    if (mounted) setState(() {});
    if (b.isOver) {
      _battleTick?.cancel();
      _goToVerdict();
    }
  }

  /// Flash + buzz the floor-holder's clock while an interrupt is winding up.
  /// The haptic fires once, only on MY device, only when I'm the one being
  /// cut into. No-op when interrupts are off (nothing ever pends).
  void _driveInterruptCue(MainStageBattleState b) {
    final pending = b.pendingBy != null && b.status == MsStatus.live;
    if (pending && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!pending && _pulse.isAnimating) {
      _pulse.stop();
      _pulse.value = 0;
    }
    final iAmTarget =
        pending && b.pendingBy == _oppFirebaseUid && b.floor == _myFirebaseUid;
    if (iAmTarget && !_beingInterrupted) {
      _beingInterrupted = true;
      HapticFeedback.heavyImpact();
    } else if (!iAmTarget && _beingInterrupted) {
      _beingInterrupted = false;
    }
  }

  /// Enter the warmup phase (both mics open) with a cosmetic countdown. Shared
  /// by the host (who then waits it out) and the guest (mirroring the host's
  /// broadcast); the first ms_state afterwards flips both into the battle.
  void _enterWarmup(int seconds) {
    if (!mounted || _phase == _Phase.battle || _phase == _Phase.verdict) return;
    setState(() {
      _phase = _Phase.warmup;
      _secondsRemaining = seconds;
    });
    _videoCallService.muteLocalAudio(false);
    _startWarmupTicker(seconds);
  }

  String get _oppFirebaseUid => _opponentFirebaseUid;

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
      // No round boundaries - a chess-clock battle has no rounds, so the
      // highlight renders full-length.
      await _matchmakingService.completeMatch(
        widget.pairing.matchId,
        quality: _quality.summary,
      );
      if (mounted) setState(() => _matchCompleted = true);
    } catch (e) {
      if (mounted) setState(() => _matchSaveError = 'Could not save match: $e');
    }
  }

  /// The match document reached a terminal status server-side. If we haven't
  /// already ended (the engine's final state landed, or a content violation
  /// ended us), force the verdict now - this rescues a guest stranded mid-
  /// battle because the host's final state message was lost. [_goToVerdict]
  /// mutes, leaves the channel and settles (idempotent), exactly as the normal
  /// end-of-battle transition does.
  void _onMatchDoc(DocumentSnapshot<Map<String, dynamic>> snap) {
    if (!mounted) return;
    final status = snap.data()?['status'] as String?;
    const terminal = {'completed', 'abandoned', 'disqualified'};
    if (status == null || !terminal.contains(status)) return;
    if (_phase == _Phase.verdict || _violationEnded) return;
    _goToVerdict();
  }

  /// The battle is over (both clocks drained, or ended early). Mute, leave the
  /// channel (an idle channel bills and would relay cross-talk on the "Match
  /// complete!" screen), and settle. Both devices run this - the engine's
  /// final state reaches both, and the match-doc backstop covers a dropped
  /// message - and it is idempotent (guarded by the phase, and completeMatch
  /// is a server-side no-op the second time).
  void _goToVerdict() {
    if (_phase == _Phase.verdict || _violationEnded) return;
    _ticker?.cancel();
    _battleTick?.cancel();
    if (mounted) setState(() => _phase = _Phase.verdict);
    _videoCallService.muteLocalAudio(true);
    unawaited(_videoCallService.leaveChannel());
    unawaited(_completeMatch());
  }

  /// A cosmetic 1s countdown for the warmup banner only - the battle clock is
  /// the engine's. The host's real warmup length is its Future.delayed; this
  /// just animates the number.
  void _startWarmupTicker(int seconds) {
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

  @override
  void dispose() {
    _ticker?.cancel();
    _battleTick?.cancel();
    _pulse.dispose();
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
    final inBattle = _phase == _Phase.battle && _battle != null;

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
          // Lift the self-view above the chess-clock controls during the
          // battle so it never sits under the Yield button.
          bottom: inBattle ? 120 : 16,
          width: 100,
          height: 140,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: _videoCallService.localVideoView(),
          ),
        ),
        if (_phase == _Phase.warmup) _buildWarmupOverlay(),
        if (inBattle) ..._buildBattleOverlay(_battle!),
        // Tap-to-deploy power-ups (tomato/extend). Interrupt is deployed from
        // the chess-clock controls themselves, not here. Sits just above the
        // controls; self-hides when abilities are off or none were brought.
        if (_phase == _Phase.warmup || inBattle)
          Positioned(
            left: 16,
            bottom: (inBattle ? 92 : 16) + MediaQuery.of(context).padding.bottom,
            child: AbilityDeployBar(
              matchId: widget.pairing.matchId,
              onDeploy: _onDeployAbility,
            ),
          ),
      ],
    );
  }

  /// A power-up was deployed from the tap-to-deploy bar. The in-match EFFECT
  /// (tomato splat, +5s extend) is format-specific and wired into the chess-
  /// clock battle as part of the abilities-effects build; for now this confirms
  /// the tap. (Interrupt is deployed from the controls, not here.)
  void _onDeployAbility(String abilityId) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(milliseconds: 1200),
        content: Text('$abilityId deployed'),
      ),
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
              // Who takes the floor first, surfaced during the warmup so that
              // roaster knows to be ready (coin-flipped, not always the same
              // player). Only shown once host election has resolved who leads.
              if (_isHost != null) ...[
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

  /// The chess-clock battle overlay: two clock chips at the top, the
  /// yield/interrupt controls at the bottom. Adapted from
  /// MainStageBattleScreen; "You"/"Them" keyed by Firebase uid.
  List<Widget> _buildBattleOverlay(MainStageBattleState b) {
    return [_clocks(b), if (!b.isOver) _controls(b)];
  }

  String _fmt(int ms) {
    final s = (ms / 1000).ceil();
    final m = s ~/ 60;
    final r = s % 60;
    return '$m:${r.toString().padLeft(2, '0')}';
  }

  Widget _clocks(MainStageBattleState b) {
    // The clock of whoever is being cut into flashes red (on both screens).
    final target = b.pendingBy == null
        ? null
        : (b.pendingBy == _myFirebaseUid ? _oppFirebaseUid : _myFirebaseUid);
    return Positioned(
      top: 12,
      left: 12,
      right: 12,
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (context, _) => Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _clockChip('You', b.remaining[_myFirebaseUid] ?? 0,
                b.floor == _myFirebaseUid, b.steals[_myFirebaseUid] ?? 0,
                flash: target == _myFirebaseUid),
            _clockChip('Them', b.remaining[_oppFirebaseUid] ?? 0,
                b.floor == _oppFirebaseUid, b.steals[_oppFirebaseUid] ?? 0,
                flash: target == _oppFirebaseUid),
          ],
        ),
      ),
    );
  }

  Widget _clockChip(String label, int ms, bool onFloor, int steals,
      {bool flash = false}) {
    final gold = context.palette.reward;
    const hotRed = Color(0xFFFF2D3A);
    final t = flash ? Curves.easeInOut.transform(_pulse.value) : 0.0;
    final baseBorder = onFloor ? gold : Colors.white24;
    final totalSteals = _settings.interrupts;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: onFloor ? gold.withValues(alpha: 0.9) : Colors.black54,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: flash ? Color.lerp(baseBorder, hotRed, 0.4 + 0.6 * t)! : baseBorder,
          width: flash ? 2.5 : (onFloor ? 2 : 1),
        ),
        boxShadow: flash
            ? [
                BoxShadow(
                  color: hotRed.withValues(alpha: 0.25 + 0.45 * t),
                  blurRadius: 8 + 12 * t,
                  spreadRadius: 1 + 2 * t,
                ),
              ]
            : null,
      ),
      child: Column(
        children: [
          Text(label,
              style: TextStyle(
                  color: onFloor ? Colors.black : Colors.white70,
                  fontSize: 11,
                  fontWeight: FontWeight.w700)),
          Text(_fmt(ms),
              style: TextStyle(
                  color: onFloor ? Colors.black : Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w900)),
          // Interrupt pips only when interrupts are in play (loadout granted
          // some). Yield-only battles show no pip row.
          if (totalSteals > 0 || steals > 0)
            Text('${'●' * steals}${'○' * (totalSteals - steals).clamp(0, 99)}',
                style: TextStyle(
                    color: onFloor ? Colors.black87 : Colors.white54,
                    fontSize: 12)),
        ],
      ),
    );
  }

  Widget _controls(MainStageBattleState b) {
    final iHoldFloor = b.floor == _myFirebaseUid;
    final oppHoldsFloor = b.floor == _oppFirebaseUid;
    final oppOutOfTime = (b.remaining[_oppFirebaseUid] ?? 0) == 0;
    final iAmInterrupting = b.pendingBy == _myFirebaseUid;
    final canInterrupt = oppHoldsFloor &&
        (b.steals[_myFirebaseUid] ?? 0) > 0 &&
        (b.remaining[_myFirebaseUid] ?? 0) > 0 &&
        b.pendingBy == null;

    // Dead-air escape: you hold the floor, your opponent is spent, nothing left
    // to say. End it rather than draining a banked clock in silence - nothing
    // is forfeited, the battle would end when your clock ran out anyway.
    if (iHoldFloor && oppOutOfTime) {
      return Positioned(
        left: 16,
        right: 16,
        bottom: 24 + MediaQuery.of(context).padding.bottom,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              "They're out of time - the floor is yours. Land one more, or end it.",
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white60, fontSize: 13),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => _intent(MsEvent.endEarly),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 54),
                  backgroundColor: context.palette.reward,
                  foregroundColor: Colors.black,
                ),
                child: const Text("I'm done - end the battle"),
              ),
            ),
          ],
        ),
      );
    }
    // Interrupt only appears when the player actually has steals (loadout);
    // the amateur base is yield-only, so most battles show Yield alone.
    final showInterrupt = (b.steals[_myFirebaseUid] ?? 0) > 0 || iAmInterrupting;
    return Positioned(
      left: 16,
      right: 16,
      bottom: 24 + MediaQuery.of(context).padding.bottom,
      child: Row(
        children: [
          Expanded(
            child: FilledButton(
              onPressed: iHoldFloor ? () => _intent(MsEvent.yield) : null,
              style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 54),
                  backgroundColor: Colors.white24),
              child: const Text('Yield'),
            ),
          ),
          if (showInterrupt) ...[
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                onPressed: canInterrupt ? () => _intent(MsEvent.interrupt) : null,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 54),
                  backgroundColor: iAmInterrupting
                      ? context.palette.reward
                      : context.palette.live,
                  foregroundColor: iAmInterrupting ? Colors.black : null,
                ),
                child: Text(iAmInterrupting
                    ? 'Cutting in...'
                    : 'Interrupt (${b.steals[_myFirebaseUid] ?? 0})'),
              ),
            ),
          ],
        ],
      ),
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
