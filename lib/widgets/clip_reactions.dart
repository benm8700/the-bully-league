import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

/// Emoji reactions on a battle clip.
///
/// This is what stands in for comments, which are ruled out entirely so
/// they can't affect the roasters' mental state. Reactions give a viewer
/// something to do and give the feed a real popularity signal, with no text
/// to moderate and nothing anonymous attached to a real person's face.
///
/// THE SET IS ALL-POSITIVE OR INTENSITY-ONLY, deliberately. A thumbs-down
/// would be a comment section in emoji form - a way for strangers to pile
/// on whoever lost, which is the exact harm that decision prevents. Every
/// option here says something about how hard a line landed, never that a
/// player is bad.
///
/// Written straight from the client to its own document rather than through
/// a callable: there is nothing to protect. The allowed set is enforced in
/// firestore.rules, you can only write your own, and the worst a modified
/// client could do is react to a clip it could react to anyway. A direct
/// write also means the tap responds instantly with no cold start.
class ClipReactions extends StatelessWidget {
  const ClipReactions({
    super.key,
    required this.matchId,
    required this.counts,
  });

  final String matchId;

  /// Server-side tallies, as of when the feed page was fetched. Deliberately
  /// not live: a listener per clip in a scrolling feed is a lot of sockets
  /// for a number nobody is watching change.
  final Map<String, int> counts;

  static const options = <String, String>{
    'fire': '🔥',
    'skull': '💀',
    'cry': '😭',
    'oof': '😬',
  };

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return const SizedBox.shrink();
    final ref = FirebaseFirestore.instance
        .collection('matches')
        .doc(matchId)
        .collection('reactions')
        .doc(uid);

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: ref.snapshots(),
      builder: (context, snap) {
        final mine = snap.data?.data()?['emoji'] as String?;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final entry in options.entries)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: _Chip(
                  emoji: entry.value,
                  // Your own tap shows immediately; the server tally is a
                  // page-load snapshot, so add yourself to it rather than
                  // waiting for a refetch to reflect what you just did.
                  count: (counts[entry.key] ?? 0) +
                      (mine == entry.key && (counts[entry.key] ?? 0) == 0
                          ? 1
                          : 0),
                  selected: mine == entry.key,
                  // Tapping your current reaction clears it, so the choice
                  // is never a trap.
                  onTap: () => mine == entry.key
                      ? ref.delete()
                      : ref.set({
                          'emoji': entry.key,
                          'createdAt': FieldValue.serverTimestamp(),
                        }),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.emoji,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String emoji;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: selected ? 0.75 : 0.45),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected ? Colors.amber : Colors.white24,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(emoji, style: const TextStyle(fontSize: 15)),
            if (count > 0) ...[
              const SizedBox(width: 5),
              Text(
                '$count',
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
