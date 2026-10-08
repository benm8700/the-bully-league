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
        builder: (dialogContext) {
          const gold = Color(0xFFF4C838);
          return AlertDialog(
            // A gold-outlined, dark "trophy case" look so an earned badge
            // reads as a reward, not a system alert (developer's call,
            // 2026-10-07).
            backgroundColor: const Color(0xFF17131B),
            surfaceTintColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(22),
              side: const BorderSide(color: gold, width: 1.6),
            ),
            icon: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: gold.withValues(alpha: 0.45),
                    blurRadius: 34,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: BadgeArt(def: top, earned: true, size: 80),
            ),
            title: const Text(
              'BADGE EARNED',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: gold,
                fontWeight: FontWeight.w800,
                letterSpacing: 3,
                fontSize: 13,
              ),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  top.title,
                  textAlign: TextAlign.center,
                  style:
                      Theme.of(dialogContext).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w900,
                            color: Colors.white,
                          ),
                ),
                const SizedBox(height: 6),
                Text(
                  top.earnedDesc,
                  textAlign: TextAlign.center,
                  style: Theme.of(dialogContext).textTheme.bodyMedium?.copyWith(
                        color: Colors.white.withValues(alpha: 0.72),
                      ),
                ),
                if (extra > 0) ...[
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: gold.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '+$extra more unlocked',
                      style: TextStyle(
                          color: gold,
                          fontWeight: FontWeight.w700,
                          fontSize: 12),
                    ),
                  ),
                ],
              ],
            ),
            actionsAlignment: MainAxisAlignment.center,
            actions: [
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                style: FilledButton.styleFrom(
                  backgroundColor: gold,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 32, vertical: 10),
                ),
                child: const Text('Nice',
                    style: TextStyle(fontWeight: FontWeight.w800)),
              ),
            ],
          );
        },
      );
    } catch (_) {
      // A celebration must never break a session.
    }
  }
}
