import 'package:flutter/material.dart';

import '../core/emoji_ratings.dart';

/// A player's audience-emoji identity in ONE card (developer's call,
/// 2026-09-29 - merged with the old separate "Crowd badges" row, which
/// duplicated these same four emojis). Each emoji is drawn as its MEDAL - gold
/// for the two positives (🔥/🧠) once a tier is earned, tarnished grey for the
/// two negatives (🥱/💩), dim until earned - with its count, its share of the
/// mix, and the earned tier name beneath. The auto-nickname sits centred below.
class EmojiStatsCard extends StatelessWidget {
  const EmojiStatsCard({super.key, required this.counts});

  /// The user document's emojiCounts map (may be null/partial).
  final Map<String, dynamic>? counts;

  static const _gold = Color(0xFFF4C838);
  static const _tarnish = Color(0xFF9198A3);

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final total = emojiTotalOf(counts);
    final nickname = emojiNicknameOf(counts);
    final percents = emojiPercentsOf(counts);
    final slots = {
      for (final s in emojiBadgeSlots(counts)) s.emojiKey: s,
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: total == 0
          ? Text(
              'No ratings yet. Win a crowd over and your \u{1F525} starts '
              'stacking up here.',
              style: text.bodySmall,
            )
          : Column(
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final r in kEmojiRatings)
                      Expanded(
                        child: _EmojiColumn(
                          rating: r,
                          slot: slots[r.key]!,
                          count: emojiCountOf(counts, r.key),
                          percent: percents[r.key]!,
                          accent: r.positive ? _gold : _tarnish,
                        ),
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

class _EmojiColumn extends StatelessWidget {
  const _EmojiColumn({
    required this.rating,
    required this.slot,
    required this.count,
    required this.percent,
    required this.accent,
  });

  final EmojiRating rating;
  final EmojiBadgeSlot slot;
  final int count;
  final int percent;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final earned = slot.earned;
    return Column(
      children: [
        _Medal(emoji: rating.emoji, earned: earned, accent: accent),
        const SizedBox(height: 6),
        Text(
          '$count',
          style: text.titleMedium?.copyWith(fontWeight: FontWeight.w800),
        ),
        Text(
          '$percent%',
          style: text.bodySmall?.copyWith(
            color: rating.positive
                ? const Color(0xFF6FE39A)
                : Colors.white.withValues(alpha: 0.5),
          ),
        ),
        const SizedBox(height: 2),
        // The earned tier name (Spark / Bright / ...), or a muted dash while
        // still locked - keeps the four columns aligned.
        Text(
          earned ? slot.earnedTier!.title : '—',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: text.labelSmall?.copyWith(
            fontSize: 11,
            fontWeight: earned ? FontWeight.w700 : FontWeight.w400,
            color: earned
                ? (accent == EmojiStatsCard._gold
                    ? EmojiStatsCard._gold
                    : Colors.white.withValues(alpha: 0.72))
                : Colors.white.withValues(alpha: 0.28),
          ),
        ),
      ],
    );
  }
}

/// The compact medallion: the emoji glyph in an [accent]-rimmed disc when a
/// tier is earned, dimmed and grey-rimmed when not. Positives use gold, the two
/// negatives use grey - so a 💩 never reads as a gold honour. Same visual
/// language as the achievement badges (badge_art.dart).
class _Medal extends StatelessWidget {
  const _Medal({required this.emoji, required this.earned, required this.accent});

  final String emoji;
  final bool earned;
  final Color accent;

  static const _size = 46.0;

  @override
  Widget build(BuildContext context) {
    final gold = accent == EmojiStatsCard._gold;
    final discColors = gold
        ? const [Color(0xFF3A2F14), Color(0xFF1A1508)]
        : const [Color(0xFF2C2C33), Color(0xFF151519)];
    return Container(
      width: _size,
      height: _size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          center: const Alignment(-0.3, -0.4),
          radius: 0.95,
          colors: discColors,
        ),
        border: Border.all(
          color: earned
              ? accent.withValues(alpha: 0.85)
              : Colors.white.withValues(alpha: 0.14),
          width: 2,
        ),
        boxShadow: earned
            ? [BoxShadow(color: accent.withValues(alpha: 0.30), blurRadius: 8)]
            : null,
      ),
      child: Center(
        child: Opacity(
          opacity: earned ? 1 : 0.35,
          child: Text(emoji, style: const TextStyle(fontSize: 20)),
        ),
      ),
    );
  }
}
