import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';


/// Live head-to-head scoreboard for a match still open for voting.
///
/// Genuinely live: it listens to `matches/{matchId}/tally/live`, which the
/// onVoteCast trigger updates on every ballot, so the numbers move while
/// the screen is open. That's the point - the intended experience is
/// watching your own result come in and refreshing to see if you're still
/// ahead.
///
/// WHO CAN SEE IT is enforced in firestore.rules, not here: the two
/// players always, and everyone else only once they have cast their own
/// ballot. A permission-denied read is therefore an expected state rather
/// than an error, and renders as a "hidden until you vote" message instead
/// of a failure.
class LiveTally extends StatelessWidget {
  const LiveTally({
    super.key,
    required this.matchId,
    required this.player1Name,
    required this.player2Name,
    this.closesAtMs,
    this.compact = false,
  });

  final String matchId;
  final String player1Name;
  final String player2Name;
  final int? closesAtMs;

  /// Compact mode drops the inner Card wrapper and shrinks the numbers, for
  /// embedding inside a list card (My Battles) that already provides its own
  /// container - so battles pack more per page. The live vote screen uses
  /// the full-size version.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('matches')
          .doc(matchId)
          .collection('tally')
          .doc('live')
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          // Almost always permission-denied, which is the rules working as
          // designed rather than something being broken.
          return _hidden(context);
        }
        if (!snapshot.hasData) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final data = snapshot.data!.data() ?? const {};
        final p1 = (data['player1Votes'] as num?)?.toInt() ?? 0;
        final p2 = (data['player2Votes'] as num?)?.toInt() ?? 0;
        return _scoreboard(context, p1, p2);
      },
    );
  }

  Widget _hidden(BuildContext context) {
    final content = Column(
      children: [
        const Icon(Icons.visibility_off_outlined),
        const SizedBox(height: 8),
        Text(
          'The score is hidden until you vote',
          style: Theme.of(context).textTheme.titleSmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 4),
        Text(
          'So nobody judges a battle by who is already winning.',
          style: Theme.of(context).textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
      ],
    );
    return compact
        ? content
        : Card(child: Padding(padding: const EdgeInsets.all(16), child: content));
  }

  Widget _scoreboard(BuildContext context, int p1, int p2) {
    final total = p1 + p2;
    // An even split at zero votes, so the bar starts neutral rather than
    // implying a lead nobody has.
    final p1Share = total == 0 ? 0.5 : p1 / total;
    final leaderIsP1 = p1 > p2;
    final tied = p1 == p2;

    final barH = compact ? 8.0 : 10.0;
    final content = Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _side(context, player1Name, p1, highlight: !tied && leaderIsP1),
            Text(
              tied ? 'TIED' : 'vs',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            _side(context, player2Name, p2,
                highlight: !tied && !leaderIsP1, alignEnd: true),
          ],
        ),
        SizedBox(height: compact ? 8 : 12),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          // At ZERO votes the bar is a single neutral track, not a
          // 50/50 gel split - a half-pink/half-purple bar reads as a
          // real tied result rather than "nothing has happened yet".
          child: total == 0
              ? Container(
                  height: barH,
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                )
              : Row(
                  children: [
                    // The two player gels, never the accent - see AppPalette.
                    Expanded(
                      flex: (p1Share * 1000).round().clamp(1, 999),
                      child: Container(height: barH, color: context.palette.gelA),
                    ),
                    Expanded(
                      flex: ((1 - p1Share) * 1000).round().clamp(1, 999),
                      child: Container(height: barH, color: context.palette.gelB),
                    ),
                  ],
                ),
        ),
        SizedBox(height: compact ? 6 : 10),
        Text(
          total == 0
              ? 'No votes yet'
              : '$total ${total == 1 ? 'person has' : 'people have'} judged this',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (closesAtMs != null) ...[
          const SizedBox(height: 2),
          Text(
            _closesIn(closesAtMs!),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    );

    // Compact drops the inner Card (its host card already frames it) and its
    // 16px padding; full-size keeps the standalone Card for the vote screen.
    return compact
        ? content
        : Card(child: Padding(padding: const EdgeInsets.all(16), child: content));
  }

  Widget _side(BuildContext context, String name, int votes,
      {required bool highlight, bool alignEnd = false}) {
    final numberStyle = compact
        ? Theme.of(context).textTheme.titleMedium
        : Theme.of(context).textTheme.headlineSmall;
    return Expanded(
      child: Column(
        crossAxisAlignment:
            alignEnd ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: highlight ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          Text(
            '$votes',
            style: numberStyle?.copyWith(
              fontWeight: highlight ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }

  String _closesIn(int closesAt) {
    final remaining = closesAt - DateTime.now().millisecondsSinceEpoch;
    if (remaining <= 0) return 'Voting has closed';
    final hours = remaining ~/ (1000 * 60 * 60);
    if (hours >= 1) return 'Voting closes in ${hours}h';
    return 'Voting closes in ${remaining ~/ (1000 * 60)}m';
  }
}
