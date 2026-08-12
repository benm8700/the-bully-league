import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../widgets/turnstile_challenge.dart';

/// Community voting (Build Order step 5). No discovery feed exists yet
/// (CLAUDE.md's Discovery/feed section is a separate, larger feature) - this
/// screen is reached by manually entering a matchId (see VoteEntryScreen),
/// which is enough to prove the voting mechanics: CAPTCHA gate, 24h window,
/// one-vote-per-account, and account-age vote-weight are all enforced
/// server-side in the castVote Cloud Function (functions/index.js) - this
/// screen never writes a ballot directly.
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
  String? _resultMessage;

  Future<void> _submitVote() async {
    if (_selectedPlayerId == null || _turnstileToken == null) return;
    setState(() {
      _submitting = true;
      _resultMessage = null;
    });

    try {
      final callable = FirebaseFunctions.instance.httpsCallable('castVote');
      final result = await callable.call({
        'matchId': widget.matchId,
        'votedForPlayerId': _selectedPlayerId,
        'turnstileToken': _turnstileToken,
      });
      if (!mounted) return;
      final weight = result.data['weight'];
      setState(() => _resultMessage = 'Vote cast! (weight: $weight)');
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() => _resultMessage = 'Vote failed: ${e.message ?? e.code}');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final matchRef = FirebaseFirestore.instance.collection('matches').doc(widget.matchId);
    final myUid = FirebaseAuth.instance.currentUser?.uid;

    return Scaffold(
      appBar: AppBar(title: const Text('Vote')),
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

          return SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Who won this roast battle?', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 16),
                if (isParticipant)
                  const Text(
                    'You were a participant in this match and can\'t vote on it.',
                    style: TextStyle(color: Colors.red),
                  )
                else ...[
                  _PlayerChoice(
                    label: 'Player 1 ($player1Id)',
                    selected: _selectedPlayerId == player1Id,
                    onTap: () => setState(() => _selectedPlayerId = player1Id),
                  ),
                  const SizedBox(height: 8),
                  _PlayerChoice(
                    label: 'Player 2 ($player2Id)',
                    selected: _selectedPlayerId == player2Id,
                    onTap: () => setState(() => _selectedPlayerId = player2Id),
                  ),
                  const SizedBox(height: 16),
                  TurnstileChallenge(onToken: (token) => setState(() => _turnstileToken = token)),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: (_selectedPlayerId != null && _turnstileToken != null && !_submitting)
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
                  if (_resultMessage != null) ...[
                    const SizedBox(height: 12),
                    Text(_resultMessage!, textAlign: TextAlign.center),
                  ],
                ],
                const SizedBox(height: 24),
                const Divider(),
                const SizedBox(height: 8),
                Text('Live tally', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                _TallyView(matchId: widget.matchId, player1Id: player1Id, player2Id: player2Id),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _PlayerChoice extends StatelessWidget {
  const _PlayerChoice({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        backgroundColor: selected ? Theme.of(context).colorScheme.primaryContainer : null,
      ),
      child: Align(alignment: Alignment.centerLeft, child: Text(label, overflow: TextOverflow.ellipsis)),
    );
  }
}

class _TallyView extends StatelessWidget {
  const _TallyView({required this.matchId, required this.player1Id, required this.player2Id});

  final String matchId;
  final String player1Id;
  final String player2Id;

  @override
  Widget build(BuildContext context) {
    final ballotsRef =
        FirebaseFirestore.instance.collection('votes').doc(matchId).collection('ballots');

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: ballotsRef.snapshots(),
      builder: (context, snap) {
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());

        double player1Weight = 0;
        double player2Weight = 0;
        for (final doc in snap.data!.docs) {
          final data = doc.data();
          final weight = (data['weight'] as num?)?.toDouble() ?? 1.0;
          if (data['votedForPlayerId'] == player1Id) player1Weight += weight;
          if (data['votedForPlayerId'] == player2Id) player2Weight += weight;
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Player 1: ${player1Weight.toStringAsFixed(1)}'),
            Text('Player 2: ${player2Weight.toStringAsFixed(1)}'),
            const SizedBox(height: 8),
            Text('${snap.data!.docs.length} ballot(s) cast', style: Theme.of(context).textTheme.bodySmall),
          ],
        );
      },
    );
  }
}
