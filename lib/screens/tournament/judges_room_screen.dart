import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../core/services/agora_spectator_service.dart';
import '../../core/services/main_stage_service.dart';
import '../../core/services/spectator_service.dart';
import '../../theme/app_theme.dart';
import '../../theme/house_theme.dart';

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
  // The battler the judge has TAPPED but not yet confirmed. The vote is a
  // two-step select -> confirm, so a mis-tap is reversible (your feedback).
  String? _selectedPlayerId;

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

  // Warm vs cool "stage gels" so the two battlers are told apart at a glance -
  // player 1 is always red/①, player 2 always blue/②. A judge who doesn't know
  // the names can still vote the right person.
  static const _p1Color = House.gelRed;
  static const _p2Color = House.gelBlue;

  String _nameOf(String? id) => id == _player1Id ? _player1Name : _player2Name;
  Color _colorOf(String? id) => id == _player1Id ? _p1Color : _p2Color;
  int _numOf(String? id) => id == _player1Id ? 1 : 2;

  Widget _live() {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _matchRef.snapshots(),
      builder: (context, msnap) {
        final match = msnap.data?.data();
        final judgeWinner = match?['judgeWinnerId'] as String?;
        final decided = judgeWinner != null;
        // Battle over (or decided): leave the channel so the audio stops.
        final completed = decided || match?['status'] == 'completed';
        if (completed && !_watchStopped) {
          _watchStopped = true;
          WidgetsBinding.instance
              .addPostFrameCallback((_) => _spectator.stopWatching());
        }
        // The vote tally drives BOTH the tile highlight and the confirm bar, so
        // it is read once here and passed down.
        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: _matchRef.collection('mainStageVotes').snapshots(),
          builder: (context, vsnap) {
            var p1 = 0;
            var p2 = 0;
            String? myPick;
            for (final d in vsnap.data?.docs ?? const []) {
              final w = d.data()['winnerUid'];
              if (w == _player1Id) p1++;
              if (w == _player2Id) p2++;
              if (d.id == _myUid) myPick = w as String?;
            }
            // Which battler reads as "selected": the one you tapped, or the one
            // you already voted for.
            final highlight = _selectedPlayerId ?? myPick;
            return Column(
              children: [
                Expanded(child: _videoOrVerdict(decided, judgeWinner, highlight)),
                _confirmBar(decided, judgeWinner, p1, p2, myPick),
              ],
            );
          },
        );
      },
    );
  }

  Widget _videoOrVerdict(bool decided, String? winner, String? highlight) {
    if (decided) {
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
            ],
          ),
        ),
      );
    }
    // No live video (battle ended before you got here, or viewing unavailable):
    // you still vote, by tapping one of the two name cards.
    if (!_hasVideo || _watchStopped) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
        child: Column(
          children: [
            Text('Tap the winner',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Colors.white, fontWeight: FontWeight.w700)),
            const SizedBox(height: 16),
            Expanded(child: _nameCard(_player1Id, highlight == _player1Id)),
            const SizedBox(height: 12),
            Expanded(child: _nameCard(_player2Id, highlight == _player2Id)),
          ],
        ),
      );
    }
    return ValueListenableBuilder<String?>(
      valueListenable: _spectator.failure,
      builder: (context, failure, _) {
        if (failure != null) return _centered(failure);
        return ValueListenableBuilder<Set<int>>(
          valueListenable: _spectator.presentUids,
          builder: (context, present, _) {
            final anySel = highlight != null;
            return Column(
              children: [
                Expanded(child: _tile(1, present, _player1Name, _player1Id,
                    highlight == _player1Id, anySel)),
                const SizedBox(height: 2),
                Expanded(child: _tile(2, present, _player2Name, _player2Id,
                    highlight == _player2Id, anySel)),
              ],
            );
          },
        );
      },
    );
  }

  /// A battler's video, tappable to SELECT them as the winner. Selected = bright
  /// white border + a check; once a pick is made the other tile dims.
  Widget _tile(int playerUid, Set<int> present, String name, String? playerId,
      bool selected, bool anySelected) {
    final view = _spectator.playerVideo(playerUid);
    final color = playerUid == 1 ? _p1Color : _p2Color;
    return Stack(
      fit: StackFit.expand,
      children: [
        Container(
          decoration: BoxDecoration(
            border: Border.all(
                color: selected ? Colors.white : color, width: selected ? 5 : 3),
          ),
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
        // Dim the battler you did NOT pick, so the choice is obvious.
        if (anySelected && !selected)
          Positioned.fill(
            child: ColoredBox(color: Colors.black.withValues(alpha: 0.5)),
          ),
        // Numbered, colour-coded name banner across the top.
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
                if (selected)
                  const Icon(Icons.check_circle, color: Colors.white, size: 22),
              ],
            ),
          ),
        ),
        // Transparent tap layer ON TOP (a platform video view would otherwise
        // swallow the tap). Topmost so the whole tile is selectable.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: playerId == null
                ? null
                : () => setState(() => _selectedPlayerId = playerId),
          ),
        ),
      ],
    );
  }

  /// The no-video fallback's tappable card (same select mechanic as a tile).
  Widget _nameCard(String? playerId, bool selected) {
    final color = _colorOf(playerId);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: playerId == null
          ? null
          : () => setState(() => _selectedPlayerId = playerId),
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: 0.22) : Colors.white10,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: selected ? Colors.white : color, width: selected ? 3 : 2),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _numBadge(_numOf(playerId), fg: Colors.white, bg: color),
            const SizedBox(width: 10),
            Flexible(
              child: Text(_nameOf(playerId),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w800)),
            ),
            if (selected) ...[
              const SizedBox(width: 10),
              const Icon(Icons.check_circle, color: Colors.white, size: 22),
            ],
          ],
        ),
      ),
    );
  }

  /// A small circled number (①/②) in the player's colour, used on the tile and
  /// the cards so they read as the same battler.
  Widget _numBadge(int n, {Color fg = Colors.white, Color? bg}) {
    return Container(
      width: 22,
      height: 22,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: bg ?? Colors.black.withValues(alpha: 0.3),
        shape: BoxShape.circle,
        border: Border.all(color: fg, width: 1.5),
      ),
      child: Text('$n',
          style: TextStyle(color: fg, fontSize: 12, fontWeight: FontWeight.w900)),
    );
  }

  /// The single bottom bar: the running tally plus ONE confirm action. There is
  /// no dual vote control any more - you pick a battler by tapping their video,
  /// then confirm here (your feedback). The pick is reversible until confirmed.
  Widget _confirmBar(
      bool decided, String? winner, int p1, int p2, String? myPick) {
    final cast = p1 + p2;
    final sel = _selectedPlayerId;
    final canConfirm = !decided && sel != null && sel != myPick && !_submitting;
    return Container(
      width: double.infinity,
      color: const Color(0xFF151515),
      padding: EdgeInsets.fromLTRB(
          16, 12, 16, 12 + MediaQuery.of(context).padding.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _panelSize > 0
                ? '$cast of $_panelSize judges have voted'
                : '$cast ${cast == 1 ? 'vote' : 'votes'} in',
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
          if (_voteError != null) ...[
            const SizedBox(height: 6),
            Text(_voteError!,
                textAlign: TextAlign.center,
                style: TextStyle(color: context.palette.live, fontSize: 12)),
          ],
          const SizedBox(height: 10),
          _confirmAction(decided, winner, sel, myPick, canConfirm),
        ],
      ),
    );
  }

  Widget _confirmAction(bool decided, String? winner, String? sel,
      String? myPick, bool canConfirm) {
    if (decided) {
      return Text('${_nameOf(winner)} wins. The bracket moves on.',
          textAlign: TextAlign.center,
          style: TextStyle(
              color: context.palette.reward, fontWeight: FontWeight.w700));
    }
    if (canConfirm) {
      final color = _colorOf(sel);
      return FilledButton(
        onPressed: () => _vote(sel!),
        style: FilledButton.styleFrom(
          minimumSize: const Size(double.infinity, 56),
          backgroundColor: color,
          foregroundColor: Colors.white,
        ),
        child: _submitting
            ? const SizedBox(
                height: 20, width: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : Text(
                myPick == null
                    ? 'Vote for ${_nameOf(sel)}'
                    : 'Change vote to ${_nameOf(sel)}',
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
              ),
      );
    }
    if (myPick != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.check_circle, color: context.palette.winner, size: 18),
              const SizedBox(width: 6),
              Text('You voted for ${_nameOf(myPick)}',
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 2),
          const Text('Tap the other battler to change your vote.',
              style: TextStyle(color: Colors.white38, fontSize: 11)),
        ],
      );
    }
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 10),
      child: Text('Tap a battler above to pick the winner.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white54)),
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
