import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../widgets/live_tally.dart';
import '../battles/get_clip_sheet.dart';
import '../moderation/clip_takedown_sheet.dart';

/// Your own battles, with the vote count moving in real time.
///
/// This is the reason to keep the app open after a match instead of
/// closing it and finding out tomorrow. The scoreboard is a live Firestore
/// listener, so a vote cast anywhere lands here within a second - which is
/// the whole appeal during a tournament, where a bracket place is riding on
/// the count.
///
/// Participants can watch their own match unrestricted precisely because
/// they cannot vote on it, so there is no judgement of theirs left to bias.
/// Everyone else sees a match's score only after casting their own ballot
/// (see firestore.rules).
class MyBattlesScreen extends StatelessWidget {
  const MyBattlesScreen({super.key, this.embedded = false});

  /// True when shown as a bottom-nav tab.
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      return const Scaffold(body: Center(child: Text('Not signed in.')));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('My battles'),
        automaticallyImplyLeading: !embedded,
      ),
      body: FutureBuilder<List<QueryDocumentSnapshot<Map<String, dynamic>>>>(
        future: _myMatches(uid),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                  child: Text('Could not load your battles: ${snap.error}')),
            );
          }
          final docs = snap.data ?? const [];
          if (docs.isEmpty) {
            return const Padding(
              padding: EdgeInsets.all(24),
              child: Center(
                child: Text(
                  'No battles yet. Once you finish one, the crowd\'s verdict '
                  'shows up here while it happens.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: docs.length,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (context, index) =>
                _MatchCard(matchId: docs[index].id, match: docs[index].data()),
          );
        },
      ),
    );
  }

  /// Firestore has no OR across different fields in a single query, so a
  /// player's matches take two queries - one for each side of the pairing -
  /// merged and re-sorted here.
  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>> _myMatches(
      String uid) async {
    final matches = FirebaseFirestore.instance.collection('matches');
    final results = await Future.wait([
      matches
          .where('player1Id', isEqualTo: uid)
          .orderBy('createdAt', descending: true)
          .limit(10)
          .get(),
      matches
          .where('player2Id', isEqualTo: uid)
          .orderBy('createdAt', descending: true)
          .limit(10)
          .get(),
    ]);
    final docs = [...results[0].docs, ...results[1].docs]
      ..sort((a, b) {
        final aTime = a.data()['createdAt'];
        final bTime = b.data()['createdAt'];
        if (aTime is! Timestamp || bTime is! Timestamp) return 0;
        return bTime.compareTo(aTime);
      });
    return docs.take(10).toList();
  }
}

class _MatchCard extends StatelessWidget {
  const _MatchCard({required this.matchId, required this.match});

  final String matchId;
  final Map<String, dynamic> match;

  @override
  Widget build(BuildContext context) {
    final player1Id = match['player1Id'] as String? ?? '';
    final player2Id = match['player2Id'] as String? ?? '';
    final status = match['status'] as String? ?? 'pending';
    final finalized = match['voteFinalized'] == true;
    final winnerId = match['winnerId'] as String?;
    // Window runs from completion, falling back to creation - mirrors
    // voteWindowStartMs in functions/matchFinalization.js.
    final windowStart = match['completedAt'] ?? match['createdAt'];
    final closesAtMs = windowStart is Timestamp
        ? windowStart.millisecondsSinceEpoch + 24 * 60 * 60 * 1000
        : null;

    return FutureBuilder<List<String>>(
      future: _usernames(player1Id, player2Id),
      builder: (context, nameSnap) {
        final names = nameSnap.data ?? const ['Player 1', 'Player 2'];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  (match['mode'] as String? ?? 'exhibition').toUpperCase(),
                  style: Theme.of(context).textTheme.labelSmall,
                ),
                const Spacer(),
                Text(
                  finalized
                      ? _verdict(winnerId, player1Id, names)
                      : status == 'completed'
                          ? 'Being judged'
                          : status,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
                // The only route to the takedown flow, and it belongs here:
                // this is the screen showing your OWN battles, which is
                // exactly where someone unhappy about their footage looks.
                // Only for RECORDED modes - practice matches produce no
                // footage, so offering a clip would promise nothing.
                if ((match['mode'] as String? ?? '') != 'exhibition' &&
                    status == 'completed')
                  IconButton(
                    icon: const Icon(Icons.movie_outlined, size: 18),
                    tooltip: 'Get your clip',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => GetClipSheet.show(context, matchId),
                  ),
                IconButton(
                  icon: const Icon(Icons.more_horiz, size: 18),
                  tooltip: 'Clip options',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => ClipTakedownSheet.show(context, matchId),
                ),
              ],
            ),
            const SizedBox(height: 4),
            // Even a finalized match keeps its scoreboard - the final count
            // is the result, and hiding it the moment it stops moving would
            // remove the payoff for watching.
            LiveTally(
              matchId: matchId,
              player1Name: names[0],
              player2Name: names[1],
              closesAtMs: finalized ? null : closesAtMs,
            ),
          ],
        );
      },
    );
  }

  String _verdict(String? winnerId, String player1Id, List<String> names) {
    if (winnerId == null) return 'Tied - no rating change';
    return '${winnerId == player1Id ? names[0] : names[1]} won';
  }

  Future<List<String>> _usernames(String player1Id, String player2Id) async {
    final db = FirebaseFirestore.instance;
    final snaps = await Future.wait([
      db.collection('users').doc(player1Id).get(),
      db.collection('users').doc(player2Id).get(),
    ]);
    return [
      (snaps[0].data()?['username'] as String?) ?? 'Player 1',
      (snaps[1].data()?['username'] as String?) ?? 'Player 2',
    ];
  }
}
