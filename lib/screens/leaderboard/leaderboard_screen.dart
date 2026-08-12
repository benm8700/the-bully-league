import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

/// Top players by rating - the in-app equivalent of the website homepage's
/// "top 5 roasters" concept (CLAUDE.md's Website — Account & Tournament
/// Rules section), broadened to a longer list for in-app browsing. GOAT
/// (top 5) is a live leaderboard position by design, so this screen is a
/// natural fit for surfacing it, though rank-title computation itself
/// stays server-side (functions/matchFinalization.js's syncGoatTier).
class LeaderboardScreen extends StatelessWidget {
  const LeaderboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final query = FirebaseFirestore.instance
        .collection('users')
        .orderBy('rating', descending: true)
        .limit(50);

    return Scaffold(
      appBar: AppBar(title: const Text('Leaderboard')),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: query.snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('Failed to load leaderboard: ${snapshot.error}'));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final docs = snapshot.data!.docs;
          if (docs.isEmpty) {
            return const Center(child: Text('No ranked players yet.'));
          }
          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: docs.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final data = docs[index].data();
              final username = data['username'] as String? ?? 'Roaster';
              final rankTitle = data['rankTitle'] as String? ?? 'Average Joe';
              final rating = data['rating'] as num? ?? 1200;
              final wins = data['wins'] as num? ?? 0;
              final losses = data['losses'] as num? ?? 0;
              final position = index + 1;
              return ListTile(
                leading: CircleAvatar(
                  child: Text(
                    position <= 5 ? '🔥' : '$position',
                    style: const TextStyle(fontSize: 14),
                  ),
                ),
                title: Text(username),
                subtitle: Text('$rankTitle · $wins-$losses'),
                trailing: Text(
                  '$rating',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              );
            },
          );
        },
      ),
    );
  }
}
