import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/services/agora_video_service.dart';
import '../../core/services/event_window.dart';
import '../../core/services/video_call_service.dart';

/// Mandatory one-time onboarding before a player's first match
/// (CLAUDE.md's Onboarding tutorial decision).
///
/// FORMAT: an interactive practice round, explicitly not slides or a
/// video. The decision is that a user "walks through a mock match flow to
/// learn by doing" - so this runs the real turn machinery (countdown, a
/// timed turn, the mic muting, the early-end button) against a scripted
/// opponent, rather than describing it.
///
/// COSTS NOTHING TO RUN. The camera preview uses the video service's local
/// preview WITHOUT joining a channel: Agora bills per participant-minute
/// in a channel, and nobody joins one here. That matters because every
/// new user passes through this screen, so a tutorial that burned real
/// video minutes would scale its cost with signups rather than with
/// matches actually played.
///
/// The opponent is simulated rather than a real pairing, which also means
/// a first-time user is never someone else's opponent while they're still
/// working out which way to hold the phone.
class TutorialScreen extends StatefulWidget {
  const TutorialScreen({super.key});

  @override
  State<TutorialScreen> createState() => _TutorialScreenState();
}

enum _Step { intro, framing, rules, practiceCountdown, practiceYourTurn, practiceTheirTurn, done }

class _TutorialScreenState extends State<TutorialScreen> {
  // Deliberately shorter than a real match's defaults. The point is to
  // teach the shape of a turn, not to make someone sit through a full
  // three rounds before they can play.
  static const _countdownSeconds = 3;
  static const _turnSeconds = 10;

  late final VideoCallService _videoCallService;
  bool _cameraReady = false;
  bool _permissionDenied = false;
  String? _error;

  _Step _step = _Step.intro;
  int _secondsRemaining = 0;
  Timer? _ticker;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _videoCallService = AgoraVideoCallService();
    _loadWindowConfig();
  }

  /// The daily window's name and hours, for the closing panel.
  ///
  /// Read once rather than watched: the tutorial is over in a couple of
  /// minutes, and a banner changing under someone mid-sentence would be
  /// stranger than a slightly stale one. Starts at the documented defaults
  /// so the copy is correct even before this resolves, and stays there if
  /// the read fails - a missed config must never block onboarding.
  EventWindowConfig _windowConfig = const EventWindowConfig();

  Future<void> _loadWindowConfig() async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('config')
          .doc('eventWindow')
          .get();
      if (!mounted) return;
      setState(() => _windowConfig = EventWindowConfig.fromMap(snap.data()));
    } catch (_) {
      // Defaults already loaded; nothing to do.
    }
  }

  String _windowHours() {
    String hour12(int h) =>
        '${h % 12 == 0 ? 12 : h % 12}${h < 12 ? 'am' : 'pm'}';
    return '${hour12(_windowConfig.startHourPacific)}-'
        '${hour12(_windowConfig.endHourPacific)} Pacific';
  }

  @override
  void dispose() {
    _ticker?.cancel();
    if (_cameraReady) _videoCallService.dispose();
    super.dispose();
  }

  /// Starts the local camera only - no channel is joined, so this is free.
  Future<void> _startCamera() async {
    final statuses = await [Permission.camera, Permission.microphone].request();
    final granted = (statuses[Permission.camera]?.isGranted ?? false) &&
        (statuses[Permission.microphone]?.isGranted ?? false);
    if (!granted) {
      if (!mounted) return;
      setState(() {
        _permissionDenied = true;
        _error = 'The camera and microphone are needed to practise framing.';
      });
      return;
    }
    try {
      await _videoCallService.initialize();
      if (!mounted) return;
      setState(() => _cameraReady = true);
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

  void _beginPractice() {
    setState(() => _step = _Step.practiceCountdown);
    _startTicker(_countdownSeconds, () {
      setState(() => _step = _Step.practiceYourTurn);
      _startTicker(_turnSeconds, _endYourTurn);
    });
  }

  void _endYourTurn() {
    _ticker?.cancel();
    setState(() => _step = _Step.practiceTheirTurn);
    // Their turn is simulated - the point is to show that your mic goes
    // muted and you cannot talk over them, which is the rule people most
    // often break in their first real match.
    _startTicker(_turnSeconds, () {
      setState(() => _step = _Step.done);
    });
  }

  /// Records completion so this never appears again. A plain field write:
  /// this is a UX gate, not a security boundary - nothing is protected by
  /// having watched it, so it doesn't need a Cloud Function the way
  /// rating or accountStatus do.
  Future<void> _finish() async {
    setState(() => _saving = true);
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid != null) {
        await FirebaseFirestore.instance
            .collection('users')
            .doc(uid)
            .update({'tutorialCompleted': true});
      }
    } catch (_) {
      // Not worth blocking on. Worst case they see the tutorial again,
      // which is far better than being unable to leave it.
    }
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // One-time and mandatory, so leaving by the back gesture would just
      // put the player back where they started.
      canPop: _step == _Step.intro,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('How a battle works'),
          automaticallyImplyLeading: _step == _Step.intro,
        ),
        body: _error != null ? _buildErrorUi() : _buildStep(),
      ),
    );
  }

  Widget _buildErrorUi() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, textAlign: TextAlign.center),
            if (_permissionDenied) ...[
              const SizedBox(height: 16),
              FilledButton(onPressed: openAppSettings, child: const Text('Open App Settings')),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStep() {
    switch (_step) {
      case _Step.intro:
        return _buildIntro();
      case _Step.framing:
        return _buildFraming();
      case _Step.rules:
        return _buildRules();
      case _Step.practiceCountdown:
      case _Step.practiceYourTurn:
      case _Step.practiceTheirTurn:
        return _buildPractice();
      case _Step.done:
        return _buildDone();
    }
  }

  Widget _buildIntro() {
    return _Panel(
      icon: Icons.sports_mma_outlined,
      title: 'You\'re about to roast a stranger',
      body: const [
        'You get matched with someone at your level. You take turns roasting '
            'each other on camera, and the community votes on who won.',
        'It takes two minutes. Let\'s walk through it once so nothing catches '
            'you off guard in a real battle.',
      ],
      action: 'Start',
      onAction: () {
        setState(() => _step = _Step.framing);
        _startCamera();
      },
    );
  }

  Widget _buildFraming() {
    return Column(
      children: [
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (_cameraReady)
                _videoCallService.localVideoView()
              else
                const ColoredBox(
                  color: Colors.black,
                  child: Center(child: CircularProgressIndicator()),
                ),
              const CustomPaint(
                painter: _FramingGuidePainter(),
                child: SizedBox.expand(),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              Text(
                'Get your face inside the oval',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              const Text(
                'Good light on your face, phone steady, and close enough that '
                'people can read your expression. Half the joke is the delivery.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _cameraReady ? () => setState(() => _step = _Step.rules) : null,
                child: const Text('Got it'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildRules() {
    return _Panel(
      icon: Icons.gavel_outlined,
      title: 'Three rules',
      body: const [
        'You take turns. While your opponent is roasting, your mic is muted '
            'automatically — you cannot talk over them, and they cannot talk '
            'over you.',
        'Each turn is short and timed. When the clock runs out, your turn '
            'ends. You can also end early if you have landed your joke.',
        'Ranked and tournament battles are recorded, and the best moments may '
            'be posted. You confirm that before every match.',
      ],
      action: 'Try a practice turn',
      onAction: _beginPractice,
    );
  }

  Widget _buildPractice() {
    final isYourTurn = _step == _Step.practiceYourTurn;
    final isCountdown = _step == _Step.practiceCountdown;

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
                        const Text('Your turn coming up',
                            style: TextStyle(color: Colors.white, fontSize: 22)),
                        const SizedBox(height: 16),
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
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      'Practice · ${_secondsRemaining}s',
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                    ),
                  ),
                ),
              if (_step == _Step.practiceTheirTurn)
                Positioned(
                  top: 12,
                  right: 12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.mic_off, size: 16, color: Colors.white),
                        SizedBox(width: 4),
                        Text('Mic muted',
                            style: TextStyle(color: Colors.white, fontSize: 13)),
                      ],
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
                        ? 'Go. Say anything — nobody is listening.'
                        : 'Now it\'s their turn. Your mic is muted.',
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              if (isYourTurn)
                FilledButton(onPressed: _endYourTurn, child: const Text('End My Turn'))
              else
                const SizedBox(height: 48),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDone() {
    return _Panel(
      icon: Icons.check_circle_outline,
      title: 'That\'s the whole format',
      body: [
        'Take turns, keep it short, land the joke. The crowd decides the rest.',
        // Said once, here, because the single hardest thing about a
        // scheduled event is getting people to remember when it is - and
        // this is the one moment every new player is guaranteed to read.
        // Pulled from live config rather than hardcoded, since the name and
        // hours are both provisional; the defaults match the live values,
        // so an unreadable config still prints the right sentence.
        '${_windowConfig.name} is the busiest hour of the day - '
            '${_windowHours()}. That is when you will find people fastest.',
        'One more thing: your profile is the ammo your opponent gets. Fill it '
            'in, and it is funnier if it is true.',
      ],
      action: _saving ? 'Saving...' : 'I\'m ready',
      onAction: _saving ? null : _finish,
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({
    required this.icon,
    required this.title,
    required this.body,
    required this.action,
    required this.onAction,
  });

  final IconData icon;
  final String title;
  final List<String> body;
  final String action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const Spacer(),
          Icon(icon, size: 56),
          const SizedBox(height: 20),
          Text(title,
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center),
          const SizedBox(height: 20),
          for (final paragraph in body) ...[
            Text(paragraph, textAlign: TextAlign.center),
            const SizedBox(height: 14),
          ],
          const Spacer(),
          SizedBox(
            width: double.infinity,
            child: FilledButton(onPressed: onAction, child: Text(action)),
          ),
        ],
      ),
    );
  }
}

/// Same oval as the real pre-match check, so the framing practised here is
/// the framing they'll see for real.
class _FramingGuidePainter extends CustomPainter {
  const _FramingGuidePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final center = Offset(size.width / 2, size.height * 0.42);
    final rect = Rect.fromCenter(
      center: center,
      width: size.width * 0.55,
      height: size.height * 0.6,
    );
    canvas.drawOval(rect, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
