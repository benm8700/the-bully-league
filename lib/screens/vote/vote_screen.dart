import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../widgets/live_tally.dart';
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
  const VoteScreen({super.key, required this.matchId});

  final String matchId;

  @override
  State<VoteScreen> createState() => _VoteScreenState();
}

class _VoteScreenState extends State<VoteScreen> {
  String? _selectedPlayerId;
  String? _turnstileToken;
  bool _submitting = false;
  String? _errorMessage;

  /// Flipped locally the moment a vote lands, so the scoreboard appears
  /// immediately rather than waiting on the ballot document to round-trip.
  bool _justVoted = false;

  Future<void> _submitVote() async {
    if (_selectedPlayerId == null || _turnstileToken == null) return;
    setState(() {
      _submitting = true;
      _errorMessage = null;
    });

    try {
      final callable = FirebaseFunctions.instance.httpsCallable('castVote');
      await callable.call({
        'matchId': widget.matchId,
        'votedForPlayerId': _selectedPlayerId,
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
              if (canVote) ...[
                Text('Who won this roast battle?',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 16),
                _PlayerChoice(
                  label: player1Name,
                  selected: _selectedPlayerId == player1Id,
                  onTap: () => setState(() => _selectedPlayerId = player1Id),
                ),
                const SizedBox(height: 8),
                _PlayerChoice(
                  label: player2Name,
                  selected: _selectedPlayerId == player2Id,
                  onTap: () => setState(() => _selectedPlayerId = player2Id),
                ),
                const SizedBox(height: 16),
                TurnstileChallenge(
                    onToken: (token) => setState(() => _turnstileToken = token)),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: (_selectedPlayerId != null &&
                          _turnstileToken != null &&
                          !_submitting)
                      ? _submitVote
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

  /// The 24h vote window is measured from when the match document was
  /// created, matching finalizeMatch's own arithmetic (functions/
  /// matchFinalization.js) so the countdown shown here is the one actually
  /// enforced.
  int? _closesAtMs(Map<String, dynamic> match) {
    final createdAt = match['createdAt'];
    if (createdAt is! Timestamp) return null;
    return createdAt.millisecondsSinceEpoch + 24 * 60 * 60 * 1000;
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

class _PlayerChoice extends StatelessWidget {
  const _PlayerChoice(
      {required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        backgroundColor:
            selected ? Theme.of(context).colorScheme.primaryContainer : null,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(label, overflow: TextOverflow.ellipsis),
      ),
    );
  }
}
