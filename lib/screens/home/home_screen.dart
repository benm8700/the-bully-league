import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/services/auth_service.dart';
import '../../core/services/push_notification_service.dart';
import '../leaderboard/leaderboard_screen.dart';
import '../match/pre_match_screen.dart';
import '../match/recording_consent_screen.dart';
import '../profile/profile_screen.dart';
import '../support/support_screen.dart';
import '../tournament/tournament_list_screen.dart';
import '../vote/finalize_test_screen.dart';
import '../vote/vote_entry_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final authService = context.read<AuthService>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('The Bully League'),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            tooltip: 'Support & Feedback',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SupportScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Sign out',
            onPressed: () => _signOut(context, authService),
          ),
        ],
      ),
      // Listens rather than reading currentUser once: right after sign-up,
      // the account is created (and this screen shown) before the
      // displayName update lands, so this needs to pick up that follow-up
      // update once it arrives instead of freezing on the first snapshot.
      body: StreamBuilder<User?>(
        stream: authService.authStateChanges(),
        initialData: authService.currentUser,
        builder: (context, snapshot) {
          final username = snapshot.data?.displayName ?? 'Roaster';
          final uid = snapshot.data?.uid;
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'Welcome, $username',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 12),
                if (uid != null) _RankBadge(uid: uid),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: () => _startMatch(context, 'ranked'),
                  child: const Text('Find Ranked Match'),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () => _startMatch(context, 'exhibition'),
                  child: const Text('Find Exhibition Match'),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const VoteEntryScreen()),
                  ),
                  child: const Text('Vote (test)'),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const FinalizeTestScreen()),
                  ),
                  child: const Text('Finalize Match (test)'),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ProfileScreen()),
                  ),
                  child: const Text('Your Profile'),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const LeaderboardScreen()),
                  ),
                  child: const Text('Leaderboard'),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const TournamentListScreen()),
                  ),
                  child: const Text('Tournaments'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Drops this device's push token before signing out, so the next person
  /// to sign in here doesn't receive the previous account's match alerts.
  /// Best-effort: a failure to clean up the token must not trap someone in
  /// an account they're trying to leave, so sign-out proceeds regardless.
  Future<void> _signOut(BuildContext context, AuthService authService) async {
    final push = context.read<PushNotificationService>();
    try {
      await push.unregister();
    } catch (_) {
      // Intentionally ignored - see above.
    }
    await authService.signOut();
  }

  /// Recording consent -> camera/mic check -> matchmaking queue -> match.
  ///
  /// Mode is chosen here and carried all the way through, because each
  /// mode has its own matchmaking queue - an exhibition player is never
  /// paired into a match that moves someone's rating. Note that the
  /// "play a few exhibition matches before ranked unlocks" gate from
  /// CLAUDE.md's Modes decision is NOT enforced yet: there's no
  /// exhibitionMatchesPlayed counter to gate on.
  Future<void> _startMatch(BuildContext context, String mode) async {
    final consented = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const RecordingConsentScreen()),
    );
    if (consented != true || !context.mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => PreMatchScreen(mode: mode)),
    );
  }
}

/// Shows rank title + raw rating + win/loss record. Real "Laugh Meter"
/// visual gauge (CLAUDE.md's Display decision) isn't designed yet - this is
/// the plain "detailed stats view" fallback CLAUDE.md explicitly allows.
class _RankBadge extends StatelessWidget {
  const _RankBadge({required this.uid});

  final String uid;

  @override
  Widget build(BuildContext context) {
    final userRef = FirebaseFirestore.instance.collection('users').doc(uid);
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: userRef.snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData || !snapshot.data!.exists) {
          return const SizedBox.shrink();
        }
        final data = snapshot.data!.data()!;
        final rankTitle = data['rankTitle'] as String? ?? 'Average Joe';
        final rating = data['rating'] as num? ?? 1200;
        final wins = data['wins'] as num? ?? 0;
        final losses = data['losses'] as num? ?? 0;
        return Column(
          children: [
            Text(rankTitle, style: Theme.of(context).textTheme.titleLarge),
            Text('Rating: $rating', style: Theme.of(context).textTheme.bodyMedium),
            Text('$wins wins, $losses losses', style: Theme.of(context).textTheme.bodySmall),
          ],
        );
      },
    );
  }
}
