import 'dart:async';

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

  MainStageBattleState? _battle;
  bool _initialized = false;
  bool _engineStarted = false;
  bool _completeSent = false;
  String? _error;

  int get _nowMs => DateTime.now().millisecondsSinceEpoch;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 450));
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
        setState(() => _error =
            "Couldn't connect to the battle. It may have already ended — "
            'head back and try again.');
      }
      return;
    }
    if (!mounted) return;
    _msgSub = _video.matchMessages.listen(_onMessage);
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
    if (!_isHost || _engineStarted || _video.remoteUid.value == null) return;
    _engineStarted = true;
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
    final iAmTarget =
        pending && b.pendingBy == _oppUid && b.floor == _myUid;
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

  Widget _body() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70)),
        ),
      );
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
                child: Text('Waiting for your opponent…',
                    style: TextStyle(color: Colors.white70)),
              ),
            ),
        Positioned(
          right: 16,
          bottom: 120,
          width: 100,
          height: 140,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: _video.localVideoView(),
          ),
        ),
        _clocks(b),
        if (b.isOver) _endOverlay() else _controls(b),
      ],
    );
  }

  String _fmt(int ms) {
    final s = (ms / 1000).ceil();
    final m = s ~/ 60;
    final r = s % 60;
    return '$m:${r.toString().padLeft(2, '0')}';
  }

  Widget _clocks(MainStageBattleState b) {
    // The clock of whoever is being cut into flashes red (shown on both
    // screens). target == the holder the pending interrupt is aimed at.
    final target =
        b.pendingBy == null ? null : (b.pendingBy == _myUid ? _oppUid : _myUid);
    return Positioned(
      top: 12,
      left: 12,
      right: 12,
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (context, _) => Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _clockChip('You', b.remaining[_myUid] ?? 0, b.floor == _myUid,
                b.steals[_myUid] ?? 0,
                flash: target == _myUid),
            _clockChip('Them', b.remaining[_oppUid] ?? 0, b.floor == _oppUid,
                b.steals[_oppUid] ?? 0,
                flash: target == _oppUid),
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
          Text('${'●' * steals}${'○' * ((widget.pairing.interrupts) - steals)}',
              style: TextStyle(
                  color: onFloor ? Colors.black87 : Colors.white54,
                  fontSize: 12)),
        ],
      ),
    );
  }

  Widget _controls(MainStageBattleState b) {
    final iHoldFloor = b.floor == _myUid;
    final oppHoldsFloor = b.floor == _oppUid;
    final oppOutOfTime = (b.remaining[_oppUid] ?? 0) == 0;
    final iAmInterrupting = b.pendingBy == _myUid; // my cut-in is winding up
    final canInterrupt = oppHoldsFloor &&
        (b.steals[_myUid] ?? 0) > 0 &&
        (b.remaining[_myUid] ?? 0) > 0 &&
        b.pendingBy == null; // one interrupt in flight at a time

    // Dead-air escape: you hold the floor, your opponent is spent, and you have
    // nothing left to say. End it now rather than draining a banked clock in
    // silence — nothing is forfeited, the battle would end when your clock ran
    // out anyway. (Keep talking by simply not pressing it.)
    if (iHoldFloor && oppOutOfTime) {
      return Positioned(
        left: 16,
        right: 16,
        bottom: 24,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              "They're out of time — the stage is yours. Land one more, or "
              'end it.',
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
                child: const Text("I'm done — end the battle"),
              ),
            ),
          ],
        ),
      );
    }
    return Positioned(
      left: 16,
      right: 16,
      bottom: 24,
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
          const SizedBox(width: 12),
          Expanded(
            child: FilledButton(
              onPressed: canInterrupt ? () => _intent(MsEvent.interrupt) : null,
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 54),
                backgroundColor:
                    iAmInterrupting ? context.palette.reward : context.palette.live,
                foregroundColor: iAmInterrupting ? Colors.black : null,
                disabledBackgroundColor: iAmInterrupting
                    ? context.palette.reward.withValues(alpha: 0.9)
                    : null,
                disabledForegroundColor: iAmInterrupting ? Colors.black : null,
              ),
              child: Text(iAmInterrupting
                  ? 'Cutting in…'
                  : 'Interrupt (${b.steals[_myUid] ?? 0})'),
            ),
          ),
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
            Text('Time',
                style: TextStyle(
                    color: context.palette.reward,
                    fontSize: 20,
                    fontWeight: FontWeight.w900)),
            const SizedBox(height: 6),
            const Text(
              'Both clocks are out. The judges decide it now — hang tight for '
              'the verdict.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }
}
