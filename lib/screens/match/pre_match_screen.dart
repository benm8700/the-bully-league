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
import '../../core/services/main_stage_service.dart';
import '../../core/services/matchmaking_service.dart';
import '../../core/services/mic_check.dart';
import '../../core/services/steadiness_monitor.dart';
import '../../core/services/video_call_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/framing_silhouette.dart';
import '../tournament/main_stage_battle_screen.dart';
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
    this.challengeMatchId,
    this.mainStageStart,
  });

  /// Set when this check precedes a MAIN STAGE (weekly finals) battle. The
  /// bracket slot is already decided; on ready we CREATE the battle (startBattle
  /// stamps the match) and step straight on stage. Checking the camera first,
  /// then creating the match, means a failed check or a back-out never leaves a
  /// stranded battle the opponent could rejoin.
  final MainStageStart? mainStageStart;

  /// Set when this check precedes an already-agreed FRIEND battle. Like a
  /// tournament match there is no queue to join - the two players are
  /// already named - so this goes straight to the bio reveal for that
  /// match rather than to matchmaking.
  final String? challengeMatchId;

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

  /// MIC CHECK (2026-11-10, developer's call): "Checking the room" (stay
  /// quiet ~1.5s) then 'Say "THE BULLY LEAGUE"'. The rules live in MicCheck:
  /// the room is measured first, so background noise can't pass the check -
  /// it either fails the room step ("Too noisy") or raises the bar the voice
  /// is judged against - and shouting doesn't count ("Too loud"). Passing
  /// flashes MIC CHECK and advances BY ITSELF - no tap. Not real speech
  /// recognition: no extra permission, nothing else competing for the mic.
  /// The player sets the phone up FIRST, so this also proves the mic works
  /// from the battle position (a phone on its bottom edge can muffle it).
  final MicCheck _mic = MicCheck();
  bool _tooLoud = false;
  bool _readyFlash = false;
  Timer? _advanceTimer;
  // After this long with no voice, explain why (covered mic is the usual cause).
  Timer? _cantHearTimer;
  bool _cantHear = false;

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
    debugPrint('PRECHECK: requesting camera/mic permission');
    // Bounded and caught: on build 5 (iPhone, 2026-11-09) the screen spun
    // forever and the video engine was never started, i.e. this request
    // never came back (or threw - e.g. permission_handler's "a request is
    // already running"), and nothing caught it.
    final Map<Permission, PermissionStatus> statuses;
    try {
      statuses = await [
        Permission.camera,
        Permission.microphone,
      ].request().timeout(const Duration(seconds: 30));
    } catch (e) {
      debugPrint('PRECHECK: permission request failed: $e');
      if (!mounted) return;
      setState(
        () => _error =
            "Couldn't check camera and microphone access. Close the app "
            'fully, reopen it and try again.',
      );
      return;
    }
    debugPrint('PRECHECK: permission result $statuses');
    final granted =
        (statuses[Permission.camera]?.isGranted ?? false) &&
        (statuses[Permission.microphone]?.isGranted ?? false);
    if (!granted) {
      if (!mounted) return;
      setState(() {
        _permissionDenied = true;
        _error =
            'Camera and microphone access are required to check in for a match.';
      });
      return;
    }
    try {
      debugPrint('PRECHECK: initializing video engine');
      await _videoCallService.initialize();
      debugPrint('PRECHECK: video engine ready');
      final myUid = FirebaseAuth.instance.currentUser?.uid;
      if (myUid == null) {
        if (!mounted) return;
        setState(
          () => _error = 'You need to be signed in to check in for a match.',
        );
        return;
      }
      final channelName = 'precheck_$myUid';
      // Bounded: joinChannel waits for Agora's join-success event, which
      // never arrives on a bad connection - the screen then spun forever
      // with no way out (developer's iPhone, build 5, 2026-11-09).
      await () async {
        final token = await fetchAgoraToken(channelName);
        debugPrint('PRECHECK: got token, joining channel');
        await _videoCallService.joinChannel(
          channelName: channelName,
          uid: 0,
          token: token,
        );
      }().timeout(const Duration(seconds: 20));
    } on TimeoutException {
      if (!mounted) return;
      setState(
        () => _error =
            "Couldn't start the camera check - your connection may be slow. "
            'Go back and tap PLAY to try again.',
      );
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Camera/mic setup failed: $e');
      return;
    }
    if (!mounted) return;
    debugPrint('PRECHECK: joined, camera check ready');
    setState(() => _initialized = true);
    _videoCallService.localAudioLevel.addListener(_onAudioLevel);
    _cantHearTimer = Timer(const Duration(seconds: 8), () {
      if (mounted && !_micVerified) setState(() => _cantHear = true);
    });
    // Sensor + frame errors must never break the check - a failed sensor
    // just leaves its indicator neutral, which is harmless.
    _accelSub = accelerometerEventStream(
      samplingPeriod: SensorInterval.uiInterval,
    ).listen(_onAccel, onError: (_) {});
    _frameSub = _videoCallService.localFrameSamples.listen(
      _onFrame,
      onError: (_) {},
    );
  }

  void _onAudioLevel() {
    if (_micVerified || _navigating) return;
    final level = _videoCallService.localAudioLevel.value;
    final now = DateTime.now().millisecondsSinceEpoch;
    final phase = _mic.add(
      level: level,
      voice: _videoCallService.localVoiceActive.value,
      nowMs: now,
    );
    setState(() {
      if (level > _micPeak) _micPeak = level;
      _tooLoud = _mic.tooLoudAt(now);
      if (phase == MicPhase.speak && level >= _mic.bar) _cantHear = false;
      if (phase == MicPhase.passed) {
        _micVerified = true;
        _readyFlash = true;
        _cantHearTimer?.cancel();
      }
    });
    if (_micVerified) {
      // A beat to see the green MIC CHECK, then straight on - no tap needed.
      _advanceTimer = Timer(const Duration(milliseconds: 700), () {
        if (mounted && !_navigating) _onReady();
      });
    }
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
    final luma = meanLuma(
      f.yBuffer,
      width: f.width,
      height: f.height,
      yStride: f.yStride,
    );
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
    _advanceTimer?.cancel();
    _cantHearTimer?.cancel();
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
    _advanceTimer?.cancel();
    _cantHearTimer?.cancel();
    _accelSub?.cancel();
    _frameSub?.cancel();
    _videoCallService.localAudioLevel.removeListener(_onAudioLevel);
    _serviceDisposed = true;
    await _videoCallService.dispose();
    if (!mounted) return;
    final challengeMatchId = widget.challengeMatchId;

    // Main Stage finals: create the battle now (the camera is verified), then
    // step straight on stage - no bio reveal / warmup, the chess-clock format
    // opens the moment both are in. startBattle is idempotent, so if the
    // opponent started first we rejoin the SAME match.
    final mainStageStart = widget.mainStageStart;
    if (mainStageStart != null) {
      try {
        final pairing = await MainStageService().startBattle(
          tournamentId: mainStageStart.tournamentId,
          roundIdx: mainStageStart.roundIdx,
          matchIdx: mainStageStart.matchIdx,
        );
        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => MainStageBattleScreen(pairing: pairing),
          ),
        );
      } on FirebaseFunctionsException catch (e) {
        if (!mounted) return;
        setState(() {
          _navigating = false;
          // The server's precondition message is written to be read ("that
          // battle has already been played", etc.); pass it through.
          _error = e.code == 'failed-precondition'
              ? (e.message ?? "This battle isn't available right now.")
              : "Couldn't start your battle — try again.";
        });
      } catch (_) {
        if (!mounted) return;
        setState(() {
          _navigating = false;
          _error = "Couldn't start your battle — try again.";
        });
      }
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
        // Reachable from a tapped "accepted" notification that sat unread,
        // so the battle may already be over or timed out. Say so plainly
        // instead of walking into a dead match.
        final status = result.data['status'];
        if (status == 'abandoned' || status == 'completed') {
          setState(
            () => _error =
                'That battle timed out before you got here. Challenge them '
                'again from Roast a friend.',
          );
          return;
        }
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
        setState(
          () => _error =
              'Could not join that battle. Check your '
              'connection and try again.',
        );
        debugPrint('getChallengeMatch failed: $e');
      }
      return;
    }

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => MatchmakingScreen(mode: widget.mode)),
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
              16,
              16,
              16,
              16 + MediaQuery.of(context).padding.bottom,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Three glanceable checks instead of a paragraph (2026-11-10).
                Row(
                  children: [
                    Expanded(child: _buildSteadyChip()),
                    const SizedBox(width: 8),
                    Expanded(child: _buildLightChip()),
                    const SizedBox(width: 8),
                    Expanded(child: _buildQuietChip()),
                  ],
                ),
                const SizedBox(height: 14),
                _buildSayReady(),
                if (_mic.phase == MicPhase.speak && !_micVerified) ...[
                  const SizedBox(height: 10),
                  _buildMicMeter(),
                ],
                if (_mic.phase == MicPhase.speak &&
                    !_micVerified &&
                    (_tooLoud || _cantHear)) ...[
                  const SizedBox(height: 8),
                  Text(
                    _tooLoud
                        ? 'Too loud - sit back a little'
                        : "Can't hear you - keep the bottom of your phone clear",
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xFFE0A030),
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                ],
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

  /// The big 'Say "THE BULLY LEAGUE"' mic-check prompt. Not a button: the check advances by
  /// itself once it hears you (see MicCheck). Turns green on success.
  Widget _buildSayReady() {
    final winner = context.palette.winner;
    final accent = context.palette.accent;
    final done = _readyFlash || _navigating;
    final color = done ? winner : accent;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: done ? 0.22 : 0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color, width: 2),
      ),
      child: Column(
        children: [
          Text(
            done
                ? 'MIC CHECK ✓'
                : switch (_mic.phase) {
                    MicPhase.room => 'Checking the room...',
                    MicPhase.tooNoisy => 'Too noisy',
                    _ => 'Say "THE BULLY LEAGUE"',
                  },
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _mic.phase == MicPhase.tooNoisy && !done
                  ? const Color(0xFFE0A030)
                  : color,
              fontSize: 26,
              fontWeight: FontWeight.w900,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            done
                ? 'Sounds good - here we go'
                : switch (_mic.phase) {
                    MicPhase.room => 'Stay quiet for a second',
                    MicPhase.tooNoisy =>
                      'Turn down the TV or music, or find a quieter spot',
                    _ => 'Out loud, like you\'re on stage',
                  },
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _buildSteadyChip() {
    return _StatusChip(
      icon: Icons.smartphone,
      label: _steady ? 'Steady' : 'Prop it up',
      state: _steady ? _ChipState.good : _ChipState.pending,
    );
  }

  Widget _buildQuietChip() {
    final quiet = _mic.roomQuiet;
    return _StatusChip(
      icon: Icons.hearing,
      label: quiet == false ? 'Too noisy' : 'Quiet room',
      state: quiet == null
          ? _ChipState.pending
          : quiet
          ? _ChipState.good
          : _ChipState.warn,
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
      label: _tooDark
          ? 'Too dark'
          : _gotLightReading
          ? 'Good light'
          : 'Face the light',
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

enum _ChipState { good, pending, warn }

class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.icon,
    required this.label,
    required this.state,
  });

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
