import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import '../screens/tournament/live_viewer_screen.dart';

/// What is on right now in a running live tournament.
///
/// Exists because a live event with no way in is not an event. Everything
/// else about live tournaments could be perfect and nobody would watch a
/// single battle, because the only route was knowing a match id. This is
/// the same class of gap as the report button that could only be reached
/// after finishing a match, or the block list nothing could write to - a
/// feature that is built, tested and unreachable.
///
/// Polls rather than listening, deliberately. The list changes when a
/// match starts or finishes, which is a handful of times per round, and a
/// Firestore listener per matchup would be several listeners per viewer
/// for a screen people have open for an hour. One callable every fifteen
/// seconds is cheaper and simpler.
class WatchLiveList extends StatefulWidget {
  const WatchLiveList({
    super.key,
    required this.tournamentId,
    required this.isLiveAndRunning,
  });

  final String tournamentId;

  /// Kept out of this widget so it renders nothing at all for an async
  /// tournament, or one that has not started, without a wasted call.
  final bool isLiveAndRunning;

  @override
  State<WatchLiveList> createState() => _WatchLiveListState();
}

class _WatchLiveListState extends State<WatchLiveList> {
  Timer? _poll;
  List<Map<String, dynamic>> _matches = const [];
  int? _roundNumber;

  @override
  void initState() {
    super.initState();
    if (widget.isLiveAndRunning) {
      _load();
      _poll = Timer.periodic(const Duration(seconds: 15), (_) => _load());
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await FirebaseFunctions.instance
          .httpsCallable('liveMatchesFor')
          .call<Map<String, dynamic>>({'tournamentId': widget.tournamentId});
      if (!mounted) return;
      setState(() {
        _matches = ((r.data['matches'] as List?) ?? const [])
            .map((e) => (e as Map).cast<String, dynamic>())
            .toList();
        _roundNumber = (r.data['roundNumber'] as num?)?.toInt();
      });
    } catch (_) {
      // Renders nothing rather than an error. A failed poll must not make
      // the tournament screen look broken mid-event.
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isLiveAndRunning || _matches.isEmpty) {
      return const SizedBox.shrink();
    }
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 16),
        Text(
          _roundNumber == null ? 'On now' : 'On now - round $_roundNumber',
          style: text.titleMedium,
        ),
        const SizedBox(height: 8),
        ..._matches.map((m) {
          final live = m['live'] == true;
          return Card(
            child: ListTile(
              leading: Icon(
                live ? Icons.sensors : Icons.hourglass_empty,
                color: live ? Theme.of(context).colorScheme.primary : null,
              ),
              title: Text(
                '${m['player1Name'] ?? 'Player 1'} vs '
                '${m['player2Name'] ?? 'Player 2'}',
              ),
              // Says which of the two states this is, because "waiting for
              // players" and "battle in progress" look identical from a
              // list otherwise, and tapping into a waiting room feels
              // broken if you expected a fight.
              subtitle: Text(live ? 'Battling now' : 'Waiting for players'),
              trailing: const Icon(Icons.play_arrow),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => LiveViewerScreen(
                    matchId: m['matchId'] as String,
                    subtitle: _roundNumber == null
                        ? null
                        : 'Round $_roundNumber',
                  ),
                ),
              ),
            ),
          );
        }),
      ],
    );
  }
}
