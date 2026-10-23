import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../core/services/agora_spectator_service.dart';
import '../../core/services/main_stage_service.dart';
import '../../core/services/spectator_service.dart';
import '../../theme/app_theme.dart';
import '../../theme/house_theme.dart';
import '../../widgets/judge_panel_view.dart';

/// The Main Stage judges' room.
///
/// During the BATTLE a seated judge just WATCHES the two roasters here - the
/// video owns the whole screen, there is no voting (that is redundant mid-
/// battle). Once the battle ENDS, this routes to [JudgePanelView]: the judges go
/// on camera at the table, debate, and cast their one public verdict there (with
/// the gavel). Reuses the spectator video path ([SpectatorService] ->
/// watchLiveMatch), now that mainstage battles are watchable.
class JudgesRoomScreen extends StatefulWidget {
  const JudgesRoomScreen({super.key, required this.matchId, this.service});

  final String matchId;
  final MainStageService? service;

  @override
  State<JudgesRoomScreen> createState() => _JudgesRoomScreenState();
}

class _JudgesRoomScreenState extends State<JudgesRoomScreen>
    with WidgetsBindingObserver {
  final SpectatorService _spectator = AgoraSpectatorService();
  final String _myUid = FirebaseAuth.instance.currentUser?.uid ?? '';

  bool _loading = true;
  bool _watchStopped = false;
  bool _hasVideo = false; // whether the live spectator stream attached
  String? _error;
  String? _player1Id;
  String? _player2Id;
  String _player1Name = 'Player 1';
  String _player2Name = 'Player 2';
  String? _tournamentId;

  DocumentReference<Map<String, dynamic>> get _matchRef =>
      FirebaseFirestore.instance.collection('matches').doc(widget.matchId);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Leave the Agora channel when backgrounded so the battle audio can't keep
    // playing out of a phone the judge has navigated away from.
    if (state != AppLifecycleState.resumed) {
      _spectator.stopWatching();
      _watchStopped = true;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _spectator.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      // The MATCH DOC is the source of truth for who is battling and which
      // tournament this is - read it FIRST, so the room always works even when
      // the live video can't be fetched (e.g. the battle just ended).
      final matchSnap = await _matchRef.get();
      final m = matchSnap.data();
      if (m == null || m['mainStage'] == null) {
        if (mounted) {
          setState(() {
            _loading = false;
            _error = "That battle isn't available.";
          });
        }
        return;
      }
      _player1Id = m['player1Id'] as String?;
      _player2Id = m['player2Id'] as String?;
      _tournamentId = (m['mainStage'] as Map?)?['tournamentId'] as String?;
      await _resolveNames();

      // Attach the LIVE video as a best-effort extra. Its failure (battle over,
      // viewing unconfigured, a token error) must never block the room.
      try {
        final result = await FirebaseFunctions.instance
            .httpsCallable('watchLiveMatch')
            .call<Map<String, dynamic>>({'matchId': widget.matchId});
        final data = result.data;
        await _spectator.initialize();
        await _spectator.watch(
          channelName: data['channelName'] as String,
          token: data['token'] as String,
          uid: (data['agoraUid'] as num).toInt(),
        );
        _hasVideo = true;
        _player1Name = data['player1Name'] as String? ?? _player1Name;
        _player2Name = data['player2Name'] as String? ?? _player2Name;
      } catch (_) {
        _hasVideo = false;
      }
      if (mounted) setState(() => _loading = false);
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = "Couldn't open the judges' room.";
        });
      }
    }
  }

  /// Player names straight from Firestore so they do not depend on the
  /// live-video token call succeeding.
  Future<void> _resolveNames() async {
    final db = FirebaseFirestore.instance;
    Future<String?> nameOf(String? uid) async {
      if (uid == null) return null;
      try {
        final s = await db.collection('users').doc(uid).get();
        return s.data()?['username'] as String?;
      } catch (_) {
        return null;
      }
    }

    final results = await Future.wait([nameOf(_player1Id), nameOf(_player2Id)]);
    _player1Name = results[0] ?? 'Player 1';
    _player2Name = results[1] ?? 'Player 2';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Judges\' room'),
        backgroundColor: Colors.black,
      ),
      body: _error != null
          ? _centered(_error!)
          : _loading
              ? const Center(child: CircularProgressIndicator())
              : _live(),
    );
  }

  // Warm vs cool "stage gels" so the two battlers are told apart at a glance -
  // player 1 is always red/①, player 2 always blue/②.
  static const _p1Color = House.gelRed;
  static const _p2Color = House.gelBlue;

  String _nameOf(String? id) => id == _player1Id ? _player1Name : _player2Name;

  Widget _live() {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _matchRef.snapshots(),
      builder: (context, msnap) {
        final match = msnap.data?.data();
        final judgeWinner = match?['judgeWinnerId'] as String?;
        final decided = judgeWinner != null;
        final decidedAtMs = (match?['judgeDecidedAtMs'] as num?)?.toInt();
        // SETTLED = the 30s grace has run and finalize applied the result.
        final settled = match?['voteFinalized'] == true;
        // Battle over (or decided): leave the channel so the audio stops.
        final completed = decided || match?['status'] == 'completed';
        if (completed && !_watchStopped) {
          _watchStopped = true;
          WidgetsBinding.instance
              .addPostFrameCallback((_) => _spectator.stopWatching());
        }

        // THE DEBATE: the battle is over but the verdict hasn't settled. The
        // judges go on camera at the table and cast their public vote there -
        // this is the ONLY place voting happens. Stays mounted (cameras live)
        // until the result settles.
        if (!settled &&
            completed &&
            _tournamentId != null &&
            _player1Id != null &&
            _player2Id != null) {
          return JudgePanelView(
            matchId: widget.matchId,
            tournamentId: _tournamentId!,
            myUid: _myUid,
            player1Id: _player1Id!,
            player2Id: _player2Id!,
            player1Name: _player1Name,
            player2Name: _player2Name,
            winnerId: judgeWinner,
            decidedAtMs: decidedAtMs,
            service: widget.service,
          );
        }

        // SETTLED: the final result.
        if (settled) return _settledScreen(judgeWinner);

        // BATTLE LIVE: judges just WATCH. No voting here - the video owns the
        // screen; the vote happens in the debate above once the battle ends.
        return _battleWatch();
      },
    );
  }

  /// The live battle, watch-only: the two roasters stacked, each filling half
  /// the screen. No vote control - that is the debate's job.
  Widget _battleWatch() {
    if (!_hasVideo || _watchStopped) {
      return _centered('Connecting to the live battle…');
    }
    return ValueListenableBuilder<String?>(
      valueListenable: _spectator.failure,
      builder: (context, failure, _) {
        if (failure != null) return _centered(failure);
        return ValueListenableBuilder<Set<int>>(
          valueListenable: _spectator.presentUids,
          builder: (context, present, _) => Column(
            children: [
              Expanded(child: _watchTile(1, present, _player1Name)),
              const SizedBox(height: 2),
              Expanded(child: _watchTile(2, present, _player2Name)),
            ],
          ),
        );
      },
    );
  }

  /// A battler's live video, full-width, with their colour-coded name banner.
  /// Watch-only - no tap, no selection.
  Widget _watchTile(int playerUid, Set<int> present, String name) {
    final view = _spectator.playerVideo(playerUid);
    final color = playerUid == 1 ? _p1Color : _p2Color;
    return Stack(
      fit: StackFit.expand,
      children: [
        Container(
          decoration: BoxDecoration(border: Border.all(color: color, width: 3)),
          child: view ??
              ColoredBox(
                color: const Color(0xFF111111),
                child: Center(
                  child: Text(
                    present.contains(playerUid) ? name : 'Waiting for $name…',
                    style: const TextStyle(color: Colors.white54),
                  ),
                ),
              ),
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Container(
            color: color.withValues(alpha: 0.92),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              children: [
                _numBadge(playerUid),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w800)),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// The final result screen, once the verdict has settled and the bracket has
  /// moved on.
  Widget _settledScreen(String? winner) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.emoji_events, size: 56, color: context.palette.reward),
            const SizedBox(height: 12),
            Text('${_nameOf(winner)} takes it',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: Colors.white, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            const Text('The panel has decided. The bracket moves on.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () => Navigator.of(context).maybePop(),
              style: FilledButton.styleFrom(
                minimumSize: const Size(220, 48),
              ),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }

  /// A small circled number (①/②) in the player's colour.
  Widget _numBadge(int n) {
    return Container(
      width: 22,
      height: 22,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.3),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 1.5),
      ),
      child: Text('$n',
          style: const TextStyle(
              color: Colors.white, fontSize: 12, fontWeight: FontWeight.w900)),
    );
  }

  Widget _centered(String s) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(s,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70)),
        ),
      );
}
