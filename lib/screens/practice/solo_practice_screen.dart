import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/services/agora_video_service.dart';
import '../../core/services/video_call_service.dart';

/// Solo practice: rehearse against the real clock, with no opponent.
///
/// WHY THIS EARNS ITS PLACE IN A THIN POOL. The single biggest threat to
/// the beta is that someone opens the app and nobody is there - and an app
/// that can only be used when a stranger happens to be awake gets deleted
/// after the second empty queue. This gives that person something to do
/// that is genuinely useful rather than a consolation prize: the hard part
/// of this format is not finding an opponent, it is landing a joke inside
/// fifteen seconds, three times, without freezing. That is rehearsable
/// alone, and comedians rehearse alone as a matter of course.
///
/// IT COSTS NOTHING TO RUN, which is what makes it safe to offer to
/// everybody at every tier. Like the tutorial, it uses the video service's
/// local preview WITHOUT joining a channel - Agora bills per
/// participant-minute in a channel and nobody joins one here. So this is
/// free for a lapsed account outside the window, where every other battle
/// mode is closed, and it keeps that state from being a dead end.
///
/// IT DELIBERATELY DOES NOT RECORD. CLAUDE.md's decision says "record
/// yourself", and a self-view mirror is what that buys you here: capturing
/// the video would mean uploading footage of a real person, which creates
/// a retention obligation, a consent question and a storage bill for
/// material that has no audience and no votes. Playback of a local-only
/// file would be the honest middle ground, but it needs a capture
/// dependency this project does not have, against a toolchain CLAUDE.md
/// documents as fragile. Worth revisiting; not worth blocking this on.
///
/// The FORMAT is read from config/matchSettings rather than hardcoded, so
/// rehearsal always matches whatever a real battle currently is. A
/// practice mode drilling last month's round length would be worse than
/// none.
class SoloPracticeScreen extends StatefulWidget {
  const SoloPracticeScreen({super.key});

  @override
  State<SoloPracticeScreen> createState() => _SoloPracticeScreenState();
}

enum _Phase { setup, countdown, yourTurn, theirTurn, done }

class _SoloPracticeScreenState extends State<SoloPracticeScreen> {
  /// Documented defaults, used until config resolves and if it never does.
  /// Mirrors functions/matchSettings.js - an unreadable config must never
  /// stop someone practising.
  int _roundCount = 3;
  int _turnSeconds = 15;
  int _countdownSeconds = 5;

  late final VideoCallService _videoCallService;
  bool _cameraReady = false;
  bool _permissionDenied = false;
  String? _error;

  _Phase _phase = _Phase.setup;
  int _round = 1;
  int _secondsRemaining = 0;
  Timer? _ticker;

  /// How long each turn actually took. The only feedback this screen can
  /// honestly give: nobody is judging the jokes, but the clock is real,
  /// and "you ran out of time in all three rounds" is a genuine finding
  /// about your set.
  final List<int> _secondsUsed = [];

  @override
  void initState() {
    super.initState();
    _videoCallService = AgoraVideoCallService();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('config')
          .doc('matchSettings')
          .get();
      final data = snap.data() ?? const {};
      // Per-field, bounds-checked, exactly as the server does: this
      // document is hand-edited in the console with nothing validating it
      // in between, and one bad field must not discard a good config.
      int pick(String key, int fallback, int lo, int hi) {
        final v = data[key];
        if (v is num && v >= lo && v <= hi) return v.toInt();
        return fallback;
      }

      if (!mounted) return;
      setState(() {
        _roundCount = pick('roundCount', 3, 1, 10);
        _turnSeconds = pick('roundLengthSeconds', 15, 5, 120);
        _countdownSeconds = pick('countdownSeconds', 5, 1, 30);
      });
    } catch (_) {
      // Defaults are already loaded.
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    if (_cameraReady) _videoCallService.dispose();
    super.dispose();
  }

  Future<void> _startCamera() async {
    final statuses =
        await [Permission.camera, Permission.microphone].request();
    final granted = (statuses[Permission.camera]?.isGranted ?? false) &&
        (statuses[Permission.microphone]?.isGranted ?? false);
    if (!granted) {
      if (!mounted) return;
      setState(() {
        _permissionDenied = true;
        _error = 'The camera and microphone are needed to practise.';
      });
      return;
    }
    try {
      await _videoCallService.initialize();
      if (!mounted) return;
      setState(() => _cameraReady = true);
      _beginRound();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not start the camera: $e');
    }
  }

  void _startTicker(int seconds, VoidCallback onDone) {
    _ticker?.cancel();
    setState(() => _secondsRemaining = seconds);
    _ticker = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_secondsRemaining <= 1) {
        timer.cancel();
        setState(() => _secondsRemaining = 0);
        onDone();
        return;
      }
      setState(() => _secondsRemaining -= 1);
    });
  }

  void _beginRound() {
    setState(() => _phase = _Phase.countdown);
    _startTicker(_countdownSeconds, () {
      setState(() => _phase = _Phase.yourTurn);
      _startTicker(_turnSeconds, _endTurn);
    });
  }

  void _endTurn() {
    _ticker?.cancel();
    _secondsUsed.add(_turnSeconds - _secondsRemaining);
    if (_round >= _roundCount) {
      setState(() => _phase = _Phase.done);
      return;
    }
    // The gap where your opponent would be roasting is kept, deliberately.
    // In a real battle that is the only time you get to think of your next
    // line while being insulted, and rehearsing the turns without it drills
    // a rhythm that does not exist.
    setState(() => _phase = _Phase.theirTurn);
    _startTicker(_turnSeconds, () {
      setState(() => _round += 1);
      _beginRound();
    });
  }

  void _restart() {
    _secondsUsed.clear();
    setState(() {
      _round = 1;
      _phase = _Phase.setup;
    });
    _beginRound();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Warm up')),
      body: _error != null ? _buildError() : _buildPhase(),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, textAlign: TextAlign.center),
            if (_permissionDenied) ...[
              const SizedBox(height: 16),
              FilledButton(
                onPressed: openAppSettings,
                child: const Text('Open App Settings'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPhase() {
    if (_phase == _Phase.setup && !_cameraReady) return _buildIntro();
    if (_phase == _Phase.done) return _buildSummary();
    return _buildLive();
  }

  Widget _buildIntro() {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(Icons.mic_none_outlined, size: 56),
          const SizedBox(height: 16),
          Text('Rehearse against the real clock',
              style: text.headlineSmall, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          Text(
            'No opponent, no votes, nothing recorded or saved. Just you, '
            '$_roundCount rounds, $_turnSeconds seconds a turn - the same '
            'format as a real battle.',
            style: text.bodyMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'The gaps are where your opponent would be roasting you. Use '
            'them to think of the next one.',
            style: text.bodySmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          FilledButton(onPressed: _startCamera, child: const Text('Start')),
        ],
      ),
    );
  }

  Widget _buildLive() {
    final isYourTurn = _phase == _Phase.yourTurn;
    final isCountdown = _phase == _Phase.countdown;
    return Column(
      children: [
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (_cameraReady)
                _videoCallService.localVideoView()
              else
                const ColoredBox(color: Colors.black),
              if (isCountdown)
                ColoredBox(
                  color: Colors.black87,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Round $_round of $_roundCount',
                            style: const TextStyle(
                                color: Colors.white, fontSize: 20)),
                        const SizedBox(height: 12),
                        Text('$_secondsRemaining',
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 64,
                                fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                ),
              if (!isCountdown)
                Positioned(
                  top: 12,
                  left: 12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      'Round $_round/$_roundCount · ${_secondsRemaining}s',
                      style: const TextStyle(
                          color: Colors.white, fontSize: 14),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              Text(
                isCountdown
                    ? 'Get ready...'
                    : isYourTurn
                        ? 'Go.'
                        : 'Their turn. Think of your next one.',
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              if (isYourTurn)
                FilledButton(
                    onPressed: _endTurn, child: const Text('End My Turn'))
              else
                const SizedBox(height: 48),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSummary() {
    final text = Theme.of(context).textTheme;
    final ranOut = _secondsUsed.where((s) => s >= _turnSeconds).length;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(Icons.check_circle_outline, size: 56),
          const SizedBox(height: 16),
          Text('That was the format', style: text.headlineSmall,
              textAlign: TextAlign.center),
          const SizedBox(height: 16),
          for (var i = 0; i < _secondsUsed.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Round ${i + 1}', style: text.bodyMedium),
                  Text('${_secondsUsed[i]}s of $_turnSeconds',
                      style: text.bodyMedium),
                ],
              ),
            ),
          const SizedBox(height: 12),
          Text(
            // The only honest read available from a stopwatch, and it
            // happens to be the useful one for this format.
            ranOut == _secondsUsed.length
                ? 'You used every second of every round. In a real battle '
                    'the clock cuts you off mid-sentence, so land the joke '
                    'earlier than feels natural.'
                : ranOut == 0
                    ? 'You finished every round early. That is the right '
                        'instinct - short and landed beats long and lost.'
                    : 'Mixed. The rounds you finished early are the ones '
                        'that would have landed.',
            style: text.bodySmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          FilledButton(onPressed: _restart, child: const Text('Go again')),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }
}
