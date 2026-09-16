import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../core/badges/badges.dart';
import 'badge_art.dart';

/// Celebrates a newly-earned badge the next time the app is opened, and keeps
/// the sticky earned set on the user document up to date.
///
/// Badges are pure recognition (no reward), so this is plain client state - no
/// Cloud Function. The user doc's `badges.earned` is the sticky record (badges
/// are earned AND KEPT); `badges.initialized` marks that the first backfill has
/// run so pre-existing achievements do not all pop at once.
class BadgePopup {
  static Future<void> maybeShow(BuildContext context) async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return;
      final ref = FirebaseFirestore.instance.collection('users').doc(uid);
      final snap = await ref.get();
      if (!snap.exists) return;
      final data = snap.data();

      final qualifying = qualifyingBadgeIds(BadgeStats.fromUser(data));
      final badges = (data?['badges'] as Map?)?.cast<String, dynamic>();
      final stored = <String>{
        ...?(badges?['earned'] as List?)?.whereType<String>(),
      };
      final initialized = badges?['initialized'] == true;

      // First run: silently record everything already earned (backfill), so a
      // veteran account is not buried in pop-ups for past milestones.
      if (!initialized) {
        await ref.set(
          {'badges': {'earned': qualifying.toList(), 'initialized': true}},
          SetOptions(merge: true),
        );
        return;
      }

      final newly = qualifying.difference(stored);
      if (newly.isEmpty) return;

      // Grow the sticky set BEFORE celebrating, so a dismissed dialog (or a
      // killed app) never re-fires for the same badge.
      await ref.set(
        {'badges': {'earned': {...stored, ...qualifying}.toList()}},
        SetOptions(merge: true),
      );
      if (!context.mounted) return;

      final defs = newly.map(badgeById).whereType<BadgeDef>().toList()
        ..sort((a, b) => b.prestige.compareTo(a.prestige));
      if (defs.isEmpty) return;
      final top = defs.first;
      final extra = defs.length - 1;

      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          icon: BadgeArt(def: top, earned: true, size: 68),
          title: const Text('Badge earned', textAlign: TextAlign.center),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                top.title,
                textAlign: TextAlign.center,
                style: Theme.of(dialogContext).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: const Color(0xFFF4C838),
                    ),
              ),
              const SizedBox(height: 4),
              Text(top.earnedDesc, textAlign: TextAlign.center),
              if (extra > 0) ...[
                const SizedBox(height: 8),
                Text(
                  '+$extra more unlocked',
                  textAlign: TextAlign.center,
                  style: Theme.of(dialogContext).textTheme.bodySmall,
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Nice'),
            ),
          ],
        ),
      );
    } catch (_) {
      // A celebration must never break a session.
    }
  }
}
