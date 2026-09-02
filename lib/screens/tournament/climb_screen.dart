import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../core/services/matchmaking_service.dart';
import '../../theme/app_theme.dart';
import '../match/pre_match_screen.dart';
import '../match/recording_consent_screen.dart';
import 'live_viewer_screen.dart';

/// The nightly "climb" tournament, from the player's seat.
///
/// It joins the climb, then polls `climbPoll` (the same poll-to-be-paired
/// shape as matchmaking). The response drives everything:
///   - waiting   -> your standing, plus the OTHER live battles to watch/vote
///                  on while you wait for a same-tier opponent. Waiting time
///                  becomes judging time - the whole point of the format.
///   - in_match  -> route into the real match flow (consent -> camera check ->
///                  bio reveal -> battle), then come back and keep climbing.
///   - eliminated-> you're out; watch the finals.
///   - done      -> the champion is crowned.
class ClimbScreen extends StatefulWidget {
  const ClimbScreen({super.key, required this.tournamentId, this.name});

  final String tournamentId;
  final String? name;

  @override
  State<ClimbScreen> createState() => _ClimbScreenState();
}

class _ClimbScreenState extends State<ClimbScreen> {
  Timer? _poll;
  String _state = "joining"; // joining | waiting | eliminated | done | error
  String? _error;
  Map<String, dynamic>? _standing;
  String? _championUid;
  String? _championName;
  // Guards against re-entering the same match if a poll still reports it while
  // the result is settling.
  String? _routedMatchId;
  bool _navigating = false;

  String get _uid => FirebaseAuth.instance.currentUser!.uid;

  @override
  void initState() {
    super.initState();
    _join();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _join() async {
    try {
      await FirebaseFunctions.instance
          .httpsCallable('joinClimb')
          .call<Map<String, dynamic>>({'tournamentId': widget.tournamentId});
      if (!mounted) return;
      setState(() => _state = "waiting");
      _startPolling();
      _pollOnce();
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      // Already eliminated / joining closed / no intro video etc. - the
      // server's message is the one that knows which.
      setState(() {
        _state = "error";
        _error = e.message ?? 'Could not join the gauntlet.';
      });
    }
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 4), (_) => _pollOnce());
  }

  Future<void> _pollOnce() async {
    if (_navigating) return;
    try {
      final r = await FirebaseFunctions.instance
          .httpsCallable('climbPoll')
          .call<Map<String, dynamic>>({'tournamentId': widget.tournamentId});
      if (!mounted) return;
      final data = r.data;
      final state = data['state'] as String? ?? 'waiting';
      final standing = (data['standing'] as Map?)?.cast<String, dynamic>();

      if (state == 'in_match') {
        final matchId = data['matchId'] as String?;
        if (matchId != null && matchId != _routedMatchId) {
          _routedMatchId = matchId;
          await _goToMatch(MatchPairing.fromMap(
              data.cast<String, dynamic>(), fallbackMode: 'tournament'));
        }
        return;
      }
      if (state == 'done') {
        _poll?.cancel();
        final winnerUid = data['winnerUid'] as String?;
        _resolveChampion(winnerUid);
        return;
      }
      setState(() {
        _state = state; // waiting | eliminated
        _standing = standing ?? _standing;
      });
    } catch (_) {
      // A dropped poll is harmless - the next tick tries again. Never surface
      // it as a broken screen mid-event.
    }
  }

  Future<void> _goToMatch(MatchPairing pairing) async {
    _navigating = true;
    _poll?.cancel();
    final consented = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const RecordingConsentScreen()),
    );
    if (consented == true && mounted) {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => PreMatchScreen(mode: 'tournament', climbPairing: pairing),
        ),
      );
    }
    // Back from the battle - keep climbing.
    _navigating = false;
    if (mounted) {
      setState(() => _state = "waiting");
      _startPolling();
      _pollOnce();
    }
  }

  Future<void> _resolveChampion(String? winnerUid) async {
    String? name;
    if (winnerUid != null) {
      try {
        final s = await FirebaseFirestore.instance
            .collection('users').doc(winnerUid).get();
        name = s.data()?['username'] as String?;
      } catch (_) {/* fall back to a generic message */}
    }
    if (!mounted) return;
    setState(() {
      _state = "done";
      _championUid = winnerUid;
      _championName = name;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.name ?? 'The Gauntlet')),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    switch (_state) {
      case "joining":
        return const Center(child: CircularProgressIndicator());
      case "error":
        return _centeredMessage(Icons.info_outline, 'Not in the gauntlet',
            _error ?? 'You are not in tonight\'s gauntlet.');
      case "done":
        return _championView(context);
      case "eliminated":
        return _statusWithWatch(context, _eliminatedHeader(context));
      case "waiting":
      default:
        return _statusWithWatch(context, _waitingHeader(context));
    }
  }

  // --- Headers -------------------------------------------------------------

  Widget _waitingHeader(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final wins = (_standing?['wins'] as num?)?.toInt() ?? 0;
    // activeCount includes YOU, so opponents = active - 1. When you're the
    // last one standing (no opponents) we drop the count rather than say
    // "0 opponents left".
    final activeCount = (_standing?['activeCount'] as num?)?.toInt();
    final opponents = activeCount == null ? null : activeCount - 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(wins == 0 ? "You're in the gauntlet" : "$wins ${wins == 1 ? 'win' : 'wins'} in",
            style: text.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text(
          opponents == null || opponents <= 0
              ? 'Finding your next match...'
              : 'Finding your next match - $opponents ${opponents == 1 ? 'opponent' : 'opponents'} left.',
          style: text.bodyMedium,
        ),
        const SizedBox(height: 4),
        Text('Win to advance. Lose once and you\'re out.',
            style: text.bodySmall),
      ],
    );
  }

  Widget _eliminatedHeader(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final wins = (_standing?['wins'] as num?)?.toInt() ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text("You're out for tonight",
            style: text.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text(
          wins == 0
              ? 'No shame - jump back in tomorrow. Watch the rest below.'
              : 'You made it to $wins ${wins == 1 ? 'win' : 'wins'}. Watch how it finishes below.',
          style: text.bodyMedium,
        ),
      ],
    );
  }

  // --- Watch list ----------------------------------------------------------

  /// The header, then the OTHER live battles to watch/vote on, read live from
  /// the tournament document (the in-match climbers and their match ids).
  Widget _statusWithWatch(BuildContext context, Widget header) {
    final text = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(16),
          ),
          child: header,
        ),
        const SizedBox(height: 24),
        Text('Live now - watch and vote',
            style: text.titleMedium),
        const SizedBox(height: 4),
        Text('Judging earns you points, and it is the crowd that decides.',
            style: text.bodySmall),
        const SizedBox(height: 12),
        _WatchList(tournamentId: widget.tournamentId, myUid: _uid),
      ],
    );
  }

  // --- Champion ------------------------------------------------------------

  Widget _championView(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final iWon = _championUid != null && _championUid == _uid;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.emoji_events,
                size: 56, color: context.palette.reward),
            const SizedBox(height: 16),
            Text(iWon ? 'You won the whole thing.' : 'We have a champion',
                style: text.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
                textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              iWon
                  ? 'You beat everyone tonight. Enjoy it.'
                  : _championName != null
                      ? '$_championName beat everyone tonight.'
                      : 'Tonight\'s gauntlet is decided.',
              style: text.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _centeredMessage(IconData icon, String title, String body) {
    final text = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(height: 14),
            Text(title,
                style: text.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
                textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(body, style: text.bodyMedium, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

/// The live climb battles happening right now, other than the viewer's own.
/// Read straight from the tournament document's climb.climbers - no extra
/// callable - so waiting players can spectate + vote.
class _WatchList extends StatelessWidget {
  const _WatchList({required this.tournamentId, required this.myUid});

  final String tournamentId;
  final String myUid;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('tournaments').doc(tournamentId).snapshots(),
      builder: (context, snapshot) {
        final climbers = ((snapshot.data?.data()?['climb']
            as Map<String, dynamic>?)?['climbers'] as List?) ?? const [];
        // Distinct match ids of in-match climbers, excluding my own battle.
        final matchIds = <String>{};
        for (final c in climbers) {
          final m = (c as Map)['currentMatchId'] as String?;
          if (m == null) continue;
          if (c['uid'] == myUid) continue;
          matchIds.add(m);
        }
        if (matchIds.isEmpty) {
          return Text('No other battles live this second - hang tight.',
              style: Theme.of(context).textTheme.bodySmall);
        }
        return Column(
          children: [
            for (final matchId in matchIds)
              Card(
                child: ListTile(
                  leading: Icon(Icons.sensors, color: context.palette.live),
                  title: const Text('Live battle'),
                  subtitle: const Text('Watch and vote'),
                  trailing: const Icon(Icons.play_arrow),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => LiveViewerScreen(matchId: matchId),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
