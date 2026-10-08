import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../widgets/empty_state.dart';
import '../tournament/live_viewer_screen.dart';
import 'vote_screen.dart';

/// The matches most in need of a vote, fewest votes first.
///
/// This is the liquidity half of the voting guardrails. Rating is now
/// weighted by how many people judged a match (see functions/rating.js),
/// which is only fair if votes are actually gettable - otherwise thin
/// results stop counting and the ladder quietly stops moving.
///
/// Ordered by NEED rather than recency on purpose. A recency feed sends
/// everyone to the same newest match while older ones close unjudged;
/// ordering by need means one ballot on a zero-vote match does far more
/// for the ladder than the eleventh ballot on a popular one.
///
/// TOURNAMENT BATTLES ARE SURFACED FIRST (developer's call, 2026-10-07).
/// A live gauntlet battle is judged on the live stream, not a clip, so it
/// can't go through the clip-based queue below - but it is exactly the
/// judging the ladder most needs (a 0-vote climb battle ties and loops).
/// So the live tournament battles sit at the top, clearly labelled, and
/// link straight into the live viewer to watch and vote.
class VoteQueueScreen extends StatefulWidget {
  const VoteQueueScreen({super.key, this.embedded = false});

  /// True when shown as a bottom-nav tab, where a back arrow would be
  /// wrong - there is nothing behind it.
  final bool embedded;

  @override
  State<VoteQueueScreen> createState() => _VoteQueueScreenState();
}

class _VoteQueueScreenState extends State<VoteQueueScreen> {
  List<Map<String, dynamic>>? _matches;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _matches = null;
      _error = null;
    });
    try {
      final result = await FirebaseFunctions.instance
          .httpsCallable('getMatchesNeedingVotes')
          .call<Map<String, dynamic>>({'limit': 5});
      final list = (result.data['matches'] as List?) ?? const [];
      if (!mounted) return;
      setState(() => _matches =
          list.map((e) => (e as Map).cast<String, dynamic>()).toList());
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not load matches to judge: $e');
    }
  }

  String _timeLeft(int msRemaining) {
    final hours = msRemaining ~/ (1000 * 60 * 60);
    if (hours >= 1) return '${hours}h left to vote';
    final minutes = msRemaining ~/ (1000 * 60);
    return '${minutes}m left to vote';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Judge a battle'),
        automaticallyImplyLeading: !widget.embedded,
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Tournament battles first, labelled, live-stream judging.
            const _LiveTournamentSection(),
            // Then the ordinary clip-based queue.
            ..._queueSection(),
          ],
        ),
      ),
    );
  }

  List<Widget> _queueSection() {
    final text = Theme.of(context).textTheme;
    if (_error != null) {
      return [
        const SizedBox(height: 8),
        Text(_error!, textAlign: TextAlign.center),
      ];
    }
    if (_matches == null) {
      return const [
        SizedBox(height: 40),
        Center(child: CircularProgressIndicator()),
      ];
    }
    if (_matches!.isEmpty) {
      return const [
        SizedBox(height: 8),
        EmptyState(
          icon: Icons.how_to_vote_outlined,
          title: 'Nothing in the queue right now',
          message: 'Every open battle has either been judged by you already or '
              'is one of your own. Any live tournament battles show up at the '
              'top the moment they start.',
        ),
      ];
    }

    return [
      Padding(
        padding: const EdgeInsets.only(bottom: 6, top: 4),
        child: Text(
          'These need votes most. Your call decides how much they count.',
          style: text.bodySmall,
        ),
      ),
      for (final match in _matches!) ...[
        _clipQueueCard(match),
        const SizedBox(height: 10),
      ],
    ];
  }

  Widget _clipQueueCard(Map<String, dynamic> match) {
    final votes = (match['voteCount'] as num?)?.toInt() ?? 0;
    return Card(
      child: ListTile(
        title: Text(
          '${match['player1Username']} vs ${match['player2Username']}',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          '${votes == 0 ? 'No votes yet' : '$votes ${votes == 1 ? 'vote' : 'votes'}'}'
          ' · ${_timeLeft((match['msRemaining'] as num?)?.toInt() ?? 0)}',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () async {
          await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => VoteScreen(
                matchId: match['matchId'] as String,
                videoUrl: match['videoUrl'] as String?,
              ),
            ),
          );
          // Refresh on return so a match just judged drops off the
          // list rather than inviting a second, refused attempt.
          if (mounted) _load();
        },
      ),
    );
  }
}

/// The live tournament battles happening across the app right now, surfaced
/// at the top of the Judge tab so anyone - not just a gauntlet entrant - can
/// find them and vote. Judged on the live stream via the viewer, which is why
/// they don't flow through the clip queue below.
///
/// Reads `tournaments` where status == in_progress (a single-field query, no
/// composite index) and pulls the live battles out of each climb's
/// `climb.climbers`. Renders nothing when there are none.
class _LiveTournamentSection extends StatelessWidget {
  const _LiveTournamentSection();

  @override
  Widget build(BuildContext context) {
    final myUid = FirebaseAuth.instance.currentUser?.uid;
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('tournaments')
          .where('status', isEqualTo: 'in_progress')
          .snapshots(),
      builder: (context, snapshot) {
        final battles = <_LiveBattle>[];
        for (final doc in snapshot.data?.docs ?? const []) {
          final t = doc.data();
          if (t['format'] != 'climb') continue; // live format tonight
          final name = t['name'] as String? ?? 'Daily Gauntlet';
          final climbers =
              ((t['climb'] as Map<String, dynamic>?)?['climbers'] as List?) ??
                  const [];
          final seen = <String>{};
          for (final raw in climbers) {
            final c = raw as Map;
            if (c['status'] != 'in_match') continue;
            if (c['uid'] == myUid) continue; // can't judge your own
            final m = c['currentMatchId'] as String?;
            if (m == null || !seen.add(m)) continue;
            battles.add(_LiveBattle(
              matchId: m,
              winTier: (c['wins'] as num?)?.toInt() ?? 0,
              tournamentName: name,
            ));
          }
        }
        if (battles.isEmpty) return const SizedBox.shrink();
        battles.sort((a, b) => b.winTier.compareTo(a.winTier));
        final scheme = Theme.of(context).colorScheme;
        final text = Theme.of(context).textTheme;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.sensors, size: 18, color: context.palette.live),
                const SizedBox(width: 6),
                Text('Tournament - live now',
                    style:
                        text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              ],
            ),
            const SizedBox(height: 2),
            Text('Judge these first - a live battle with no votes ends in a tie.',
                style: text.bodySmall),
            const SizedBox(height: 10),
            for (final b in battles) ...[
              Card(
                color: scheme.surfaceContainerHigh,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(
                      color: context.palette.live.withValues(alpha: 0.5)),
                ),
                child: ListTile(
                  leading: Icon(Icons.sensors, color: context.palette.live),
                  title: Text(
                    b.winTier == 0
                        ? 'Opening battle'
                        : '${b.winTier}-win battle',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text('${b.tournamentName} · watch & vote live'),
                  trailing: _LiveTag(color: context.palette.live),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => LiveViewerScreen(matchId: b.matchId),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
            ],
            const Divider(height: 24),
          ],
        );
      },
    );
  }
}

class _LiveBattle {
  const _LiveBattle({
    required this.matchId,
    required this.winTier,
    required this.tournamentName,
  });
  final String matchId;
  final int winTier;
  final String tournamentName;
}

class _LiveTag extends StatelessWidget {
  const _LiveTag({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text('LIVE',
          style: TextStyle(
              color: color, fontWeight: FontWeight.w800, fontSize: 11)),
    );
  }
}
