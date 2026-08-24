import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'hall_of_fame_tab.dart';

/// Top players by rating - the in-app equivalent of the website homepage's
/// "top 5 roasters" concept (CLAUDE.md's Website — Account & Tournament
/// Rules section), broadened to a longer list for in-app browsing. GOAT
/// (top 5) is a live leaderboard position by design, so this screen is a
/// natural fit for surfacing it, though rank-title computation itself
/// stays server-side (functions/matchFinalization.js's syncGoatTier).
class LeaderboardScreen extends StatelessWidget {
  const LeaderboardScreen({super.key, this.embedded = false});

  /// True when shown as a bottom-nav tab.
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final query = FirebaseFirestore.instance
        .collection('users')
        .orderBy('rating', descending: true)
        // 100 rather than 50: the board is the app's one public
        // scoreboard, and a longer list is what makes a position
        // outside it feel like a real distance to close.
        .limit(kBoardSize);

    // Two things belong on this tab and they answer different questions:
    // who is the best PLAYER, and what were the best BATTLES. Tabs rather
    // than one scrolling page, because a hall of fame buried under fifty
    // leaderboard rows would never be seen.
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Ranks'),
          automaticallyImplyLeading: !embedded,
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Players'),
              Tab(text: 'Hall of Fame'),
            ],
          ),
        ),
        body: TabBarView(
          children: [_buildPlayers(context, query), const HallOfFameTab()],
        ),
      ),
    );
  }

  Widget _buildPlayers(
    BuildContext context,
    Query<Map<String, dynamic>> query,
  ) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: query.snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Text('Failed to load leaderboard: ${snapshot.error}'),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final docs = snapshot.data!.docs;
        if (docs.isEmpty) {
          return const Center(child: Text('No ranked players yet.'));
        }
        final me = FirebaseAuth.instance.currentUser?.uid;
        final onBoard = me != null && docs.any((d) => d.id == me);

        return ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 8),
          // One extra row when the viewer is NOT on the board - their own
          // position, appended after the hundredth. A scoreboard you
          // cannot find yourself on is just a list of other people.
          itemCount: docs.length + (onBoard || me == null ? 0 : 1),
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, index) {
            if (index >= docs.length) return const _YourPosition();
            final data = docs[index].data();
            return _Row(
              position: index + 1,
              username: data['username'] as String? ?? 'Roaster',
              rankTitle: data['rankTitle'] as String? ?? 'Average Joe',
              rating: data['rating'] as num? ?? 1200,
              wins: data['wins'] as num? ?? 0,
              losses: data['losses'] as num? ?? 0,
              isMe: docs[index].id == me,
            );
          },
        );
      },
    );
  }
}

/// How many players the board shows.
const int kBoardSize = 100;

/// One leaderboard row.
///
/// Split out so the viewer's own appended position renders identically
/// to a row on the board - if it looked different, it would read as a
/// separate widget rather than as their place in the same list.
class _Row extends StatelessWidget {
  const _Row({
    required this.position,
    required this.username,
    required this.rankTitle,
    required this.rating,
    required this.wins,
    required this.losses,
    this.isMe = false,
  });

  final int position;
  final String username;
  final String rankTitle;
  final num rating;
  final num wins;
  final num losses;
  final bool isMe;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      tileColor: isMe ? scheme.primaryContainer.withValues(alpha: 0.35) : null,
      leading: CircleAvatar(
        child: Text(
          // The flame is for the GOAT five, which is a real scarcity
          // rather than decoration - but a viewer needs to see their own
          // NUMBER, so it never replaces theirs.
          position <= 5 && !isMe ? '🔥' : '$position',
          style: const TextStyle(fontSize: 14),
        ),
      ),
      title: Text(isMe ? '$username (you)' : username),
      subtitle: Text('$rankTitle · $wins-$losses'),
      trailing: Text(
        '$rating',
        style: Theme.of(context).textTheme.titleMedium,
      ),
    );
  }
}

/// The viewer's own place on the ladder, shown when they are outside the
/// visible board.
///
/// Counted rather than paged to: finding position 387 by reading 387
/// documents would be absurd, so this is one aggregation query -
/// how many players out-rate me, plus one. That is the standard
/// competition ranking, and it means tied players share a position
/// rather than being ordered arbitrarily.
class _YourPosition extends StatefulWidget {
  const _YourPosition();

  @override
  State<_YourPosition> createState() => _YourPositionState();
}

class _YourPositionState extends State<_YourPosition> {
  Map<String, dynamic>? _me;
  int? _position;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;
      final db = FirebaseFirestore.instance;
      final doc = await db.collection('users').doc(uid).get();
      final data = doc.data();
      final rating = data?['rating'] as num?;
      if (data == null || rating == null) {
        // No rating means they have never been placed. Saying nothing is
        // better than inventing a position for somebody who has not
        // played - the board is not where you learn you are unranked.
        if (mounted) setState(() => _failed = true);
        return;
      }
      final ahead = await db
          .collection('users')
          .where('rating', isGreaterThan: rating)
          .count()
          .get();
      if (!mounted) return;
      setState(() {
        _me = data;
        _position = (ahead.count ?? 0) + 1;
      });
    } catch (_) {
      // Fails quiet. The board above is the feature; a missing self-row
      // is a smaller loss than an error banner under a scoreboard.
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) return const SizedBox.shrink();
    final me = _me;
    final position = _position;
    if (me == null || position == null) {
      return const SizedBox(height: 72);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // A visible break, because this row is NOT the 101st player - it
        // is a jump of unknown distance, and running it straight on from
        // the board would misrepresent where they stand.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
          child: Row(
            children: [
              const Expanded(child: Divider()),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text('YOU',
                    style: Theme.of(context).textTheme.labelSmall),
              ),
              const Expanded(child: Divider()),
            ],
          ),
        ),
        _Row(
          position: position,
          username: me['username'] as String? ?? 'You',
          rankTitle: me['rankTitle'] as String? ?? 'Average Joe',
          rating: me['rating'] as num? ?? 1200,
          wins: me['wins'] as num? ?? 0,
          losses: me['losses'] as num? ?? 0,
          isMe: true,
        ),
      ],
    );
  }
}
