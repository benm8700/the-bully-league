import 'package:flutter/material.dart';

import 'vote_screen.dart';

/// Minimal stand-in for the Discovery/feed (CLAUDE.md) that doesn't exist
/// yet - lets a tester paste a matchId (shown on MatchScreen's verdict
/// screen) to reach VoteScreen directly, proving the voting mechanics work
/// without building the full browsable feed.
class VoteEntryScreen extends StatefulWidget {
  const VoteEntryScreen({super.key});

  @override
  State<VoteEntryScreen> createState() => _VoteEntryScreenState();
}

class _VoteEntryScreenState extends State<VoteEntryScreen> {
  final _matchIdController = TextEditingController();

  @override
  void dispose() {
    _matchIdController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Vote (test)')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'No discovery feed yet - paste a match ID (shown on the verdict '
              'screen after a test match) to vote on it.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _matchIdController,
              decoration: const InputDecoration(labelText: 'Match ID'),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () {
                final matchId = _matchIdController.text.trim();
                if (matchId.isEmpty) return;
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => VoteScreen(matchId: matchId)),
                );
              },
              child: const Text('Go'),
            ),
          ],
        ),
      ),
    );
  }
}
