import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../widgets/live_tally.dart';
import '../../widgets/match_clip_player.dart';
import '../../widgets/turnstile_challenge.dart';
import '../moderation/report_screen.dart';

/// Community voting (Build Order step 5). CAPTCHA gate, 24h window,
/// one-vote-per-account and account-age vote-weight are all enforced
/// server-side in the castVote Cloud Function (functions/index.js) - this
/// screen never writes a ballot directly.
///
/// The running score is deliberately NOT shown until your ballot is in.
/// Seeing who is ahead before you judge biases the judgement, and it would
/// tell anyone rallying support exactly how many more votes they need.
/// Once you have voted there is nothing left to bias, so the scoreboard
/// opens up and stays live - that reveal is also the reward for voting.
/// The rule is enforced in firestore.rules, not here; this screen only
/// decides what to render.
class VoteScreen extends StatefulWidget {
  const VoteScreen({super.key, required this.matchId, this.videoUrl});

  final String matchId;

  /// The highlight clip to judge, when one has been published. Passed in
  /// from the queue so this screen doesn't refetch what the caller
  /// already knows; null renders an honest 'not available yet' state.
  final String? videoUrl;

  @override
  State<VoteScreen> createState() => _VoteScreenState();
}

class _VoteScreenState extends State<VoteScreen> {
  /// The vote button stays locked until the clip has actually played for
  /// a few seconds.
  ///
  /// WHAT THIS IS AND IS NOT. It is not a security boundary - a modified
  /// client skips it in a line, and `castVote` enforces a minimum interval
  /// between votes server-side for exactly that reason. It is a PRICE ON
  /// SPEED. The whole farming exploit is that a careless vote takes two
  /// seconds and an honest one takes thirty; this closes most of that gap
  /// and costs an honest judge nothing, because they were watching anyway.
  ///
  /// Deliberately short. The goal is not to make someone watch a whole
  /// battle before forming a view - people decide fast and that is fine -
  /// it is to stop a vote being cheaper than a glance.
  static const kWatchSecondsBeforeVote = 12;

  bool _watchedEnough = false;

  /// Per-round winner picks (round index -> playerId). The match goes to
  /// whoever won the most rounds.
  final Map<int, String> _picks = {};

  /// Optional: which round the judge found funniest - the signal behind the
  /// Funniest Rounds board, separate from who won each round and never
  /// required to submit.
  int? _funniestRound;
  String? _turnstileToken;
  bool _submitting = false;
  String? _errorMessage;

  /// Flipped locally the moment a vote lands, so the scoreboard appears
  /// immediately rather than waiting on the ballot document to round-trip.
  bool _justVoted = false;

  Future<void> _submitVote(int roundCount) async {
    if (_picks.length < roundCount || _turnstileToken == null) return;
    setState(() {
      _submitting = true;
      _errorMessage = null;
    });

    try {
      final callable = FirebaseFunctions.instance.httpsCallable('castVote');
      await callable.call({
        'matchId': widget.matchId,
        // Per-round winners keyed by round index (strings for the wire).
        'picks': _picks.map((k, v) => MapEntry(k.toString(), v)),
        // ignore: use_null_aware_elements
        if (_funniestRound != null) 'funniestRound': _funniestRound,
        'turnstileToken': _turnstileToken,
      });
      if (!mounted) return;
      setState(() => _justVoted = true);
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = 'Vote failed: ${e.message ?? e.code}');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// Optional "which round was funniest" selector - the signal behind the
  /// Funniest Rounds board. One tap, distinct from picking each round's
  /// winner, and never required to submit (tapping again clears it).
  Widget _funniestRow(BuildContext context, int roundCount) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(Icons.local_fire_department, color: scheme.primary, size: 18),
        const SizedBox(width: 6),
        Text('Best round?', style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(width: 10),
        for (int r = 0; r < roundCount; r++)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: GestureDetector(
              onTap: () => setState(
                  () => _funniestRound = _funniestRound == r ? null : r),
              child: Container(
                width: 32,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _funniestRound == r
                      ? scheme.primary
                      : scheme.onSurface.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text('${r + 1}',
                    style: TextStyle(
                      color: _funniestRound == r
                          ? scheme.onPrimary
                          : scheme.onSurfaceVariant,
                      fontWeight: FontWeight.bold,
                    )),
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final matchRef =
        FirebaseFirestore.instance.collection('matches').doc(widget.matchId);
    final myUid = FirebaseAuth.instance.currentUser?.uid;

    return Scaffold(
      appBar: AppBar(title: const Text('Judge this battle')),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: matchRef.snapshots(),
        builder: (context, matchSnap) {
          if (matchSnap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (!matchSnap.hasData || !matchSnap.data!.exists) {
            return const Center(child: Text('Match not found.'));
          }
          final match = matchSnap.data!.data()!;
          final player1Id = match['player1Id'] as String;
          final player2Id = match['player2Id'] as String;
          final isParticipant = myUid == player1Id || myUid == player2Id;
          final closesAtMs = _closesAtMs(match);
          final roundCount =
              (((match['settings'] as Map?)?['roundCount'] as num?)?.toInt() ?? 3)
                  .clamp(1, 12);

          return FutureBuilder<List<String>>(
            future: _usernames(player1Id, player2Id),
            builder: (context, nameSnap) {
              final names = nameSnap.data ?? const ['Player 1', 'Player 2'];
              return _body(
                context: context,
                myUid: myUid,
                player1Id: player1Id,
                player2Id: player2Id,
                player1Name: names[0],
                player2Name: names[1],
                isParticipant: isParticipant,
                closesAtMs: closesAtMs,
                roundCount: roundCount,
              );
            },
          );
        },
      ),
    );
  }

  Widget _body({
    required BuildContext context,
    required String? myUid,
    required String player1Id,
    required String player2Id,
    required String player1Name,
    required String player2Name,
    required bool isParticipant,
    required int? closesAtMs,
    required int roundCount,
  }) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      // Your own ballot, which is the only one any client may read. Its
      // existence is what decides whether the scoreboard is unlocked.
      stream: myUid == null
          ? const Stream.empty()
          : FirebaseFirestore.instance
              .collection('votes')
              .doc(widget.matchId)
              .collection('ballots')
              .doc(myUid)
              .snapshots(),
      builder: (context, ballotSnap) {
        final alreadyVoted = _justVoted || (ballotSnap.data?.exists ?? false);
        final canVote = !isParticipant && !alreadyVoted;

        return SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The clip comes first, always. Judging without watching is
              // not judging, and the vote-confidence weighting assumes a
              // vote carries information - so the match has to be
              // watchable before anyone is asked to pick a winner.
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: MatchClipPlayer(
                  videoUrl: widget.videoUrl,
                  watchSecondsRequired: kWatchSecondsBeforeVote,
                  onWatchedEnough: () {
                    if (mounted) setState(() => _watchedEnough = true);
                  },
                ),
              ),
              const SizedBox(height: 20),
              if (canVote) ...[
                Text('Who won each round?',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 6),
                Text(
                  'The match goes to whoever wins the most rounds.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 16),
                for (int r = 0; r < roundCount; r++) ...[
                  _RoundPicker(
                    round: r,
                    player1Id: player1Id,
                    player1Name: player1Name,
                    player2Id: player2Id,
                    player2Name: player2Name,
                    gelA: context.palette.gelA,
                    gelB: context.palette.gelB,
                    selected: _picks[r],
                    onPick: (id) => setState(() => _picks[r] = id),
                  ),
                  const SizedBox(height: 10),
                ],
                const SizedBox(height: 4),
                _funniestRow(context, roundCount),
                const SizedBox(height: 10),
                TurnstileChallenge(
                    onToken: (token) => setState(() => _turnstileToken = token)),
                const SizedBox(height: 16),
                if (!_watchedEnough) ...[
                  Text(
                    'Watch a bit of it first.',
                    style: Theme.of(context).textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                ] else if (_picks.length < roundCount) ...[
                  Text(
                    'Pick a winner for every round.',
                    style: Theme.of(context).textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                ],
                FilledButton(
                  onPressed: (_picks.length >= roundCount &&
                          _turnstileToken != null &&
                          _watchedEnough &&
                          !_submitting)
                      ? () => _submitVote(roundCount)
                      : null,
                  child: _submitting
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Cast Vote'),
                ),
                if (_errorMessage != null) ...[
                  const SizedBox(height: 12),
                  Text(_errorMessage!, textAlign: TextAlign.center),
                ],
                const SizedBox(height: 20),
                Text(
                  'The score is hidden until you vote, so nobody judges a '
                  'battle by who is already winning.',
                  style: Theme.of(context).textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
              ] else ...[
                Text(
                  isParticipant
                      ? 'Your battle, live'
                      : 'Judged. Here is how it stands.',
                  style: Theme.of(context).textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
                if (isParticipant) ...[
                  const SizedBox(height: 6),
                  Text(
                    'You can\'t judge your own battle - the crowd decides '
                    'this one.',
                    style: Theme.of(context).textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                ],
                const SizedBox(height: 16),
                LiveTally(
                  matchId: widget.matchId,
                  player1Name: player1Name,
                  player2Name: player2Name,
                  closesAtMs: closesAtMs,
                ),
              ],
              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 8),
              // Reporting stays available even for match participants
              // (unlike voting) - CLAUDE.md's report categories are about
              // things outside the roast format itself, which a participant
              // is in the best position to have witnessed.
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton.icon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ReportScreen(
                            reportedUserId: player1Id, matchId: widget.matchId),
                      ),
                    ),
                    icon: const Icon(Icons.flag_outlined, size: 18),
                    label: Text('Report $player1Name',
                        overflow: TextOverflow.ellipsis),
                  ),
                  TextButton.icon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ReportScreen(
                            reportedUserId: player2Id, matchId: widget.matchId),
                      ),
                    ),
                    icon: const Icon(Icons.flag_outlined, size: 18),
                    label: Text('Report $player2Name',
                        overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  /// The 24h vote window runs from match COMPLETION, falling back to
  /// creation for a match that never completed - mirroring
  /// voteWindowStartMs in functions/matchFinalization.js exactly, so the
  /// countdown shown here is the one actually enforced by castVote.
  int? _closesAtMs(Map<String, dynamic> match) {
    final start = match['completedAt'] ?? match['createdAt'];
    if (start is! Timestamp) return null;
    return start.millisecondsSinceEpoch + 24 * 60 * 60 * 1000;
  }

  Future<List<String>> _usernames(String player1Id, String player2Id) async {
    final db = FirebaseFirestore.instance;
    final snaps = await Future.wait([
      db.collection('users').doc(player1Id).get(),
      db.collection('users').doc(player2Id).get(),
    ]);
    return [
      (snaps[0].data()?['username'] as String?) ?? 'Player 1',
      (snaps[1].data()?['username'] as String?) ?? 'Player 2',
    ];
  }
}

/// One round's winner picker: "Round N" and the two players as choices. The
/// gel colours are the SAME ones the players wear on the scoreboard and in
/// the burned-in clip captions, so "who is who" reads consistently.
class _RoundPicker extends StatelessWidget {
  const _RoundPicker({
    required this.round,
    required this.player1Id,
    required this.player1Name,
    required this.player2Id,
    required this.player2Name,
    required this.gelA,
    required this.gelB,
    required this.selected,
    required this.onPick,
  });

  final int round;
  final String player1Id;
  final String player1Name;
  final String player2Id;
  final String player2Name;
  final Color gelA;
  final Color gelB;
  final String? selected;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 68,
          child: Text('Round ${round + 1}',
              style: Theme.of(context).textTheme.labelMedium),
        ),
        Expanded(child: _choice(context, player1Id, player1Name, gelA)),
        const SizedBox(width: 8),
        Expanded(child: _choice(context, player2Id, player2Name, gelB)),
      ],
    );
  }

  Widget _choice(BuildContext context, String id, String name, Color color) {
    final scheme = Theme.of(context).colorScheme;
    final isSel = selected == id;
    return OutlinedButton(
      onPressed: () => onPick(id),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        backgroundColor: isSel ? color.withValues(alpha: 0.18) : null,
        side: BorderSide(
          color: isSel ? color : scheme.outlineVariant,
          width: isSel ? 2 : 1,
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(name,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: scheme.onSurface)),
          ),
          if (isSel) ...[
            const SizedBox(width: 6),
            Icon(Icons.check_circle, color: color, size: 16),
          ],
        ],
      ),
    );
  }
}
