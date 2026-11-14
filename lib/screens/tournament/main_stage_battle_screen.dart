import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/main_stage_battle.dart';
import '../../core/services/agora_video_service.dart';
import '../../core/services/agora_token_service.dart';
import '../../core/services/main_stage_service.dart';
import '../../core/services/matchmaking_service.dart';
import '../../core/services/video_call_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/match/battle_scorebug.dart';
import '../../widgets/neon_action_button.dart';
import 'watch_judges_screen.dart';

/// The Main Stage finals battle: the chess-clock + interrupt format, driving
/// the verified MainStageBattleState engine live over Agora. Host-authoritative
/// (player1/agoraUid 1 runs the engine and broadcasts the whole state each
/// tick; the guest renders it and sends yield/interrupt intents back). Reuses
/// the proven match video/mic/dispose path. When both clocks hit zero the host
/// marks the battle complete, and the 5-judge panel then settles it - this
/// screen ends at "the panel decides".
class MainStageBattleScreen extends StatefulWidget {
  const MainStageBattleScreen({super.key, required this.pairing});

  final MainStageBattlePairing pairing;

  @override
  State<MainStageBattleScreen> createState() => _MainStageBattleScreenState();
}

class _MainStageBattleScreenState extends State<MainStageBattleScreen>
    with SingleTickerProviderStateMixin {
  late final VideoCallService _video;
  final _matchmaking = MatchmakingService();
  StreamSubscription<Map<String, dynamic>>? _msgSub;
  Timer? _tick;

  // Drives the red "you're being cut into" flash on the floor-holder's clock
  // while an interrupt is in its grace window. Haptic fires once on the edge.
  late final AnimationController _pulse;
  bool _beingInterrupted = false;

  final String _myUid = FirebaseAuth.instance.currentUser?.uid ?? '';
  late final String _oppUid = widget.pairing.opponentId;
  bool get _isHost => widget.pairing.isHost;

  // The same broadcast layout as a ranked battle (2026-11-12 show overhaul):
  // scorebug hugging the top, self-view tight under it on the right, one
  // contextual action pill beside the self-view.
  static const double _kSelfViewW = 92;
  static const double _kSelfViewH = 128;
  static const double _kSelfViewTop = 2 + 78 + 4;
  String? _oppName;

  Future<void> _loadOppName() async {
    try {
      final d = await FirebaseFirestore.instance
          .collection('users')
          .doc(_oppUid)
          .get();
      final n = d.data()?['username'] as String?;
      if (n != null && mounted) setState(() => _oppName = n);
    } catch (_) {
      // Quiet: the scorebug just says "Them".
    }
  }

  MainStageBattleState? _battle;
  bool _initialized = false;
  bool _engineStarted = false;
  bool _completeSent = false;
  String? _error;

  // Pre-battle countdown: once both players are present, run a brief "starts
  // in N" before the first clock drains - so the battle has a real start
  // instead of lurching straight into someone's turn. The host drives it and
  // broadcasts once; the guest mirrors it locally.
  static const int _kCountdownMs = 15000;
  int? _countdownEndMs;
  Timer? _countdownTimer;
  int get _countdownLeft {
    final end = _countdownEndMs;
    if (end == null) return 0;
    final left = ((end - _nowMs) / 1000).ceil();
    final cap = (_kCountdownMs / 1000).ceil();
    return left < 0 ? 0 : (left > cap ? cap : left);
  }

  int get _nowMs => DateTime.now().millisecondsSinceEpoch;

  @override
  void initState() {
    super.initState();
    _loadOppName();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
    );
    _video = AgoraVideoCallService();
    _setup();
  }

  Future<void> _setup() async {
    try {
      await _video.initialize();
      final token = await fetchAgoraToken(widget.pairing.channelName);
      await _video.joinChannel(
        channelName: widget.pairing.channelName,
        uid: widget.pairing.agoraUid,
        token: token,
      );
    } catch (_) {
      // Never surface a raw Firebase error. The usual cause is the match
      // having already ended (its token is refused), so point back.
      if (mounted) {
        setState(
          () => _error =
              "Couldn't connect to the battle. It may have already ended — "
              'head back and try again.',
        );
      }
      return;
    }
    if (!mounted) return;
    _msgSub = _video.matchMessages.listen(_onMessage);
    // BOTH mics stay muted through connect + countdown. There is no warmup on
    // the Main Stage - it goes countdown -> battle - so nobody should be
    // audible until the clock assigns the floor. _afterStateChange unmutes the
    // floor-holder the moment the battle opens (host) / its first state lands
    // (guest), so this only silences the dead pre-battle window.
    _video.muteLocalAudio(true);
    setState(() => _initialized = true);

    if (_isHost) {
      // The host owns the engine - but it must NOT open (and start draining
      // its own clock) until the opponent is actually in the channel. Both
      // players arrive independently through consent + the camera check, so
      // whoever lands first would otherwise burn their minute talking to an
      // empty room. Wait for the remote participant, then open exactly once.
      _video.remoteUid.addListener(_maybeStartHostEngine);
      _maybeStartHostEngine();
    }
  }

  /// Host-only: open the chess-clock engine the first moment the opponent is
  /// present, then drive it on a timer. Guarded so a remote reconnect (uid
  /// flapping) never re-opens a battle already under way.
  void _maybeStartHostEngine() {
    if (!_isHost ||
        _engineStarted ||
        _countdownEndMs != null ||
        _video.remoteUid.value == null) {
      return;
    }
    // Both players are here. Run the countdown first (synced to the guest),
    // then open the engine when it hits zero.
    _countdownEndMs = _nowMs + _kCountdownMs;
    _video.sendMatchMessage({'t': 'ms_countdown'});
    _countdownTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!mounted) return;
      if (_nowMs >= (_countdownEndMs ?? 0)) {
        _countdownTimer?.cancel();
        _openEngine();
      } else {
        setState(() {}); // tick the on-screen number
      }
    });
    if (mounted) setState(() {});
  }

  /// Host-only: actually open the chess-clock engine (after the countdown) and
  /// drive it on a timer.
  void _openEngine() {
    if (_engineStarted) return;
    _engineStarted = true;
    // Record the finals like any tournament match - the match is mode
    // "tournament", so the backend records it and completeMatch (fired when
    // both clocks hit zero) stops it. Host-only and once. Fire-and-forget: a
    // recording failure must never block the marquee battle. No round
    // boundaries are sent - the chess-clock format has no fixed rounds, so the
    // highlight renders full-length.
    unawaited(_matchmaking.startRecording(widget.pairing.matchId));
    final cfg = MainStageBattleConfig(
      turnMs: widget.pairing.turnMs,
      interrupts: widget.pairing.interrupts,
      shotClockMs: widget.pairing.shotClockMs,
      graceMs: widget.pairing.graceMs,
    );
    var b = MainStageBattleState.create([_myUid, _oppUid], config: cfg);
    b = b.reduce(MsEvent.open, by: _myUid, atMs: _nowMs);
    _battle = b;
    _afterStateChange(broadcast: true);
    _tick = Timer.periodic(const Duration(milliseconds: 300), (_) {
      if (_battle == null || _battle!.isOver) return;
      _hostApply(MsEvent.tick);
    });
  }

  /// Host-only: apply an event to the engine, auto-start the holder's talk
  /// clock (so the shot-clock never ping-pongs - V1 keeps talk auto-started;
  /// voice-driven start is a later refinement), then broadcast + react.
  void _hostApply(MsEvent ev, {String? by}) {
    if (!_isHost || _battle == null) return;
    var b = _battle!.reduce(ev, by: by, atMs: _nowMs);
    if (b.floor != null && !b.talking) {
      b = b.reduce(MsEvent.startTalking, by: b.floor, atMs: _nowMs);
    }
    _battle = b;
    _afterStateChange(broadcast: true);
  }

  void _onMessage(Map<String, dynamic> m) {
    final t = m['t'];
    if (t == 'ms_state' && !_isHost) {
      final s = m['s'];
      if (s is Map) {
        _battle = MainStageBattleState.fromMap(Map<String, dynamic>.from(s));
        _afterStateChange(broadcast: false);
      }
    } else if (t == 'ms_countdown' && !_isHost && _countdownEndMs == null) {
      // Mirror the host's pre-battle countdown locally. When the host opens the
      // engine it broadcasts ms_state, which takes over and ends the countdown.
      _countdownEndMs = _nowMs + _kCountdownMs;
      _countdownTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (!mounted) return;
        if (_battle != null) _countdownTimer?.cancel();
        setState(() {});
      });
      if (mounted) setState(() {});
    } else if (t == 'ms_intent' && _isHost) {
      final ev = _eventFromName(m['ev'] as String?);
      if (ev != null) _hostApply(ev, by: m['by'] as String?);
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

  /// Push an intent: the host applies it directly; the guest sends it to the
  /// host (who is authoritative). Yield only matters if you hold the floor;
  /// interrupt only if the opponent does - the engine re-checks either way.
  void _intent(MsEvent ev) {
    if (_battle == null || _battle!.isOver) return;
    if (_isHost) {
      _hostApply(ev, by: _myUid);
    } else {
      _video.sendMatchMessage({'t': 'ms_intent', 'ev': ev.name, 'by': _myUid});
    }
  }

  /// Common reaction to any new state: refresh the mic (only the floor-holder
  /// is heard), repaint, broadcast if host, and settle on end.
  void _afterStateChange({required bool broadcast}) {
    final b = _battle;
    if (b == null) return;
    // Mute me unless I hold the floor (one speaker at a time, the turn rule).
    _video.muteLocalAudio(b.mutedPlayer == _myUid);
    if (broadcast && _isHost) {
      _video.sendMatchMessage({'t': 'ms_state', 's': b.toMap()});
    }
    if (b.isOver && _isHost && !_completeSent) {
      _completeSent = true;
      _tick?.cancel();
      // Mark the battle complete so the judge panel can settle it.
      _matchmaking.completeMatch(widget.pairing.matchId).catchError((_) {});
    }
    _driveInterruptCue(b);
    if (mounted) setState(() {});
  }

  /// Flash + buzz when an interrupt is winding up. The flash animates whenever
  /// SOMEONE is being cut into (shown on the target's clock on both screens);
  /// the haptic fires once, only on MY device, only when I'm the one being
  /// interrupted — the person who needs the "land it now" jolt.
  void _driveInterruptCue(MainStageBattleState b) {
    final pending = b.pendingBy != null && b.status == MsStatus.live;
    if (pending && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!pending && _pulse.isAnimating) {
      _pulse.stop();
      _pulse.value = 0;
    }
    final iAmTarget = pending && b.pendingBy == _oppUid && b.floor == _myUid;
    if (iAmTarget && !_beingInterrupted) {
      _beingInterrupted = true;
      HapticFeedback.heavyImpact();
    } else if (!iAmTarget && _beingInterrupted) {
      _beingInterrupted = false;
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _countdownTimer?.cancel();
    _msgSub?.cancel();
    _pulse.dispose();
    _video.remoteUid.removeListener(_maybeStartHostEngine);
    _video.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(child: _body()),
    );
  }

  /// The pre-battle countdown: a big number that pops each second until the
  /// clock starts.
  Widget _countdownView() {
    final n = _countdownLeft;
    final gold = context.palette.reward;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'BOTH ON STAGE',
            style: TextStyle(
              color: gold,
              fontSize: 14,
              fontWeight: FontWeight.w900,
              letterSpacing: 3,
            ),
          ),
          const SizedBox(height: 12),
          // Same draining ring as a ranked warm-up (one timer language).
          WarmupRing(seconds: n, total: _kCountdownMs ~/ 1000),
          const SizedBox(height: 8),
          Text(
            n > 0 ? 'Battle starts…' : 'Here we go.',
            style: const TextStyle(color: Colors.white70, fontSize: 16),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70),
          ),
        ),
      );
    }
    // Both players are present: the pre-battle countdown runs before the first
    // clock starts.
    if (_battle == null && _countdownEndMs != null) {
      return _countdownView();
    }
    if (!_initialized || _battle == null) {
      // Before the engine opens: connecting, or (for the first arrival) waiting
      // on the opponent. Say so, and promise the clock has not started - the
      // host's engine does not open until the opponent is in the channel.
      final waitingForOpponent = _initialized && _isHost && !_engineStarted;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(
                waitingForOpponent
                    ? 'Waiting for your opponent to arrive…\nYour clock has not started.'
                    : 'Connecting to the stage…',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
            ],
          ),
        ),
      );
    }
    final b = _battle!;
    return Stack(
      fit: StackFit.expand,
      children: [
        _video.remoteVideoView() ??
            const ColoredBox(
              color: Colors.black,
              child: Center(
                child: Text(
                  'Waiting for your opponent…',
                  style: TextStyle(color: Colors.white70),
                ),
              ),
            ),
        Positioned(
          // Tight under the scorebug on the right, glowing while you hold
          // the mic (camera eye line: the lens is at the top of the phone).
          right: 4,
          top: _kSelfViewTop,
          width: _kSelfViewW,
          height: _kSelfViewH,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: b.floor == _myUid
                    ? const Color(0xFFFF2E7E)
                    : Colors.white.withValues(alpha: 0.25),
                width: b.floor == _myUid ? 2 : 1,
              ),
              boxShadow: b.floor == _myUid
                  ? const [BoxShadow(color: Color(0x8CFF2E7E), blurRadius: 18)]
                  : null,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: _video.localVideoView(),
            ),
          ),
        ),
        _clocks(b),
        if (b.isOver) ...[
          Positioned.fill(
            child: IgnorePointer(
              child: Center(
                child: EndStamp(
                  text: 'TIME!',
                  gold: true,
                  kicker: widget.pairing.roundLabel,
                  footer: 'THE JUDGES DECIDE',
                ),
              ),
            ),
          ),
          _endOverlay(),
        ] else
          _controls(b),
      ],
    );
  }

  Widget _clocks(MainStageBattleState b) {
    // The scorebug (same as a ranked battle). The clock of whoever is being
    // cut into flashes red on both screens.
    final target = b.pendingBy == null
        ? null
        : (b.pendingBy == _myUid ? _oppUid : _myUid);
    final iHold = b.floor == _myUid;
    final oppOut = (b.remaining[_oppUid] ?? 0) == 0;
    return Positioned(
      top: 2,
      left: 4,
      right: 4,
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (context, _) {
          final t = Curves.easeInOut.transform(_pulse.value);
          return BattleScorebug(
            oppName: _oppName ?? 'Them',
            myMs: b.remaining[_myUid] ?? 0,
            oppMs: b.remaining[_oppUid] ?? 0,
            totalMs: b.config.turnMs,
            myMood: !iHold
                ? PlateMood.idle
                : (oppOut ? PlateMood.finalWord : PlateMood.live),
            oppLive: b.floor == _oppUid,
            mySteals: b.steals[_myUid] ?? 0,
            oppSteals: b.steals[_oppUid] ?? 0,
            totalSteals: widget.pairing.interrupts,
            flashMine: target == _myUid ? t : 0,
            flashOpp: target == _oppUid ? t : 0,
            mainStage: true,
            mySeed: widget.pairing.seeds[_myUid],
            oppSeed: widget.pairing.seeds[_oppUid],
          );
        },
      ),
    );
  }

  /// ONE contextual action beside the self-view: Pass the mic while you hold
  /// it, Interrupt while they do, Drop the mic once they're out of time.
  Widget _controls(MainStageBattleState b) {
    final iHoldFloor = b.floor == _myUid;
    final oppHoldsFloor = b.floor == _oppUid;
    final oppOutOfTime = (b.remaining[_oppUid] ?? 0) == 0;
    final iAmInterrupting = b.pendingBy == _myUid; // my cut-in is winding up
    final canInterrupt =
        oppHoldsFloor &&
        (b.steals[_myUid] ?? 0) > 0 &&
        (b.remaining[_myUid] ?? 0) > 0 &&
        b.pendingBy == null; // one interrupt in flight at a time

    final Widget pill;
    if (iHoldFloor && oppOutOfTime) {
      // Dead-air escape: nothing is forfeited, the battle would end when
      // your clock ran out anyway.
      pill = NeonActionButton(
        label: 'Drop the mic',
        icon: Icons.mic_external_off_rounded,
        compact: true,
        colors: const [Color(0xFFF6D66B), Color(0xFFD9A21E)],
        glow: const Color(0xFFF4C838),
        onPressed: () => _intent(MsEvent.endEarly),
      );
    } else if (iHoldFloor) {
      pill = NeonActionButton(
        label: 'Pass the mic',
        icon: Icons.mic_external_off_rounded,
        compact: true,
        onPressed: () => _intent(MsEvent.yield),
      );
    } else {
      final left = b.steals[_myUid] ?? 0;
      pill = NeonActionButton(
        label: iAmInterrupting ? 'Cutting in' : 'Interrupt ($left)',
        icon: Icons.bolt_rounded,
        compact: true,
        busy: iAmInterrupting,
        colors: const [Color(0xFFFF7A1A), Color(0xFFFF2D3A)],
        glow: const Color(0xFFFF7A1A),
        onPressed: canInterrupt ? () => _intent(MsEvent.interrupt) : null,
      );
    }
    final round = widget.pairing.roundLabel;
    return Positioned(
      left: 4,
      right: 4 + _kSelfViewW + 6,
      top: _kSelfViewTop,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          pill,
          if (round != null) ...[
            const SizedBox(height: 8),
            // Which round this is, and who is deciding it.
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: BattleScorebug.gold.withValues(alpha: 0.45),
                ),
              ),
              child: Text(
                '$round · THE JUDGES DECIDE',
                style: const TextStyle(
                  color: BattleScorebug.goldLight,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.4,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _endOverlay() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        color: Colors.black87,
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Time',
              style: TextStyle(
                color: context.palette.reward,
                fontSize: 20,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              "Both clocks are out — now watch the panel decide it. That's the "
              'best part of the show.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 16),
            NeonActionButton(
              label: 'Watch the judges decide',
              icon: Icons.gavel_rounded,
              compact: true,
              colors: const [Color(0xFF22C58B), Color(0xFF0E8F6A)],
              glow: const Color(0xFF22C58B),
              onPressed: () => Navigator.of(context).pushReplacement(
                MaterialPageRoute(
                  builder: (_) =>
                      WatchJudgesScreen(matchId: widget.pairing.matchId),
                ),
              ),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst),
              child: const Text('Leave'),
            ),
          ],
        ),
      ),
    );
  }
}
