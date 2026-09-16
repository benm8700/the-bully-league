import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../widgets/empty_state.dart';
import '../profile/performer_profile_screen.dart';

/// The Fame board's accent - the brand PINK (follow/social), so Fame reads as
/// its own axis, distinct from the skill Ranks board.
const Color _fameAccent = Color(0xFFFF3B6B);

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
    final skillQuery = FirebaseFirestore.instance
        .collection('users')
        .orderBy('rating', descending: true)
        // 100 rather than 50: the board is the app's one public
        // scoreboard, and a longer list is what makes a position
        // outside it feel like a real distance to close.
        .limit(kBoardSize);

    // THE FAME BOARD - a second axis beside skill. Ordered by follower count
    // (popularity), which the developer wants public as a real motivator: play
    // and get famous, and here is where the fame is measured. It is
    // deliberately a DIFFERENT board from Ranks (fame vs skill) - a Fame board
    // beside the skill board is coherent; it only becomes the one-status-
    // ladder problem if it competes to BE the skill answer, which it does not.
    // Ranks stays the FIRST/primary tab. Only players with at least one
    // follower appear - a board of zeroes is not a board.
    final fameQuery = FirebaseFirestore.instance
        .collection('users')
        .where('followerCount', isGreaterThan: 0)
        .orderBy('followerCount', descending: true)
        .limit(kBoardSize);

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        // The cinematic stage background runs behind everything, including the
        // transparent app bar / tabs.
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          automaticallyImplyLeading: !embedded,
          bottom: TabBar(
            // Ranks keeps the neutral accent; Fame the pink so the selected
            // tab colour itself signals which axis you're on.
            indicatorColor: Colors.white,
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white.withValues(alpha: 0.55),
            labelStyle: const TextStyle(
                fontWeight: FontWeight.w900, letterSpacing: 2, fontSize: 15),
            tabs: const [
              Tab(text: 'RANKS'),
              Tab(text: 'FAME'),
            ],
          ),
        ),
        body: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: Color(0xFF0E0B14)),
            Image.asset(
              'assets/home/ranks_background.png',
              fit: BoxFit.fitWidth,
              alignment: Alignment.topCenter,
              errorBuilder: (_, _, _) =>
                  const ColoredBox(color: Color(0xFF0E0B14)),
            ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0x3D000000),
                    Color(0x0A000000),
                    Color(0x59000000)
                  ],
                ),
              ),
            ),
            SafeArea(
              child: TabBarView(
                children: [
                  _buildPlayers(context, skillQuery, fame: false),
                  _buildPlayers(context, fameQuery, fame: true),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlayers(
    BuildContext context,
    Query<Map<String, dynamic>> query, {
    required bool fame,
  }) {
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
          return EmptyState(
            icon: fame ? Icons.favorite_border : Icons.leaderboard_outlined,
            title: fame ? 'No fans yet' : 'No one on the board yet',
            message: fame
                ? 'Get funny in front of a crowd and people will follow '
                    'you. The most-followed comedians show up here.'
                : 'Play a battle and you could be the first name '
                    'on the board.',
          );
        }
        final me = FirebaseAuth.instance.currentUser?.uid;
        final onBoard = me != null && docs.any((d) => d.id == me);
        // The self-row is appended only on the skill board - fame position by
        // follower count is far less meaningful, and a fan-less new account
        // isn't on the fame board at all (the query excludes zero-follower
        // users), so there is nothing honest to append.
        final appendSelf = !fame && !onBoard && me != null;

        return ListView.separated(
          // Clears the transparent app bar AND the tab bar above the list.
          padding: const EdgeInsets.fromLTRB(
              0, kToolbarHeight + kTextTabBarHeight + 8, 0, 16),
          itemCount: docs.length + (appendSelf ? 1 : 0),
          separatorBuilder: (_, _) => Divider(
            height: 1,
            thickness: 0.5,
            indent: 16,
            endIndent: 16,
            color: Colors.white.withValues(alpha: 0.08),
          ),
          itemBuilder: (context, index) {
            if (index >= docs.length) return const _YourPosition();
            final data = docs[index].data();
            return _Row(
              uid: docs[index].id,
              position: index + 1,
              username: data['username'] as String? ?? 'Roaster',
              wins: data['wins'] as num? ?? 0,
              losses: data['losses'] as num? ?? 0,
              isMe: docs[index].id == me,
              isGoat: !fame && data['rankTitle'] == 'GOAT',
              fameCount: fame
                  ? ((data['followerCount'] as num?) ?? 0).toInt()
                  : null,
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
    this.uid,
    this.fameCount,
  });

  final int position;
  final String username;
  final num wins;
  final num losses;
  final bool isMe;

  /// True only for an account that actually holds the GOAT title, not merely
  /// one sitting in the top five rows.
  final bool isGoat;

  /// The player's uid, so a tap opens their fame page. Null on the appended
  /// self-position row (which the viewer doesn't need to tap into).
  final String? uid;

  /// When non-null this is a FAME row: the trailing shows this follower count
  /// (in pink) instead of the win-loss record.
  final int? fameCount;

  VoidCallback? _tap(BuildContext context) => uid == null
      ? null
      : () => PerformerProfileScreen.open(context, uid!, username: username);

  /// Trailing content: a follower count on the fame board, else the record.
  Widget _trailing(TextTheme text, {required Color recordColor}) {
    if (fameCount != null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.favorite, size: 13, color: _fameAccent),
          const SizedBox(width: 4),
          Text(
            '$fameCount',
            style: text.bodyMedium
                ?.copyWith(color: _fameAccent, fontWeight: FontWeight.w800),
          ),
        ],
      );
    }
    return Text('$wins-$losses',
        style: text.bodyMedium?.copyWith(color: recordColor));
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final gold = context.palette.reward;

    // THE VIEWER'S OWN ROW is the premium gold row (per the reference): a warm
    // dark-gold translucent tile, a thin gold border and restrained glow, a
    // gold crown + gold rank number, and a white name.
    if (isMe) {
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: gold.withValues(alpha: 0.22),
              blurRadius: 14,
              spreadRadius: -2,
            ),
          ],
        ),
        child: ListTile(
          dense: true,
          onTap: _tap(context),
          visualDensity: const VisualDensity(vertical: -3),
          minVerticalPadding: 4,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
          tileColor: Color.alphaBlend(
            gold.withValues(alpha: 0.15),
            Colors.black.withValues(alpha: 0.5),
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: gold.withValues(alpha: 0.7)),
          ),
          leading: SizedBox(
            width: 52,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('👑', style: TextStyle(fontSize: 16)),
                const SizedBox(width: 4),
                Text(
                  '$position',
                  style: text.titleMedium
                      ?.copyWith(color: gold, fontWeight: FontWeight.w900),
                ),
              ],
            ),
          ),
          title: Text(
            '$username (you)',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: text.bodyLarge
                ?.copyWith(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          trailing: _trailing(text, recordColor: Colors.white),
        ),
      );
    }

    // EVERY other row shows its position number (a real ranking). An actual
    // GOAT additionally carries the 🐐. Understated over the art: a dark glass
    // tile, white name, muted-grey number and record.
    final marker = isGoat ? '$position 🐐' : '$position';
    // DENSE single-line rows so the top ~25 fit without scrolling - the
    // board's job is a scoreboard you can scan, not a few oversized cards.
    return ListTile(
      dense: true,
      onTap: _tap(context),
      visualDensity: const VisualDensity(vertical: -3),
      minVerticalPadding: 4,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      // Dark GLASS, not opaque black, so the artwork stays subtly visible.
      tileColor: Colors.black.withValues(alpha: 0.36),
      leading: SizedBox(
        width: 46,
        child: Text(
          marker,
          textAlign: TextAlign.center,
          style: text.titleMedium?.copyWith(
              color: isGoat
                  ? Colors.white
                  : Colors.white.withValues(alpha: 0.6)),
        ),
      ),
      // A pure skill ladder: position, name, record. No Elo number (hidden)
      // and no XP title (a different axis that would look out of order on
      // an Elo-ranked board). The win-loss record is the one honest,
      // Elo-free signal that belongs on a competitive board - kept on the
      // trailing edge so each row is a single scannable line.
      title: Text(
        username,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: text.bodyLarge
            ?.copyWith(color: Colors.white, fontWeight: FontWeight.w500),
      ),
      trailing: _trailing(text, recordColor: Colors.white.withValues(alpha: 0.6)),
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
