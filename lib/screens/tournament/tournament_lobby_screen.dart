import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../core/services/matchmaking_service.dart';
import '../match/match_screen.dart';

/// Waiting for your bracket opponent to turn up.
///
/// WHY TOURNAMENTS NEED THIS RATHER THAN THE BIO REVEAL. An ordinary match
/// pairs two people who are both in the app right now, so the reveal can
/// assume both are present and count down. A tournament round is ASYNC by
/// design - your opponent has hours to play and may not be awake - so the
/// honest state here is "you've checked in, they haven't yet", with no
/// countdown pretending otherwise.
///
/// It also deliberately offers no skip and no requeue. You cannot decline
/// your bracket opponent, and there is no queue to go back to: the only
/// two outcomes are that they turn up, or the round's window closes and
/// the forfeit sweep hands you the win.
class TournamentLobbyScreen extends StatefulWidget {
  const TournamentLobbyScreen({super.key, required this.tournamentId});

  final String tournamentId;

  @override
  State<TournamentLobbyScreen> createState() => _TournamentLobbyScreenState();
}

class _TournamentLobbyScreenState extends State<TournamentLobbyScreen> {
  MatchPairing? _pairing;
  String? _opponentName;
  String? _error;
  int? _windowEndMs;
  bool _opponentHere = false;
  bool _navigated = false;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _matchSub;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _matchSub?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final result = await FirebaseFunctions.instance
          .httpsCallable('startTournamentMatch')
          .call<Map<String, dynamic>>({'tournamentId': widget.tournamentId});
      final data = result.data;
      final pairing = MatchPairing.fromMap(data, fallbackMode: 'tournament');
      if (!mounted) return;
      setState(() {
        _pairing = pairing;
        _windowEndMs = (data['windowEndMs'] as num?)?.toInt();
        _opponentHere = data['opponentArrived'] == true;
      });
      _loadOpponent(pairing.opponentId);
      _watch(pairing);
    } on FirebaseFunctionsException catch (e) {
      if (mounted) setState(() => _error = e.message ?? 'Could not start.');
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not start your match.');
    }
  }

  Future<void> _loadOpponent(String uid) async {
    final snap =
        await FirebaseFirestore.instance.collection('users').doc(uid).get();
    if (mounted) {
      setState(() => _opponentName = snap.data()?['username'] as String?);
    }
  }

  /// Both sides watch the match document, so whichever arrives second
  /// starts the battle for both rather than one waiting on a poll.
  void _watch(MatchPairing pairing) {
    _matchSub = FirebaseFirestore.instance
        .collection('matches')
        .doc(pairing.matchId)
        .snapshots()
        .listen((snap) {
      final data = snap.data();
      if (data == null || !mounted) return;
      final arrived = (data['arrivedAt'] as Map?)?.cast<String, dynamic>() ?? {};
      final here = arrived.containsKey(pairing.opponentId);
      if (here != _opponentHere) setState(() => _opponentHere = here);
      if (here && !_navigated) {
        _navigated = true;
        _matchSub?.cancel();
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => MatchScreen(pairing: pairing)),
        );
      }
    });
  }

  String get _windowLabel {
    final end = _windowEndMs;
    if (end == null) return '';
    final left = end - DateTime.now().millisecondsSinceEpoch;
    if (left <= 0) return 'This round has closed.';
    final hours = left ~/ 3600000;
    if (hours >= 1) return 'Round closes in about ${hours}h.';
    return 'Round closes in ${(left ~/ 60000).clamp(1, 59)}m.';
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Your Match')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: _error != null
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!, textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Back'),
                    ),
                  ],
                )
              : _pairing == null
                  ? const CircularProgressIndicator()
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('vs ${_opponentName ?? 'your opponent'}',
                            style: text.headlineSmall),
                        const SizedBox(height: 24),
                        const CircularProgressIndicator(),
                        const SizedBox(height: 24),
                        Text(
                          _opponentHere
                              ? 'Starting...'
                              : 'You are checked in. Waiting for them to '
                                  'arrive.',
                          textAlign: TextAlign.center,
                          style: text.bodyMedium,
                        ),
                        const SizedBox(height: 8),
                        Text(_windowLabel,
                            textAlign: TextAlign.center, style: text.bodySmall),
                        const SizedBox(height: 24),
                        // Said plainly, because otherwise leaving feels like
                        // forfeiting - and it is the opposite. Checking in is
                        // exactly what protects you if they never come.
                        Text(
                          'You can leave and come back before the round '
                          'closes. If they never turn up, the win is yours.',
                          textAlign: TextAlign.center,
                          style: text.bodySmall,
                        ),
                        const SizedBox(height: 16),
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('Leave for now'),
                        ),
                      ],
                    ),
        ),
      ),
    );
  }
}

/// Whether this player has a live matchup they can start right now.
///
/// Mirrors `currentMatchupFor` + `playability` in
/// functions/tournamentPlay.js closely enough to decide whether to SHOW
/// the button. The server is the authority on whether it actually works -
/// this only avoids offering an action that will certainly be refused.
({bool canPlay, String? opponentId, String? note}) tournamentPlayState(
    Map<String, dynamic> tournament, String uid) {
  if (tournament['status'] != 'in_progress') {
    return (canPlay: false, opponentId: null, note: null);
  }
  final rounds = (tournament['bracket'] as Map<String, dynamic>?)?['rounds'];
  if (rounds is! List || rounds.isEmpty) {
    return (canPlay: false, opponentId: null, note: null);
  }
  final round = rounds.last as Map<String, dynamic>;
  final matchups = (round['matchups'] as List?) ?? const [];
  for (final raw in matchups) {
    final m = (raw as Map).cast<String, dynamic>();
    if (m['player1Id'] != uid && m['player2Id'] != uid) continue;
    if (m['isBye'] == true) {
      return (canPlay: false, opponentId: null, note: 'You have a bye.');
    }
    if (m['winnerId'] != null) {
      return (
        canPlay: false,
        opponentId: null,
        note: m['winnerId'] == uid
            ? 'You won this round.'
            : 'You are out of this tournament.',
      );
    }
    final endMs = (round['windowEndMs'] as num?)?.toInt();
    if (endMs != null && DateTime.now().millisecondsSinceEpoch > endMs) {
      return (canPlay: false, opponentId: null, note: 'This round has closed.');
    }
    return (
      canPlay: true,
      opponentId: (m['player1Id'] == uid ? m['player2Id'] : m['player1Id'])
          as String?,
      note: null,
    );
  }
  return (canPlay: false, opponentId: null, note: null);
}

/// Convenience for the detail screen.
String? currentUid() => FirebaseAuth.instance.currentUser?.uid;
