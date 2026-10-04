import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

/// The "defend your throne" banner - the drama half of the GOAT title fight.
/// Shown ONLY to the two players a throne contest involves (the vulnerable GOAT
/// and the challenger closing on their spot), driven by stats/goatThrone, which
/// the watchGoatThrone job keeps current. Renders nothing for everyone else and
/// nothing when no throne is under threat, so it never clutters Home.
class GoatThroneBanner extends StatelessWidget {
  const GoatThroneBanner({super.key});

  static final DocumentReference<Map<String, dynamic>> _doc =
      FirebaseFirestore.instance.collection('stats').doc('goatThrone');

  // Crimson urgency, distinct from the gold belt banner - this is a WARNING,
  // not an honour.
  static const _crimson = Color(0xFFFF3B47);

  @override
  Widget build(BuildContext context) {
    final me = FirebaseAuth.instance.currentUser?.uid;
    if (me == null) return const SizedBox.shrink();
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _doc.snapshots(),
      builder: (context, snap) {
        final d = snap.data?.data();
        if (d == null || d['underThreat'] != true) {
          return const SizedBox.shrink();
        }
        final isDefender = d['goatUid'] == me;
        final isChallenger = d['challengerUid'] == me;
        if (!isDefender && !isChallenger) return const SizedBox.shrink();

        final title = isDefender
            ? 'Your throne is under threat'
            : 'A GOAT throne is in reach';
        final body = isDefender
            ? '${d['challengerName'] ?? 'A challenger'} is closing in. '
                'Defend it in the Daily Gauntlet.'
            : "You're closing in on ${d['goatName'] ?? 'a GOAT'}. "
                'Win the Daily Gauntlet to take it.';

        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              gradient: const LinearGradient(
                colors: [Color(0xFF3A0F12), Color(0xFF1C0A0C)],
              ),
              border: Border.all(color: _crimson.withValues(alpha: 0.55)),
            ),
            child: Row(
              children: [
                const Text('👑', style: TextStyle(fontSize: 22)),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: _crimson,
                          fontSize: 13,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.3,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        body,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.85),
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                          height: 1.25,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
