import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import '../../widgets/empty_state.dart';
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
      setState(() => _error = 'Could not load matches to vote on: $e');
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
        title: const Text('Vote on a battle'),
        automaticallyImplyLeading: !widget.embedded,
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
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
          message: 'Every open battle has either been voted on by you already or '
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
