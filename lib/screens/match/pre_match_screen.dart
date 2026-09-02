import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

import 'package:permission_handler/permission_handler.dart';

import '../../core/services/agora_token_service.dart';
import '../../core/services/agora_video_service.dart';
import '../../core/services/matchmaking_service.dart';
import '../../core/services/video_call_service.dart';
import '../tournament/tournament_lobby_screen.dart';
import 'bio_reveal_screen.dart';
import 'matchmaking_screen.dart';

/// Camera/mic check before a match (Build Order step 3). Real per-check
/// scope, per CLAUDE.md's Agora notes:
/// - Mic level: REAL, via Agora's volume indication.
/// - Lighting/shake/face-visible: advisory prompts only - no automated
///   brightness/motion/face analysis is wired up (see the visual content
///   moderation module for the one place a video frame observer IS used).
///
/// Joins a SOLO channel of its own (precheck_{uid}) rather than the real
/// match channel: this step is just the player checking their own camera
/// and mic, so there's no reason for an opponent to be able to see or hear
/// it. generateAgoraToken will only mint a precheck token for the caller's
/// own uid, so nobody can join anyone else's check either.
///
/// Runs BEFORE matchmaking, not after. Both orderings satisfy CLAUDE.md's
/// "both users must pass this before the match starts"; doing it first
/// means a player sorting out their lighting or a denied permission isn't
/// burning an already-paired opponent's time while they do it.
class PreMatchScreen extends StatefulWidget {
  const PreMatchScreen({
    super.key,
    required this.mode,
    this.tournamentId,
    this.challengeMatchId,
    this.climbPairing,
  });

  /// Set when this check precedes an already-agreed FRIEND battle. Like a
  /// tournament match there is no queue to join - the two players are
  /// already named - so this goes straight to the bio reveal for that
  /// match rather than to matchmaking.
  final String? challengeMatchId;

  /// Set when this check precedes a CLIMB match. climbPoll already handed the
  /// pairing over, so after the check we go straight to the bio reveal for it
  /// - no fetch, no queue.
  final MatchPairing? climbPairing;

  /// Set when this check precedes a TOURNAMENT match. The pairing is
  /// already decided by the bracket, so there is no queue to join - the
  /// player goes to the lobby to meet a named opponent instead.
  final String? tournamentId;

  /// Carried through to matchmaking - 'exhibition' or 'ranked'.
  final String mode;

  @override
  State<PreMatchScreen> createState() => _PreMatchScreenState();
}

class _PreMatchScreenState extends State<PreMatchScreen> {
  late final VideoCallService _videoCallService;
  bool _initialized = false;
  bool _micVerified = false;
  bool _serviceDisposed = false;
  bool _navigating = false;
  bool _permissionDenied = false;
  String? _error;

  /// Loudest level seen so far (0-255). Verification is peak-held rather than
  /// judged on the instantaneous value: speech is bursty, so a single clear
  /// syllable should pass and stay passed. Without this, a real user could
  /// talk, watch the meter twitch, and never trip the gate - which happened
  /// on a device (2026-09-01).
  int _micPeak = 0;

  /// The level a clear voice must reach. Lowered from 15 to 10: 15 only
  /// tripped for loud/close speech, so quieter rooms/phones-at-arms-length
  /// never crossed it. 10 is still well above the idle noise floor (~2-3),
  /// so a dead or muted mic still won't pass.
  static const _micThreshold = 10; // out of 255

  /// The meter fills relative to this, NOT to 255 - at /255 normal speech
  /// (~10-40) fills only a few percent and the bar looks frozen, which is
  /// most of why the check felt broken. /45 makes speech visibly move the bar
  /// and cross the target marker.
  static const _micMeterReference = 45.0;

  @override
  void initState() {
    super.initState();
    _videoCallService = AgoraVideoCallService();
    _setup();
  }

  Future<void> _setup() async {
    // Must be requested before initialize() acquires the camera/mic -
    // without this, a real device (unlike the dev emulators, which have
    // permissions pre-granted via `adb shell pm grant`) would silently fail
    // or crash instead of showing the OS permission prompt. See CLAUDE.md's
    // Tech Stack notes on why permission_handler was previously removed and
    // is now back.
    final statuses = await [Permission.camera, Permission.microphone].request();
    final granted = (statuses[Permission.camera]?.isGranted ?? false) &&
        (statuses[Permission.microphone]?.isGranted ?? false);
    if (!granted) {
      if (!mounted) return;
      setState(() {
        _permissionDenied = true;
        _error = 'Camera and microphone access are required to check in for a match.';
      });
      return;
    }
    try {
      await _videoCallService.initialize();
      final myUid = FirebaseAuth.instance.currentUser?.uid;
      if (myUid == null) {
        if (!mounted) return;
        setState(() => _error = 'You need to be signed in to check in for a match.');
        return;
      }
      final channelName = 'precheck_$myUid';
      final token = await fetchAgoraToken(channelName);
      await _videoCallService.joinChannel(
        channelName: channelName,
        uid: 0,
        token: token,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Camera/mic setup failed: $e');
      return;
    }
    if (!mounted) return;
    setState(() => _initialized = true);
    _videoCallService.localAudioLevel.addListener(_onAudioLevel);
  }

  void _onAudioLevel() {
    if (_micVerified) return;
    final level = _videoCallService.localAudioLevel.value;
    if (level <= _micPeak) return;
    setState(() {
      _micPeak = level;
      if (_micPeak >= _micThreshold) _micVerified = true;
    });
  }

  @override
  void dispose() {
    _videoCallService.localAudioLevel.removeListener(_onAudioLevel);
    // Only dispose here if _onReady() didn't already do it - see there for
    // why: State.dispose() can't be async/awaited, so relying on it to
    // leave the channel before MatchScreen's own engine tries to join the
    // same channel is a race (MatchScreen usually wins, and Agora rejects
    // the join with AgoraRtcException(-17) since this engine is still
    // joined).
    if (!_serviceDisposed) {
      _videoCallService.dispose();
    }
    super.dispose();
  }

  Future<void> _onReady() async {
    if (_navigating) return;
    setState(() => _navigating = true);
    _videoCallService.localAudioLevel.removeListener(_onAudioLevel);
    _serviceDisposed = true;
    await _videoCallService.dispose();
    if (!mounted) return;
    final tournamentId = widget.tournamentId;
    final challengeMatchId = widget.challengeMatchId;

    // Climb match: the pairing is already in hand, so straight to the bio
    // reveal (the intro + warmup + battle flow) like any other named matchup.
    if (widget.climbPairing != null) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => BioRevealScreen(pairing: widget.climbPairing!),
        ),
      );
      return;
    }

    if (challengeMatchId != null) {
      // The pairing already exists - fetch it and hand off to the same bio
      // reveal every other match uses, which already handles both players
      // arriving at different times.
      try {
        final result = await FirebaseFunctions.instance
            .httpsCallable('getChallengeMatch')
            .call<Map<String, dynamic>>({'matchId': challengeMatchId});
        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => BioRevealScreen(
              pairing: MatchPairing.fromMap(
                result.data.cast<String, dynamic>(),
                fallbackMode: 'friend',
              ),
            ),
          ),
        );
      } catch (e) {
        if (!mounted) return;
        setState(() => _error = 'Could not join that battle: $e');
      }
      return;
    }

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => tournamentId == null
            ? MatchmakingScreen(mode: widget.mode)
            : TournamentLobbyScreen(tournamentId: tournamentId),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pre-Match Check')),
      body: _error != null
          ? _buildErrorUi()
          : !_initialized
              ? const Center(child: CircularProgressIndicator())
              : _buildCheckUi(),
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

  Widget _buildCheckUi() {
    return Column(
      children: [
        Expanded(
          flex: 3,
          child: Stack(
            fit: StackFit.expand,
            children: [
              _videoCallService.localVideoView(),
              const CustomPaint(painter: _FramingGuidePainter(), child: SizedBox.expand()),
            ],
          ),
        ),
        Expanded(
          flex: 2,
          child: SingleChildScrollView(
            // Scrollable because this panel has a fixed share of the
            // screen and its contents do not shrink: on a short device the
            // Ready button falls off the bottom entirely, which strands
            // someone one tap short of a match with no way to reach it.
            // Seen live as a 28px overflow on a 320x640 emulator.
            //
            // The bottom padding includes the system gesture inset so the
            // Ready / skip-mic buttons clear the home-gesture bar - without
            // it, on a gesture-nav phone a tap on the bottom button triggers
            // the launcher instead (found on a real S22, 2026-09-01).
            padding: EdgeInsets.fromLTRB(
                16, 16, 16, 16 + MediaQuery.of(context).padding.bottom),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildMicMeter(),
                const SizedBox(height: 16),
                const _AdvisoryPrompt(
                  icon: Icons.wb_sunny_outlined,
                  text: 'Make sure you\'re in a well-lit area.',
                ),
                const _AdvisoryPrompt(
                  icon: Icons.videocam_outlined,
                  text: 'Hold your device steady.',
                ),
                const _AdvisoryPrompt(
                  icon: Icons.face_outlined,
                  text: 'Keep your face inside the outline.',
                ),
                // A Spacer here would throw now that this scrolls - it
                // needs bounded height from a Flex, and a scroll view gives
                // its child unbounded height by definition.
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: (_micVerified && !_navigating) ? _onReady : null,
                  child: _navigating
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(_micVerified
                          ? 'Find an Opponent'
                          : _micPeak > 2
                              ? 'Almost - a little louder'
                              : 'Say something to test your mic...'),
                ),
                if (kDebugMode && !_micVerified)
                  TextButton(
                    onPressed: _navigating ? null : _onReady,
                    child: const Text('Skip mic check (debug build only)'),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMicMeter() {
    return ValueListenableBuilder<int>(
      valueListenable: _videoCallService.localAudioLevel,
      builder: (context, level, _) {
        final scheme = Theme.of(context).colorScheme;
        // Scaled to the reference, not 255, so speech visibly moves the bar.
        final fraction = (level / _micMeterReference).clamp(0.0, 1.0);
        final target = (_micThreshold / _micMeterReference).clamp(0.0, 1.0);
        // Brass when verified, a dimmer brass while your voice is registering
        // (so the movement reads as "it hears me"), grey at rest.
        final fillColor = _micVerified
            ? context.palette.accent
            : _micPeak > 2
                ? context.palette.accent.withValues(alpha: 0.6)
                : scheme.outline;
        return Row(
          children: [
            Icon(
              _micVerified ? Icons.mic : Icons.mic_none,
              color: _micVerified ? context.palette.accent : scheme.outline,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: SizedBox(
                height: 10,
                child: Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(5),
                      child: LinearProgressIndicator(
                        value: fraction,
                        minHeight: 10,
                        backgroundColor: scheme.surfaceContainerHighest,
                        color: fillColor,
                      ),
                    ),
                    // The target marker: fill past this line to pass. Gives
                    // the user a visible goal instead of a mystery threshold.
                    if (!_micVerified)
                      FractionallySizedBox(
                        widthFactor: target,
                        alignment: Alignment.centerLeft,
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: Container(
                            width: 2,
                            color: scheme.onSurface.withValues(alpha: 0.7),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _AdvisoryPrompt extends StatelessWidget {
  const _AdvisoryPrompt({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

class _FramingGuidePainter extends CustomPainter {
  const _FramingGuidePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    final center = Offset(size.width / 2, size.height * 0.42);
    final rect = Rect.fromCenter(center: center, width: size.width * 0.55, height: size.height * 0.6);
    canvas.drawOval(rect, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
