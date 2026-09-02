import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../widgets/empty_state.dart';

/// The skill ladder - the in-app equivalent of the website homepage's
/// "top 5 roasters" concept (CLAUDE.md's Website — Account & Tournament
/// Rules section), broadened to a longer list for in-app browsing.
///
/// ORDERED BY ELO (skill), not by XP (2026-08-26). This board answers "who
/// is actually best", and nobody cares who has ground the most XP - so it
/// ranks on the hidden skill rating. The raw Elo NUMBER is still never
/// shown; a player sees only their POSITION, which is what "you can't see
/// the rank number but you can see who's best and where you stand" means.
///
/// Deliberately DIFFERENT from the XP title, which is a player's earned,
/// never-falling identity shown on Home and the profile. This is the
/// competition (position moves up and down); the title is the progression
/// (only climbs). The two axes are different, so the XP TITLE is NOT shown
/// on a row here - a #3 with a lower title than a #5 would look broken.
///
/// The 🐐 marks ACTUAL GOATs - accounts whose authoritative rankTitle is
/// "GOAT" (top-five by Elo AND career-XP eligible, per syncGoatTier), NOT
/// merely whoever sits in the top five rows. So a top-five player who is not
/// yet a GOAT shows their position number and no flame: "if they aren't
/// GOATs they don't get the goat" (the developer's call, 2026-08-31). The
/// board and the profile title therefore always agree on who a GOAT is.
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

    // A single ranked list. The "Hall of Fame" tab was removed - Hall of
    // Fame was dropped from the design (the GOAT top-five serves the
    // fame/prestige purpose), so a second tab for it was dead UI.
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ranks'),
        automaticallyImplyLeading: !embedded,
      ),
      body: _buildPlayers(context, query),
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
          return const EmptyState(
            icon: Icons.leaderboard_outlined,
            title: 'No one on the board yet',
            message: 'Play a battle and you could be the first name '
                'on the board.',
          );
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
              wins: data['wins'] as num? ?? 0,
              losses: data['losses'] as num? ?? 0,
              isMe: docs[index].id == me,
              isGoat: data['rankTitle'] == 'GOAT',
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
    required this.wins,
    required this.losses,
    this.isMe = false,
    this.isGoat = false,
  });

  final int position;
  final String username;
  final num wins;
  final num losses;
  final bool isMe;

  /// True only for an account that actually holds the GOAT title, not merely
  /// one sitting in the top five rows.
  final bool isGoat;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    // EVERY row shows its position number (a real ranking). An actual GOAT
    // additionally carries the 🐐, so their row reads "1 🐐". Everyone else -
    // including a top-five player who is not (yet) a GOAT - is just their
    // number.
    final marker = isGoat ? '$position 🐐' : '$position';
    // DENSE single-line rows so the top ~25 fit without scrolling - the
    // board's job is a scoreboard you can scan, not a few oversized cards.
    return ListTile(
      dense: true,
      visualDensity: const VisualDensity(vertical: -3),
      minVerticalPadding: 4,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      tileColor: isMe ? scheme.primaryContainer.withValues(alpha: 0.35) : null,
      leading: SizedBox(
        width: 46,
        child: Text(
          marker,
          textAlign: TextAlign.center,
          style: text.titleMedium?.copyWith(
              color: isGoat ? null : scheme.onSurfaceVariant),
        ),
      ),
      // A pure skill ladder: position, name, record. No Elo number (hidden)
      // and no XP title (a different axis that would look out of order on
      // an Elo-ranked board). The win-loss record is the one honest,
      // Elo-free signal that belongs on a competitive board - kept on the
      // trailing edge so each row is a single scannable line.
      title: Text(
        isMe ? '$username (you)' : username,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: text.bodyLarge?.copyWith(
            fontWeight: isMe ? FontWeight.bold : FontWeight.w500),
      ),
      trailing: Text('$wins-$losses',
          style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
    );
  }
}

/// The viewer's own place on the ladder, shown when they are outside the
/// visible board.
///
/// Counted rather than paged to: finding position 387 by reading 387
/// documents would be absurd, so this is one aggregation query -
/// how many players out-rank me by Elo, plus one. That is the standard
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
        // No rating means they have never been placed - said nothing about
        // rather than invented a skill position for someone who has not
        // played. (Signup does write a starting rating, so this is only
        // the truly-legacy case.)
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
          wins: me['wins'] as num? ?? 0,
          losses: me['losses'] as num? ?? 0,
          isMe: true,
          isGoat: me['rankTitle'] == 'GOAT',
        ),
      ],
    );
  }
}
