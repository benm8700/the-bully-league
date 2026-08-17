import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../core/services/career_track.dart';

/// The all-time career board: who has done the most, ever.
///
/// A SECOND LADDER ANSWERING A DIFFERENT QUESTION from the ratings board.
/// Rating says who is best right now and it goes down; career points say
/// what someone has actually put in and they only rise. Both deserve a
/// public board, because a ladder nobody can see the top of motivates
/// nobody - and this is the one where showing up beats being gifted.
///
/// Deliberately separate from the Players tab rather than a column on it:
/// the whole point is that a Walk-In can outrank a Headliner here, and
/// side-by-side numbers would just read as a worse version of rating.
class CareerTab extends StatelessWidget {
  const CareerTab({super.key});

  @override
  Widget build(BuildContext context) {
    final me = FirebaseAuth.instance.currentUser?.uid;
    // Single-field ordering, so no composite index is needed.
    final query = FirebaseFirestore.instance
        .collection('users')
        .orderBy('points', descending: true)
        .limit(50);

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: query.snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Center(child: Text('Failed to load the career board.'));
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        // Anyone with no points yet is left off rather than padding the
        // board with a wall of zeroes - an empty board reads as "nobody
        // has started", which at least is true.
        final docs = snapshot.data!.docs
            .where((d) => ((d.data()['points'] as num?) ?? 0) > 0)
            .toList();
        if (docs.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Text(
                'Nobody has put any miles in yet.\n'
                'Points come from battling and from judging other battles.',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }

        return ListView.builder(
          itemCount: docs.length,
          itemBuilder: (context, i) {
            final data = docs[i].data();
            final standing =
                CareerStanding.fromPoints(data['points'] as num?);
            final isMe = docs[i].id == me;
            return ListTile(
              leading: Text(
                '${i + 1}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              title: Text(
                data['username'] as String? ?? 'Unknown',
                style: TextStyle(
                  fontWeight: isMe ? FontWeight.bold : FontWeight.normal,
                ),
              ),
              subtitle: Text(standing.title),
              trailing: Text('${standing.points}'),
            );
          },
        );
      },
    );
  }
}

/// This player's own standing, with how far the next title is.
///
/// The progress bar matters more than the number: a bar visibly filling is
/// what makes a losing streak survivable, since this is the one ladder
/// that cannot go backwards.
class CareerStandingCard extends StatelessWidget {
  const CareerStandingCard({super.key, required this.points});

  final num? points;

  @override
  Widget build(BuildContext context) {
    final s = CareerStanding.fromPoints(points);
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(s.title, textAlign: TextAlign.center, style: text.titleMedium),
          const SizedBox(height: 6),
          if (s.progress != null) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(value: s.progress, minHeight: 6),
            ),
            const SizedBox(height: 4),
            Text(
              '${s.pointsToNext} points to ${s.nextTitle}',
              textAlign: TextAlign.center,
              style: text.bodySmall,
            ),
          ] else
            Text(
              'Top of the career ladder.',
              textAlign: TextAlign.center,
              style: text.bodySmall,
            ),
        ],
      ),
    );
  }
}
