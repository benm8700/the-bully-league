import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../core/services/belt_service.dart';
import '../../screens/profile/performer_profile_screen.dart';
import '../../theme/app_theme.dart';
import '../empty_state.dart';

/// The Prize tab of the tournament hub: what you're playing for.
///
/// Prizes are PRESTIGE for now (per the decision record) - The Belt, a
/// permanent Champion badge, and the all-time champions wall. Real/experiential
/// prizes layer on later. The reigning-champion spotlight reads stats/belt; the
/// champions board is a single-field query on the server-only tournamentWins
/// counter (no index, no backend).
class PrizeTab extends StatelessWidget {
  const PrizeTab({super.key});

  @override
  Widget build(BuildContext context) {
    final gold = context.palette.reward;
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final me = FirebaseAuth.instance.currentUser?.uid;

    final champions = FirebaseFirestore.instance
        .collection('users')
        .where('tournamentWins', isGreaterThan: 0)
        .orderBy('tournamentWins', descending: true)
        .limit(50);

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
      children: [
        // The reigning champion spotlight.
        StreamBuilder<BeltHolder>(
          stream: BeltService.watch(),
          builder: (context, snap) {
            final belt = snap.data;
            final hasHolder = belt != null && belt.hasHolder;
            return Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                gradient: const LinearGradient(
                  colors: [Color(0xFF3A2F14), Color(0xFF1A1508)],
                ),
                border: Border.all(color: gold.withValues(alpha: 0.6)),
              ),
              child: Column(
                children: [
                  const Text('🏆', style: TextStyle(fontSize: 40)),
                  const SizedBox(height: 6),
                  Text('THE BELT',
                      style: text.labelLarge?.copyWith(
                          color: gold,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 2)),
                  const SizedBox(height: 6),
                  if (hasHolder)
                    GestureDetector(
                      onTap: belt.holderUid == null
                          ? null
                          : () => PerformerProfileScreen.open(
                              context, belt.holderUid!,
                              username: belt.holderName),
                      child: Column(
                        children: [
                          Text(belt.holderName ?? 'Champion',
                              style: text.headlineSmall?.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w900)),
                          Text(
                            belt.defenseCount > 0
                                ? 'Reigning champion · defended ×${belt.defenseCount}'
                                : 'Reigning champion',
                            style: text.bodySmall?.copyWith(
                                color: Colors.white.withValues(alpha: 0.7)),
                          ),
                        ],
                      ),
                    )
                  else
                    Text(
                      'No champion yet — win a Main Stage and take the crown.',
                      textAlign: TextAlign.center,
                      style: text.bodyMedium
                          ?.copyWith(color: Colors.white.withValues(alpha: 0.8)),
                    ),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: 16),
        // What you're playing for.
        Text('What you win',
            style: text.titleMedium?.copyWith(
                fontWeight: FontWeight.w800, color: gold)),
        const SizedBox(height: 6),
        Text(
          'Win the Main Stage and you take The Belt — the one title you can lose '
          'the moment someone else wins. Every champion also earns a permanent '
          'Champion badge for their profile. Bigger, real prizes come later; for '
          'now the prize is the prestige, and the whole room watching you take '
          'it.',
          style: text.bodyMedium
              ?.copyWith(color: scheme.onSurfaceVariant, height: 1.4),
        ),
        const SizedBox(height: 18),
        // The all-time champions wall.
        Row(
          children: [
            Icon(Icons.military_tech, color: gold, size: 20),
            const SizedBox(width: 8),
            Text('Hall of champions',
                style: text.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800, color: gold)),
          ],
        ),
        const SizedBox(height: 8),
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: champions.snapshots(),
          builder: (context, snap) {
            if (snap.hasError) {
              return const SizedBox.shrink();
            }
            if (!snap.hasData) {
              return const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final docs = snap.data!.docs;
            if (docs.isEmpty) {
              return const EmptyState(
                icon: Icons.emoji_events_outlined,
                title: 'No champions crowned yet',
                message: 'The first Main Stage winner starts the wall.',
              );
            }
            return Column(
              children: docs.asMap().entries.map((entry) {
                final i = entry.key;
                final d = entry.value;
                final wins = (d.data()['tournamentWins'] as num?)?.toInt() ?? 0;
                final name = d.data()['username'] as String? ?? 'Roaster';
                final isSelf = d.id == me;
                return Material(
                  color: isSelf ? gold.withValues(alpha: 0.14) : Colors.transparent,
                  child: ListTile(
                    dense: true,
                    visualDensity: const VisualDensity(vertical: -3),
                    onTap: () => PerformerProfileScreen.open(context, d.id,
                        username: name),
                    leading: Text('${i + 1}',
                        style: TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 16,
                            color: i == 0
                                ? gold
                                : scheme.onSurfaceVariant)),
                    title: Text(isSelf ? '$name  (you)' : name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontWeight:
                                isSelf ? FontWeight.w800 : FontWeight.w600)),
                    trailing: Text('🏆 $wins',
                        style: TextStyle(
                            color: gold, fontWeight: FontWeight.w800)),
                  ),
                );
              }).toList(),
            );
          },
        ),
      ],
    );
  }
}
