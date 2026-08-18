import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import 'live_tally.dart';

/// The crowd's ballot, during the short window after a live battle ends.
///
/// THIS IS WHAT MAKES LIVE TOURNAMENTS WORTH THE TROUBLE. Judging
/// liquidity is the app's hardest problem everywhere else - a match closes
/// with a handful of ballots and vote confidence discounts the result
/// accordingly. Here the audience is already assembled and has just
/// watched the thing, so ninety seconds of a full room can carry more
/// ballots than a quiet day does. The verdict is part of the show rather
/// than something that arrives tomorrow.
///
/// The tally is deliberately hidden until you have voted - seeing who is
/// ahead before judging biases the judgement, which is the same rule the
/// ordinary vote screen follows.
class LiveVotePanel extends StatefulWidget {
  const LiveVotePanel({
    super.key,
    required this.matchId,
    required this.player1Id,
    required this.player2Id,
    required this.player1Name,
    required this.player2Name,
  });

  final String matchId;
  final String player1Id;
  final String player2Id;
  final String player1Name;
  final String player2Name;

  @override
  State<LiveVotePanel> createState() => _LiveVotePanelState();
}

class _LiveVotePanelState extends State<LiveVotePanel> {
  Timer? _ticker;
  bool _busy = false;
  bool _voted = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Drives the countdown. A live vote window is ninety seconds, so a
    // second-by-second clock is the difference between urgency and a
    // static label nobody reacts to.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _vote(String playerId) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await FirebaseFunctions.instance
          .httpsCallable('castVote')
          .call<Map<String, dynamic>>({
        'matchId': widget.matchId,
        'votedForPlayerId': playerId,
      });
      if (mounted) {
        setState(() {
          _busy = false;
          _voted = true;
        });
      }
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        // A missing vote session is the one failure worth naming
        // specifically, because the fix is a single tap on the Judge tab
        // rather than anything to do with this battle.
        _error = e.code == 'failed-precondition' &&
                (e.message ?? '').contains('session')
            ? 'Solve the quick check on the Judge tab first, then come back.'
            : e.message ?? 'Could not cast that vote.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('matches')
          .doc(widget.matchId)
          .snapshots(),
      builder: (context, snapshot) {
        final match = snapshot.data?.data();
        if (match == null) return const SizedBox.shrink();

        // Nothing to vote on until the battle is actually over.
        if (match['status'] != 'completed') return const SizedBox.shrink();

        final finalized = match['voteFinalized'] == true;
        final winnerId = match['winnerId'] as String?;
        if (finalized) return _result(context, winnerId);

        final endMs = _voteWindowEndMs(match);
        final left = endMs == null
            ? null
            : Duration(
                milliseconds: endMs - DateTime.now().millisecondsSinceEpoch);
        final closed = left != null && left.isNegative;

        if (closed) {
          _nudgeSettle();
          return _counting(context);
        }
        return _ballot(context, left);
      },
    );
  }

  /// Mirrors voteWindowStartMs + voteWindowMs on the server. A live match
  /// carries its own short window; anything else falls back to the day.
  int? _voteWindowEndMs(Map<String, dynamic> match) {
    final completed = match['completedAt'];
    if (completed is! Timestamp) return null;
    final raw = match['voteWindowMs'];
    final windowMs = raw is num && raw > 0
        ? raw.toInt()
        : 24 * 60 * 60 * 1000;
    return completed.millisecondsSinceEpoch + windowMs;
  }

  Widget _shell(BuildContext context, List<Widget> children) {
    return Container(
      width: double.infinity,
      color: Theme.of(context).colorScheme.surface,
      padding: const EdgeInsets.all(16),
      child: Column(mainAxisSize: MainAxisSize.min, children: children),
    );
  }

  Widget _ballot(BuildContext context, Duration? left) {
    final text = Theme.of(context).textTheme;
    if (_voted) {
      return _shell(context, [
        Text('Vote in. Watching the count.', style: text.titleSmall),
        const SizedBox(height: 10),
        LiveTally(
          matchId: widget.matchId,
          player1Name: widget.player1Name,
          player2Name: widget.player2Name,
        ),
      ]);
    }
    return _shell(context, [
      Text(
        left == null ? 'Who won?' : 'Who won? ${left.inSeconds}s left',
        style: text.titleMedium,
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(
            child: FilledButton(
              onPressed: _busy ? null : () => _vote(widget.player1Id),
              child: Text(widget.player1Name, overflow: TextOverflow.ellipsis),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: FilledButton(
              onPressed: _busy ? null : () => _vote(widget.player2Id),
              child: Text(widget.player2Name, overflow: TextOverflow.ellipsis),
            ),
          ),
        ],
      ),
      if (_error != null) ...[
        const SizedBox(height: 10),
        Text(_error!,
            textAlign: TextAlign.center,
            style: text.bodySmall
                ?.copyWith(color: Theme.of(context).colorScheme.error)),
      ],
    ]);
  }

  /// Voting has closed but the result has not landed yet. Says so, rather
  /// than showing a dead ballot or an empty space - the settle is
  /// client-nudged and server-verified, so this is a real few seconds.
  /// Asks the server to settle the moment the countdown reaches zero.
  ///
  /// The per-minute sweep is the reliable backstop and settles this
  /// regardless; this is purely so a crowd watching a countdown hit zero
  /// does not then wait up to another minute for the result they are
  /// watching for. The server re-checks the window itself, so asking
  /// early cannot rush a verdict.
  ///
  /// Asked once per panel. Retrying on a timer would have every spectator
  /// hammering the same callable for the same match.
  bool _nudged = false;
  Future<void> _nudgeSettle() async {
    if (_nudged) return;
    _nudged = true;
    try {
      await FirebaseFunctions.instance
          .httpsCallable('settleLiveMatch')
          .call<Map<String, dynamic>>({'matchId': widget.matchId});
    } catch (_) {
      // Silent by design: the per-minute sweep settles this anyway, so a
      // failed nudge costs a few seconds and must never put an error in
      // front of an audience.
    }
  }

  Widget _counting(BuildContext context) => _shell(context, [
        Text('Voting closed. Counting...',
            style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        const LinearProgressIndicator(),
      ]);

  Widget _result(BuildContext context, String? winnerId) {
    final text = Theme.of(context).textTheme;
    final name = winnerId == widget.player1Id
        ? widget.player1Name
        : winnerId == widget.player2Id
            ? widget.player2Name
            : null;
    return _shell(context, [
      Text(
        // A tie is a real outcome here, not a missing one - the tie rule
        // is no rating change rather than a coin flip, so saying "draw"
        // is the honest word.
        name == null ? 'Draw - nobody took it.' : '$name takes it.',
        style: text.titleMedium,
      ),
    ]);
  }
}
