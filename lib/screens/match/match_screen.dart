import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/config/agora_config.dart';
import '../../core/services/agora_video_service.dart';
import '../../core/services/video_call_service.dart';
import '../../core/services/visual_moderation_service.dart';
import '../../core/services/yuv_to_jpeg.dart';

/// Round/turn/timer state machine (Build Order step 4). Real matchmaking
/// and Firestore match documents don't exist yet, so:
/// - Both devices join the same hardcoded "test-channel" (temp token, see
///   agora_config.dart) - same placeholder pattern as PreMatchScreen.
/// - Round count/length/countdown are hardcoded to the documented V1
///   defaults (CLAUDE.md's config/matchSettings schema) rather than pulled
///   from Firebase Remote Config, which isn't wired up yet.
/// - There's no server-authoritative state. One device is elected "host"
///   (lower Agora-assigned uid) and drives the real timer, broadcasting
///   state to the other over Agora's data-stream messaging
///   (sendStreamMessage/onStreamMessage - see AgoraVideoCallService). The
///   non-host device purely mirrors whatever the host broadcasts.
/// - Who goes first each round is always the host - CLAUDE.md doesn't
///   document a rule for this (e.g. alternating/coin-flip), so this is a
///   placeholder default, not a final decision. Flagged in CLAUDE.md.
class MatchScreen extends StatefulWidget {
  const MatchScreen({super.key});

  @override
  State<MatchScreen> createState() => _MatchScreenState();
}

enum _Phase { waitingForOpponent, countdown, turn, verdict }

class _MatchScreenState extends State<MatchScreen> {
  static const _roundCount = 3;
  static const _roundLengthSeconds = 15;
  static const _countdownSeconds = 5;
  static const _totalTurns = _roundCount * 2;

  late final VideoCallService _videoCallService;
  late final VisualModerationService _moderationService;
  bool _initialized = false;
  String? _error;

  bool? _isHost;
  int? _myUid;
  int? _opponentUid;
  String? _opponentFirebaseUid;
  StreamSubscription<Map<String, dynamic>>? _msgSub;
  StreamSubscription<RawVideoFrame>? _frameSampleSub;
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
  String? _violationReason;

  _Phase _phase = _Phase.waitingForOpponent;
  int _turnIndex = 0;
  int? _activeUid;
  int _secondsRemaining = 0;
  Timer? _ticker;
  String? _savedMatchId;
  String? _matchSaveError;

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
    try {
      await _videoCallService.initialize();
      await _videoCallService.joinChannel(
        channelName: 'test-channel',
        uid: 0,
        token: agoraTestChannelToken,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Match setup failed: $e');
      return;
    }
    if (!mounted) return;
    setState(() => _initialized = true);
    _msgSub = _videoCallService.matchMessages.listen(_onMessage);
    _videoCallService.localUid.addListener(_maybeElectHost);
    _videoCallService.remoteUid.addListener(_maybeElectHost);
    _maybeElectHost();
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
    _violationReason = reason;
    _ticker?.cancel();

    if (iAmReporter) {
      final myFirebaseUid = FirebaseAuth.instance.currentUser?.uid;
      final opponentFirebaseUid = _opponentFirebaseUid;
      if (myFirebaseUid != null && opponentFirebaseUid != null) {
        try {
          await FirebaseFirestore.instance.collection('reports').add({
            'reporterId': myFirebaseUid,
            'reportedUserId': opponentFirebaseUid,
            'matchId': null,
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
    _isHost = myUid < oppUid;
    _videoCallService.sendMatchMessage({
      'type': 'identity',
      'firebaseUid': FirebaseAuth.instance.currentUser?.uid,
    });
    if (_isHost!) {
      unawaited(_runHostSequence());
    }
  }

  void _onMessage(Map<String, dynamic> message) {
    switch (message['type']) {
      case 'earlyEnd':
        _earlyEndCompleter?.complete();
      case 'identity':
        _opponentFirebaseUid = message['firebaseUid'] as String?;
        // Frame sampling deliberately doesn't start until the opponent's
        // Firebase uid is known, not right at join - a violation detected
        // before this arrives would have no reportedUserId to file
        // against. Confirmed live: an early enough violation (e.g. a
        // trivially-fast moderation check) can otherwise race ahead of
        // this message and silently produce no report at all, since
        // _handleContentViolation's report-filing is guarded on
        // _opponentFirebaseUid being non-null.
        _frameSampleSub ??= _videoCallService.remoteFrameSamples.listen(_onRemoteFrameSample);
      case 'matchSaved':
        if (mounted) setState(() => _savedMatchId = message['matchId'] as String?);
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

  Future<void> _runHostSequence() async {
    for (var i = 0; i < _totalTurns; i++) {
      if (_violationEnded) return;
      final activeUid = (i.isEven) ? _myUid! : _opponentUid!;
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
    await _saveMatch();
  }

  Future<void> _saveMatch() async {
    if (_violationEnded) return;
    final myFirebaseUid = FirebaseAuth.instance.currentUser?.uid;
    final opponentFirebaseUid = _opponentFirebaseUid;
    if (myFirebaseUid == null || opponentFirebaseUid == null) {
      if (mounted) {
        setState(() => _matchSaveError = 'Could not save match: missing player identity.');
      }
      return;
    }

    try {
      final docRef = FirebaseFirestore.instance.collection('matches').doc();
      await docRef.set({
        'player1Id': myFirebaseUid,
        'player2Id': opponentFirebaseUid,
        // Hardcoded 'ranked' so the rating pipeline (Build Order step 6) is
        // testable - there's no real mode selection UI yet, and no
        // enforcement of "a few exhibition matches first" (see CLAUDE.md's
        // Modes note) before ranked unlocks.
        'mode': 'ranked',
        'status': 'completed',
        'createdAt': FieldValue.serverTimestamp(),
        'completedAt': FieldValue.serverTimestamp(),
        'voteFinalized': false,
        'winnerId': null,
      });
      if (mounted) setState(() => _savedMatchId = docRef.id);
      await _videoCallService.sendMatchMessage({'type': 'matchSaved', 'matchId': docRef.id});
    } catch (e) {
      if (mounted) setState(() => _matchSaveError = 'Could not save match: $e');
    }
  }

  Future<void> _hostAdvance({
    required _Phase phase,
    required int turnIndex,
    required int? activeUid,
    required int duration,
    bool allowEarlyEnd = false,
  }) async {
    _applyState(phase: phase, turnIndex: turnIndex, activeUid: activeUid, duration: duration);
    await _videoCallService.sendMatchMessage({
      'type': 'state',
      'phase': phase.name,
      'turnIndex': turnIndex,
      'activeUid': activeUid,
      'duration': duration,
    });

    if (duration == 0) return;
    if (allowEarlyEnd) {
      _earlyEndCompleter = Completer<void>();
      await Future.any([Future.delayed(Duration(seconds: duration)), _earlyEndCompleter!.future]);
    } else {
      await Future.delayed(Duration(seconds: duration));
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
      case _Phase.turn:
        _videoCallService.muteLocalAudio(activeUid != _myUid);
      case _Phase.verdict:
        _videoCallService.muteLocalAudio(false);
      case _Phase.countdown:
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
    _frameSampleSub?.cancel();
    _videoCallService.localUid.removeListener(_maybeElectHost);
    _videoCallService.remoteUid.removeListener(_maybeElectHost);
    _videoCallService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Match')),
      body: _error != null
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)))
          : !_initialized
              ? const Center(child: CircularProgressIndicator())
              : _violationEnded
                  ? _buildViolationEndedUi()
                  : _buildMatchUi(),
    );
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
                  ? 'Our automated content check flagged something in this match '
                      '(${_violationReason ?? 'content violation'}) and ended it. A '
                      'report has been filed for review - this doesn\'t mean anyone\'s '
                      'been banned, just that a human will take a look.'
                  : 'This match was ended and reported by the other participant\'s '
                      'device. If you think this was a mistake, you can reach out '
                      'via Support & Feedback on Home.',
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
        if (_phase == _Phase.countdown) _buildCountdownOverlay(),
        if (_phase == _Phase.turn) _buildTurnOverlay(),
      ],
    );
  }

  Widget _buildCountdownOverlay() {
    final isMe = _activeUid == _myUid;
    return ColoredBox(
      color: Colors.black87,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              isMe ? 'Your turn coming up' : "Opponent's turn coming up",
              style: const TextStyle(color: Colors.white, fontSize: 22),
            ),
            const SizedBox(height: 16),
            Text(
              '$_secondsRemaining',
              style: const TextStyle(color: Colors.white, fontSize: 64, fontWeight: FontWeight.bold),
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
            const Text(
              'Match participants can\'t vote on their own match - use a different '
              'account\'s "Vote (test)" flow on Home with the ID below.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            if (_savedMatchId != null) ...[
              const Text('Match ID', style: TextStyle(fontWeight: FontWeight.bold)),
              SelectableText(_savedMatchId!),
            ] else if (_matchSaveError != null)
              Text(_matchSaveError!, style: const TextStyle(color: Colors.red))
            else
              const CircularProgressIndicator(),
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
}
