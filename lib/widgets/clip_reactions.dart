import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Emoji reactions on a battle clip.
///
/// This is what stands in for comments, which are ruled out entirely so
/// they can't affect the roasters' mental state. Reactions give a viewer
/// something to do and give the feed a real popularity signal, with no text
/// to moderate and nothing anonymous attached to a real person's face.
///
/// THE SET IS WIDE AND INCLUDES NEGATIVE REACTIONS, deliberately. Feedback
/// that can only agree measures how many people watched rather than how
/// good anything was, and the crowd already votes that someone LOST a
/// battle - a far heavier judgement than an emoji. What stays out is
/// contempt aimed at the human rather than at the material: audiences boo
/// the bit, not the person's worth.
///
/// An allowlist rather than free emoji entry, because a field accepting
/// arbitrary characters is a comment box - and avoiding that is the whole
/// reason comments are ruled out.
///
/// Written straight from the client to its own document rather than through
/// a callable: there is nothing to protect. The allowed set is enforced in
/// firestore.rules, you can only write your own, and the worst a modified
/// client could do is react to a clip it could react to anyway. A direct
/// write also means the tap responds instantly with no cold start.
class ClipReactions extends StatelessWidget {
  const ClipReactions({super.key, required this.matchId, required this.counts});

  final String matchId;

  /// Server-side tallies, as of when the feed page was fetched. Deliberately
  /// not live: a listener per clip in a scrolling feed is a lot of sockets
  /// for a number nobody is watching change.
  final Map<String, int> counts;

  /// Ordered roughly from "that killed" through to "that died", so the
  /// strip reads as a spectrum rather than a grab bag. Must stay in step
  /// with the allowlist in firestore.rules and functions/reactions.js.
  static const options = <String, String>{
    // It landed.
    'fire': '🔥',
    'skull': '💀',
    'coffin': '⚰️',
    'cold_blooded': '🥶',
    'bullseye': '🎯',
    'mindblown': '🤯',
    'cry': '😭',
    'laugh': '😂',
    'clap': '👏',
    'salute': '🫡',
    // Reactions to the hit itself.
    'shocked': '😳',
    'hide': '🙈',
    'oof': '😬',
    // It didn't land.
    'ice': '🧊',
    'crickets': '🦗',
    'yawn': '🥱',
    'meh': '🫤',
    'thumbsdown': '👎',
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
        // A horizontal strip rather than a wrapped grid: eighteen chips
        // will not fit across a phone, and a grid would cover the faces,
        // which is the one thing a reaction bar over a video must not do.
        // Whatever this clip has actually received leads, so the strip
        // opens on what people found worth saying rather than on a fixed
        // order nobody chose.
        final ordered = options.keys.toList()
          ..sort((a, b) {
            if (mine == a) return -1;
            if (mine == b) return 1;
            return (counts[b] ?? 0).compareTo(counts[a] ?? 0);
          });
        return SizedBox(
          height: 36,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final entry in ordered.map((k) => MapEntry(k, options[k]!)))
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: _Chip(
                    emoji: entry.value,
                    // Your own tap shows immediately; the server tally is a
                    // page-load snapshot, so add yourself to it rather than
                    // waiting for a refetch to reflect what you just did.
                    count:
                        (counts[entry.key] ?? 0) +
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
          ),
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
            // The brand accent for the selected reaction (white for the
            // rest, which stays legible over any video). Ties the pick to
            // the active skin instead of a hardcoded amber.
            color: selected ? context.palette.accent : Colors.white24,
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
