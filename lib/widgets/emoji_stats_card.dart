import 'package:flutter/material.dart';

import '../core/emoji_ratings.dart';

/// A player's audience-emoji identity: their auto-nickname (from their mix)
/// and the four rating counts. Shown on the profile (own and others') so the
/// emoji ecosystem is a visible part of who a player is.
class EmojiStatsCard extends StatelessWidget {
  const EmojiStatsCard({super.key, required this.counts});

  /// The user document's emojiCounts map (may be null/partial).
  final Map<String, dynamic>? counts;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final total = emojiTotalOf(counts);
    final nickname = emojiNicknameOf(counts);
    final percents = emojiPercentsOf(counts);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The "Crowd read" label is gone (developer's call, 2026-09-29); the
          // emoji row leads and the auto-nickname sits centred UNDERNEATH it.
          if (total == 0)
            Text(
              'No ratings yet. Win a crowd over and your \u{1F525} starts '
              'stacking up here.',
              style: text.bodySmall,
            )
          else
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (final r in kEmojiRatings)
                  Column(
                    children: [
                      Text(r.emoji, style: const TextStyle(fontSize: 26)),
                      const SizedBox(height: 4),
                      Text(
                        '${emojiCountOf(counts, r.key)}',
                        style: text.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800),
                      ),
                      Text(
                        '${percents[r.key]}%',
                        style: text.bodySmall?.copyWith(
                          color: r.positive
                              ? const Color(0xFF6FE39A)
                              : Colors.white.withValues(alpha: 0.5),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          if (nickname != null) ...[
            const SizedBox(height: 14),
            Text(
              '“$nickname”',
              textAlign: TextAlign.center,
              style: text.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: const Color(0xFFFF4D8D),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
