import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import '../../widgets/admin_only.dart';
import '../../widgets/empty_state.dart';
import 'tournament_detail_screen.dart';

/// Browse tournaments (Build Order step 8). Real tournament creation is
/// meant to happen via the Firebase console (same "admin uses the console"
/// pattern as profile approval/report review - see CLAUDE.md's Admin/
/// moderation tooling notes), so the "Create Test Tournament" button here
/// is dev/test-only, calling the debugCreateTournament Cloud Function
/// purely so this screen can be exercised end to end without console
/// access - see CLAUDE.md's step 8 status note.
class TournamentListScreen extends StatefulWidget {
  const TournamentListScreen({super.key});

  @override
  State<TournamentListScreen> createState() => _TournamentListScreenState();
}

class _TournamentListScreenState extends State<TournamentListScreen> {
  bool _creating = false;

  Future<void> _createTestTournament() async {
    setState(() => _creating = true);
    try {
      final callable = FirebaseFunctions.instance.httpsCallable('debugCreateTournament');
      await callable.call({
        'name': 'Test Cup ${DateTime.now().millisecondsSinceEpoch}',
        'minEntrants': 4,
      });
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to create tournament: ${e.message ?? e.code}')),
        );
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final query = FirebaseFirestore.instance
        .collection('tournaments')
        .orderBy('createdAt', descending: true);

    return Scaffold(
      appBar: AppBar(title: const Text('Tournaments')),
      // Admin tooling. Real tournaments are created in the Firebase
      // console (CLAUDE.md's Admin/moderation tooling decision); this
      // exists because no console access was available while testing. An
      // entrant must not see it - the server refuses them anyway, and a
      // button that answers "Admin only" reads as a broken app.
      floatingActionButton: AdminOnly(
        child: FloatingActionButton.extended(
          onPressed: _creating ? null : _createTestTournament,
          label: _creating
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Create Test Tournament'),
          icon: _creating ? null : const Icon(Icons.add),
        ),
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: query.snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('Failed to load tournaments: ${snapshot.error}'));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final docs = snapshot.data!.docs;
          if (docs.isEmpty) {
            // The nightly tournament is auto-created shortly before the
            // evening window, so off-hours there is genuinely nothing here.
            // Point people at the Home countdown (which carries the real,
            // config-driven time) rather than hardcoding a time/name that
            // could drift from config.
            return const EmptyState(
              icon: Icons.emoji_events_outlined,
              title: 'No tournament running right now',
              message: 'The nightly tournament runs during the evening window. '
                  'Check the countdown on Home - and tap "I\'m in tonight" so '
                  'you do not miss it.',
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: docs.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final doc = docs[index];
              final data = doc.data();
              final name = data['name'] as String? ?? 'Unnamed tournament';
              final status = data['status'] as String? ?? 'open';
              final prizeType = data['prizeType'] as String? ?? 'points';
              return ListTile(
                title: Text(name),
                subtitle: Text('$status · $prizeType prize'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => TournamentDetailScreen(tournamentId: doc.id)),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
