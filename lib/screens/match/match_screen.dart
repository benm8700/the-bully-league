import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';


import 'package:provider/provider.dart';

import '../../core/main_stage_battle.dart';
import '../../core/services/abilities_service.dart';
import '../../core/services/agora_token_service.dart';
import '../../core/services/agora_video_service.dart';
import '../../core/services/matchmaking_service.dart';
import '../../core/services/capture_quality.dart';
import '../../core/services/fart_player.dart';
import '../../core/services/video_call_service.dart';
import '../../core/services/visual_moderation_service.dart';
import '../../core/services/yuv_to_jpeg.dart';
import '../../theme/app_theme.dart';
import '../../widgets/match/ability_deploy_bar.dart';
import '../../widgets/match/tomato_splat.dart';
import '../vote/my_battles_screen.dart';
import '../vote/vote_queue_screen.dart';
import 'pre_match_screen.dart';

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

  // Warm-up skip: BOTH players must agree to end the warmup early. Each sends
  // a skipWarmup message when they tap; the HOST (which drives the timeline)
  // ends the warmup the moment it holds both agreements. The Skip Warm-Up
  // ABILITY (below) bypasses the mutual rule: one person ends it for both.
  bool _mySkipRequested = false;
  bool _oppSkipRequested = false;
  // The Skip Warm-Up ability (a paid power-up; free in friend battles). Loaded
  // at warmup start so the button can appear; _skipWarmupUsed is the one-shot
  // guard (maxPerMatch is 1). Both players' counts come from the server.
  MatchAbilities? _matchAbilities;
  bool _loadingAbilities = false;
  bool _skipWarmupUsed = false;
  // The host's warmup wait resolves EITHER on the full timer OR early when
  // both agree to skip - a single place that opens the engine, so the skip
  // never races a second _openEngine against _runHostSequence.
  Completer<void>? _warmupSkip;
  // Re-announces this side's skip intent every couple of seconds while in
  // warmup, so a peer who (re)joins mid-warmup learns about a skip request
  // that was sent before it was listening.
  Timer? _skipResend;
  bool _matchCompleted = false;
  bool _completeRequested = false;
  String? _matchSaveError;
  // Friend-battle rematch: re-challenge the same opponent from the end screen.
  bool _rematchSending = false;
  bool _rematchSent = false;
  // While a rematch is out, poll for the opponent accepting (or sending their
  // own), so the sender is pulled straight into the new battle without having
  // to go back to Home - the "both tap Rematch, reconnect automatically" rule.
  Timer? _rematchPoll;
  bool _rematchJoining = false;
  // Set once the Agora engine has been torn down (either by dispose() going
  // Home, or by _joinRematch tearing it down early). Guards against a double
  // release and against disposing already-disposed notifiers.
  bool _videoTornDown = false;
  // Plays the Fart ability's sound locally (never recorded).
  final FartPlayer _fartPlayer = FartPlayer();

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

  // Tomato splat (a loadout ability): a brief full-screen splat on the RECEIVER
  // only, rendered over the Flutter UI so it never touches the recording.
  bool _tomatoSplat = false;
  int _splatSeq = 0; // bumped per throw so a repeat splat replays its animation
  Timer? _splatTimer;

  // The Instant Interrupt cue (no grace, so the floor just snaps - this makes
  // the steal visible on both screens). Seq replays the one-shot flash.
  bool _stealFlash = false;
  int _stealSeq = 0;
  Timer? _stealTimer;

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
    if (message['type'] == 'skipWarmup') {
      // The other player wants to end the warmup early. Record it; the HOST
      // ends the warmup once BOTH have agreed (mutual, see _maybeEndWarmup).
      if (message['by'] != _myFirebaseUid) {
        if (!_oppSkipRequested && mounted) {
          setState(() => _oppSkipRequested = true);
        }
        _maybeEndWarmupEarly();
      }
      return;
    }
    if (message['type'] == 'forceSkipWarmup') {
      // The opponent SPENT a Skip Warm-Up ability: end the warmup for both
      // NOW, no mutual agreement. Only the host drives the timeline, so only
      // it acts; the guest flips to battle on the host's first ms_state.
      if (message['by'] != _myFirebaseUid) _forceEndWarmup();
      return;
    }
    final t = message['t'];
    if (t == 'ability' && message['id'] == 'tomato') {
      // A tomato splats on the RECEIVER's screen. Ephemeral and client-only -
      // it renders over the Flutter UI, never into the Agora stream, so it can
      // never reach the recording (the heckle-graphics welfare rule).
      _showTomatoSplat();
      return;
    }
    if (t == 'ability' && message['id'] == 'fart') {
      // A random fart plays on the RECEIVER's phone - locally, through the
      // device audio, NEVER through Agora, so it's a live hindrance but is not
      // captured in the recording (same client-only rule as the tomato).
      _fartPlayer.playRandom();
      return;
    }
    if (t == 'fx' && message['id'] == 'instantSteal') {
      // An Instant Interrupt has no grace window (unlike the graced interrupt's
      // flash + buzz), so the floor just snaps over. This cue makes that
      // visible to the person being cut off. Client-only, like the tomato.
      _showStealFlash();
      return;
    }
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
      if (ev != null) {
        _hostApply(ev,
            by: message['by'] as String?, instant: message['instant'] == true);
      }
    }
  }

  MsEvent? _eventFromName(String? n) {
    switch (n) {
      case 'yield':
        return MsEvent.yield;
      case 'interrupt':
        return MsEvent.interrupt;
      case 'extend':
        return MsEvent.extend;
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
      // Wait out the warmup, OR end it early when both players agree to skip
      // (whichever comes first). The early end completes _warmupSkip from
      // _maybeEndWarmupEarly - so the engine still opens through THIS one path.
      _warmupSkip = Completer<void>();
      await Future.any<void>([
        Future<void>.delayed(Duration(seconds: _warmupSeconds)),
        _warmupSkip!.future,
      ]);
    }
    if (_violationEnded || !mounted) return;
    await _openEngine();
  }

  /// HOST: open the chess-clock engine and start the authoritative tick.
  ///
  /// Seeds each player's interrupt/extend tokens and the go-first choice from
  /// the paid loadout (server-resolved, since the opponent's loadout is not
  /// client-readable). FAILS OPEN to the base yield-only / coin-flip format if
  /// that resolution can't be read - abilities are a bonus, never a gate on the
  /// battle starting. With abilities off every count is 0, so this is exactly
  /// the amateur base: 30s each, yield-only, coin-flip first.
  Future<void> _openEngine() async {
    if (_engineStarted) return;
    _engineStarted = true;

    Map<String, int>? steals;
    Map<String, int>? instantSteals;
    Map<String, int>? extendsBy;
    var myGoFirst = false;
    var oppGoFirst = false;
    var myGoSecond = false;
    var oppGoSecond = false;
    try {
      // Reuse the counts already loaded at warmup start when present.
      final ab = _matchAbilities ??
          await AbilitiesService.getMatchAbilities(widget.pairing.matchId);
      _matchAbilities = ab;
      if (ab.enabled) {
        steals = {
          _myFirebaseUid: ab.count(_myFirebaseUid, 'interrupt'),
          _oppFirebaseUid: ab.count(_oppFirebaseUid, 'interrupt'),
        };
        instantSteals = {
          _myFirebaseUid: ab.count(_myFirebaseUid, 'instantInterrupt'),
          _oppFirebaseUid: ab.count(_oppFirebaseUid, 'instantInterrupt'),
        };
        extendsBy = {
          _myFirebaseUid: ab.count(_myFirebaseUid, 'extend'),
          _oppFirebaseUid: ab.count(_oppFirebaseUid, 'extend'),
        };
        myGoFirst = ab.count(_myFirebaseUid, 'goFirst') > 0;
        oppGoFirst = ab.count(_oppFirebaseUid, 'goFirst') > 0;
        myGoSecond = ab.count(_myFirebaseUid, 'goSecond') > 0;
        oppGoSecond = ab.count(_oppFirebaseUid, 'goSecond') > 0;
      }
    } catch (_) {
      // Base format.
    }
    if (!mounted || _violationEnded) return;

    // Who takes the floor first, honouring BOTH abilities: Go First claims the
    // first slot; Go Second claims the second slot (i.e. hands the opponent
    // first). A player "wants first" if they brought Go First OR their opponent
    // brought Go Second. If exactly one side ends up wanting first, they lead;
    // a conflict (both want the same slot) or neither -> the coin flip.
    final meWantsFirst = myGoFirst || oppGoSecond;
    final oppWantsFirst = oppGoFirst || myGoSecond;
    final String firstFloor;
    if (meWantsFirst && !oppWantsFirst) {
      firstFloor = _myFirebaseUid;
    } else if (oppWantsFirst && !meWantsFirst) {
      firstFloor = _oppFirebaseUid;
    } else {
      firstFloor = _hostGoesFirst() ? _myFirebaseUid : _oppFirebaseUid;
    }

    var b = MainStageBattleState.create(
      [_myFirebaseUid, _oppFirebaseUid],
      config: _battleConfig,
      stealsByPlayer: steals,
      instantStealsByPlayer: instantSteals,
      extendsByPlayer: extendsBy,
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
  void _hostApply(MsEvent ev, {String? by, bool instant = false}) {
    if (_isHost != true || _battle == null) return;
    var b = _battle!.reduce(ev, by: by, atMs: _nowMs, instant: instant);
    if (b.floor != null && !b.talking) {
      b = b.reduce(MsEvent.startTalking, by: b.floor, atMs: _nowMs);
    }
    _battle = b;
    _afterBattleState(broadcast: true);
  }

  /// Push an intent: the host applies it; the guest sends it to the host (the
  /// authority). The engine re-checks validity either way. [instant] marks an
  /// interrupt as the no-grace instant-interrupt ability.
  void _intent(MsEvent ev, {bool instant = false}) {
    if (_battle == null || _battle!.isOver || _violationEnded) return;
    if (_isHost == true) {
      _hostApply(ev, by: _myFirebaseUid, instant: instant);
    } else {
      _videoCallService.sendMatchMessage({
        't': 'ms_intent',
        'ev': ev.name,
        'by': _myFirebaseUid,
        'instant': instant,
      });
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
    // Load both players' ability counts now so the Skip Warm-Up button can
    // appear during the warmup (the engine reuses this cache at battle start).
    _loadMatchAbilities();
  }

  /// Fetch both players' resolved ability counts (server-authoritative) once.
  /// Fire-and-forget: a failure just means no Skip Warm-Up button, never a
  /// blocked warmup.
  Future<void> _loadMatchAbilities() async {
    if (_matchAbilities != null || _loadingAbilities) return;
    _loadingAbilities = true;
    try {
      final ab = await AbilitiesService.getMatchAbilities(widget.pairing.matchId);
      if (mounted) setState(() => _matchAbilities = ab);
    } catch (_) {
      // No button; fine.
    } finally {
      _loadingAbilities = false;
    }
  }

  /// This player taps "Skip warm-up". Announces it to the opponent and, if the
  /// opponent has already agreed, ends the warmup. Both must agree - a single
  /// tap only arms this side.
  void _requestSkipWarmup() {
    if (_phase != _Phase.warmup || _mySkipRequested) return;
    setState(() => _mySkipRequested = true);
    _sendSkipIntent();
    // Re-announce every 2s so a peer that (re)joins mid-warmup still learns
    // this standing request; self-cancels once warmup is over.
    _skipResend?.cancel();
    _skipResend = Timer.periodic(const Duration(seconds: 2), (t) {
      if (!mounted || _phase != _Phase.warmup || !_mySkipRequested) {
        t.cancel();
        return;
      }
      _sendSkipIntent();
    });
    _maybeEndWarmupEarly();
  }

  void _sendSkipIntent() {
    _videoCallService
        .sendMatchMessage({'type': 'skipWarmup', 'by': _myFirebaseUid});
  }

  /// Ends the warmup early once BOTH players have asked to skip. Only the HOST
  /// acts (it drives the timeline): it completes the warmup wait, so the engine
  /// opens through the SINGLE path in _runHostSequence rather than a second,
  /// racing _openEngine call. The guest flips to battle when the host's first
  /// ms_state arrives.
  void _maybeEndWarmupEarly() {
    if (_phase != _Phase.warmup || _isHost != true) return;
    if (!_mySkipRequested || !_oppSkipRequested) return;
    _forceEndWarmup();
  }

  /// Spend a Skip Warm-Up ABILITY: end the warmup for BOTH players right now,
  /// with no mutual agreement (unlike _requestSkipWarmup). One-shot per match.
  void _deploySkipWarmup() {
    if (_phase != _Phase.warmup || _skipWarmupUsed) return;
    setState(() => _skipWarmupUsed = true);
    _toast('Skipping warm-up');
    if (_isHost == true) {
      _forceEndWarmup();
    } else {
      // The host owns the timeline; ask it to end and broadcast battle start.
      _videoCallService
          .sendMatchMessage({'type': 'forceSkipWarmup', 'by': _myFirebaseUid});
    }
  }

  /// HOST: end the warmup now, through the SAME single Completer path
  /// _runHostSequence awaits - so the engine still opens exactly once, whether
  /// the end came from the full timer, a mutual skip, or a Skip Warm-Up ability.
  void _forceEndWarmup() {
    if (_isHost != true || _phase != _Phase.warmup) return;
    _ticker?.cancel();
    _skipResend?.cancel();
    if (_warmupSkip != null && !_warmupSkip!.isCompleted) {
      _warmupSkip!.complete();
    }
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

  /// Removes every listener/subscription on the video service and releases the
  /// Agora engine. Idempotent via [_videoTornDown]. Awaitable, because the
  /// rematch path MUST finish releasing the native engine before the next
  /// pre-match check initializes a new one (one native engine per process -
  /// skipping the await leaves the camera/mic dead on the next screen).
  Future<void> _tearDownVideo() async {
    if (_videoTornDown) return;
    _videoTornDown = true;
    _frameSampleSub?.cancel();
    _localFrameSub?.cancel();
    _videoCallService.localAudioLevel.removeListener(_onLocalAudioLevel);
    _videoCallService.localUid.removeListener(_maybeElectHost);
    _videoCallService.remoteUid.removeListener(_maybeElectHost);
    await _videoCallService.dispose();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _battleTick?.cancel();
    _skipResend?.cancel();
    _splatTimer?.cancel();
    _stealTimer?.cancel();
    _rematchPoll?.cancel();
    _pulse.dispose();
    _msgSub?.cancel();
    _matchDocSub?.cancel();
    _fartPlayer.dispose();
    // Fire-and-forget here (State.dispose can't await); already a no-op if
    // _joinRematch tore it down first.
    _tearDownVideo();
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
        content: Text(
          // "your opponent keeps going without you" was confusing - a 1v1
          // roast has nothing to continue solo. Friend battles carry no
          // penalty at all (not scored, not recorded).
          widget.pairing.mode == 'friend'
              ? 'The battle is still going. Leaving now ends it - but a '
                  'friend battle is just for fun, so there is no penalty. '
                  'You can challenge them again any time.'
              : 'The battle is still going. If you leave now it can count '
                  'as a loss.',
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
              // +5s only works on your own clock, so gate its button on holding
              // the floor; tomato stays always-on inside the bar.
              holdsFloor: inBattle && _battle?.floor == _myFirebaseUid,
            ),
          ),
        if (_tomatoSplat)
          Positioned.fill(
            child: TomatoSplat(
              key: ValueKey(_splatSeq),
              onDone: () {
                if (mounted) setState(() => _tomatoSplat = false);
              },
            ),
          ),
        if (_stealFlash) Positioned.fill(child: _buildStealFlash()),
      ],
    );
  }

  /// A power-up was deployed from the tap-to-deploy bar. Interrupt is NOT here
  /// (it's the chess-clock controls' button); this handles the bar abilities:
  ///  - extend: feed MsEvent.extend into the engine (+5s to your clock, and it
  ///    defers an incoming interrupt) - the engine enforces the token count.
  ///  - tomato: broadcast a splat to the opponent (ephemeral, never recorded).
  void _onDeployAbility(String abilityId) {
    if (!mounted) return;
    switch (abilityId) {
      case 'extend':
        _intent(MsEvent.extend);
        _toast('+5 seconds');
      case 'tomato':
        _videoCallService
            .sendMatchMessage({'t': 'ability', 'id': 'tomato', 'by': _myFirebaseUid});
        _toast('Tomato thrown');
      case 'fart':
        // Fires a random fart on the opponent's phone (local sound only, never
        // recorded). Nothing plays on this device - it's their hindrance.
        _videoCallService
            .sendMatchMessage({'t': 'ability', 'id': 'fart', 'by': _myFirebaseUid});
        _toast('Fart deployed');
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(duration: const Duration(milliseconds: 1200), content: Text(message)),
    );
  }

  /// Show the tomato splat briefly (I'm the target). Client-only overlay.
  /// Deploy the Instant Interrupt: snap the floor with no grace, flash the cue
  /// locally, and tell the opponent so their screen flashes too.
  void _deployInstant() {
    _intent(MsEvent.interrupt, instant: true);
    _showStealFlash();
    _videoCallService
        .sendMatchMessage({'t': 'fx', 'id': 'instantSteal', 'by': _myFirebaseUid});
  }

  void _showStealFlash() {
    if (!mounted) return;
    HapticFeedback.heavyImpact();
    setState(() {
      _stealSeq++;
      _stealFlash = true;
    });
    _stealTimer?.cancel();
    _stealTimer = Timer(const Duration(milliseconds: 750), () {
      if (mounted) setState(() => _stealFlash = false);
    });
  }

  /// A one-shot "cut in" flash for the Instant Interrupt: a quick gold wash and
  /// a bolt that pops and fades. Replays per [_stealSeq].
  Widget _buildStealFlash() {
    final gold = context.palette.reward;
    return IgnorePointer(
      child: TweenAnimationBuilder<double>(
        key: ValueKey(_stealSeq),
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 650),
        curve: Curves.easeOut,
        builder: (context, t, _) {
          final fade = t < 0.35 ? 1.0 : (1 - (t - 0.35) / 0.65);
          return Opacity(
            opacity: fade.clamp(0.0, 1.0),
            child: Container(
              color: gold.withValues(alpha: 0.16 * (1 - t)),
              alignment: Alignment.center,
              child: Transform.scale(
                scale: 0.6 + 0.6 * Curves.easeOutBack.transform(t.clamp(0.0, 1.0)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.bolt, color: gold, size: 52),
                    const Text('CUT IN!',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 42,
                          fontWeight: FontWeight.w900,
                          shadows: [Shadow(color: Colors.black, blurRadius: 8)],
                        )),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  void _showTomatoSplat() {
    if (!mounted) return;
    setState(() {
      _splatSeq++;
      _tomatoSplat = true;
    });
    // The TomatoSplat widget self-times (~1.1s) and clears via onDone; this is
    // a backstop in case onDone never fires (e.g. disposed mid-animation).
    _splatTimer?.cancel();
    _splatTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _tomatoSplat = false);
    });
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
              const SizedBox(height: 4),
              _buildWarmupSkipAbility(),
              _buildWarmupSkip(),
            ],
          ),
        ),
      ),
    );
  }

  /// The Skip Warm-Up ability button: shown only when this player actually
  /// holds a charge (bought it in ranked, or free in a friend battle) and
  /// hasn't spent it. One tap ends the warmup for both - no waiting on the
  /// opponent, unlike the mutual control below.
  Widget _buildWarmupSkipAbility() {
    final have = (_matchAbilities?.count(_myFirebaseUid, 'skipWarmup') ?? 0) > 0;
    if (!have || _skipWarmupUsed) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: FilledButton.tonalIcon(
        onPressed: _deploySkipWarmup,
        icon: const Icon(Icons.bolt, size: 16),
        style: FilledButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          minimumSize: const Size(0, 30),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        label: const Text('Skip for both now', style: TextStyle(fontSize: 12)),
      ),
    );
  }

  /// Small, unobtrusive "skip warm-up" control under the warmup banner. Both
  /// players must tap it; a single tap arms this side and waits for the other.
  Widget _buildWarmupSkip() {
    if (_mySkipRequested) {
      return const Text(
        'Waiting for your opponent to skip…',
        style: TextStyle(color: Colors.white54, fontSize: 12),
      );
    }
    final agreeing = _oppSkipRequested;
    return TextButton.icon(
      onPressed: _requestSkipWarmup,
      icon: Icon(Icons.fast_forward,
          size: 16, color: agreeing ? Colors.amberAccent : Colors.white70),
      style: TextButton.styleFrom(
        foregroundColor: agreeing ? Colors.amberAccent : Colors.white70,
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(0, 28),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      label: Text(
        agreeing ? 'Opponent wants to skip — tap to agree' : 'Skip warm-up',
        style: const TextStyle(fontSize: 12),
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
    final instantN = b.instantSteals[_myFirebaseUid] ?? 0;
    final canInstant = oppHoldsFloor &&
        instantN > 0 &&
        (b.remaining[_myFirebaseUid] ?? 0) > 0 &&
        b.pendingBy == null;
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
          if (instantN > 0) ...[
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                onPressed: canInstant ? _deployInstant : null,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 54),
                  backgroundColor: context.palette.reward,
                  foregroundColor: Colors.black,
                ),
                child: Text('Instant ($instantN)'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Re-challenge the same opponent (friend battles only), and converge both
  /// sides onto ONE new battle with no trip back to Home.
  ///
  /// If the opponent has ALREADY sent me a rematch (they tapped first), accept
  /// theirs and go straight in. Otherwise send my own and start polling: when
  /// they accept it - whether from this screen or from Home - the poll pulls me
  /// into the new battle. This is the "both tap Rematch, reconnect them
  /// automatically" rule, and also fixes the sender being stranded on "Match
  /// complete" after the other person accepts.
  Future<void> _sendRematch() async {
    if (_rematchSending || _rematchSent || _rematchJoining) return;
    setState(() => _rematchSending = true);
    final oppId = widget.pairing.opponentId;
    final fns = FirebaseFunctions.instance;
    try {
      // Did they beat me to it? Accept their incoming rematch instead of
      // creating a second, competing challenge.
      final mine = await fns.httpsCallable('getMyChallenges')
          .call<Map<String, dynamic>>();
      final incoming = (mine.data['incoming'] as List?) ?? const [];
      final theirs = incoming.cast<dynamic>().firstWhere(
            (c) => (c as Map)['fromUid'] == oppId,
            orElse: () => null,
          );
      if (theirs != null) {
        final r = await fns.httpsCallable('respondToChallenge')
            .call<Map<String, dynamic>>({
          'challengeId': (theirs as Map)['challengeId'],
          'accept': true,
        });
        final matchId = r.data['matchId'] as String?;
        if (matchId != null) {
          await _joinRematch(matchId);
          return;
        }
      }

      // Nobody's waiting yet - send mine and poll for them to take it up.
      await fns.httpsCallable('challengeFriend')
          .call<Map<String, dynamic>>({'toUid': oppId});
      if (!mounted) return;
      setState(() {
        _rematchSent = true;
        _rematchSending = false;
      });
      _rematchPoll?.cancel();
      _rematchPoll = Timer.periodic(
          const Duration(seconds: 3), (_) => _pollRematch());
    } catch (_) {
      if (!mounted) return;
      setState(() => _rematchSending = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not send the rematch - try again.')),
      );
    }
  }

  /// While my rematch is out: join the moment they accept it, or - if we both
  /// sent at the same instant and neither saw the other - have exactly ONE side
  /// (the lower uid, a stable tiebreak) accept the other's so we don't create
  /// two matches.
  Future<void> _pollRematch() async {
    if (_rematchJoining || !mounted) return;
    final oppId = widget.pairing.opponentId;
    final fns = FirebaseFunctions.instance;
    try {
      final r =
          await fns.httpsCallable('getMyChallenges').call<Map<String, dynamic>>();
      final accepted = (r.data['accepted'] as List?) ?? const [];
      final taken = accepted.cast<dynamic>().firstWhere(
            (c) => (c as Map)['toUid'] == oppId,
            orElse: () => null,
          );
      if (taken != null) {
        await _joinRematch((taken as Map)['matchId'] as String);
        return;
      }
      // Simultaneous double-send: the lower uid accepts the other's incoming.
      if (_myFirebaseUid.compareTo(oppId) < 0) {
        final incoming = (r.data['incoming'] as List?) ?? const [];
        final theirs = incoming.cast<dynamic>().firstWhere(
              (c) => (c as Map)['fromUid'] == oppId,
              orElse: () => null,
            );
        if (theirs != null) {
          final resp = await fns.httpsCallable('respondToChallenge')
              .call<Map<String, dynamic>>({
            'challengeId': (theirs as Map)['challengeId'],
            'accept': true,
          });
          final matchId = resp.data['matchId'] as String?;
          if (matchId != null) await _joinRematch(matchId);
        }
      }
    } catch (_) {
      // Transient - the next tick retries.
    }
  }

  /// Replace this finished match's screen with the new battle's pre-match
  /// check, so finishing the rematch returns Home rather than to a stale
  /// "Match complete" screen.
  Future<void> _joinRematch(String matchId) async {
    if (_rematchJoining || !mounted) return;
    _rematchPoll?.cancel();
    setState(() => _rematchJoining = true);
    // Fully release THIS match's Agora engine before the new pre-match check
    // initializes a fresh one. createAgoraRtcEngine() is one native engine per
    // process, so a new initialize() while this one is still releasing left the
    // camera dead and the mic-gated Ready button unreachable (seen on device
    // after a rematch). Awaiting the teardown is the documented fix.
    await _tearDownVideo();
    if (!mounted) return;
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) =>
            PreMatchScreen(mode: 'friend', challengeMatchId: matchId),
      ),
    );
  }

  Widget _buildVerdictUi() {
    // A FRIEND battle is a private scrimmage - not judged, not with the crowd -
    // so it gets a rematch offer instead of the vote flow.
    final isFriend = widget.pairing.mode == 'friend';
    final scheme = Theme.of(context).colorScheme;
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
            if (isFriend) ...[
              const Text('Good battle. Run it back?', textAlign: TextAlign.center),
              const SizedBox(height: 24),
              if (_rematchJoining)
                const Column(mainAxisSize: MainAxisSize.min, children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 10),
                  Text('Starting the rematch…', textAlign: TextAlign.center),
                ])
              else if (_rematchSent)
                const Column(mainAxisSize: MainAxisSize.min, children: [
                  SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  SizedBox(height: 10),
                  Text("Rematch sent - waiting for them to jump back in…",
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Color(0xFF4FD69A))),
                ])
              else
                FilledButton.icon(
                  onPressed: _rematchSending ? null : _sendRematch,
                  icon: const Icon(Icons.replay),
                  label: Text(_rematchSending ? 'Sending…' : 'Rematch'),
                  // Purple (secondary), distinct from the pink Back-to-home.
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(200, 48),
                    backgroundColor: scheme.secondary,
                    foregroundColor: scheme.onSecondary,
                  ),
                ),
            ] else ...[
              // The reciprocal ask, made at the highest-intent moment in the
              // app: they're invested, waiting on their own verdict, and
              // already looking at this screen. Asking here converts far
              // better than a cold notification later.
              const Text(
                'Your battle is now with the crowd. They have 24 hours to call it.\n\n'
                'Vote on a few others while you wait - the more people who vote '
                'on a battle, the more it counts.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              if (_matchCompleted)
                FilledButton.icon(
                  onPressed: () => Navigator.of(context).pushReplacement(
                    MaterialPageRoute(builder: (_) => const VoteQueueScreen()),
                  ),
                  icon: const Icon(Icons.how_to_vote_outlined),
                  label: const Text('Vote on a battle'),
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
                TextButton.icon(
                  onPressed: () => Navigator.of(context).pushReplacement(
                    MaterialPageRoute(builder: (_) => const MyBattlesScreen()),
                  ),
                  icon: const Icon(Icons.leaderboard_outlined, size: 18),
                  label: const Text('Watch the votes come in'),
                ),
              ],
            ],
            const SizedBox(height: 16),
            // A big, easy-to-hit way home (the small arrow was hard to tap).
            // In a friend battle it's the PINK primary (paired with the purple
            // Rematch); in ranked it stays tonal so it doesn't fight the pink
            // "Vote on a battle" CTA above it.
            if (isFriend)
              FilledButton.icon(
                onPressed: () =>
                    Navigator.of(context).popUntil((route) => route.isFirst),
                icon: const Icon(Icons.home_outlined),
                label: const Text('Back to home'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(200, 48),
                  backgroundColor: scheme.primary,
                  foregroundColor: scheme.onPrimary,
                ),
              )
            else
              FilledButton.tonalIcon(
                onPressed: () =>
                    Navigator.of(context).popUntil((route) => route.isFirst),
                icon: const Icon(Icons.home_outlined),
                label: const Text('Back to home'),
                style: FilledButton.styleFrom(minimumSize: const Size(200, 48)),
              ),
          ],
        ),
      ),
    );
  }
}
