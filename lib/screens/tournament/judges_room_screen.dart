import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../core/services/agora_spectator_service.dart';
import '../../core/services/main_stage_service.dart';
import '../../core/services/spectator_service.dart';
import '../../theme/app_theme.dart';

/// The Main Stage judges' room: a seated panellist watches the battle live and
/// casts their OPEN verdict. Unlike the crowd's live vote, a judge's pick is
/// public and binding - the panel's majority decides the finals, and the whole
/// room sees each vote land as a running tally, which is the drama of the show.
///
/// It reuses the spectator video path ([SpectatorService] -> watchLiveMatch),
/// now that mainstage battles are watchable, and drives
/// [MainStageService.castJudgeVote]. The vote can be cast (and changed) any
/// time during the battle; it locks once the panel reaches a verdict, which the
/// server stamps as `judgeWinnerId` and which settles the battle + advances the
/// bracket.
///
/// This is the LEAN judging surface. The full judges'-video-table / broadcast
/// desk (the five judges seeing each other and debating on camera) is the
/// deliberately deferred layer; here each judge watches the battle and votes.
class JudgesRoomScreen extends StatefulWidget {
  const JudgesRoomScreen({super.key, required this.matchId, this.service});

  final String matchId;
  final MainStageService? service;

  @override
  State<JudgesRoomScreen> createState() => _JudgesRoomScreenState();
}

class _JudgesRoomScreenState extends State<JudgesRoomScreen>
    with WidgetsBindingObserver {
  late final MainStageService _service = widget.service ?? MainStageService();
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
  int _panelSize = 0; // the number of seated judges (the "of N" denominator)

  bool _submitting = false;
  String? _voteError;

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
      // tournament this is - read it FIRST, so the judge can always vote even
      // when the live video can't be fetched. (A judge who opens the room just
      // as the battle ends gets "already-finished" from watchLiveMatch; the
      // open vote has no deadline, so they must still be able to settle it.)
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
      final tid = (m['mainStage'] as Map?)?['tournamentId'] as String?;
      await _resolveNamesAndPanel(tid);

      // Attach the LIVE video as a best-effort extra. Its failure (battle over,
      // viewing unconfigured, a token error) must never block the verdict.
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
        // Prefer the names the token call resolved, if present.
        _player1Name = data['player1Name'] as String? ?? _player1Name;
        _player2Name = data['player2Name'] as String? ?? _player2Name;
      } catch (_) {
        _hasVideo = false; // vote + tally still work without the video
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

  /// Player names + the "of N" panel denominator, straight from Firestore so
  /// they do not depend on the live-video token call succeeding.
  Future<void> _resolveNamesAndPanel(String? tournamentId) async {
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
    if (tournamentId != null) {
      try {
        final t = await db.collection('tournaments').doc(tournamentId).get();
        final judges = t.data()?['judges'];
        if (judges is List) _panelSize = judges.length;
      } catch (_) {/* denominator is cosmetic; the tally still shows counts */}
    }
  }

  Future<void> _vote(String winnerUid) async {
    setState(() {
      _submitting = true;
      _voteError = null;
    });
    try {
      await _service.castJudgeVote(widget.matchId, winnerUid);
    } on FirebaseFunctionsException catch (e) {
      if (mounted) setState(() => _voteError = e.message ?? "Couldn't record that.");
    } catch (_) {
      if (mounted) setState(() => _voteError = "Couldn't record that — try again.");
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
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

  Widget _live() {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _matchRef.snapshots(),
      builder: (context, snap) {
        final match = snap.data?.data();
        final judgeWinner = match?['judgeWinnerId'] as String?;
        final decided = judgeWinner != null;
        // Battle over (or decided): leave the channel so the audio stops.
        final completed = decided || match?['status'] == 'completed';
        if (completed && !_watchStopped) {
          _watchStopped = true;
          WidgetsBinding.instance
              .addPostFrameCallback((_) => _spectator.stopWatching());
        }
        return Column(
          children: [
            Expanded(child: _videoOrVerdict(decided, judgeWinner)),
            _tallyAndVote(decided, judgeWinner),
          ],
        );
      },
    );
  }

  Widget _videoOrVerdict(bool decided, String? winner) {
    if (decided) {
      final name = winner == _player1Id ? _player1Name : _player2Name;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.emoji_events, size: 56, color: context.palette.reward),
              const SizedBox(height: 12),
              Text('$name takes it',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      color: Colors.white, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              const Text('The panel has decided. The bracket moves on.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70)),
            ],
          ),
        ),
      );
    }
    // No live video (battle already ended, or viewing unavailable): the judge
    // still votes. Show a neutral prompt rather than a dead black video area.
    if (!_hasVideo || _watchStopped) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.gavel, size: 48, color: context.palette.reward),
              const SizedBox(height: 12),
              Text(
                '$_player1Name  vs  $_player2Name',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              const Text('Cast your verdict below.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white54)),
            ],
          ),
        ),
      );
    }
    return ValueListenableBuilder<String?>(
      valueListenable: _spectator.failure,
      builder: (context, failure, _) {
        if (failure != null) return _centered(failure);
        return ValueListenableBuilder<Set<int>>(
          valueListenable: _spectator.presentUids,
          builder: (context, present, _) => Column(
            children: [
              Expanded(child: _tile(1, present, _player1Name)),
              const SizedBox(height: 2),
              Expanded(child: _tile(2, present, _player2Name)),
            ],
          ),
        );
      },
    );
  }

  Widget _tile(int playerUid, Set<int> present, String name) {
    final view = _spectator.playerVideo(playerUid);
    return Stack(
      fit: StackFit.expand,
      children: [
        view ??
            ColoredBox(
              color: const Color(0xFF111111),
              child: Center(
                child: Text(
                  present.contains(playerUid)
                      ? name
                      : 'Waiting for $name…',
                  style: const TextStyle(color: Colors.white54),
                ),
              ),
            ),
        Positioned(
          left: 10,
          bottom: 8,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(name,
                style: const TextStyle(color: Colors.white, fontSize: 12)),
          ),
        ),
      ],
    );
  }

  /// The open running tally of judge votes + this judge's vote control.
  Widget _tallyAndVote(bool decided, String? winner) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _matchRef.collection('mainStageVotes').snapshots(),
      builder: (context, snap) {
        var p1 = 0;
        var p2 = 0;
        String? myPick;
        for (final d in snap.data?.docs ?? const []) {
          final w = d.data()['winnerUid'];
          if (w == _player1Id) p1++;
          if (w == _player2Id) p2++;
          if (d.id == _myUid) myPick = w as String?;
        }
        final cast = p1 + p2;
        return Container(
          width: double.infinity,
          color: const Color(0xFF151515),
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _panelSize > 0
                    ? '$cast of $_panelSize judges have voted'
                    : '$cast ${cast == 1 ? 'vote' : 'votes'} in',
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: _voteButton(
                        _player1Id, _player1Name, p1, myPick, decided),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _voteButton(
                        _player2Id, _player2Name, p2, myPick, decided),
                  ),
                ],
              ),
              if (_voteError != null) ...[
                const SizedBox(height: 8),
                Text(_voteError!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: context.palette.live, fontSize: 12)),
              ],
              if (!decided) ...[
                const SizedBox(height: 8),
                const Text('Tap a battler to vote. You can change it until the '
                    'panel decides.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white38, fontSize: 11)),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _voteButton(
      String? uid, String name, int count, String? myPick, bool decided) {
    final gold = context.palette.reward;
    final mine = myPick != null && myPick == uid;
    return FilledButton(
      onPressed: (decided || _submitting || uid == null) ? null : () => _vote(uid),
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 60),
        backgroundColor: mine ? gold : Colors.white12,
        foregroundColor: mine ? Colors.black : Colors.white,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700)),
          Text('$count',
              style:
                  const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
        ],
      ),
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
