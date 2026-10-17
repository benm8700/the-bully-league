import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/services/agora_token_service.dart';
import '../../core/services/agora_video_service.dart';
import '../../core/services/matchmaking_service.dart';
import '../../core/services/video_call_service.dart';
import '../../core/services/visual_moderation_service.dart';
import '../../core/services/yuv_to_jpeg.dart';
import '../../theme/app_theme.dart';

/// IMPROV STATION match flow (2026-10-16: SIMULTANEOUS).
///
/// A prompt-based comedy SHOWCASE: both comedians get the SAME prompt each
/// round and riff a quick one-liner - AT THE SAME TIME, blind to each other.
/// Because they never see or hear each other and share the prompt, there's no
/// reason to take turns (and taking turns was both slower and visibly buggy),
/// so both perform together. The crowd votes who was funnier on the recorded
/// clip via the normal Judge feed (one overall vote).
///
/// THE BLIND RULE: you only ever see your OWN camera; the opponent's video is
/// kept mounted (invisible, behind your own) ONLY so this device can moderate
/// their frames, and their audio is muted on your device the whole time.
///
/// A SEPARATE screen from MatchScreen on purpose: it reuses the video service
/// (join/leave/mute/data-channel/recording) but has its own simple fixed-timer
/// sequence, leaving the device-proven roast match screen untouched.
///
/// NOT DEVICE-VERIFIED for every edge yet - treat as first-run.
class ImprovMatchScreen extends StatefulWidget {
  const ImprovMatchScreen({super.key, required this.pairing});

  final MatchPairing pairing;

  @override
  State<ImprovMatchScreen> createState() => _ImprovMatchScreenState();
}

enum _Phase { connecting, performing, done }

class _ImprovMatchScreenState extends State<ImprovMatchScreen> {
  final AgoraVideoCallService _video = AgoraVideoCallService();
  final MatchmakingService _matchmaking = MatchmakingService();
  late final VisualModerationService _moderation;

  StreamSubscription<Map<String, dynamic>>? _msgSub;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _matchDocSub;
  StreamSubscription<RawVideoFrame>? _frameSub;

  bool _initialized = false;
  bool? _isHost;
  String? _error;
  bool _sequenceStarted = false;
  bool _completeRequested = false;

  bool _processingFrame = false;
  bool _violationEnded = false;
  bool _violationIAmReporter = false;

  _Phase _phase = _Phase.connecting;
  List<String> _prompts = const [];
  int _roundCount = 3;
  int _turnLength = 10;

  int _promptIndex = 0;
  int _secondsRemaining = 0;
  Timer? _displayTicker;

  @override
  void initState() {
    super.initState();
    _moderation = context.read<VisualModerationService>();
    _roundCount = widget.pairing.settings.roundCount;
    _turnLength = widget.pairing.settings.roundLengthSeconds;
    _setup();
  }

  Future<void> _setup() async {
    final channelName = widget.pairing.channelName;
    try {
      await _video.initialize();
      try {
        final doc = await FirebaseFirestore.instance
            .collection('matches')
            .doc(widget.pairing.matchId)
            .get();
        final raw = doc.data()?['improvPrompts'];
        if (raw is List && raw.isNotEmpty) {
          _prompts = raw.whereType<String>().toList();
        }
      } catch (_) {/* fallback below */}
      if (_prompts.isEmpty) {
        _prompts = List.generate(_roundCount, (i) => 'Riff for ${_turnLength}s');
      }
      _roundCount = _prompts.length;

      final token = await fetchAgoraToken(channelName);
      await _video.joinChannel(
        channelName: channelName,
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
    _video.muteLocalAudio(true); // open only during a perform window
    _video.muteRemoteAudio(true); // blind the whole match
    _msgSub = _video.matchMessages.listen(_onMessage);
    _matchDocSub = FirebaseFirestore.instance
        .collection('matches')
        .doc(widget.pairing.matchId)
        .snapshots()
        .listen(_onMatchDoc);
    _frameSub = _video.remoteFrameSamples.listen(_onRemoteFrame);
    _video.localUid.addListener(_maybeElectHost);
    _video.remoteUid.addListener(_maybeElectHost);
    _maybeElectHost();
  }

  void _maybeElectHost() {
    if (_isHost != null) return;
    final myUid = _video.localUid.value;
    final oppUid = _video.remoteUid.value;
    if (myUid == null || oppUid == null) return;
    _isHost = myUid < oppUid;
    if (_isHost! && !_sequenceStarted) {
      _sequenceStarted = true;
      unawaited(_matchmaking.startRecording(widget.pairing.matchId));
      unawaited(_runSequence());
    }
  }

  /// HOST: one shared window per prompt - BOTH players riff at once for the
  /// full round length (no separate think beat; people just start talking).
  /// Broadcasts each prompt; the guest mirrors it.
  Future<void> _runSequence() async {
    for (var i = 0; i < _roundCount; i++) {
      if (!mounted || _phase == _Phase.done || _violationEnded) return;
      _applyPhase(promptIndex: i);
      _broadcast({'type': 'improvState', 'prompt': i, 'phase': 'perform'});
      await Future<void>.delayed(Duration(seconds: _turnLength));
    }
    if (!mounted || _phase == _Phase.done || _violationEnded) return;
    _broadcast({'type': 'improvState', 'phase': 'done'});
    _goToDone();
  }

  void _broadcast(Map<String, dynamic> msg) =>
      unawaited(_video.sendMatchMessage(msg));

  void _onMessage(Map<String, dynamic> message) {
    if (message['type'] == 'matchEndedViolation') {
      _handleContentViolation('flagged by the other device', iAmReporter: false);
      return;
    }
    if (message['type'] != 'improvState') return;
    if (message['phase'] == 'done') {
      _goToDone();
      return;
    }
    final prompt = (message['prompt'] as num?)?.toInt() ?? 0;
    _applyPhase(promptIndex: prompt);
  }

  /// Set the prompt and start the round. Both devices run this. You're always
  /// muted-remote (blind); your own mic is open for the whole round.
  void _applyPhase({required int promptIndex}) {
    if (!mounted) return;
    setState(() {
      _phase = _Phase.performing;
      _promptIndex = promptIndex;
      _secondsRemaining = _turnLength;
    });
    _video.muteLocalAudio(false); // performing
    _video.muteRemoteAudio(true); // always blind in improv
    _startDisplayTicker();
  }

  void _startDisplayTicker() {
    _displayTicker?.cancel();
    _displayTicker = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted || _secondsRemaining <= 1 || _phase != _Phase.performing) {
        t.cancel();
        if (mounted && _secondsRemaining > 0) {
          setState(() => _secondsRemaining = 0);
        }
        return;
      }
      setState(() => _secondsRemaining -= 1);
    });
  }

  /// Moderate the opponent's frames the whole time they're on camera. Their
  /// video is mounted (behind yours) so frames flow even though you can't see
  /// them. Same Cloud Vision check + auto-end + report as the roast mode.
  Future<void> _onRemoteFrame(RawVideoFrame frame) async {
    if (_violationEnded || _processingFrame || _phase != _Phase.performing) {
      return;
    }
    _processingFrame = true;
    try {
      final jpeg =
          await compute(i420ToJpeg, I420FrameData.fromRawVideoFrame(frame));
      final reason = await _moderation.checkImageBytes(jpeg);
      if (reason != null) {
        await _handleContentViolation(reason, iAmReporter: true);
      }
    } catch (e) {
      debugPrint('Improv frame moderation failed: $e');
    } finally {
      _processingFrame = false;
    }
  }

  Future<void> _handleContentViolation(String reason,
      {required bool iAmReporter}) async {
    if (_violationEnded) return;
    _violationEnded = true;
    _violationIAmReporter = iAmReporter;
    _displayTicker?.cancel();
    if (iAmReporter) {
      final myUid = FirebaseAuth.instance.currentUser?.uid;
      if (myUid != null) {
        try {
          await FirebaseFirestore.instance.collection('reports').add({
            'reporterId': myUid,
            'reportedUserId': widget.pairing.opponentId,
            'matchId': widget.pairing.matchId,
            'reason': 'inappropriate_content',
            'details':
                'Auto-detected by live visual moderation (Improv): $reason',
            'status': 'pending',
            'createdAt': FieldValue.serverTimestamp(),
          });
        } catch (e) {
          debugPrint('Failed to auto-file improv violation report: $e');
        }
      }
      try {
        await _video.sendMatchMessage({'type': 'matchEndedViolation'});
      } catch (_) {}
    }
    try {
      await _matchmaking.completeMatch(widget.pairing.matchId,
          outcome: 'abandoned');
    } catch (e) {
      debugPrint('Failed to mark improv violation match abandoned: $e');
    }
    try {
      await _video.leaveChannel();
    } catch (_) {}
    if (mounted) setState(() {});
  }

  void _onMatchDoc(DocumentSnapshot<Map<String, dynamic>> snap) {
    if (!mounted) return;
    final status = snap.data()?['status'] as String?;
    const terminal = {'completed', 'abandoned', 'disqualified'};
    if (status != null && terminal.contains(status)) _goToDone();
  }

  void _goToDone() {
    if (_phase == _Phase.done || _violationEnded) return;
    _displayTicker?.cancel();
    if (mounted) setState(() => _phase = _Phase.done);
    _video.muteLocalAudio(true);
    unawaited(_video.leaveChannel());
    _complete();
  }

  Future<void> _complete() async {
    if (_completeRequested) return;
    _completeRequested = true;
    try {
      await _matchmaking.completeMatch(widget.pairing.matchId);
    } catch (_) {/* backstop + sweep settle it */}
  }

  void _home() => Navigator.of(context).popUntil((r) => r.isFirst);

  @override
  void dispose() {
    _displayTicker?.cancel();
    _msgSub?.cancel();
    _matchDocSub?.cancel();
    _frameSub?.cancel();
    _video.localUid.removeListener(_maybeElectHost);
    _video.remoteUid.removeListener(_maybeElectHost);
    _video.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canLeaveFreely = _error != null ||
        !_initialized ||
        _phase == _Phase.done ||
        _violationEnded;
    return PopScope(
      canPop: canLeaveFreely,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        final leave = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Leave the match?'),
            content: const Text(
                "You're in the middle of an Improv battle. Leaving now ends "
                'it for you.'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(c, false),
                  child: const Text('Stay')),
              TextButton(
                  onPressed: () => Navigator.pop(c, true),
                  child: const Text('Leave')),
            ],
          ),
        );
        if (leave == true && mounted) {
          _goToDone();
          navigator.popUntil((r) => r.isFirst);
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(child: _body(context)),
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (_error != null) {
      return _centered(
        icon: Icons.error_outline,
        title: 'Something went wrong',
        body: _error!,
      );
    }
    if (_violationEnded) return _violationUi(context);
    if (!_initialized || _phase == _Phase.connecting) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Setting up the stage…',
                style: TextStyle(color: Colors.white70)),
          ],
        ),
      );
    }
    if (_phase == _Phase.done) {
      return _centered(
        icon: Icons.theater_comedy,
        title: 'Sets are in!',
        body: 'The crowd will judge who was funnier.',
        buttonLabel: 'Back to home',
        onButton: _home,
      );
    }
    return _performing(context);
  }

  Widget _performing(BuildContext context) {
    final accent = context.palette.accent;
    final prompt = (_promptIndex >= 0 && _promptIndex < _prompts.length)
        ? _prompts[_promptIndex]
        : '';
    return Stack(
      children: [
        // The opponent's video is mounted UNDERNEATH (for moderation only -
        // the blind rule), with your own camera opaque on top, so you only
        // ever see yourself.
        Positioned.fill(
            child: _video.remoteVideoView() ?? const SizedBox.shrink()),
        Positioned.fill(child: _video.localVideoView()),
        // Big, unmissable timer, top-right.
        Positioned(top: 14, right: 14, child: _timerChip(accent)),
        // Status + the shared prompt, top-left (clear of the timer).
        Positioned(
          top: 14, left: 14, right: 100,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  "You're on · Round ${_promptIndex + 1} of $_roundCount",
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 13),
                ),
              ),
              const SizedBox(height: 10),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: accent.withValues(alpha: 0.6)),
                ),
                child: Text(
                  prompt,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                    height: 1.1,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _timerChip(Color color) {
    return Container(
      width: 76,
      height: 76,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        shape: BoxShape.circle,
        border: Border.all(color: color, width: 4),
      ),
      alignment: Alignment.center,
      child: Text('$_secondsRemaining',
          style: const TextStyle(
              color: Colors.white,
              fontSize: 34,
              height: 1.0,
              fontWeight: FontWeight.w900)),
    );
  }

  Widget _violationUi(BuildContext context) => _centered(
        icon: Icons.gpp_maybe,
        iconColor: Colors.orangeAccent,
        title: 'Match ended',
        body: _violationIAmReporter
            ? 'The automated visual check flagged something on your '
                "opponent's camera, so the match was ended. It's never about "
                'anything said - only video.'
            : 'The automated visual check flagged something on camera, so the '
                'match was ended. This was NOT your opponent reporting you, '
                'and it is never about anything said - only video.',
        buttonLabel: 'Back to home',
        onButton: _home,
      );

  Widget _centered({
    required IconData icon,
    required String title,
    required String body,
    Color iconColor = Colors.white70,
    String? buttonLabel,
    VoidCallback? onButton,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: iconColor),
            const SizedBox(height: 14),
            Text(title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            Text(body,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 15)),
            if (buttonLabel != null && onButton != null) ...[
              const SizedBox(height: 22),
              FilledButton(
                onPressed: onButton,
                style: FilledButton.styleFrom(
                    minimumSize: const Size(200, 48)),
                child: Text(buttonLabel),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
