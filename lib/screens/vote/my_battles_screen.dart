import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/player_avatar.dart';
import '../battles/get_clip_sheet.dart';
import '../settings/blocked_players_screen.dart';
import '../moderation/clip_takedown_sheet.dart';

/// Your own battles, over the battle-themed stage background, with a career
/// summary, filters, and one compact matchup card per completed battle.
///
/// The vote count is a live Firestore listener, so a vote cast anywhere lands
/// here within a second - the reason to keep the app open after a match. The
/// winner is read from the real result, never assumed to be the current user:
/// the CENTRE badge says whether YOU won or lost, while the GREEN avatar ring
/// always marks whoever actually won.
class MyBattlesScreen extends StatefulWidget {
  const MyBattlesScreen({super.key, this.embedded = false});

  /// True when shown as a bottom-nav tab.
  final bool embedded;

  @override
  State<MyBattlesScreen> createState() => _MyBattlesScreenState();
}

enum _BattleFilter { all, wins, losses }

class _MyBattlesScreenState extends State<MyBattlesScreen> {
  _BattleFilter _filter = _BattleFilter.all;

  /// Fetched once and cached, so tapping a filter re-filters locally rather
  /// than re-querying Firestore on every tap.
  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>>? _matchesFuture;
  String? _uid;

  @override
  void initState() {
    super.initState();
    _uid = FirebaseAuth.instance.currentUser?.uid;
    if (_uid != null) _matchesFuture = _myMatches(_uid!);
  }

  /// Win / loss / tie / still-judging, from the current user's perspective.
  bool _isWin(Map<String, dynamic> m) =>
      m['voteFinalized'] == true && m['winnerId'] == _uid;
  bool _isLoss(Map<String, dynamic> m) {
    final w = m['winnerId'];
    return m['voteFinalized'] == true && w != null && w != _uid;
  }

  @override
  Widget build(BuildContext context) {
    final uid = _uid;
    if (uid == null) {
      return const Scaffold(body: Center(child: Text('Not signed in.')));
    }
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        automaticallyImplyLeading: !widget.embedded,
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Battle-themed stage background: gloves + mic at the top, a dark
          // open middle for the content, crowd at the bottom. fitWidth /
          // topCenter keeps the whole composition visible; the dark base fills
          // whatever the artwork doesn't reach.
          const ColoredBox(color: Color(0xFF0E0B14)),
          Image.asset(
            'assets/home/mybattles_background.png',
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
                colors: [Color(0x2E000000), Color(0x0A000000), Color(0x66000000)],
              ),
            ),
          ),
          SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Title rides up beside the mic stand (left of it), so the
                // career card below meets the base of the mic stand rather
                // than leaving dead space at the top.
                const SizedBox(height: 12),
                const _Title(),
                const SizedBox(height: 12),
                _CareerSummary(uid: uid),
                const SizedBox(height: 14),
                _Filters(
                  selected: _filter,
                  onChanged: (f) => setState(() => _filter = f),
                ),
                const SizedBox(height: 12),
                Expanded(child: _buildList(uid)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList(String uid) {
    return FutureBuilder<List<QueryDocumentSnapshot<Map<String, dynamic>>>>(
      future: _matchesFuture,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: Text(
                'Could not load your battles: ${snap.error}',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
            ),
          );
        }
        final all = snap.data ?? const [];
        final docs = all.where((d) {
          final m = d.data();
          switch (_filter) {
            case _BattleFilter.all:
              return true;
            case _BattleFilter.wins:
              return _isWin(m);
            case _BattleFilter.losses:
              return _isLoss(m);
          }
        }).toList();

        if (docs.isEmpty) {
          return EmptyState(
            icon: Icons.sports_mma_outlined,
            title: _filter == _BattleFilter.all
                ? 'No battles yet'
                : 'Nothing here',
            message: _filter == _BattleFilter.all
                ? 'Once you finish a battle, it shows up here so you can '
                    'watch the crowd\'s verdict come in.'
                : 'No battles match this filter yet.',
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          itemCount: docs.length,
          separatorBuilder: (_, _) => const SizedBox(height: 12),
          itemBuilder: (context, index) => _BattleCard(
            uid: uid,
            matchId: docs[index].id,
            match: docs[index].data(),
          ),
        );
      },
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
          .limit(20)
          .get(),
      matches
          .where('player2Id', isEqualTo: uid)
          .orderBy('createdAt', descending: true)
          .limit(20)
          .get(),
    ]);
    final docs = [...results[0].docs, ...results[1].docs]
      ..sort((a, b) {
        final aTime = a.data()['createdAt'];
        final bTime = b.data()['createdAt'];
        if (aTime is! Timestamp || bTime is! Timestamp) return 0;
        return bTime.compareTo(aTime);
      });
    return docs.take(20).toList();
  }
}

/// "MY BATTLES" - bold italic, off-white with a subtle pink glow.
class _Title extends StatelessWidget {
  const _Title();

  @override
  Widget build(BuildContext context) {
    final accent = context.palette.accent;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Text(
        'MY BATTLES',
        style: Theme.of(context).textTheme.headlineMedium?.copyWith(
          fontWeight: FontWeight.w900,
          fontStyle: FontStyle.italic,
          color: const Color(0xFFF5F0EA),
          letterSpacing: 0.5,
          shadows: [
            Shadow(color: accent.withValues(alpha: 0.55), blurRadius: 16),
            const Shadow(color: Colors.black, blurRadius: 6),
          ],
        ),
      ),
    );
  }
}

/// A compact translucent card with the current user's career stats:
/// WINS | LOSSES | WIN RATE | STREAK, from the live user document.
class _CareerSummary extends StatelessWidget {
  const _CareerSummary({required this.uid});

  final String uid;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('users')
            .doc(uid)
            .snapshots(),
        builder: (context, snap) {
          final d = snap.data?.data() ?? const {};
          final wins = (d['wins'] as num?)?.toInt() ?? 0;
          final losses = (d['losses'] as num?)?.toInt() ?? 0;
          final played = wins + losses;
          final winRate = played > 0 ? ((wins / played) * 100).round() : 0;
          final streakMap = d['voteStreak'];
          final streak =
              (streakMap is Map ? streakMap['days'] : null) as num? ?? 0;

          return Container(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF0C0A12).withValues(alpha: 0.82),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
            ),
            child: IntrinsicHeight(
              child: Row(
                children: [
                  _stat(context, '$wins', 'WINS',
                      valueColor: palette.winner),
                  _divider(),
                  _stat(context, '$losses', 'LOSSES',
                      valueColor: palette.accent),
                  _divider(),
                  _stat(context, '$winRate%', 'WIN RATE',
                      valueColor: Colors.white,
                      labelColor: const Color(0xFF7FD3E6)),
                  _divider(),
                  _stat(context, '🔥 $streak', 'STREAK',
                      valueColor: const Color(0xFFFFA31E)),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _divider() => Container(
        width: 1,
        margin: const EdgeInsets.symmetric(vertical: 2),
        color: Colors.white.withValues(alpha: 0.10),
      );

  Widget _stat(BuildContext context, String value, String label,
      {required Color valueColor, Color? labelColor}) {
    final text = Theme.of(context).textTheme;
    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              maxLines: 1,
              style: text.titleLarge?.copyWith(
                fontWeight: FontWeight.w900,
                color: valueColor,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: text.labelSmall?.copyWith(
              color: labelColor ?? Colors.white.withValues(alpha: 0.6),
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
            ),
          ),
        ],
      ),
    );
  }
}

/// ALL / WINS / LOSSES pill filters.
class _Filters extends StatelessWidget {
  const _Filters({required this.selected, required this.onChanged});

  final _BattleFilter selected;
  final ValueChanged<_BattleFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          _pill(context, 'ALL', _BattleFilter.all),
          const SizedBox(width: 10),
          _pill(context, 'WINS', _BattleFilter.wins),
          const SizedBox(width: 10),
          _pill(context, 'LOSSES', _BattleFilter.losses),
        ],
      ),
    );
  }

  Widget _pill(BuildContext context, String label, _BattleFilter value) {
    final accent = context.palette.accent;
    final isSel = selected == value;
    return Expanded(
      child: Material(
        color: isSel ? accent : Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(22),
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: () => onChanged(value),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: isSel
                    ? accent
                    : Colors.white.withValues(alpha: 0.16),
              ),
              boxShadow: isSel
                  ? [
                      BoxShadow(
                        color: accent.withValues(alpha: 0.4),
                        blurRadius: 12,
                        spreadRadius: -3,
                      ),
                    ]
                  : null,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 9),
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: isSel
                          ? Colors.white
                          : Colors.white.withValues(alpha: 0.75),
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.5,
                    ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One completed battle, from the CURRENT USER's perspective (always on the
/// left). The winner's avatar carries a green glowing ring; the centre badge
/// says whether the current user won or lost.
class _BattleCard extends StatelessWidget {
  const _BattleCard({
    required this.uid,
    required this.matchId,
    required this.match,
  });

  final String uid;
  final String matchId;
  final Map<String, dynamic> match;

  @override
  Widget build(BuildContext context) {
    final player1Id = match['player1Id'] as String? ?? '';
    final player2Id = match['player2Id'] as String? ?? '';
    final status = match['status'] as String? ?? 'pending';
    final finalized = match['voteFinalized'] == true;
    final winnerId = match['winnerId'] as String?;
    final mode = match['mode'] as String? ?? 'exhibition';
    final isTournament = mode == 'tournament';
    final palette = context.palette;

    final iAmP1 = uid == player1Id;
    final oppId = iAmP1 ? player2Id : player1Id;

    final gold = palette.reward;
    final pink = palette.accent;
    final borderColor = isTournament ? gold : pink;

    final when = _relativeDate(match['completedAt'] ?? match['createdAt']);

    return FutureBuilder<List<({String name, String? photo})>>(
      future: _players(player1Id, player2Id),
      builder: (context, infoSnap) {
        final info = infoSnap.data ??
            const [
              (name: 'Player 1', photo: null),
              (name: 'Player 2', photo: null),
            ];
        // Current user is always shown on the LEFT.
        final me = iAmP1 ? info[0] : info[1];
        final opp = iAmP1 ? info[1] : info[0];

        return Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => _showOptions(context, mode, status, oppId, opp.name),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xFF0B0910).withValues(alpha: 0.78),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: borderColor.withValues(
                      alpha: isTournament ? 0.6 : 0.35),
                  width: isTournament ? 1.4 : 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.35),
                    blurRadius: 10,
                    spreadRadius: -4,
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: Column(
                  children: [
                    // Top row: type pill (left), date (right).
                    Row(
                      children: [
                        _typePill(context, isTournament, gold, pink),
                        const Spacer(),
                        Text(
                          when,
                          style: Theme.of(context)
                              .textTheme
                              .labelSmall
                              ?.copyWith(
                                  color: Colors.white.withValues(alpha: 0.55)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // The matchup, fed by the live tally.
                    StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                      stream: FirebaseFirestore.instance
                          .collection('matches')
                          .doc(matchId)
                          .collection('tally')
                          .doc('live')
                          .snapshots(),
                      builder: (context, tallySnap) {
                        final t = tallySnap.data?.data();
                        final p1 = (t?['player1Votes'] as num?)?.toInt() ?? 0;
                        final p2 = (t?['player2Votes'] as num?)?.toInt() ?? 0;
                        final meVotes = iAmP1 ? p1 : p2;
                        final oppVotes = iAmP1 ? p2 : p1;
                        final total = p1 + p2;

                        final decided = finalized && winnerId != null;
                        final meWon = decided && winnerId == uid;
                        final oppWon = decided && winnerId == oppId;
                        final result = !finalized
                            ? _Result.judging
                            : winnerId == null
                                ? _Result.draw
                                : meWon
                                    ? _Result.win
                                    : _Result.loss;

                        return Column(
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: _playerColumn(context,
                                      name: me.name,
                                      photo: me.photo,
                                      votes: meVotes,
                                      isWinner: meWon,
                                      isLoser: oppWon),
                                ),
                                const SizedBox(width: 6),
                                _centre(context, result),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: _playerColumn(context,
                                      name: opp.name,
                                      photo: opp.photo,
                                      votes: oppVotes,
                                      isWinner: oppWon,
                                      isLoser: meWon),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            _judgedRow(context, total),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _typePill(
      BuildContext context, bool isTournament, Color gold, Color pink) {
    final color = isTournament ? gold : pink;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        isTournament ? 'TOURNAMENT' : 'ROAST',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
      ),
    );
  }

  Widget _playerColumn(BuildContext context,
      {required String name,
      required String? photo,
      required int votes,
      required bool isWinner,
      required bool isLoser}) {
    final text = Theme.of(context).textTheme;
    final green = context.palette.winner;
    final pink = context.palette.accent;
    final voteColor = isWinner
        ? green
        : isLoser
            ? pink
            : Colors.white.withValues(alpha: 0.6);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Winner gets a bright green glowing ring; everyone else a thin
        // neutral one so the avatar always reads as circular over the art.
        Container(
          padding: const EdgeInsets.all(2.5),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: isWinner ? green : Colors.white.withValues(alpha: 0.18),
              width: isWinner ? 2.5 : 1,
            ),
            boxShadow: isWinner
                ? [
                    BoxShadow(
                      color: green.withValues(alpha: 0.55),
                      blurRadius: 10,
                      spreadRadius: 0,
                    ),
                  ]
                : null,
          ),
          child: PlayerAvatar(name: name, photoUrl: photo, size: 46),
        ),
        const SizedBox(height: 6),
        Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: text.titleSmall?.copyWith(
            color: Colors.white,
            fontWeight: isWinner ? FontWeight.w800 : FontWeight.w600,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          '$votes ${votes == 1 ? 'vote' : 'votes'}',
          style: text.bodySmall
              ?.copyWith(color: voteColor, fontWeight: FontWeight.w700),
        ),
      ],
    );
  }

  /// The centre column: the result badge (current user's perspective) over VS.
  Widget _centre(BuildContext context, _Result result) {
    final text = Theme.of(context).textTheme;
    final green = context.palette.winner;
    final pink = context.palette.accent;

    late final Widget badge;
    switch (result) {
      case _Result.win:
        badge = _badge(
          bg: green.withValues(alpha: 0.18),
          border: green.withValues(alpha: 0.6),
          glow: green.withValues(alpha: 0.4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('👑', style: TextStyle(fontSize: 12)),
              const SizedBox(width: 3),
              Text('WIN',
                  style: text.labelMedium?.copyWith(
                      color: const Color(0xFF6BE0A0),
                      fontWeight: FontWeight.w900)),
            ],
          ),
        );
      case _Result.loss:
        badge = _badge(
          bg: pink.withValues(alpha: 0.12),
          border: pink.withValues(alpha: 0.6),
          glow: pink.withValues(alpha: 0.3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.close_rounded, size: 14, color: pink),
              const SizedBox(width: 2),
              Text('LOSS',
                  style: text.labelMedium
                      ?.copyWith(color: pink, fontWeight: FontWeight.w900)),
            ],
          ),
        );
      case _Result.draw:
        badge = _badge(
          bg: Colors.white.withValues(alpha: 0.06),
          border: Colors.white.withValues(alpha: 0.22),
          child: Text('DRAW',
              style: text.labelMedium?.copyWith(
                  color: Colors.white70, fontWeight: FontWeight.w800)),
        );
      case _Result.judging:
        badge = _badge(
          bg: Colors.white.withValues(alpha: 0.06),
          border: Colors.white.withValues(alpha: 0.22),
          child: Text('JUDGING',
              style: text.labelSmall?.copyWith(
                  color: Colors.white70, fontWeight: FontWeight.w800)),
        );
    }
    return SizedBox(
      width: 84,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          badge,
          const SizedBox(height: 6),
          Text('VS',
              style: text.labelMedium?.copyWith(
                  color: Colors.white.withValues(alpha: 0.5),
                  fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }

  Widget _badge(
      {required Color bg,
      required Color border,
      Color? glow,
      required Widget child}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: border),
        boxShadow: glow != null
            ? [BoxShadow(color: glow, blurRadius: 10, spreadRadius: -2)]
            : null,
      ),
      child: child,
    );
  }

  /// Centred "N people judged" with a chevron pinned to the right.
  Widget _judgedRow(BuildContext context, int total) {
    final muted = Colors.white.withValues(alpha: 0.55);
    return Row(
      children: [
        const SizedBox(width: 22), // balances the trailing chevron
        Expanded(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.groups, size: 15, color: muted),
              const SizedBox(width: 5),
              Text(
                total == 0
                    ? 'No votes yet'
                    : '$total ${total == 1 ? 'person' : 'people'} judged',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: muted),
              ),
            ],
          ),
        ),
        Icon(Icons.chevron_right,
            size: 20, color: Colors.white.withValues(alpha: 0.45)),
      ],
    );
  }

  /// The card's actions - kept reachable (clip, takedown, block) via a sheet
  /// so the WHOLE card stays tappable, per the spec.
  void _showOptions(BuildContext context, String mode, String status,
      String oppId, String oppName) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (mode != 'exhibition' && status == 'completed')
              ListTile(
                leading: const Icon(Icons.movie_outlined),
                title: const Text('Get your clip'),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  GetClipSheet.show(context, matchId);
                },
              ),
            ListTile(
              leading: const Icon(Icons.flag_outlined),
              title: const Text('Clip options'),
              onTap: () {
                Navigator.pop(sheetCtx);
                ClipTakedownSheet.show(context, matchId);
              },
            ),
            if (oppId.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.block),
                title: const Text('Block this player'),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  confirmBlock(context, oppId, oppName);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<List<({String name, String? photo})>> _players(
      String player1Id, String player2Id) async {
    final db = FirebaseFirestore.instance;
    final snaps = await Future.wait([
      db.collection('users').doc(player1Id).get(),
      db.collection('users').doc(player2Id).get(),
    ]);
    ({String name, String? photo}) read(
        DocumentSnapshot<Map<String, dynamic>> s, String fallback) {
      final data = s.data();
      final name = (data?['username'] as String?) ?? fallback;
      final photos = (data?['profile'] as Map?)?['photoUrls'];
      final photo = (photos is List && photos.isNotEmpty)
          ? photos.first as String?
          : null;
      return (name: name, photo: photo);
    }

    return [read(snaps[0], 'Player 1'), read(snaps[1], 'Player 2')];
  }
}

enum _Result { win, loss, draw, judging }

/// "2h ago" / "Aug 28" style relative date from a Firestore Timestamp.
String _relativeDate(Object? ts) {
  if (ts is! Timestamp) return '';
  final then = ts.toDate();
  final diff = DateTime.now().difference(then);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  if (diff.inDays < 7) return '${diff.inDays}d ago';
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  return '${months[then.month - 1]} ${then.day}';
}
