import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../../core/services/agora_token_service.dart';
import '../../core/services/agora_video_service.dart';
import '../../core/services/capture_quality.dart';
import '../../core/services/matchmaking_service.dart';
import '../../core/services/steadiness_monitor.dart';
import '../../core/services/video_call_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/framing_silhouette.dart';
import '../tournament/tournament_lobby_screen.dart';
import 'bio_reveal_screen.dart';
import 'matchmaking_screen.dart';

/// Camera/mic check before a match (Build Order step 3).
///
/// Redesigned 2026-09-16 around one idea the developer landed on: the best
/// shot comes from PROPPING the phone and sitting back, not holding it at
/// arm's length with your face jammed in a ring. A steady, framed, lit shot
/// is better for the performer (no arm to hold), the recording, and the
/// audience all at once. So this screen now:
/// - draws a head-and-shoulders silhouette instead of the old oval
///   (`FramingSilhouette`, shared with the tutorial),
/// - reads the phone's motion sensor and shows a live "Steady" indicator,
/// - reuses the in-match brightness signal to show a "Good light / Too dark"
///   indicator,
/// - carries a compact "prop it up, good light" reminder.
///
/// Steadiness and lighting are NON-BLOCKING - they light indicators, they do
/// not gate Ready. Only the mic check gates (a dead mic is unrecoverable
/// mid-battle). The mic gate itself already taught us that a hard sensor gate
/// strands real users, so the two new signals are encouragement, not walls.
///
/// Scope of each check, per CLAUDE.md's Agora notes:
/// - Mic level: REAL, via Agora's volume indication (gates Ready).
/// - Steadiness: REAL, via the accelerometer (indicator only).
/// - Lighting: REAL mean-brightness of the local feed (indicator only).
/// - Face-visible: still not auto-detected (no face detection wired up).
///
/// Joins a SOLO channel of its own (precheck_{uid}) rather than the real
/// match channel: this step is just the player checking their own camera and
/// mic. generateAgoraToken only mints a precheck token for the caller's own
/// uid, so nobody can join anyone else's check.
///
/// Runs BEFORE matchmaking, not after, so a player sorting out their setup
/// isn't burning an already-paired opponent's time.
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

  // --- Steadiness (non-blocking indicator) ---
  final SteadinessMonitor _steadiness = SteadinessMonitor();
  StreamSubscription<AccelerometerEvent>? _accelSub;
  bool _steady = false;

  // --- Lighting (non-blocking indicator) ---
  StreamSubscription<RawVideoFrame>? _frameSub;
  int _darkRun = 0;
  bool _tooDark = false;
  bool _gotLightReading = false;

  /// The "good light on your face" bar for the pre-match tip. Deliberately
  /// FAR higher than capture_quality's kDarkLumaThreshold (28) - that low
  /// value exists only to catch a genuinely black/dead camera in-match.
  /// Raised 28 -> 60 -> 100 across two developer reports that dim rooms were
  /// still passing (2026-09-16, 2026-09-17). The reason it has to be this
  /// high: phone auto-exposure aggressively brightens a dark room, so the
  /// mean luma of a genuinely underlit room still lands surprisingly high.
  /// This is a non-blocking nudge, so erring toward "get more light" is safe.
  /// Tunable.
  static const _dimLumaThreshold = 100; // out of 255

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
    // or crash instead of showing the OS permission prompt.
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
    // Sensor + frame errors must never break the check - a failed sensor
    // just leaves its indicator neutral, which is harmless.
    _accelSub = accelerometerEventStream(samplingPeriod: SensorInterval.uiInterval)
        .listen(_onAccel, onError: (_) {});
    _frameSub = _videoCallService.localFrameSamples.listen(_onFrame, onError: (_) {});
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

  void _onAccel(AccelerometerEvent e) {
    if (!mounted || _navigating) return;
    final steady = _steadiness.record(e.x, e.y, e.z);
    // Only rebuild when the verdict flips - the sensor fires ~16x/second and
    // a setState per sample would be wasteful.
    if (steady != _steady) setState(() => _steady = steady);
  }

  void _onFrame(RawVideoFrame f) {
    if (!mounted || _navigating) return;
    final luma =
        meanLuma(f.yBuffer, width: f.width, height: f.height, yStride: f.yStride);
    final dark = luma < _dimLumaThreshold;
    _darkRun = dark ? _darkRun + 1 : 0;
    // Two sustained dark samples (~a few seconds, given the internal throttle)
    // before saying "too dark", so a hand passing the lens doesn't trip it.
    final tooDark = _darkRun >= 2;
    if (tooDark != _tooDark || !_gotLightReading) {
      setState(() {
        _tooDark = tooDark;
        _gotLightReading = true;
      });
    }
  }

  @override
  void dispose() {
    _accelSub?.cancel();
    _frameSub?.cancel();
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
    _accelSub?.cancel();
    _frameSub?.cancel();
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
              const FramingSilhouette(),
            ],
          ),
        ),
        Expanded(
          flex: 2,
          child: SingleChildScrollView(
            // Scrollable because this panel has a fixed share of the screen
            // and its contents do not shrink: on a short device the Ready
            // button would otherwise fall off the bottom, stranding someone
            // one tap short of a match.
            //
            // The bottom padding includes the system gesture inset so the
            // Ready / skip-mic buttons clear the home-gesture bar (found on a
            // real S22, 2026-09-01).
            padding: EdgeInsets.fromLTRB(
                16, 16, 16, 16 + MediaQuery.of(context).padding.bottom),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _SetupReminder(),
                const SizedBox(height: 16),
                _buildMicMeter(),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(child: _buildSteadyChip()),
                    const SizedBox(width: 8),
                    Expanded(child: _buildLightChip()),
                  ],
                ),
                const SizedBox(height: 20),
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

  Widget _buildSteadyChip() {
    return _StatusChip(
      icon: Icons.smartphone,
      label: _steady ? 'Steady' : 'Prop it up',
      state: _steady ? _ChipState.good : _ChipState.pending,
    );
  }

  Widget _buildLightChip() {
    final state = !_gotLightReading
        ? _ChipState.pending
        : _tooDark
            ? _ChipState.warn
            : _ChipState.good;
    return _StatusChip(
      icon: Icons.wb_sunny_outlined,
      label: _tooDark ? 'Too dark' : 'Good light',
      state: state,
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

/// The compact "how to set up" reminder shown every match. The full teaching
/// lives once in the tutorial; this is the small persistent nudge.
class _SetupReminder extends StatelessWidget {
  const _SetupReminder();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.tips_and_updates_outlined, size: 20, color: scheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Rest your phone on something and sit back — a steady shot beats '
              'everything. Get some light on your face and your head and '
              'shoulders in the outline.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

enum _ChipState { good, pending, warn }

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.icon, required this.label, required this.state});

  final IconData icon;
  final String label;
  final _ChipState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final Color color = switch (state) {
      _ChipState.good => context.palette.winner,
      _ChipState.warn => const Color(0xFFE0A030),
      _ChipState.pending => scheme.outline,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            state == _ChipState.good ? Icons.check_circle : icon,
            size: 18,
            color: color,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: color, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
