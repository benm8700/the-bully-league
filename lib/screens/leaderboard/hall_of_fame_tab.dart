import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../vote/feed_page.dart';
import '../../core/services/watch_feed_service.dart';

/// The all-time greatest battles.
///
/// Reads a single precomputed document rather than ranking client-side:
/// the ranking needs every published match plus a username lookup per
/// entry, and it changes at most once a day. See functions/hallOfFame.js
/// for how it is scored - relative to each battle's own era, so a great
/// clip from the first quiet month is not pushed out by a mediocre recent
/// one that simply had more people around to watch it.
///
/// Only PUBLISHED clips are eligible, which is a hard constraint rather
/// than a curation choice: unpublished renders are purged after seven
/// days, so anything else would leave a permanent list of dead links.
class HallOfFameTab extends StatelessWidget {
  const HallOfFameTab({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('stats')
          .doc('hallOfFame')
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const _Empty(
            title: 'Hall of Fame unavailable',
            body: 'Could not load it just now.',
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final entries = (snapshot.data?.data()?['entries'] as List?) ?? const [];
        if (entries.isEmpty) {
          return const _Empty(
            title: 'Nothing here yet',
            body: 'Once battles start getting published, the best of them '
                'end up here permanently.',
          );
        }

        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: entries.length,
          separatorBuilder: (_, _) => const SizedBox(height: 10),
          itemBuilder: (context, i) {
            final e = (entries[i] as Map).cast<String, dynamic>();
            return _HallCard(entry: e);
          },
        );
      },
    );
  }
}

class _HallCard extends StatelessWidget {
  const _HallCard({required this.entry});

  final Map<String, dynamic> entry;

  @override
  Widget build(BuildContext context) {
    final rank = (entry['rank'] as num?)?.toInt() ?? 0;
    final p1 = entry['player1Username'] as String? ?? 'Unknown';
    final p2 = entry['player2Username'] as String? ?? 'Unknown';
    final winner = entry['winnerUsername'] as String?;
    final votes = (entry['voteCount'] as num?)?.toInt() ?? 0;
    final acclaim = (entry['acclaim'] as num?)?.toInt() ?? 0;
    final videoUrl = entry['videoUrl'] as String?;

    return Card(
      child: ListTile(
        leading: Text(
          '#$rank',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                // The top three get the colour; everything else is a
                // number. A hall of fame where every row looks equally
                // special has no top.
                color: rank <= 3 ? Colors.amber : null,
              ),
        ),
        title: Text('$p1 vs $p2',
            style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text([
          if (winner != null) '$winner won',
          '$votes ${votes == 1 ? 'vote' : 'votes'}',
          if (acclaim > 0) '$acclaim reactions',
        ].join(' · ')),
        trailing: videoUrl == null
            ? null
            : const Icon(Icons.play_circle_outline),
        onTap: videoUrl == null
            ? null
            : () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => Scaffold(
                      backgroundColor: Colors.black,
                      appBar: AppBar(
                        backgroundColor: Colors.black,
                        title: Text('#$rank  $p1 vs $p2'),
                      ),
                      // Reuses the feed's player so a hall-of-fame clip
                      // behaves exactly like any other: same reactions,
                      // same call-it, same everything. A second player
                      // would drift from it.
                      body: FeedPage(
                        match: FeedMatch(
                          matchId: entry['matchId'] as String,
                          player1Id: '',
                          player2Id: '',
                          player1Username: p1,
                          player2Username: p2,
                          voteCount: votes,
                          canVote: false,
                          isParticipant: false,
                          alreadyVoted: false,
                          windowOpen: false,
                          videoUrl: videoUrl,
                          verdict: null,
                          reactionCounts: const {},
                        ),
                        isActive: true,
                        onVote: (_) async => false,
                        onCall: (_, _) {},
                      ),
                    ),
                  ),
                ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.emoji_events_outlined, size: 40),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(body, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
